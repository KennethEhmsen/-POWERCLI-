param(
    [parameter(Mandatory=$true)] $source_cluster,
    [parameter(Mandatory=$true)] $source_vcenter,
    [parameter(Mandatory=$true)] $target_cluster,
    [parameter(Mandatory=$true)] $target_vcenter,
    [parameter(Mandatory=$true)] $target_storage_pod,
    [parameter(Mandatory=$true)] $pools_to_move,
    [parameter(Mandatory=$true)] $folder,
    [parameter(Mandatory=$true)] $db_server,
    [parameter(Mandatory=$true)] $db_pass,
    [parameter(Mandatory=$true)] $customer_id,
    [parameter(Mandatory=$false)] $vm_name_list,
    [parameter(Mandatory=$false)] $target_pool_name
)

. ..\utils\db_util.ps1
$migration_start_date = get-date

$db_conn = ndb_get_connection $db_server "clouddb" "cloud" $db_pass

$sj_prod_thumb = "35:97:53:68:27:4F:4D:E2:B6:2A:9E:F4:7C:A7:05:5C:74:BE:2C:69"
$sc_prod_thumb = "A7:DA:A3:A2:E4:5C:1E:46:D2:10:B4:AD:DB:21:5F:99:C1:E5:92:74"
$thumbprint = $sc_prod_thumb

#####################################################
# set the correct vdc_id for db migration (cladm_vdc)
#  vdc_id | vcenter_id |  vdc_name  
#--------+------------+------------
#   1000 |       1000 | Andover
#   1020 |       1020 | SanJose
#   1041 |       1041 | Woking
#   1042 |       1042 | Andover02
#   1043 |       1043 | RedHill
#   1045 |       1045 | SantaClara
$source_vdc_id = 1020
$source_vdc_path_name = "/SanJose/"
$destination_vdc_id = 1045
$destination_vdc_path_name = "/SantaClara/"
$destination_env_name = "SantaClara - My Environment"
#####################################################
# dvs_id |  type  |     ip      |         name         
#--------+--------+-------------+----------------------
#      4 | VMWARE | 0.0.0.0     | Andover02-dvSwitch01 
#      6 | VMWARE | 0.0.0.0     | Andover01-dvSwitch01 
#      5 | VMWARE | 0.0.0.0     | SanJose-dvSwitch01   
#      7 | VMWARE | 0.0.0.0     | Wouk01-dvSwitch01    
#   1003 | VMWARE | 0.0.0.0     | reuk01-dvSwitch01    
#   1004 | VMWARE | 0.0.0.0     | scca01-dvSwitch01    
$destination_dvs_id = 1004
# set the anyconnect based on the cladm_anyconnect (anyconnect_url)
$destination_anyconnect = "204.216.80.6"
#####################################################

$ErrorActionPreference = "Stop"
$global:NDB_DEBUG = $false

$source_vc = connect-viserver $source_vcenter
$source_cl = get-cluster -server $source_vc -name $source_cluster 
$source_pool = get-resourcepool -server $source_vc -name $pools_to_move

$target_vc = connect-viserver $target_vcenter
$target_cl = get-cluster -server $target_vc -name $target_cluster
$target_hosts = get-vmhost -server $target_vc -location $target_cl
$t_airlock_host = get-vmhost -server $target_vc -location "Airlock"
$target_datastores = get-datastore -server $target_vc -location $target_storage_pod

$destFolder = get-folder -server $target_vc -name $folder -erroraction Ignore
if ($destFolder -eq $null) {
    write-host "Creating folder on destination vCenter"
    $env_prod_folder = get-folder -server $target_vc -name "env-prod"
    new-folder -server $target_vc -name $folder -location $env_prod_folder
    $destFolder = get-folder -server $target_vc -name $folder
}


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
$TARGET_HOSTS = get-vmhost -server $target_vc -Location $target_cl
$vm_datastore_table = @{}

