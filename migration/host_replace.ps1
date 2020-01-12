param(
    [parameter(Mandatory=$true)]
    $oldhosts,
	[parameter(Mandatory=$true)]
    $newhosts,
	[parameter(Mandatory=$true)]
    $targetcluster,
	[parameter(Mandatory=$true)]
    $decommissioncluster,
	$templatetargethost=$null,
	[ValidateRange(1,32)] 
	[Int]
	$maxhostsincluster=25
)


function confirm {
Param($title="Confirm", $msg="")
	$choiceYes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Answer Yes."
	$choiceNo = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Answer No."
	$options = [System.Management.Automation.Host.ChoiceDescription[]]($choiceYes, $choiceNo)
	$result = $host.ui.PromptForChoice($title, $msg, $options, 1)
	switch ($result) {
		0 {Return $true}
		1 {Return $false}
	}
}

if (($newhosts | where {$_.connectionstate -eq 'maintenance'}).count -ne $newhosts.count) {
	write 'Not all new hosts are in maintenance mode'
	exit
}

if (($oldhosts | where {$_.connectionstate -eq 'connected'}).count -ne $oldhosts.count) {
	write 'Not all old hosts are connected'
	exit
}

$newhosts = $newhosts | sort-object -property name
$oldhosts = $oldhosts | sort-object -property name

if ($templatetargethost -eq $null) {
	if ($newhosts -eq $null) {
		write "No available host for templates"
		exit
	}
	$templatetargethost = $newhosts[0]
}

write "Original Hosts"
write $oldhosts | ft -AutoSize
write "`n`nNew Hosts"
write $newhosts | ft -AutoSize
write "`n`nTemplate Target Host"
write $templatetargethost | ft -AutoSize
write " "
write "Remember to set DRS to Fully automated level 1 and to disable HA."
if ((confirm -msg "Is this done?") -eq $false) {
  exit
}

write " "
write "Also run check_mounted_cds to make sure no tools CDs are going to hang the script."
if ((confirm -msg "Did you do this?") -eq $false) {
  exit
}
write " "

#Determine how many hosts we can add to cluster before starting evacs
$hostslots = $maxhostsincluster - ($targetcluster | get-vmhost).count
	
while ($oldhosts -ne $null -or $newhosts -ne $null) {
  $newhost, $newhosts = $newhosts
  
  if ($newhost -ne $null) {
	 write $newhost.name
	 
	 write "  Move to proper cluster"
	 Move-VMHost $newhost -destination $targetcluster

	 write "  Exit Maintenance mode"
	 Set-VMHost -VMHost $newhost -State "connected"
	 if ($hostslots -gt 1) {
	 	$hostslots -= 1
		continue
	 }
  }
  
  $oldhost, $oldhosts = $oldhosts
  if ($oldhost -ne $null) {
	 write $oldhost.name

	 write "  Move templates"
	 Get-Template -Location $oldhost | Set-Template -ToVM | Move-VM -Destination $templatetargethost | Set-VM -ToTemplate -Confirm:$false

	 write "  Enter Maintenance mode"
     Set-VMHost -VMHost $oldhost -State "maintenance" -Evacuate:$true

	 write "  Move to decommision cluster"
	 Move-VMHost $oldhost -destination $decommissioncluster
  }
}

