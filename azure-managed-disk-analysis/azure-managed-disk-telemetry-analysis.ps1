<#
.SYNOPSIS
    Analyzes Azure managed disk performance telemetry to identify disks that may benefit from Performance Plus or expansion.

.DESCRIPTION
    This script retrieves Azure managed disk metrics from Azure Monitor and analyzes their performance over a specified time window.
    It identifies disks that consistently exceed their provisioned IOPS or throughput limits, suggesting they may benefit from:
    - Enabling Performance Plus (for eligible disk SKUs)
    - Expanding to a larger disk size with higher limits
    
    The script generates CSV reports with detailed metrics and recommendations.

.PARAMETER DaysToInspect
    Number of days of historical metrics to analyze. Default is 3 days.

.PARAMETER ExceedanceThreshold
    The percentage threshold (0-1) for determining if a disk consistently exceeds its limits.
    For example, 0.05 means if more than 5% of samples exceed the limit, it triggers a recommendation.
    Default is 0.05 (5%).

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to analyze. If not specified, uses the current subscription context.

.PARAMETER SpecFile
    Path to the JSON file containing disk SKU specifications (IOPS and throughput limits by size).
    Default is "disk-specs.json" in the script directory.

.PARAMETER OutputPrefix
    Prefix for output CSV files. Two files will be generated:
    - {OutputPrefix}-perfplus-candidates.csv - Disks that could benefit from Performance Plus
    - {OutputPrefix}-expansion-candidates.csv - Disks that should be expanded to a larger size
    Default is "disk-analysis".

.EXAMPLE
    .\azure-managed-disk-telemetry-analysis.ps1
    
    Analyzes all disks in the current subscription using default settings.

.EXAMPLE
    .\azure-managed-disk-telemetry-analysis.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -DaysToInspect 7
    
    Analyzes disks in the specified subscription over the last 7 days.

.EXAMPLE
    .\azure-managed-disk-telemetry-analysis.ps1 -ExceedanceThreshold 0.10 -OutputPrefix "weekly-report"
    
    Uses a 10% exceedance threshold and generates reports with custom filenames.

.NOTES
    Requires Azure CLI (az) to be installed and authenticated.
    Requires read access to Azure Monitor metrics for the target subscriptions.
#>

param(
    [int]$DaysToInspect = 7,
    [double]$ExceedanceThreshold = 0.05,
    [string[]]$SubscriptionId,
    [string]$SpecFile = "disk-specs.json",
    [string]$OutputPrefix = "disk-analysis"
)

#region Helper Functions

<#
.SYNOPSIS
    Calculates the percentage of samples where a property exceeds a limit.
#>
function Get-PercentAbove {
    param($Samples, [string]$Property, [double]$Limit)
    if (-not $Samples -or -not $Samples.Count) { return 0 }
    ($Samples | Where-Object { $_.$Property -gt $Limit }).Count / $Samples.Count
}

<#
.SYNOPSIS
    Retrieves the specification (IOPS/throughput limits) for a specific disk size from the spec table.
#>
function Get-SkuSpec {
    param($Table, [int]$SizeGiB)
    $key = $SizeGiB.ToString()
    $prop = $Table.PSObject.Properties[$key]
    if ($prop) { return $prop.Value }
    return $null
}

<#
.SYNOPSIS
    Maps an Azure disk tier (e.g., S10, E10) to its corresponding size in GiB.
    Returns the tier size, or null if the tier is not recognized.
#>
function Get-TierSize {
    param([string]$Tier)
    
    # Standard HDD (S-series) and Standard SSD (E-series) tier sizes
    $tierSizes = @{
        "S4" = 32; "E4" = 32
        "S6" = 64; "E6" = 64
        "S10" = 128; "E10" = 128
        "S15" = 256; "E15" = 256
        "S20" = 512; "E20" = 512
        "S30" = 1024; "E30" = 1024
        "S40" = 2048; "E40" = 2048
        "S50" = 4096; "E50" = 4096
        "S60" = 8192; "E60" = 8192
        "S70" = 16384; "E70" = 16384
        "S80" = 32767; "E80" = 32767
    }
    
    if ($tierSizes.ContainsKey($Tier)) {
        return $tierSizes[$Tier]
    }
    return $null
}

<#
.SYNOPSIS
    Determines the billing tier for a disk based on its actual size.
    Azure bills disks at the next tier up, so a 100GB disk is billed as S10 (128GB).
#>
function Get-BillingTier {
    param([string]$DiskType, [int]$ActualSizeGB)
    
    # Define tier boundaries (max size for each tier)
    $tiers = @(
        @{Name="S4/E4"; MaxSize=32; BilledSize=32},
        @{Name="S6/E6"; MaxSize=64; BilledSize=64},
        @{Name="S10/E10"; MaxSize=128; BilledSize=128},
        @{Name="S15/E15"; MaxSize=256; BilledSize=256},
        @{Name="S20/E20"; MaxSize=512; BilledSize=512},
        @{Name="S30/E30"; MaxSize=1024; BilledSize=1024},
        @{Name="S40/E40"; MaxSize=2048; BilledSize=2048},
        @{Name="S50/E50"; MaxSize=4096; BilledSize=4096},
        @{Name="S60/E60"; MaxSize=8192; BilledSize=8192},
        @{Name="S70/E70"; MaxSize=16384; BilledSize=16384},
        @{Name="S80/E80"; MaxSize=32767; BilledSize=32767}
    )
    
    foreach ($tier in $tiers) {
        if ($ActualSizeGB -le $tier.MaxSize) {
            $tierPrefix = if ($DiskType -eq "StandardSSD_LRS") { "E" } else { "S" }
            $tierNumber = $tier.Name.Split('/')[0].Substring(1)
            return @{
                TierName = "$tierPrefix$tierNumber"
                BilledSizeGB = $tier.BilledSize
                ActualSizeGB = $ActualSizeGB
                IsCustomSize = ($ActualSizeGB -ne $tier.BilledSize)
            }
        }
    }
    
    # If larger than S80/E80, return the actual size
    return @{
        TierName = "Custom"
        BilledSizeGB = $ActualSizeGB
        ActualSizeGB = $ActualSizeGB
        IsCustomSize = $true
    }
}

<#
.SYNOPSIS
    Invokes Azure CLI and returns raw stdout output.
#>
function Invoke-AzCliRaw {
    param([string[]]$Arguments)
    # Get the full path to az.exe to work with UseShellExecute = false
    $azPath = (Get-Command az -ErrorAction Stop).Source
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $azPath
    
    # Add all arguments including common flags
    foreach ($arg in ($Arguments + @("--only-show-errors","--output","json"))) {
        $psi.ArgumentList.Add($arg)
    }
    
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    
    if ($process.ExitCode -ne 0) {
        if ($stderr) { Write-Error $stderr.Trim() }
        throw "az $($Arguments -join ' ') failed with exit code $($process.ExitCode)"
    }
    return $stdout
}

<#
.SYNOPSIS
    Invokes Azure CLI and returns parsed JSON output.
#>
function Invoke-AzCliJson {
    param([string[]]$Arguments)
    $json = Invoke-AzCliRaw -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    return $json | ConvertFrom-Json
}

#endregion

#region Initialization

# Start timing
$scriptStartTime = Get-Date

# Load disk specifications from JSON file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$specPath = if ([System.IO.Path]::IsPathRooted($SpecFile)) { $SpecFile } else { Join-Path $scriptDir $SpecFile }
if (-not (Test-Path $specPath)) { throw "Spec file not found at $specPath" }
$spec = Get-Content $specPath -Raw | ConvertFrom-Json
$hddSpecs = $spec.StandardHDD
$ssdSpecs = $spec.StandardSSD
$premiumSpecs = $spec.PremiumSSD
$premiumV2Specs = $spec.PremiumSSDv2

# Use current subscription if none specified
if (-not $SubscriptionId -or -not $SubscriptionId.Count) {
    $SubscriptionId = @((Invoke-AzCliJson @("account","show")).id)
}

# Define the analysis time window
$analysisWindowEnd = Get-Date
$analysisWindowStart = $analysisWindowEnd.AddDays(-$DaysToInspect)

# Metrics to collect from Azure Monitor
$metricNames = "Composite Disk Read Operations/sec,Composite Disk Write Operations/sec,Composite Disk Read Bytes/sec,Composite Disk Write Bytes/sec,DiskPaidBurstIOPS"

