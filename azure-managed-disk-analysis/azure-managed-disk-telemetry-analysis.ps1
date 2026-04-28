<#
.SYNOPSIS
    Analyzes Azure managed disk performance telemetry to identify optimization opportunities.

.DESCRIPTION
    This script retrieves Azure managed disk metrics from Azure Monitor and analyzes their performance over a specified time window.
    It identifies disks that could benefit from tier changes (upgrade/downgrade) based on:
    - Performance metrics (IOPS, throughput, latency)
    - Cost optimization opportunities
    - Utilization patterns
    
    The script generates JSON and CSV reports with detailed metrics and recommendations.
    Use New-DiskAnalysisHtmlReport.ps1 to generate an interactive HTML report from the JSON output.

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
    Prefix for output files. Two files will be generated:
    - {OutputPrefix}-{timestamp}.json - Full analysis results in JSON format
    - {OutputPrefix}-{timestamp}.csv - Analysis results in CSV format
    Default is "disk-analysis".
    
    To generate an HTML report, run:
    .\New-DiskAnalysisHtmlReport.ps1 -JsonPath "{OutputPrefix}-{timestamp}.json"

.EXAMPLE
    .\azure-managed-disk-telemetry-analysis.ps1
    
    Analyzes all disks in the current subscription using default settings.
    Outputs JSON and CSV files with timestamp.

.EXAMPLE
    .\azure-managed-disk-telemetry-analysis.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -DaysToInspect 7
    
    Analyzes disks in the specified subscription over the last 7 days.

.EXAMPLE
    .\azure-managed-disk-telemetry-analysis.ps1 -ExceedanceThreshold 0.10 -OutputPrefix "weekly-report"
    
    Uses a 10% exceedance threshold and generates reports with custom filenames.
    
