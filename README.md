# Azure Assessment Tools

A comprehensive collection of PowerShell scripts for analyzing and optimizing Azure infrastructure. These tools help identify cost savings opportunities, performance optimization needs, and resource inefficiencies across your Azure subscriptions.

## 🛠️ Available Assessment Tools

### 1. Managed Disk Analysis
**Location:** `azure-managed-disk-analysis/`

Analyzes Azure managed disk performance telemetry to identify optimization opportunities for disk sizing, SKU selection, and cost reduction.

**Key Features:**
- Performance metrics analysis (IOPS, throughput, latency)
- Cost comparison across disk SKUs (Standard HDD, Standard SSD, Premium SSD, Premium SSD v2)
- Identification of over-provisioned and under-utilized disks
- Custom disk size detection and optimization recommendations
- Interactive HTML reports with filtering and sorting

[📖 Full Documentation](azure-managed-disk-analysis/README.md)

### 2. Recovery Services Vault Analysis
**Location:** `azure-recovery-services-vault-analysis/`

Analyzes Azure Recovery Services Vaults backup configurations to identify high-churn VMs and estimate backup storage consumption patterns.

**Key Features:**
- Backup policy and schedule analysis
- Protected VM backup status monitoring
- Daily churn rate estimation from backup jobs
- Cost analysis based on backup storage patterns
- High-churn VM identification for investigation
- Interactive HTML reports with risk level highlighting

[📖 Full Documentation](azure-recovery-services-vault-analysis/README.md)

### 3. Virtual Machine Analysis
**Location:** `azure-vm-analysis/`

Analyzes Azure Virtual Machines for Advisor recommendations, host utilization, and VM pricing comparisons across pay-as-you-go and reserved instance options.

**Key Features:**
- Azure Advisor Cost and Performance recommendation collection per VM
- Host-metric utilization analysis using Azure Monitor CPU, network, disk, and B-series credit metrics
- Improved PAYG, 1-year RI, and 3-year RI pricing comparison with Windows OS license modeled when applicable
- Top-3 B-series, D-series, and E-series target SKU recommendations based on utilization and regional SKU availability
- Self-contained HTML report with sorting, filtering, visible-row CSV export, and rationale sections below each VM row
- Config-driven execution with inline-documented settings and report behavior

## 🚀 Quick Start

### Prerequisites

- **Azure CLI** installed and configured (`az` command available)
- **PowerShell** 5.1 or later (PowerShell Core 7+ recommended)
- **Azure Authentication**: You must be logged in via Azure CLI (`az login`)
- **Permissions**: Read access to the Azure resources you want to analyze

### Installation

1. **Clone or download this repository:**
   ```powershell
   git clone https://github.com/tonym-emergent/azure-assessment.git
   cd azure-assessment
   ```

2. **Ensure Azure CLI is installed:**
   ```powershell
   az --version
   ```

3. **Login to Azure:**
   ```powershell
   az login
   ```

## 📊 Usage Examples

### Managed Disk Analysis

Analyze all disks in your current subscription:
```powershell
cd azure-managed-disk-analysis
.\azure-managed-disk-telemetry-analysis.ps1
```

Analyze disks in a specific subscription over the last 7 days:
```powershell
.\azure-managed-disk-telemetry-analysis.ps1 `
    -SubscriptionId "12345678-1234-1234-1234-123456789012" `
    -DaysToInspect 7
```

Multi-subscription analysis with custom thresholds:
```powershell
.\azure-managed-disk-telemetry-analysis.ps1 `
    -SubscriptionId @("sub-id-1", "sub-id-2") `
    -DaysToInspect 30 `
    -ExceedanceThreshold 0.10 `
    -OutputPrefix "monthly-disk-report"
```

### Recovery Services Vault Analysis

Analyze all vaults in your current subscription:
```powershell
cd azure-recovery-services-vault-analysis
.\recovery-services-vault-analysis.ps1
```

