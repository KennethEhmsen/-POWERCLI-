param(
    [parameter(Mandatory=$true)]
    $cluster,
    $what
)

if ($what -eq 'hba') {
    Get-VMHost -location $cluster | Get-VMHostStorage -rescanallhba
}
elseif ($what -eq 'vmfs') {
    Get-VMHost -location $cluster | Get-VMHostStorage -RescanVmfs
}
else {
    Get-VMHost -location $cluster | Get-VMHostStorage -rescanallhba  -RescanVmfs
}
