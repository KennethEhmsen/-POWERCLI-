param(
    [parameter(Mandatory=$true)] $username,
    [parameter(Mandatory=$true)] $password,
    $datacenters=@('mm01','mm02','sj01','sc01','wk01','rh01')
    )

foreach ($datacenter in $datacenters) {
	get-vicredentialstoreitem -user $username -host $datacenter | remove-vicredentialstoreitem -confirm:$false
	new-vicredentialstoreitem -user $username -password $password -Host $datacenter
}	 