write-host "Getting mounted datastores in target cluster..."
$t_host = $TARGET_HOSTS[1]
$TARGET_DATASTORES = ($t_host | Get-Datastore | where { $_.state -eq 'Available'})
$script:TARGET_DS_CLUSTER = Get-Datastorecluster -Name ("sp-" + $target_cl.Name)
write-host "target_ds_cluster: " $TARGET_DS_CLUSTER

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
    param( [parameter(Mandatory=$true)] $vms,
           [parameter(Mandatory=$true)] $vcenter
         )
    foreach($vm in $vms) {
        $dc = get-datastorecluster -server $vcenter -vm $vm
        if($dc){
            if($SSD_STORAGE_PODS -contains $dc){
                write-host $vm " contains disks on SSD SAN"
                return $true
            }
        }
    }
    return $false
}

#determine free space on destination storage pod.
function check_free_space {
    param(
	[parameter(Mandatory=$true)] $vms,
	[parameter(Mandatory=$true)] $destination_pod
    )

    $total_vm_usage = 0
    $usable_space = ($destination_pod.freespacegb - ($destination_pod.capacitygb * .10))
    write-host "usable space: " $usable_space
    $total_vm_usage = ($vms | Measure-Object -Property usedspacegb -Sum).sum
    write-host "total vm usage: " $total_vm_usage
    return ($total_vm_usage -lt $usable_space)
}

#select a random datastore for vm in datastore cluster
function pick_datastore {
    param(
    [parameter(Mandatory=$true)] $vm,
    [parameter(Mandatory=$true)] $dsc,
    [parameter(Mandatory=$true)] $vcenter
    )
    $datastores = (get-datastore -server $vcenter -location $dsc)|sort {[System.Guid]::NewGuid()}
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
	    [parameter(Mandatory=$true)] $target_pool,
        [parameter(Mandatory=$false)] $in_airlock	    
    )



    ###############################################################################
    $rspec = New-Object VMware.Vim.VirtualMachineRelocateSpec
    $rspec.folder = $destFolder.id
    $rspec.pool = $target_pool.extensiondata.moref

    # New Service Locator required for Destination vCenter Server when not part of same SSO Domain
    $service = New-Object VMware.Vim.ServiceLocator
    $credential = New-Object VMware.Vim.ServiceLocatorNamePassword
    $credential.username = (Get-VICredentialStoreItem -Host $target_vcenter).user
    $credential.password = (Get-VICredentialStoreItem -Host $target_vcenter).password
    $service.credential = $credential
    $service.instanceUuid = $target_vc.InstanceUuid.toUpper()
    $service.sslThumbprint = $thumbprint
    $service.url = ("https://" + $target_vcenter)
    $rspec.service = $service

    $rspec.deviceChange = New-Object VMware.Vim.VirtualDeviceConfigSpec[]($vm.networkadapters.count)
    $devices = $vm.extensiondata.Config.Hardware.Device
    $i = 0
    foreach ($device in $devices) {
        if($device -is [VMware.Vim.VirtualEthernetCard]) {
          $rspec.deviceChange[$i] = New-Object VMware.Vim.VirtualDeviceConfigSpec
          $rspec.deviceChange[$i].Operation = "edit"
          $rspec.deviceChange[$i].Device = $device
          $nic = get-networkadapter -vm $vm -name $device.DeviceInfo.label
          $destPG = get-vdportgroup -server $target_vc -name $nic.networkname
          $dvSwitchUuid = (Get-View -server $target_vc -Id $destPG.extensiondata.Config.DistributedVirtualSwitch).Summary.Uuid
          $rspec.deviceChange[$i].Device.Backing = New-Object VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo
          $rspec.deviceChange[$i].Device.Backing.Port = New-Object VMware.Vim.DistributedVirtualSwitchPortConnection
          $rspec.deviceChange[$i].Device.Backing.Port.PortgroupKey = $destPG.key
          $rspec.deviceChange[$i].Device.Backing.Port.SwitchUuid = $dvSwitchUuid
          $i++
       }
    }
    #####################################################################################
    if($in_airlock){
        $rspec.host = $t_airlock_host.extensiondata.moref
    }
    else {
        # Store any DRS rules applying to it.
        $rules = @(Get-DrsRule -Cluster $source_cluster -VM $vm -erroraction Continue)
        if ($rules.count -gt 0) {
	        write-host ("      rules: " + $rules)
	        $fname = ("rules_" + $source_cluster.Name + "_" + $vm.Name + "_" + (Get-Random -Maximum 10000) + ".csv")
	        $rules | Export-Csv $fname
	        write-host ("        (written to " + $fname + ")")
	        $script:DRS_RULES_TO_MOVE += $rules
        }
        $t_host = pick_host -vm $vm
        if ($t_host -ne $null){
            $rspec.host = $t_host.extensiondata.moref
        }
        else{
            write-host "unable to select target host for vm: " $vm.name
        }
    }

  
    # relocate the vm to the target pool and change the datastore
    $dsc_datastore = pick_datastore -vm $vm -dsc $TARGET_DS_CLUSTER -vcenter $target_vc
    if ($dsc_datastore -eq $null){
        write-host "unable to relocate vm: " $vm.name " unable to select target datastore"
        return $null
    }
    $rspec.Datastore = $dsc_datastore.ExtensionData.MoRef
    write-host "relocating " $vm.name " to " $target_pool $dsc_datastore.name
    $task = $vm.ExtensionData.RelocateVM_Task($rspec, $null)
    $script:ACTIVE_MIGRATIONS.add($task, $task)
    $script:vm_datastore_table.Add($vm.id, @($vm, $dsc_datastore.name))
  
}

