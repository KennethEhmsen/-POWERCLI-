param(
    [parameter(Mandatory=$true)]
    $cluster
)

Get-VMHost -location $cluster | Get-VMHostStorage -RescanVmfs

