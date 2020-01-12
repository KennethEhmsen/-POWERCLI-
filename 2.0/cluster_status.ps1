function verify_ha{ 
    param([parameter(Mandatory=$true)] $cluster)
    return $cluster.HAEnabled
}

function verify_drs_level{
    param([parameter(Mandatory=$true)] $cluster)
    $cluster.ExtensionData.Configuration.DrsConfig.VmotionRate
}

function verify_vcd_host_enabled{
    param([parameter(Mandatory=$true)] $ci_host)
    if ( ($ci_host.isEnabled -eq $false) -and (get-vmhost $ci_host.name).ConnectionState -eq "Connected" ){
            return $false
    }
    return $true
}

function verify_zerto {
    param([parameter(Mandatory=$true)] $esx_host)
    $zerto_vm = get-view -viewtype "virtualmachine" -filter @{"name" = ("Z-VRA-" + $esx_host.name)} -searchroot $esx_host.extensiondata.moref -ErrorAction SilentlyContinue
    if($zerto_vm){
        if( ($zerto_vm.runtime.PowerState -eq "PoweredOff") -and ($esx_host.runtime.ConnectionState -eq "Connected") ){
            return $false
        }
        return $true
    }
}

function verify_no_snapshot {
    param([parameter(Mandatory=$true)] $vm)
        $snaps = get-snapshot -vm $vm
        if ($snaps){
            $three_days_ago = (get-date).AddDays(-3)
            foreach ($snap in $snaps){
                if($snap.created -lt $three_days_ago){
                    return $false
                }
            }
        }
        return $true
}

function verify_vxlan {
    param([parameter(Mandatory=$true)] $esxhost)
    $dvswitch="dvSwitch1"
	$ehost = get-esxcli -VMHost $esxhost
	$result = 'Success'
	try {
		$res = $ehost.network.vswitch.dvs.vmware.vxlan.vmknic.list($null, $dvswitch)
		if ($res.count -eq 0) {
			$result = 'No vxlan vmknic'
		} elseif ($res.ip.startswith('169')) {
			$result = 'Missing vtep ip address'
		}
	}
	catch {
		$result = $Error[0].exception.message
	}
    return $result
}

function verify_ntp_time{
    param([parameter(Mandatory=$true)] $esxhost)
    $server_date = (get-view $esxhost.ExtensionData.ConfigManager.DateTimeSystem[0]).querydatetime()
    $now = (get-date).touniversaltime()
    $diff = $server_date - $now
    if($diff.minutes -ne 0){
        return $false
    }
    return $true
}

function verify_storage_pods {
    param([parameter(Mandatory=$true)] $cluster_list,
          [parameter(Mandatory=$true)] $threshold)
    $error_list = @()
    foreach($cluster in $cluster_list){
        $PercentFree = ([Math]::Truncate(($cluster.freespacegb/$cluster.capacitygb)*100))
        if ($PercentFree -lt $threshold){
            write-host ($cluster.Name + " " + $PercentFree + " Percent Free`r`n")
            $error_list += ($cluster.Name + " " + $PercentFree + " Percent Free`r`n")
        }
        $datastores = get-datastore -location $cluster
        foreach($datastore in $datastores){
            $PercentFree = ([Math]::Truncate(($datastore.freespacegb/$datastore.capacitygb)*100))
            if ($PercentFree -lt $threshold){
                write-host ($cluster.Name + " with datastore " + $datastore.name + " " + $PercentFree + " Percent Free`r`n")
                $error_list += ($cluster.Name + " with datastore " + $datastore.name + " " + $PercentFree + " Percent Free`r`n")
            }
        }
    }
    return $error_list
}

function generate_report {
    param([parameter(Mandatory=$true)] $datacenters)
    $errors = @()
    foreach ($dc in $datacenters){
        $errors += ("---------- $dc ----------")
        write-host "checking" $dc
        $ci_server = $dc + "01-1-vcd.vcloud-int.net"
        $c_vcenter = $dc + "01-1-vc1.vcloud-int.net"
        $m_vcenter = $dc + "01-m-vc.vcloud-int.net"
        try{
            $vcd_server = Connect-CIServer $ci_server
            $cust_vcenter = Connect-VIServer $c_vcenter
            $mgmt_vcenter = Connect-VIServer $m_vcenter
        }
        catch{
            $errors += ("unable to to connect to vcd or vcenter in " + $dc)
        }

        $ci_hosts = Search-Cloud -server $vcd_server -Querytype Host
        $customer_hosts = get-vmhost -server $cust_vcenter -location "zone*"

        foreach($ci_host in $ci_hosts) {
            if ((verify_vcd_host_enabled -ci_host $ci_host) -ne $true){
                write-host $ci_host.name "disabled in VCloud Director"
                $errors += ($ci_host.name + " disabled in VCloud Director")
            } 
        }

        $clusters = get-cluster -server $cust_vcenter -name "zone*"
        foreach($cluster in $clusters){
            if ((verify_ha -cluster $cluster) -ne $true){
                write-host $cluster.name "HA disabled"
                $errors += ($cluster.name + " HA disabled")
            }
            if ((verify_drs_level -cluster $cluster) -ne 3){
                write-host $cluster.name "drs level not 3"
                $errors += ($cluster.name + " drs level not 3")
            }
        }

        foreach($cust_host in $customer_hosts){
            if ( (verify_zerto -esx_host $cust_host) -ne $true){
                write-host $cust_host.name "zerto powered off"
                $errors += ($cust_host.name + " zerto powered off")
            }
            $vxlan_test = verify_vxlan -esxhost $cust_host
            if ( $vxlan_test -ne "Success"){
                write-host $cust_host.name $cust_host.connectionstate  $vxlan_test
                $errors += ($cust_host.name + " " + $cust_host.connectionstate + " " + $vxlan_test)
            }
            if(!($cust_host.ExtensionData.Config.Service.Service|?{$_.key -like "ntpd"}).running){
                $error_list += ($cust_host.name + " " + "NTPD not running")
            }
            if(!(verify_ntp_time -esxhost $cust_host)){
                $error_list += ($cust_host.name + " " + "NTP out of sync by more than 1 minute")
            }
        }

        $mgmt_vms = get-vm -server $mgmt_vcenter -location "*mgmt"
        foreach ($mgmt_vm in $mgmt_vms){
            if ((verify_no_snapshot -vm $mgmt_vm) -ne $true){
                write-host $mgmt_vm.name "contains snapshots"
                $errors += ($mgmt_vm.name + " contains snapshots")
            }
        }

        write-host "checking storage pods in mgmt vcenter"
        $m_sp_errors = verify_storage_pods -cluster_list (get-datastorecluster -server $mgmt_vcenter) -threshold 20
        $errors += $m_sp_errors
        write-host "checking storage pods in customer vcenter"
        $c_sp_erorrs = verify_storage_pods -cluster_list (get-datastorecluster -server $cust_vcenter) -threshold 20
        $errors += $c_sp_erorrs
        
        Disconnect-CIServer -confirm:$false -server $vcd_server
        Disconnect-VIServer -confirm:$false -server $c_vcenter
        Disconnect-VIServer -confirm:$false -server $m_vcenter
        $errors += ("------------------------")
    }
    return $errors
}