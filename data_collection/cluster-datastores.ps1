$TDate = Get-Date -uformat "%m%d%Y"
$File = "DataStore_Report_" + $TDate + ".csv"

# Check to see if the file exists 
if (Test-Path $File)
{
  Remove-Item $File
}

$DS = @()
Get-Cluster | ForEach-Object {
  $Cluster = $_
  $Cluster | Get-VMHost | ForEach-Object {
    $VMHost = $_
    $VMHost | Get-DataStore | Where-Object { $_.Name -notlike "local*"} | ForEach-Object { 
      $out = "" | Select-Object Cluster, DSName, FreespaceGB, CapacityGB, PercentFree
      $out.Cluster = $Cluster.Name
      $out.DSName = $_.Name
      $out.FreespaceGB = $($_.FreespaceMB / 1024).tostring("F02")
      $out.CapacityGB = $($_.CapacityMB / 1024).tostring("F02")
      $out.PercentFree = (($_.FreespaceMB) / ($_.CapacityMB) * 100).tostring("F02")
      $DS += $out 
    }
  }
}
$DS | Sort-Object Cluster, DSName -Unique | Export-Csv -NoTypeInformation -UseCulture -Path $File

