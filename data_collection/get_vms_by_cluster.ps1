$start = Get-Date
Write-Progress -Activity "Getting VMs in Cluster" -status "Starting..." -percentComplete (0)
$vm_report = @()
$cluster_report = @()

$rps = Get-ResourcePool
$rpsht = @{}
Write-Progress -Activity "Getting VMs in Cluster" -status "Preprocess Resource Pools..." -percentComplete (0)
foreach ($rp in $rps) {
	$rpsht[$rp.id] = $rp
}

#Get all the clusters:
$clusters = Get-Cluster
$z = 0
foreach ($cluster in $clusters) {
	$z++
	$vms = Get-VM -Location $cluster
	$hosts = Get-VMHost -Location $cluster
	foreach($h in $hosts){
		$row = "" | select ClusterName, HostName, Manufacturer, Model, ConnectionState, PowerState, version, build
		$row.ClusterName = $cluster.Name
		$row.HostName = $h.Name
		$row.Manufacturer = $h.Manufacturer
		$row.Model = $h.Model
		$row.ConnectionState = $h.ConnectionState
		$row.PowerState = $h.PowerState
		$row.version = $h.version
		$row.build = $h.Build
		$cluster_report += $row
	}
	
	$i = 0
	if($vms.count -gt 0){
		foreach ($vm in $vms) {
			$i++
			Write-Progress -Activity "Getting VMs in Cluster" -status ("Cluster "+$cluster.Name+"("+$z+"/"+$clusters.count+") - Processing VM: "+$vm.Name) -percentComplete ($i / $vms.count*100)
			$row = "" | select VMname , vcFolder, PowerState, Cluster, Host, ResourcePool, NICs, HardDisks
			$row.VMname = $vm.Name
			$row.vcFolder = $vm.Folder.Name
			$row.PowerState = $vm.PowerState
			$row.Cluster = $cluster.Name
			$row.Host = $vm.VMHost.Name
			
			#Get Resource Pool Information
			$rp = $rpsht[$vm.ResourcePoolId]

			$nested = ""
			while ($rp.Name -ne "Resources"){
				$nested = $rp.Name + "/" + $nested
				if($rp.ParentId){
					if ($rpsht.ContainsKey($rp.ParentId)){
						$rp = $rpsht[$rp.ParentId]
					}else{
						break
					}
				}else{
					break
				}
			}	
			$row.ResourcePool = $nested
			
			#Get NIC Information
			#$nics = $vm | Get-NetworkAdapter
			$nics = $vm.NetworkAdapters
			$nicdata = @()
			foreach($nic in $nics){
				$nicdata += [string]::Join('>>', ($nic.Name, $nic.NetworkName))
			}
			$row.NICs = [string]::Join('|', $nicdata)
			
			#Get Hard Disk Information
			#$hds = $vm | Get-HardDisk
			$hds = $vm.HardDisks
			$hddata = @()
			foreach($hd in $hds){
				$hddata += [string]::Join('>>', ($hd.Name, $hd.Filename))
			}
			$row.HardDisks = [string]::Join('|', $hddata)
			#append data
			$vm_report += $row
		}
	}else{
	Write-Warning ($cluster.Name+" contains no VMs")
	}
}

Write-Host "Writing Files...."
$date = Get-Date -Format "yyyy-M-d_hh-mm-ss"
$prefix = "c:\Temp\"+($Global:DefaultVIServer.name)
$vm_report | Export-Csv ($prefix+"_vm_report-"+$date+".csv") -NoTypeInformation
$cluster_report | Export-Csv ($prefix+"_cluster_report-"+$date+".csv") -NoTypeInformation
$rps | select Name, CpuSharesLevel, NumCpuShares, CpuReservationMHz,CpuExpandableReservation,CpuLimitMHz,MemSharesLevel,NumMemShares,MemReservationMB,MemReservationGB,MemExpandableReservation,MemLimitMB,MemLimitGB | Export-Csv ($prefix+"_resource_pool-"+$date+".csv") -NoTypeInformation
((Get-Date)-$start) -f "m"







