param(
    [parameter(Mandatory=$true)] $vmhost
)
$Report = @()

foreach ($d in get-datastore -vmhost $vmhost) {
  $row = "" | Select "Datastore", "FreeSpaceGB", "EUI"
  $row.datastore = $d.name
  $row.FreeSpaceGB = $d.FreeSpaceGB
  $row.EUI = ($d | get-view | %{$_.Info.vmfs.extent | select Diskname}).diskname
  $Report += $row

}

$Report