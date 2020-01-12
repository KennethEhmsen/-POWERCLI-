param(
    [parameter(Mandatory=$true)] $source_cluster,
    [parameter(Mandatory=$true)] $target_cluster,
    [parameter()]                $pools_to_move,
    [parameter(Mandatory=$true)] $db_server,
    [parameter(Mandatory=$true)] $db_pass,
    [Switch]                     $real,
    [Switch]                     $test
)

# Migrates one or more resource pools and all contained subpools and VMs from
# one cluster to another:

# 1) Copies the resource pool structure and settings
# 2) Updates the database records to keep appcenter in sync with vcenter
# 3) Migrate VMs, using storage vmotion if needed (destination must have pod)
# 4) Replicates affinity rules.
# 5) Removes old resource pools in original cluster.

$ErrorActionPreference = "Stop"
$global:NDB_DEBUG = $false
. ..\utils\db_util.ps1

$DO_REAL = ($real -eq $true)
$DO_TEST = ($test -eq $true)

# DRS and Datastore globals
# NOTE: global arrays must be prefixed by $global: or $script: in functions,
#       but not hashtables.  :-?
$DRS_RULES_TO_MOVE = @()
$VMS_TO_MOVE = @{}
$ACTIVE_MIGRATIONS = @()
$TARGET_HOSTS = Get-VMHost -Location $target_cluster

# Get the datastores that are actually mounted in the target cluster
function Get-DatastoreMountState {
    param(
	[parameter(Mandatory=$true)] $h,
	[parameter(Mandatory=$true)] $ds
    )
    # With ESXi 4.1 there is no vmfs field but the DS is always mounted
    if ($ds.ExtensionData.vmfs -eq $null) {
	return $true
    }
    return ($ds.ExtensionData.Host | where { $_.key -eq $h.id }).MountInfo.Mounted | Get-Unique
}

write-host "Getting mounted datastores in target cluster..."
$t_host = $TARGET_HOSTS[1]
$TARGET_DATASTORES = ($t_host | Get-Datastore | where { Get-DatastoreMountState $t_host $_ })
#$TARGET_DATASTORES = ($t_host | Get-Datastore | where { (Get-DatastoreMountState $t_host $_) -and $_.Name.startsWith("Large") -eq $true }  )
write-host $TARGET_DATASTORES
$TARGET_DS_CLUSTER = Get-Datastorecluster -Name ("sp-" + $target_cluster.Name)
write-host $TARGET_DS_CLUSTER

