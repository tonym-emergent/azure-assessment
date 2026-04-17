<#
.SYNOPSIS
    Analyzes Azure Virtual Machines for Advisor findings, host utilization, and compute pricing opportunities.

.DESCRIPTION
    This script reviews Azure Virtual Machines in one or more subscriptions and combines four data sources:
    - Azure VM inventory from Azure CLI
    - Azure Advisor recommendations for Cost and Performance categories
    - Azure Monitor host metrics for CPU, network, and disk activity
    - Azure Retail Prices API for pay-as-you-go and reserved instance pricing

    The script produces three outputs in the script directory:
    - {OutputPrefix}-{timestamp}.json
    - {OutputPrefix}-{timestamp}.csv
    - {OutputPrefix}-{timestamp}.html

    The HTML report is self-contained and includes client-side sorting, filtering, and CSV export.

.NOTES
    Requires:
    - PowerShell 7+
    - Azure CLI authenticated with read access to VMs, Advisor, and Azure Monitor metrics
    - Internet access to query the Azure Retail Prices API

    Pricing notes:
    - Pricing is compute-only for the current VM size.
    - The report excludes attached disk costs, savings plans, and Spot pricing.
    - Reserved instance values are displayed as monthly equivalents derived from retail term prices.

    Utilization notes:
    - Uses Azure Monitor host metrics only.
    - Does not require guest memory or VM Insights for the first version.

.PARAMETER ConfigPath
    Optional path to a JSON or JSONC configuration file. Any setting in the config file is used unless
    the same value is explicitly passed on the command line.

.EXAMPLE
    .\azure-vm-assessment.ps1 -ConfigPath .\azure-vm-assessment.config.jsonc

    Runs the assessment using the JSON config file in the script directory.

.EXAMPLE
    .\azure-vm-assessment.ps1 -ConfigPath .\azure-vm-assessment.config.jsonc -DaysToInspect 1 -VMName vmadconnect001

    Runs with the config file but overrides the review window and targets a single VM.

.EXAMPLE
    .\azure-vm-assessment.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -OutputPrefix vm-analysis-weekly

    Runs without a config file by providing values directly as command-line parameters.
#>

param(
    [string]$ConfigPath,
    [int]$DaysToInspect = 14,
    [string[]]$SubscriptionId,
    [string]$OutputPrefix = "vm-analysis",
    [string[]]$VMName,
    [switch]$RefreshAdvisor,
    [double]$UnderutilizedCpuAverageThreshold = 10,
    [double]$UnderutilizedCpuP95Threshold = 25,
    [double]$OverutilizedCpuAverageThreshold = 65,
    [double]$OverutilizedCpuP95Threshold = 85,
    [double]$LowNetworkAverageThresholdMBps = 0.5,
    [double]$LowDiskAverageThresholdMBps = 1.0,
    [double]$BurstableLowCreditsThreshold = 20,
    [int]$MinimumSamplesForClassification = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Utility Functions

function Get-Mean {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return 0
    }

    return [double](($Values | Measure-Object -Average).Average)
}

function Get-Maximum {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return 0
    }

    return [double](($Values | Measure-Object -Maximum).Maximum)
}

function Get-PercentAbove {
    param(
        [double[]]$Values,
        [double]$Threshold
    )

    if (-not $Values -or $Values.Count -eq 0) {
        return 0
    }

    $hits = @($Values | Where-Object { $_ -gt $Threshold }).Count
    return ($hits / $Values.Count) * 100
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [ValidateRange(0, 100)]
        [double]$Percentile
    )

    if (-not $Values -or $Values.Count -eq 0) {
        return 0
    }

    $sorted = $Values | Sort-Object
    $rank = [math]::Ceiling(($Percentile / 100) * $sorted.Count)
    $index = [math]::Max([math]::Min($rank - 1, $sorted.Count - 1), 0)
    return [double]$sorted[$index]
}

function Join-TagSummary {
    param($Tags)

    if (-not $Tags) {
        return ""
    }

    $pairs = foreach ($property in $Tags.PSObject.Properties) {
        "{0}={1}" -f $property.Name, $property.Value
    }

    return ($pairs | Sort-Object) -join "; "
}

function ConvertTo-Array {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Normalize-StringList {
    param($Value)

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($entry in (ConvertTo-Array -Value $Value)) {
        if ($null -eq $entry) {
            continue
        }

        foreach ($segment in ([string]$entry -split ',')) {
            $trimmed = $segment.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $items.Add($trimmed)
            }
        }
    }

    return @($items | Select-Object -Unique)
}

function ConvertTo-Boolean {
    param($Value)

    if ($Value -is [bool]) {
        return $Value
    }

    if ($Value -is [string]) {
        $normalized = $Value.Trim().ToLowerInvariant()
        if ($normalized -in @("true", "1", "yes", "y", "on")) {
            return $true
        }

        if ($normalized -in @("false", "0", "no", "n", "off")) {
            return $false
        }
    }

    return [bool]$Value
}

function Resolve-ConfigPath {
    param(
        [string]$Path,
        [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $BaseDirectory $Path
}

function Import-AssessmentConfig {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{}
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        return @{}
    }

    # Allow JSONC-style comments in config files so the template can document each setting inline.
    $content = [System.Text.RegularExpressions.Regex]::Replace($content, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $content = [System.Text.RegularExpressions.Regex]::Replace($content, '(?m)^\s*//.*$', '')

    $parsed = $content | ConvertFrom-Json -AsHashtable
    if (-not $parsed) {
        return @{}
    }

    return $parsed
}

function Get-PrimaryZone {
    param($Zones)

    if (-not $Zones) {
        return ""
    }

    if ($Zones -is [System.Array] -and $Zones.Count -gt 0) {
        return [string]$Zones[0]
    }

    return [string]$Zones
}

function Invoke-AzCliRaw {
    param([string[]]$Arguments)

    $azPath = (Get-Command az -ErrorAction Stop).Source
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $azPath

    foreach ($arg in ($Arguments + @("--only-show-errors", "--output", "json"))) {
        [void]$psi.ArgumentList.Add($arg)
    }

    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Error $stderr.Trim()
        }

        throw "az $($Arguments -join ' ') failed with exit code $($process.ExitCode)"
    }

    return $stdout
}

function Invoke-AzCliJson {
    param([string[]]$Arguments)

    $json = Invoke-AzCliRaw -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json
}

function Invoke-RetailPriceQuery {
    param([string]$Filter)

    $baseUri = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&meterRegion='primary'"
    $requestUri = "{0}&`$filter={1}" -f $baseUri, [System.Uri]::EscapeDataString($Filter)
    $items = @()

    while ($requestUri) {
        try {
            $response = Invoke-RestMethod -Uri $requestUri -Method Get -TimeoutSec 60
        }
        catch {
            throw "Retail prices API request failed for filter [$Filter]: $($_.Exception.Message)"
        }

        if ($response.Items) {
            $items += @($response.Items)
        }

        $requestUri = $response.NextPageLink
    }

    return $items
}

function Get-IntervalConfig {
    param([int]$Days)

    if ($Days -gt 89) {
        return [pscustomobject]@{
            Interval = "PT1H"
            SecondsPerSample = 3600
        }
    }

    if ($Days -gt 29) {
        return [pscustomobject]@{
            Interval = "PT5M"
            SecondsPerSample = 300
        }
    }

    return [pscustomobject]@{
        Interval = "PT1M"
        SecondsPerSample = 60
    }
}

function Invoke-AzMetricQuery {
    param(
        [string]$ResourceId,
        [string[]]$MetricNames,
        [string[]]$Aggregations,
        [string]$Interval,
        [datetime]$AnalysisWindowStart,
        [datetime]$AnalysisWindowEnd
    )

    $arguments = @(
        "monitor", "metrics", "list",
        "--resource", $ResourceId,
        "--metrics", ($MetricNames -join ","),
        "--aggregation"
    )

    $arguments += $Aggregations
    $arguments += @(
        "--interval", $Interval,
        "--start-time", $AnalysisWindowStart.ToString("yyyy-MM-ddTHH:mm:ssZ"),
        "--end-time", $AnalysisWindowEnd.ToString("yyyy-MM-ddTHH:mm:ssZ")
    )

    return Invoke-AzCliJson -Arguments $arguments
}

function Add-MetricBatchResults {
    param(
        [hashtable]$Map,
        [System.Array]$Batch,
        $MetricsResponse
    )

    $batchMap = Get-MetricSeriesMap -MetricsResponse $MetricsResponse
    foreach ($plan in $Batch) {
        if ($batchMap.ContainsKey($plan.Name)) {
            $Map[$plan.Name] = ConvertTo-Array -Value $batchMap[$plan.Name]
        }
        else {
            $Map[$plan.Name] = @()
        }
    }
}

function Invoke-AdaptiveMetricBatch {
    param(
        [string]$ResourceId,
        [System.Array]$Batch,
        [string]$Interval,
        [datetime]$AnalysisWindowStart,
        [datetime]$AnalysisWindowEnd,
        [hashtable]$Map
    )

    $batchMetricNames = @($Batch | ForEach-Object { $_.Name })
    $batchAggregations = @($Batch | ForEach-Object { $_.Aggregations } | Select-Object -Unique)

    try {
        $metrics = Invoke-AzMetricQuery -ResourceId $ResourceId -MetricNames $batchMetricNames -Aggregations $batchAggregations -Interval $Interval -AnalysisWindowStart $AnalysisWindowStart -AnalysisWindowEnd $AnalysisWindowEnd
        Add-MetricBatchResults -Map $Map -Batch $Batch -MetricsResponse $metrics
        return
    }
    catch {
        if ($Batch.Count -gt 1) {
            $midpoint = [math]::Floor($Batch.Count / 2)
            $leftBatch = @($Batch[0..($midpoint - 1)])
            $rightBatch = @($Batch[$midpoint..($Batch.Count - 1)])

            Invoke-AdaptiveMetricBatch -ResourceId $ResourceId -Batch $leftBatch -Interval $Interval -AnalysisWindowStart $AnalysisWindowStart -AnalysisWindowEnd $AnalysisWindowEnd -Map $Map
            Invoke-AdaptiveMetricBatch -ResourceId $ResourceId -Batch $rightBatch -Interval $Interval -AnalysisWindowStart $AnalysisWindowStart -AnalysisWindowEnd $AnalysisWindowEnd -Map $Map
            return
        }

        $plan = $Batch[0]
        Write-Warning "Metric query failed for $ResourceId metric '$($plan.Name)' : $($_.Exception.Message)"
        $Map[$plan.Name] = @()
    }
}

function Get-MetricSeriesMap {
    param($MetricsResponse)

    $map = @{}
    if (-not $MetricsResponse -or -not $MetricsResponse.value) {
        return $map
    }

    foreach ($metric in $MetricsResponse.value) {
        $points = @()
        if ($metric.timeseries) {
            foreach ($series in $metric.timeseries) {
                if ($series.data) {
                    $points += @($series.data)
                }
            }
        }

        $map[$metric.name.value] = @($points | Sort-Object timeStamp)
    }

    return $map
}

function Get-ValueSamples {
    param(
        [System.Array]$Series,
        [string]$PropertyName
    )

    if (-not $Series) {
        return @()
    }

    $values = foreach ($point in $Series) {
        $property = $point.PSObject.Properties[$PropertyName]
        if ($property -and $null -ne $property.Value) {
            [double]$property.Value
        }
    }

    return @($values)
}

function Get-CombinedRateSamples {
    param(
        [System.Array[]]$SeriesCollection,
        [int]$SecondsPerSample
    )

    $bucket = @{}

    foreach ($series in $SeriesCollection) {
        if (-not $series) {
            continue
        }

        foreach ($point in $series) {
            $totalProperty = $point.PSObject.Properties['total']
            if (-not $totalProperty -or $null -eq $totalProperty.Value) {
                continue
            }

            $key = [string]$point.timeStamp
            if (-not $bucket.ContainsKey($key)) {
                $bucket[$key] = 0.0
            }

            $bucket[$key] += ([double]$totalProperty.Value / 1MB / $SecondsPerSample)
        }
    }

    return @($bucket.GetEnumerator() | Sort-Object Name | ForEach-Object { [double]$_.Value })
}

function Test-IsWindowsPrice {
    param($Item)

    $productName = [string]$Item.productName
    $meterName = [string]$Item.meterName

    return ($productName -match "Windows" -or $meterName -match "Windows") -and
        $productName -notmatch "SQL|BizTalk|Visual Studio|Oracle"
}

function Test-IsLinuxBasePrice {
    param($Item)

    $productName = [string]$Item.productName
    $meterName = [string]$Item.meterName
    $combined = "$productName $meterName"

    return $combined -notmatch "Windows|SQL|BizTalk|Visual Studio|Oracle|Red Hat|RedHat|RHEL|SUSE|Ubuntu Pro"
}

function Test-PrimaryMeter {
    param($Item)

    if ($null -eq $Item.isPrimaryMeterRegion) {
        return $true
    }

    if ($Item.isPrimaryMeterRegion -is [bool]) {
        return $Item.isPrimaryMeterRegion
    }

    return ([string]$Item.isPrimaryMeterRegion).ToLowerInvariant() -eq "true"
}

function Get-PriceDescriptorText {
    param($Item)

    return (@(
            [string]$Item.armSkuName,
            [string]$Item.skuName,
            [string]$Item.productName,
            [string]$Item.meterName
        ) -join ' ').Trim()
}