function migrate_vms_broken {
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
				$toschedule = 6 - (get_running_tasks -tasks $script:ACTIVE_MIGRATIONS $source_vc)
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

function migrate_vms {
    param(
	[parameter(Mandatory=$true)] $vms,
	[parameter(Mandatory=$true)] $target_pool
    )

	$toschedule = 0
	$queued = 0
	foreach ($vm in $vms) {
		if ($toschedule -eq 0){
			while ($true) {
                $r = get_running_tasks -tasks $script:ACTIVE_MIGRATIONS -vcenter $source_vc
				$toschedule = 6 - $r
				if ($toschedule -ne 0) {
					break
				}	
				sleep 5
			}
		}

		if ( $vm.ExtensionData.DisabledMethod.Contains("RelocateVM_Task")) {
            Write-Host "Relocate Task already running for vm: " $_.name
        }
        else{
            migrate_vm $vm $target_pool
		}
		$toschedule -= 1
		$queued += 1
		write-host $queued "/" $vms.count "initiated"
	}
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


function copy_pool {
    param(
	[parameter(Mandatory=$true)] $pool,
	[parameter(Mandatory=$true)] $target_container,
    [parameter(Mandatory=$true)] $vcenter
    )

    # First, check if it already exists (assume same name is enough)
    $res = Get-ResourcePool -server $vcenter -Location $target_container -Name $pool.Name -NoRecursion -ErrorAction Ignore
    if ($res -ne $null) {
        write-host "pool " $pool.Name " already exists in target cluster"
	    return $res
    }

    # OK, let's make it (unf no copy function)
    write-host "creating " $pool.Name " in " $target_container $vcenter.name
    $res = New-ResourcePool -server $vcenter -Location $target_container -Name $pool.Name `
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
	    Set-ResourcePool -server $vcenter -ResourcePool $res -NumCpuShares $pool.NumCpuShares
    }
    if ($pool.MemSharesLevel -eq 'custom') {
	    Set-ResourcePool -server $vcenter -ResourcePool $res -NumMemShares $pool.NumMemShares
    }

    return $res
}


# Create pool copy, store VMs and templates for move, recurse to subpools.
function copy_pool_deep {
    param(
	[parameter(Mandatory=$true)] $pool,
	[parameter(Mandatory=$true)] $target_container,
    [parameter(Mandatory=$true)] $s_vcenter,
    [parameter(Mandatory=$true)] $t_vcenter
    )

    $target_pool = copy_pool $pool $target_container $t_vcenter
    $vms = @(Get-VM -server $s_vcenter -Location $pool -NoRecursion)
    write-host $vms.count "vms count from copy_pool_deep"
    #move the smaller vms first
    $vms = $vms |sort -Property usedspacegb -Descending
    if ($vms.count -gt 0) {
	    $VMS_TO_MOVE.Add($target_pool, $vms)
    }
    foreach ($subpool in @(Get-ResourcePool -server $s_vcenter -Location $pool -NoRecursion -ErrorAction Ignore)) {
	    copy_pool_deep $subpool $target_pool $s_vcenter $t_vcenter
    }
}


# Remove pool if it contains no templates or VMs
function remove_pool_safe {
    param(
	[parameter(Mandatory=$true)] $pool,
	[parameter(Mandatory=$true)] $vcenter
    )
    $c = @(Get-VM -server $vcenter -Location $pool).count
	    if ($c -eq 0) {
	        write-host ("    Removing resource pool " + $pool.Name)
	        Remove-ResourcePool -server $vcenter -ResourcePool $_ -Confirm:$false
	    } else {
	        write-host ("    NOT Removing resource pool " + $pool.Name + "; it has " + $c + "VMs/templates left in " + $vcenter.name)
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

# Change the folder path for the vm being migrated
function migrate_vm_db_record {
    param(
    [parameter(Mandatory=$true)] $vm_instance_uuid,
	[parameter(Mandatory=$true)] $conn
    )
    $vm_path = ndb_query_single_field $conn ("select path from cl_virtual_server where instanceuuid = '" + $vm_instance_uuid + "'")
    $vm_path = $vm_path.replace($source_vdc_path_name, $destination_vdc_path_name)
    $sql = ("update cl_virtual_server set path = '" + $vm_path + "' where instanceuuid = '" + $vm_instance_uuid + "'")
    write-host $sql
    ndb_update $conn $sql
}


# This updates cluster IDs in the tables cl_resource_pool, cladm_provision_hdr,
# and cladm_cluster_fw from the old cluster to the new cluster for the resource
# pools and/or customer-cluster combinations moved.
function migrate_db {
    param(
	[parameter(Mandatory=$true)] $conn,
	[parameter(Mandatory=$true)] $pool
    )
    $cust_pool = get_cust_and_pool $pool
    if ($cust_pool -eq $null) {
	    write-host "Resource pool name '$($pool.Name)' does not match expected pattern.  ABORT"
	    exit
    }
    $custId = $cust_pool[0]
    $poolId = $cust_pool[1]
    
    # get the environment id
    $environment_id = ndb_query_single_field $conn ("select environment_id from cl_environment where customer_id = " + $customer_id + " and vdc_id = " + $source_vdc_id)
    if ($environment_id -eq $null){
        $environment_id = ndb_query_single_field $conn ("select environment_id from cl_environment where customer_id = " + $customer_id + " and vdc_id = " + $destination_vdc_id)
        if($environment_id){
            write-host "CL_ENVIRONMENT already migrated.  environment_id = $environment_id destination_vdc_id = $destination_vdc_id"
        }
    }
    else{
        # update the cl_environment table
        $cl_env_sql = ("update cl_environment set vdc_id = " + $destination_vdc_id + ", name = '" + $destination_env_name + "', anyconnect_ip = '" + $destination_anyconnect + "' where environment_id = " + $environment_id)
        write-host $cl_env_sql
        ndb_update $conn $cl_env_sql
    }

    # We have both cluster_id and vcenter_cluster_id -- lovely...
    $src_vcluster_id = ndb_query_single_field $conn ("select vcenter_cluster_id from cladm_vcenter_cluster where cluster_name = '" + $source_cl.name + "'")
    $src_cluster_id = ndb_query_single_field $conn ("select cluster_id from cladm_cluster where cluster_name = '" + $source_cl.name + "'")
    
    $dst_vcluster_id = ndb_query_single_field $conn ("select vcenter_cluster_id from cladm_vcenter_cluster where cluster_name = '"+ $target_cl.name + "'")
    $dst_cluster_id = ndb_query_single_field $conn ("select cluster_id from cladm_cluster where cluster_name = '"+ $target_cl.name + "'")

    # Update cl_resource_pool
    $sql = ("update cl_resource_pool set vcenter_cluster_id = " + $dst_vcluster_id + " where resource_pool_id = " + $poolId)
    write-host $sql
    write-host ("    (vcenter_cluster_id was " + $src_vcluster_id + ")")
    ndb_update $conn $sql

    # update cl_vlan records to point to target dvs
    $vlan_ids = ndb_query_single_field $conn ("select vlan_id from cl_vlan where firewall_id = (select firewall_id from cl_firewall where environment_id = " + $environment_id + ")")
    foreach ($vlan_id in $vlan_ids) {
        $cl_vlan_sql = ("update cl_vlan set dvs_id = " + $destination_dvs_id + " where vlan_id = " + $vlan_id)
        ndb_update $conn $cl_vlan_sql
    }

    # update cladm tables
    $prov_hdr_id = ndb_query_single_field $conn ("select provision_hdr_id from cladm_provision_hdr where customer_id = " + $custId + " and cluster_id = " + $src_cluster_id)

    if ($prov_hdr_id) {
	    $sql = ("update cladm_provision_hdr set cluster_id = " + $dst_cluster_id + " where provision_hdr_id = " + $prov_hdr_id)
	    write-host $sql
	    write-host ("    (cluster_id was " + $src_cluster_id + ")")
        ndb_update $conn $sql

	    # If failure in one of the next two statements, you must either reset
	    # the DB before running again (so provision_hdr_id is found) or run
	    # manually.

	    $prov_fw_ids = ndb_query_single_field $conn ("select distinct fw_id from cladm_provision_lns where provision_hdr_id = " + $prov_hdr_id + " and fw_id is not null")
	    
	    if ($prov_fw_ids) {
	        $in_str = $prov_fw_ids -join ","
	        write-host ("    updating firewall entries for: " + $in_str)

	        # Update cladm_cluster_fw, which has rows for firewalls being used
	        # in each cluster.  For each firewall:
	        #    If there's no row for the target cluster, add one
	        #    If there are no remaining customers in the source cluster
	        #        using this firewall, remove the row for the source cluster

	        foreach ($fw_id in $prov_fw_ids) {
		        $n = ndb_query_single_field $conn ("select count(*) from cladm_cluster_fw where cluster_id = " + $dst_cluster_id + " and fw_id = " + $fw_id)
		        if ($n -eq 0) {
		            $sql = ("insert into cladm_cluster_fw (cluster_id, fw_id) values (" + $dst_cluster_id + ", " + $fw_id + ")")
		            write-host $sql
		            ndb_update $conn $sql
		        } else {
		            write-host ("        fw_id " + $fw_id + " is already provisioned (x " + $n + ") in cluster " + $target_cl.name)
		        }

		        $n = ndb_query_single_field $conn ("select count(*) from cladm_provision_lns lns join cladm_provision_hdr hdr on lns.provision_hdr_id = hdr.provision_hdr_id where lns.fw_id = " + $fw_id + " and hdr.cluster_id = " + $src_cluster_id + " and hdr.customer_id != " + $custId)
                #"select count(*) from cladm_provision_lns where fw_id = " + $fw_id + " and provision_hdr_id in (select provision_hdr_id from cladm_provision_hdr where cluster_id = " + $src_cluster_id + " and customer_id != " + $custId + ")")
		        if ($n -eq 0) {
		            $sql = ("delete from cladm_cluster_fw where cluster_id = " + $src_cluster_id + " and fw_id = " + $fw_id)
		            write-host $sql
		            ndb_update $conn $sql
		        } else {
		            write-host ("        fw_id " + $fw_id + " is still being used in cluster " + $source_cl.name + " by another customer (x " + $n + ")")
		        }
	        }
	    } else {
	        write-host ("    customer has no firewalls provisioned in " + $source_cl.name)
	    }
    }
}


function copy_drs_rule {
    param(
	[parameter(Mandatory=$true)] $rule,
	[parameter(Mandatory=$true)] $target_cluster,
    [parameter(Mandatory=$true)] $vcenter
    )

    write-host ("    Rule: " + $rule.Name)
	New-DrsRule -server $vcenter -cluster $target_cluster -Name $rule.Name -Enabled $rule.Enabled `
	  -KeepTogether $rule.KeepTogether -RunAsync:$true -Confirm:$false `
	  -VM ($rule.VMIds | % { Get-VM -Id $_ })
}


function find_templates {
    param(
	[parameter(Mandatory=$true)] $pools,
	[parameter(Mandatory=$true)] $vcenter
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
    
	    $folder = Get-Folder -server $vcenter -Name $custId -ErrorAction Ignore
	    if ($folder -ne $null) {
	        $res += Get-Template -server $vcenter -Location $folder
	    }
    }
    return $res
}

function get_running_tasks {
    [OutputType([Int32])]
    param(
    [parameter(Mandatory=$true)] $tasks,
    [parameter(Mandatory=$true)] $vcenter
    )
    $running = 0
    
    if ($tasks.count -le 0){
        write-host "no tasks running"
        return $running
    }
    foreach ($task in @($tasks.keys)) {
        $test = get-task -server $vcenter -id $tasks[$task] -erroraction Ignore
        if($test){
            if ($test.State -eq "Running"){
                $running += 1
            }
            else{
                #remove vm from datastore table and active table
                if($script:vm_datastore_table.ContainsKey($test.objectid)) {
                    $vm_name = $script:vm_datastore_table[$test.objectid][0].name
                    [void]$script:vm_datastore_table.Remove($test.objectid)
                    [void]$script:ACTIVE_MIGRATIONS.Remove($test.extensiondata.moref)
                    write-host "task complete for vm: " $vm_name " updating appcenter virtual server record"
                    $moved_vm = get-vm -name $vm_name -server $target_vc
                    migrate_vm_db_record $moved_vm.ExtensionData.Config.InstanceUuid $db_conn | out-null
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
    return ,$running
}

##############################################################################
# Main
##############################################################################

$pools = Get-ResourcePool -server $source_vc -name $pools_to_move
$top_target_pool = Get-ResourcePool -server $target_vc -Location $TARGET_CLUSTER -NoRecursion

#if(check_zerto -dbc $db_conn -customer_id $customer_id){
#    write-host "Zerto customer detected, exiting."
#    exit
#}

write-host $TARGET_DS_CLUSTER.name " free space: " $TARGET_DS_CLUSTER.freespacegb
    
# move only the vms specified and exit without db update
if ($vm_name_list){
    #get the source vms
    $source_vms = @()
    foreach ($v in $vm_name_list){
        $source_vms += get-vm -server $source_vc -name $v -location $target_pool_name
    }
    # copy the customer pool and the target pool (sub pool)
    $cust_pool = copy_pool $source_pool $top_target_pool $target_vc
    $sub_pool = get-resourcepool -server $source_vc -name $target_pool_name
    copy_pool $sub_pool $cust_pool $target_vc
    $destination_resource_pool = get-resourcepool -server $target_vc -name $target_pool_name
    $source_vms = $source_vms |sort -Property usedspacegb -Descending
    migrate_vms $source_vms $destination_resource_pool
    # Wait for all migrations to finish...
    write-host "Waiting for migrations to finish."
    $runningTasks = $ACTIVE_MIGRATIONS.count
    while ($runningTasks -gt 0) {
        $runningTasks = get_running_tasks -tasks $script:ACTIVE_MIGRATIONS $source_vc
        write-host ("    " + $runningTasks + " outstanding")
        if ($runningTasks -gt 0){
            Start-Sleep -Seconds 60
        }
    }
    write-host "exiting"
    exit
}

$vms = get-vm -server $source_vc -location $folder
write-host $vms.count "total vms in folder" $source_vc.name

#write-host "checking for SSD vms..."
#if(check_ssd -vms $vms -vcenter $source_vc){
#    write-host "VMS found on SSD storage pod. exiting."
#    exit
#}

write-host "checking free space..."
if ( (check_free_space $vms $TARGET_DS_CLUSTER) -ne $true ) {
    write-host "Insufficient space in target datastore cluster, exiting"
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

#move airlock vms
try{
    $airlock_rp = get-resourcepool -server $source_vc "Airlock-Prod"
}catch{
    $airlock_rp = get-resourcepool -server $source_vc "Airlock"
}
try{
    $dest_airlock_rp = get-resourcepool -server $target_vc "Airlock-Prod"
}catch{
    $dest_airlock_rp = get-resourcepool -server $target_vc "Airlock"
}
write-host "searching for airlock vms"
foreach ($vm in $vms) {
    if($vm.extensiondata.resourcepool.value -eq $airlock_rp.extensiondata.moref.value){
        write-host "migrating airlock vm: " $vm.name
        migrate_vm -vm $vm -target_pool $dest_airlock_rp -in_airlock $true
        migrate_vm_db_record $vm.ExtensionData.Config.InstanceUuid $db_conn
    }
}

# Copy pools and update the database
write-host ("Copying " + $pools.count + " pools and updating DB...")
$pools | % {
    write-host ("    " + $_.Name + "...")
    copy_pool_deep $_ $top_target_pool $source_vc $target_vc
    write-host "    done"
}

# Migrate Templates synchronously
$tmpls = find_templates $pools $source_vc
if ($tmpls.count -gt 0) {
    write-host "Migrating templates (synchronously)..."
    $tmpls | % { migrate_tmpls $_ $target_cluster } | out-null
} else {
    write-host "No templates to migrate."
}

# Migrate VMs partially asynchronously
write-host "Kicking off VM migrations..."
#$VMS_TO_MOVE.GetEnumerator() | % { migrate_vms ($_.value) ($_.key) } | out-null
write-host $VMS_TO_MOVE.count " vms_to_move count"
foreach ($item in $VMS_TO_MOVE.GetEnumerator()) {
    write-host ($item.value).count $item.key
    migrate_vms ($item.value) ($item.key) | out-null
}

# migrate any remaining vms in the folder that are not in the resource pool
# netscalers or other vms that have been moved outside of appcenter
#$source_folder = get-folder -server $source_vc -name $folder
#$remaining_vms = get-vm -location $source_folder
#write-host $remaining_vms.count "vms remaining in source folder"
#foreach ($f_vm in $remaining_vms){
#    write-host "migrating $f_vm"
#    migrate_vm -vm $f_vm -target_pool $top_target_pool
#    write-host "reminder: manually update appcenter database for this vm"
#}

# Wait for all migrations to finish...
write-host "Waiting for migrations to finish."
$runningTasks = $ACTIVE_MIGRATIONS.count
while ($runningTasks -gt 0) {
    $runningTasks = get_running_tasks -tasks $script:ACTIVE_MIGRATIONS $source_vc
    write-host ("    " + $runningTasks + " outstanding")
    if ($runningTasks -gt 0){
        Start-Sleep -Seconds 60
    }
}


# Update the appcenter database after the migration
$pools | % { migrate_db $db_conn $_ }

$db_conn.close()

write-host "Copying "$DRS_RULES_TO_MOVE.count" rules"
$DRS_RULES_TO_MOVE | % { copy_drs_rule $_ $target_cluster }

write-host "Removing empty resource pools"
$pools | % { remove_pool_safe $_ $source_vc}

write-host "DONE."
write-host "bounce the Source DHCP server (example SanJose) to prevent lease expiration!!!!!!!!!!!!!!!!"
$migration_end_date = get-date
write-host "started:  $migration_start_date"
write-host "finished: $migration_end_date"