Analyze vaults over the last 14 days with custom churn threshold:
```powershell
.\recovery-services-vault-analysis.ps1 `
    -SubscriptionId "12345678-1234-1234-1234-123456789012" `
    -DaysToInspect 14 `
    -HighChurnThresholdGB 100
```

Multi-subscription backup analysis:
```powershell
.\recovery-services-vault-analysis.ps1 `
    -SubscriptionId @("sub-id-1", "sub-id-2") `
    -OutputPrefix "monthly-backup-report"
```

### Virtual Machine Analysis

Run with the sample config file:
```powershell
cd azure-vm-analysis
.\azure-vm-assessment.ps1 -ConfigPath .\azure-vm-assessment.config.jsonc
```

Run with config but override a few values from the command line:
```powershell
.\azure-vm-assessment.ps1 `
    -ConfigPath .\azure-vm-assessment.config.jsonc `
    -DaysToInspect 1 `
    -VMName vmadconnect001 `
    -OutputPrefix vm-analysis-smoke
```

Run fully from parameters without a config file:
```powershell
.\azure-vm-assessment.ps1 `
    -SubscriptionId "12345678-1234-1234-1234-123456789012" `
    -DaysToInspect 14 `
    -OutputPrefix "vm-analysis-weekly"
```

## 📈 Output Reports

All tools generate three types of reports:

### 1. HTML Report (Interactive)
- **Beautiful, interactive dashboard** with statistics and visualizations
- **Sortable and filterable tables** for easy data exploration
- **Color-coded risk levels** for quick identification of issues
- **Export functionality** to CSV from filtered results
- **Responsive design** for viewing on any device

### 2. CSV Report (Data Analysis)
- **Comma-separated values** for Excel, Power BI, or custom analysis
- **Complete dataset** with all metrics and recommendations
- **Easy import** into existing reporting workflows

### 3. JSON Report (Programmatic Access)
- **Structured data** for API integration
- **Machine-readable format** for automation
- **Complete metadata** for downstream processing

## 🎯 Common Use Cases

### Cost Optimization
- **Identify over-provisioned disks** that can be downsized
- **Find Standard HDD disks** that should be Standard SSD
- **Detect inefficient custom sizes** near tier boundaries
- **Estimate monthly savings** from optimization actions

### Performance Optimization
- **Identify disks exceeding IOPS limits** that need upgrading
- **Find throughput bottlenecks** impacting application performance
- **Detect latency-sensitive workloads** requiring Premium storage
- **Optimize burst usage** and potential Performance Plus candidates

### Backup Optimization
- **Identify high-churn VMs** consuming excessive backup storage
- **Find VMs with backup health issues** requiring attention
- **Estimate backup costs** based on storage and retention
- **Review backup policies** for optimization opportunities

### Compliance & Governance
- **Track disk usage patterns** across subscriptions
- **Monitor backup coverage** and protection status
- **Generate audit reports** for management review
- **Identify configuration drift** from standards

## 🔧 Configuration

### Disk Analysis Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `DaysToInspect` | Int | 7 | Days of historical metrics to analyze |
| `ExceedanceThreshold` | Double | 0.05 | Percentage threshold for limit exceedance (5%) |
| `SubscriptionId` | String[] | Current | Azure subscription ID(s) to analyze |
| `SpecFile` | String | "disk-specs.json" | Path to disk SKU specifications file |
| `OutputPrefix` | String | "disk-analysis" | Prefix for output files |

### Vault Analysis Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `DaysToInspect` | Int | 30 | Days of historical backup data to analyze |
| `HighChurnThresholdGB` | Double | 50 | Daily churn threshold (GB) to flag high-churn VMs |
| `SubscriptionId` | String[] | Current | Azure subscription ID(s) to analyze |
| `OutputPrefix` | String | "vault-analysis" | Prefix for output files |

