param(
    [Parameter(ValueFromPipeline=$true, Mandatory=$true)]
	$datastore
	)

#$erroractionpreference = "stop"


if (($datastore | Get-VM) -ne $null) {
	write "This datastore ($($datastore.name)) has vms on it.  Exiting."
	exit
}


if (($datastore | Get-Template) -ne $null) {
	write "This datastore ($($datastore.name)) has templates on it.  Exiting."
	exit
}




. .\datastorefunctions.ps1

write "Unmount datastores"
get-datastore -Name $datastore.Name | unmount-datastore

Start-Sleep 5
write "Unmount again in case any failed"
get-datastore -Name $datastore.Name | unmount-datastore

Start-Sleep 5
write "Unmount again in case any failed, last time"
get-datastore -Name $datastore.Name | unmount-datastore

Start-Sleep 5
write "Detach datastores"
get-datastore -Name $datastore.Name | detach-datastore

Start-Sleep 5
get-datastore -Name $datastore.Name | Get-DatastoreMountInfo | Sort Datastore, VMHost | FT -AutoSize

#get-datastore -Name $datastore.Name | .\datastore_delete.ps1