# Azure pricing (North Central US region)
# Storage costs are defined in disk-specs.json per SKU
# Premium SSD v2 uses capacity-based pricing: $0.00011/hour/GiB = $0.0803/month/GiB
# Premium SSD v2 has fixed limits: 750 MB/s throughput, 3000 IOPS (can scale higher with additional configuration)
# The script automatically compares Premium SSD v1 vs v2 and recommends the cheaper option
$hddTransactionCostPer10k = 0.0005   # $0.005 per 10,000 transactions for Standard HDD
$ssdTransactionCostPer10k = 0.002   # $0.002 per 10,000 transactions for Standard SSD
$burstIopsCost = 0.005              # $0.005 per burst IOPS per month (approximate)

#endregion

#region Telemetry Collection

<#
.SYNOPSIS
    Retrieves disk performance metrics from Azure Monitor for a specific disk.
.DESCRIPTION
    Collects metric samples of IOPS and throughput over the analysis window.
    Automatically selects appropriate interval based on time window to stay within Azure Monitor retention limits.
    Returns aggregated samples and estimated transaction count.
#>
function Get-DiskTelemetry {
    param([string]$ResourceId)
    
    # Determine appropriate interval based on days to inspect
    # Azure Monitor retention limits: PT1M=30d, PT5M=90d, PT1H=93d
    $interval = "PT1M"
    $secondsPerSample = 60
    
    if ($DaysToInspect -gt 29) {
        # Use 5-minute intervals for 30+ days to stay within retention limits
        $interval = "PT5M"
        $secondsPerSample = 300
    }
    
    if ($DaysToInspect -gt 89) {
        # Use 1-hour intervals for 90+ days
        $interval = "PT1H"
        $secondsPerSample = 3600
    }
    
    # Query Azure Monitor for disk metrics
    $metrics = Invoke-AzCliJson @(
        "monitor","metrics","list",
        "--resource",$ResourceId,
        "--metrics",$metricNames,
        "--aggregation","Average",
        "--interval",$interval,
        "--start-time",$analysisWindowStart.ToString("yyyy-MM-ddTHH:mm:ssZ"),
        "--end-time",$analysisWindowEnd.ToString("yyyy-MM-ddTHH:mm:ssZ")
    )
    
    if (-not $metrics.value) { return [pscustomobject]@{Samples=@(); Transactions=0} }
    
    # Build a map of metric name to time series data
    $map = @{}
    foreach ($metric in $metrics.value) {
        if ($metric.timeseries.Count -gt 0) {
            $map[$metric.name.value] = $metric.timeseries[0].data
        }
    }
    
    # Return empty result if required metrics are not available
    $requiredMetrics = @(
        "Composite Disk Read Operations/sec",
        "Composite Disk Write Operations/sec",
        "Composite Disk Read Bytes/sec",
        "Composite Disk Write Bytes/sec"
    )
    
    foreach ($metricName in $requiredMetrics) {
        if (-not $map.ContainsKey($metricName) -or -not $map[$metricName]) {
            Write-Host "      WARNING: Missing metric data for '$metricName'" -ForegroundColor Yellow
            return [pscustomobject]@{Samples=@(); Transactions=0; BurstOperations=0}
        }
    }
    
    # Combine read and write metrics into IOPS and MBps snapshots
    # Find the minimum count across all metrics to avoid index out of bounds
    $count = @(
        $map["Composite Disk Read Operations/sec"].Count,
        $map["Composite Disk Write Operations/sec"].Count,
        $map["Composite Disk Read Bytes/sec"].Count,
        $map["Composite Disk Write Bytes/sec"].Count
    ) | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
    
    $snapshots = @()
    for ($i = 0; $i -lt $count; $i++) {
        $rOps = $map["Composite Disk Read Operations/sec"][$i].average
        $wOps = $map["Composite Disk Write Operations/sec"][$i].average
        $rBps = $map["Composite Disk Read Bytes/sec"][$i].average
        $wBps = $map["Composite Disk Write Bytes/sec"][$i].average
        $timestamp = $map["Composite Disk Read Operations/sec"][$i].timeStamp
        
        # Skip samples with missing data
        if ($null -in ($rOps,$wOps,$rBps,$wBps)) { continue }
        
        $snapshots += [pscustomobject]@{
            TimeStamp = $timestamp
            IOPS = $rOps + $wOps
            MBps = ($rBps + $wBps) / 1MB
        }
    }
    
    # Calculate total transactions (for billing analysis on Standard HDD/SSD)
    $transactions = 0
    foreach ($metricName in @("Composite Disk Read Operations/sec","Composite Disk Write Operations/sec")) {
        if ($map.ContainsKey($metricName)) {
            foreach ($entry in $map[$metricName]) {
                if ($null -ne $entry.average) {
                    # Convert ops/sec to total ops (multiply by sample duration in seconds)
                    $transactions += [double]$entry.average * $secondsPerSample
                }
            }
        }
    }
    
    # Calculate burst IOPS (on-demand burst operations)
    $burstOps = 0
    if ($map.ContainsKey("DiskPaidBurstIOPS")) {
        foreach ($entry in $map["DiskPaidBurstIOPS"]) {
            if ($null -ne $entry.total) {
                $burstOps += [double]$entry.total
            }
        }
    }
    
    return [pscustomobject]@{
        Samples = $snapshots
        Transactions = [math]::Round($transactions,2)
        BurstOperations = [math]::Round($burstOps,2)
        AvgLatencyMs = 0  # Latency metrics not available for managed disks
    }
}

<#
.SYNOPSIS
    Detects continuous burst windows where performance exceeds 80% of limits for 60+ minutes.
.DESCRIPTION
    Analyzes time-series samples to find continuous windows where IOPS or throughput
    exceeds 80% of the maximum for at least 60 consecutive minutes.
#>
function Get-BurstWindows {
    param(
        $Samples,
        [double]$MaxIOPS,
        [double]$MaxMBps,
        [int]$IntervalSeconds = 60
    )
    
    if (-not $Samples -or $Samples.Count -eq 0) { return @() }
    
    $burstWindows = @()
    $currentWindow = $null
    $threshold = 0.80  # 80% threshold
    
    foreach ($sample in $Samples) {
        $iopsRatio = if ($MaxIOPS -gt 0) { $sample.IOPS / $MaxIOPS } else { 0 }
        $mbpsRatio = if ($MaxMBps -gt 0) { $sample.MBps / $MaxMBps } else { 0 }
        $isHighUsage = ($iopsRatio -ge $threshold) -or ($mbpsRatio -ge $threshold)
        
        if ($isHighUsage) {
            if (-not $currentWindow) {
                # Start new window
                $currentWindow = @{
                    StartTime = $sample.TimeStamp
                    EndTime = $sample.TimeStamp
                    MaxIOPS = $sample.IOPS
                    MaxMBps = $sample.MBps
                }
            } else {
                # Extend current window
                $currentWindow.EndTime = $sample.TimeStamp
                if ($sample.IOPS -gt $currentWindow.MaxIOPS) { $currentWindow.MaxIOPS = $sample.IOPS }
                if ($sample.MBps -gt $currentWindow.MaxMBps) { $currentWindow.MaxMBps = $sample.MBps }
            }
        } else {
            # End current window if it exists
            if ($currentWindow) {
                $duration = ([datetime]$currentWindow.EndTime - [datetime]$currentWindow.StartTime).TotalMinutes
                if ($duration -ge 60) {
                    $burstWindows += [pscustomobject]@{
                        StartTime = $currentWindow.StartTime
                        EndTime = $currentWindow.EndTime
                        DurationMinutes = [math]::Round($duration, 1)
                        MaxIOPS = [math]::Round($currentWindow.MaxIOPS, 0)
                        MaxMBps = [math]::Round($currentWindow.MaxMBps, 2)
                    }
                }
                $currentWindow = $null
            }
        }
    }
    
    # Check final window
    if ($currentWindow) {
        $duration = ([datetime]$currentWindow.EndTime - [datetime]$currentWindow.StartTime).TotalMinutes
        if ($duration -ge 60) {
            $burstWindows += [pscustomobject]@{
                StartTime = $currentWindow.StartTime
                EndTime = $currentWindow.EndTime
                DurationMinutes = [math]::Round($duration, 1)
                MaxIOPS = [math]::Round($currentWindow.MaxIOPS, 0)
                MaxMBps = [math]::Round($currentWindow.MaxMBps, 2)
            }
        }
    }
    
    return $burstWindows
}

<#
.SYNOPSIS
    Retrieves per-disk latency metrics from the VM using LUN-based filtering.
.DESCRIPTION
    Azure provides disk latency at the VM level with LUN dimensions for data disks.
    This function queries the VM for the specific disk's latency using its LUN.
