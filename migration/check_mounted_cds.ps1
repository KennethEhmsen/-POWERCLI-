param(
    [parameter(Mandatory=$true)]
    $hosts
)
$vms = get-vm -location $hosts

write-host "checking for vmware tools installation cd..."
$tools_mounted_vms = $vms| Get-View | Where {$_.Runtime.ToolsInstallerMounted} | % {$_.Name}
if ($tools_mounted_vms.count -gt 0){
    write-host "vmware tools mounted on " $tools_mounted_vms.count " vms. Running unmount command..."
    $tools_mounted_vms | % {Dismount-Tools -vm $_}
}

$res_cd = $vms | where { $_ | get-cddrive | where { $_.ConnectionState.Connected -eq "true" -and $_.ISOPath -like "*.ISO*"} } | select Name, @{Name=".ISO Path";Expression={(Get-CDDrive $_).isopath }}
if ($res_cd) {
	write  'Some hosts have VMs with CDs connected: '
	write $res_cd
	exit
} else {
	write 'You are in luck -- no hosts have VMs with CDs connected.'
}