### VM Analysis Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ConfigPath` | String | None | Path to a JSON or JSONC config file |
| `DaysToInspect` | Int | 14 | Days of Azure Monitor history to analyze |
| `SubscriptionId` | String[] | Current | Azure subscription ID(s) to analyze |
| `OutputPrefix` | String | "vm-analysis" | Prefix for generated output file names |
| `VMName` | String[] | All | Optional VM name filter |
| `RefreshAdvisor` | Switch | False | Refresh Advisor recommendations during execution |
| `UnderutilizedCpuAverageThreshold` | Double | 10 | CPU average threshold for underutilization |
| `UnderutilizedCpuP95Threshold` | Double | 25 | CPU P95 threshold for underutilization |
| `OverutilizedCpuAverageThreshold` | Double | 65 | CPU average threshold for overutilization |
| `OverutilizedCpuP95Threshold` | Double | 85 | CPU P95 threshold for overutilization |
| `LowNetworkAverageThresholdMBps` | Double | 0.5 | Network MB/s threshold for low activity |
| `LowDiskAverageThresholdMBps` | Double | 1.0 | Disk MB/s threshold for low activity |
| `BurstableLowCreditsThreshold` | Double | 20 | B-series CPU credits threshold |
| `MinimumSamplesForClassification` | Int | 12 | Minimum CPU samples required to classify a VM |

### VM Analysis Config Notes

- The sample config file is at `azure-vm-analysis/azure-vm-assessment.config.jsonc`.
- Use `.jsonc` when you want inline comments. Use plain `.json` only if you remove comments.
- Command-line parameters override config values when both are provided.
- Report behavior is configured under the `Report` object, including output directory, output format toggles, and HTML report text.
- Current-SKU pricing now records PAYG and reservation matches separately, so `RI meters not found` should only appear when the reservation price really is unavailable.
- Windows pricing includes OS license only when the VM is not using a license benefit such as Azure Hybrid Benefit. For reservations, the script derives the monthly Windows uplift from the difference between Windows PAYG and base compute PAYG, then adds that uplift to the reservation compute monthly estimate.
- The HTML report uses the recommended target SKU for the `Cost Comparison` column when a target SKU is available.
- Aggregate cards show estimated monthly cost for PAYG, 1YR RI, and 3YR RI rather than visible savings totals.
- CPU Avg % and CPU P95 % were removed from the main table and are now surfaced in the expandable rationale section under `Data`.
- The HTML report includes a best target SKU summary in the main grid and a top-3 B/D/E candidate table inside each VM detail panel.
- SKU recommendations prefer the current VM family first and only switch families when the utilization profile strongly supports it.

## 📁 Repository Structure

```
azure-assessment/
├── README.md                                    # This file
├── .gitignore                                   # Git ignore patterns
│
├── azure-managed-disk-analysis/
│   ├── README.md                                # Disk analysis documentation
│   ├── azure-managed-disk-telemetry-analysis.ps1 # Main disk analysis script
│   ├── disk-specs.json                          # Disk SKU specifications
│   └── disk-analysis-*.{html,csv,json}          # Generated reports
│
├── azure-vm-analysis/
│   ├── azure-vm-assessment.ps1                  # Main VM analysis script
│   ├── azure-vm-assessment.config.jsonc         # Sample annotated config file
│   └── vm-analysis-*.{html,csv,json}            # Generated reports
│
└── azure-recovery-services-vault-analysis/
    ├── README.md                                # Vault analysis documentation
    ├── recovery-services-vault-analysis.ps1     # Main vault analysis script
    └── vault-analysis-*.{html,csv,json}         # Generated reports
```

## 🚨 Troubleshooting

### Common Issues

#### Azure CLI Not Found
```powershell
# Install Azure CLI
winget install Microsoft.AzureCLI
# Or download from: https://aka.ms/installazurecliwindows
```

#### Authentication Errors
```powershell
# Re-authenticate with Azure
az login

# Verify current subscription
az account show

# List available subscriptions
az account list --output table

# Set default subscription
az account set --subscription "subscription-name-or-id"
```

