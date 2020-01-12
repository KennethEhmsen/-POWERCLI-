# Usage Instructions:
# preload cluster and resource pool parameters:
# $source_cluster = get-cluster mm01-cld99
# $target_cluster = get-cluster mm01-cld98
# $pools_to_move = get-resourcepool -name env-prod-9999-9999 -location $source_cluster 
# $folder = "9999"
#  C:\> .\migrate_rp_to_cluster_async.ps1 -source_cluster $source_cluster -target_cluster $target_cluster -pools_to_move $pools_to_move -folder $folder -db_server "10.xxx.xx.xx" -db_pass "lolwtf"

# Migrates one or more resource pools and all contained subpools and VMs from
# one cluster to another:
# 1) Copies the resource pool structure and settings
# 2) Updates the database records to keep appcenter in sync with vcenter
# 3) Migrate VMs, using storage vmotion if needed (destination must have pod)
# 4) Replicates affinity rules.
# 5) Removes old resource pools in original cluster.

# New features 4/17/2015:
# - Added checks for customers using Zerto, SSD storage and Encrypted storage.
#     These customers need manual steps resolved before migrating to a new cluster.
# - Check for vmware tools installations and terminate the installation 
# - Check for cdrom mounted isos
# - check for sufficient disk space on target storage pod

param(
    [parameter(Mandatory=$true)] $source_cluster,
    [parameter(Mandatory=$true)] $target_cluster,
    [parameter(Mandatory=$true)] $pools_to_move,
    [parameter(Mandatory=$true)] $folder,
    [parameter(Mandatory=$true)] $db_server,
    [parameter(Mandatory=$true)] $db_pass,
    [parameter(Mandatory=$false)] $customer_id
)

$ErrorActionPreference = "Stop"
$global:NDB_DEBUG = $false

. ..\utils\db_util.ps1

#static list of ssd and encrypted storage pods
$SSD_STORAGE_PODS = @("ssd-mm02-cld01", "sp-mm01-cld08", "sp-mm01-cld05", "sp-sj01-cld04")
if (!$customer_id){
    $customer_id = $folder.Substring($folder.length - 6).trimstart("(").trimend(")")
    Write-Host "using customer id: " $customer_id
}

# DRS and Datastore globals
# NOTE: global arrays must be prefixed by $global: or $script: in functions,
#       but not hashtables.  :-?
$DRS_RULES_TO_MOVE = @()
$VMS_TO_MOVE = @{}
$ACTIVE_MIGRATIONS = @{}
$TARGET_HOSTS = Get-VMHost -Location $target_cluster
$vm_datastore_table = @{}

write-host "Getting mounted datastores in target cluster..."
$t_host = $TARGET_HOSTS[1]
$TARGET_DATASTORES = ($t_host | Get-Datastore | where { $_.state -eq 'Available'})
#$script:TARGET_DS_CLUSTER = Get-Datastorecluster -Name ("sp-" + $target_cluster.Name)
#write-host "target_ds_cluster: " $TARGET_DS_CLUSTER

function check_zerto {
    param( [parameter(Mandatory=$true)] $customer_id,
           [parameter(Mandatory=$true)] $dbc)
    $zerto_ids = ndb_query_single_field $dbc ("select zerto_id from cl_zerto_environment_lnk where environment_uuid in (select uuid from cl_environment where customer_id = " + $customer_id + ")")
    if ($zerto_ids){
        return $true
    }
    return $false
}

function check_ssd {
    param( [parameter(Mandatory=$true)] $vms)
    foreach($vm in $vms) {
        $dc = get-datastorecluster -vm $vm
        if($dc){
            if($SSD_STORAGE_PODS -contains $dc){
                write-host $vm " contains disks on SSD SAN"
                return $true
            }
        }
    }
    return $false
}


