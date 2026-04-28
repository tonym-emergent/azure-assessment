<#
.SYNOPSIS
    Analyzes Azure Recovery Services Vaults VM backup configurations to identify high-churn VMs and estimate backup storage consumption.

.DESCRIPTION
    This script queries all Recovery Services Vaults in specified subscriptions and analyzes Azure IaaS VM backups:
    - Backup policies and schedules
    - Protected VMs and their backup status
    - Backup storage size estimates based on recent backup jobs
    - Daily snapshot growth to calculate churn rate
    - Risk assessment based on backup patterns and health status
    
    IMPORTANT: Azure does not expose per-VM total backup storage size through programmatic APIs.
    The "Backup Size" shown in this report is based on the most recent backup job's data transfer size,
    which may not accurately represent the total cumulative storage consumed by all retention points.
    
    For accurate total backup storage consumption, please refer to:
    - Azure Portal > Recovery Services Vault > Backup Items > Storage consumption
    - Azure Cost Management billing reports
    
    Note: This script currently focuses only on Azure VM (IaaS) backups and does not analyze SQL, SAP HANA, or other workload types.
    
    The script generates HTML, CSV, and JSON reports highlighting VMs with high backup storage consumption
    and high churn rates that may benefit from policy optimization or investigation.

.PARAMETER DaysToInspect
    Number of days of historical backup data to analyze. Default is 30 days.

.PARAMETER HighChurnThresholdGB
    Daily churn threshold in GB to flag a VM as high-churn. Default is 50 GB/day.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to analyze. If not specified, uses the current subscription context.

.PARAMETER OutputPrefix
    Prefix for output files. Default is "vault-analysis".

.EXAMPLE
    .\recovery-services-vault-analysis.ps1
    
    Analyzes all Recovery Services Vaults in the current subscription using default settings.

.EXAMPLE
    .\recovery-services-vault-analysis.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -DaysToInspect 14
    
    Analyzes vaults in the specified subscription over the last 14 days.

.EXAMPLE
    .\recovery-services-vault-analysis.ps1 -HighChurnThresholdGB 100 -OutputPrefix "monthly-backup-report"
    
    Uses a 100 GB/day high-churn threshold and generates reports with custom filenames.

.EXAMPLE
    .\recovery-services-vault-analysis.ps1 -VMName "vmaderant001","vmsql001" -DaysToInspect 7
    
    Analyzes only the specified VMs and shows detailed recovery point information.

.NOTES
    Requires Azure CLI (az) to be installed and authenticated.
    Requires read access to Recovery Services Vaults and backup data in the target subscriptions.
    
    LIMITATION: Per-VM total backup storage size is not available through Azure CLI or APIs.
    The script uses the most recent backup job size as an approximation.
    
    STORAGE REDUNDANCY: The "Actual Vault Storage" metric shows the total billable storage.
    For RA-GRS vaults, this is the primary storage size (replication is included in billing but not doubled).
#>

param(
    [int]$DaysToInspect = 30,
    [double]$HighChurnThresholdGB = 50,
    [string[]]$SubscriptionId,
    [string]$OutputPrefix = "vault-analysis",
    [string[]]$VMName
)

#region Helper Functions

<#
.SYNOPSIS
    Invokes Azure CLI and returns raw stdout output.
#>
function Invoke-AzCliRaw {
    param([string[]]$Arguments)
    $azPath = (Get-Command az -ErrorAction Stop).Source
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $azPath
    
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
        if ($stderr) { Write-Warning "Azure CLI warning: $($stderr.Trim())" }
        return $null
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
    try {
        return $json | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse JSON response from: az $($Arguments -join ' ')"
        return $null
    }
}

<#
.SYNOPSIS
    Calculates the average daily churn based on backup size changes.
