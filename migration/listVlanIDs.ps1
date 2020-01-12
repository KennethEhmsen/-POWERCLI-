##############################################################
# usage instructions
# connect-viserver target_vcenter_ip
# 
# $your_variable_name = .\listVlanIDs.ps1 -cluster_name "sj0X-cld0X -db_server "x.x.x.x" -db_pass "abc123"
#
# Returns hashtable with vlan_names and vlan ids.
#
# Used for determining all vlans used by vms in target_cluster
# and vlans referenced by the database for that cluster.
#
##############################################################

param(
    [parameter(Mandatory=$true)] $cluster_name,
    [parameter(Mandatory=$true)] $db_server,
    [parameter(Mandatory=$true)] $db_pass
    )

. ..\utils\db_util.ps1

$vms = get-vm -location (get-cluster -name $cluster_name)
$vlans = @{}
write-host $vms.count "vms in cluster"

foreach ($vm in $vms){
    $nics = get-networkadapter -vm $vm
    foreach ($nic in $nics){
        if(!$vlans.containskey($nic.networkname)){
            $vlans.add($nic.networkname , "")
        }
    }
}
write-host "Vlans from Vcenter: " $vlans.count
write-host "retrieving vlan_ids..."

foreach ($vlan in $($vlans.Keys)){
    $pg = get-virtualPortGroup -name $vlan
    foreach ($p in $pg){
        if(($p.key).startswith("dvportgroup")){
            $vlans[$vlan] = $p.ExtensionData.Config.DefaultPortConfig.Vlan.vlanid
        }else{
            $vlans.set_item($vlan, $p.vlanid)
        }
    }
}
write-host "retrieving vlans from appcenter database"
$db_conn = ndb_get_connection $db_server "clouddb" "cloud" $db_pass
$appcenter_vlans = ndb_query_multi_field $db_conn ("select nameif, vlan_num from cl_vlan where firewall_id in (select firewall_id from cl_firewall where environment_id in (select environment_id from cl_resource_pool where vcenter_cluster_id = (select vcenter_cluster_id from cladm_vcenter_cluster where cluster_name = '" + $cluster_name + "')))")
if($appcenter_vlans){
    write-host "vlans from appcenter: " $appcenter_vlans.count
}

foreach ($row in $appcenter_vlans){
    if(!$vlans.containskey($row.nameif)){
        $vlans.add($row.nameif , $row.vlan_num)
    }
}

write-host "total vlans: " $vlans.count

return $vlans