param(
    [parameter(Mandatory=$true)]
    $datastores
)
$WAITSECS = 1000

$datastores = $datastores.split(',')

$ctr = 0
$datastores | % {
  $datastore = Get-Datastore -Name $_
  $datastore | set-datastore -name "X$datastore"
  $ctr++
  if ($ctr -ne $datastores.Count) {
	for ($a=1; $a -lt $WAITSECS; $a++) {
		Write-Progress -Activity "Working..." -SecondsRemaining $a -CurrentOperation "$($a/$WAITSECS*100)% complete" -Status "Please wait."
		Start-Sleep 1
        if ($Host.UI.RawUI.KeyAvailable -and ("c" -eq $Host.UI.RawUI.ReadKey("IncludeKeyUp,NoEcho").Character)) {
			break
		}
	}
  }
}