function Test-IsVmAddonPrice {
    param($Item)

    $text = Get-PriceDescriptorText -Item $Item
    return $text -match 'Spot|Low Priority|Dedicated Host|SQL|BizTalk|Visual Studio|Oracle'
}

function Test-IsLinuxLicensedPrice {
    param($Item)

    $text = Get-PriceDescriptorText -Item $Item
    return $text -match 'Red Hat|RedHat|RHEL|SUSE|Ubuntu Pro'
}

function Test-HasWindowsLicenseBenefit {
    param(
        [string]$OsType,
        [string]$LicenseType
    )

    if ([string]$OsType -ne 'Windows') {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($LicenseType)) {
        return $false
    }

    $normalized = ([string]$LicenseType).Trim().ToLowerInvariant()
    return $normalized -match 'windows|hybrid'
}

function Select-PriceMatch {
    param(
        [System.Array]$Items,
        [string]$PriceType,
        [string]$OsType,
        [string]$ArmSkuName,
        [string]$ReservationTerm
    )

    $candidates = @($Items | Where-Object {
            $_.type -eq $PriceType -and
            (Test-PrimaryMeter -Item $_) -and
            ([string]$_.meterName) -notmatch 'Spot|Low Priority' -and
            ([string]$_.skuName) -notmatch 'Spot|Low Priority'
        })

    if ($PriceType -eq 'Consumption') {
        $candidates = @($candidates | Where-Object { $_.unitOfMeasure -eq '1 Hour' })
    }

    if (-not [string]::IsNullOrWhiteSpace($ReservationTerm)) {
        $candidates = @($candidates | Where-Object { $_.reservationTerm -eq $ReservationTerm })
    }

    $scored = foreach ($item in $candidates) {
        if (Test-IsVmAddonPrice -Item $item) {
            continue
        }

        $text = Get-PriceDescriptorText -Item $item
        $isWindowsTagged = $text -match '\bWindows\b'
        $isLinuxLicensed = Test-IsLinuxLicensedPrice -Item $item
        $isGenericBase = -not $isWindowsTagged -and -not $isLinuxLicensed
        $score = 0
        $matchType = 'Unmatched'

        if ([string]$item.armSkuName -eq $ArmSkuName) {
            $score += 200
        }

        if ($PriceType -eq 'Consumption') {
            if ($OsType -eq 'Windows') {
                if ($isWindowsTagged) {
                    $score += 120
                    $matchType = 'WindowsTagged'
                }
                elseif ($isGenericBase) {
                    $score += 70
                    $matchType = 'GenericBaseFallback'
                }
                else {
                    continue
                }
            }
            else {
                if ($isWindowsTagged -or $isLinuxLicensed) {
                    continue
                }

                $score += 120
                $matchType = 'BaseCompute'
            }
        }
        else {
            if ($OsType -eq 'Windows') {
                if ($isWindowsTagged) {
                    $score += 110
                    $matchType = 'WindowsReservation'
                }
                elseif ($isGenericBase) {
                    $score += 100
                    $matchType = 'GenericReservationFallback'
                }
                else {
                    continue
                }
            }
            else {
                if ($isWindowsTagged -or $isLinuxLicensed) {
                    continue
                }

                $score += 110
                $matchType = 'BaseReservation'
            }
        }

        if ([string]$item.productName -match 'Virtual Machines') {
            $score += 10
        }

        [pscustomobject]@{
            Item = $item
            Score = $score
            MatchType = $matchType
        }
    }

    return $scored | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = { [double]$_.Item.retailPrice }; Descending = $false } | Select-Object -First 1
}

function Get-BestMonthlyPricingSummary {
    param(
        $Pricing,
        [double]$BaselineMonthly
    )

    $bestMonthlyOption = 'PAYG'
    $bestMonthlyCost = [double]$Pricing.PaygMonthly

    foreach ($candidate in @(
            [pscustomobject]@{ Name = '1YR RI'; Cost = [double]$Pricing.Reservation1YearMonthly },
            [pscustomobject]@{ Name = '3YR RI'; Cost = [double]$Pricing.Reservation3YearMonthly }
        )) {
        if ($candidate.Cost -gt 0 -and ($bestMonthlyCost -eq 0 -or $candidate.Cost -lt $bestMonthlyCost)) {
            $bestMonthlyCost = $candidate.Cost
            $bestMonthlyOption = $candidate.Name
        }
    }

    $bestMonthlySavings = if ($BaselineMonthly -gt 0 -and $bestMonthlyCost -gt 0) {
        [math]::Round($BaselineMonthly - $bestMonthlyCost, 2)
    }
    else {
        0
    }

    return [pscustomobject]@{
        BestMonthlyOption = $bestMonthlyOption
        BestMonthlyCost = [math]::Round($bestMonthlyCost, 2)
        BestMonthlySavings = $bestMonthlySavings
    }
}

function Get-SkuCapabilityValue {
    param(
        $Capabilities,
        [string]$Name
    )

    foreach ($capability in (ConvertTo-Array -Value $Capabilities)) {
        if ([string]$capability.name -eq $Name) {
            return [string]$capability.value
        }
    }

    return $null
}

function Get-RegionVmSkuCatalog {
    param(
        [string]$Location,
        [hashtable]$Cache
    )

    $cacheKey = ([string]$Location).ToLowerInvariant()
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    $skuResponse = Invoke-AzCliJson -Arguments @('vm', 'list-skus', '--location', $Location, '--resource-type', 'virtualMachines')
    $catalog = foreach ($sku in (ConvertTo-Array -Value $skuResponse)) {
        $name = [string]$sku.name
        if ($name -notmatch '^Standard_([BDE])') {
            continue
        }

        if ($name -match 'Promo') {
            continue
        }

        $restrictions = ConvertTo-Array -Value $sku.restrictions
        if (@($restrictions | Where-Object { ([string]$_.reasonCode) -match 'NotAvailable' }).Count -gt 0) {
            continue
        }

        $family = $Matches[1]
        $vcpuValue = Get-SkuCapabilityValue -Capabilities $sku.capabilities -Name 'vCPUsAvailable'
        if ([string]::IsNullOrWhiteSpace($vcpuValue)) {
            $vcpuValue = Get-SkuCapabilityValue -Capabilities $sku.capabilities -Name 'vCPUs'
        }

        $memoryValue = Get-SkuCapabilityValue -Capabilities $sku.capabilities -Name 'MemoryGB'
        if ([string]::IsNullOrWhiteSpace($vcpuValue) -or [string]::IsNullOrWhiteSpace($memoryValue)) {
            continue
        }

        [pscustomobject]@{
            Name = $name
            Family = $family
            VCpu = [int][math]::Round([double]$vcpuValue, 0)
            MemoryGB = [double]$memoryValue
            MaxDataDiskCount = [int]([double](Get-SkuCapabilityValue -Capabilities $sku.capabilities -Name 'MaxDataDiskCount'))
            PremiumIO = (Get-SkuCapabilityValue -Capabilities $sku.capabilities -Name 'PremiumIO')
        }
    }

    $catalog = @($catalog | Sort-Object VCpu, MemoryGB, Name)
    $Cache[$cacheKey] = $catalog
    return $catalog
}

function Get-PricingModel {
    param(
        [string]$ArmRegionName,
        [string]$ArmSkuName,
        [string]$OsType,
        [string]$LicenseType,
        [hashtable]$Cache
    )

    $licenseMode = if (Test-HasWindowsLicenseBenefit -OsType $OsType -LicenseType $LicenseType) { 'benefit' } else { 'standard' }
    $cacheKey = ("{0}|{1}|{2}|{3}" -f $ArmRegionName, $ArmSkuName, $OsType, $licenseMode).ToLowerInvariant()
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$ArmRegionName' and armSkuName eq '$ArmSkuName'"
    try {
        $items = Invoke-RetailPriceQuery -Filter $filter
    }
    catch {
        $fallback = [pscustomobject]@{
            CurrencyCode = "USD"
            PaygHourly = 0
            PaygMonthly = 0
            PaygComputeMonthly = 0
            Reservation1YearTotal = 0
            Reservation1YearMonthly = 0
            Reservation1YearComputeMonthly = 0
            Reservation3YearTotal = 0
            Reservation3YearMonthly = 0
            Reservation3YearComputeMonthly = 0
            IncludeOsLicense = $false
            LicenseBenefitApplied = $false
            OsLicenseHourly = 0
            OsLicenseMonthly = 0
            OsLicenseStatus = 'LookupFailed'
            PricingStatus = "Pricing lookup failed"
            PaygMatchType = ''
            Reservation1YearMatchType = ''
            Reservation3YearMatchType = ''
            MeterName = ""
            ProductName = ""
        }

        $Cache[$cacheKey] = $fallback
        Write-Warning "Pricing lookup failed for $ArmSkuName in ${ArmRegionName}: $($_.Exception.Message)"
        return $fallback
    }

    $includeOsLicense = [string]$OsType -eq 'Windows' -and -not (Test-HasWindowsLicenseBenefit -OsType $OsType -LicenseType $LicenseType)
    $basePaygSelection = Select-PriceMatch -Items $items -PriceType 'Consumption' -OsType 'Linux' -ArmSkuName $ArmSkuName -ReservationTerm ''
    $windowsPaygSelection = if ([string]$OsType -eq 'Windows') {
        Select-PriceMatch -Items $items -PriceType 'Consumption' -OsType 'Windows' -ArmSkuName $ArmSkuName -ReservationTerm ''
    }
    else {
        $basePaygSelection
    }

    $ri1BaseSelection = Select-PriceMatch -Items $items -PriceType 'Reservation' -OsType 'Linux' -ArmSkuName $ArmSkuName -ReservationTerm '1 Year'
    $ri3BaseSelection = Select-PriceMatch -Items $items -PriceType 'Reservation' -OsType 'Linux' -ArmSkuName $ArmSkuName -ReservationTerm '3 Years'
    $ri1Selection = if ([string]$OsType -eq 'Windows') {
        Select-PriceMatch -Items $items -PriceType 'Reservation' -OsType 'Windows' -ArmSkuName $ArmSkuName -ReservationTerm '1 Year'
    }
    else {
        $ri1BaseSelection
    }
    $ri3Selection = if ([string]$OsType -eq 'Windows') {
        Select-PriceMatch -Items $items -PriceType 'Reservation' -OsType 'Windows' -ArmSkuName $ArmSkuName -ReservationTerm '3 Years'
    }
    else {
        $ri3BaseSelection
    }

    $basePayg = if ($basePaygSelection) { $basePaygSelection.Item } else { $null }
    $windowsPayg = if ($windowsPaygSelection) { $windowsPaygSelection.Item } else { $null }
    $ri1Base = if ($ri1BaseSelection) { $ri1BaseSelection.Item } else { $null }
    $ri3Base = if ($ri3BaseSelection) { $ri3BaseSelection.Item } else { $null }
    $ri1 = if ($ri1Selection) { $ri1Selection.Item } else { $null }
    $ri3 = if ($ri3Selection) { $ri3Selection.Item } else { $null }

    $basePaygHourly = if ($basePayg) { [double]$basePayg.retailPrice } else { 0 }
    $windowsPaygHourly = if ($windowsPayg) { [double]$windowsPayg.retailPrice } else { 0 }
    $basePaygMonthly = if ($basePaygHourly -gt 0) { [math]::Round($basePaygHourly * 730, 2) } else { 0 }

    $osLicenseHourly = 0
    $osLicenseStatus = if ([string]$OsType -ne 'Windows') {
        'NotApplicable'
    }
    elseif ($includeOsLicense) {
        'EstimateUnavailable'
    }
    else {
        'ExcludedByLicenseBenefit'
    }

    if ($includeOsLicense -and $windowsPaygSelection -and $windowsPaygSelection.MatchType -eq 'WindowsTagged' -and $windowsPaygHourly -gt $basePaygHourly) {
        $osLicenseHourly = [math]::Round([math]::Max($windowsPaygHourly - $basePaygHourly, 0), 6)
        $osLicenseStatus = 'DerivedFromWindowsConsumptionDelta'
    }

    $osLicenseMonthly = if ($osLicenseHourly -gt 0) { [math]::Round($osLicenseHourly * 730, 2) } else { 0 }
    $paygHourly = 0

    if ($includeOsLicense) {
        if ($windowsPaygHourly -gt 0) {
            $paygHourly = $windowsPaygHourly
        }
        elseif ($basePaygHourly -gt 0 -and $osLicenseHourly -gt 0) {
            $paygHourly = $basePaygHourly + $osLicenseHourly
        }
        else {
            $paygHourly = $basePaygHourly
        }
    }
    elseif ($basePaygHourly -gt 0) {
        $paygHourly = $basePaygHourly
    }
    else {
        $paygHourly = $windowsPaygHourly
    }

    $paygMonthly = if ($paygHourly -gt 0) { [math]::Round($paygHourly * 730, 2) } else { 0 }
    $ri1BaseMonthly = if ($ri1Base) { [math]::Round(([double]$ri1Base.retailPrice) / 12, 2) } else { 0 }
    $ri3BaseMonthly = if ($ri3Base) { [math]::Round(([double]$ri3Base.retailPrice) / 36, 2) } else { 0 }
    $ri1RawMonthly = if ($ri1) { [math]::Round(([double]$ri1.retailPrice) / 12, 2) } else { 0 }
    $ri3RawMonthly = if ($ri3) { [math]::Round(([double]$ri3.retailPrice) / 36, 2) } else { 0 }

    if ($includeOsLicense) {
        if ($ri1Selection -and $ri1Selection.MatchType -eq 'WindowsReservation') {
            $ri1Monthly = $ri1RawMonthly
        }
        elseif ($ri1BaseMonthly -gt 0) {
            $ri1Monthly = [math]::Round($ri1BaseMonthly + $osLicenseMonthly, 2)
        }
        else {
            $ri1Monthly = $ri1RawMonthly
        }

        if ($ri3Selection -and $ri3Selection.MatchType -eq 'WindowsReservation') {
            $ri3Monthly = $ri3RawMonthly
        }
        elseif ($ri3BaseMonthly -gt 0) {
            $ri3Monthly = [math]::Round($ri3BaseMonthly + $osLicenseMonthly, 2)
        }
        else {
            $ri3Monthly = $ri3RawMonthly
        }
    }
    else {
        $ri1Monthly = if ($ri1BaseMonthly -gt 0) { $ri1BaseMonthly } else { $ri1RawMonthly }
        $ri3Monthly = if ($ri3BaseMonthly -gt 0) { $ri3BaseMonthly } else { $ri3RawMonthly }
    }

    $status = "OK"
    if ($paygMonthly -le 0) {
        $status = "PAYG meter not found"
    }
    elseif ($ri1Monthly -le 0 -and $ri3Monthly -le 0) {
        $status = "RI meters not found"
    }
    elseif ($ri1Monthly -le 0) {
        $status = '1YR RI not found'
    }
    elseif ($ri3Monthly -le 0) {
        $status = '3YR RI not found'
    }

    $currencyCode = if ($windowsPayg) { [string]$windowsPayg.currencyCode } elseif ($basePayg) { [string]$basePayg.currencyCode } elseif ($ri1) { [string]$ri1.currencyCode } elseif ($ri3) { [string]$ri3.currencyCode } else { "USD" }

    $result = [pscustomobject]@{
        CurrencyCode = $currencyCode
        PaygHourly = [math]::Round($paygHourly, 6)
        PaygMonthly = $paygMonthly
        PaygComputeMonthly = $basePaygMonthly
        Reservation1YearTotal = if ($ri1Base) { [math]::Round([double]$ri1Base.retailPrice, 2) } elseif ($ri1) { [math]::Round([double]$ri1.retailPrice, 2) } else { 0 }
        Reservation1YearMonthly = $ri1Monthly
        Reservation1YearComputeMonthly = $ri1BaseMonthly
        Reservation3YearTotal = if ($ri3Base) { [math]::Round([double]$ri3Base.retailPrice, 2) } elseif ($ri3) { [math]::Round([double]$ri3.retailPrice, 2) } else { 0 }
        Reservation3YearMonthly = $ri3Monthly
        Reservation3YearComputeMonthly = $ri3BaseMonthly
        IncludeOsLicense = $includeOsLicense
        LicenseBenefitApplied = -not $includeOsLicense -and [string]$OsType -eq 'Windows' -and (Test-HasWindowsLicenseBenefit -OsType $OsType -LicenseType $LicenseType)
        OsLicenseHourly = $osLicenseHourly
        OsLicenseMonthly = $osLicenseMonthly
        OsLicenseStatus = $osLicenseStatus
        PricingStatus = $status
        PaygMatchType = if ($windowsPaygSelection) { [string]$windowsPaygSelection.MatchType } elseif ($basePaygSelection) { [string]$basePaygSelection.MatchType } else { '' }
        Reservation1YearMatchType = if ($ri1Selection) { [string]$ri1Selection.MatchType } else { '' }
        Reservation3YearMatchType = if ($ri3Selection) { [string]$ri3Selection.MatchType } else { '' }
        MeterName = if ($windowsPayg) { [string]$windowsPayg.meterName } elseif ($basePayg) { [string]$basePayg.meterName } else { "" }
        ProductName = if ($windowsPayg) { [string]$windowsPayg.productName } elseif ($basePayg) { [string]$basePayg.productName } else { "" }
    }

    $Cache[$cacheKey] = $result
    return $result
}

