param(
    $vcenters=@('an01-1-vc1', 'ch01-1-vc1', 're01-1-vc1', 'wo01-1-vc1'),
	[switch]$csv
	)

$ROOT = split-path -Parent $PSScriptRoot
. "$ROOT\utils\util.ps1"

disconnectvcs
connectvcs $vcenters

$rpt = get-vmhost -location zone* | sort -property connectionstate, name | % { 
	$esxcli = get-esxcli -VMHost $_
	try {
		$driverinfo = $esxcli.network.nic.get('vmnic0').driverinfo
	}
	catch {
		$result = $Error[0].exception.message
	}

	$dvswitch="dvSwitch1"
	$vtepstatus = "Success"
	try {
		$a = $esxcli.network.vswitch.dvs.vmware.vxlan.vmknic.list($null, $dvswitch)
		if ($a.count -eq 0) {
			$vtepstatus = 'No vxlan vmknic'
		} elseif ($a.ip.startswith('169')) {
			$vtepstatus = 'Missing vtep ip address'
		}
	}
	catch {
		$vtepstatus = $Error[0].exception.message
	}
	
	[PSCustomObject]@{	
		"vmhost" = $_.name;
		"ConnectionState" = $_.connectionstate;
		"ESXiVersion" = $_.Version
		"Build" = $_.build;
		"FirmwareVersion" = $driverinfo.firmwareversion;
		"DriverVersion" = $driverinfo.version;
		"vtepStatus" = $vtepstatus;
	}
}

disconnectvcs

if ($csv) {
	dtcsv $rpt 'host_verification'
}

$rpt

