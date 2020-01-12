param(
    [parameter(Mandatory=$true)]
    $datastorepattern
    )

$Report = @()

foreach ($h in (get-datastore -name $datastorepattern)) {
  $row = "" | Select "Datastore","Hosts Connected"
  $row."Datastore" = $h.Name
  $row."Hosts Connected" = ($h | get-vmhost).count
  $Report += $row
}
$Report | sort Datastore | format-table -autosize
