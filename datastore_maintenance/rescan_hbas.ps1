param(
    [parameter(Mandatory=$true)]
    $cluster
)

Get-VMHost -location $cluster | sort | Get-VMHostStorage -rescanallhba