param(
    $vcenters=@('an01-1-vc1', 'ch01-1-vc1', 're01-1-vc1', 'wo01-1-vc1'),
	[switch]$csv
	)

$ROOT = split-path -Parent $PSScriptRoot
. "$ROOT\utils\util.ps1"

disconnectvcs
connectvcs $vcenters

$rpt = get-vmhost -location zone* | sort -property name | % { 
	$z = get-esxcli -VMHost $_
	try {
		#esxcli network nic get -n vmnic0
		$driver0 = $z.network.nic.get('vmnic0').driverinfo
		$stats0 = $z.network.nic.stats.get('vmnic0')
		$driver1 = $z.network.nic.get('vmnic1').driverinfo
		$stats1 = $z.network.nic.stats.get('vmnic1')
	}
	catch {
		$result = $Error[0].exception.message
	}
	
	[PSCustomObject]@{	
		"vmhost"= $_.name;
		"vmnic0-FirmwareVersion"=$driver0.firmwareversion;
		"vmnic0-DriverVersion"=$driver0.version;
		"vmnic0-ReceiveCRCerrors"=$stats0.ReceiveCRCerrors;
		"vmnic0-TotalReceiveErrors"=$stats0.Totalreceiveerrors;
		"vmnic0-ReceivePacketsDropped"=$stats0.Receivepacketsdropped;
		"vmnic1-FirmwareVersion"=$driver1.firmwareversion;
		"vmnic1-DriverVersion"=$driver1.version;
		"vmnic1-ReceiveCRCerrors"=$stats1.ReceiveCRCerrors;
		"vmnic1-TotalReceiveErrors"=$stats1.Totalreceiveerrors;
		"vmnic1-ReceivePacketsDropped"=$stats1.Receivepacketsdropped;
	}
}

disconnectvcs

if ($csv) {
	dtcsv $rpt 'emulex-info'
}

$rpt
