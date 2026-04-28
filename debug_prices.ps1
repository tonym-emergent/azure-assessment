$prices = (Invoke-RestMethod "https://prices.azure.com/api/retail/prices?`$filter=armRegionName eq 'northcentralus' and armSkuName eq 'Standard_D16as_v5' and serviceName eq 'Virtual Machines'").Items | Where { $_.type -ne 'DevTestConsumption' }
$prices | Select-Object unitPrice, reservationTerm, type, productName, meterName | Sort-Object type | ft -AutoSize
