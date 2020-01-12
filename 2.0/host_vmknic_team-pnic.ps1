param(
    $vcenter=@('an01-1-vc1', 're01-1-vc1', 'sa01-1-vc1', 'wo01-1-vc1'),
	[parameter(Mandatory=$false)][bool]$outputcsv
	)

$ROOT = split-path -Parent $PSScriptRoot
. "$ROOT\utils\util.ps1"

disconnectvcs
connectvcs $vcenter

$vmhosts = Get-VMHost
foreach( $vmhost in $vmhosts){
    if($vmhost.name.startswith('sa01')){
        $passwd = '__PASSWORD__'
    }
    else{
        $passwd = '__PASSWORD__'
    }
    Write-Host 'Connecting to :' + $vmhost
    connect-viserver $vmhost -username root -password $passwd
}
$results = Get-EsxTop -CounterName NetPort | select @{n="VMHostName"; e={$_.Server.Name}}, ClientName, TeamUplink | where clientname -eq "vmk2" | Sort-Object -Property TeamUplink,VMHostName
$results | format-table
if( $outputcsv ){
	$results | Export-Csv -NoTypeInformation -UseCulture c:\host-portgroup.csv
}

disconnectvcs