#>
function Get-DailyChurnRate {
    param($BackupJobs, [int]$Days)
    
    if (-not $BackupJobs -or $BackupJobs.Count -lt 2) {
        return [PSCustomObject]@{
            DailyChurnGB = 0
            TotalBackupSizeGB = 0
            JobCount = 0
        }
    }
    
    # Sort jobs by date
    $sortedJobs = $BackupJobs | Sort-Object { [DateTime]$_.properties.endTime }
    
    # Calculate size differences between consecutive backups
    $churnSamples = @()
    for ($i = 1; $i -lt $sortedJobs.Count; $i++) {
        $prevJob = $sortedJobs[$i - 1]
        $currJob = $sortedJobs[$i]
        
        # Try multiple possible property paths for backup size
        $prevSizeStr = $null
        $currSizeStr = $null
        
        # Check different property paths where size might be stored
        if ($prevJob.properties.extendedInfo.propertyBag.'Backup Size') {
            $prevSizeStr = $prevJob.properties.extendedInfo.propertyBag.'Backup Size'
        } elseif ($prevJob.properties.extendedInfo.propertyBag.'Data Transferred') {
            $prevSizeStr = $prevJob.properties.extendedInfo.propertyBag.'Data Transferred'
        }
        
        if ($currJob.properties.extendedInfo.propertyBag.'Backup Size') {
            $currSizeStr = $currJob.properties.extendedInfo.propertyBag.'Backup Size'
        } elseif ($currJob.properties.extendedInfo.propertyBag.'Data Transferred') {
            $currSizeStr = $currJob.properties.extendedInfo.propertyBag.'Data Transferred'
        }
        
        if ($prevSizeStr -and $currSizeStr) {
            # Parse backup size (format: "123.45 GB" or "1.23 TB" or "123.45 MB")
            $prevSize = [double]($prevSizeStr -replace '[^0-9.]','')
            $currSize = [double]($currSizeStr -replace '[^0-9.]','')
            
            # Convert to GB
            if ($prevSizeStr -match 'TB') {
                $prevSize = $prevSize * 1024
            } elseif ($prevSizeStr -match 'MB') {
                $prevSize = $prevSize / 1024
            }
            
            if ($currSizeStr -match 'TB') {
                $currSize = $currSize * 1024
            } elseif ($currSizeStr -match 'MB') {
                $currSize = $currSize / 1024
            }
            
            # Calculate churn (absolute difference)
            $churn = [math]::Abs($currSize - $prevSize)
            $churnSamples += $churn
        }
    }
    
    # Get latest backup size
    $latestSize = 0
    $latestJob = $sortedJobs[-1]
    $latestSizeStr = $null
    
    if ($latestJob.properties.extendedInfo.propertyBag.'Backup Size') {
        $latestSizeStr = $latestJob.properties.extendedInfo.propertyBag.'Backup Size'
    } elseif ($latestJob.properties.extendedInfo.propertyBag.'Data Transferred') {
        $latestSizeStr = $latestJob.properties.extendedInfo.propertyBag.'Data Transferred'
    }
    
    if ($latestSizeStr) {
        $latestSize = [double]($latestSizeStr -replace '[^0-9.]','')
        if ($latestSizeStr -match 'TB') {
            $latestSize = $latestSize * 1024
        } elseif ($latestSizeStr -match 'MB') {
            $latestSize = $latestSize / 1024
        }
    }
    
    $avgChurn = if ($churnSamples.Count -gt 0) {
        ($churnSamples | Measure-Object -Average).Average
    } else { 0 }
    
    return [PSCustomObject]@{
        DailyChurnGB = [math]::Round($avgChurn, 2)
        TotalBackupSizeGB = [math]::Round($latestSize, 2)
        JobCount = $BackupJobs.Count
    }
}

<#
.SYNOPSIS
    Calculates the Azure Backup protected instance tier based on source data size.
    
.DESCRIPTION
    Azure Backup bills VMs based on protected instance tiers:
    - Instance 1: 0-512 GB
    - Instance 2: 512-1024 GB (512 GB + 512 GB)
    - Instance 3: 1024-1536 GB (1024 GB + 512 GB)
    - Instance 4: 1536-2048 GB (1536 GB + 512 GB)
    And continues in 512 GB increments.
    
.PARAMETER SizeGB
    The total source data size in GB (sum of all disk sizes attached to the VM).
#>
function Get-BackupInstanceTier {
    param([double]$SizeGB)
    
    if ($SizeGB -eq 0) { return 0 }
    
    # Instance tier is calculated as: ceiling(SizeGB / 512)
    # This means every 512 GB (or portion thereof) counts as one instance
    $tier = [Math]::Ceiling($SizeGB / 512)
    
    return [int]$tier
}

<#
.SYNOPSIS
    Formats bytes to human-readable format (GB, TB, etc.)
#>
function Format-ByteSize {
    param([long]$Bytes)
    
    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    } elseif ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    } elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    } else {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
}

<#
.SYNOPSIS
    Gets the total backup storage consumption for a Recovery Services Vault.
    
.DESCRIPTION
    Queries the vault's usages API to retrieve actual total backup storage consumption
    by storage redundancy type (GRS, LRS, RAGRS, ZRS, RAGZRS, Archive).
    
.RETURNS
    PSCustomObject with storage usage by type in bytes and formatted strings.
#>
function Get-VaultStorageUsage {
    param(
        [string]$VaultName,
        [string]$VaultResourceGroup,
        [string]$SubscriptionId
    )
    
    try {
        $usagesUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$VaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$VaultName/usages?api-version=2024-04-01"
        
        $usages = Invoke-AzCliJson @(
            "rest",
            "--method","get",
            "--url",$usagesUrl
        )
        
        $storageTypes = @{
            GRS = 0
            LRS = 0
            RAGRS = 0
            ZRS = 0
            RAGZRS = 0
            ArchiveGRS = 0
            ArchiveLRS = 0
        }
        
        if ($usages -and $usages.value) {
            foreach ($usage in $usages.value) {
                $name = $usage.name.value
                switch ($name) {
                    "GRSStorageUsage" { $storageTypes.GRS = $usage.currentValue }
                    "LRSStorageUsage" { $storageTypes.LRS = $usage.currentValue }
                    "RAGRSStorageUsage" { $storageTypes.RAGRS = $usage.currentValue }
                    "ZRSStorageUsage" { $storageTypes.ZRS = $usage.currentValue }
                    "RAGZRSStorageUsage" { $storageTypes.RAGZRS = $usage.currentValue }
                    "ArchiveGRSStorageUsage" { $storageTypes.ArchiveGRS = $usage.currentValue }
                    "ArchiveLRSStorageUsage" { $storageTypes.ArchiveLRS = $usage.currentValue }
                }
            }
        }
        
        $totalBytes = $storageTypes.GRS + $storageTypes.LRS + $storageTypes.RAGRS + $storageTypes.ZRS + $storageTypes.RAGZRS + $storageTypes.ArchiveGRS + $storageTypes.ArchiveLRS
        
        return [PSCustomObject]@{
            TotalBytes = $totalBytes
            TotalGB = [math]::Round($totalBytes / 1GB, 2)
            TotalTB = [math]::Round($totalBytes / 1TB, 2)
            GRS_GB = [math]::Round($storageTypes.GRS / 1GB, 2)
            LRS_GB = [math]::Round($storageTypes.LRS / 1GB, 2)
            RAGRS_GB = [math]::Round($storageTypes.RAGRS / 1GB, 2)
            ZRS_GB = [math]::Round($storageTypes.ZRS / 1GB, 2)
            RAGZRS_GB = [math]::Round($storageTypes.RAGZRS / 1GB, 2)
            ArchiveGRS_GB = [math]::Round($storageTypes.ArchiveGRS / 1GB, 2)
            ArchiveLRS_GB = [math]::Round($storageTypes.ArchiveLRS / 1GB, 2)
            FormattedTotal = Format-ByteSize -Bytes $totalBytes
        }
    }
    catch {
        Write-Warning "Failed to get vault storage usage for $VaultName : $_"
        return [PSCustomObject]@{
            TotalBytes = 0
            TotalGB = 0
            TotalTB = 0
            GRS_GB = 0
            LRS_GB = 0
            RAGRS_GB = 0
            ZRS_GB = 0
            RAGZRS_GB = 0
            ArchiveGRS_GB = 0
            ArchiveLRS_GB = 0
            FormattedTotal = "N/A"
        }
    }
}