function Get-VmTelemetry {
    param(
        [string]$ResourceId,
        [pscustomobject]$IntervalConfig,
        [datetime]$AnalysisWindowStart,
        [datetime]$AnalysisWindowEnd,
        [bool]$IsBurstable
    )

    $metricPlans = @(
        @{ Name = "Percentage CPU"; Aggregations = @("Average", "Maximum") },
        @{ Name = "Network In Total"; Aggregations = @("Total") },
        @{ Name = "Network Out Total"; Aggregations = @("Total") },
        @{ Name = "Disk Read Bytes"; Aggregations = @("Total") },
        @{ Name = "Disk Write Bytes"; Aggregations = @("Total") }
    )

    $metricBatches = @(
        @(
            @{ Name = "Percentage CPU"; Aggregations = @("Average", "Maximum") }
        ),
        @(
            @{ Name = "Network In Total"; Aggregations = @("Total") },
            @{ Name = "Network Out Total"; Aggregations = @("Total") },
            @{ Name = "Disk Read Bytes"; Aggregations = @("Total") },
            @{ Name = "Disk Write Bytes"; Aggregations = @("Total") }
        )
    )

    if ($IsBurstable) {
        $burstablePlans = @(
            @{ Name = "CPU Credits Remaining"; Aggregations = @("Average") },
            @{ Name = "CPU Credits Consumed"; Aggregations = @("Average") }
        )

        $metricPlans += $burstablePlans
        $metricBatches += ,@($burstablePlans)
    }

    $map = @{}
    foreach ($batch in $metricBatches) {
        Invoke-AdaptiveMetricBatch -ResourceId $ResourceId -Batch $batch -Interval $IntervalConfig.Interval -AnalysisWindowStart $AnalysisWindowStart -AnalysisWindowEnd $AnalysisWindowEnd -Map $map
    }

    $cpuSeries = if ($map.ContainsKey("Percentage CPU")) { ConvertTo-Array -Value $map["Percentage CPU"] } else { @() }
    $networkInSeries = if ($map.ContainsKey("Network In Total")) { ConvertTo-Array -Value $map["Network In Total"] } else { @() }
    $networkOutSeries = if ($map.ContainsKey("Network Out Total")) { ConvertTo-Array -Value $map["Network Out Total"] } else { @() }
    $diskReadSeries = if ($map.ContainsKey("Disk Read Bytes")) { ConvertTo-Array -Value $map["Disk Read Bytes"] } else { @() }
    $diskWriteSeries = if ($map.ContainsKey("Disk Write Bytes")) { ConvertTo-Array -Value $map["Disk Write Bytes"] } else { @() }
    $cpuCreditsRemainingSeries = if ($map.ContainsKey("CPU Credits Remaining")) { ConvertTo-Array -Value $map["CPU Credits Remaining"] } else { @() }
    $cpuCreditsConsumedSeries = if ($map.ContainsKey("CPU Credits Consumed")) { ConvertTo-Array -Value $map["CPU Credits Consumed"] } else { @() }

    $cpuAverageSamples = @(Get-ValueSamples -Series $cpuSeries -PropertyName "average")
    $cpuPeakSamples = @()
    if ($cpuSeries.Count -gt 0) {
        $cpuPeakSamples = @(foreach ($point in $cpuSeries) {
            $maximumProperty = $point.PSObject.Properties['maximum']
            $averageProperty = $point.PSObject.Properties['average']

            if ($maximumProperty -and $null -ne $maximumProperty.Value) {
                [double]$maximumProperty.Value
            }
            elseif ($averageProperty -and $null -ne $averageProperty.Value) {
                [double]$averageProperty.Value
            }
        })
    }

    $networkSamples = @(Get-CombinedRateSamples -SeriesCollection @($networkInSeries, $networkOutSeries) -SecondsPerSample $IntervalConfig.SecondsPerSample)
    $diskSamples = @(Get-CombinedRateSamples -SeriesCollection @($diskReadSeries, $diskWriteSeries) -SecondsPerSample $IntervalConfig.SecondsPerSample)
    $cpuCreditsRemaining = @(Get-ValueSamples -Series $cpuCreditsRemainingSeries -PropertyName "average")
    $cpuCreditsConsumed = @(Get-ValueSamples -Series $cpuCreditsConsumedSeries -PropertyName "average")

    $metricsStatus = if (@($cpuAverageSamples).Count -gt 0) { "OK" } else { "No host metrics" }

    return [pscustomobject]@{
        MetricsStatus = $metricsStatus
        SampleCount = @($cpuAverageSamples).Count
        CpuAveragePct = [math]::Round((Get-Mean -Values $cpuAverageSamples), 2)
        CpuP95Pct = [math]::Round((Get-Percentile -Values $cpuAverageSamples -Percentile 95), 2)
        CpuPeakPct = [math]::Round((Get-Maximum -Values $cpuPeakSamples), 2)
        CpuBusyPct = [math]::Round((Get-PercentAbove -Values $cpuAverageSamples -Threshold 20), 2)
        NetworkAverageMBps = [math]::Round((Get-Mean -Values $networkSamples), 3)
        NetworkPeakMBps = [math]::Round((Get-Maximum -Values $networkSamples), 3)
        DiskAverageMBps = [math]::Round((Get-Mean -Values $diskSamples), 3)
        DiskPeakMBps = [math]::Round((Get-Maximum -Values $diskSamples), 3)
        CpuCreditsRemainingAverage = [math]::Round((Get-Mean -Values $cpuCreditsRemaining), 2)
        CpuCreditsConsumedAverage = [math]::Round((Get-Mean -Values $cpuCreditsConsumed), 2)
    }
}

function Get-UtilizationAssessment {
    param(
        $VmRecord,
        $Telemetry,
        [pscustomobject]$IntervalConfig,
        [datetime]$AnalysisWindowStart,
        [datetime]$AnalysisWindowEnd
    )

    $windowSeconds = [math]::Max(($AnalysisWindowEnd - $AnalysisWindowStart).TotalSeconds, 1)
    $coveragePct = [math]::Round([math]::Min((($Telemetry.SampleCount * $IntervalConfig.SecondsPerSample) / $windowSeconds) * 100, 100), 1)
    $confidence = if ($coveragePct -ge 75) { "High" } elseif ($coveragePct -ge 30) { "Medium" } else { "Low" }

    if ($VmRecord.PowerState -match "deallocated|stopped" -and $Telemetry.SampleCount -eq 0) {
        return [pscustomobject]@{
            UtilizationClass = "Stopped"
            UtilizationReason = "VM is $($VmRecord.PowerState) and produced no host metrics in the selected window."
            CoveragePct = $coveragePct
            Confidence = $confidence
        }
    }

    if ($Telemetry.SampleCount -lt $MinimumSamplesForClassification) {
        return [pscustomobject]@{
            UtilizationClass = "Insufficient Data"
            UtilizationReason = "Only $($Telemetry.SampleCount) CPU samples were available across the review period."
            CoveragePct = $coveragePct
            Confidence = $confidence
        }
    }

    if ($VmRecord.IsBurstable -and $Telemetry.CpuCreditsRemainingAverage -gt 0 -and $Telemetry.CpuCreditsRemainingAverage -lt $BurstableLowCreditsThreshold -and $Telemetry.CpuP95Pct -ge 60) {
        return [pscustomobject]@{
            UtilizationClass = "Burstable Attention"
            UtilizationReason = "B-series credits averaged $($Telemetry.CpuCreditsRemainingAverage) with CPU P95 at $($Telemetry.CpuP95Pct)%."
            CoveragePct = $coveragePct
            Confidence = $confidence
        }
    }

    if ($Telemetry.CpuAveragePct -ge $OverutilizedCpuAverageThreshold -or $Telemetry.CpuP95Pct -ge $OverutilizedCpuP95Threshold) {
        return [pscustomobject]@{
            UtilizationClass = "Overutilized"
            UtilizationReason = "CPU average $($Telemetry.CpuAveragePct)% and P95 $($Telemetry.CpuP95Pct)% indicate sustained pressure."
            CoveragePct = $coveragePct
            Confidence = $confidence
        }
    }

    if ($Telemetry.CpuAveragePct -le $UnderutilizedCpuAverageThreshold -and
        $Telemetry.CpuP95Pct -le $UnderutilizedCpuP95Threshold -and
        $Telemetry.CpuBusyPct -le 10 -and
        $Telemetry.NetworkAverageMBps -le $LowNetworkAverageThresholdMBps -and
        $Telemetry.DiskAverageMBps -le $LowDiskAverageThresholdMBps) {

        return [pscustomobject]@{
            UtilizationClass = "Underutilized"
            UtilizationReason = "CPU average $($Telemetry.CpuAveragePct)% with low network and disk throughput suggests excess headroom."
            CoveragePct = $coveragePct
            Confidence = $confidence
        }
    }

    return [pscustomobject]@{
        UtilizationClass = "Balanced"
        UtilizationReason = "Host metrics did not show clear underutilization or sustained saturation."
        CoveragePct = $coveragePct
        Confidence = $confidence
    }
}

