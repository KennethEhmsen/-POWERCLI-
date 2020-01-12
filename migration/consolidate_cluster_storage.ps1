<#
	BLARG
#>

$ErrorActionPreference = "Stop"

function change-datastore($vm, $dsc){
	<#
		This is a function that someone on VMware Communities wrote to get 
		around a bug I found in this release of PowerCLI .
                (Believed still present in 5.1-2, but should verify.)
	#>
    if ( $vm.ExtensionData.DisabledMethod.Contains("RelocateVM_Task") ){
        Write-Host "Relocate Task already running for vm: " $vm.name
        return
    }
	$storMgr = Get-View StorageResourceManager
	$storageSpec = New-Object VMware.Vim.StoragePlacementSpec
	$storageSpec.type = "relocate"
	$storageSpec.priority = "defaultPriority"
	$storageSpec.vm = $vm.ExtensionData.MoRef
	
	$pod = New-Object VMware.Vim.StorageDrsPodSelectionSpec
	$pod.storagePod = $dsc.ExtensionData.MoRef

	$storageSpec.podSelectionSpec += $pod
	Write-Host "Asking to recommend datastore...."
    try{
	    $storPlacement = $storMgr.RecommendDatastores($storageSpec)
    }
    catch {
        Write-host "unable to recommend Datastore, skipping!"
        return
    }
    
    try {
	    $tgtDS = $storPlacement.Recommendations[0].Action[0].Destination
    }
    catch{
        Write-Host "Storage Recommendation null"
        return
    }
    
    $rds = get-datastore -id $tgtDS
    if ( (($rds.FreeSpaceGB - ($rds.CapacityGB * .20) - $vm.provisionedspacegb) -lt 0.0)) {
        write-host $rds.Name " has exceed capacity threshold: " ($rds.FreeSpaceGB - ($rds.CapacityGB * .20)) "GB free"
        return
    }
    else {
        write-host $rds.Name "has" $rds.FreeSpaceGB "free" ($rds.FreeSpaceGB / $rds.CapacityGB)"%"
    }
    
	$spec = New-Object VMware.Vim.VirtualMachineRelocateSpec
	$spec.datastore = $tgtDS
	$vm.ExtensionData.Config.Hardware.Device |
	where {$_ -is [VMware.Vim.VirtualDisk]} | %{
	  $disk = New-Object VMware.Vim.VirtualMachineRelocateSpecDiskLocator
	  $disk.diskId = $_.Key
	  $disk.datastore = $tgtDS
	  $disk.diskBackingInfo = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
	  $disk.diskBackingInfo.fileName = $_.Backing.FileName
	  $disk.diskBackingInfo.datastore = $tgtDS
	  $disk.diskBackingInfo.diskMode = "persistent"
	  $disk.diskBackingInfo.split = $false
	  $disk.diskBackingInfo.writeThrough = $false
	  $disk.diskBackingInfo.thinProvisioned = $true
	  $disk.diskBackingInfo.eagerlyScrub = $false
	  $disk.diskBackingInfo.uuid = $_.Backing.Uuid
	  $disk.diskBackingInfo.contentId = $_.Backing.ContentId
	  $disk.diskBackingInfo.digestEnabled = $false

	  $spec.disk += $disk
	}
	Write-Host "calling relocatevm_task for vm: " $vm.Name ([Math]::Truncate($vm.provisionedspacegb)) "GB"
	return $vm.ExtensionData.RelocateVM_Task($spec, $null)
}

function move_vms{
	param(
    [parameter(Mandatory=$true)] $dest_datastore_cluster,
	[parameter(Mandatory=$true)] $vms_to_move
	)
		
	if($vms_to_move){
		$dsc = Get-DatastoreCluster -Name $dest_datastore_cluster
		
		Write-Host "Begin VM Storage Migration`n-----------------"
		#Move all the VMs
		foreach ($v in $vms_to_move) {
			Write-Host "Move: " $v.Name ([Math]::Truncate($v.provisionedspacegb)) "GB"
			#This is the command that should work once they fix the bug
			#Move-VM -Datastore $dsc.Name -VM $v.Name -DiskStorageFormat Thin -RunAsync
			#In the mean time use the function above:
			change-datastore $v $dsc
            Write-Host "----------------------------"
		}
	}
}

function move_templates{
	param(
    [parameter(Mandatory=$true)] $dest_datastore_cluster,
	[parameter(Mandatory=$true)] $temps_to_move
	)
	
	if($temps_to_move){
		$dsc = Get-DatastoreCluster -Name $dest_datastore_cluster
		
		Write-Host "Begin Template Storage Migration"
		#Move all the Templates
		foreach ($t in $temps_to_move) {
			Write-Host "Move: " $t.Name
			#convert to VM
			Set-Template -Template $t -ToVM
			
			$vm = Get-VM $t
            #special code for mm01
            $cluster = get-cluster -vm $vm
            $dsc = get-datastorecluster -name ("sp-"+$cluster.name)
			
			#This is the command that should work once they fix the bug. (Believed still not as of 5.1-2, but should verify.)
			#Move-VM -Datastore $dsc.Name -VM $v.Name -DiskStorageFormat Thin -RunAsync
			#In the mean time use the function above:
			$task = change-datastore $vm $dsc
			write-host "task: " $task
			do {
				$status = Get-VIObjectByVIView $task
				Start-Sleep -Seconds 2
				Write-Progress -Activity "Moving Templates" -status ("Processing: "+$tc+" of "+ $cluster_templates.Count) -percentComplete ($status.PercentComplete)
			} while ($status.PercentComplete -ne 100)
            if ($status.State -ne 'Success') {
                $task = change-datastore $vm $dsc
			    write-host "task: " $task
			    do {
				    $status = Get-VIObjectByVIView $task
				    Start-Sleep -Seconds 2
				    Write-Progress -Activity "Moving Templates" -status ("Processing: "+$tc+" of "+ $cluster_templates.Count) -percentComplete ($status.PercentComplete)
			    } while ($status.PercentComplete -ne 100)
            }
			
			#convert back to template
			Set-VM -VM (Get-VM $t) -ToTemplate -Confirm:$False
		}
	}
}