# select an appropriate datastore within the datastore cluster for the vm
function pick_datastore($vm, $dsc){
    $datastores = get-datastore -location $dsc
    foreach ($datastore in $datastores){
        if ( ($datastore.FreeSpaceGB/$datastore.CapacityGB -gt .20) -and ($vm.provisionedspacegb -lt $datastore.FreeSpaceGB) ){
            return $datastore
        }
    }
    write-host "unable to select sufficient space on datastores within " $dsc.name
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

# Move VM to target pool:
# - Store any DRS rules applying to it.
# - Check if all its datastores are mounted in the target_cluster.
#   -> If so, just move the VM
#   -> If not, specify the target DS cluster (we don't support without cluster)
# NOTE: the -async parameter is currently IGNORED, since we always need to do
#       two moves, first to the host/cluster and then to the resource pool
function migrate_vm {
    param(
	[parameter(Mandatory=$true)] $vm,
	[parameter(Mandatory=$true)] $target_pool,
	[Switch]                     $async
    )

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

    <# PENDING: We would like to only pick the host ourselves when the VM
       is not running.  But we cannot specify a datastore when moving a VM to
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
    write-host ("    " + $vm.Name + " -> " + $dest.Name + " / " + $target_pool.name + $msg)
    if ($easy_move) {
	    if ($DO_REAL) {
	        Move-VM -VM $vm -Destination $dest -Confirm:$false
	        $script:ACTIVE_MIGRATIONS += (Move-VM -VM $vm -Destination $target_pool -Confirm:$false -RunAsync:$true)
	    }
    } else {
	    if ($TARGET_DS_CLUSTER -eq $null) {
	        write-host ("unable to locate target datastore cluster, ABORT")
	        exit
	    }
        write-host "VM:" $vm 
        write-host "DEST:" $dest
	    if ($DO_REAL) {
	        $dsc_datastore = pick_datastore -vm $vm -dsc $TARGET_DS_CLUSTER
            if ($dsc_datastore -ne $null){
                Move-VM -VM $vm -Destination $dest -Datastore $dsc_datastore -Confirm:$false
                write-host "moved " $vm " to host " $dest " datastore " $dsc_datastore
                $script:ACTIVE_MIGRATIONS += (Move-VM -VM $vm -Destination $target_pool -Confirm:$false -RunAsync:$true)
            }
	    }
    }
}


function migrate_vms {
    param(
	[parameter(Mandatory=$true)] $vms,
	[parameter(Mandatory=$true)] $target_pool
    )
    write-host $vms.count " vms to migrate"
    $vms | % { migrate_vm $_ $target_pool -async:$true }
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
	    if ($DO_REAL) {
	        $vm = Set-Template -Template $template -ToVM
	        migrate_vm $vm $target_cluster -async:$false
            Set-VM -VM $vm -ToTemplate -Confirm:$False -RunAsync:$true | Out-Null
	    } else {
	        write-host ("    " + $template.Name)
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

    if ($DO_REAL) {
	    $target_pool = copy_pool $pool $target_container
    } else {
	    # Just do something for the dry-run to go further
	    $target_pool = $pool
    }
    
    $vms = @(Get-VM -Location $pool -NoRecursion)
    if ($vms.count -gt 0) {
	    $VMS_TO_MOVE.Add($target_pool, $vms)
    }
    #foreach ($subpool in @(Get-ResourcePool -Location $source_cluster -name $pool.name|get-resourcepool)) {
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
    if ($DO_REAL) {
	    if ($c -eq 0) {
	        write-host ("    Removing resource pool " + $pool.Name)
	        Remove-ResourcePool -ResourcePool $_ -Confirm:$false
	    } else {
	        write-host ("    NOT Removing resource pool " + $pool.Name + "; it has " + $c + "VMs/templates left.")
	    }
    } else {
        write-host ("    resource pool " + $pool.Name)
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
    
    # We have both cluster_id and vcenter_cluster_id -- lovely...
    $src_vcluster_id = ndb_query_single_field $conn ("select vcenter_cluster_id from cladm_vcenter_cluster where cluster_name = '" + $source_cluster.name + "'")
    $src_cluster_id = ndb_query_single_field $conn ("select cluster_id from cladm_cluster where cluster_name = '" + $source_cluster.name + "'")
    $dst_vcluster_id = ndb_query_single_field $conn ("select vcenter_cluster_id from cladm_vcenter_cluster where cluster_name = '"+ $target_cluster.name + "'")
    $dst_cluster_id = ndb_query_single_field $conn ("select cluster_id from cladm_cluster where cluster_name = '"+ $target_cluster.name + "'")

    ##TESTING
    if ($DO_TEST) {
	    $src_cluster_id = 3000
	    $dst_cluster_id = 4000
    }

    # Update cl_resource_pool
    $sql = ("update cl_resource_pool set vcenter_cluster_id = " + $dst_vcluster_id + " where resource_pool_id = " + $poolId)
    write-host $sql
    write-host ("    (vcenter_cluster_id was " + $src_vcluster_id + ")")
    if ($DO_REAL -and -not $DO_TEST) {
	    ndb_update $conn $sql
    }

    $prov_hdr_id = ndb_query_single_field $conn ("select provision_hdr_id from cladm_provision_hdr where customer_id = " + $custId + " and cluster_id = "+ $src_cluster_id)
    ##TESTING
    if ($DO_TEST) {
	    $prov_hdr_id = @(5000)
    }
    if ($prov_hdr_id) {
	    $sql = ("update cladm_provision_hdr set cluster_id = " + $dst_cluster_id + " where provision_hdr_id = " + $prov_hdr_id)
	    write-host $sql
	    write-host ("    (cluster_id was " + $src_cluster_id + ")")
	    if ($DO_REAL -and -not $DO_TEST) {
	        ndb_update $conn $sql
	    }

	    # If failure in one of the next two statements, you must either reset
	    # the DB before running again (so provision_hdr_id is found) or run
	    # manually.

	    $prov_fw_ids = ndb_query_single_field $conn ("select distinct fw_id from cladm_provision_lns where provision_hdr_id = " + $prov_hdr_id + " and fw_id is not null")
	    ##TESTING
	    if ($DO_TEST) {
    	    $prov_fw_ids = @(100,200,300)
	    }
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
		        if ($DO_REAL -and -not $DO_TEST) {
			        ndb_update $conn $sql
		        }
		    } else {
		        write-host ("        fw_id " + $fw_id + " is already provisioned (x " + $n + ") in cluster " + $target_cluster.name)
		    }

		    $n = ndb_query_single_field $conn ("select count(*) from cladm_provision_lns lns join cladm_provision_hdr hdr on lns.provision_hdr_id = hdr.provision_hdr_id where lns.fw_id = " + $fw_id + " and hdr.cluster_id = " + $src_cluster_id + " and hdr.customer_id != " + $custId)
            #"select count(*) from cladm_provision_lns where fw_id = " + $fw_id + " and provision_hdr_id in (select provision_hdr_id from cladm_provision_hdr where cluster_id = " + $src_cluster_id + " and customer_id != " + $custId + ")")
		    if ($n -eq 0) {
		        $sql = ("delete from cladm_cluster_fw where cluster_id = " + $src_cluster_id + " and fw_id = " + $fw_id)
		        write-host $sql
		        if ($DO_REAL -and -not $DO_TEST) {
			        ndb_update $conn $sql
		        }
		    } else {
		        write-host ("        fw_id " + $fw_id + " is still being used in cluster " + $source_cluster.name + " by another customer (x " + $n + ")")
		    }
	    }
	} else {
	    write-host ("    customer has no firewalls provisioned in " + $source_cluster.name)
	}
    }
}


