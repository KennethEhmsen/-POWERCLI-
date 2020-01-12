param(
    [parameter(Mandatory=$true)] $sourcehost,
    [parameter(Mandatory=$true)] $bouncehost,
    [parameter(Mandatory=$true)] $targethost,
    [parameter()]                $real
)

$sourcehost = get-vmhost $sourcehost
$bouncehost = get-vmhost $bouncehost
$targethost = get-vmhost $targethost
$vms = get-vm -location $sourcehost

write-host $vms.count "vms on sourcehost:" $sourcehost.name "bouncehost:" $bouncehost.name "targethost:" $targethost.name

foreach ($vm in $vms){
    $networks = get-networkadapter -vm $vm
    if (!$vm.name.ToLower().Contains("mbx")){
        foreach ($network in $networks){
            write-host "retrieving target port group for: " $vm.name
            $target_port_group = get-virtualportgroup -VirtualSwitch "Andover01-dvSwitch01" -name $network.NetworkName
            if ($real){
                write-host "------------"
                write-host "moving" $vm.name "from" $sourcehost.name "to" $bouncehost.name 
                move-vm -vm $vm -destination $bouncehost
                write-host "changing" $vm.name "to:" $target_port_group.name
                Set-NetworkAdapter -networkadapter $network -Portgroup $target_port_group -Confirm:$false | Out-Null
                write-host "moving " $vm.name "to:" $targethost.name
                move-vm -vm (get-vm -name $vm.name -location $bouncehost) -destination $targethost -runasync:$true
                write-host "------------"
            }
            else{
                write-host "TESTING----"
                write-host "moving" $vm.name "from" $sourcehost.name "to" $bouncehost.name 
                write-host "changing" $vm.name "to:" $target_port_group.name
                write-host "moving " $vm.name "to:" $targethost.name
                write-host "------------"
            }
        }
    }
    else{
        write-host "*** skipping MBX virtual machine" $vm.name
    }
}

