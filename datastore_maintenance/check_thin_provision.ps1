param(
    [parameter(Mandatory=$true)] $vms
    )

$thick = @()

foreach ($vm in $vms) {
    write-host "checking" $vm.name 
    foreach ($device in $vm.extensiondata.config.hardware.device){
        if ($device.DeviceInfo.Label.ToLower().StartsWith("hard disk")){
            if ($device.Backing.ThinProvisioned -ne $true){
                $thick += $vm
                break
            }
        }
    }
}
write-host "----------------------REPORT----------------------"
foreach ($vm in $thick){
    $ds = get-datastore -vm $vm
    write-host $ds "contains thick vm:" $vm.name ([Math]::Truncate($vm.provisionedspacegb)) "GB"
}