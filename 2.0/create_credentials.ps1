param(
    [parameter(Mandatory=$true)] $username,
    [parameter(Mandatory=$true)] $password,
    $datacenters=@('an','ch','re','wo', 'sa')
    )

foreach ($datacenter in $datacenters) {
	foreach ($h in @(($datacenter + "01-m-vc"),
					 ($datacenter + "01-m-vc.vcloud-int.net"),
			 		 ($datacenter + "01-1-vc1"),
			 		 ($datacenter + "01-1-vc1.vcloud-int.net"))) {

		get-vicredentialstoreitem -user $username -host $h -erroraction SilentlyContinue| remove-vicredentialstoreitem -confirm:$false -erroraction SilentlyContinue
		new-vicredentialstoreitem -user $username -password $password -Host $h
	}	 

    $vcd_conn = connect-ciserver -user $username -password $password -server ($datacenter + "01-1-vcd") -savecredentials
    disconnect-ciserver -confirm:$false -server $vcd_conn
    $vcd_conn = connect-ciserver -user $username -password $password -server ($datacenter + "01-1-vcd.vcloud-int.net") -savecredentials
    disconnect-ciserver -confirm:$false -server $vcd_conn
}