#select a random datastore for vm in datastore cluster
function pick_datastore {
    param(
    [parameter(Mandatory=$true)] $vm,
    [parameter(Mandatory=$true)] $dsc
    )
    $datastores = (get-datastore -location $dsc)|sort {[System.Guid]::NewGuid()}
    foreach ($datastore in $datastores){
        $pendingUsedGB = 0
        #check to see if there are any running tasks copying into the datastore
        foreach ($row in $script:vm_datastore_table.GetEnumerator() ) {
            if ($row.value[1] -eq $datastore.name) {
                $pendingUsedGB += ($row.value[0].usedspacegb)
            }
        }
        #check datastore capacity
        if ( ($datastore.FreeSpaceGB/$datastore.CapacityGB -gt .10) -and ($vm.provisionedspacegb -lt ($datastore.freespacegb - ( ($datastore.Capacitygb *.10) + $pendingUsedGB) )) ) {
        #if ( ($datastore.FreeSpaceGB/$datastore.CapacityGB -gt .10) -and ($vm.provisionedspacegb -lt ($datastore.freespacegb - ( ($datastore.Capacitygb *.10) + $pendingUsedGB) )) ) {
            write-host $pendingUsedGB "GB copy in progress for: " $datastore.name
            return $datastore
        }
    }
    write-host "unable to select sufficient space on datastores within " $dsc.name " for vm: " $vm.name " size: " $vm.usedspacegb "GB "
    return $null
}

# Pick a random host (with enough memory if $vm is powered on)
function pick_host {
    param(
	[parameter(Mandatory=$true)] $vm
    )
    $rand_hosts = $TARGET_HOSTS | Get-Random -Count $TARGET_HOSTS.Count
    foreach ($h in $rand_hosts) {
	    if (($vm.PowerState -eq 'PoweredOff') -or (($h.MemoryTotalGB - $h.MemoryUsageGB) -gt ($vm.MemoryGB + 4))) {
	        return $h
	    }
    }
    return $null
}    

function migrate_vm {
    param(
	    [parameter(Mandatory=$true)] $vm,
	    [parameter(Mandatory=$true)] $target_pool	    
    )

    # Store any DRS rules applying to it.
    $rules = @(Get-DrsRule -Cluster $source_cluster -VM $vm)
    if ($rules.count -gt 0) {
	    write-host ("      rules: " + $rules)
	    $fname = ("rules_" + $source_cluster.Name + "_" + $vm.Name + "_" + (Get-Random -Maximum 10000) + ".csv")
	    $rules | Export-Csv $fname
	    write-host ("        (written to " + $fname + ")")
	    $script:DRS_RULES_TO_MOVE += $rules
    }

    $vmds = Get-Datastore -VM $vm
    $easy_move = $true
    foreach ($vmd in $vmds) {
	    if ($TARGET_DATASTORES -notcontains $vmd) {
	        $easy_move = $false
	        break
	    }
    }
    
    $vmspec = New-Object vmware.vim.virtualmachinerelocatespec
    $vmspec.Pool = $target_pool.ExtensionData.MoRef
    $t_host = pick_host -vm $vm
    if ($t_host -ne $null){
        $vmspec.host = $t_host.extensiondata.moref
    }
    else{
        write-host "unable to select target host for vm: " $vm.name
    }

    if ($easy_move) {
        # relocate the vm to the target pool on the same datastore
        write-host "relocating " $vm.name " to " $target_pool
        $task = $vm.ExtensionData.RelocateVM_Task($vmspec, $null)
        $script:ACTIVE_MIGRATIONS.add($task, $task)

    }
    else{
        # relocate the vm to the target pool and change the datastore
        $dsc_datastore = pick_datastore -vm $vm -dsc $TARGET_DS_CLUSTER
        if ($dsc_datastore -eq $null){
            write-host "unable to relocate vm: " $vm.name " unable to select target datastore"
            return $null
        }
        $vmspec.Datastore = $dsc_datastore.ExtensionData.MoRef
        write-host "relocating " $vm.name " to " $target_pool $dsc_datastore.name
        $task = $vm.ExtensionData.RelocateVM_Task($vmspec, $null)
        $script:ACTIVE_MIGRATIONS.add($task, $task)
        $script:vm_datastore_table.Add($vm.id, @($vm, $dsc_datastore.name))
    }
}

function migrate_vms {
    param(
	[parameter(Mandatory=$true)] $vms,
	[parameter(Mandatory=$true)] $target_pool
    )
    write-host $vms.count " vms to migrate"

	$toschedule = 0
	$queued = 0
	$vms | % {
		if ($toschedule -eq 0){
			while ($true) {
				$toschedule = 6 - (get_running_tasks -tasks $script:ACTIVE_MIGRATIONS)
				if ($toschedule -ne 0) {
					break
				}	
				sleep 5
			}
		}

		if ( $_.ExtensionData.DisabledMethod.Contains("RelocateVM_Task")) {
            Write-Host "Relocate Task already running for vm: " $_.name
        }
        else{
            migrate_vm $_ $target_pool
		}
		$toschedule -= 1
		$queued += 1
		write-host $queued "/" $vms.count "initiated"
	}
}

