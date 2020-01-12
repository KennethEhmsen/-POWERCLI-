param(
    [parameter(Mandatory=$true)]  $vm_name,
    [parameter(Mandatory=$true)]  $source_cluster,
    [parameter(Mandatory=$true)]  $source_vcenter,
    [parameter(Mandatory=$true)]  $target_cluster,
    [parameter(Mandatory=$true)]  $target_vcenter,
    [parameter(Mandatory=$true)]  $target_datastore,
    [parameter(Mandatory=$true)]  $pools_to_move,
    [parameter(Mandatory=$true)]  $folder
)
#########################################
write-host " REMINDER USE THE VCENTER IP ADDRESS instead of alias!!!!!!"
########################################

$mmqa_thumb    = "9E:51:A8:54:88:5F:52:1D:7A:E0:7C:D3:4A:F5:AC:17:00:0E:25:53"
$sc_test_thumb = "13:AE:E1:92:56:82:35:E5:5E:47:3F:FE:99:07:AA:F5:16:0E:49:4B"
$mm_test_thumb = "EB:54:F5:F1:57:0D:56:57:3D:52:1C:75:BB:48:BB:08:15:49:A4:D2"
$sc_prod_thumb = "A7:DA:A3:A2:E4:5C:1E:46:D2:10:B4:AD:DB:21:5F:99:C1:E5:92:74"
$sj_prod_thumb = "35:97:53:68:27:4F:4D:E2:B6:2A:9E:F4:7C:A7:05:5C:74:BE:2C:69"
$scmsg_prod_thumb = "68:D3:7A:C2:C5:15:E5:26:40:C8:F9:96:52:A4:1D:91:76:FC:D8:48"

$thumbprint = $sc_prod_thumb
write-host "connecting to " $source_vcenter
$source_vc = connect-viserver $source_vcenter
$source_cl = get-cluster -server $source_vc -name $source_cluster 
$source_pool = get-resourcepool -server $source_vc -name $pools_to_move

write-host "connecting to " $target_vcenter
$target_vc = connect-viserver $target_vcenter
$target_cl = get-cluster -server $target_vc -name $target_cluster
$target_hosts = get-vmhost -server $target_vc -location $target_cl
$target_hosts = $target_hosts | Get-Random -Count $target_hosts.Count
$target_pool = get-resourcepool -server $target_vc -location $target_cl -name $pools_to_move
$target_datastore = get-datastore -server $target_vc -name $target_datastore
$vm = get-vm -server $source_vc -name $vm_name -location $source_pool

$destFolder = get-folder -server $target_vc -name $folder
$rspec = New-Object VMware.Vim.VirtualMachineRelocateSpec
$rspec.folder = $destFolder.id
$rspec.datastore = $target_datastore.extensiondata.moref
$rspec.host = $target_hosts[0].extensiondata.moref
$rspec.pool = $target_pool.extensiondata.moref

# New Service Locator required for Destination vCenter Server when not part of same SSO Domain
$service = New-Object VMware.Vim.ServiceLocator
$credential = New-Object VMware.Vim.ServiceLocatorNamePassword
$credential.username = (Get-VICredentialStoreItem -Host $target_vcenter).user
$credential.password = (Get-VICredentialStoreItem -Host $target_vcenter).password
$service.credential = $credential
$service.InstanceUuid = $target_vc.InstanceUuid.toUpper()
$service.sslThumbprint = $thumbprint
$service.url = ("https://" + $target_vcenter)
$rspec.service = $service
$rspec.deviceChange = New-Object VMware.Vim.VirtualDeviceConfigSpec[]($vm.networkadapters.count)
$devices = $vm.extensiondata.Config.Hardware.Device
$i = 0
foreach ($device in $devices) {
    if($device -is [VMware.Vim.VirtualEthernetCard]) {
      $rspec.deviceChange[$i] = New-Object VMware.Vim.VirtualDeviceConfigSpec
      $rspec.deviceChange[$i].Operation = "edit"
      $rspec.deviceChange[$i].Device = $device
      $nic = get-networkadapter -vm $vm -name $device.DeviceInfo.label
      $destPG = get-vdportgroup -server $target_vc -name $nic.networkname
      $dvSwitchUuid = (Get-View -server $target_vc -Id $destPG.extensiondata.Config.DistributedVirtualSwitch).Summary.Uuid
      $rspec.deviceChange[$i].Device.Backing = New-Object VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo
      $rspec.deviceChange[$i].Device.Backing.Port = New-Object VMware.Vim.DistributedVirtualSwitchPortConnection
      $rspec.deviceChange[$i].Device.Backing.Port.PortgroupKey = $destPG.key
      $rspec.deviceChange[$i].Device.Backing.Port.SwitchUuid = $dvSwitchUuid
      $i++
   }
}
Write-Host "`nMigrating $vm from $source_vc to $target_vc.`n"
# Issue Cross VC-vMotion 
$task = $vm.extensiondata.RelocateVM_Task($rspec,"defaultPriority") 
Disconnect-VIServer $source_vc -Force -confirm:$false
Disconnect-VIServer $target_vc -Force -confirm:$false
return $task
