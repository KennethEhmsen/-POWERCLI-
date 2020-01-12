param(
    [Parameter(Mandatory=$true)]
	$templates,
    [Parameter(Mandatory=$true)]
	$destinationhost
)

$templates | Set-Template -ToVM | Move-VM -Destination $destinationhost | Set-VM -ToTemplate -Confirm:$false