function Get-AdvisorRecommendations {
    param(
        [string]$Subscription,
        [bool]$ShouldRefresh
    )

    $advisorItems = @()
    foreach ($category in @("Cost", "Performance")) {
        $arguments = @("advisor", "recommendation", "list", "--category", $category, "--subscription", $Subscription)
        if ($ShouldRefresh) {
            $arguments += "--refresh"
        }

        try {
            $response = Invoke-AzCliJson -Arguments $arguments
            if ($response) {
                $advisorItems += @($response)
            }
        }
        catch {
            Write-Warning "Advisor query failed for subscription $Subscription category ${category}: $($_.Exception.Message)"
        }
    }

    $vmRecommendations = @($advisorItems | Where-Object {
            $resourceId = [string]$_.resourceMetadata.resourceId
            $resourceId -match "/providers/Microsoft.Compute/virtualMachines/"
        })

    $map = @{}
    foreach ($recommendation in $vmRecommendations) {
        $resourceId = ([string]$recommendation.resourceMetadata.resourceId).ToLowerInvariant()
        if (-not $map.ContainsKey($resourceId)) {
            $map[$resourceId] = New-Object System.Collections.Generic.List[object]
        }

        $map[$resourceId].Add([pscustomobject]@{
                Category = [string]$recommendation.category
                Impact = [string]$recommendation.impact
                Problem = [string]$recommendation.shortDescription.problem
                Solution = [string]$recommendation.shortDescription.solution
                RecommendationTypeId = [string]$recommendation.recommendationTypeId
            })
    }

    return $map
}

function Get-RecommendationText {
    param($Record)

    $actions = [System.Collections.Generic.List[string]]::new()

    switch ($Record.UtilizationClass) {
        "Underutilized" {
            $actions.Add("Review rightsizing or shutdown scheduling before committing to the current VM size.")
        }
        "Overutilized" {
            $actions.Add("Review a larger SKU or performance tuning for sustained CPU pressure.")
        }
        "Burstable Attention" {
            $actions.Add("Review B-series credit burn; sustained load may justify a non-burstable SKU.")
        }
        "Stopped" {
            $actions.Add("Confirm the VM still needs to exist and that attached resources match the intended lifecycle.")
        }
        "Insufficient Data" {
            $actions.Add("Collect more runtime data before making commitment or sizing decisions.")
        }
        default {
            $actions.Add("Current host signals look stable for the selected VM size.")
        }
    }

    if ($Record.AdvisorCostCount -gt 0) {
        $actions.Add("Azure Advisor has cost recommendations that should be reviewed alongside this assessment.")
    }

    if ($Record.AdvisorPerformanceCount -gt 0) {
        $actions.Add("Azure Advisor has performance recommendations for this VM.")
    }

    if ($Record.UtilizationClass -notin @("Underutilized", "Insufficient Data") -and $Record.Reservation3YearMonthly -gt 0 -and $Record.Savings3YearMonthly -gt 0) {
        $actions.Add("If workload tenure is stable, 3-year RI is the lowest estimated monthly option for the current SKU.")
    }
    elseif ($Record.UtilizationClass -notin @("Underutilized", "Insufficient Data") -and $Record.Reservation1YearMonthly -gt 0 -and $Record.Savings1YearMonthly -gt 0) {
        $actions.Add("If workload tenure is stable, 1-year RI reduces estimated monthly cost for the current SKU.")
    }

    return (($actions | Select-Object -Unique) -join " ")
}

function Get-SkuRecommendationProfile {
    param(
        $VmRecord,
        $CurrentSpec
    )

    $preferredFamily = $CurrentSpec.Family
    $allowFamilySwitch = $false
    $includeCurrentSku = $false
    $targetVCpu = $CurrentSpec.VCpu
    $targetMemoryGB = $CurrentSpec.MemoryGB
    $profileReason = 'Candidate sizing stayed close to the current VM profile.'

    $strongUnderutilization = $VmRecord.UtilizationClass -eq 'Underutilized' -and
        $VmRecord.CpuAveragePct -le 5 -and
        $VmRecord.CpuP95Pct -le 15 -and
        $VmRecord.NetworkAverageMBps -le ($LowNetworkAverageThresholdMBps * 0.6) -and
        $VmRecord.DiskAverageMBps -le ($LowDiskAverageThresholdMBps * 0.6)

    switch ($VmRecord.UtilizationClass) {
        'Underutilized' {
            $factor = if ($strongUnderutilization) { 0.25 } else { 0.5 }
            $targetVCpu = [math]::Max(1, [int][math]::Ceiling($CurrentSpec.VCpu * $factor))
            $targetMemoryGB = [math]::Max(1, [math]::Round($CurrentSpec.MemoryGB * $factor, 1))
            $allowFamilySwitch = $strongUnderutilization -and $CurrentSpec.Family -ne 'E' -and $targetVCpu -le 4 -and $targetMemoryGB -le 16
            $profileReason = if ($strongUnderutilization) {
                'Low CPU, network, and disk activity support a materially smaller target profile.'
            }
            else {
                'Observed load supports a smaller target profile while staying conservative on memory.'
            }
        }
        'Balanced' {
            $includeCurrentSku = $true
            $profileReason = 'Current utilization is balanced, so the shortlist stays close to the current size.'
        }
        'Overutilized' {
            $growthFactor = if ($VmRecord.CpuP95Pct -ge 95 -or $VmRecord.CpuPeakPct -ge 98) { 2.0 } else { 1.5 }
            $targetVCpu = [math]::Max($CurrentSpec.VCpu + 1, [int][math]::Ceiling($CurrentSpec.VCpu * $growthFactor))
            $targetMemoryGB = [math]::Max($CurrentSpec.MemoryGB, [math]::Round($CurrentSpec.MemoryGB * 1.25, 1))
            if ($CurrentSpec.Family -eq 'B') {
                $preferredFamily = 'D'
                $allowFamilySwitch = $true
            }

            $profileReason = 'Sustained CPU pressure supports moving to a larger target profile.'
        }
        'Burstable Attention' {
            $targetVCpu = $CurrentSpec.VCpu
            $targetMemoryGB = $CurrentSpec.MemoryGB
            $preferredFamily = if ($CurrentSpec.Family -eq 'B') { 'D' } else { $CurrentSpec.Family }
            $allowFamilySwitch = $true
            $profileReason = 'Burst credit pressure favors a non-burstable target profile with similar capacity.'
        }
        'Stopped' {
            $includeCurrentSku = $true
            $profileReason = 'VM is stopped, so the shortlist stays near the current size for review only.'
        }
        'Insufficient Data' {
            $includeCurrentSku = $true
            $profileReason = 'Insufficient host data keeps the shortlist close to the current size.'
        }
    }

    return [pscustomobject]@{
        PreferredFamily = $preferredFamily
        AllowFamilySwitch = $allowFamilySwitch
        IncludeCurrentSku = $includeCurrentSku
        TargetVCpu = $targetVCpu
        TargetMemoryGB = $targetMemoryGB
        ProfileReason = $profileReason
    }
}

function Get-CandidateFitScore {
    param(
        $Candidate,
        $CurrentSpec,
        $Profile,
        $VmRecord
    )

    $score = 0.0
    $score += [math]::Abs($Candidate.VCpu - $Profile.TargetVCpu) * 12
    $score += [math]::Abs($Candidate.MemoryGB - $Profile.TargetMemoryGB) * 1.5

    if ($Candidate.Name -eq $CurrentSpec.Name) {
        if ($Profile.IncludeCurrentSku) {
            $score -= 12
        }
        else {
            $score += 30
        }
    }

    if ($Candidate.Family -ne $Profile.PreferredFamily) {
        $score += if ($Profile.AllowFamilySwitch) { 18 } else { 55 }
    }

    if ($CurrentSpec.Family -eq 'E' -and $Candidate.Family -ne 'E') {
        $score += 30
    }

    switch ($VmRecord.UtilizationClass) {
        'Underutilized' {
            if ($Candidate.VCpu -gt $CurrentSpec.VCpu) {
                $score += 45
            }

            if ($Candidate.MemoryGB -gt $CurrentSpec.MemoryGB) {
                $score += 14
            }
        }
        'Balanced' {
            $score += [math]::Abs($Candidate.VCpu - $CurrentSpec.VCpu) * 8
            $score += [math]::Abs($Candidate.MemoryGB - $CurrentSpec.MemoryGB)
        }
        'Overutilized' {
            if ($Candidate.VCpu -lt $CurrentSpec.VCpu) {
                $score += 60
            }

            if ($Candidate.MemoryGB -lt $CurrentSpec.MemoryGB) {
                $score += 20
            }
        }
        'Burstable Attention' {
            if ($Candidate.Family -eq 'B') {
                $score += 60
            }
        }
    }

    return [math]::Round($score, 2)
}

function Get-SkuRecommendationReason {
    param(
        $Candidate,
        $CurrentSpec,
        $Profile,
        $VmRecord
    )

    $sizeNote = if ($Candidate.VCpu -lt $CurrentSpec.VCpu) {
        'smaller capacity'
    }
    elseif ($Candidate.VCpu -gt $CurrentSpec.VCpu) {
        'larger capacity'
    }
    else {
        'similar capacity'
    }

    $familyNote = if ($Candidate.Family -eq $CurrentSpec.Family) {
        'same family preference'
    }
    else {
        'cross-family fallback'
    }

    switch ($VmRecord.UtilizationClass) {
        'Underutilized' {
            return "$sizeNote candidate aligned to low observed host utilization with $familyNote."
        }
        'Balanced' {
            return "$sizeNote candidate retained because current utilization looks steady and $familyNote."
        }
        'Overutilized' {
            return "$sizeNote candidate sized for higher sustained CPU demand with $familyNote."
        }
        'Burstable Attention' {
            return "$sizeNote candidate selected to reduce burst-credit dependence with $familyNote."
        }
        'Stopped' {
            return "$sizeNote candidate kept near the current size because the VM was stopped during the review window."
        }
        default {
            return "$sizeNote candidate kept near the current size because host data was limited."
        }
    }
}

function Get-TopSkuRecommendations {
    param(
        $VmRecord,
        $CurrentSpec,
        [System.Array]$SkuCatalog,
        [string]$OsType,
        [string]$LicenseType,
        [string]$Location,
        [hashtable]$PriceCache
    )

    if (-not $CurrentSpec -or -not $SkuCatalog -or $SkuCatalog.Count -eq 0) {
        return @()
    }

    $profile = Get-SkuRecommendationProfile -VmRecord $VmRecord -CurrentSpec $CurrentSpec
    $scoredCandidates = foreach ($candidate in $SkuCatalog) {
        if ($candidate.Family -notin @('B', 'D', 'E')) {
            continue
        }

        [pscustomobject]@{
            Candidate = $candidate
            FitScore = Get-CandidateFitScore -Candidate $candidate -CurrentSpec $CurrentSpec -Profile $profile -VmRecord $VmRecord
        }
    }

    $candidatePool = @($scoredCandidates | Sort-Object FitScore, @{ Expression = { $_.Candidate.VCpu }; Descending = $false }, @{ Expression = { $_.Candidate.MemoryGB }; Descending = $false }, @{ Expression = { $_.Candidate.Name }; Descending = $false } | Select-Object -First 12)

    $recommendations = foreach ($entry in $candidatePool) {
        $candidate = $entry.Candidate
        $candidatePricing = Get-PricingModel -ArmRegionName $Location -ArmSkuName $candidate.Name -OsType $OsType -LicenseType $LicenseType -Cache $PriceCache
        $pricingSummary = Get-BestMonthlyPricingSummary -Pricing $candidatePricing -BaselineMonthly ([double]$VmRecord.PaygMonthly)

        [pscustomobject]@{
            CandidateSku = $candidate.Name
            Family = $candidate.Family
            VCpu = $candidate.VCpu
            MemoryGB = [math]::Round([double]$candidate.MemoryGB, 1)
            FitScore = $entry.FitScore
            PaygMonthly = $candidatePricing.PaygMonthly
            Reservation1YearMonthly = $candidatePricing.Reservation1YearMonthly
            Reservation3YearMonthly = $candidatePricing.Reservation3YearMonthly
            OsLicenseMonthly = $candidatePricing.OsLicenseMonthly
            BestMonthlyOption = $pricingSummary.BestMonthlyOption
            BestMonthlyCost = $pricingSummary.BestMonthlyCost
            MonthlyDeltaFromCurrentPayg = $pricingSummary.BestMonthlySavings
            PricingStatus = $candidatePricing.PricingStatus
            Reason = Get-SkuRecommendationReason -Candidate $candidate -CurrentSpec $CurrentSpec -Profile $profile -VmRecord $VmRecord
            ProfileReason = $profile.ProfileReason
        }
    }

    return @($recommendations | Sort-Object FitScore, BestMonthlyCost, CandidateSku | Select-Object -First 3)
}

function Convert-ToCsvProjection {
    param([System.Array]$Results)

    $properties = @(
        'SubscriptionName',
        'SubscriptionId',
        'VMName',
        'ResourceGroup',
        'Location',
        'VmSize',
        'OsType',
        'LicenseType',
        'PowerState',
        'Zone',
        'UtilizationClass',
        'UtilizationReason',
        'Confidence',
        'CoveragePct',
        'MetricsStatus',
        'SampleCount',
        'CpuAveragePct',
        'CpuP95Pct',
        'CpuPeakPct',
        'CpuBusyPct',
        'NetworkAverageMBps',
        'NetworkPeakMBps',
        'DiskAverageMBps',
        'DiskPeakMBps',
        'CpuCreditsRemainingAverage',
        'AdvisorCount',
        'AdvisorCostCount',
        'AdvisorPerformanceCount',
        'AdvisorImpacts',
        'AdvisorSummary',
        'PaygMonthly',
        'PaygComputeMonthly',
        'Reservation1YearMonthly',
        'Reservation1YearComputeMonthly',
        'Reservation3YearMonthly',
        'Reservation3YearComputeMonthly',
        'OsLicenseMonthly',
        'OsLicenseStatus',
        'Savings1YearMonthly',
        'Savings3YearMonthly',
        'BestMonthlyOption',
        'PotentialBestMonthlySavings',
        'RecommendedSku',
        'RecommendedFamily',
        'RecommendedVCpu',
        'RecommendedMemoryGB',
        'RecommendedPaygMonthly',
        'RecommendedReservation1YearMonthly',
        'RecommendedReservation3YearMonthly',
        'RecommendedOsLicenseMonthly',
        'RecommendedBestMonthlyOption',
        'RecommendedMonthlyDeltaFromCurrentPayg',
        'RecommendedPricingStatus',
        'RecommendedReason',
        'PricingStatus',
        'CurrencyCode',
        'Recommendation',
        'Tags',
        'PortalUrl'
    )

    return @($Results | Select-Object -Property $properties)
}

