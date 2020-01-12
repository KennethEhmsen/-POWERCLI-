param(
    [parameter(Mandatory=$true)] $customer,
    [parameter(Mandatory=$true)] $bouncehost,
    [parameter(Mandatory=$true)] $targethosts,
    [parameter(Mandatory=$true)] $distributedswitch,
    [parameter()]                $noantiaffinity,
    [parameter()]                $includembx,
    [parameter()]                $real
)

$ErrorActionPreference = "Stop"

$DO_REAL = ($real -ne $null)
$NO_AVOID = ($noantiaffinity -ne $null)
$SKIP_MBX = ($includembx -eq $null)

$PORTGROUPS = @{}
$RESERVE_FRACTION = 0.10

# Return free mem after reserved space on host for VMs
function calc_free_mem {
    param([parameter(Mandatory=$true,ValueFromPipeline=$true)] $targhost)

    $totGB = $targhost.MemoryTotalGB * (1 - $RESERVE_FRACTION)
    $vms = Get-VM -Location $targhost | where { $_.PowerState -eq "PoweredOn" }
    return $totGB - ($vms | % { $_.MemoryGB } | Measure-Object -Sum).Sum
}


#  return index from $hosts with highest $freeMem that is not in $avoidHosts
function pick_host {
    param (
        [parameter(Mandatory=$true)] $hosts,
        [parameter(Mandatory=$true)] $freeMem,
        [parameter(Mandatory=$true)] $avoidHosts
    )
    $n = $hosts.count
    $maxIdx = -1
    for ($i=0; $i -lt $n; $i++) {
        if ($NO_AVOID -or ($avoidHosts -notcontains $hosts[$i])) {
	    if ($maxIdx -eq -1 -or ($freeMem[$i] -gt $freeMem[$maxIdx])) {
		$maxIdx = $i
	    }
        }
    }
    return $maxIdx
}


function migrate_networking {
	param(
	[parameter(Mandatory=$true)]
	$vms,
	[parameter(Mandatory=$true)]
	$dvs
	)
	$vms | Get-NetworkAdapter | % {
		write "    Migrate $($_.networkname) to $($dvs.name)"
		
		if ($_ -eq $null) {
			continue
		}
		
		if ($PORTGROUPS.ContainsKey($_.NetworkName) -eq $true) {
			$targetportgroup = $PORTGROUPS[$_.NetworkName]
		}
		else {
			$targetportgroup = Get-VDPortgroup -name $_.NetworkName -VDSwitch $dvs
			if ($targetportgroup -eq $null) {
				write "$($_.parent.name) - Unable to find $($_.NetworkName) attached to $($dvs)"
				exit
			}
			$PORTGROUPS[$_.NetworkName] = $targetportgroup
		}
		
	        if ($DO_REAL) {
	 	    Start-Sleep 10
		    $_ | Set-NetworkAdapter -Portgroup $targetportgroup -Confirm:$false | Out-Null
		}
	}
}


function migrate_vm {
    param(
        [parameter(Mandatory=$true)] $vm,
        [parameter(Mandatory=$true)] $targethost,
        [parameter(Mandatory=$true)] $bouncehost,
        [parameter(Mandatory=$true)] $dvs)

    #Migrate vms to bounce host
    write "    Migrate to bounce host"
    if ($DO_REAL) {
	move-vm $vm -Destination $bouncehost | Out-Null
    }

    #Change dvs
    migrate_networking -vms @($vm) -dvs $dvs

    #Migrate converted vms to targethost
    write "    Migrate to target host"
    if ($DO_REAL) {
	move-vm -VM $vm -Destination $targethost -RunAsync:$true | Out-Null
    }
}


function migrate_vms {
    param(
        [parameter(Mandatory=$true)] $vms,
        [parameter(Mandatory=$true)] $targethosts,
        [parameter(Mandatory=$true)] $bouncehost,
        [parameter(Mandatory=$true)] $dvs,
        [parameter(Mandatory=$true)] $qsize)

    #$freeMem = $targethosts | % { ($_.MemoryTotalGB - $_.MemoryUsageGB) }
    $freeMem = $targethosts | % { calc_free_mem $_ }
    $done_hostnames = ($targethosts + $bouncehost) | % { $_.Name }

    # Sanity check
    $mem_required = ($vms | % { $_.MemoryGB } | Measure-Object -Sum).Sum
    $mem_avail = ($freeMem | Measure-Object -Sum).Sum
    if ($mem_required -gt $mem_avail) {
        write ("*** " + [string] $mem_required + " GB is required for these VMs, however only " + [string] $mem_avail + " GB is available (" + [string] (100 * $RESERVE_FRACTION) + "% reserved) - aborting.")
	exit
    }

    # track most recent hosts
    $q = New-Object System.Collections.Queue

    $vms_sorted = $vms | Sort-Object -Property 'Name'

    # we repeatedly migrate next VM, host w/most free mem not in the queue
    foreach ($vm in $vms_sorted) {

	# filter MBX if needed
	if ($SKIP_MBX -and ($vm.Name -Match 'MBX')) {
	    write ("VM " + $vm.Name + " is an MBX VM and you requested to skip those - leaving untouched.")
	    continue
	}

	# check that it isn't already on one of the target or bounce hosts
	if ($done_hostnames -contains $vm.Host.Name) {
	    write ("VM " + $vm.Name + " has already been migrated to host " + $vm.Host.Name + " - leaving untouched.")
	    continue
	}

        $hidx = pick_host $targethosts $freeMem $q.toArray()
	if ($hidx -eq -1) {
	    write ("Unable to find a host to migrate VM " + $vm.Name + " to - aborting.")
	    exit
	}
        $targethost = $targethosts[$hidx]

	# give user some info
	if ($vm.PowerState -eq 'PoweredOn') {
	    $vmMem = [int] $vm.MemoryGB
	} else {
	    $vmMem = 0
	}
	$hostMem = [int] $freeMem[$hidx]
	if ($vmMem -gt $hostMem) {
	    write ("*** Host " + $targethost.Name + " was picked but only has " + [string] $hostMem + " GB free, not enough for VM size " + [string] $vmMem + " GB - aborting.")
	    exit
	}

        write ("Migrating VM " + $vm.Name + " (" + [string] $vmMem + " GB) to host " + $targethost.Name + " (" + [string] $hostMem + " GB free).")

        migrate_vm $vm $targethost $bouncehost $dvs

        # update the host's mem if need be
        if ($vm.PowerState -eq 'PoweredOn') {
            $freeMem[$hidx] -= $vm.MemoryGB
}

        # update the queue of recently-used hosts
        $q.enqueue($targethost)
        if ($q.ToArray().count -gt $qsize) {
            $q.dequeue() | Out-Null
	}
    }
}


# Top level
$rp = Get-ResourcePool -Name ('env-prod-' + $customer + '-*')
##$rp = Get-ResourcePool -Name ($customer + '*')
$custVMs = Get-VM -Location $rp

if ($custVMs -ne $null) {
    write ('Migrating ' + ($custVMs.count) + ' VMs')
    migrate_vms $custVMs $targethosts $bouncehost $distributedswitch 2
}
