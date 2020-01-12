 #Get total space required for a cluster
 
 $clusters = Get-Cluster
 $clust = @()
 $z = 0
 foreach ($cluster in $clusters) {
 	$z++
 	Write-Progress -Activity "Getting Cluster Size Report" -status ("Processing: "+$cluster.Name) -percentComplete ($z / $clusters.count*100)
	$row = "" | select name, vm_count, vm_space_tb, temp_count, temp_space_tb, total_space_needed_tb
	$vms = Get-VM -location $cluster
	$hosts = Get-VMHost -Location $cluster
	$vmspace = 0
	foreach ($v in $vms) {
		$vmspace += $v.ProvisionedSpaceGB
	}
	$tempspace = 0
	$tempcount = 0
	foreach ($h in $hosts) {
		$templates = Get-Template -Location $h
		$tempcount += $templates.count
		foreach ($t in $templates) {
			$tempspace += $t.ExtensionData.Summary.Storage.Committed
		}
	}
	$row.name = $cluster.Name
	$row.vm_count = $vms.Count
	$row.vm_space_tb = [Math]::Round($vmspace/1024, 2)#convert to TB
	$row.temp_count = $tempcount
	$row.temp_space_tb = [Math]::Round($tempspace/(1024*1024*1024*1024), 2)#convert to TB
	$row.total_space_needed_tb = ($row.vm_space_tb + $row.temp_space_tb)
	$clust += $row
}

$date = Get-Date -Format "yyyy-M-d_hh-mm-ss"
$clust | Export-Csv ("c:\Temp\cluster_size-"+$global:DefaultVIServer.Name+"-"+$date+".csv") -NoTypeInformation
