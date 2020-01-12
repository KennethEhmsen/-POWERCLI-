#$all_hosts = get-vmhost -name mmcloudesx090*
$all_hosts = get-vmhost -location mm01-cld*

$known_good_ds = get-datastore -vmhost *084*

$Report = @()

foreach ($h in $all_hosts) {
  $ds = get-datastore -vmhost $h
  if ($ds.count -ne 234) {
    $row = "" | Select "Cluster","Host","Datastore"
    $row."Cluster" = $h.parent.Name
    $row."Host" = $h.Name
    $qq = compare-object $known_good_ds $ds | where-object -filterscript {$_.inputobject -notlike '*boot'}

    $row.Datastore = $qq | select InputObject
  }
  $Report += $row
}
$Report | sort Cluster, Host, Datastore | format-table -autosize