#### No Data Returned
- Verify you have resources in the subscription (disks or vaults)
- Check that metrics are being collected (may take time for new resources)
- Ensure you have read permissions on the resources
- For disk analysis: Wait at least 24 hours after disk creation for metrics

#### Slow Performance
- Reduce `DaysToInspect` parameter for faster analysis
- Analyze one subscription at a time for large environments
- Check network connectivity to Azure

#### Permission Errors
Required Azure RBAC roles:
- **Disk Analysis**: Reader role on subscriptions/resource groups
- **Vault Analysis**: Backup Reader or Backup Operator role

## 💡 Best Practices

### Running Regular Assessments
```powershell
# Weekly disk analysis (recommended)
.\azure-managed-disk-telemetry-analysis.ps1 -DaysToInspect 7

# Monthly backup analysis (recommended)
.\recovery-services-vault-analysis.ps1 -DaysToInspect 30
```

### Multi-Subscription Organizations
```powershell
# Get all subscription IDs
$subs = (az account list --query "[].id" -o tsv)

# Run analysis across all subscriptions
.\azure-managed-disk-telemetry-analysis.ps1 -SubscriptionId $subs
```

### Automating Reports
Create a scheduled task or Azure Automation runbook to:
1. Run scripts weekly/monthly
2. Store reports in Azure Storage or SharePoint
3. Email reports to stakeholders
4. Track trends over time

### Cost Savings Tracking
1. Export initial assessment to CSV
2. Implement recommended changes
3. Run assessment again after 30 days
4. Compare results to validate savings

## 📊 Understanding the Metrics

### Disk Analysis Metrics

- **IOPS Above %**: Percentage of time disk IOPS exceeded provisioned limits
- **MBps Above %**: Percentage of time throughput exceeded limits
- **Avg Latency**: Average disk response time (lower is better)
- **Transactions**: Total read/write operations during analysis period
- **Cost Diff**: Monthly cost difference between current and recommended SKU

### Vault Analysis Metrics

- **Daily Churn GB**: Average daily change in backup size
- **Monthly Churn GB**: Estimated monthly data change (Daily × 30)
- **Total Backup Size GB**: Current total backup storage consumed
- **Recovery Points**: Number of backup snapshots available
- **Risk Level**: High/Medium/Low based on churn and health status

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## 📝 License

This project is provided as-is for Azure infrastructure assessment purposes.

## 🔗 Related Resources

- [Azure Disk Pricing](https://azure.microsoft.com/pricing/details/managed-disks/)
- [Azure Backup Pricing](https://azure.microsoft.com/pricing/details/backup/)
- [Azure CLI Documentation](https://docs.microsoft.com/cli/azure/)
- [Azure Monitor Metrics](https://docs.microsoft.com/azure/azure-monitor/essentials/metrics-supported)

## ✉️ Support
- Excel/spreadsheet analysis
- Power BI imports
- Further data processing

### 3. JSON Report (`vault-analysis-YYYYMMDD-HHMMSS.json`)

Structured JSON data for:
- Programmatic access
- API integration
- Custom reporting tools

## Contributing

Contributions are welcome! To add new assessment tools:

1. Follow the established PowerShell script structure
2. Include HTML, CSV, and JSON output formats
3. Add comprehensive documentation to this README
4. Include parameter descriptions and examples

## License

These scripts are provided as-is for Azure infrastructure assessment purposes.

## Additional Resources

- [Azure CLI Documentation](https://docs.microsoft.com/en-us/cli/azure/)
- [Azure Monitor Metrics](https://docs.microsoft.com/en-us/azure/azure-monitor/essentials/metrics-supported)
- [Azure Backup Documentation](https://docs.microsoft.com/en-us/azure/backup/)
- [Azure Cost Management](https://docs.microsoft.com/en-us/azure/cost-management-billing/)

---

For detailed documentation on each tool, see their respective sections above. For issues or questions, verify Azure CLI installation and permissions before running the scripts.
