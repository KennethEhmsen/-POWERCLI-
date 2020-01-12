#you need to actually pass the migrate flag to move the disks.
param(
	[Switch] $migrate
    )

#Set a move limit:
$move_limit = 10
#Define the VM List:
$temp_vms = Get-VM -Location '1002', '1343','1583','1543','1164','1843','1866','1245','1266','1323','1115','1703','2024','1043','1403','1118','1263'
#$temp_vms = Get-VM -Location '1002'
#How we find the datastores:
$datastore_prefix = 'Large'
#Set a datastore reservation:
$datastore_reservation_GB = 500 #being conservitive here
# -----------------------------------------------------------------------------------------

$temp_target_datastores = Get-Datastore -Name ($datastore_prefix+'*')
$global:target_datastores = @()
$datastore_space = 0
$datastore_ids = @()
foreach ($ds in $temp_target_datastores){
	#we want all these ids to see if VMs have already been moved.
	$datastore_ids += $ds.Id
	#Only add if there is room to put stuff on it
	if ($ds.FreeSpaceGB -gt $datastore_reservation_GB){
		#datastore has some space on it, consider it usable
		$avail_space = ($ds.FreeSpaceGB - $global:datastore_reservation_GB)
		$datastore_space += $avail_space
		$global:target_datastores += @{'Name'=$ds.Name; 'space'=$avail_space; 'ref'=$ds}
	}
}
$target_datastore_count = $global:target_datastores.Count
$global:target_datastore_pointer = 0


#Checks the status of ones that have been moved:
$moved_vms = @()
#remove vms that have already been moved:
$vms = @()
foreach($vm in $temp_vms){
	$b = $true
	foreach($did in $vm.DatastoreIdList){
		if($datastore_ids -contains $did){
			$b = $false
			$moved_vms += $vm
			break
		}
	}
	#Check to see if it is still powered off
	#if($b -and ($vm.PowerState -eq 'PoweredOff') -and ($vm.ProvisionedSpaceGB -lt 100)){
	if($b){
		$vms += $vm
	}
}

#Determine how much space will be needed to move all the VMs
$size_needed_gb = 0
foreach($vm in $vms){
	$size_needed_gb += $vm.ProvisionedSpaceGB
}

Write-Host "----------------------------------"
Write-Host "VMs left to move: " $vms.Count
Write-Host "This move will require $size_needed_gb GB" 
Write-Host "The datastores provided have: $datastore_space GB available."
Write-Host "The current reserve is: $datastore_reservation_GB GB"
Write-Host "----------------------------------"
Write-Host "VMs moved so far: " $moved_vms.Count
$pspace = ($moved_vms | Measure-Object ProvisionedSpaceGB -Sum).sum
$uspace = ($moved_vms | Measure-Object UsedSpaceGB -Sum).sum
Write-Host "Space Provisioned: " $pspace
Write-Host "used Provisioned: "	$uspace
Write-Host "Total Saved: " ($pspace - $uspace)
Write-Host "----------------------------------"

function findDataStore {
	
	param(
		$size
	)
	$datastoreRef = ''
	$maxCheck = 0
	do {
		#Write-Host $global:target_datastore_pointer
		if(($global:target_datastores[$global:target_datastore_pointer]['space']) -gt $size){
			Write-Host "PICKED: "$global:target_datastores[$global:target_datastore_pointer]['name']
			#update size
			$global:target_datastores[$global:target_datastore_pointer]['space'] -= $size
			Write-Host "Space Left: " $global:target_datastores[$global:target_datastore_pointer]['space']
			#set datastore reference to return
			$datastoreRef = $global:target_datastores[$global:target_datastore_pointer]['ref']
		}
		$global:target_datastore_pointer++
		if($global:target_datastore_pointer -ge $target_datastore_count){
			$global:target_datastore_pointer = 0
		}
		$max_check++
		if($max_check -gt $target_datastore_count){
			Write-Error "There is not enough datastore space to complete this move. Needed $size GB"
			exit
		}
	} while ($datastoreRef -eq '')

	return $datastoreRef
}





if($migrate){
	$i = 0
	foreach($vm in $vms){
		if($i -ge $move_limit){
			Write-Host "Max number of object moves hit."
			break
		}
		Write-Progress -Activity "Converting to thin" -status ($vm.Name) -percentComplete ($i / $vms.Count*100)
		#get a datastore
		$datastore = findDataStore $vm.ProvisionedSpaceGB
		if ($datastore){
			Move-VM -VM $vm -Datastore $datastore -Confirm:$false -DiskStorageFormat Thin -RunAsync
		}else{
			Write-Host "Couldn't move $vm.Name"
		}
		$i++
	}
}

Write-Host "All Done"