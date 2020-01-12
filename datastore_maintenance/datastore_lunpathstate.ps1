$initalTime = Get-Date
$filepath = "C:temp"
$filename = "LunPathState"
$date = Get-Date ($initalTime) -uformat %Y%m%d
$time = Get-Date ($initalTime) -uformat %H%M

Write-Host "$(Get-Date ($initalTime) -uformat %H:%M:%S) - Starting"

$AllHosts = Get-VMHost | Sort Name

$reportLunPathState = @()

Write-Host "$(Get-Date -uformat %H:%M:%S) - $($AllHosts.length) hosts acquired"

$i = 0
ForEach ($VMHost in $AllHosts) {
    $i++
    Write-Host "$(Get-Date -uformat %H:%M:%S) - $($i) of $($AllHosts.length) - $($VMHost)"
    $VMHostScsiLuns = $VMHost | Get-ScsiLun -LunType disk
    ForEach ($VMHostScsiLun in $VMHostScsiLuns) {
        $VMHostScsiLunPaths = $VMHostScsiLun | Get-ScsiLunPath
        $reportLunPathState += ($VMHostScsiLunPaths | Measure-Object) | Select @{N="Hostname"; E={$VMHost.Name}}, @{N="Number of Paths"; E={$_.Count}}, Name, State
        $reportLunPathState += $VMHostScsiLunPaths | Select @{N="Hostname"; E={$VMHost.Name}}, "Number of Paths", Name, State
    }
}

$conclusionTime = Get-Date
Write-Host "$(Get-Date ($conclusionTime) -uformat %H:%M:%S) - Finished"
$totalTime = New-TimeSpan $initalTime $conclusionTime
Write-Host "$($totalTime.Hours):$($totalTime.Minutes):$($totalTime.Seconds) - Total Time"

$reportLunPathState | Out-GridView
$reportLunPathState | Export-Csv $filepath$date$time"-"$filename".csv" -NoType