#>
function Get-VmDiskLatency {
    param(
        [string]$VmResourceId,
        [string]$DiskResourceId
    )
    
    if ([string]::IsNullOrEmpty($VmResourceId) -or [string]::IsNullOrEmpty($DiskResourceId)) {
        return 0  # Disk not attached to a VM
    }
    
    # Determine appropriate interval based on days to inspect
    $interval = "PT1M"
    if ($DaysToInspect -gt 29) { $interval = "PT5M" }
    if ($DaysToInspect -gt 89) { $interval = "PT1H" }
    
    try {
        # Get VM storage profile to find the disk's LUN
        $vm = Invoke-AzCliJson @("vm","show","--ids",$VmResourceId,"--query","storageProfile")
        
        # Check if this is an OS disk or data disk
        $isOsDisk = $false
        $lun = $null
        
        if ($vm.osDisk.managedDisk.id -eq $DiskResourceId) {
            $isOsDisk = $true
        } else {
            # Find the LUN for this data disk
            foreach ($dataDisk in $vm.dataDisks) {
                if ($dataDisk.managedDisk.id -eq $DiskResourceId) {
                    $lun = $dataDisk.lun
                    break
                }
            }
            
            if ($null -eq $lun) {
                # Disk not found in VM's storage profile
                return 0
            }
        }
        
        # Query the appropriate metric
        if ($isOsDisk) {
            # OS Disk Latency (no LUN dimension needed)
            $metrics = Invoke-AzCliJson @(
                "monitor","metrics","list",
                "--resource",$VmResourceId,
                "--metrics","OS Disk Latency",
                "--aggregation","Average",
                "--interval",$interval,
                "--start-time",$analysisWindowStart.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                "--end-time",$analysisWindowEnd.ToString("yyyy-MM-ddTHH:mm:ssZ")
            )
        } else {
            # Data Disk Latency with LUN filter
            $metrics = Invoke-AzCliJson @(
                "monitor","metrics","list",
                "--resource",$VmResourceId,
                "--metrics","Data Disk Latency",
                "--aggregation","Average",
                "--interval",$interval,
                "--filter","LUN eq '$lun'",
                "--start-time",$analysisWindowStart.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                "--end-time",$analysisWindowEnd.ToString("yyyy-MM-ddTHH:mm:ssZ")
            )
        }
        
        if (-not $metrics.value -or $metrics.value.Count -eq 0) { return 0 }
        
        # Calculate average latency from all samples
        $totalLatency = 0
        $sampleCount = 0
        
        foreach ($metric in $metrics.value) {
            if ($metric.timeseries.Count -gt 0) {
                foreach ($dataPoint in $metric.timeseries[0].data) {
                    if ($null -ne $dataPoint.average) {
                        $totalLatency += [double]$dataPoint.average
                        $sampleCount++
                    }
                }
            }
        }
        
        if ($sampleCount -gt 0) {
            return [math]::Round($totalLatency / $sampleCount, 2)
        }
        
        return 0
    }
    catch {
        # VM might not have latency metrics enabled
        Write-Host "      Could not retrieve latency metrics: $($_.Exception.Message)" -ForegroundColor DarkGray
        return 0
    }
}

#endregion

#region Disk Discovery

# Retrieve all managed disks from specified subscriptions
Write-Host "Discovering managed disks..." -ForegroundColor Cyan
$allDisks = @()
foreach ($sub in $SubscriptionId) {
    Write-Host "  Querying subscription: $sub" -ForegroundColor Gray
    $diskList = Invoke-AzCliJson @(
        "disk","list",
        "--subscription",$sub,
        "--query","[].{id:id,name:name,rg:resourceGroup,sku:sku.name,diskSizeGB:diskSizeGB,perfPlus:supportedCapabilities.performancePlus,expandedIops:diskIOPSReadWrite,expandedMBps:diskMBpsReadWrite,managedBy:managedBy}"
    )
    if ($diskList) {
        foreach ($disk in $diskList) {
            $disk | Add-Member -NotePropertyName subscriptionId -NotePropertyValue $sub -Force
            $allDisks += $disk
        }
        Write-Host "    Found $($diskList.Count) disk(s)" -ForegroundColor Gray
    } else {
        Write-Host "    No disks found" -ForegroundColor Gray
    }
}

if (-not $allDisks.Count) {
    Write-Warning "No managed disks found for the provided subscription scope."
    return
}

Write-Host "`nTotal disks discovered: $($allDisks.Count)" -ForegroundColor Green
Write-Host "Analysis window: $($analysisWindowStart.ToString('yyyy-MM-dd HH:mm')) to $($analysisWindowEnd.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green

# Inform user about metric granularity based on time window
$intervalMessage = if ($DaysToInspect -gt 89) {
    "Using 1-hour metric intervals (time window > 89 days)"
} elseif ($DaysToInspect -gt 29) {
    "Using 5-minute metric intervals (time window > 29 days)"
} else {
    "Using 1-minute metric intervals"
}
Write-Host "Metric granularity: $intervalMessage" -ForegroundColor Gray
Write-Host ""

#endregion

#region Performance Analysis

