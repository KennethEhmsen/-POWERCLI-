$dsTab = @{}
$report = @()
$esxName = "mmcloudesx050.navicloud-int.net"
foreach($ds in (Get-Datastore | where {$_.Type -eq "vmfs"})){
    $ds.Extensiondata.Info.Vmfs.Extent | %{
        $dsTab[$_.DiskName] = $ds.Name
    }
}


Get-ScsiLun -VmHost $esxName -LunType "disk" | %{
    $row = "" | Select Cluster, Host, ConsoleDeviceName, Vendor, Model, Datastore
    $row.Cluster = $cluster
    $row.host = $esxName
    $row.ConsoleDeviceName = $_.ConsoleDeviceName
    $row.vendor = $_.Vendor 
    $row.model = $_.Model
    $row.Datastore = &{
    if($dsTab.ContainsKey($_.CanonicalName)){
        $dsTab[$_.CanonicalName]
        }
    }
    $report += $row
} 

$report |Export-Csv c:\scripts\results.csv -NoTypeInformation 