<#
.SYNOPSIS
    Gets the actual backup storage size for a protected item using Azure Monitor metrics.
    
.DESCRIPTION
    Attempts to query backup storage size. Note: Azure does not currently expose per-VM backup storage
    size through programmatic APIs. This function is included for future compatibility and will
    return 0 if no data is available. The script falls back to using the latest backup job size
    as an approximation.
    
.NOTES
    Azure Recovery Services Vaults do not expose BackupStorageSize as a metric.
    Per-VM storage size is only available through:
    - Azure Portal UI
    - Cost Management/Billing reports
    - Manual calculation from recovery point storage
#>
function Get-ActualBackupStorageSize {
    param(
        [string]$VaultName,
        [string]$VaultResourceGroup,
        [string]$SubscriptionId,
        [string]$ProtectedItemName
    )
    
    # Azure does not expose per-VM backup storage size through APIs
    # Return 0 to indicate no data available
    # The calling code will fall back to using backup job size estimates
    return 0
}

<#
.SYNOPSIS
    Gets recovery point details for a protected VM.
    
.DESCRIPTION
    Retrieves all recovery points for a VM backup and returns detailed information
    about each restore point including time, type, and tier status.
#>
function Get-RecoveryPointDetails {
    param(
        [string]$VaultName,
        [string]$VaultResourceGroup,
        [string]$SubscriptionId,
        [string]$ContainerName,
        [string]$ItemName
    )
    
    try {
        $recoveryPoints = Invoke-AzCliJson @(
            "backup","recoverypoint","list",
            "--container-name",$ContainerName,
            "--item-name",$ItemName,
            "--resource-group",$VaultResourceGroup,
            "--vault-name",$VaultName,
            "--backup-management-type","AzureIaasVM"
        )
        
        $rpDetails = @()
        if ($recoveryPoints) {
            foreach ($rp in $recoveryPoints) {
                $tiers = @()
                if ($rp.properties.recoveryPointTierDetails) {
                    $tiers = $rp.properties.recoveryPointTierDetails | ForEach-Object {
                        "$($_.type):$($_.status)"
                    }
                }
                
                $rpDetails += [PSCustomObject]@{
                    Name = $rp.name
                    Time = $rp.properties.recoveryPointTime
                    Type = $rp.properties.recoveryPointType
                    Tiers = ($tiers -join ", ")
                }
            }
        }
        
        return $rpDetails
    }
    catch {
        Write-Warning "Failed to get recovery points for $ItemName : $_"
        return @()
    }
}

#endregion

#region Initialization

$scriptStartTime = Get-Date

# Use current subscription if none specified
if (-not $SubscriptionId -or -not $SubscriptionId.Count) {
    $currentSub = Invoke-AzCliJson @("account","show")
    if ($currentSub) {
        $SubscriptionId = @($currentSub.id)
    } else {
        throw "Unable to determine current subscription. Please specify -SubscriptionId parameter."
    }
}

