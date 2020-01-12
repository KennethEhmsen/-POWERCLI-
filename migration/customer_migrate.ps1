#you need to actually pass the migrate flag to move the disks.
param(
	[Switch] $migrate
    )
	
# -----------------------------------------------------------------------------------------------------
# Config:
# -----------------------------------------------------------------------------------------------------
$customer_rp = 'env-prod-1383-1402'
$customer_id = 1383
$datastore_prefix = 'TT'
$global:datastore_reservation_GB = 50 #GB
$move_limit = 10 #XXX: CHANGE THIS TO DO THE MOVE!
#XIV4
#$datastores = 'BKUP-Datastore119', 'Datastore170', 'Datastore214', 'Datastore333', 'Datastore334', 'Datastore335', 'Datastore336', 'Datastore338', 'Datastore37', 'Datastore539', 'Datastore729', 'Datastore730', 'Datastore810', 'Datastore948', 'Datastore949', 'Datastore952', 'Datastore955'
#XIV5
$datastores ='Datastore302', 'Datastore304', 'Datastore316', 'Datastore401', 'Datastore403', 'Datastore405', 'Datastore406', 'Datastore407', 'Datastore408', 'Datastore409', 'Datastore410', 'Datastore411', 'Datastore412', 'Datastore413', 'Datastore414', 'Datastore416', 'Datastore417', 'Datastore418', 'Datastore419', 'Datastore420'


# -----------------------------------------------------------------------------------------------------
# Gather Datastore information:
# -----------------------------------------------------------------------------------------------------
#check the datastores ahead of time to see if we have some space:
#$temp_target_datastores = Get-Datastore -Name ($datastore_prefix+'*')
$temp_target_datastores = Get-Datastore -Name @('Datastore960','Datastore961')

$global:target_datastores = @()
$ds_space = 0
foreach ($ds in $temp_target_datastores){
	if ($ds.FreeSpaceGB -gt $global:datastore_reservation_GB){
		#datastore has some space on it, consider it usable
		$ds_space += ($ds.FreeSpaceGB - $global:datastore_reservation_GB)
		$global:target_datastores += @{'Name'=$ds.Name; 'FreeSpaceGB'=$ds.FreeSpaceGB; 'moref'=$ds.ExtensionData.MoRef}
	}
}
Write-Host "--------------------------------------------------"
Write-Host $ds_space " GB Avail Datastore space"
Write-Host "--------------------------------------------------"
#this will be reused.
$global:target_datastore_count = $global:target_datastores.Count
$global:target_datastore_pointer = 0

if($global:target_datastore_count -le 0){
	Write-Error "No datastores with space."
	#exit
}

Write-Host "Start Gather Datastore refs"
#Build complete datastore lookup
$all_datastores =  Get-Datastore
$ds_lookup = @{}
$i = 0
foreach($ds in $all_datastores){
	$i++
	Write-Progress -Activity "Gathering Datastore Information" -status  'Get MoRef' -percentComplete ($i / $all_datastores.Count*100)
	$ds_lookup[$ds.Name] = $ds.ExtensionData.MoRef
}
# -----------------------------------------------------------------------------------------------------
# Helper Functions ------------------------------------------------------------------------------------
# -----------------------------------------------------------------------------------------------------
function GatherData {
	param(
		$vms,
		$type
	)
	$i = 0
	$vms_to_move = @()
	$space_required = 0
	$vmsc = $vms.Count
	if(-not $vmsc){
		$vmsc = 1
	}
	foreach($vm in $vms){
		$move_config = $false
		$total_disk_size = 0
		$config_size = 0
		$i++
		Write-Progress -Activity "Gathering Information" -status  $type -percentComplete ($i / $vmsc*100)
		#configfile
		if($datastores -contains $vm.ExtensionData.Config.Files.VmPathName.Split("]")[0].TrimStart("[")){
			#need to move the config file
			$move_config = $true
		}
		
		if($type -eq 'vm'){
			$hds = Get-HardDisk -VM $VM
		}else{
			$hds = Get-HardDisk -Template $VM
		}
		
		$hds_to_move = @()
		foreach ($hd in $hds) {
			if($move_config){
				$total_disk_size += $hd.CapacityGB
			}
			$name = $hd.FileName.Split("]")[0].TrimStart("[")
			if($datastores -contains $name){
				$hds_to_move += $hd
				$space_required += $hd.CapacityGB
			}
		}
		
		if($move_config){
			$config_size = ($vm.ProvisionedSpaceGB - $total_disk_size)
			$space_required += $config_size
		}
			
		if($move_config -or ($hds_to_move.Count -gt 0)){
			$vms_to_move += @{'vm'=$vm; 'move_config'=$move_config; 'config_size'=$config_size; 'hds'=$hds}
		}
	}
	Write-Host "--------------------------------------------------"
	Write-Host $vms_to_move.Count " moves needed for " $type
	Write-Host "Space Needed: " $space_required "GB for " $type
	Write-Host "--------------------------------------------------"
	return $vms_to_move
}

