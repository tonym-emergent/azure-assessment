$prices = (Invoke-RestMethod "https://prices.azure.com/api/retail/prices?`$filter=armRegionName eq 'northcentralus' and armSkuName eq 'Standard_D16as_v5' and serviceName eq 'Virtual Machines'").Items | Where { $_.type -ne 'DevTestConsumption' }
$basePAYG = ($prices | Where { ($_.productName -eq 'Virtual Machines Dasv5 Series' -or $_.productName -eq 'Dasv5 Series Cloud Services') -and $_.meterName -eq 'D16as v5' -and $_.type -eq 'Consumption' })[0].unitPrice
$winPAYG = ($prices | Where { $_.productName -match 'Windows' -and $_.meterName -eq 'D16as v5' -and $_.type -eq 'Consumption' })[0].unitPrice
$osLicMonthly = ($winPAYG - $basePAYG) * 730
# Reservation unitPrice from the API is often the total for the term or a monthly cost pre-calculated. 
# Looking at the numbers: 3556.0 (1 Yr) and 6871.0 (3 Yr). 
# 3556 / 12 = 296.33. 6871 / 36 = 190.86.
$baseRI1YrMonthly = 3556.0 / 12
$baseRI3YrMonthly = 6871.0 / 36

$cPAYG = [math]::Round($winPAYG * 730, 2)
$c1YR = [math]::Round($baseRI1YrMonthly + $osLicMonthly, 2)
$c3YR = [math]::Round($baseRI3YrMonthly + $osLicMonthly, 2)

"PAYG: $cPAYG (Target: 1039.52), 1YR: $c1YR (Target: 833.61), 3YR: $c3YR (Target: 728.14)"