.EXAMPLE
    # Run analysis and immediately generate HTML report
    .\azure-managed-disk-telemetry-analysis.ps1
    .\New-DiskAnalysisHtmlReport.ps1 -JsonPath "disk-analysis-20250115-120000.json"

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
    
    # Standard HDD (S-series), Standard SSD (E-series), and Premium SSD (P-series) tier sizes
    $tierSizes = @{
        "S4" = 32; "E4" = 32; "P4" = 32
        "S6" = 64; "E6" = 64; "P6" = 64
        "S10" = 128; "E10" = 128; "P10" = 128
        "S15" = 256; "E15" = 256; "P15" = 256
        "S20" = 512; "E20" = 512; "P20" = 512
        "S30" = 1024; "E30" = 1024; "P30" = 1024
        "S40" = 2048; "E40" = 2048; "P40" = 2048
        "S50" = 4096; "E50" = 4096; "P50" = 4096
        "S60" = 8192; "E60" = 8192; "P60" = 8192
        "S70" = 16384; "E70" = 16384; "P70" = 16384
        "S80" = 32767; "E80" = 32767; "P80" = 32768
        # Premium SSD has additional smaller tiers
        "P1" = 4; "P2" = 8; "P3" = 16
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
    # Premium SSD has additional smaller tiers at 4, 8, 16 GB
    $tiers = @(
        @{Name="P1/E1"; MaxSize=4; BilledSize=4},
        @{Name="P2/E2"; MaxSize=8; BilledSize=8},
        @{Name="P3/E3"; MaxSize=16; BilledSize=16},
        @{Name="S4/E4/P4"; MaxSize=32; BilledSize=32},
        @{Name="S6/E6/P6"; MaxSize=64; BilledSize=64},
        @{Name="S10/E10/P10"; MaxSize=128; BilledSize=128},
        @{Name="S15/E15/P15"; MaxSize=256; BilledSize=256},
        @{Name="S20/E20/P20"; MaxSize=512; BilledSize=512},
        @{Name="S30/E30/P30"; MaxSize=1024; BilledSize=1024},
        @{Name="S40/E40/P40"; MaxSize=2048; BilledSize=2048},
        @{Name="S50/E50/P50"; MaxSize=4096; BilledSize=4096},
        @{Name="S60/E60/P60"; MaxSize=8192; BilledSize=8192},
        @{Name="S70/E70/P70"; MaxSize=16384; BilledSize=16384},
        @{Name="S80/E80/P80"; MaxSize=32768; BilledSize=32768}
    )
    
    foreach ($tier in $tiers) {
        if ($ActualSizeGB -le $tier.MaxSize) {
            # Determine tier prefix based on disk type
            $tierPrefix = if ($DiskType -eq "StandardSSD_LRS") { "E" } 
                         elseif ($DiskType -eq "Premium_LRS" -or $DiskType -eq "PremiumV2_LRS") { "P" } 
                         else { "S" }
            
            # Extract tier number from the appropriate position in the tier name
            $tierParts = $tier.Name.Split('/')
            $tierPart = $tierParts | Where-Object { $_ -like "$tierPrefix*" } | Select-Object -First 1
            if ($tierPart) {
                $tierNumber = $tierPart.Substring(1)
            } else {
                # Fallback: use first tier part
                $tierNumber = $tierParts[0].Substring(1)
            }
            
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
            Write-Host "               Possible causes: Disk unattached, VM stopped/deallocated, or newly created disk" -ForegroundColor DarkGray
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
        "--query","[].{id:id,name:name,rg:resourceGroup,sku:sku.name,diskSizeGB:diskSizeGB,perfPlus:supportedCapabilities.performancePlus,expandedIops:diskIOPSReadWrite,expandedMBps:diskMBpsReadWrite,managedBy:managedBy,osType:osType}"
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
    $isOsDisk = ($null -ne $disk.osType -and $disk.osType -ne "")
    
    # Determine the billing tier and whether it's a custom size
    $billingInfo = $null
    $size = $actualSize
    $isCustomSize = $false
    $billingTierName = "N/A"
    
    if ($tier -eq "Standard_LRS" -or $tier -eq "StandardSSD_LRS" -or $tier -eq "Premium_LRS") {
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
        "Premium_LRS" { Get-SkuSpec $premiumSpecs $size }
        default { $null }
    }
    
    # Fetch performance telemetry
    $telemetry = Get-DiskTelemetry -ResourceId $disk.id
    
    # Provide context if no metrics were retrieved
    if ($telemetry.Samples.Count -eq 0) {
        if (-not $disk.managedBy) {
            Write-Host "      Disk is unattached (no VM) - metrics not available" -ForegroundColor DarkGray
        } else {
            Write-Host "      No metric samples retrieved - VM may have been stopped during analysis period" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "      Retrieved $($telemetry.Samples.Count) metric samples" -ForegroundColor DarkGray
    }
    
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
        $metricsStatus = if ($telemetry.Samples.Count -eq 0) {
            if (-not $disk.managedBy) { "Unattached" } else { "No Metrics" }
        } else { "OK" }
        
        [pscustomobject]@{
            Disk=$disk.name; ResourceGroup=$disk.rg; Subscription=$disk.subscriptionId
            SKU=$tier; ActualSizeGiB=$actualSize; BilledSizeGiB=$size; BillingTier=$billingTierName
            CustomSize=if ($isCustomSize) { "Yes" } else { "No" }
            Samples=$telemetry.Samples.Count
            MetricsStatus=$metricsStatus
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
            if ($hddBaseline -and -not $isOsDisk) {
                $performanceOk = (
                    (Get-PercentAbove $telemetry.Samples "IOPS" $hddBaseline.MaxIOPS) -le $ExceedanceThreshold -and
                    (Get-PercentAbove $telemetry.Samples "MBps" $hddBaseline.MaxMBps) -le $ExceedanceThreshold
                )
                
                # Check if latency indicates need for SSD performance
                # If latency > 5ms, the disk is experiencing slower response times and should stay on SSD
                $latencyRequiresSSD = $avgLatencyMs -gt 5
                
                # Calculate potential savings (costSavingsHDDtoSSD is negative when HDD is cheaper)
                $potentialSavings = [math]::Abs($costSavingsHDDtoSSD)
                
                # Only recommend downgrade if:
                # 1. Not an OS disk
                # 2. HDD would be cheaper (costSavingsHDDtoSSD is negative)
                # 3. Savings are at least $5/month
                # 4. Performance is acceptable on HDD
                # 5. Latency is low enough (<= 5ms) that HDD would be acceptable
                $downgrade = $performanceOk -and ($costSavingsHDDtoSSD -lt 0) -and ($potentialSavings -ge 5) -and (-not $latencyRequiresSSD)
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
                Write-Host "      Recommendation: $decision (data disk, underutilized) - Would save `$$([math]::Round([math]::Abs($costSavingsHDDtoSSD),2))/month" -ForegroundColor Cyan
            }
            elseif ($performanceOk -and ($costSavingsHDDtoSSD -lt 0) -and $avgLatencyMs -gt 5) {
                # Would save money with HDD but latency indicates need for SSD performance
                $decision = "Stay (latency-sensitive)"
                Write-Host "      Recommendation: $decision - Latency ($avgLatencyMs ms) indicates need for SSD performance" -ForegroundColor Green
            }
            elseif ($performanceOk -and ($costSavingsHDDtoSSD -lt 0) -and $isOsDisk) {
                # Would save money with HDD but it's an OS disk
                $decision = "Stay (OS disk)"
                Write-Host "      Recommendation: $decision - OS disks should not use Standard HDD" -ForegroundColor Green
            }
            elseif ($performanceOk -and ($costSavingsHDDtoSSD -lt 0) -and ([math]::Abs($costSavingsHDDtoSSD) -lt 5)) {
                # Would save money with HDD but savings are less than $5/month
                $decision = "Stay (minimal savings)"
                Write-Host "      Recommendation: $decision - Potential savings <`$5/month (HDD would save `$$([math]::Round([math]::Abs($costSavingsHDDtoSSD),2))/month)" -ForegroundColor Green
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
    
    # Determine metrics availability status
    $metricsStatus = if ($telemetry.Samples.Count -eq 0) {
        if (-not $disk.managedBy) { "Unattached" } else { "No Metrics" }
    } else { "OK" }
    
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
        MetricsStatus=$metricsStatus
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



# Display results
Write-Host "`n=== Analysis Results ===" -ForegroundColor Cyan
$results | Sort-Object Subscription, ResourceGroup, Disk | Format-Table -AutoSize

# Display results
Write-Host "`n=== Analysis Results ===" -ForegroundColor Cyan
$results | Sort-Object Subscription, ResourceGroup, Disk | Format-Table -AutoSize

# Export to JSON and CSV with timestamp
Write-Host "Exporting results..." -ForegroundColor Cyan
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonPath = Join-Path $scriptDir "$OutputPrefix-$timestamp.json"
$csvPath = Join-Path $scriptDir "$OutputPrefix-$timestamp.csv"

$results | ConvertTo-Json -Depth 4 | Set-Content $jsonPath
$results | Export-Csv $csvPath -NoTypeInformation

Write-Host "  JSON: $jsonPath" -ForegroundColor Green
Write-Host "  CSV:  $csvPath" -ForegroundColor Green
Write-Host ""
Write-Host "To generate an HTML report, run:" -ForegroundColor Cyan
Write-Host "  .\New-DiskAnalysisHtmlReport.ps1 -JsonPath '$jsonPath'" -ForegroundColor Yellow

# Calculate and display execution time
$scriptEndTime = Get-Date
$executionTime = $scriptEndTime - $scriptStartTime
$timeString = if ($executionTime.TotalMinutes -ge 1) {
    "{0:N0} minutes {1:N0} seconds" -f [math]::Floor($executionTime.TotalMinutes), $executionTime.Seconds
} else {
    "{0:N1} seconds" -f $executionTime.TotalSeconds
}

Write-Host "`n⏱️  Total execution time: $timeString" -ForegroundColor Magenta