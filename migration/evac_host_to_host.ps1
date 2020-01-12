param(
    [parameter(Mandatory=$true)]    $sourcehost,
    [parameter(Mandatory=$true)]    $desthost
)

write-host "getting source host"
$source = get-vmhost -name $sourcehost
write-host "getting dest host"
$dest = get-vmhost -name $desthost
write-host "getting vm list"
$vms = ($source | get-view).vm | Get-VIObjectByVIView

foreach ($vm in $vms) { 
    write-host "moving " $vm.name " to " $dest.name
    move-vm -vm $vm -dest $dest
}