$vms = Get-VM -Location 'env-prod'| where {$_.PowerState -eq "PoweredOff"}
$vmPoweredOff = $vms | %{$_.Name}
$events = Get-VIEvent -Start (Get-Date).AddDays(-7) -Entity $vms | where{$_.FullFormattedMessage -like "*is powered off"}
$lastweekVM = $events | %{$_.Vm.Name}
$vmPoweredOff | where {!($lastweekVM -contains $_)}