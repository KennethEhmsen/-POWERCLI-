param(
    [parameter(Mandatory=$true)]
    $clusterpattern='*'
)

$Report = @()
foreach ($cluster in get-cluster -name $clusterpattern) {
  $row = "" | Select "Cluster","Slots" 
  $slots = 0
  $vmhost = $cluster | get-vmhost | Select-Object -First 1
  if ($vmhost -ne $null) {
	 $vmhost | Get-Datastore | where {$_.Name.Substring(0,9) -cmatch 'Datastore'} | % {
		  $available = $_.FreeSpaceGB - 50
		  while (($available - 250) -gt 0) {
			 $available -= 250
			 $slots += 1
		  }
	  }
	}	
  $row.Cluster = $cluster.Name
  $row.slots = $slots
  $report += $row
}

$Report
