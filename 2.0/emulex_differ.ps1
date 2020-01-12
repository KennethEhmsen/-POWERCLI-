param(
    $file1,
	$file2
)
$ROOT = split-path -Parent $PSScriptRoot
. "$ROOT\utils\util.ps1"

$f1 = Import-Csv $file1
$f2 = Import-Csv $file2



$rpt = $f1 | % {
	$vmhost = $_.vmhost
	$row = $f2 | ? {$_.vmhost -eq $vmhost}
	
	

	[PSCustomObject]@{	
		"vmhost"= $_.vmhost;
		"vmnic0-ReceiveCRCerrors"=$row."vmnic0-ReceiveCRCerrors" - $_."vmnic0-ReceiveCRCerrors"
		"vmnic0-TotalReceiveErrors"=$row."vmnic0-TotalReceiveErrors" - $_."vmnic0-TotalReceiveErrors"
		"vmnic0-ReceivePacketsDropped"=$row."vmnic0-ReceivePacketsDropped" - $_."vmnic0-ReceivePacketsDropped"
		"vmnic1-ReceiveCRCerrors"=$row."vmnic1-ReceiveCRCerrors" - $_."vmnic1-ReceiveCRCerrors"
		"vmnic1-TotalReceiveErrors"=$row."vmnic1-TotalReceiveErrors" - $_."vmnic1-TotalReceiveErrors"
		"vmnic1-ReceivePacketsDropped"=$row."vmnic1-ReceivePacketsDropped" - $_."vmnic1-ReceivePacketsDropped"
		
	}
}

$fn = "c:\temp\diff-emulex-info-$((((Split-Path -leaf $file1) -split "__")[1] -split "\.")[0])___$((((Split-Path -leaf $file2) -split "__")[1] -split "\.")[0]).csv"
$rpt | Export-Csv -NoTypeInformation -path $fn
