$EmailAddresses = 'dl-cld-alerts@navisite.com'

function set_email {
  Param($alarmname, $emailaddress="")
  Get-AlarmDefinition -Name $alarmname | New-AlarmAction -Email -To ($emailaddress)
}

function set_trigger {
  Param($alarmname, $startstatus="", $endstatus="")
  Get-AlarmDefinition -Name $alarmname | Get-AlarmAction -ActionType SendEmail | New-AlarmActionTrigger -StartStatus "$startstatus" -EndStatus "$endstatus"
}

function remove_alarmaction {
  Param($alarmname)
  Get-AlarmDefinition -Name $alarmname | Get-AlarmAction | where ActionType -eq SendEmail | Remove-AlarmAction -Confirm:$false
}

$decode = @{"Y"='Yellow'; 'G'='Green'; 'R'='Red'}
function set_alarm {
  param($alarmname, $emailaddress, $status=@())
  
  remove_alarmaction $alarmname
  set_email $alarmname $emailaddress
  $status | % {
	$startstatus = $decode[$_[0].tostring()]
	$endstatus = $decode[$_[1].tostring()]
	
	if ($startstatus -eq 'Yellow' -and $endstatus -eq 'Red') {
	  return
	}
	set_trigger $alarmname $startstatus $endstatus
  }
}


set_alarm  "Host connection and power state" $emailaddresses @("YR", "RY")
set_alarm  "Cannot connect to storage" $emailaddresses @("YR", "RY")
set_alarm  "Datastore cluster is out of space" $emailaddresses @("YR", "RY")
set_alarm  "vSphere HA failover in progress" $emailaddresses @("YR", "RY")
set_alarm  "vSphere Distributed Switch vlan trunked status" $emailaddresses @("YR", "RY")
set_alarm  "vSphere Distributed Switch MTU matched status" $emailaddresses @("YR", "RY")
set_alarm  "Network connectivity lost" $emailaddresses @("YR", "RY")


