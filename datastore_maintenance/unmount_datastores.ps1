param(
    [parameter(Mandatory=$true)] $datastores,
    [parameter(Mandatory=$true)] $vcenter_vm,
    [parameter(Mandatory=$true)] $vcenter_datastore_server
)

. ./datastorefunctions


foreach ($ds in $datastores){
    #### make sure no vms or templates
    $vms = get-vm -datastore $ds -server $vcenter_datastore_server
    $templates = get-template -datastore $ds -server $vcenter_datastore_server
    if($vms -or $templates){
        write-host $ds " contains vms or templates, exiting."
        exit
    }
    
    try{
        Unmount-Datastore -datastore $ds -vc_server $vcenter_datastore_server
    }
    catch{
        write-host "problem unmounting " $ds.name
    }

    #poll the vcenter every 2 seconds for a minute until the CPU goes above 35%
    $count = 0
    do{
        $percent = (get-stat -Entity $vcenter_vm -realtime -MaxSamples 1 -stat "cpu.usage.average").Value
        write-progress -activity "waiting for cpu to spike" -status $percent -PercentComplete $percent
        if ($percent -gt 25){
            break
        }
        $count++
        sleep -Seconds 2
    }while ( ($count -lt 29) -and ($percent -lt 25) )

    #poll the vcenter every 2 seconds for at least 2 minutes until the cpu drops below 20%
    $count = 0
    do{
        $percent = (get-stat -Entity $vcenter_vm -realtime -MaxSamples 1 -stat "cpu.usage.average").Value
        if ($percent -gt 20){
            $count = 0
        }
        write-progress -activity "waiting for cpu to settle" -status $percent -PercentComplete $percent
        $count++
        sleep -Seconds 2
    }while ($count -lt 60)

    write-host "count: " $count " percent: " $percent
}