param(
    [parameter(Mandatory=$true)]
    $vihost,
    [parameter(Mandatory=$true)]
    $user,
    [parameter(Mandatory=$true)]
    $pass,
    [parameter(Mandatory=$true)]
    $clusterpattern
    )

. ..\utils\util.ps1

$srv = connect $vihost $user $pass
Write-Host "Rescanning for new devices and Datastores..."


$CNT = 15
$hosts = Get-vmHost -location $clusterpattern
$max = $hosts.count
$ctr = 0
do {
	$names = @()
	foreach ($h in $hosts | sort-object | select -First $CNT -Skip $ctr | select Name) {
		$names += $h.name
	}
	$names = $names -join ','
	
    $PSLine = "Start-Job -Name JOB$ctr -ScriptBlock {powershell.exe C:\Users\kvalenti\Documents\GitHub\powercli\datastore_maintenance\scan-hba-worker.ps1 $($srv.Name) $($srv.SessionId) '$names'}"
	write "Spawned $PSLine"
	Invoke-Expression $PSLine

	$ctr += $CNT
} while ($ctr -lt $max)
 
$getjobs = Get-Job

do { 
  sleep 5
  $getjobs = Get-Job | where {$_.state -eq "Running"}
  $getjobs
  write-host " "
} while ($getjobs -ne $null)


