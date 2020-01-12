param(
    $vcenters=@('an01-m-vc', 'ch01-m-vc', 're01-m-vc', 'sa01-m-vc', 'wo01-m-vc', 'an01-1-vc1', 'ch01-1-vc1', 're01-1-vc1', 'sa01-1-vc1', 'wo01-1-vc1')
	)

$ROOT = split-path -Parent $PSScriptRoot
. "$ROOT\utils\util.ps1"

disconnectvcs
connectvcs $vcenters

$rpt = get-vmhost | sort -property connectionstate, name | % { 
	$z = get-esxcli -VMHost $_
	
	$vmnic0 = $z.network.nic.get("vmnic0").driverinfo
	$vmnic1 = $z.network.nic.get("vmnic1").driverinfo
	
	[PSCustomObject]@{	
		"vmhost"= $_.name;
		"vmnic0_driver" = $vmnic0.driver;
		"vmnic0_firmwaredriver" = $vmnic0.firmwareversion;
		"vmnic0_version" = $vmnic0.version;
		"vmnic1_driver" = $vmnic1.driver;
		"vmnic1_firmwaredriver" = $vmnic1.firmwareversion;
		"vmnic1_version" = $vmnic1.version;
	}
}

disconnectvcs
$rpt | sort vmhost | ft -autosize
