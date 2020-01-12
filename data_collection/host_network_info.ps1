$clusters = get-cluster

$report = Get-View -ViewType hostsystem -Property name, parent.value, config.network.vnic | % {
$id = $_.parent.value
[PSCustomObject]@{
			"vcenter" = $Global:DefaultVIServers.name;
			"cluster" = ($clusters | where {$_.id -eq "ClusterComputeResource-$($id)"}).name;
			"hostname" = $_.name;
			"IP" = ($_.Config.Network.vnic | ? {$_.Device -eq "vmk0"}).Spec.Ip.IpAddress;
			}
}
$report | sort -Property cluster, hostname
