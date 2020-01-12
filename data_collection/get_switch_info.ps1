$start = Get-Date

$std_report = @()
$dvs_host_report = @()
$dvs_report = @()
Write-Progress -Activity "Getting Switch Information" -status "Starting..." -percentComplete (0)
#Get all standard switches

$switchs = Get-VirtualSwitch -Standard
$switch_count = $switchs.Count
if ($switchs -and (!$switch_count)){
	$switch_count = 1
}

$sc = 0
foreach ($s in $switchs) {
	$sc++
	Write-Progress -Activity "Getting Switch Information" -status "Processing Standard Switches step (1 of 2)" -percentComplete ($sc * 50 / $switch_count)
	$portGroups = $s | Get-VirtualPortGroup
	foreach ($pg in $portGroups) {
		$hrow = "" | select switchName, hostName, portname, port, vlanid
		$hrow.switchName = $s.Name
		$hrow.hostName = ($s.get_VMHost()).Name
		$hrow.portname = $pg.Name
		$hrow.port = $pg.Port
		$hrow.vlanid = $pg.VLanId
		$std_report += $hrow
	}
}

#Get all dv switches
$dvss = Get-VirtualSwitch -Distributed
$dc = 0
$dvs_count = $dvss.Count
if ($dvss -and (!$dvs_count)){
	$dvs_count = 1
}
	
foreach ($dvs in $dvss) {
	$dc++
	
	Write-Progress -Activity "Getting Switch Information" -status "Processing Distributed Switches step (2 of 2)" -percentComplete (($dc * 50 / $dvs_count)+50)
	$hostsConnected = Get-VMHost -DistributedSwitch $dvs
	foreach ($h in $hostsConnected) {
		$hrow = "" | select switchName, hostName
		$hrow.switchName = $dvs.Name
		$hrow.hostName = $h.Name

		$dvs_host_report += $hrow
	}
	
	$portGroups = $dvs | Get-VirtualPortGroup
	$pgc = 0
	foreach ($pg in $portGroups) {
		$pgc++
		if($dvs_count -eq 1){
			Write-Progress -Activity "Getting Switch Information" -status "Processing single Distributed Switches step (2 of 2)" -percentComplete (($pgc * 50 / $portGroups.Count)+50)
		}
		$row = "" | select switchName, portname, key, portbinding, numports, vlanid
		$row.switchName = $dvs.Name
		$row.portname = $pg.name
		$row.key = $pg.key
		$row.portbinding = $pg.PortBinding
		$row.numports = $pg.numports
		
		$vid = $pg.VlanId
		if(!$vid){
			$vid = $pg.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
		}
		if(!$vid){
			$vid = $pg.Notes
			if($vid){
				$vid = $vid.Split(' ')[1]
			}
		}
		
		$row.vlanid = $vid
		
		$dvs_report += $row
	}
}
Write-Progress -Activity "Getting Switch Information" -status "Writing Files" -percentComplete (100)
$date = Get-Date -Format "yyyy-M-d_hh-mm-ss"
$prefix = "c:\Temp\"+($Global:DefaultVIServer.name)
$std_report | Export-Csv ($prefix+"_std_switch_report-"+$date+".csv") -NoTypeInformation
$dvs_host_report | Export-Csv ($prefix+"_dvs_host_report-"+$date+".csv") -NoTypeInformation
$dvs_report | Export-Csv ($prefix+"_dvs_report-"+$date+".csv") -NoTypeInformation

((Get-Date)-$start) -f "m"
