param(
    [parameter(Mandatory=$true)]
    $clusterpattern
)

Get-VMHost -location $clusterpattern | % {
     $Server = $_
     ($Server | Get-View).config.storagedevice.multipathinfo.Lun | % { $_.Path } | ? { $_.PathState -like "Dead" } | select Name, PathState, Adapter |
     Add-Member -pass NoteProperty  Server $Server | select Server, Name, Adapter, PathState | ft -AutoSize
}



# $VMHosts = Get-VMHost -location $clusterpattern | ? { $_.ConnectionState -eq "Connected" } | Sort-Object -Property Name
# $results= @()

# foreach ($VMHost in $VMHosts) {

# 	#Get-VMHostStorage -RescanAllHba -VMHost $VMHost | Out-Null

# 	[ARRAY]$HBAs = $VMHost | Get-VMHostHba -Type "FibreChannel"

# 	foreach ($HBA in $HBAs) {
# 		$pathState = $HBA | Get-ScsiLun | Get-ScsiLunPath | Group-Object -Property state
#         write-host $pathState
# 		$pathStateActive = $pathState | ? { $_.Name -eq "Active"}
# 		$pathStateDead = $pathState | ? { $_.Name -eq "Dead"}
# 		$pathStateStandby = $pathState | ? { $_.Name -eq "Standby"}
# 		$results += "{0},{1},{2},{3},{4},{5}" -f $VMHost.Name, $HBA.Device, $VMHost.Parent, [INT]$pathStateActive.Count, [INT]$pathStateDead.Count, [INT]$pathStateStandby.Count
# 	}

# }
# ConvertFrom-Csv -Header "VMHost","HBA","Cluster","Active","Dead","Standby" -InputObject $results | Ft -AutoSize