# Define analysis time window
$analysisWindowEnd = Get-Date
$analysisWindowStart = $analysisWindowEnd.AddDays(-$DaysToInspect)

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Azure Recovery Services Vault Backup Analysis               ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Analysis Period: $($analysisWindowStart.ToString('yyyy-MM-dd')) to $($analysisWindowEnd.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
Write-Host "High Churn Threshold: $HighChurnThresholdGB GB/day" -ForegroundColor Gray
Write-Host ""

#endregion

#region Vault Discovery and Data Collection

$allResults = @()
$vaultStorageInfo = @{}  # Track vault storage by vault name
$totalVaults = 0
$totalProtectedItems = 0

foreach ($sub in $SubscriptionId) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "📋 Processing Subscription: $sub" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    
    # Get all Recovery Services Vaults in the subscription
    $vaults = Invoke-AzCliJson @(
        "backup","vault","list",
        "--subscription",$sub
    )
    
    if (-not $vaults -or $vaults.Count -eq 0) {
        Write-Host "  ⚠️  No Recovery Services Vaults found" -ForegroundColor Yellow
        continue
    }
    
    $totalVaults += $vaults.Count
    Write-Host "  ✓ Found $($vaults.Count) Recovery Services Vault(s)" -ForegroundColor Green
    Write-Host ""
    
    foreach ($vault in $vaults) {
        $vaultName = $vault.name
        $vaultRg = $vault.resourceGroup
        
        Write-Host "  🔍 Analyzing Vault: $vaultName (RG: $vaultRg)" -ForegroundColor White
        
        # Get vault-level total storage usage
        Write-Host "    ├─ Querying vault storage usage..." -ForegroundColor Gray
        $vaultStorage = Get-VaultStorageUsage -VaultName $vaultName -VaultResourceGroup $vaultRg -SubscriptionId $sub
        Write-Host "    ├─ Vault Total Storage: $($vaultStorage.FormattedTotal) ($($vaultStorage.TotalGB) GB)" -ForegroundColor Cyan
        
        # Get backup policies for this vault
        $policies = Invoke-AzCliJson @(
            "backup","policy","list",
            "--vault-name",$vaultName,
            "--resource-group",$vaultRg,
            "--subscription",$sub
        )
        
        Write-Host "    ├─ Found $($policies.Count) backup policy/policies" -ForegroundColor Gray
        
        # Get all protected items (VMs) in this vault - filter for Azure VMs only
        $protectedItems = Invoke-AzCliJson @(
            "backup","item","list",
            "--vault-name",$vaultName,
            "--resource-group",$vaultRg,
            "--subscription",$sub,
            "--backup-management-type","AzureIaasVM"
        )
        
        if (-not $protectedItems -or $protectedItems.Count -eq 0) {
            Write-Host "    └─ No VM backups found" -ForegroundColor Gray
            Write-Host ""
            continue
        }
        
        $totalProtectedItems += $protectedItems.Count
        Write-Host "    ├─ Found $($protectedItems.Count) VM backup(s)" -ForegroundColor Gray
        
        # Filter by VM name if specified
        if ($VMName -and $VMName.Count -gt 0) {
            $protectedItems = $protectedItems | Where-Object { 
                $vmFriendlyName = $_.properties.friendlyName
                $VMName -contains $vmFriendlyName
            }
            
            if ($protectedItems.Count -eq 0) {
                Write-Host "    └─ No matching VMs found for filter: $($VMName -join ', ')" -ForegroundColor Yellow
                Write-Host ""
                continue
            }
            
            Write-Host "    ├─ Filtered to $($protectedItems.Count) matching VM(s)" -ForegroundColor Cyan
        }
        
        # Store vault storage info for reporting
        $vaultKey = "$sub|$vaultRg|$vaultName"
        $vaultStorageInfo[$vaultKey] = $vaultStorage
        
        # Analyze each protected item
        $itemCount = 0
        foreach ($item in $protectedItems) {
            $itemCount++
            $itemName = $item.properties.friendlyName
            $itemFullName = $item.name
            $containerFullName = $item.properties.containerName
            $containerName = if ($containerFullName) { $containerFullName.Split(';')[-1] } else { "N/A" }
            $workloadType = $item.properties.workloadType
            $policyId = $item.properties.policyId
            $policyName = if ($policyId) { $policyId.Split('/')[-1] } else { "N/A" }
            $sourceResourceId = $item.properties.sourceResourceId
            
            Write-Host "    ├─ [$itemCount/$($protectedItems.Count)] $itemName" -ForegroundColor DarkGray
            
            # Get VM disk information for instance tier calculation
            $vmDiskSizeGB = 0
            $instanceTier = 0
            if ($sourceResourceId) {
                $vmDetails = Invoke-AzCliJson @("vm","show","--ids",$sourceResourceId)
                if ($vmDetails -and $vmDetails.storageProfile) {
                    # Sum all disk sizes (OS + data disks)
                    if ($vmDetails.storageProfile.osDisk.diskSizeGB) {
                        $vmDiskSizeGB += $vmDetails.storageProfile.osDisk.diskSizeGB
                    }
                    if ($vmDetails.storageProfile.dataDisks) {
                        foreach ($disk in $vmDetails.storageProfile.dataDisks) {
                            if ($disk.diskSizeGB) {
                                $vmDiskSizeGB += $disk.diskSizeGB
                            }
                        }
                    }
                    $instanceTier = Get-BackupInstanceTier -SizeGB $vmDiskSizeGB
                }
            }
            
            # Get backup jobs for this item in the analysis window
            $jobs = Invoke-AzCliJson @(
                "backup","job","list",
                "--vault-name",$vaultName,
                "--resource-group",$vaultRg,
                "--subscription",$sub,
                "--status","Completed",
                "--operation","Backup",
                "--start-date",$analysisWindowStart.ToString("dd-MM-yyyy"),
                "--end-date",$analysisWindowEnd.ToString("dd-MM-yyyy")
            )
            
            # Filter jobs for this specific item and get detailed info for each
            if ($jobs) {
                $itemJobs = $jobs | Where-Object { 
                    $_.properties.entityFriendlyName -eq $itemName 
                }
                
                # Get detailed job info for each job (includes extendedInfo with backup size)
                $detailedJobs = @()
                foreach ($job in $itemJobs) {
                    $jobName = $job.name
                    $jobDetail = Invoke-AzCliJson @(
                        "backup","job","show",
                        "--name",$jobName,
                        "--vault-name",$vaultName,
                        "--resource-group",$vaultRg,
                        "--subscription",$sub
                    )
                    if ($jobDetail) {
                        $detailedJobs += $jobDetail
                    }
                }
                $itemJobs = $detailedJobs
            } else {
                $itemJobs = @()
            }
            
            # Calculate churn metrics from backup jobs (incremental backup sizes)
            $churnMetrics = Get-DailyChurnRate -BackupJobs $itemJobs -Days $DaysToInspect
            
            # Note: Azure does not expose per-VM total backup storage size through APIs
            # We use the most recent backup job size as an approximation
            $totalBackupSizeGB = $churnMetrics.TotalBackupSizeGB
            
            # If VMName filter is active, display individual backup job details
            if ($VMName -and $VMName.Count -gt 0 -and $itemJobs -and $itemJobs.Count -gt 0) {
                Write-Host "    │" -ForegroundColor DarkGray
                Write-Host "    │  📊 Backup Job Details (last $DaysToInspect days - $($itemJobs.Count) jobs):" -ForegroundColor Cyan
                
                $sortedJobs = $itemJobs | Sort-Object { [DateTime]$_.properties.endTime } -Descending
                foreach ($job in $sortedJobs) {
                    $jobEndTime = [DateTime]$job.properties.endTime
                    $backupSizeStr = "N/A"
                    $backupSizeGB = 0
                    
                    if ($job.properties.extendedInfo.propertyBag.'Backup Size') {
                        $backupSizeStr = $job.properties.extendedInfo.propertyBag.'Backup Size'
                    } elseif ($job.properties.extendedInfo.propertyBag.'Data Transferred') {
                        $backupSizeStr = $job.properties.extendedInfo.propertyBag.'Data Transferred'
                    }
                    
                    # Convert to GB for display
                    if ($backupSizeStr -ne "N/A") {
                        $sizeValue = [double]($backupSizeStr -replace '[^0-9.]','')
                        if ($backupSizeStr -match 'TB') {
                            $backupSizeGB = [math]::Round($sizeValue * 1024, 2)
                        } elseif ($backupSizeStr -match 'MB') {
                            $backupSizeGB = [math]::Round($sizeValue / 1024, 2)
                        } elseif ($backupSizeStr -match 'GB') {
                            $backupSizeGB = [math]::Round($sizeValue, 2)
                        }
                        $displaySize = "$backupSizeGB GB"
                    } else {
                        $displaySize = "N/A"
                    }
                    
                    Write-Host "    │    • $($jobEndTime.ToString('yyyy-MM-dd HH:mm')) - Size: $displaySize" -ForegroundColor Gray
                }
                Write-Host "    │" -ForegroundColor DarkGray
            }
            
            # Get recovery point count from backup jobs instead of querying recovery points
            # Querying recovery points can be problematic with container name formats
            $recoveryPointCount = 0
            $latestRecoveryPoint = "N/A"
            
            if ($itemJobs -and $itemJobs.Count -gt 0) {
                # Use job count as a proxy for recovery points
                $recoveryPointCount = $itemJobs.Count
                
                # Get the most recent backup job end time
                $sortedJobs = $itemJobs | Sort-Object { [DateTime]$_.properties.endTime } -Descending
                if ($sortedJobs -and $sortedJobs.Count -gt 0) {
                    $latestRecoveryPoint = $sortedJobs[0].properties.endTime
                }
            }
            
            # Determine status and risk level
            $status = $item.properties.protectionState
            $healthStatus = $item.properties.healthStatus
            
            $riskLevel = "Low"
            $flags = @()
            
            if ($churnMetrics.DailyChurnGB -ge $HighChurnThresholdGB) {
                $riskLevel = "High"
                $flags += "High Churn"
            } elseif ($churnMetrics.DailyChurnGB -ge ($HighChurnThresholdGB * 0.5)) {
                $riskLevel = "Medium"
                $flags += "Moderate Churn"
            }
            
            if ($totalBackupSizeGB -ge 1000) {
                $flags += "Large Backup (>1TB)"
                if ($riskLevel -eq "Low") { $riskLevel = "Medium" }
            }
            
            if ($healthStatus -ne "Passed") {
                $flags += "Health: $healthStatus"
                $riskLevel = "High"
            }
            
            # Create result object
            $result = [PSCustomObject]@{
                Subscription = $sub
                Vault = $vaultName
                ResourceGroup = $vaultRg
                VMName = $itemName
                Container = $containerName
                WorkloadType = $workloadType
                Policy = $policyName
                ProtectionState = $status
                HealthStatus = $healthStatus
                LatestRecoveryPoint = $latestRecoveryPoint
                VMDiskSizeGB = $vmDiskSizeGB
                InstanceTier = $instanceTier
                TotalBackupSizeGB = $totalBackupSizeGB
                DailyChurnGB = $churnMetrics.DailyChurnGB
                MonthlyChurnGB = [math]::Round($churnMetrics.DailyChurnGB * 30, 2)
                BackupJobCount = $churnMetrics.JobCount
                RecoveryPoints = $recoveryPointCount
                RiskLevel = $riskLevel
                Flags = ($flags -join ", ")
                RecommendedAction = if ($riskLevel -eq "High") { 
                    "Investigate high churn/backup issues" 
                } elseif ($riskLevel -eq "Medium") { 
                    "Review backup policy and retention" 
                } else { 
                    "No action needed" 
                }
                BackupJobs = $itemJobs  # Store job details for detailed reporting
            }
            
            $allResults += $result
        }
        
        Write-Host "    └─ Completed analysis for vault: $vaultName" -ForegroundColor DarkGray
        Write-Host ""
    }
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
Write-Host "✓ Discovery complete: $totalVaults vault(s), $totalProtectedItems VM backup(s)" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
Write-Host ""

if ($allResults.Count -eq 0) {
    Write-Warning "No backup data found to analyze. Exiting."
    return
}

#endregion

#region HTML Report Generation

<#
.SYNOPSIS
    Generates HTML report with styled table and highlighting for high-churn VMs.
#>
function New-HtmlReport {
    param($Results, [string]$OutputPath)
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Recovery Services Vault Analysis Report</title>
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
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
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
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            padding: 30px;
            background: #f8f9fa;
            border-bottom: 3px solid #e9ecef;
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
        
        .table-container {
            padding: 30px;
            overflow-x: auto;
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
        }
        
        .risk-high {
            background: #ffcccc !important;
            border-left: 4px solid #dc3545;
            color: #2c1a1a;
        }
        
        .risk-medium {
            background: #fff9db !important;
            border-left: 4px solid #ffc107;
            color: #2c2416;
        }
        
        .risk-low {
            background: #d4edda !important;
            border-left: 4px solid #28a745;
            color: #1e4620;
        }
        
        .badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.85em;
            font-weight: 600;
        }
        
        .badge-danger {
            background: #dc3545;
            color: white;
        }
        
        .badge-warning {
            background: #ffc107;
            color: #856404;
        }
        
        .badge-success {
            background: #28a745;
            color: white;
        }
        
        .badge-info {
            background: #17a2b8;
            color: white;
        }
        
        .number-cell {
            text-align: right;
            font-family: 'Courier New', monospace;
        }
        
        .footer {
            padding: 20px;
            text-align: center;
            background: #f8f9fa;
            color: #6c757d;
            font-size: 0.9em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🛡️ Azure Recovery Services Vault Analysis</h1>
            <p>Generated on $(Get-Date -Format "MMMM dd, yyyy 'at' HH:mm:ss")</p>
        </div>
"@

    # Calculate statistics
    $totalVMs = $Results.Count
    $highRisk = ($Results | Where-Object { $_.RiskLevel -eq "High" }).Count
    $mediumRisk = ($Results | Where-Object { $_.RiskLevel -eq "Medium" }).Count
    $lowRisk = ($Results | Where-Object { $_.RiskLevel -eq "Low" }).Count
    $totalBackupSize = [math]::Round(($Results | Measure-Object -Property TotalBackupSizeGB -Sum).Sum, 2)
    $totalDailyChurn = [math]::Round(($Results | Measure-Object -Property DailyChurnGB -Sum).Sum, 2)
    
    # Calculate actual vault storage totals
    $actualVaultStorageGB = 0
    $actualVaultStorageTB = 0
    foreach ($vaultInfo in $script:vaultStorageInfo.Values) {
        $actualVaultStorageGB += $vaultInfo.TotalGB
        $actualVaultStorageTB += $vaultInfo.TotalTB
    }
    $actualVaultStorageGB = [math]::Round($actualVaultStorageGB, 2)
    $actualVaultStorageTB = [math]::Round($actualVaultStorageTB, 2)
    
    $html += @"
        <div class="stats">
            <div class="stat-card">
                <div class="number">$totalVMs</div>
                <div class="label">Protected VMs</div>
            </div>
            <div class="stat-card">
                <div class="number" style="color: #dc3545;">$highRisk</div>
                <div class="label">High Risk</div>
            </div>
            <div class="stat-card">
                <div class="number" style="color: #ffc107;">$mediumRisk</div>
                <div class="label">Medium Risk</div>
            </div>
            <div class="stat-card">
                <div class="number" style="color: #28a745;">$lowRisk</div>
                <div class="label">Low Risk</div>
            </div>
            <div class="stat-card">
                <div class="number" style="color: #17a2b8;">$actualVaultStorageTB TB</div>
                <div class="label">Actual Vault Storage</div>
            </div>
            <div class="stat-card">
                <div class="number">$totalDailyChurn</div>
                <div class="label">Daily Churn (GB)</div>
            </div>
        </div>
        
        <div class="legend">
            <h3>📋 Risk Level Legend</h3>
            <div class="legend-items">
                <div class="legend-item">
                    <div class="legend-color" style="background: #ffcccc; border-left: 4px solid #dc3545;"></div>
                    <span><strong>High Risk</strong> - High churn rate (≥$HighChurnThresholdGB GB/day) or health issues</span>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #fff9db; border-left: 4px solid #ffc107;"></div>
                    <span><strong>Medium Risk</strong> - Moderate churn or large backup size</span>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #d4edda; border-left: 4px solid #28a745;"></div>
                    <span><strong>Low Risk</strong> - Normal backup pattern</span>
                </div>
            </div>
        </div>
        
        <div class="filter-controls">
            <button onclick="clearAllFilters()">Clear Filters</button>
            <button onclick="exportToCSV()">Export Filtered to CSV</button>
            <span class="results-count">Showing <span id="visibleCount">0</span> of <span id="totalCount">0</span> VMs</span>
        </div>
        
        <div class="table-container">
            <table id="vaultTable">
                <thead>
                    <tr>
                        <th class="sortable" onclick="sortTable(0)">VM Name</th>
                        <th class="sortable" onclick="sortTable(1)">Vault</th>
                        <th class="sortable" onclick="sortTable(2)">Resource Group</th>
                        <th class="sortable" onclick="sortTable(3)">Policy</th>
                        <th class="sortable" onclick="sortTable(4)">Status</th>
                        <th class="sortable" onclick="sortTable(5)">Health</th>
                        <th class="sortable" onclick="sortTable(6)">VM Disk Size (GB)</th>
                        <th class="sortable" onclick="sortTable(7)">Instance Tier</th>
                        <th class="sortable" onclick="sortTable(8)">Backup Size (GB)</th>
                        <th class="sortable" onclick="sortTable(9)">Daily Churn (GB)</th>
                        <th class="sortable" onclick="sortTable(10)">Monthly Churn (GB)</th>
                        <th class="sortable" onclick="sortTable(11)">Recovery Points</th>
                        <th class="sortable" onclick="sortTable(12)">Risk Level</th>
                        <th class="sortable" onclick="sortTable(13)">Recommended Action</th>
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
                        <th><input type="text" class="filter-input" placeholder="Filter..." onkeyup="filterTable()"></th>
                    </tr>
                </thead>
                <tbody>
"@

    foreach ($result in ($Results | Sort-Object RiskLevel -Descending)) {
        $rowClass = switch ($result.RiskLevel) {
            "High" { "risk-high" }
            "Medium" { "risk-medium" }
            "Low" { "risk-low" }
            default { "" }
        }
        
        $riskBadge = switch ($result.RiskLevel) {
            "High" { "<span class='badge badge-danger'>High Risk</span>" }
            "Medium" { "<span class='badge badge-warning'>Medium Risk</span>" }
            "Low" { "<span class='badge badge-success'>Low Risk</span>" }
            default { "<span class='badge badge-info'>Unknown</span>" }
        }
        
        $healthBadge = if ($result.HealthStatus -eq "Passed") {
            "<span class='badge badge-success'>✓ Healthy</span>"
        } else {
            "<span class='badge badge-danger'>⚠ $($result.HealthStatus)</span>"
        }
        
$html += @"
                    <tr class="$rowClass">
                        <td><strong>$($result.VMName)</strong></td>
                        <td>$($result.Vault)</td>
                        <td>$($result.ResourceGroup)</td>
                        <td>$($result.Policy)</td>
                        <td>$($result.ProtectionState)</td>
                        <td>$healthBadge</td>
                        <td class="number-cell">$($result.VMDiskSizeGB)</td>
                        <td class="number-cell">$($result.InstanceTier)</td>
                        <td class="number-cell">$($result.TotalBackupSizeGB)</td>
                        <td class="number-cell">$($result.DailyChurnGB)</td>
                        <td class="number-cell">$($result.MonthlyChurnGB)</td>
                        <td class="number-cell">$($result.RecoveryPoints)</td>
                        <td>$riskBadge</td>
                        <td>$($result.RecommendedAction)</td>
                    </tr>
"@
    }
    
    $html += @"
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <p>Azure Recovery Services Vault Analysis Report | Analysis Period: $DaysToInspect days | High Churn Threshold: $HighChurnThresholdGB GB/day</p>
            <p><strong>Important:</strong> Per-VM "Backup Size" is estimated from recent backup job data transfer sizes and may not reflect total cumulative storage.</p>
            <p>The "Actual Vault Storage" stat above shows the true total backup storage consumption from Azure vault usage metrics ($actualVaultStorageTB TB).</p>
            <p><strong>Note on RA-GRS:</strong> For RA-GRS vaults, the storage shown is the billable amount (primary data). Azure replicates this data but doesn't double-charge.</p>
        </div>
    </div>
    
    <script>
        // Initialize counts on page load
        window.addEventListener('DOMContentLoaded', function() {
            updateCount();
        });
        
        // Sort table by column
        let sortDirection = [];
        function sortTable(columnIndex) {
            const table = document.getElementById('vaultTable');
            const tbody = table.tBodies[0];
            const rows = Array.from(tbody.rows);
            
            // Toggle sort direction
            sortDirection[columnIndex] = !sortDirection[columnIndex];
            const ascending = sortDirection[columnIndex];
            
            rows.sort((a, b) => {
                let aVal = a.cells[columnIndex].textContent.trim();
                let bVal = b.cells[columnIndex].textContent.trim();
                
                // Remove currency symbols and parse numbers
                aVal = aVal.replace(/[$,]/g, '');
                bVal = bVal.replace(/[$,]/g, '');
                
                // Try to parse as number
                const aNum = parseFloat(aVal);
                const bNum = parseFloat(bVal);
                
                if (!isNaN(aNum) && !isNaN(bNum)) {
                    return ascending ? aNum - bNum : bNum - aNum;
                }
                
                // String comparison
                return ascending ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
            });
            
            // Remove existing rows and re-append in sorted order
            rows.forEach(row => tbody.appendChild(row));
            
            // Update header styling
            const headers = table.querySelectorAll('thead tr:first-child th');
            headers.forEach((th, idx) => {
                th.classList.remove('sort-asc', 'sort-desc');
                if (idx === columnIndex) {
                    th.classList.add(ascending ? 'sort-asc' : 'sort-desc');
                }
            });
        }
        
        // Filter table rows
        function filterTable() {
            const table = document.getElementById('vaultTable');
            const filterInputs = document.querySelectorAll('.filter-input');
            const tbody = table.tBodies[0];
            let visibleCount = 0;
            
            Array.from(tbody.rows).forEach(row => {
                let showRow = true;
                
                filterInputs.forEach((input, index) => {
                    const filter = input.value.toLowerCase();
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
            const table = document.getElementById('vaultTable');
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
            const table = document.getElementById('vaultTable');
            const headers = Array.from(table.querySelectorAll('thead tr:first-child th'))
                .map(th => th.textContent.trim().replace(/[⇅▲▼]/g, '').trim());
            
            const visibleRows = Array.from(table.tBodies[0].rows)
                .filter(row => row.style.display !== 'none');
            
            let csv = headers.map(h => '"' + h + '"').join(',') + '\n';
            
            visibleRows.forEach(row => {
                const rowData = Array.from(row.cells).map(cell => {
                    let text = cell.textContent.trim();
                    text = text.replace(/[🛡️✓⚠]/g, '').trim();
                    return '"' + text.replace(/"/g, '""') + '"';
                });
                csv += rowData.join(',') + '\n';
            });
            
            const blob = new Blob([csv], { type: 'text/csv' });
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'vault-analysis-filtered-' + new Date().toISOString().slice(0,10) + '.csv';
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

# Display summary
Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    Analysis Summary                            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$highRiskVMs = $allResults | Where-Object { $_.RiskLevel -eq "High" }
$mediumRiskVMs = $allResults | Where-Object { $_.RiskLevel -eq "Medium" }
$lowRiskVMs = $allResults | Where-Object { $_.RiskLevel -eq "Low" }

Write-Host "Total Protected VMs:     $($allResults.Count)" -ForegroundColor White
Write-Host "  High Risk:             $($highRiskVMs.Count)" -ForegroundColor Red
Write-Host "  Medium Risk:           $($mediumRiskVMs.Count)" -ForegroundColor Yellow
Write-Host "  Low Risk:              $($lowRiskVMs.Count)" -ForegroundColor Green
Write-Host ""

# Calculate actual vault storage totals
$actualVaultStorageGB = 0
$actualVaultStorageTB = 0
foreach ($vaultInfo in $vaultStorageInfo.Values) {
    $actualVaultStorageGB += $vaultInfo.TotalGB
    $actualVaultStorageTB += $vaultInfo.TotalTB
}
$actualVaultStorageGB = [math]::Round($actualVaultStorageGB, 2)
$actualVaultStorageTB = [math]::Round($actualVaultStorageTB, 2)

$totalBackup = [math]::Round(($allResults | Measure-Object -Property TotalBackupSizeGB -Sum).Sum, 2)
$totalChurn = [math]::Round(($allResults | Measure-Object -Property DailyChurnGB -Sum).Sum, 2)

Write-Host "Actual Vault Storage:    $actualVaultStorageTB TB ($actualVaultStorageGB GB)" -ForegroundColor Cyan
Write-Host "                         (For RA-GRS: this is billable primary data, not including replication)" -ForegroundColor DarkGray
Write-Host "Per-VM Estimate Total:   $totalBackup GB (from backup job sizes)" -ForegroundColor DarkCyan
Write-Host "Total Daily Churn:       $totalChurn GB/day" -ForegroundColor Cyan
Write-Host ""

if ($highRiskVMs.Count -gt 0) {
    Write-Host "⚠️  High Risk VMs (Top 5 by churn rate):" -ForegroundColor Red
    $highRiskVMs | Sort-Object DailyChurnGB -Descending | Select-Object -First 5 | ForEach-Object {
        $instanceInfo = if ($_.InstanceTier -gt 0) { " [Instance Tier $($_.InstanceTier), $($_.VMDiskSizeGB) GB]" } else { "" }
        Write-Host "   • $($_.VMName)$instanceInfo : $($_.DailyChurnGB) GB/day - $($_.Flags)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Export results
Write-Host "Exporting results..." -ForegroundColor Cyan
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonPath = Join-Path $scriptDir "$OutputPrefix-$timestamp.json"
$csvPath = Join-Path $scriptDir "$OutputPrefix-$timestamp.csv"
$htmlPath = Join-Path $scriptDir "$OutputPrefix-$timestamp.html"

$allResults | ConvertTo-Json -Depth 4 | Set-Content $jsonPath
$allResults | Export-Csv $csvPath -NoTypeInformation
New-HtmlReport -Results $allResults -OutputPath $htmlPath

Write-Host "  ✓ JSON: $jsonPath" -ForegroundColor Green
Write-Host "  ✓ CSV:  $csvPath" -ForegroundColor Green
Write-Host "  ✓ HTML: $htmlPath" -ForegroundColor Green
Write-Host ""

# Calculate and display execution time
$scriptEndTime = Get-Date
$executionTime = $scriptEndTime - $scriptStartTime
$timeString = if ($executionTime.TotalMinutes -ge 1) {
    "{0:N0} minutes {1:N0} seconds" -f [math]::Floor($executionTime.TotalMinutes), $executionTime.Seconds
} else {
    "{0:N1} seconds" -f $executionTime.TotalSeconds
}

Write-Host "⏱️  Total execution time: $timeString" -ForegroundColor Magenta
Write-Host ""

#endregion
