param(
    $vcenters=@('an01-1-vc1', 'ch01-1-vc1', 're01-1-vc1', 'sa01-1-vc1', 'wo01-1-vc1')
	)

$ROOT = split-path -Parent $PSScriptRoot
. "$ROOT\utils\util.ps1"

disconnectvcs
connectvcs $vcenters

$rpt = get-vmhost -location *zone* | sort -property connectionstate, name | % { 
	$dvswitch = get-vdswitch -name "*-1-dvSwitch1"
	$z = get-esxcli -VMHost $_
	$result = 'Success'
	try {
		$a = $z.network.vswitch.dvs.vmware.vxlan.vmknic.list($null, $dvswitch.name)
		if ($a.count -eq 0) {
			$result = 'No vxlan vmknic'
		} elseif ($a.ip.startswith('169')) {
			$result = 'Missing vtep ip address'
		}
	}
	catch {
		$result = $Error[0].exception.message
	}
	[PSCustomObject]@{	
		"vmhost"= $_.name;
		"connectionstate" = $_.connectionstate;
		"result" = $result;
	}
}

disconnectvcs
$rpt | ft -autosize