function New-HtmlReport {
    param(
        [System.Array]$Results,
        [string]$OutputPath,
        [pscustomobject]$Meta
    )

    $reportJson = ConvertTo-Json -InputObject @($Results) -Depth 8 -Compress
    $metaJson = ConvertTo-Json -InputObject $Meta -Depth 5 -Compress

    $template = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>__DOCUMENT_TITLE__</title>
    <style>
        :root {
            --ink: #122230;
            --muted: #58707f;
            --line: rgba(18, 34, 48, 0.10);
            --card: rgba(255, 255, 255, 0.82);
            --card-strong: rgba(255, 255, 255, 0.94);
            --teal: #0f8b8d;
            --teal-deep: #0b5963;
            --amber: #d9913d;
            --rose: #cd5c5c;
            --olive: #5f7c3a;
            --shadow: 0 22px 60px rgba(19, 40, 56, 0.14);
            --radius: 20px;
        }

        * { box-sizing: border-box; }

        body {
            margin: 0;
            font-family: "Aptos", "Segoe UI Variable", "Segoe UI", sans-serif;
            color: var(--ink);
            background:
                radial-gradient(circle at top left, rgba(217, 145, 61, 0.16), transparent 28%),
                radial-gradient(circle at top right, rgba(15, 139, 141, 0.16), transparent 30%),
                linear-gradient(180deg, #f7f3ec 0%, #eef3f1 54%, #f5f8f7 100%);
            min-height: 100vh;
        }

        .shell {
            width: min(1600px, calc(100vw - 32px));
            margin: 24px auto 40px;
        }

        .hero {
            background: linear-gradient(135deg, rgba(15, 139, 141, 0.92), rgba(11, 89, 99, 0.9) 54%, rgba(217, 145, 61, 0.86));
            color: #f8fffd;
            border-radius: 28px;
            padding: 28px 30px;
            box-shadow: var(--shadow);
            position: relative;
            overflow: hidden;
        }

        .hero::after {
            content: "";
            position: absolute;
            inset: auto -80px -90px auto;
            width: 260px;
            height: 260px;
            border-radius: 50%;
            background: rgba(255, 255, 255, 0.10);
        }

        .hero-grid {
            display: grid;
            grid-template-columns: 2.2fr 1fr;
            gap: 22px;
            position: relative;
            z-index: 1;
        }

        .eyebrow {
            text-transform: uppercase;
            letter-spacing: 0.18em;
            font-size: 12px;
            opacity: 0.84;
            margin-bottom: 8px;
        }

        h1 {
            margin: 0;
            font-family: "Bahnschrift", "Aptos Display", "Aptos", sans-serif;
            font-size: clamp(2rem, 3vw, 3.2rem);
            line-height: 1.04;
        }

        .hero p {
            margin: 10px 0 0;
            max-width: 760px;
            font-size: 1rem;
            line-height: 1.55;
            opacity: 0.92;
        }

        .hero-meta {
            display: grid;
            gap: 12px;
            align-content: start;
        }

        .hero-chip {
            background: rgba(255, 255, 255, 0.12);
            border: 1px solid rgba(255, 255, 255, 0.18);
            border-radius: 18px;
            padding: 14px 16px;
            backdrop-filter: blur(12px);
        }

        .hero-chip strong {
            display: block;
            font-size: 1.1rem;
            margin-bottom: 4px;
        }

        .section {
            margin-top: 18px;
            background: var(--card);
            border: 1px solid rgba(255, 255, 255, 0.55);
            border-radius: var(--radius);
            box-shadow: var(--shadow);
            backdrop-filter: blur(14px);
        }

        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 14px;
            padding: 18px;
        }

        .stat-card {
            background: var(--card-strong);
            border: 1px solid var(--line);
            border-radius: 18px;
            padding: 18px;
            min-height: 128px;
            display: flex;
            flex-direction: column;
            justify-content: space-between;
        }

        .stat-label {
            font-size: 0.78rem;
            text-transform: uppercase;
            letter-spacing: 0.14em;
            color: var(--muted);
        }

        .stat-value {
            font-size: 2rem;
            font-weight: 700;
            line-height: 1;
            margin-top: 6px;
        }

        .stat-sub {
            font-size: 0.9rem;
            color: var(--muted);
        }

        .toolbar {
            display: grid;
            grid-template-columns: 2fr 1fr 1fr auto auto;
            gap: 12px;
            padding: 18px;
            align-items: center;
            border-top: 1px solid var(--line);
            border-bottom: 1px solid var(--line);
        }

        .field,
        .button {
            border-radius: 14px;
            border: 1px solid rgba(18, 34, 48, 0.14);
            background: rgba(255, 255, 255, 0.92);
            min-height: 46px;
            font: inherit;
            color: var(--ink);
        }

        .field {
            width: 100%;
            padding: 0 14px;
        }

        .button {
            padding: 0 16px;
            cursor: pointer;
        }

        .button.primary {
            background: linear-gradient(135deg, rgba(15, 139, 141, 0.96), rgba(11, 89, 99, 0.96));
            color: white;
            border-color: transparent;
        }

        .countline {
            padding: 0 18px 18px;
            color: var(--muted);
            font-size: 0.94rem;
        }

        .table-wrap {
            overflow-x: auto;
            padding: 0 18px 18px;
        }

        table {
            width: 100%;
            border-collapse: separate;
            border-spacing: 0;
            min-width: 1320px;
        }

        thead th {
            position: sticky;
            top: 0;
            z-index: 3;
            background: rgba(245, 249, 248, 0.98);
            color: var(--muted);
            text-align: left;
            font-size: 0.76rem;
            text-transform: uppercase;
            letter-spacing: 0.16em;
            padding: 14px 12px;
            border-bottom: 1px solid var(--line);
            cursor: pointer;
            user-select: none;
            white-space: nowrap;
        }

        tbody td {
            padding: 14px 12px;
            border-bottom: 1px solid rgba(18, 34, 48, 0.07);
            vertical-align: top;
            background: rgba(255, 255, 255, 0.72);
        }

        tbody tr.detail-row td {
            padding-top: 0;
            padding-bottom: 18px;
            background: rgba(255, 255, 255, 0.72);
        }

        tbody tr:hover td {
            background: rgba(255, 255, 255, 0.96);
        }

        tbody tr.detail-row:hover td {
            background: rgba(255, 255, 255, 0.96);
        }

        tbody tr.row-underutilized td:first-child { border-left: 5px solid #c58b2b; }
        tbody tr.row-balanced td:first-child { border-left: 5px solid #4f7f52; }
        tbody tr.row-overutilized td:first-child { border-left: 5px solid #c45b4d; }
        tbody tr.row-burstable-attention td:first-child { border-left: 5px solid #0f8b8d; }
        tbody tr.row-insufficient-data td:first-child,
        tbody tr.row-stopped td:first-child { border-left: 5px solid #8d99a6; }

        .vm-name { font-weight: 700; margin-bottom: 4px; }
        .subtle { color: var(--muted); font-size: 0.88rem; }

        .badge {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 6px 10px;
            border-radius: 999px;
            font-size: 0.78rem;
            font-weight: 700;
            white-space: nowrap;
        }

        .badge-underutilized { background: rgba(217, 145, 61, 0.18); color: #8f5b14; }
        .badge-balanced { background: rgba(95, 124, 58, 0.18); color: #466121; }
        .badge-overutilized { background: rgba(205, 92, 92, 0.18); color: #8d2f2f; }
        .badge-burstable-attention { background: rgba(15, 139, 141, 0.18); color: #0b5963; }
        .badge-insufficient-data,
        .badge-stopped { background: rgba(88, 112, 127, 0.18); color: #47606f; }

        .number {
            text-align: right;
            font-variant-numeric: tabular-nums;
            white-space: nowrap;
        }

        .comparison {
            display: grid;
            gap: 6px;
            min-width: 210px;
        }

        .price-row {
            display: grid;
            grid-template-columns: 56px 1fr auto;
            gap: 8px;
            align-items: center;
            font-size: 0.84rem;
        }

        .bar {
            position: relative;
            height: 10px;
            border-radius: 999px;
            background: rgba(18, 34, 48, 0.08);
            overflow: hidden;
        }

        .bar-fill {
            position: absolute;
            inset: 0 auto 0 0;
            border-radius: 999px;
        }

        .fill-payg { background: linear-gradient(90deg, #c45b4d, #e39677); }
        .fill-ri1 { background: linear-gradient(90deg, #d9913d, #f0bf77); }
        .fill-ri3 { background: linear-gradient(90deg, #0f8b8d, #4cc9c6); }

        details {
            border: 1px solid rgba(18, 34, 48, 0.08);
            border-radius: 14px;
            background: rgba(255, 255, 255, 0.7);
            padding: 10px 12px;
        }

        summary { cursor: pointer; font-weight: 600; color: var(--teal-deep); }
        .detail-list { margin: 10px 0 0; padding: 0; list-style: none; display: grid; gap: 10px; }
        .detail-card { border-left: 3px solid rgba(15, 139, 141, 0.34); padding-left: 10px; }
        .muted-note { padding: 14px 18px 20px; color: var(--muted); font-size: 0.88rem; line-height: 1.5; }
        .empty { padding: 40px 24px 54px; text-align: center; color: var(--muted); }
        a.portal-link { color: var(--teal-deep); text-decoration: none; font-weight: 600; }
        .mini-table { width: 100%; min-width: 0; border-collapse: collapse; margin-top: 8px; }
        .mini-table th,
        .mini-table td { padding: 8px 10px; border-bottom: 1px solid rgba(18, 34, 48, 0.08); font-size: 0.82rem; vertical-align: top; }
        .mini-table th { text-align: left; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; font-size: 0.7rem; }
        .mini-table td.number { text-align: right; }

        @media (max-width: 1120px) {
            .hero-grid,
            .toolbar { grid-template-columns: 1fr; }
            .shell { width: min(100vw - 20px, 1600px); margin-top: 10px; }
            .hero,
            .section { border-radius: 22px; }
        }
    </style>
</head>
<body>
    <div class="shell">
        <section class="hero">
            <div class="hero-grid">
                <div>
                    <div class="eyebrow" id="heroEyebrow">__HERO_EYEBROW__</div>
                    <h1 id="heroTitle">__HERO_TITLE__</h1>
                    <p id="heroDescription">__HERO_DESCRIPTION__</p>
                </div>
                <div class="hero-meta">
                    <div class="hero-chip">
                        <strong id="heroGenerated"></strong>
                        <span id="heroGeneratedLabel">__GENERATED_LABEL__</span>
                    </div>
                    <div class="hero-chip">
                        <strong id="heroWindow"></strong>
                        <span id="heroScope"></span>
                    </div>
                </div>
            </div>
        </section>

        <section class="section">
            <div class="stats" id="stats"></div>
            <div class="toolbar">
                <input id="searchInput" class="field" type="search" placeholder="Search VM, resource group, size, or recommendation text">
                <select id="utilizationFilter" class="field">
                    <option value="All">All utilization states</option>
                    <option value="Underutilized">Underutilized</option>
                    <option value="Balanced">Balanced</option>
                    <option value="Overutilized">Overutilized</option>
                    <option value="Burstable Attention">Burstable Attention</option>
                    <option value="Stopped">Stopped</option>
                    <option value="Insufficient Data">Insufficient Data</option>
                </select>
                <select id="advisorFilter" class="field">
                    <option value="All">All Advisor states</option>
                    <option value="HasAdvisor">Has Advisor recommendations</option>
                    <option value="NoAdvisor">No Advisor recommendations</option>
                </select>
                <button id="clearFiltersButton" class="button" type="button">Clear Filters</button>
                <button id="exportButton" class="button primary" type="button">Export Visible Rows</button>
            </div>
            <div class="countline"><span id="visibleCount"></span></div>
            <div class="table-wrap" id="tableMount"></div>
            <div class="muted-note" id="footerNote">__FOOTER_NOTE__</div>
        </section>
    </div>

    <script>
        const rawData = __REPORT_JSON__;
        const meta = __META_JSON__;
        const state = { search: "", utilization: "All", advisor: "All", sortKey: "PotentialBestMonthlySavings", sortDirection: "desc" };

        function escapeHtml(value) {
            const text = value === null || value === undefined ? "" : String(value);
            return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\"/g, "&quot;").replace(/'/g, "&#39;");
        }

        function formatMoney(value, currencyCode) {
            if (value === null || value === undefined || Number(value) <= 0) { return "n/a"; }
            return new Intl.NumberFormat("en-US", { style: "currency", currency: currencyCode || "USD", maximumFractionDigits: 2 }).format(Number(value));
        }

        function formatDeltaMoney(value, currencyCode) {
            if (value === null || value === undefined || Number.isNaN(Number(value))) { return "n/a"; }
            const amount = Number(value);
            const formatted = new Intl.NumberFormat("en-US", { style: "currency", currency: currencyCode || "USD", maximumFractionDigits: 2 }).format(Math.abs(amount));
            if (amount > 0) { return `+${formatted}`; }
            if (amount < 0) { return `-${formatted}`; }
            return formatted;
        }

        function formatNumber(value, digits = 2) {
            if (value === null || value === undefined || Number.isNaN(Number(value))) { return "n/a"; }
            return Number(value).toFixed(digits);
        }

        function badgeClass(value) {
            return "badge-" + String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
        }

        function rowClass(value) {
            return "row-" + String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
        }

        function sortValue(row, key) {
            const value = row[key];
            if (value === null || value === undefined) { return ""; }
            if (typeof value === "number") { return value; }
            const numeric = Number(value);
            return Number.isNaN(numeric) ? String(value).toLowerCase() : numeric;
        }

        function getFilteredRows() {
            return rawData.filter((row) => {
                const recommendationSkus = Array.isArray(row.SkuRecommendations) ? row.SkuRecommendations.map((item) => item.CandidateSku).join(" ") : "";
                const searchBlob = [row.VMName, row.ResourceGroup, row.Location, row.VmSize, row.UtilizationClass, row.AdvisorSummary, row.Recommendation, row.RecommendedSku, recommendationSkus, row.Tags].join(" ").toLowerCase();
                if (state.search && !searchBlob.includes(state.search)) { return false; }
                if (state.utilization !== "All" && row.UtilizationClass !== state.utilization) { return false; }
                if (state.advisor === "HasAdvisor" && Number(row.AdvisorCount) === 0) { return false; }
                if (state.advisor === "NoAdvisor" && Number(row.AdvisorCount) > 0) { return false; }
                return true;
            }).sort((left, right) => {
                const leftValue = sortValue(left, state.sortKey);
                const rightValue = sortValue(right, state.sortKey);
                if (leftValue < rightValue) { return state.sortDirection === "asc" ? -1 : 1; }
                if (leftValue > rightValue) { return state.sortDirection === "asc" ? 1 : -1; }
                return 0;
            });
        }

        function renderStats(rows) {
            const totalPayg = rows.reduce((sum, row) => sum + (Number(row.PaygMonthly) || 0), 0);
            const totalRi1 = rows.reduce((sum, row) => sum + (Number(row.Reservation1YearMonthly) || 0), 0);
            const totalRi3 = rows.reduce((sum, row) => sum + (Number(row.Reservation3YearMonthly) || 0), 0);
            const under = rows.filter((row) => row.UtilizationClass === "Underutilized").length;
            const over = rows.filter((row) => row.UtilizationClass === "Overutilized").length;
            const advisor = rows.filter((row) => Number(row.AdvisorCount) > 0).length;
            const cards = [
                { label: "Visible VMs", value: rows.length, sub: `${rawData.length} total in report` },
                { label: "Underutilized", value: under, sub: "Review rightsizing first" },
                { label: "Overutilized", value: over, sub: "Check capacity pressure" },
                { label: "Advisor Findings", value: advisor, sub: "Cost or Performance" },
                { label: "Current PAYG / Mo", value: formatMoney(totalPayg, meta.currencyCode), sub: "Compute with OS license when applicable" },
                { label: "1YR RI Est. / Mo", value: formatMoney(totalRi1, meta.currencyCode), sub: "Aggregate estimated monthly cost" },
                { label: "3YR RI Est. / Mo", value: formatMoney(totalRi3, meta.currencyCode), sub: "Aggregate estimated monthly cost" }
            ];
            document.getElementById("stats").innerHTML = cards.map((card) => `<article class="stat-card"><div><div class="stat-label">${escapeHtml(card.label)}</div><div class="stat-value">${escapeHtml(card.value)}</div></div><div class="stat-sub">${escapeHtml(card.sub)}</div></article>`).join("");
        }

        function buildComparisonCell(row) {
            const hasTargetPricing = Boolean(row.RecommendedSku) && (Number(row.RecommendedPaygMonthly) > 0 || Number(row.RecommendedReservation1YearMonthly) > 0 || Number(row.RecommendedReservation3YearMonthly) > 0);
            const payg = hasTargetPricing ? (Number(row.RecommendedPaygMonthly) || 0) : (Number(row.PaygMonthly) || 0);
            const ri1 = hasTargetPricing ? (Number(row.RecommendedReservation1YearMonthly) || 0) : (Number(row.Reservation1YearMonthly) || 0);
            const ri3 = hasTargetPricing ? (Number(row.RecommendedReservation3YearMonthly) || 0) : (Number(row.Reservation3YearMonthly) || 0);
            const maxValue = Math.max(payg, ri1, ri3, 1);
            const barWidth = (value) => `${Math.max((value / maxValue) * 100, value > 0 ? 6 : 0)}%`;
            const subtitle = hasTargetPricing ? `Target ${escapeHtml(row.RecommendedSku || '')} · Compute with OS license` : 'Current SKU · Compute with OS license';
            return `<div class="comparison"><div class="subtle">${subtitle}</div><div class="price-row"><span>PAYG</span><span class="bar"><span class="bar-fill fill-payg" style="width:${barWidth(payg)}"></span></span><strong>${escapeHtml(formatMoney(payg, row.CurrencyCode))}</strong></div><div class="price-row"><span>1YR</span><span class="bar"><span class="bar-fill fill-ri1" style="width:${barWidth(ri1)}"></span></span><strong>${escapeHtml(formatMoney(ri1, row.CurrencyCode))}</strong></div><div class="price-row"><span>3YR</span><span class="bar"><span class="bar-fill fill-ri3" style="width:${barWidth(ri3)}"></span></span><strong>${escapeHtml(formatMoney(ri3, row.CurrencyCode))}</strong></div></div>`;
        }

        function buildRecommendationTable(row) {
            const recommendations = Array.isArray(row.SkuRecommendations) ? row.SkuRecommendations : [];
            if (recommendations.length === 0) {
                return `<div class="subtle">No ranked B-, D-, or E-series recommendation candidates were available for this VM.</div>`;
            }

            return `<table class="mini-table"><thead><tr><th>Candidate</th><th>Specs</th><th>PAYG</th><th>1YR</th><th>3YR</th><th>Best</th><th>Savings vs Current</th><th>Reason</th></tr></thead><tbody>${recommendations.map((item) => `<tr><td><strong>${escapeHtml(item.CandidateSku)}</strong><div class="subtle">${escapeHtml(item.Family)}-series</div></td><td>${escapeHtml(String(item.VCpu))} vCPU / ${escapeHtml(formatNumber(item.MemoryGB, 1))} GiB</td><td class="number">${escapeHtml(formatMoney(item.PaygMonthly, row.CurrencyCode))}</td><td class="number">${escapeHtml(formatMoney(item.Reservation1YearMonthly, row.CurrencyCode))}</td><td class="number">${escapeHtml(formatMoney(item.Reservation3YearMonthly, row.CurrencyCode))}</td><td><strong>${escapeHtml(item.BestMonthlyOption || 'PAYG')}</strong><div class="subtle">${escapeHtml(item.PricingStatus || '')}</div></td><td class="number">${escapeHtml(formatDeltaMoney(item.MonthlyDeltaFromCurrentPayg, row.CurrencyCode))}</td><td>${escapeHtml(item.Reason || '')}</td></tr>`).join("")}</tbody></table>`;
        }

        function renderTable(rows) {
            const mount = document.getElementById("tableMount");
            document.getElementById("visibleCount").textContent = `${rows.length} of ${rawData.length} VMs visible`;
            if (rows.length === 0) { mount.innerHTML = `<div class="empty">No VMs matched the active filters.</div>`; return; }

            const columns = [["VMName", "VM"], ["UtilizationClass", "Utilization"], ["RecommendedSku", "Target SKU"], ["AdvisorCount", "Advisor"], ["PotentialBestMonthlySavings", "Best Savings / Mo"], ["RecommendedPaygMonthly", "Cost Comparison"], ["RecommendedBestMonthlyOption", "Best Option"]];
            mount.innerHTML = `<table><thead><tr>${columns.map(([key, label]) => `<th data-key="${key}">${escapeHtml(label)}${state.sortKey === key ? (state.sortDirection === "asc" ? " ▲" : " ▼") : ""}</th>`).join("")}</tr></thead><tbody>${rows.map((row) => {
                const advisorDetails = Array.isArray(row.AdvisorDetails) ? row.AdvisorDetails : [];
                const advisorMarkup = advisorDetails.length > 0 ? `<ul class="detail-list">${advisorDetails.map((item) => `<li class="detail-card"><strong>${escapeHtml(item.Category)} · ${escapeHtml(item.Impact || "Unknown")}</strong><br><span>${escapeHtml(item.Problem || "No problem text provided.")}</span>${item.Solution ? `<div class="subtle">${escapeHtml(item.Solution)}</div>` : ""}</li>`).join("")}</ul>` : `<div class="subtle">No Cost or Performance Advisor recommendations were returned for this VM.</div>`;
                const recommendationMarkup = buildRecommendationTable(row);
                const dataSummary = `CPU Avg ${formatNumber(row.CpuAveragePct, 2)}% · CPU P95 ${formatNumber(row.CpuP95Pct, 2)}% · CPU Peak ${formatNumber(row.CpuPeakPct, 2)}% · Busy ${formatNumber(row.CpuBusyPct, 2)}% · Net ${formatNumber(row.NetworkAverageMBps, 3)} MB/s avg · Disk ${formatNumber(row.DiskAverageMBps, 3)} MB/s avg`;
                const detailBlock = `<details><summary>Open rationale</summary><div style="margin-top:10px; display:grid; gap:12px;"><div><strong>Data</strong><div class="subtle">${escapeHtml(dataSummary)}</div></div><div><strong>Assessment</strong><div class="subtle">${escapeHtml(row.UtilizationReason || "")}</div></div><div><strong>Recommendation</strong><div class="subtle">${escapeHtml(row.Recommendation || "")}</div></div><div><strong>Top SKU Candidates</strong><div class="subtle" style="margin-bottom:8px;">${escapeHtml(row.RecommendedReason || '')}</div>${recommendationMarkup}</div><div><strong>Advisor</strong>${advisorMarkup}</div><div class="subtle">Coverage ${escapeHtml(formatNumber(row.CoveragePct, 1))}% · Confidence ${escapeHtml(row.Confidence || "")}${row.RecommendedPricingStatus ? ` · Target pricing ${escapeHtml(row.RecommendedPricingStatus)}` : row.PricingStatus ? ` · Pricing ${escapeHtml(row.PricingStatus)}` : ""}</div></div></details>`;
                return `<tr class="${rowClass(row.UtilizationClass)}"><td><div class="vm-name">${escapeHtml(row.VMName)}</div><div class="subtle">${escapeHtml(row.ResourceGroup)} · ${escapeHtml(row.Location)} · ${escapeHtml(row.VmSize)}</div><div class="subtle">${escapeHtml(row.SubscriptionName)}${row.PortalUrl ? ` · <a class="portal-link" href="${escapeHtml(row.PortalUrl)}" target="_blank" rel="noreferrer">Portal</a>` : ""}</div></td><td><span class="badge ${badgeClass(row.UtilizationClass)}">${escapeHtml(row.UtilizationClass)}</span></td><td><div><strong>${escapeHtml(row.RecommendedSku || 'n/a')}</strong></div><div class="subtle">${escapeHtml(row.RecommendedFamily || '')}${row.RecommendedVCpu ? ` · ${escapeHtml(String(row.RecommendedVCpu))} vCPU / ${escapeHtml(formatNumber(row.RecommendedMemoryGB, 1))} GiB` : ''}</div></td><td><div><strong>${escapeHtml(String(row.AdvisorCount || 0))}</strong></div><div class="subtle">${escapeHtml(row.AdvisorSummary || "No findings")}</div></td><td class="number">${escapeHtml(formatMoney(row.PotentialBestMonthlySavings, row.CurrencyCode))}</td><td>${buildComparisonCell(row)}</td><td><div><strong>${escapeHtml(row.RecommendedBestMonthlyOption || row.BestMonthlyOption || "PAYG")}</strong></div><div class="subtle">${escapeHtml(row.RecommendedPricingStatus || row.PricingStatus || "")}</div></td></tr><tr class="detail-row ${rowClass(row.UtilizationClass)}"><td colspan="${columns.length}">${detailBlock}</td></tr>`;
            }).join("")}</tbody></table>`;

            mount.querySelectorAll("th[data-key]").forEach((header) => {
                header.addEventListener("click", () => {
                    const nextKey = header.getAttribute("data-key");
                    if (state.sortKey === nextKey) { state.sortDirection = state.sortDirection === "asc" ? "desc" : "asc"; }
                    else { state.sortKey = nextKey; state.sortDirection = nextKey === "VMName" ? "asc" : "desc"; }
                    render();
                });
            });
        }

        function exportVisibleRows(rows) {
            const headers = ["SubscriptionName", "VMName", "ResourceGroup", "Location", "VmSize", "RecommendedSku", "RecommendedBestMonthlyOption", "RecommendedMonthlyDeltaFromCurrentPayg", "UtilizationClass", "AdvisorCount", "AdvisorSummary", "RecommendedPaygMonthly", "RecommendedReservation1YearMonthly", "RecommendedReservation3YearMonthly", "PotentialBestMonthlySavings", "Recommendation"];
            const csv = [headers.join(","), ...rows.map((row) => headers.map((header) => { const value = row[header] === null || row[header] === undefined ? "" : String(row[header]); return `"${value.replace(/"/g, '""')}"`; }).join(","))].join("\n");
            const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
            const url = URL.createObjectURL(blob);
            const anchor = document.createElement("a");
            anchor.href = url;
            anchor.download = `${meta.exportFilePrefix || "vm-assessment-visible"}-${new Date().toISOString().slice(0, 10)}.csv`;
            anchor.click();
            URL.revokeObjectURL(url);
        }

        function render() {
            const rows = getFilteredRows();
            renderStats(rows);
            renderTable(rows);
        }

        document.getElementById("searchInput").addEventListener("input", (event) => { state.search = event.target.value.trim().toLowerCase(); render(); });
        document.getElementById("utilizationFilter").addEventListener("change", (event) => { state.utilization = event.target.value; render(); });
        document.getElementById("advisorFilter").addEventListener("change", (event) => { state.advisor = event.target.value; render(); });
        document.getElementById("clearFiltersButton").addEventListener("click", () => {
            state.search = "";
            state.utilization = "All";
            state.advisor = "All";
            document.getElementById("searchInput").value = "";
            document.getElementById("utilizationFilter").value = "All";
            document.getElementById("advisorFilter").value = "All";
            render();
        });
        document.getElementById("exportButton").addEventListener("click", () => { exportVisibleRows(getFilteredRows()); });
        document.getElementById("heroGenerated").textContent = meta.generatedOn;
        document.getElementById("heroWindow").textContent = `${meta.daysToInspect} day review window`;
        document.getElementById("heroScope").textContent = meta.scopeText;
        render();
    </script>
</body>
</html>
'@

    $html = $template.Replace("__REPORT_JSON__", $reportJson).Replace("__META_JSON__", $metaJson)
    $html = $html.Replace("__DOCUMENT_TITLE__", [string]$Meta.DocumentTitle)
    $html = $html.Replace("__HERO_EYEBROW__", [string]$Meta.HeroEyebrow)
    $html = $html.Replace("__HERO_TITLE__", [string]$Meta.HeroTitle)
    $html = $html.Replace("__HERO_DESCRIPTION__", [string]$Meta.HeroDescription)
    $html = $html.Replace("__GENERATED_LABEL__", [string]$Meta.GeneratedLabel)
    $html = $html.Replace("__FOOTER_NOTE__", [string]$Meta.FooterNote)
    $html | Set-Content -Path $OutputPath -Encoding UTF8
}

#endregion

#region Initialization

$scriptStartTime = Get-Date
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $defaultJsoncConfigPath = Join-Path $scriptDir 'azure-vm-assessment.config.jsonc'
    if (Test-Path -LiteralPath $defaultJsoncConfigPath) {
        $ConfigPath = $defaultJsoncConfigPath
    }
}

$resolvedConfigPath = Resolve-ConfigPath -Path $ConfigPath -BaseDirectory (Get-Location).Path
$configSettings = Import-AssessmentConfig -Path $resolvedConfigPath

if (-not $PSBoundParameters.ContainsKey('DaysToInspect') -and $configSettings.ContainsKey('DaysToInspect')) {
    $DaysToInspect = [int]$configSettings['DaysToInspect']
}

if (-not $PSBoundParameters.ContainsKey('SubscriptionId') -and $configSettings.ContainsKey('SubscriptionId')) {
    $SubscriptionId = @(ConvertTo-Array -Value $configSettings['SubscriptionId'])
}

if (-not $PSBoundParameters.ContainsKey('OutputPrefix') -and $configSettings.ContainsKey('OutputPrefix')) {
    $OutputPrefix = [string]$configSettings['OutputPrefix']
}

$reportSettings = @{}
if ($configSettings.ContainsKey('Report')) {
    $reportSettings = $configSettings['Report']
}

if (-not $PSBoundParameters.ContainsKey('VMName') -and $configSettings.ContainsKey('VMName')) {
    $VMName = @(ConvertTo-Array -Value $configSettings['VMName'])
}

$SubscriptionId = @(Normalize-StringList -Value $SubscriptionId)
$VMName = @(Normalize-StringList -Value $VMName)

$shouldRefreshAdvisor = if ($PSBoundParameters.ContainsKey('RefreshAdvisor')) {
    $RefreshAdvisor.IsPresent
}
elseif ($configSettings.ContainsKey('RefreshAdvisor')) {
    ConvertTo-Boolean -Value $configSettings['RefreshAdvisor']
}
else {
    $false
}

if (-not $PSBoundParameters.ContainsKey('UnderutilizedCpuAverageThreshold') -and $configSettings.ContainsKey('UnderutilizedCpuAverageThreshold')) {
    $UnderutilizedCpuAverageThreshold = [double]$configSettings['UnderutilizedCpuAverageThreshold']
}

if (-not $PSBoundParameters.ContainsKey('UnderutilizedCpuP95Threshold') -and $configSettings.ContainsKey('UnderutilizedCpuP95Threshold')) {
    $UnderutilizedCpuP95Threshold = [double]$configSettings['UnderutilizedCpuP95Threshold']
}

if (-not $PSBoundParameters.ContainsKey('OverutilizedCpuAverageThreshold') -and $configSettings.ContainsKey('OverutilizedCpuAverageThreshold')) {
    $OverutilizedCpuAverageThreshold = [double]$configSettings['OverutilizedCpuAverageThreshold']
}

if (-not $PSBoundParameters.ContainsKey('OverutilizedCpuP95Threshold') -and $configSettings.ContainsKey('OverutilizedCpuP95Threshold')) {
    $OverutilizedCpuP95Threshold = [double]$configSettings['OverutilizedCpuP95Threshold']
}

if (-not $PSBoundParameters.ContainsKey('LowNetworkAverageThresholdMBps') -and $configSettings.ContainsKey('LowNetworkAverageThresholdMBps')) {
    $LowNetworkAverageThresholdMBps = [double]$configSettings['LowNetworkAverageThresholdMBps']
}

if (-not $PSBoundParameters.ContainsKey('LowDiskAverageThresholdMBps') -and $configSettings.ContainsKey('LowDiskAverageThresholdMBps')) {
    $LowDiskAverageThresholdMBps = [double]$configSettings['LowDiskAverageThresholdMBps']
}

if (-not $PSBoundParameters.ContainsKey('BurstableLowCreditsThreshold') -and $configSettings.ContainsKey('BurstableLowCreditsThreshold')) {
    $BurstableLowCreditsThreshold = [double]$configSettings['BurstableLowCreditsThreshold']
}

if (-not $PSBoundParameters.ContainsKey('MinimumSamplesForClassification') -and $configSettings.ContainsKey('MinimumSamplesForClassification')) {
    $MinimumSamplesForClassification = [int]$configSettings['MinimumSamplesForClassification']
}

$generateJson = if ($reportSettings.ContainsKey('GenerateJson')) { ConvertTo-Boolean -Value $reportSettings['GenerateJson'] } else { $true }
$generateCsv = if ($reportSettings.ContainsKey('GenerateCsv')) { ConvertTo-Boolean -Value $reportSettings['GenerateCsv'] } else { $true }
$generateHtml = if ($reportSettings.ContainsKey('GenerateHtml')) { ConvertTo-Boolean -Value $reportSettings['GenerateHtml'] } else { $true }

if (-not ($generateJson -or $generateCsv -or $generateHtml)) {
    throw "Report configuration disabled all outputs. Enable at least one of Report.GenerateJson, Report.GenerateCsv, or Report.GenerateHtml."
}

$outputBaseDirectory = if ($reportSettings.ContainsKey('OutputDirectory')) {
    Resolve-ConfigPath -Path ([string]$reportSettings['OutputDirectory']) -BaseDirectory $scriptDir
}
else {
    $scriptDir
}

if (-not [string]::IsNullOrWhiteSpace($outputBaseDirectory) -and -not (Test-Path -LiteralPath $outputBaseDirectory)) {
    [void](New-Item -ItemType Directory -Path $outputBaseDirectory -Force)
}

$reportDocumentTitle = if ($reportSettings.ContainsKey('DocumentTitle')) { [string]$reportSettings['DocumentTitle'] } else { 'Azure VM Assessment Report' }
$reportHeroEyebrow = if ($reportSettings.ContainsKey('HeroEyebrow')) { [string]$reportSettings['HeroEyebrow'] } else { 'Azure Virtual Machine Assessment' }
$reportHeroTitle = if ($reportSettings.ContainsKey('HeroTitle')) { [string]$reportSettings['HeroTitle'] } else { 'Advisor, utilization, and compute commitment analysis in one view.' }
$reportHeroDescription = if ($reportSettings.ContainsKey('HeroDescription')) { [string]$reportSettings['HeroDescription'] } else { 'This report combines Azure Advisor Cost and Performance guidance with Azure Monitor host metrics and retail compute pricing. Reserved instance values are shown as monthly equivalents for the current VM size.' }
$reportGeneratedLabel = if ($reportSettings.ContainsKey('GeneratedLabel')) { [string]$reportSettings['GeneratedLabel'] } else { 'Generated from the local assessment script.' }
$reportFooterNote = if ($reportSettings.ContainsKey('FooterNote')) { [string]$reportSettings['FooterNote'] } else { 'Pricing reflects compute with OS license when applicable for the matched Azure VM retail meter. Windows OS license is excluded when the VM license state indicates a benefit such as Azure Hybrid Benefit. Attached disks, savings plans, and guest memory were not included in this version.' }
$reportScopeTextOverride = if ($reportSettings.ContainsKey('ScopeTextOverride')) { [string]$reportSettings['ScopeTextOverride'] } else { '' }
$reportExportFilePrefix = if ($reportSettings.ContainsKey('VisibleRowsExportPrefix')) { [string]$reportSettings['VisibleRowsExportPrefix'] } else { 'vm-assessment-visible' }

if (-not $SubscriptionId -or $SubscriptionId.Count -eq 0) {
    $currentContext = Invoke-AzCliJson -Arguments @("account", "show")
    $SubscriptionId = @([string]$currentContext.id)
}

$analysisWindowEnd = Get-Date
$analysisWindowStart = $analysisWindowEnd.AddDays(-$DaysToInspect)
$intervalConfig = Get-IntervalConfig -Days $DaysToInspect
$priceCache = @{}
$skuCatalogCache = @{}
$allResults = New-Object System.Collections.Generic.List[object]

Write-Host "Review window: $DaysToInspect day(s) using interval $($intervalConfig.Interval)" -ForegroundColor Cyan
Write-Host "Subscriptions: $($SubscriptionId -join ', ')" -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config file: $resolvedConfigPath" -ForegroundColor Cyan
}
Write-Host "Output directory: $outputBaseDirectory" -ForegroundColor Cyan
Write-Host ""

#endregion

#region Inventory and Analysis

foreach ($subscription in $SubscriptionId) {
    $subscriptionContext = Invoke-AzCliJson -Arguments @("account", "show", "--subscription", $subscription)
    $subscriptionName = [string]$subscriptionContext.name

    Write-Host "Processing subscription: $subscriptionName ($subscription)" -ForegroundColor Yellow

    $vmQuery = "[].{id:id,name:name,resourceGroup:resourceGroup,location:location,vmSize:hardwareProfile.vmSize,osType:storageProfile.osDisk.osType,licenseType:licenseType,zones:zones,tags:tags,powerState:powerState,provisioningState:provisioningState}"
    $vms = Invoke-AzCliJson -Arguments @("vm", "list", "-d", "--subscription", $subscription, "--query", $vmQuery)
    $vms = @($vms)

    if ($VMName -and $VMName.Count -gt 0) {
        $requested = @($VMName | ForEach-Object { $_.ToLowerInvariant() })
        $vms = @($vms | Where-Object { $requested -contains ([string]$_.name).ToLowerInvariant() })
    }

    Write-Host "  Found $($vms.Count) VM(s) after filtering" -ForegroundColor Green

    $advisorMap = Get-AdvisorRecommendations -Subscription $subscription -ShouldRefresh:$shouldRefreshAdvisor
    Write-Host "  Advisor VM recommendation targets: $($advisorMap.Keys.Count)" -ForegroundColor Green

    foreach ($vm in $vms) {
        try {
            $vmId = [string]$vm.id
            $normalizedVmId = $vmId.ToLowerInvariant()
            $vmSize = [string]$vm.vmSize
            $osType = if ([string]::IsNullOrWhiteSpace([string]$vm.osType)) { "Unknown" } else { [string]$vm.osType }
            $powerState = if ([string]::IsNullOrWhiteSpace([string]$vm.powerState)) { "Unknown" } else { [string]$vm.powerState }
            $isBurstable = $vmSize -match "^Standard_B"

            Write-Host "    Analyzing $($vm.name) ($vmSize, $osType)" -ForegroundColor DarkCyan

            $telemetry = Get-VmTelemetry -ResourceId $vmId -IntervalConfig $intervalConfig -AnalysisWindowStart $analysisWindowStart -AnalysisWindowEnd $analysisWindowEnd -IsBurstable:$isBurstable
            $utilization = Get-UtilizationAssessment -VmRecord ([pscustomobject]@{ PowerState = $powerState; IsBurstable = $isBurstable }) -Telemetry $telemetry -IntervalConfig $intervalConfig -AnalysisWindowStart $analysisWindowStart -AnalysisWindowEnd $analysisWindowEnd
            $regionSkuCatalog = Get-RegionVmSkuCatalog -Location ([string]$vm.location) -Cache $skuCatalogCache
            $currentSkuSpec = @($regionSkuCatalog | Where-Object { $_.Name -eq $vmSize } | Select-Object -First 1)
            $pricing = Get-PricingModel -ArmRegionName ([string]$vm.location) -ArmSkuName $vmSize -OsType $osType -LicenseType ([string]$vm.licenseType) -Cache $priceCache
            $pricingSummary = Get-BestMonthlyPricingSummary -Pricing $pricing -BaselineMonthly ([double]$pricing.PaygMonthly)
            $skuRecommendations = if ($currentSkuSpec.Count -gt 0) {
                Get-TopSkuRecommendations -VmRecord ([pscustomobject]@{
                        UtilizationClass = $utilization.UtilizationClass
                        CpuAveragePct = $telemetry.CpuAveragePct
                        CpuP95Pct = $telemetry.CpuP95Pct
                        CpuPeakPct = $telemetry.CpuPeakPct
                        NetworkAverageMBps = $telemetry.NetworkAverageMBps
                        DiskAverageMBps = $telemetry.DiskAverageMBps
                        PaygMonthly = $pricing.PaygMonthly
                    }) -CurrentSpec $currentSkuSpec[0] -SkuCatalog $regionSkuCatalog -OsType $osType -LicenseType ([string]$vm.licenseType) -Location ([string]$vm.location) -PriceCache $priceCache
            }
            else {
                @()
            }
            $bestCandidate = @($skuRecommendations | Select-Object -First 1)
            $advisorDetails = @()
            if ($advisorMap.ContainsKey($normalizedVmId)) {
                $advisorDetails = $advisorMap[$normalizedVmId].ToArray()
            }

            $advisorCostCount = @($advisorDetails | Where-Object { $_.Category -eq "Cost" }).Count
            $advisorPerformanceCount = @($advisorDetails | Where-Object { $_.Category -eq "Performance" }).Count
            $advisorImpacts = (@($advisorDetails | ForEach-Object { $_.Impact } | Where-Object { $_ } | Select-Object -Unique) -join ", ")
            $advisorSummary = if ($advisorDetails.Count -gt 0) { (@($advisorDetails | ForEach-Object { $_.Problem } | Where-Object { $_ } | Select-Object -First 3) -join " | ") } else { "" }

            $savings1 = if ($pricing.PaygMonthly -gt 0 -and $pricing.Reservation1YearMonthly -gt 0) { [math]::Round($pricing.PaygMonthly - $pricing.Reservation1YearMonthly, 2) } else { 0 }
            $savings3 = if ($pricing.PaygMonthly -gt 0 -and $pricing.Reservation3YearMonthly -gt 0) { [math]::Round($pricing.PaygMonthly - $pricing.Reservation3YearMonthly, 2) } else { 0 }

            $record = [pscustomobject]@{
                SubscriptionName = $subscriptionName
                SubscriptionId = $subscription
                VMName = [string]$vm.name
                ResourceGroup = [string]$vm.resourceGroup
                Location = [string]$vm.location
                VmSize = $vmSize
                OsType = $osType
                LicenseType = [string]$vm.licenseType
                PowerState = $powerState
                Zone = Get-PrimaryZone -Zones $vm.zones
                Tags = Join-TagSummary -Tags $vm.tags
                IsBurstable = $isBurstable
                MetricsStatus = $telemetry.MetricsStatus
                SampleCount = $telemetry.SampleCount
                CpuAveragePct = $telemetry.CpuAveragePct
                CpuP95Pct = $telemetry.CpuP95Pct
                CpuPeakPct = $telemetry.CpuPeakPct
                CpuBusyPct = $telemetry.CpuBusyPct
                NetworkAverageMBps = $telemetry.NetworkAverageMBps
                NetworkPeakMBps = $telemetry.NetworkPeakMBps
                DiskAverageMBps = $telemetry.DiskAverageMBps
                DiskPeakMBps = $telemetry.DiskPeakMBps
                CpuCreditsRemainingAverage = $telemetry.CpuCreditsRemainingAverage
                CpuCreditsConsumedAverage = $telemetry.CpuCreditsConsumedAverage
                UtilizationClass = $utilization.UtilizationClass
                UtilizationReason = $utilization.UtilizationReason
                CoveragePct = $utilization.CoveragePct
                Confidence = $utilization.Confidence
                AdvisorCount = $advisorDetails.Count
                AdvisorCostCount = $advisorCostCount
                AdvisorPerformanceCount = $advisorPerformanceCount
                AdvisorImpacts = $advisorImpacts
                AdvisorSummary = $advisorSummary
                AdvisorDetails = $advisorDetails
                CurrencyCode = $pricing.CurrencyCode
                PaygHourly = $pricing.PaygHourly
                PaygMonthly = $pricing.PaygMonthly
                PaygComputeMonthly = $pricing.PaygComputeMonthly
                Reservation1YearTotal = $pricing.Reservation1YearTotal
                Reservation1YearMonthly = $pricing.Reservation1YearMonthly
                Reservation1YearComputeMonthly = $pricing.Reservation1YearComputeMonthly
                Reservation3YearTotal = $pricing.Reservation3YearTotal
                Reservation3YearMonthly = $pricing.Reservation3YearMonthly
                Reservation3YearComputeMonthly = $pricing.Reservation3YearComputeMonthly
                IncludeOsLicense = $pricing.IncludeOsLicense
                LicenseBenefitApplied = $pricing.LicenseBenefitApplied
                OsLicenseMonthly = $pricing.OsLicenseMonthly
                OsLicenseStatus = $pricing.OsLicenseStatus
                Savings1YearMonthly = $savings1
                Savings3YearMonthly = $savings3
                BestMonthlyOption = $pricingSummary.BestMonthlyOption
                PotentialBestMonthlySavings = [math]::Round([math]::Max($savings1, $savings3), 2)
                PricingStatus = $pricing.PricingStatus
                PaygMatchType = $pricing.PaygMatchType
                Reservation1YearMatchType = $pricing.Reservation1YearMatchType
                Reservation3YearMatchType = $pricing.Reservation3YearMatchType
                RecommendedSku = if ($bestCandidate.Count -gt 0) { [string]$bestCandidate[0].CandidateSku } else { '' }
                RecommendedFamily = if ($bestCandidate.Count -gt 0) { [string]$bestCandidate[0].Family } else { '' }
                RecommendedVCpu = if ($bestCandidate.Count -gt 0) { [int]$bestCandidate[0].VCpu } else { 0 }
                RecommendedMemoryGB = if ($bestCandidate.Count -gt 0) { [double]$bestCandidate[0].MemoryGB } else { 0 }
                RecommendedPaygMonthly = if ($bestCandidate.Count -gt 0) { [double]$bestCandidate[0].PaygMonthly } else { 0 }
                RecommendedReservation1YearMonthly = if ($bestCandidate.Count -gt 0) { [double]$bestCandidate[0].Reservation1YearMonthly } else { 0 }
                RecommendedReservation3YearMonthly = if ($bestCandidate.Count -gt 0) { [double]$bestCandidate[0].Reservation3YearMonthly } else { 0 }
                RecommendedOsLicenseMonthly = if ($bestCandidate.Count -gt 0) { [double]$bestCandidate[0].OsLicenseMonthly } else { 0 }
                RecommendedBestMonthlyOption = if ($bestCandidate.Count -gt 0) { [string]$bestCandidate[0].BestMonthlyOption } else { '' }
                RecommendedMonthlyDeltaFromCurrentPayg = if ($bestCandidate.Count -gt 0) { [double]$bestCandidate[0].MonthlyDeltaFromCurrentPayg } else { 0 }
                RecommendedPricingStatus = if ($bestCandidate.Count -gt 0) { [string]$bestCandidate[0].PricingStatus } else { '' }
                RecommendedReason = if ($bestCandidate.Count -gt 0) { [string]$bestCandidate[0].ProfileReason } else { '' }
                SkuRecommendations = $skuRecommendations
                PortalUrl = "https://portal.azure.com/#resource$vmId/overview"
                Recommendation = ""
            }

            $record.Recommendation = Get-RecommendationText -Record $record
            if ($bestCandidate.Count -gt 0) {
                $record.Recommendation = ($record.Recommendation + " Recommended target SKU shortlist is led by $($bestCandidate[0].CandidateSku), priced as $($bestCandidate[0].BestMonthlyOption) with a monthly delta of $([math]::Round([double]$bestCandidate[0].MonthlyDeltaFromCurrentPayg, 2)) against current PAYG.").Trim()
            }
            $allResults.Add($record)
        }
        catch {
            $positionMessage = if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) { $_.InvocationInfo.PositionMessage.Trim() } else { "Position unavailable" }
            Write-Warning "VM analysis failed for $($vm.name): $($_.Exception.Message) | $positionMessage"
        }
    }

    Write-Host ""
}

#endregion

#region Output

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonPath = Join-Path $outputBaseDirectory "$OutputPrefix-$timestamp.json"
$csvPath = Join-Path $outputBaseDirectory "$OutputPrefix-$timestamp.csv"
$htmlPath = Join-Path $outputBaseDirectory "$OutputPrefix-$timestamp.html"

$resultArray = $allResults.ToArray()
$csvProjection = Convert-ToCsvProjection -Results $resultArray

if ($generateJson) {
    $resultArray | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
}

if ($generateCsv) {
    $csvProjection | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
}

$reportCurrency = if ($resultArray.Count -gt 0 -and $resultArray[0].CurrencyCode) { $resultArray[0].CurrencyCode } else { "USD" }
$scopeText = if (-not [string]::IsNullOrWhiteSpace($reportScopeTextOverride)) {
    $reportScopeTextOverride
}
elseif ($VMName -and $VMName.Count -gt 0) {
    "Scope filtered to $($VMName.Count) requested VM name(s) across $($SubscriptionId.Count) subscription(s)."
}
else {
    "Scope includes $($SubscriptionId.Count) subscription(s) using the current Azure CLI context."
}

if ($generateHtml) {
    New-HtmlReport -Results $resultArray -OutputPath $htmlPath -Meta ([pscustomobject]@{
            generatedOn = (Get-Date -Format "MMMM dd, yyyy 'at' HH:mm:ss")
            daysToInspect = $DaysToInspect
            scopeText = $scopeText
            currencyCode = $reportCurrency
            DocumentTitle = $reportDocumentTitle
            HeroEyebrow = $reportHeroEyebrow
            HeroTitle = $reportHeroTitle
            HeroDescription = $reportHeroDescription
            GeneratedLabel = $reportGeneratedLabel
            FooterNote = $reportFooterNote
            ExportFilePrefix = $reportExportFilePrefix
        })
}

$underutilized = @($resultArray | Where-Object { $_.UtilizationClass -eq "Underutilized" }).Count
$overutilized = @($resultArray | Where-Object { $_.UtilizationClass -eq "Overutilized" }).Count
$advisorBacked = @($resultArray | Where-Object { $_.AdvisorCount -gt 0 }).Count
$paygMeasure = $resultArray | Measure-Object -Property PaygMonthly -Sum
$ri1Measure = $resultArray | Measure-Object -Property Reservation1YearMonthly -Sum
$ri3Measure = $resultArray | Measure-Object -Property Reservation3YearMonthly -Sum
$paygTotal = 0
$ri1Total = 0
$ri3Total = 0
if ($paygMeasure -and $null -ne $paygMeasure.Sum) {
    $paygTotal = $paygMeasure.Sum
}
if ($ri1Measure -and $null -ne $ri1Measure.Sum) {
    $ri1Total = $ri1Measure.Sum
}
if ($ri3Measure -and $null -ne $ri3Measure.Sum) {
    $ri3Total = $ri3Measure.Sum
}
$estimatedPayg = [math]::Round($paygTotal, 2)
$estimatedRi1 = [math]::Round($ri1Total, 2)
$estimatedRi3 = [math]::Round($ri3Total, 2)

Write-Host "Assessment summary" -ForegroundColor Cyan
Write-Host "  Total VMs assessed:       $($resultArray.Count)" -ForegroundColor White
Write-Host "  Underutilized:            $underutilized" -ForegroundColor Yellow
Write-Host "  Overutilized:             $overutilized" -ForegroundColor Red
Write-Host "  With Advisor findings:    $advisorBacked" -ForegroundColor Green
Write-Host "  PAYG est. per month:      $reportCurrency $estimatedPayg" -ForegroundColor White
Write-Host "  1YR RI est. per month:    $reportCurrency $estimatedRi1" -ForegroundColor White
Write-Host "  3YR RI est. per month:    $reportCurrency $estimatedRi3" -ForegroundColor White
Write-Host ""
Write-Host "Outputs" -ForegroundColor Cyan
if ($generateJson) {
    Write-Host "  JSON: $jsonPath" -ForegroundColor Green
}
if ($generateCsv) {
    Write-Host "  CSV:  $csvPath" -ForegroundColor Green
}
if ($generateHtml) {
    Write-Host "  HTML: $htmlPath" -ForegroundColor Green
}
Write-Host ""

$elapsed = (Get-Date) - $scriptStartTime
if ($elapsed.TotalMinutes -ge 1) {
    $elapsedText = "{0:N0} minutes {1:N0} seconds" -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
}
else {
    $elapsedText = "{0:N1} seconds" -f $elapsed.TotalSeconds
}

Write-Host "Execution time: $elapsedText" -ForegroundColor Magenta

#endregion
