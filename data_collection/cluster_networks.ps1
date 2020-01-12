param(
    [parameter(Mandatory=$true)]
    $clusterpattern
	)
	
	

$networks = @()
foreach ($vm in Get-Vm -Location (Get-Cluster -Name $clusterpattern)) {
	$networks += $vm | Get-NetworkAdapter | select networkname
}

write $networks
write ----
$networks | Sort-Object -Property networkname 
write ----
$networks | Sort-Object 
write ----
