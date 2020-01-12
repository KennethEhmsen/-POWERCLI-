param(
    [parameter(Mandatory=$true)]$vmhosts,
    $vdsname="*",
    $vssname="vSwitch0",
    $mgmt_name="mgmt",
    $vmotion_name="vmotion",
    $mgmt_vlan=22,
    $vmotion_vlan=23
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
	Write-Host "`nProcessing" $vmhost

	# pNICs to migrate to VSS
	Write-Host "Retrieving pNIC info for vmnic0,vmnic1"
	$vmnic0 = Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmnic0"
	$vmnic1 = Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmnic1"

	# Array of pNICs to migrate to VSS
	Write-Host "Creating pNIC array"
	$pnic_array = @($vmnic0,$vmnic1)

	# vSwitch to migrate to
	$vss = Get-VMHost -Name $vmhost | New-VirtualSwitch -Name $vssname

	# Create destination portgroups
	Write-Host "`Creating" $mgmt_name "portgroup on" $vssname
	$mgmt_pg = New-VirtualPortGroup -VirtualSwitch $vss -Name $mgmt_name
	$mgmt_pg | Set-VirtualPortGroup -VLanId $mgmt_vlan | out-null

	Write-Host "`Creating" $vmotion_name "portgroup on" $vssname
	$vmotion_pg = New-VirtualPortGroup -VirtualSwitch $vss -Name $vmotion_name
	$vmotion_pg | Set-VirtualPortGroup -VLanId $vmotion_vlan | out-null

	# Array of portgroups to map VMkernel interfaces (order matters!)
	Write-Host "Creating portgroup array"
	$pg_array = @($mgmt_pg,$vmotion_pg)

	# VMkernel interfaces to migrate to VSS
	Write-Host "`Retrieving VMkernel interface details for vmk0,vmk1"
	$mgmt_vmk = Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmk0"
	$vmotion_vmk = Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmk1"

	# Array of VMkernel interfaces to migrate to VSS (order matters!)
	Write-Host "Creating VMkernel interface array"
	$vmk_array = @($mgmt_vmk,$vmotion_vmk)

	# Perform the migration
	Write-Host "Migrating from" $vdsname "to" $vssname"`n"
	Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $vss -VMHostPhysicalNic $pnic_array -VMHostVirtualNic $vmk_array -VirtualNicPortgroup $pg_array  -Confirm:$false
}

Write-Host "`nRemoving" $vmhosts "from" $vdsname
$vds | Remove-VDSwitchVMHost -VMHost $vmhosts -Confirm:$false


