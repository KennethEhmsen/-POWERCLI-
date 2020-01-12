param(
	[parameter(Mandatory=$true)]
    $bouncehost,
	[parameter(Mandatory=$true)]
    $targethost,
	[parameter(Mandatory=$true)]
    $distributedswitch,
	$vmstomove,
	$tmplstomove,
	$srchost
)

$ErrorActionPreference = "Stop"

if ($srchost -ne $null) {
	$tmplstomove = Get-Template -Location $srchost
	$vmstomove = Get-VM -Location $srchost
}

$PORTGROUPS = @{}

function migrate_networking {
	param(
	[parameter(Mandatory=$true)]
	$vms,
	[parameter(Mandatory=$true)]
	$dvs
	)
	$vms | Get-NetworkAdapter | % {
		write "    Migrate $($_.networkname) to $($dvs.name)"
		
		if ($_ -eq $null) {
			continue
		}
		
		if ($PORTGROUPS.ContainsKey($_.NetworkName) -eq $true) {
			$targetportgroup = $PORTGROUPS[$_.NetworkName]
		}
		else {
			$targetportgroup = Get-VDPortgroup -name $_.NetworkName -VDSwitch $dvs
			if ($targetportgroup -eq $null) {
				write "$($_.parent.name) - Unable to find $($_.NetworkName) attached to $($dvs)"
				exit
			}
			$PORTGROUPS[$_.NetworkName] = $targetportgroup
		}
		
	 	Start-Sleep 10
		$_ | Set-NetworkAdapter -Portgroup $targetportgroup -Confirm:$false | Out-Null
	}
}



#Migrate templates
if ($tmplstomove -ne $null) {
	write "Migrating templates"
	$tmplstomove | % {
		if ($Host.UI.RawUI.KeyAvailable -and ("s" -eq $Host.UI.RawUI.ReadKey("IncludeKeyUp,NoEcho").Character)) {
			exit
		}

		write "  $($_.name)"
		
		#Untemplatize
		write "    Untemplatize"
		$_ | Set-Template -ToVM | Out-Null

		#Get vm object
		$vm = Get-VM -Name $_.name

		#Migrate template to bounce host
		write "    Migrate template to bounce host"
		$vm | move-vm -Destination $bouncehost | Out-Null

		#Change dvs
		migrate_networking -vms $vm -dvs $distributedswitch

		#Migrate converted template to targethost
		write "    Migrate to target host"
		$vm | move-vm -Destination $targethost | Out-Null

		#Templatize
		write "    Templatize"
		$vm | Set-vm -ToTemplate -Confirm:$False -RunAsync:$true | Out-Null
	}
}

#Migrate vms
if ($vmstomove -ne $null) {
	write "Migrating VMs"
	$vmstomove | % {
		if ($Host.UI.RawUI.KeyAvailable -and ("s" -eq $Host.UI.RawUI.ReadKey("IncludeKeyUp,NoEcho").Character)) {
			exit
		}	

		write "  $($_.name)"

		#Migrate vms to bounce host
		write "    Migrate to bounce host"
		$_ | move-vm -Destination $bouncehost | Out-Null

		#Change dvs
		migrate_networking -vms $_ -dvs $distributedswitch

		#Migrate converted vms to targethost
		write "    Migrate to target host"
		$_ | move-vm -Destination $targethost | Out-Null
	}
}