function copy_drs_rule {
    param(
	[parameter(Mandatory=$true)] $rule,
	[parameter(Mandatory=$true)] $target_cluster
    )

    write-host ("    Rule: " + $rule.Name)
    if ($DO_REAL) {
	New-DrsRule -cluster $target_cluster -Name $rule.Name -Enabled $rule.Enabled `
	  -KeepTogether $rule.KeepTogether -RunAsync:$true -Confirm:$false `
	  -VM ($rule.VMIds | % { Get-VM -Id $_ })
    }
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



##############################################################################
# Main
# Set resource pools to all in cluster (under 'Resources') if no arg given.
if ($pools_to_move -eq $null) {
    $pools = @(Get-ResourcePool -Location (Get-ResourcePool -Location $source_cluster -NoRecursion -ErrorAction Ignore) -NoRecursion -ErrorAction Ignore)
} else {
    $pools = $pools_to_move
}

$db_conn = ndb_get_connection $db_server "clouddb" "cloud" $db_pass

# Copy pools and update the database
write-host ("Copying " + $pools.count + " pools and updating DB...")
$top_target_pool = Get-ResourcePool -Location $TARGET_CLUSTER -NoRecursion
$pools | % {
    write-host ("    " + $_.Name + "...")
    copy_pool_deep $_ $top_target_pool
    migrate_db $db_conn $_
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
do {
    $runningTasks = ($script:ACTIVE_MIGRATIONS | ? { $_.State -eq "Running" }).Count
    write-host ("    " + $runningTasks + " outstanding")
    Start-Sleep -Seconds 2
} while ($runningTasks -gt 0)

write-host "Copying rules"
$DRS_RULES_TO_MOVE | % { copy_drs_rule $_ $target_cluster }

write-host "Removing empty resource pools"
$pools | % { remove_pool_safe $_ }

write-host "DONE."
