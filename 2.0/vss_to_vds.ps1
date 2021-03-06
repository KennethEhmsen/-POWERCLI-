﻿param(
    [parameter(Mandatory=$true)]$vmhosts,
    $vdsname,
    $vssname="vSwitch0",
    $prefix #ex. an01
)
  
# Get VDS
$vds = get-VDSwitch -Name $vdsname
if ($vds -eq $null) {
	write-host "Can't find VDS"
	exit		
}
if (@($vds).count -ne 1) {
	write-host "Too many VDSs found"
	exit		
}
$vdsname = $vds.name
Write-Host "`nFound VDS:" $vdsname

foreach ($vmhost in $vmhosts) {
	# Add ESXi host to VDS
	Write-Host "Adding" $vmhost "to" $vdsname
	$vds | Add-VDSwitchVMHost -VMHost $vmhost | Out-Null
	 
	# Migrate pNIC to VDS (vmnic0)
	Write-Host "Adding vmnic0 to" $vdsname
	$vmhostNetworkAdapter = Get-VMHost $vmhost | Get-VMHostNetworkAdapter -Physical -Name vmnic0
	$vds | Add-VDSwitchPhysicalNetworkAdapter -VMHostNetworkAdapter $vmhostNetworkAdapter -Confirm:$false
	 
	# Migrate VMkernel interfaces to VDS
	 
	# Management #
	$mgmt_portgroup = "$($prefix)-mgmt"
	Write-Host "Migrating" $mgmt_portgroup "to" $vdsname
	$dvportgroup = Get-VDPortgroup -name $mgmt_portgroup -VDSwitch $vds
	$vmk = Get-VMHostNetworkAdapter -Name vmk0 -VMHost $vmhost
	Set-VMHostNetworkAdapter -PortGroup $dvportgroup -VirtualNic $vmk -confirm:$false | Out-Null
	 
	# vMotion #
	$vmotion_portgroup = "$($prefix)-vmotion"
	Write-Host "Migrating" $vmotion_portgroup "to" $vdsname
	$dvportgroup = Get-VDPortgroup -name $vmotion_portgroup -VDSwitch $vds
	$vmk = Get-VMHostNetworkAdapter -Name vmk1 -VMHost $vmhost
	Set-VMHostNetworkAdapter -PortGroup $dvportgroup -VirtualNic $vmk -confirm:$false | Out-Null
	 
	# Migrate remainder pNIC to VDS (vmnic1)
	Write-Host "Adding vmnic1 to" $vdsname
	$vmhostNetworkAdapter = Get-VMHost $vmhost | Get-VMHostNetworkAdapter -Physical -Name vmnic1
	$vds | Add-VDSwitchPhysicalNetworkAdapter -VMHostNetworkAdapter $vmhostNetworkAdapter -Confirm:$false
	 
	Write-Host "`n"
	Get-VirtualSwitch -VMhost $VMhost -name $vssname | Remove-VirtualSwitch -confirm:$false
}