# Analyze each disk's performance against its limits
Write-Host "Analyzing disk performance..." -ForegroundColor Cyan
if ($DaysToInspect -lt 30) {
    Write-Host "NOTE: Analyzing $DaysToInspect days of data. All cost estimates are projected to 30-day monthly values." -ForegroundColor Yellow
}
Write-Host ""
$results = foreach ($disk in $allDisks) {
    $diskNumber = $allDisks.IndexOf($disk) + 1
    Write-Host "  [$diskNumber/$($allDisks.Count)] Processing: $($disk.name) ($($disk.sku), $($disk.diskSizeGB) GiB)" -ForegroundColor Gray
    
    $tier = $disk.sku
    $actualSize = [int]$disk.diskSizeGB
    $isPerfPlus = [bool]$disk.perfPlus
    
    # Determine the billing tier and whether it's a custom size
    $billingInfo = $null
    $size = $actualSize
    $isCustomSize = $false
    $billingTierName = "N/A"
    
    if ($tier -eq "Standard_LRS" -or $tier -eq "StandardSSD_LRS") {
        $billingInfo = Get-BillingTier -DiskType $tier -ActualSizeGB $actualSize
        $size = $billingInfo.BilledSizeGB
        $isCustomSize = $billingInfo.IsCustomSize
        $billingTierName = $billingInfo.TierName
        
        if ($isCustomSize) {
            Write-Host "      Custom size detected: $actualSize GiB billed as $billingTierName ($($size) GiB)" -ForegroundColor Cyan
        }
    }
    
    # Get the specification for this disk tier and size
    $specForTier = switch ($tier) {
        "Standard_LRS" { Get-SkuSpec $hddSpecs $size }
        "StandardSSD_LRS" { Get-SkuSpec $ssdSpecs $size }
        default { $null }
    }
    
    # Fetch performance telemetry
    $telemetry = Get-DiskTelemetry -ResourceId $disk.id
    Write-Host "      Retrieved $($telemetry.Samples.Count) metric samples" -ForegroundColor DarkGray
    
    # Try to get per-disk latency metrics from the parent VM using LUN filtering
    $avgLatencyMs = 0
    if ($disk.managedBy) {
        Write-Host "      Disk attached to VM, querying latency metrics..." -ForegroundColor DarkGray
        $avgLatencyMs = Get-VmDiskLatency -VmResourceId $disk.managedBy -DiskResourceId $disk.id
        if ($avgLatencyMs -gt 0) {
            Write-Host "      Average disk latency: $avgLatencyMs ms" -ForegroundColor DarkGray
        }
    }
    
    # Calculate transaction costs (for HDD and SSD)
    # Project to monthly cost for accurate comparisons
    $hddTransactionCost = 0
    $ssdTransactionCost = 0
    $daysInMonth = 30
    $monthlyTransactions = ($telemetry.Transactions / $DaysToInspect) * $daysInMonth
    $hddTransactionCost = ($monthlyTransactions / 10000) * $hddTransactionCostPer10k
    $ssdTransactionCost = ($monthlyTransactions / 10000) * $ssdTransactionCostPer10k
    
    # Display transaction cost analysis if analyzing less than 30 days
    if ($DaysToInspect -lt 30 -and $telemetry.Transactions -gt 0) {
        Write-Host "      Observed $([math]::Round($telemetry.Transactions, 0).ToString("N0")) transactions over $DaysToInspect days (Projected monthly: $([math]::Round($monthlyTransactions, 0).ToString("N0")))" -ForegroundColor DarkGray
        if ($tier -eq "Standard_LRS" -and $hddTransactionCost -gt 1) {
            Write-Host "      Projected monthly HDD transaction cost: `$$($hddTransactionCost.ToString('F2'))" -ForegroundColor $(if ($hddTransactionCost -gt 5) { "Yellow" } else { "DarkGray" })
        }
        if ($tier -eq "StandardSSD_LRS" -and $ssdTransactionCost -gt 0.1) {
            Write-Host "      Projected monthly SSD transaction cost: `$$($ssdTransactionCost.ToString('F2'))" -ForegroundColor DarkGray
        }
    }
    
    # Get storage costs from disk specs (based on North Central US pricing)
    $hddSpec = Get-SkuSpec $hddSpecs $size
    $ssdSpec = Get-SkuSpec $ssdSpecs $size
    $premiumSpec = Get-SkuSpec $premiumSpecs $size
    
    # Use MonthlyCost from specs if available, otherwise fallback to per-GiB calculation
    $hddStorageCost = if ($hddSpec -and $hddSpec.MonthlyCost) { 
        $hddSpec.MonthlyCost 
    } else { 
        $size * 0.04  # Fallback: ~$0.04/GiB for Standard HDD
    }
    
    $ssdStorageCost = if ($ssdSpec -and $ssdSpec.MonthlyCost) { 
        $ssdSpec.MonthlyCost 
    } else { 
        $size * 0.125  # Fallback: ~$0.125/GiB for Standard SSD
    }
    
    $premiumStorageCost = if ($premiumSpec -and $premiumSpec.MonthlyCost) { 
        $premiumSpec.MonthlyCost 
    } else { 
        0  # No fallback for Premium - needs spec data
    }
    
    # Premium SSD v2 uses capacity-based pricing (per GiB)
    $premiumV2StorageCost = if ($premiumV2Specs -and $premiumV2Specs.MonthlyRatePerGiB) {
        $size * $premiumV2Specs.MonthlyRatePerGiB
    } else {
        $size * 0.0803  # Fallback: $0.00011/hour/GiB = $0.0803/month/GiB
    }
    
    # Burst costs only apply to Premium SSD and Standard SSD (not Standard HDD)
    $burstCost = 0
    if ($telemetry.BurstOperations -gt 0 -and ($tier -eq "Premium_LRS" -or $tier -eq "PremiumV2_LRS" -or $tier -eq "StandardSSD_LRS" -or $tier -eq "StandardSSD_ZRS")) {
        # Scale burst operations to monthly estimate
        $monthlyBurstOps = ($telemetry.BurstOperations / $DaysToInspect) * 30
        $burstCost = $monthlyBurstOps * $burstIopsCost
        Write-Host "      Burst operations detected: $($telemetry.BurstOperations) (Est. monthly cost: `$$($burstCost.ToString('F2')))" -ForegroundColor Yellow
    }
    
    # Total cost calculation based on disk type
    $totalEstimatedMonthlyCost = 0
    $hddTotalCost = $hddStorageCost + $hddTransactionCost  # HDD = storage + transactions
    $ssdTotalCost = $ssdStorageCost + $ssdTransactionCost + $burstCost  # SSD = storage + transactions + burst (if any)
    $premiumTotalCost = $premiumStorageCost  # Premium SSD v1 = storage only (no burst charges, no transaction fees)
    $premiumV2TotalCost = $premiumV2StorageCost  # Premium SSD v2 = storage only (capacity-based pricing)
    
    if ($tier -eq "Standard_LRS") {
        # Standard HDD: storage + transaction costs
        $totalEstimatedMonthlyCost = $hddTotalCost
    }
    elseif ($tier -eq "StandardSSD_LRS" -or $tier -eq "StandardSSD_ZRS") {
        # Standard SSD: storage + transaction costs + burst costs (if any)
        $totalEstimatedMonthlyCost = $ssdTotalCost
    }
    else {
        # Premium SSD: storage cost (no burst charges, no transaction fees)
        $totalEstimatedMonthlyCost = $premiumStorageCost
    }
    
    # Calculate cost savings/difference comparisons
    $costSavingsHDDtoSSD = $hddTotalCost - $ssdTotalCost  # Positive = HDD more expensive, Negative = SSD more expensive
    $costDiffSSDtoPremium = $premiumTotalCost - $ssdTotalCost  # Positive = Premium v1 more expensive, Negative = Premium v1 cheaper
    $costDiffSSDtoPremiumV2 = $premiumV2TotalCost - $ssdTotalCost  # Positive = Premium v2 more expensive, Negative = Premium v2 cheaper
    
    # Determine best Premium option (v1 vs v2)
    $bestPremiumCost = [Math]::Min($premiumTotalCost, $premiumV2TotalCost)
    $bestPremiumType = if ($premiumV2TotalCost -lt $premiumTotalCost) { "Premium SSD v2" } else { "Premium SSD" }
    $costDiffSSDtoBestPremium = $bestPremiumCost - $ssdTotalCost
    
    # Skip tiers we don't have specs for (e.g., Premium SSD, Ultra Disk, or unsupported sizes)
    # "Tier not handled" means the disk SKU or size is not defined in the spec file (disk-specs.json)
    # This typically occurs for Premium SSD, Ultra Disk, or disk sizes not listed in the spec file
    if (-not $specForTier) {
        Write-Host "      Tier '$tier' (size: $size GiB) not in spec file - skipping analysis" -ForegroundColor Yellow
        [pscustomobject]@{
            Disk=$disk.name; ResourceGroup=$disk.rg; Subscription=$disk.subscriptionId
            SKU=$tier; ActualSizeGiB=$actualSize; BilledSizeGiB=$size; BillingTier=$billingTierName
            CustomSize=if ($isCustomSize) { "Yes" } else { "No" }
            Samples=$telemetry.Samples.Count
            PercentIOPSAbove=0; PercentMBpsAbove=0; Transactions=$telemetry.Transactions
            BurstOperations=$telemetry.BurstOperations
            EstMonthlyTransactionCost=[math]::Round($transactionCost,2)
            EstMonthlyBurstCost=[math]::Round($burstCost,2)
            EstMonthlyTotalCost=[math]::Round($totalEstimatedMonthlyCost,2)
            ChargedForTransactions="n/a"; PerformancePlus="No"
            EffectiveMaxIOPS=0; EffectiveMaxMBps=0; Decision="Tier not handled"
        }
        continue
    }
    
    # Calculate effective limits (accounting for Performance Plus if enabled)
    $effectiveIops = if ($isPerfPlus -and $disk.expandedIops) { [double]$disk.expandedIops } else { $specForTier.MaxIOPS }
    $effectiveMb = if ($isPerfPlus -and $disk.expandedMBps) { [double]$disk.expandedMBps } else { $specForTier.MaxMBps }
    
    # Calculate what percentage of samples exceeded the limits
    $percentIOPS = Get-PercentAbove $telemetry.Samples "IOPS" $effectiveIops
    $percentMBps = Get-PercentAbove $telemetry.Samples "MBps" $effectiveMb
    
    # Detect burst windows (60+ minute continuous periods at/above 80% capacity)
    $burstWindows = Get-BurstWindows -Samples $telemetry.Samples -MaxIOPS $effectiveIops -MaxMBps $effectiveMb
    $hasBurstWindows = $burstWindows.Count -gt 0
    $burstWindowsSummary = if ($hasBurstWindows) {
        ($burstWindows | ForEach-Object {
            "$($_.StartTime) to $($_.EndTime) ($($_.DurationMinutes)min, IOPS:$($_.MaxIOPS), MBps:$($_.MaxMBps))"
        }) -join "; "
    } else {
        "None"
    }
    
    # Determine recommendation based on tier and performance
    $decision = "Stay"
    $txnNote = "n/a"
    
    switch ($tier) {
        "Standard_LRS" {
            # Standard HDD: recommend upgrade to SSD if consistently exceeding limits OR if transaction costs make SSD cheaper
            if ($percentIOPS -gt $ExceedanceThreshold -or $percentMBps -gt $ExceedanceThreshold) {
                $decision = "Upgrade to Standard SSD"
                # Show cost comparison
                if ($costSavingsHDDtoSSD -gt 0) {
                    Write-Host "      Recommendation: $decision (IOPS: $([math]::Round($percentIOPS*100,1))% above, MBps: $([math]::Round($percentMBps*100,1))% above) - Would also save `$$($costSavingsHDDtoSSD.ToString('F2'))/month on transactions" -ForegroundColor Yellow
                } else {
                    Write-Host "      Recommendation: $decision (IOPS: $([math]::Round($percentIOPS*100,1))% above, MBps: $([math]::Round($percentMBps*100,1))% above)" -ForegroundColor Yellow
                }
                if ($hasBurstWindows) {
                    Write-Host "      NOTE: Detected $($burstWindows.Count) burst window(s) - review if workload has temporary spikes" -ForegroundColor Cyan
                }
            } 
            elseif ($hasBurstWindows) {
                # Burst windows detected but overall usage is low
                $decision = "Review burst patterns - potential upgrade needed"
                Write-Host "      Recommendation: $decision - Detected $($burstWindows.Count) sustained burst(s) at 80%+ capacity" -ForegroundColor Yellow
            }
            elseif ($costSavingsHDDtoSSD -gt 5) {
                # Not exceeding limits, but transaction costs make SSD cheaper (savings > $5/month)
                $decision = "Upgrade to Standard SSD (high transaction costs)"
                Write-Host "      Recommendation: $decision - Would save `$$($costSavingsHDDtoSSD.ToString('F2'))/month despite higher storage cost" -ForegroundColor Yellow
            } 
            else {
                Write-Host "      Recommendation: $decision" -ForegroundColor Green
            }
            $txnNote = if ($telemetry.Transactions -gt 0) { "Yes (Standard HDD bills per transaction)" } else { "No" }
        }
        "StandardSSD_LRS" {
            # Standard SSD: check both upgrade and downgrade scenarios
            # Priority for upgrade recommendations: 1) Cost Savings, 2) Throughput/IOPS, 3) Latency
            $hddBaseline = Get-SkuSpec $hddSpecs $size
            $upgrade = ($percentIOPS -gt $ExceedanceThreshold -or $percentMBps -gt $ExceedanceThreshold)
            $downgrade = $false
            
            # Check performance issues
            $highLatency = $avgLatencyMs -gt 10
            $exceedsIOPS = $percentIOPS -gt $ExceedanceThreshold
            $exceedsMBps = $percentMBps -gt $ExceedanceThreshold
            
            # Consider downgrade to HDD if performance would still be acceptable AND it would save money
            if ($hddBaseline) {
                $performanceOk = (
                    (Get-PercentAbove $telemetry.Samples "IOPS" $hddBaseline.MaxIOPS) -le $ExceedanceThreshold -and
                    (Get-PercentAbove $telemetry.Samples "MBps" $hddBaseline.MaxMBps) -le $ExceedanceThreshold
                )
                
                # Check if latency indicates need for SSD performance
                # If latency > 5ms, the disk is experiencing slower response times and should stay on SSD
                $latencyRequiresSSD = $avgLatencyMs -gt 5
                
                # Only recommend downgrade if:
                # 1. HDD would be cheaper (costSavingsHDDtoSSD is negative)
                # 2. Performance is acceptable on HDD
                # 3. Latency is low enough (<= 5ms) that HDD would be acceptable
                $downgrade = $performanceOk -and ($costSavingsHDDtoSSD -lt 0) -and (-not $latencyRequiresSSD)
            }
            
            # Upgrade decision priority: Cost Savings → Latency → Throughput/IOPS
            # Check if Premium is cheaper overall (Premium has no transaction fees or burst charges)
            # Compare both Premium v1 and v2, recommend the better option
            
            if ($costDiffSSDtoBestPremium -lt -5) {
                # Premium is significantly cheaper overall
                $actualSavings = [math]::Abs($costDiffSSDtoBestPremium)
                $decision = "Upgrade to $bestPremiumType (cost savings)"
                Write-Host "      Recommendation: $decision - Would save `$$($actualSavings.ToString('F2'))/month (SSD: `$$($ssdTotalCost.ToString('F2')), $bestPremiumType`: `$$($bestPremiumCost.ToString('F2')))" -ForegroundColor Yellow
            }
            elseif ($costDiffSSDtoBestPremium -lt 0) {
                # Premium is slightly cheaper overall
                $actualSavings = [math]::Abs($costDiffSSDtoBestPremium)
                $decision = "Upgrade to $bestPremiumType (cost savings)"
                Write-Host "      Recommendation: $decision - Would save `$$($actualSavings.ToString('F2'))/month" -ForegroundColor Yellow
            }
            elseif ($highLatency) {
                # High latency indicates disk is struggling - prioritize this over performance metrics
                $decision = "Upgrade to $bestPremiumType (latency)"
                $costChangeMsg = if ($costDiffSSDtoBestPremium -gt 0) { 
                    "+`$$($costDiffSSDtoBestPremium.ToString('F2'))/month" 
                } else { 
                    "saves `$$([math]::Abs($costDiffSSDtoBestPremium).ToString('F2'))/month" 
                }
                Write-Host "      Recommendation: $decision - Latency ($avgLatencyMs ms) indicates performance issues, $bestPremiumType $costChangeMsg" -ForegroundColor Yellow
            }
            elseif ($exceedsIOPS -or $exceedsMBps) {
                # Exceeding throughput/IOPS limits
                $decision = "Upgrade to $bestPremiumType (performance)"
                $costChangeMsg = if ($costDiffSSDtoBestPremium -gt 0) { 
                    "+`$$($costDiffSSDtoBestPremium.ToString('F2'))/month" 
                } else { 
                    "saves `$$([math]::Abs($costDiffSSDtoBestPremium).ToString('F2'))/month" 
                }
                Write-Host "      Recommendation: $decision (IOPS: $([math]::Round($percentIOPS*100,1))% above, MBps: $([math]::Round($percentMBps*100,1))% above) - $bestPremiumType $costChangeMsg" -ForegroundColor Yellow
                if ($hasBurstWindows) {
                    Write-Host "      NOTE: Detected $($burstWindows.Count) burst window(s) - review if workload has temporary spikes" -ForegroundColor Cyan
                }
            }
            elseif ($hasBurstWindows) {
                # Burst windows detected but overall usage is low and burst cost is minimal
                $decision = "Review burst patterns - potential upgrade needed"
                Write-Host "      Recommendation: $decision - Detected $($burstWindows.Count) sustained burst(s) at 80%+ capacity" -ForegroundColor Yellow
            }
            elseif ($downgrade) { 
                $decision = "Downgrade to Standard HDD"
                # Show cost savings (costSavingsHDDtoSSD is negative, so we use Abs to show positive savings)
                Write-Host "      Recommendation: $decision (underutilized) - Would save `$$([math]::Round([math]::Abs($costSavingsHDDtoSSD),2))/month" -ForegroundColor Cyan
            }
            elseif ($performanceOk -and ($costSavingsHDDtoSSD -lt 0) -and $avgLatencyMs -gt 5) {
                # Would save money with HDD but latency indicates need for SSD performance
                $decision = "Stay (latency-sensitive)"
                Write-Host "      Recommendation: $decision - Latency ($avgLatencyMs ms) indicates need for SSD performance" -ForegroundColor Green
            }
            else {
                # Check if performance allows downgrade but cost doesn't make sense
                if ($hddBaseline) {
                    $performanceOk = (
                        (Get-PercentAbove $telemetry.Samples "IOPS" $hddBaseline.MaxIOPS) -le $ExceedanceThreshold -and
                        (Get-PercentAbove $telemetry.Samples "MBps" $hddBaseline.MaxMBps) -le $ExceedanceThreshold
                    )
                    if ($performanceOk -and $costSavingsHDDtoSSD -gt 0) {
                        # Performance allows downgrade but would cost more due to transactions
                        Write-Host "      Recommendation: $decision (underutilized, but HDD would cost `$$($costSavingsHDDtoSSD.ToString('F2')) more/month due to transactions)" -ForegroundColor Green
                    } else {
                        Write-Host "      Recommendation: $decision" -ForegroundColor Green
                    }
                } else {
                    Write-Host "      Recommendation: $decision" -ForegroundColor Green
                }
            }
            
            $txnNote = if ($ssdTransactionCost -gt 0) { "Yes (Standard SSD: `$$($ssdTransactionCost.ToString('F2'))/month)" } else { "No" }
        }
        default { 
            Write-Host "      Recommendation: $decision" -ForegroundColor Green
        }
    }
    
    # Output analysis result for this disk
    [pscustomobject]@{
        Disk=$disk.name
        ResourceGroup=$disk.rg
        Subscription=$disk.subscriptionId
        SKU=$tier
        ActualSizeGiB=$actualSize
        BilledSizeGiB=$size
        BillingTier=$billingTierName
        CustomSize=if ($isCustomSize) { "Yes" } else { "No" }
        Samples=$telemetry.Samples.Count
        PercentIOPSAbove=[math]::Round($percentIOPS*100,2)
        PercentMBpsAbove=[math]::Round($percentMBps*100,2)
        Transactions=$telemetry.Transactions
        BurstOperations=$telemetry.BurstOperations
        BurstWindowCount=$burstWindows.Count
        BurstWindows=$burstWindowsSummary
        AvgLatencyMs=$avgLatencyMs
        EstMonthlyHDDTransactionCost=[math]::Round($hddTransactionCost,2)
        EstMonthlySSDTransactionCost=[math]::Round($ssdTransactionCost,2)
        EstMonthlyBurstCost=[math]::Round($burstCost,2)
        EstMonthlyHDDTotalCost=[math]::Round($hddTotalCost,2)
        EstMonthlySSDTotalCost=[math]::Round($ssdTotalCost,2)
        EstMonthlyPremiumTotalCost=[math]::Round($premiumTotalCost,2)
        EstMonthlyPremiumV2TotalCost=[math]::Round($premiumV2TotalCost,2)
        BestPremiumOption=$bestPremiumType
        BestPremiumCost=[math]::Round($bestPremiumCost,2)
        CostSavingsHDDtoSSD=[math]::Round($costSavingsHDDtoSSD,2)
        CostDiffSSDtoPremium=[math]::Round($costDiffSSDtoPremium,2)
        CostDiffSSDtoPremiumV2=[math]::Round($costDiffSSDtoPremiumV2,2)
        CostDiffSSDtoBestPremium=[math]::Round($costDiffSSDtoBestPremium,2)
        EstMonthlyTotalCost=[math]::Round($totalEstimatedMonthlyCost,2)
        ChargedForTransactions=$txnNote
        PerformancePlus=if ($isPerfPlus) { "Yes" } else { "No" }
        EffectiveMaxIOPS=[math]::Round($effectiveIops,0)
        EffectiveMaxMBps=[math]::Round($effectiveMb,0)
        Decision=$decision
    }
}

