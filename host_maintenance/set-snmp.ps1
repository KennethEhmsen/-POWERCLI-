param(
  [parameter(Mandatory=$true)] $vmhosts
)
	
$communities = "9_jv4xq"
$syslocation = "NaviSite, Inc."
$syscontact = "nocmonitor@navisite.com"
$port = "161"
$targets = "127.0.0.1@162 public"
	
foreach ($vmhost in $vmhosts) {
  Write-Host "vmhost = $($vmhost)"
  $esxcli = Get-EsxCli -VMHost $vmhost
  $esxcli.system.snmp.set($null,$communities,"true",$null,$null,$null,$null,$null,$port,$null,$null,$null,$syscontact,$syslocation,$targets)
  #$esxcli.system.snmp.get()
}