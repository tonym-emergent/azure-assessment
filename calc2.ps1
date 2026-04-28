$prices = (Invoke-RestMethod "https://prices.azure.com/api/retail/prices?`$filter=armRegionName eq 'northcentralus' and armSkuName eq 'Standard_D16as_v5' and serviceName eq 'Virtual Machines'").Items | Where { $_.type -ne 'DevTestConsumption' }
$basePAYG = ($prices | Where { $_.productName -match 'Dasv5' -and $_.meterName -eq 'D16as v5' -and $_.type -eq 'Consumption' })[0].unitPrice
$winPAYG = ($prices | Where { $_.productName -match 'Windows' -and $_.skuName -eq 'Standard_D16as_v5' -and $_.type -eq 'Consumption' })[0].unitPrice
$osLic = ($winPAYG - $basePAYG) * 730
$baseRI1 = ($prices | Where { $_.skuName -eq 'Standard_D16as_v5' -and $_.reservationTerm -eq '1 Year' })[0].unitPrice
$baseRI3 = ($prices | Where { $_.skuName -eq 'Standard_D16as_v5' -and $_.reservationTerm -eq '3 Years' })[0].unitPrice
$cPAYG = [math]::Round($winPAYG * 730, 2)
$c1YR = [math]::Round(($baseRI1 * 730) + $osLic, 2)
$c3YR = [math]::Round(($baseRI3 * 730) + $osLic, 2)
"PAYG: $cPAYG (Target: 1039.52), 1YR: $c1YR (Target: 833.61), 3YR: $c3YR (Target: 728.14)"
