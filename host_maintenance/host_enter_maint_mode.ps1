param(
    [parameter(Mandatory=$true)]
    $targethost
)

if ($targethost.connectionstate -ne 'connected') {
	write 'Target host is not connected'
	exit
}

$templates = Get-Template -Location $targethost
if ($templates -ne $null) {
	$tmpltargethosts = @(get-vmhost -location $targethost.parent.name | where {$_.connectionstate -eq 'Connected' -and $_.name -ne $targethost.name})
	if ($tmpltargethosts -eq $null) {
		write 'Unable to find a host to put the templates on'
		exit
	}
	$tmpltargethost = $tmpltargethosts[0]
	write 'Template target host: ' $tmpltargethost
	$templates | Set-Template -ToVM | Move-VM -Destination $tmpltargethost | Set-VM -ToTemplate -Confirm:$false
}

write 'Evac'
Set-VMHost -VMHost $targethost -State "maintenance" -Evacuate:$true
