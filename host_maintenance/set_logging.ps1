 param(
    [parameter(Mandatory=$true)]
	$Hosts,
	[parameter(Mandatory=$true)]
	$SplunkTargetIp
)		

$Hosts | % {
    Write-Host "Adding $splunktargetip as Syslog server for $($_.Name)"
    $SetSysLog = Get-AdvancedSetting -Entity $_ -Name "Syslog.global.logHost" | Set-AdvancedSetting -Value $SplunkTargetIp -Confirm:$False
    Write-Host "Reloading Syslog on $($_.Name)"
    $Reload = (Get-ESXCLI -VMHost $_).System.Syslog.reload()
    Write-Host "Setting firewall to allow Syslog out of $($_)"
    $FW = $_ | Get-VMHostFirewallException -Name "syslog" | Set-VMHostFirewallException -Enabled:$true
}
