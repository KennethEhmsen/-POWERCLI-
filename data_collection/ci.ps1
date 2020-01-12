function formatter {
  param(
    $data,
	$format=$null
	)
	
	if ($data) {
		if ($format) {
			return $format -f $data
		} else {
			return $data
		}	
	} else {
		return 0
	}
}

function ci {
    param(
        [parameter(Mandatory=$true)]
        $location
	)
    #$location = get-folder -Location (Get-Folder -name 'env-stage')
    #$location = Get-Cluster
    #$location = Get-ResourcePool env-stage*

    $Report = $location | foreach {
		$moref = ($_ | Get-View).moref
		
		$vms = Get-View -ViewType virtualmachine -SearchRoot $moref -Property name, `
																			  runtime.powerstate, `
																			  summary.config.numcpu, `
																			  summary.quickstats.overallcpuusage, `
																			  summary.quickstats.hostmemoryusage, `
																			  summary.quickstats.sharedmemory, `
																			  summary.config.memorysizemb, `
																			  summary.config.memoryreservation, `
																			  summary.storage.committed, `
																			  summary.storage.uncommitted
		$vmsflat = $vms | select name, `
								 @{name="powerstate";expression={$_.runtime.powerstate}}, `
		                         @{name="numcpu";expression={$_.summary.config.numcpu}}, `
		                         @{name="overallcpuusage";expression={$_.summary.quickstats.overallcpuusage}}, `
								 @{name="memorysizemb";expression={$_.summary.config.memorysizemb}}, `
								 @{name="memoryreservation";expression={$_.summary.config.memoryreservation}}, `
		                         @{name="hostmemoryusage";expression={$_.summary.quickstats.hostmemoryusage}}, `
								 @{name="sharedmemory";expression={$_.summary.quickstats.sharedmemory}}, `
								 @{name="provisioned";expression={($_.summary.storage.committed+$_.summary.storage.uncommitted)/1GB}}, `
								 @{name="committed";expression={$_.summary.storage.committed/1GB}}, `
								 @{name="uncommitted";expression={$_.summary.storage.uncommitted/1GB}}
		$vmsonflat = $vmsflat | where powerstate -EQ 'PoweredOn'
		
		$vmspoweredon = ($vmsonflat | measure-object).count
		$vmsvcpuson = ($vmsonflat | measure-object -property numCpu -Sum).sum
		$vmscpuusage = ($vmsonflat | measure-object -property overallcpuusage -Sum).sum
		$vmsmemallocon = ($vmsonflat | measure-object -property memorysizemb -Sum).sum
		[PSCustomObject]@{
			"ID" = $_.name;
			"VMS Powered On" = $vmspoweredon
			"vCPUs On" = formatter $vmsvcpuson
			"Average Cores" = if ($vmspoweredon) {formatter ($vmsvcpuson / $vmspoweredon) "{0:f2}"} else {0};
			"CPU Usage" = formatter $vmscpuusage
			"CPU Usage Ratio" = if ($vmspoweredon) {formatter ($vmscpuusage / $vmspoweredon) "{0:f2}"} else {0};
			"Memory Allocated On (MB)" = formatter $vmsmemallocon
			"Average Memory On (MB)" = if ($vmspoweredon) {formatter ($vmsmemallocon / $vmspoweredon) "{0:f2}"} else {0};
			"Memory Reservation (MB)" = formatter ($vmsonflat | measure-object -property memoryreservation -Sum).sum;
			"Host Memory Usage" = formatter ($vmsonflat | measure-object -property hostmemoryusage -Sum).sum;
			"Shared Memory" = formatter ($vmsonflat | measure-object -property sharedmemory -Sum).sum;
			"ProvisionedSpace (GB)" = formatter ($vmsflat | measure-object -property provisioned -Sum).sum "{0:f2}";
			"Used Space (GB)" = formatter ($vmsonflat | measure-object -property committed -Sum).sum "{0:f2}";

			"VMS Total" = ($vmsflat | measure-object).count;
			"vCPUs" = formatter ($vmsflat | measure-object -property numCpu -Sum).sum;
			"Memory Allocated (MB)" = formatter ($vmsflat | measure-object -property memorysizemb -Sum).sum;
		}
	}

	$Report
}

function ci_clusters {
	param(
	    $clusterpattern="*-cld*"
	)

	$clusters = get-cluster -name $clusterpattern

	$Report = ci -location $clusters | % {
		$cluster = $clusters | where name -eq $_.id
		$summary = $cluster.extensiondata.summary

		$chassisinuse = @{}
		$cluster | get-vmhost | % {
			if ($_.name -match '(.*hp\d+)' -or $_.name -match '(.*fuj\d+)' -or $_.name -match '(.*ucs\d+)') {
				$chassisinuse[$matches[0]] += 1
			}
		}
		$chassisdata = @()
		$chassisinuse.GetEnumerator() | % {
			if ($_.value -eq $summary.numhosts) {
				$chassisdata += "$($_.name)"
			} else {
				$chassisdata += "$($_.name)($($_.value))"
			}
		}
		$chassis = ($chassisdata -join ", ")

		[PSCustomObject]@{
			"Cluster" = $_."Id";
			"Chassis" = $chassis;
			"NumHosts" = $summary.numhosts;
			"NumCpuCores" = $summary.numcpucores;
			"EffectiveCpu" = $summary.effectivecpu;
			"EffectiveMemory" = $summary.effectivememory;

			"VMS Total" = $_."VMS Total";
			"VMS Powered On" = $_."VMS Powered On";
			"vCPUs" = $_."vCPUs";
			"vCPUs On" = $_."vCPUs On";
			"Average Cores" = $_."Average Cores";
			"CPU Usage" = $_."CPU Usage" ;
			"CPU Usage Ratio" = $_."CPU Usage Ratio";
			"Memory Allocated (MB)" = $_."Memory Allocated (MB)" ;
			"Memory Allocated On (MB)" = $_."Memory Allocated On (MB)";
			"Average Memory On (MB)" = $_."Average Memory On (MB)";
			"Host Memory Usage" = $_."Host Memory Usage";
			"Shared Memory" = $_."Shared Memory";
			"Memory Reservation (MB)" = $_."Memory Reservation (MB)";
			"ProvisionedSpace (GB)" = $_."ProvisionedSpace (GB)";
			"Used Space (GB)" = $_."Used Space (GB)";
			"Cap memory remaining on" = formatter (($_."Memory Allocated On (MB)" / $summary.effectivememory) * 100) "{0:f2}";
			"Cap memory remaining all" = formatter (($_."Memory Allocated (MB)" / $summary.effectivememory) * 100) "{0:f2}";
			"Cap memory host usage" = formatter (($_."Host Memory Usage" / $summary.effectivememory) * 100) "{0:f2}";
			"Cap PtoV" = formatter ($_."vCPUs On" / ($summary.numcpucores*2)) "{0:f2}";
			"Cap CPU usage" = formatter (($_."CPU Usage" / $summary.effectivecpu) * 100) "{0:f2}";
		}
	} | sort -Property @{Expression="Cluster";Descending=$false}

	$Report
}

function ci_resourcepools {
    param(
		$cluster_name="*-cld*",
		$rppattern="*env-prod-*"
	)

	$rps = get-resourcepool -location $cluster_name -name $rppattern 

	$Report = ci -location $rps | % {
		$resourcepool = $rps | where name -eq $_."Id" | select -Property @{L='Cluster'; E={$_.parent.parent.name}}
		[PSCustomObject]@{
			"Cluster" = $resourcepool."Cluster";
			"ID" = $_."Id";
	        "VMS Total" = $_."VMS Total";
	        "VMS Powered On" = $_."VMS Powered On" ;
	        "vCPUs" = $_."vCPUs" ;
	        "vCPUs On" = $_."vCPUs On";
	        "Average Cores" = $_."Average Cores";
	        "CPU Usage" = $_."CPU Usage" ;
	        "CPU Usage Ratio" = $_."CPU Usage Ratio";
	        "Memory Allocated (MB)" = $_."Memory Allocated (MB)";
	        "Memory Allocated On (MB)" = $_."Memory Allocated On (MB)";
	        "Average Memory On (MB)" = $_."Average Memory On (MB)";
	        "Host Memory Usage" = $_."Host Memory Usage";
	        "Shared Memory" = $_."Shared Memory";
	        "Memory Reservation (MB)" = $_."Memory Reservation (MB)";
	        "ProvisionedSpace (GB)" = $_."ProvisionedSpace (GB)";
	        "Used Space (GB)" = $_."Used Space (GB)";
		}
	} | sort -Property @{Expression="Cluster";Descending=$false}, @{Expression="Memory Allocated On (MB)";Descending=$true}

	$Report
}
