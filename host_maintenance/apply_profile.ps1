param(
    [parameter(ValueFromPipeline=$true, Mandatory=$true)]
    $vmhosts,
	$profilename=$null
)

$prof = $null
if ($profilename -ne $ne) {
	$prof = Get-VMHostProfile -name $profilename
	if ($prof -eq $null) {
		write 'Profile not found'
	}
}

$vmhosts | Apply-VMHostProfile -Profile $prof -RunAsync -Confirm:$false
