param(
    [parameter(Mandatory=$true)]
    $vihost,
    [parameter(Mandatory=$true)]
    $sess,
    [parameter(Mandatory=$true)]
    $hostnames
    )
 

Add-PSsnapin VMware.VimAutomation.Core -ErrorAction SilentlyContinue
connect-viserver $vihost -Session $sess
#Get-VMHost -location $clustername | Get-VMHostStorage -RescanVmfs -RescanAllHba | out-null
#Get-VMHost -location $clustername | Get-VMHostStorage -RescanVmfs | out-null
Get-VMHost -name $hostnames | Get-VMHostStorage -RescanAllHba | out-null
