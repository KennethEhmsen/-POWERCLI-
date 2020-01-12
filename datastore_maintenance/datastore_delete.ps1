param(
    [Parameter(ValueFromPipeline=$true, Mandatory=$true)]
	$datastore
	)

$vm_hosts = Get-VMHost -Datastore $datastore

Remove-Datastore -VMHost $vm_hosts[0].Name -Datastore $datastore.name -ErrorVariable myError -Confirm:$false # | Out-Null
if ($myError -ne $null) {
  write $myError | gm
  write $myError[0] | gm
  write "Errors: $myError"
  if ($myError[0] -contains 'failed to quiesce file') {
  	Start-Sleep 10
	write "Second try"
	Remove-Datastore -VMHost $vm_hosts[0].Name -Datastore $datastore.name -ErrorVariable myError -Confirm:$false # | Out-Null
    write "Errors: $myError"
  }
}


