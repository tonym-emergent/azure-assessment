$prices = (Invoke-RestMethod "https://prices.azure.com/api/retail/prices?`$filter=armRegionName eq 'northcentralus' and armSkuName eq 'Standard_D16as_v5' and serviceName eq 'Virtual Machines'").Items | Where { $_.type -ne 'DevTestConsumption' }
$basePAYG_Hourly = ($prices | Where { ($_.productName -eq 'Virtual Machines Dasv5 Series' -or $_.productName -eq 'Dasv5 Series Cloud Services') -and $_.meterName -eq 'D16as v5' -and $_.type -eq 'Consumption' })[0].unitPrice
$winPAYG_Hourly = ($prices | Where { $_.productName -match 'Windows' -and $_.meterName -eq 'D16as v5' -and $_.type -eq 'Consumption' })[0].unitPrice

$osLicMonthly = ($winPAYG_Hourly - $basePAYG_Hourly) * 730
$basePAYG_Monthly = $basePAYG_Hourly * 730

$baseRI1Yr_Total = ($prices | Where { $_.skuName -eq 'Standard_D16as_v5' -and $_.reservationTerm -eq '1 Year' })[0].unitPrice
$baseRI3Yr_Total = ($prices | Where { $_.skuName -eq 'Standard_D16as_v5' -and $_.reservationTerm -eq '3 Years' })[0].unitPrice

# If unitPrice is the total cost for the reservation term
$baseRI1YrMonthly = $baseRI1Yr_Total / 12
$baseRI3YrMonthly = $baseRI3Yr_Total / 36

# Check if unitPrice * 730 is closer to target
$baseRI1Yr_Computed = $baseRI1Yr_Total * 730
$baseRI3Yr_Computed = $baseRI3Yr_Total * 730

$calcPAYG = [math]::Round($winPAYG_Hourly * 730, 2)
$calc1YR = [math]::Round($baseRI1YrMonthly + $osLicMonthly, 2)
$calc3YR = [math]::Round($baseRI3YrMonthly + $osLicMonthly, 2)

"Results:"
"Base Compute PAYG Monthly: $([math]::Round($basePAYG_Monthly, 2))"
"Windows PAYG Total Monthly: $calcPAYG"
"Derived Windows OS License Monthly: $([math]::Round($osLicMonthly, 2))"
"1 Year RI Total Monthly: $calc1YR"
"3 Years RI Total Monthly: $calc3YR"
"Targets: PAYG 1039.52, 1YR 833.61, 3YR 728.14"
