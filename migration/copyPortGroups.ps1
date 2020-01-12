param(
    [parameter(Mandatory=$true)] $sourceVcenter,
    [parameter(Mandatory=$true)] $destVcenter,
    [parameter(Mandatory=$true)] $sourceSwitch,
    [parameter(Mandatory=$true)] $targetSwitch
)

write-host "connecting to vcenter servers"
$s_vc = connect-viserver $sourceVcenter
$d_vc = connect-viserver $destVcenter

$portsToCopy = get-vdportgroup -server $s_vc -vdswitch $sourceSwitch
$newSwitch = get-vdswitch -server $d_vc -name $targetSwitch

write-host $portsToCopy.count "port groups to copy"

foreach ($pg in $portsToCopy){
    $tpg = get-vdportgroup -server $d_vc -name $pg.name -erroraction 0
    if ($tpg -eq $null){
        write-host "copying " $pg.name
        new-vdportgroup -vdswitch $newSwitch -name $pg.name -numports $pg.numports -portbinding $pg.portbinding -vlanid $pg.vlanconfiguration.vlanid
    }
    else{
        write-host $pg.name "exists on" $newSwitch.name
    }
}

write-host "Disconnecting from vcenter servers"
disconnect-viserver $s_vc -confirm:$false
disconnect-viserver $d_vc -confirm:$false