Write-Host "`nAnalysis complete!" -ForegroundColor Green

#endregion

#region HTML Generation

<#
.SYNOPSIS
    Generates HTML report with styled table and highlighting for optimization opportunities.
#>
function New-HtmlReport {
    param($Results, [string]$OutputPath)
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Managed Disk Analysis Report</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            min-height: 100vh;
        }
        
        .container {
            max-width: 100%;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
            overflow: hidden;
            display: block;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
            display: block;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        
        .header p {
            font-size: 1.1em;
            opacity: 0.9;
        }
        
        .stats {
            display: grid;
            grid-template-columns: repeat(6, 1fr);
            gap: 20px;
            padding: 30px;
            background: #f8f9fa;
            border-bottom: 3px solid #e9ecef;
        }
        
        @media (max-width: 1400px) {
            .stats {
                grid-template-columns: repeat(3, 1fr);
            }
        }
        
        @media (max-width: 900px) {
            .stats {
                grid-template-columns: repeat(2, 1fr);
            }
        }
        
        @media (max-width: 600px) {
            .stats {
                grid-template-columns: 1fr;
            }
        }
        
        .stat-card {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            text-align: center;
        }
        
        .stat-card .number {
            font-size: 2.5em;
            font-weight: bold;
            color: #667eea;
            margin-bottom: 5px;
        }
        
        .stat-card .label {
            color: #6c757d;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        
        .legend {
            padding: 20px 30px;
            background: #fff3cd;
            border-bottom: 3px solid #ffc107;
            display: block;
        }
        
        .legend h3 {
            margin-bottom: 15px;
            color: #856404;
        }
        
        .legend-items {
            display: flex;
            flex-wrap: wrap;
            gap: 20px;
        }
        
        .legend-item {
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .legend-color {
            width: 30px;
            height: 20px;
            border-radius: 4px;
            border: 1px solid #ddd;
        }
        
        .table-container {
            padding: 30px;
            overflow-x: auto;
            display: block;
            width: 100%;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9em;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        
        thead {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            position: sticky;
            top: 0;
            z-index: 10;
        }
        
        th {
            padding: 15px 12px;
            text-align: left;
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.85em;
            letter-spacing: 0.5px;
            cursor: pointer;
            user-select: none;
            position: relative;
        }
        
        th:hover {
            background: rgba(255,255,255,0.1);
        }
        
        th.sortable::after {
            content: ' ⇅';
            opacity: 0.3;
            font-size: 0.8em;
        }
        
        th.sort-asc::after {
            content: ' ▲';
            opacity: 1;
        }
        
        th.sort-desc::after {
            content: ' ▼';
            opacity: 1;
        }
        
        .filter-row {
            background: #f8f9fa;
        }
        
        .filter-row th {
            padding: 8px;
            cursor: default;
        }
        
        .filter-row th:hover {
            background: #f8f9fa;
        }
        
        .filter-input {
            width: 100%;
            padding: 6px 8px;
            border: 1px solid #ced4da;
            border-radius: 4px;
            font-size: 0.85em;
            font-family: 'Segoe UI', sans-serif;
        }
        
        .filter-input:focus {
            outline: none;
            border-color: #667eea;
            box-shadow: 0 0 0 2px rgba(102, 126, 234, 0.2);
        }
        
        .filter-controls {
            padding: 15px 30px;
            background: #f8f9fa;
            border-bottom: 2px solid #dee2e6;
            display: flex;
            gap: 15px;
            align-items: center;
            flex-wrap: wrap;
        }
        
        .filter-controls button {
            padding: 8px 16px;
            border: none;
            border-radius: 4px;
            background: #667eea;
            color: white;
            cursor: pointer;
            font-size: 0.9em;
            font-weight: 600;
            transition: background 0.2s;
        }
        
        .filter-controls button:hover {
            background: #5568d3;
        }
        
        .filter-controls .results-count {
            margin-left: auto;
            color: #6c757d;
            font-weight: 600;
        }
        
        td {
            padding: 12px;
            border-bottom: 1px solid #e9ecef;
        }
        
        tbody tr {
            transition: all 0.2s ease;
        }
        
        tbody tr:hover {
            transform: scale(1.01);
            box-shadow: 0 2px 8px rgba(0,0,0,0.2);
            filter: brightness(1.05);
        }
        
        /* Row highlighting based on recommendation */
        .upgrade-needed {
            background: #ffcccc !important;
            border-left: 4px solid #dc3545;
        }
        
        .downgrade-opportunity {
            background: #fff9db !important;
            border-left: 4px solid #ffc107;
        }
        
        .stay-ok {
            background: #d4edda !important;
            border-left: 4px solid #28a745;
        }
        
        .custom-size {
            background: #e7e8ff !important;
            border-left: 4px solid #6c5ce7;
        }
        
        .tier-not-handled {
            background: #f0f0f0 !important;
            border-left: 4px solid #95a5a6;
            color: #2c3e50;
        }
        
        .badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.85em;
            font-weight: 600;
        }
        
        .badge-warning {
            background: #ffc107;
            color: #856404;
        }
        
        .badge-info {
            background: #17a2b8;
            color: white;
        }
        
        .badge-danger {
            background: #dc3545;
            color: white;
        }
        
        .badge-success {
            background: #28a745;
            color: white;
        }
        
        .badge-secondary {
            background: #6c757d;
            color: white;
        }
        
        .badge-purple {
            background: #6c5ce7;
            color: white;
        }
        
        .footer {
            padding: 20px;
            text-align: center;
            background: #f8f9fa;
            color: #6c757d;
            font-size: 0.9em;
        }
        
        .number-cell {
            text-align: right;
            font-family: 'Courier New', monospace;
        }
        
        .percent-high {
            color: #dc3545;
            font-weight: bold;
        }
        
        .percent-medium {
            color: #ffc107;
            font-weight: bold;
        }
        
        .percent-low {
            color: #28a745;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔍 Azure Managed Disk Analysis</h1>
            <p>Generated on $(Get-Date -Format "MMMM dd, yyyy 'at' HH:mm:ss")</p>
        </div>
"@

    # Calculate statistics
    $totalDisks = $Results.Count
    $upgradeCount = ($Results | Where-Object { $_.Decision -like "*Upgrade*" }).Count
    $downgradeCount = ($Results | Where-Object { $_.Decision -like "*Downgrade*" }).Count
    $stayCount = ($Results | Where-Object { $_.Decision -eq "Stay" -or $_.Decision -eq "Stay (latency-sensitive)" }).Count
    
    $html += @"

        <div class="stats">
            <div class="stat-card">
                <div class="number">$totalDisks</div>
                <div class="label">Total Disks</div>
            </div>
            <div class="stat-card">
                <div class="number" style="color: #dc3545;">$upgradeCount</div>
                <div class="label">Upgrade Recommended</div>
            </div>
            <div class="stat-card">
                <div class="number" style="color: #ffc107;">$downgradeCount</div>
                <div class="label">Downgrade Possible</div>
            </div>
            <div class="stat-card">
                <div class="number" style="color: #28a745;">$stayCount</div>
                <div class="label">Optimal</div>
            </div>
        </div>
        
        <div class="legend">
            <h3>📋 Row Color Legend</h3>
            <div class="legend-items">
                <div class="legend-item">
                    <div class="legend-color" style="background: #ffcccc; border-left: 4px solid #dc3545;"></div>
                    <span><strong>Upgrade Recommended</strong> - Performance issues detected</span>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #fff9db; border-left: 4px solid #ffc107;"></div>
                    <span><strong>Downgrade Possible</strong> - Underutilized, could save money</span>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #d4edda; border-left: 4px solid #28a745;"></div>
                    <span><strong>Stay</strong> - Disk is optimally sized</span>
                </div>
            </div>
        </div>
        
        <div class="filter-controls">
            <button onclick="clearAllFilters()">Clear Filters</button>
            <button onclick="exportToCSV()">Export Filtered to CSV</button>
            <span class="results-count">Showing <span id="visibleCount">0</span> of <span id="totalCount">0</span> disks</span>
        </div>
        
        <div class="table-container">
            <table id="diskTable">
                <thead>
                    <tr>
                        <th class="sortable" onclick="sortTable(0)">Disk Name</th>
                        <th class="sortable" onclick="sortTable(1)">Resource Group</th>
                        <th class="sortable" onclick="sortTable(2)">SKU</th>
                        <th class="sortable" onclick="sortTable(3)">Actual Size</th>
                        <th class="sortable" onclick="sortTable(4)">Billed Size</th>
                        <th class="sortable" onclick="sortTable(5)">Tier</th>
                        <th class="sortable" onclick="sortTable(6)">Custom</th>
                        <th class="sortable" onclick="sortTable(7)">IOPS Above %</th>
                        <th class="sortable" onclick="sortTable(8)">MBps Above %</th>
                        <th class="sortable" onclick="sortTable(9)">Avg Latency (ms)</th>
                        <th class="sortable" onclick="sortTable(10)">Transactions</th>
                        <th class="sortable" onclick="sortTable(11)">Cost Diff</th>
                        <th class="sortable" onclick="sortTable(12)">Decision</th>
                    </tr>
                    <tr class="filter-row">
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                    </tr>
                </thead>
                <tbody>
"@

    foreach ($result in ($Results | Sort-Object Subscription, ResourceGroup, Disk)) {
        # Determine row class based on conditions
        $rowClass = ""
        
        # Assign row class based on decision type
        if ($result.Decision -like "*Upgrade*") {
            $rowClass = "upgrade-needed"
        } elseif ($result.Decision -like "*Downgrade*") {
            $rowClass = "downgrade-opportunity"
        } elseif ($result.Decision -eq "Stay" -or $result.Decision -eq "Stay (latency-sensitive)") {
            $rowClass = "stay-ok"
        } elseif ($result.Decision -eq "Tier not handled") {
            $rowClass = "tier-not-handled"
        } elseif ($result.CustomSize -eq "Yes") {
            $rowClass = "custom-size"
        }
        
        # Format percentages with color
        $iopsClass = if ($result.PercentIOPSAbove -gt 5) { "percent-high" } elseif ($result.PercentIOPSAbove -gt 1) { "percent-medium" } else { "percent-low" }
        $mbpsClass = if ($result.PercentMBpsAbove -gt 5) { "percent-high" } elseif ($result.PercentMBpsAbove -gt 1) { "percent-medium" } else { "percent-low" }
        
        # Format latency with color (green <5ms, yellow 5-10ms, red >10ms)
        if ($result.AvgLatencyMs -gt 0) {
            $latencyDisplay = "$($result.AvgLatencyMs) ms"
            $latencyClass = if ($result.AvgLatencyMs -gt 10) { "percent-high" } 
                            elseif ($result.AvgLatencyMs -gt 5) { "percent-medium" } 
                            else { "percent-low" }
        } else {
            $latencyDisplay = "-"
            $latencyClass = ""
        }
        
        # Create decision badge
        $decisionBadge = ""
        if ($result.Decision -like "*Upgrade*") {
            $decisionBadge = "<span class='badge badge-warning'>⬆️ $($result.Decision)</span>"
        } elseif ($result.Decision -like "*Downgrade*") {
            $decisionBadge = "<span class='badge badge-info'>⬇️ $($result.Decision)</span>"
        } elseif ($result.Decision -eq "Stay (latency-sensitive)") {
            $decisionBadge = "<span class='badge badge-success'>✅ Stay (latency-sensitive)</span>"
        } elseif ($result.Decision -eq "Stay") {
            $decisionBadge = "<span class='badge badge-success'>✅ $($result.Decision)</span>"
        } elseif ($result.Decision -eq "Tier not handled") {
            $decisionBadge = "<span class='badge badge-secondary'>⚠️ $($result.Decision)</span>"
        } else {
            $decisionBadge = "<span class='badge badge-secondary'>$($result.Decision)</span>"
        }
        
        # Custom size badge
        $customBadge = if ($result.CustomSize -eq "Yes") { "<span class='badge badge-purple'>Custom</span>" } else { "" }
        
        # Format cost with color highlighting if high
        $costClass = if ($result.EstMonthlyTotalCost -gt 10) { "percent-high" } elseif ($result.EstMonthlyTotalCost -gt 1) { "percent-medium" } else { "" }
        $costDisplay = if ($result.EstMonthlyTotalCost -gt 0) { "`$$($result.EstMonthlyTotalCost.ToString('F2'))" } else { "-" }
        
        # Burst operations display
        $burstDisplay = if ($result.BurstOperations -gt 0) { 
            "<span class='badge badge-warning'>$([math]::Round($result.BurstOperations, 0).ToString("N0"))</span>" 
        } else { 
            "-" 
        }
        
        # Cost Difference display - context-aware based on disk type and recommendation
        $costDiffClass = ""
        $costDiffDisplay = "-"
        $costDiffSortValue = 0  # Numeric value for sorting
        
        # Determine what comparison to show based on SKU and recommendation
        if ($result.SKU -eq "StandardSSD_LRS" -and $result.Decision -like "*Premium*") {
            # Standard SSD with Premium upgrade recommendation - show best Premium option vs SSD comparison
            $costDiffSortValue = $result.CostDiffSSDtoBestPremium
            $absDiff = [math]::Abs($result.CostDiffSSDtoBestPremium)
            $premiumLabel = $result.BestPremiumOption
            
            if ($result.CostDiffSSDtoBestPremium -lt -5) {
                # Premium would save significant money
                $costDiffClass = "percent-low"
                $costDiffDisplay = "<span class='badge badge-success'>$premiumLabel saves `$$($absDiff.ToString('F2'))</span>"
            } elseif ($result.CostDiffSSDtoBestPremium -lt 0) {
                # Premium would save some money
                $costDiffClass = "percent-low"
                $costDiffDisplay = "<span class='badge badge-info'>$premiumLabel saves `$$($absDiff.ToString('F2'))</span>"
            } elseif ($result.CostDiffSSDtoBestPremium -le 10) {
                # Premium slightly more expensive
                $costDiffClass = "percent-medium"
                $costDiffDisplay = "<span class='badge badge-warning'>$premiumLabel +`$$($absDiff.ToString('F2'))</span>"
            } else {
                # Premium significantly more expensive
                $costDiffClass = "percent-high"
                $costDiffDisplay = "<span class='badge badge-danger'>$premiumLabel +`$$($absDiff.ToString('F2'))</span>"
            }
        }
        elseif (($result.SKU -eq "Standard_LRS" -or $result.SKU -eq "StandardSSD_LRS" -or $result.Decision -like "*Downgrade*HDD*" -or $result.Decision -like "*Standard SSD*") -and $result.CostSavingsHDDtoSSD -ne 0) {
            # HDD vs Standard SSD comparison
            $absDiff = [math]::Abs($result.CostSavingsHDDtoSSD)
            $costDiffSortValue = $result.CostSavingsHDDtoSSD  # Use actual value for sorting (positive = HDD costs more)
            
            if ($result.CostSavingsHDDtoSSD -gt 5) {
                # HDD significantly more expensive - recommend SSD
                $costDiffClass = "percent-high"
                $costDiffDisplay = "<span class='badge badge-danger'>HDD +`$$($absDiff.ToString('F2'))</span>"
            } elseif ($result.CostSavingsHDDtoSSD -gt 0) {
                # HDD slightly more expensive
                $costDiffClass = "percent-medium"
                $costDiffDisplay = "<span class='badge badge-warning'>HDD +`$$($absDiff.ToString('F2'))</span>"
            } elseif ($result.CostSavingsHDDtoSSD -lt -5) {
                # SSD significantly more expensive - HDD is cheaper
                $costDiffClass = ""
                $costDiffDisplay = "<span class='badge badge-info'>SSD +`$$($absDiff.ToString('F2'))</span>"
            } else {
                # SSD slightly more expensive
                $costDiffClass = ""
                $costDiffDisplay = "SSD +`$$($absDiff.ToString('F2'))"
            }
        }
        
        $html += @"

                    <tr class="$rowClass">
                        <td><strong>$($result.Disk)</strong></td>
                        <td>$($result.ResourceGroup)</td>
                        <td>$($result.SKU)</td>
                        <td class="number-cell">$($result.ActualSizeGiB) GiB</td>
                        <td class="number-cell">$($result.BilledSizeGiB) GiB</td>
                        <td>$($result.BillingTier)</td>
                        <td>$customBadge</td>
                        <td class="number-cell $iopsClass">$($result.PercentIOPSAbove)%</td>
                        <td class="number-cell $mbpsClass">$($result.PercentMBpsAbove)%</td>
                        <td class="number-cell $latencyClass">$latencyDisplay</td>
                        <td class="number-cell">$([math]::Round($result.Transactions, 0).ToString("N0"))</td>
                        <td class="number-cell $costDiffClass" data-sort-value="$costDiffSortValue">$costDiffDisplay</td>
                        <td>$decisionBadge</td>
                    </tr>
"@
    }
    
    $html += @"
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <p>Azure Managed Disk Analysis Report | Generated by Emergent Software</p>
            <p>Analysis Period: $($analysisWindowStart.ToString('yyyy-MM-dd HH:mm')) to $($analysisWindowEnd.ToString('yyyy-MM-dd HH:mm')) ($DaysToInspect days)</p>
            $(if ($DaysToInspect -lt 30) { "<p><strong>Note:</strong> All cost estimates are projected to 30-day monthly values based on observed usage patterns.</p>" } else { "" })
        </div>
    </div>
    
    <script>
        // Initialize counts on page load
        window.addEventListener('DOMContentLoaded', function() {
            updateCount();
        });
        
        // Sort table by column
        let sortDirection = {};
        function sortTable(columnIndex) {
            const table = document.getElementById('diskTable');
            const tbody = table.tBodies[0];
            const rows = Array.from(tbody.rows);
            
            // Toggle sort direction
            if (!sortDirection[columnIndex]) sortDirection[columnIndex] = 'asc';
            else sortDirection[columnIndex] = sortDirection[columnIndex] === 'asc' ? 'desc' : 'asc';
            
            const isAscending = sortDirection[columnIndex] === 'asc';
            
            // Remove sort indicators from all headers
            const headers = table.querySelectorAll('thead tr:first-child th');
            headers.forEach(th => {
                th.classList.remove('sort-asc', 'sort-desc');
            });
            
            // Add sort indicator to current header
            headers[columnIndex].classList.add(isAscending ? 'sort-asc' : 'sort-desc');
            
            // Sort rows
            rows.sort((a, b) => {
                let aValue = a.cells[columnIndex].textContent.trim();
                let bValue = b.cells[columnIndex].textContent.trim();
                
                // Check for data-sort-value attribute (used for Cost Diff column)
                const aSortAttr = a.cells[columnIndex].getAttribute('data-sort-value');
                const bSortAttr = b.cells[columnIndex].getAttribute('data-sort-value');
                
                if (aSortAttr !== null && bSortAttr !== null) {
                    const aNum = parseFloat(aSortAttr);
                    const bNum = parseFloat(bSortAttr);
                    return isAscending ? aNum - bNum : bNum - aNum;
                }
                
                // Remove common formatting for numeric comparison
                aValue = aValue.replace(/[,$%]/g, '').replace(' GiB', '');
                bValue = bValue.replace(/[,$%]/g, '').replace(' GiB', '');
                
                // Try numeric comparison first
                const aNum = parseFloat(aValue);
                const bNum = parseFloat(bValue);
                
                if (!isNaN(aNum) && !isNaN(bNum)) {
                    return isAscending ? aNum - bNum : bNum - aNum;
                }
                
                // Fall back to string comparison
                return isAscending ? 
                    aValue.localeCompare(bValue) : 
                    bValue.localeCompare(aValue);
            });
            
            // Reappend sorted rows
            rows.forEach(row => tbody.appendChild(row));
        }
        
        // Filter table based on all filter inputs
        function filterTable() {
            const table = document.getElementById('diskTable');
            const tbody = table.tBodies[0];
            const filterRow = table.querySelectorAll('.filter-row input');
            const filters = Array.from(filterRow).map(input => input.value.toLowerCase());
            
            let visibleCount = 0;
            
            Array.from(tbody.rows).forEach(row => {
                let showRow = true;
                
                filters.forEach((filter, index) => {
                    if (filter && row.cells[index]) {
                        const cellText = row.cells[index].textContent.toLowerCase();
                        if (!cellText.includes(filter)) {
                            showRow = false;
                        }
                    }
                });
                
                row.style.display = showRow ? '' : 'none';
                if (showRow) visibleCount++;
            });
            
            updateCount(visibleCount);
        }
        
        // Clear all filter inputs
        function clearAllFilters() {
            const filterInputs = document.querySelectorAll('.filter-input');
            filterInputs.forEach(input => input.value = '');
            filterTable();
        }
        
        // Update visible/total count
        function updateCount(visible) {
            const table = document.getElementById('diskTable');
            const tbody = table.tBodies[0];
            const total = tbody.rows.length;
            
            if (visible === undefined) {
                visible = Array.from(tbody.rows).filter(row => row.style.display !== 'none').length;
            }
            
            document.getElementById('visibleCount').textContent = visible;
            document.getElementById('totalCount').textContent = total;
        }
        
        // Export filtered results to CSV
        function exportToCSV() {
            const table = document.getElementById('diskTable');
            const headers = Array.from(table.querySelectorAll('thead tr:first-child th'))
                .map(th => th.textContent.trim().replace(/[⇅▲▼]/g, '').trim());
            
            const visibleRows = Array.from(table.tBodies[0].rows)
                .filter(row => row.style.display !== 'none');
            
            let csv = headers.map(h => '"' + h + '"').join(',') + '\\n';
            
            visibleRows.forEach(row => {
                const rowData = Array.from(row.cells).map(cell => {
                    let text = cell.textContent.trim();
                    // Remove emoji and extra whitespace
                    text = text.replace(/[🔍⬆️⬇️✅⚠️💸]/g, '').trim();
                    return '"' + text.replace(/"/g, '""') + '"';
                });
                csv += rowData.join(',') + '\\n';
            });
            
            // Download CSV
            const blob = new Blob([csv], { type: 'text/csv' });
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'disk-analysis-filtered-' + new Date().toISOString().slice(0,10) + '.csv';
            a.click();
            window.URL.revokeObjectURL(url);
        }
    </script>
</body>
</html>
"@
    
    $html | Set-Content -Path $OutputPath -Encoding UTF8
}

#endregion

#region Output

# Display results
Write-Host "`n=== Analysis Results ===" -ForegroundColor Cyan
$results | Sort-Object Subscription, ResourceGroup, Disk | Format-Table -AutoSize

# Export to JSON, CSV, and HTML with timestamp
Write-Host "Exporting results..." -ForegroundColor Cyan
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonPath = Join-Path $scriptDir "$OutputPrefix-$timestamp.json"
$csvPath = Join-Path $scriptDir "$OutputPrefix-$timestamp.csv"
$htmlPath = Join-Path $scriptDir "$OutputPrefix-$timestamp.html"

$results | ConvertTo-Json -Depth 4 | Set-Content $jsonPath
$results | Export-Csv $csvPath -NoTypeInformation
New-HtmlReport -Results $results -OutputPath $htmlPath

Write-Host "  JSON: $jsonPath" -ForegroundColor Green
Write-Host "  CSV:  $csvPath" -ForegroundColor Green
Write-Host "  HTML: $htmlPath" -ForegroundColor Green

# Calculate and display execution time
$scriptEndTime = Get-Date
$executionTime = $scriptEndTime - $scriptStartTime
$timeString = if ($executionTime.TotalMinutes -ge 1) {
    "{0:N0} minutes {1:N0} seconds" -f [math]::Floor($executionTime.TotalMinutes), $executionTime.Seconds
} else {
    "{0:N1} seconds" -f $executionTime.TotalSeconds
}

Write-Host "`n⏱️  Total execution time: $timeString" -ForegroundColor Magenta

#endregion