function change-datastore {
    param(
    [parameter(Mandatory=$true)] $vm,
    [parameter(Mandatory=$true)] $dsc
    )
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
    $task = $vm.ExtensionData.RelocateVM_Task($spec, $null)
    $script:ACTIVE_MIGRATIONS.add($task, $task)
    $script:vm_datastore_table.Add($vm.id, @($vm, $tgtDS.name))
    write-host "added" $vm.id "and" $tgtDS.name "to table"
}

function migrate_tmpls {
    param(
	[parameter(Mandatory=$true)] $templates,
	[parameter(Mandatory=$true)] $target_cluster
    )

    foreach ($template in $templates) {
	    # First, see if it's already in the target cluster.
	    if ($TARGET_HOSTS -contains (Get-VMHost -Id $template.HostId)) {
	        write ("    " + $template.name + ": skipping - already migrated")
	        continue
	    }
        $vm = Set-Template -Template $template -ToVM
	    migrate_vm_old $vm $target_cluster -async:$false
        Set-VM -VM $vm -ToTemplate -Confirm:$False -RunAsync:$true | Out-Null
	}
}

# Move VM to target pool:
# - S tore any DRS rules applying to it.
# - Check if all its datastores are mounted in the target_cluster.
# -> If so, just move the VM
# -> If not, specify the target DS cluster (we don't support without cluster)
# NOTE: the -async parameter is currently IGNORED, since we always need to do
# two moves, first to the host/cluster and then to the resource pool
function migrate_vm_old {
    param(
        [parameter(Mandatory=$true)] $vm,
        [parameter(Mandatory=$true)] $target_pool,
        [Switch] $async
    )

    $rules = @(Get-DrsRule -Cluster $source_cluster -VM $vm)
    if ($rules.count -gt 0) {
         write-host (" rules: " + $rules)
         $fname = ("rules_" + $source_cluster.Name + "_" + $vm.Name + "_" + (Get-Random -Maximum 10000) + ".csv")
         $rules | Export-Csv $fname
         write-host (" (written to " + $fname + ")")
         $script:DRS_RULES_TO_MOVE += $rules
    }

    $vmds = Get-Datastore -VM $vm
    $easy_move = $true
    foreach ($vmd in $vmds) {
         if ($TARGET_DATASTORES -notcontains $vmd) {
         $easy_move = $false
         break
         }
    }

    <# PENDING: We would like to only pick the host ourselves when the VM
is not running. But we cannot specify a datastore when moving a VM to
a cluster, and if we do not specify it then the vmotion fails. #>
    if ($vm.PowerState -eq "PoweredOff" -or $vm.PowerState -eq "PoweredOn") {
         $dest = pick_host $vm
         if ($dest -eq $null) {
            write-host ("Unable to find host w/enough memory for VM " + $vm.name + "; ABORT")
         exit
         }
    } else {
         $dest = $target_cluster
    }

    if ($easy_move) {
         $msg = " (same datastore)"
    } else {
         $msg = " (different datastore)"
    }
    write-host (" " + $vm.Name + " -> " + $dest.Name + " / " + $target_pool.name + $msg)
    if ($easy_move) {
         Move-VM -VM $vm -Destination $dest -Confirm:$false
         Move-VM -VM $vm -Destination $target_pool -Confirm:$false
    } else {
         if ($TARGET_DS_CLUSTER -eq $null) {
         write-host ("unable to locate target datastore cluster, ABORT")
         exit
         }
        write-host "VM:" $vm
        write-host "DEST:" $dest
         $dsc_datastore = pick_datastore -vm $vm -dsc $TARGET_DS_CLUSTER
            if ($dsc_datastore -ne $null){
                Move-VM -VM $vm -Destination $dest -Datastore $dsc_datastore -Confirm:$false
                write-host "moved " $vm " to host " $dest " datastore " $dsc_datastore
                Move-VM -VM $vm -Destination $target_pool -Confirm:$false
            }
    }
}


