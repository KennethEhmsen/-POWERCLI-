
param(
	[Switch] $migrate,
	[Switch] $templates,
    [parameter(Mandatory=$true)] $datastore_cluster,
    [parameter(Mandatory=$true)] $datastore,
	[Int] $max_moves = 20,
	[Int] $max_vm_size = 99999
    )
	
$ErrorActionPreference = "Stop"

if($templates){
	Write-Host "Gather Templates"
    $tps = Get-Template -datastore $datastore
}else{
	Write-Host "Gather VMs"
	$vms = Get-VM -Datastore $datastore
}

$datastore_ids = Get-DatastoreCluster -name $datastore_cluster | select -ExpandProperty Id
function get_machines_to_move {
	param(
	[parameter(Mandatory=$true)]
	$machines
	)
	
	$need_to_move = @()
    
	foreach($m in $machines){
        $b = $false
		foreach($did in $m.DatastoreIdList){
			if($datastore_ids -notcontains $did){
				$b = $true
				break
			}
		}
		if ( $b -and $m.provisionedSpaceGB -lt $max_vm_size){
            $need_to_move += $m
		}
	}
	return $need_to_move
}

Write-Host "Max Moves: " $max_moves

if($templates){
	$templates_to_move = get_machines_to_move -machines $tps
	write-host "Templates to move: " $templates_to_move.Length $templates_to_move
}else{
	$vms_to_move = get_machines_to_move -machines $vms
	write-host "VMs to move: " $vms_to_move.Length
	Write-Host "Space Needed: " ($vms_to_move | Measure-Object ProvisionedSpaceGB -Sum).sum
}

if($migrate){
	Write-Host "DO the migration"
	. ./consolidate_cluster_storage
	
	if($templates){
		move_templates -dest_datastore_cluster $datastore_cluster -temps_to_move $templates_to_move[0..($max_moves-1)]
	}else{
		move_vms -dest_datastore_cluster $datastore_cluster -vms_to_move $vms_to_move[0..($max_moves-1)]
	}
}