function findDataStore {
	param(
		$size
	)
	$datastoreMoRef = ''
	$maxCheck = 0
	Write-Host "--- Looking for $size GB ---"
	do {
		if(($global:target_datastores[$global:target_datastore_pointer]['FreeSpaceGB']-$global:datastore_reservation_GB) -gt $size){
			Write-Host "Found Datastore:"
			Write-Host "Space Avail: " ($global:target_datastores[$global:target_datastore_pointer]['FreeSpaceGB']-$global:datastore_reservation_GB)
			#update size
			$global:target_datastores[$global:target_datastore_pointer]['FreeSpaceGB'] -= $size
			#set datastore id to return
			$datastoreMoRef = $global:target_datastores[$global:target_datastore_pointer]['moref']
			Write-Host "Found Datastore: " $datastoreMoRef.Value
			
		}
		$global:target_datastore_pointer++
		if($global:target_datastore_pointer -ge $global:target_datastore_count){
			$global:target_datastore_pointer = 0
		}
		$max_check++
		if($max_check -gt $global:target_datastore_count){
			Write-Error "There is not enough datastore space to complete this move. Needed $size GB"
			exit
		}
	} while ($datastoreMoRef -eq '')

	return $datastoreMoRef
}

function MoveVM {
	param(
		$vm
	)
	
	$spec = New-Object VMware.Vim.VirtualMachineRelocateSpec
	if($vm['move_config']){
		$spec.datastore = findDataStore $vm['config_size']
	}
	
	$spec.Disk = @()
	foreach($hd in $vm['hds']){	
		#build HD spec
		#if broke check out: http://communities.vmware.com/thread/324976
		$hdSpec = New-Object VMware.Vim.VirtualMachineRelocateSpecDiskLocator
		$hdSpec.diskId = $hd.Extensiondata.Key
		$name = $hd.FileName.Split("]")[0].TrimStart("[")
		if($datastores -contains $name){
			$hdSpec.datastore = findDataStore $hd.CapacityGB
		}else{
			$hdSpec.datastore = $ds_lookup[$name]
		}
		$spec.Disk += $hdSpec
	}
	#The move call
	return (Get-View -Id $vm['vm'].id).RelocateVM_Task($spec, "defaultPriority")
}


# -----------------------------------------------------------------------------------------------------
# Gather VM and Template Information
# -----------------------------------------------------------------------------------------------------

Write-Host "Gather VM Information"
#Find all the VM - HardDisks to move
$vms = Get-VM -location $customer_rp | Sort-Object -Property Name
#$vms = Get-VM -Name 10591
$vms_to_move = GatherData $vms 'vm'

Write-Host "Gather Template Information"
#Find all the templates to move
$tps = Get-Template -Location $customer_id
$temps_to_move = GatherData $tps 'Templates'

$move_count = 0

# -----------------------------------------------------------------------------------------------------
# Do the actual move:
# -----------------------------------------------------------------------------------------------------
Write-Host "About to move....."
if($migrate){
	Write-Host "Begin migration of VMs...."
	if ($vms_to_move -ne $null){
		foreach($vm in $vms_to_move){	
			#Move safety
			if($move_count -ge $move_limit){
				Write-Host "VMs:Max number of object moves hit."
				break
			}
			MoveVM $vm
			$move_count++
		}
	}
	Write-Host "Begin migration of Templates...."
	$i = 0
	if ($temps_to_move -ne $null){
		foreach($t in $temps_to_move){	
			#Move safety
			if($move_count -ge $move_limit){
				Write-Host "Templates: Max number of object moves hit."
				break
			}
			$i++
			#convert to VM
			Set-Template -Template $t['vm'] -ToVM
			
			#get the vm ref and overide
			$vm = Get-VM $t['vm']
			$t['vm'] = $vm
			#Call MoveVM
			$task = MoveVM $t
			$ctr = 1
			do {
			   	$status = Get-VIObjectByVIView $task
				if ($status.State -eq 'Error' -and $ctr -ne 0) {
					$task = MoveVM $t
					$ctr -= 1
					continue
				}
				Start-Sleep -Seconds 5
				Write-Progress -Activity "Moving Templates" -status ("Processing: "+$i+" of "+ $temps_to_move.Count) -percentComplete ($status.PercentComplete)
			} while ($status.State -ne 'Success')
			#convert back to template
			Set-VM -VM $vm -ToTemplate -Confirm:$False
			
			$move_count++
		}
	}
}