function copy_pool {
    param(
	[parameter(Mandatory=$true)] $pool,
	[parameter(Mandatory=$true)] $target_container
    )

    # First, check if it already exists (assume same name is enough)
    $res = Get-ResourcePool -Location $target_container -Name $pool.Name -NoRecursion -ErrorAction Ignore
    if ($res -ne $null) {
        write-host "pool " $pool.Name " already exists in target cluster"
	    return $res
    }

    # OK, let's make it (unf no copy function)
    write-host "creating " $pool.Name " in " $target_container
    $res = New-ResourcePool -Location $target_container -Name $pool.Name `
      -CpuExpandableReservation $pool.CpuExpandableReservation `
      -CpuLimitMhz $pool.CpuLimitMhz `
      -CpuReservationMhz $pool.CpuReservationMhz `
      -CpuSharesLevel $pool.CpuSharesLevel `
      -MemExpandableReservation $pool.MemExpandableReservation `
      -MemLimitMB $pool.MemLimitMB `
      -MemReservationMB $pool.MemReservationMB `
      -MemSharesLevel $pool.MemSharesLevel `
      -Verbose:$false -confirm:$false
    if ($pool.CpuSharesLevel -eq 'custom') {
	    Set-ResourcePool -ResourcePool $res -NumCpuShares $pool.NumCpuShares
    }
    if ($pool.MemSharesLevel -eq 'custom') {
	    Set-ResourcePool -ResourcePool $res -NumMemShares $pool.NumMemShares
    }

    return $res
}


# Create pool copy, store VMs and templates for move, recurse to subpools.
function copy_pool_deep {
    param(
	[parameter(Mandatory=$true)] $pool,
	[parameter(Mandatory=$true)] $target_container
    )

    $target_pool = copy_pool $pool $target_container
    $vms = @(Get-VM -Location $pool -NoRecursion)
    #move the larger vms first
    $vms = $vms |sort -Property usedspacegb 
    if ($vms.count -gt 0) {
	    $VMS_TO_MOVE.Add($target_pool, $vms)
    }
    foreach ($subpool in @(Get-ResourcePool -Location $pool -NoRecursion -ErrorAction Ignore)) {
	    copy_pool_deep $subpool $target_pool
    }
}


# Remove pool if it contains no templates or VMs
function remove_pool_safe {
    param(
	[parameter(Mandatory=$true)] $pool
    )
    $c = @(Get-VM -Location $pool).count
# + @(Get-Template -Location $pool).count
	    if ($c -eq 0) {
	        write-host ("    Removing resource pool " + $pool.Name)
	        Remove-ResourcePool -ResourcePool $_ -Confirm:$false
	    } else {
	        write-host ("    NOT Removing resource pool " + $pool.Name + "; it has " + $c + "VMs/templates left.")
	    }
}


# Return an array of custID and pool ID, or null.
function get_cust_and_pool {
    param(
	[parameter(Mandatory=$true)] $pool
    )

    if (-not ($pool.Name -match '[a-zA-Z]+-[a-zA-Z]+-([0-9]+)-([0-9]+)')) {
	return $null
    }

    return @($matches[1], $matches[2])
}


function copy_drs_rule {
    param(
	[parameter(Mandatory=$true)] $rule,
	[parameter(Mandatory=$true)] $target_cluster
    )

    write-host ("    Rule: " + $rule.Name)
	New-DrsRule -cluster $target_cluster -Name $rule.Name -Enabled $rule.Enabled `
	  -KeepTogether $rule.KeepTogether -RunAsync:$true -Confirm:$false `
	  -VM ($rule.VMIds | % { Get-VM -Id $_ })
}


function find_templates {
    param(
	[parameter(Mandatory=$true)] $pools
    )

    $res = @()
    foreach ($pool in $pools) {
	    $cust_pool = get_cust_and_pool $pool
	    if ($cust_pool -eq $null) {
    	    write-host "Resource pool name '$($pool.Name)' does not match expected pattern.  ABORT"
	        exit
	    }
	    $custId = $cust_pool[0]
	    $poolId = $cust_pool[1]
    
	    $folder = Get-Folder -Name $custId -ErrorAction Ignore
	    #write-host ("Search templates in folder '" + $folder + "'")
	    if ($folder -ne $null) {
	        $res += Get-Template -Location $folder
	    }
    }
    return $res
}

function get_running_tasks {
    param(
    [parameter(Mandatory=$true)] $tasks
    )
    $running = 0
    
    if ($tasks.count -le 0){
        write-host "no tasks running"
        return $running
    }
    foreach ($task in @($tasks.keys)) {
        $test = get-task -id $tasks[$task] -erroraction Ignore
        if($test){
            if ($test.State -eq "Running"){
                $running += 1
            }
            else{
                #remove vm from datastore table and active table
                if($script:vm_datastore_table.ContainsKey($test.objectid)) {
                    $vm_name = $script:vm_datastore_table[$test.objectid][0].name
                    $script:vm_datastore_table.Remove($test.objectid)
                    $script:ACTIVE_MIGRATIONS.Remove($test.extensiondata.moref)
                    write-host "task complete for vm: " $vm_name
                }
                else{
                    write-host "unable to remove non-running task from table"
                }
            }
        }
        else{
            write-host "task not returned from get-task call"
            $running += 1
        }
    }
    write-host $running "tasks running"
    return $running
}

##############################################################################
# Main
# Set resource pools to all in cluster (under 'Resources') if no arg given.


if ($pools_to_move -eq $null) {
    $pools = @(Get-ResourcePool -Location (Get-ResourcePool -Location $source_cluster -NoRecursion -ErrorAction Ignore) -NoRecursion -ErrorAction Ignore)
} else {
    $pools = $pools_to_move
}

$db_conn = ndb_get_connection $db_server "clouddb" "cloud" $db_pass
if(check_zerto -dbc $db_conn -customer_id $customer_id){
    write-host "Zerto customer detected, exiting."
    exit
}

write-host "target_ds_cluster free space: " $TARGET_DS_CLUSTER.freespacegb
    
$vms = get-vm -location $folder
write-host $vms.count "total vms in folder"

write-host "checking for SSD vms..."
if(check_ssd -vms $vms){
    write-host "VMS found on SSD storage pod. exiting."
    exit
}

#locate and terminate vmware tools installations
write-host "checking for vmware tools installation cd..."
$tools_mounted_vms = $vms| Get-View | Where {$_.Runtime.ToolsInstallerMounted} | % {$_.Name}
if ($tools_mounted_vms.count -gt 0){
    write-host "vmware tools mounted on " $tools_mounted_vms.count " vms. Running unmount command..."
    $tools_mounted_vms | % {Dismount-Tools -vm $_}
}

#check for mounted cd-rom
write-host "checking for mounted isos..."
$res_cd = $vms | where { $_ | get-cddrive | where { $_.ConnectionState.Connected -eq "true" -and $_.ISOPath -like "*.ISO*"} } | select Name, @{Name=".ISO Path";Expression={(Get-CDDrive $_).isopath }}
if ($res_cd) {
    write-host $res_cd.count " vms have isos mounted"
    write-host $res_cd
    write-host "exiting..."
    exit
}

#locate airlock vm and change storage pod
try{
    $airlock_rp = get-resourcepool "Airlock-Prod"
}catch{
    $airlock_rp = get-resourcepool "Airlock"
}
foreach ($vm in $vms) {
    if($vm.extensiondata.resourcepool.value -eq $airlock_rp.extensiondata.moref.value){
        $dsc = get-datastorecluster -vm $vm
        if($dsc.name -ne $TARGET_DS_CLUSTER.name) {
            write-host "located airlock vm: " $vm.name
            #change-datastore -vm $vm -dsc $TARGET_DS_CLUSTER
        }
    }
}

# Copy pools and update the database
write-host ("Copying " + $pools.count + " pool...")
$top_target_pool = Get-ResourcePool -Location $TARGET_CLUSTER -NoRecursion
$pools | % {
    write-host ("    " + $_.Name + "...")
    copy_pool_deep $_ $top_target_pool
    write-host "    done"
}

# Migrate Templates synchronously
$tmpls = find_templates $pools
if ($tmpls.count -gt 0) {
    write-host "Migrating templates (synchronously)..."
    $tmpls | % { migrate_tmpls $_ $target_cluster } | out-null
} else {
    write-host "No templates to migrate."
}

# Migrate VMs partially asynchronously
write-host "Kicking off VM migrations..."
$VMS_TO_MOVE.GetEnumerator() | % { migrate_vms ($_.value) ($_.key) } | out-null

# Wait for all migrations to finish...
write-host "Waiting for migrations to finish."
$runningTasks = $ACTIVE_MIGRATIONS.count
while ($runningTasks -gt 0) {
    $runningTasks = get_running_tasks -tasks $script:ACTIVE_MIGRATIONS 
    write-host ("    " + $runningTasks + " outstanding")
    if ($runningTasks -gt 0){
        Start-Sleep -Seconds 60
    }
}

write-host "Copying rules"
$DRS_RULES_TO_MOVE | % { copy_drs_rule $_ $target_cluster }

write-host "Removing empty resource pools"
$pools | % { remove_pool_safe $_ }

write-host "DONE."