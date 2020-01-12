#This gets all hard disks for timetrade.  (Not sure about the "memory" disk)  

$customer_rp = 'env-prod-1383-1402'
$customer_id = 1383

#XIV4
$datastores = 'Datastore123','Datastore125','Datastore126','Datastore128','Datastore129','Datastore130','Datastore729','Datastore730','Datastore333','Datastore338','Datastore539','Datastore810','Datastore37','Datastore336','Datastore335','Datastore334','Datastore127','Datastore124','XDatastore120','XDatastore121','X12Datastore119_11','Datastore948','Datastore949','Datastore952','Datastore955','Datastore170','Datastore214'
#XIV5
#$datastores = 'Datastore302','Datastore304','Datastore316','Datastore401','Datastore403','Datastore405','Datastore406','Datastore407','Datastore408','Datastore409','Datastore410','Datastore411','Datastore412','Datastore413','Datastore414','Datastore416','Datastore417','Datastore418','Datastore419','Datastore420'

$report = @()
$vms = Get-VM -location $customer_rp | Sort-Object -Property Name

$ds_ids = @()
foreach($d in $datastores){
	$ds_ids += (Get-Datastore -Name $d).ID
}

$size = 0
$vms_to_move = @()
$i = 0
foreach($vm in $vms){
	$move_config = $false
	$total_disk_size = 0
	$config_size = 0
	$i++
	Write-Progress -Activity "Gathering Information" -status  'VMs' -percentComplete ($i / $vms.Count*100)
	#configfile
	if($datastores -contains $vm.ExtensionData.Config.Files.VmPathName.Split("]")[0].TrimStart("[")){
		#need to move the config file
		$move_config = $true
	}

	$hds = Get-HardDisk -VM $VM
	
	$hds_to_move = @()
	foreach ($hd in $hds) {
		if($move_config){
			$total_disk_size += $hd.CapacityGB
		}
		$name = $hd.FileName.Split("]")[0].TrimStart("[")
		if($datastores -contains $name){
			$hds_to_move += $hd
			$size += $hd.CapacityGB
		}
	}
	
	if($move_config){
			$config_size = ($vm.ProvisionedSpaceGB - $total_disk_size)
			$size += $config_size
	}
		
	if($move_config -or ($hds_to_move.Count -gt 0)){
		$vms_to_move += @{'vm'=$vm; 'move_config'=$move_config; 'config_size'=$config_size; 'hds'=$hds_to_move}
	}
}
Write-Host "-------------------- Templates"
$temps = @()
$tps = Get-Template -Location $customer_id
foreach($t in $tps){
	foreach ($ds_id in $t.DatastoreIdList) {
		if($ds_ids -contains $ds_id){
			$temps += $t
			$t.Name
			break
		}
	}
}

Write-Host "Need to move: " $vms_to_move.Count " VMs"
Write-Host "Need " $size "GB to move the vms."
Write-Host "Need to move: " $temps.Count " Templates"
