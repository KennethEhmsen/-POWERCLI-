# -*- mode: shell-script -*-
##############################
<#  
.SYNOPSIS  
    Moves specified host from isolation into an active cluster and move another
    set of specified hosts into isolationK
.DESCRIPTION  
    Example usage:

    $oldhosts = get-vmhost -location "cluster-name1"
    $newhosts = get-vmhost -location "cluster-name2"
    $targetcluster = get-cluster -name "cluster-name1"
    $decommisioncluster = get-cluster -name "cluster-name2"
    $zertoip = "10.193.8.151"
    $zertoport = "9080"
    $zertouser = "admin"
    $zertopass = "lakepoopcrap"

    ./host_replace_zerto.ps1 -oldhosts $oldhosts -newhosts $newhosts -targetcluster \
         $targetcluster -decommisioncluster $decommisioncluster $zertoip $zertoip \
         -zertoport $zertoport -zertouser $zertouser -zertopass $zertopass
.NOTES  
    File Name  : host_replace_zerto.ps1
    Author     : Bill Bigness - william.bigness@twcable.com
    Requires   : PowerShell V2??
.LINK
    https://github.com/Navisite/powercli/blob/master/migration/host_replace_zerto.ps1
#>

param(
    [parameter(Mandatory=$true)] $oldhosts,
	[parameter(Mandatory=$true)] $newhosts,
	[parameter(Mandatory=$true)] $targetcluster,
	[parameter(Mandatory=$true)] $decommissioncluster,
	$templatetargethost=$null,
    [parameter(Mandatory=$true)] $zertoip,
    [parameter(Mandatory=$true)] $zertoport,
    [parameter(Mandatory=$true)] $zertouser,
    [parameter(Mandatory=$true)] $zertopass,
	[ValidateRange(1,32)] [Int] $maxhostsincluster=25,
    [STRING]$VRASelector='z-vra*.navicloud-int.net',
    [STRING]$DSVASelector='dsva*.navicloud-int.net'
)

if ( (Get-PSSnapin -Name "Zerto.PS.Commands" -ErrorAction SilentlyContinue) -eq $null ) {
    Add-PsSnapin "Zerto.PS.Commands"
}

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
$movedhosts = @()
#Create basic param arguments
$args = @{
    "ZVMIP" = $zertoip;
    "ZVMPort" = $zertoport;
	"UserName" = $zertouser;
	"Password" = $zertopass;
    }

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
	 write-host $newhost.name "  Move to proper cluster"
	 Move-VMHost $newhost -destination $targetcluster

	 write "  Exit Maintenance mode"
	 Set-VMHost -VMHost $newhost -State "connected"
     #front load hosts to max limit
	 if ($hostslots -gt 1) {
	 	$hostslots -= 1
        # power on VRA
        $vra_vm = get-vm -name ("Z-VRA-" + $newhost.name)
        if ($vra_vm) {
            Start-VM -VM $vra_vm -RunAsync
        }
        $movedhosts += $newhost
		continue
	 }
  }
  
  $oldhost, $oldhosts = $oldhosts
  if ($oldhost -ne $null) {
	 write $oldhost.name

	 write "  Move templates"
	 Get-Template -Location $oldhost | Set-Template -ToVM | Move-VM -Destination (get-random -input $movedhosts) | Set-VM -ToTemplate -Confirm:$false

	 try {
	 	$WorkloadsToMove = Get-VmsReplicatingToHost @args -HostIp $oldhost
	 } catch {
		Write-Warning "Unable to find any workloads on $SourceVMHost. Exception: $_.Exception.Message"
	 }
     if($WorkloadsToMove) {
        $idx = 0
        foreach ($Workload in $WorkloadsToMove) {
            $desthost = (get-random -input $movedhosts)
            Write-Verbose "Moving $Workload from $oldhost to $desthost"
            try {
                Set-ChangeRecoveryHost @args -VmName $Workload -CurrentTargetHost $oldhost -NewTargetHost $desthost | Out-Null
            } catch {
                Write-Warning "Unable to move $Workload from $oldhost to $desthost. Exception: $_.Exception.Message"
            }
        }
     }
	 write "  Enter Maintenance mode" $oldhost.name
     $return_id = Set-VMHost -VMHost $oldhost -State "maintenance" -runasync -Evacuate:$true

     $complete = $false
     while ($complete -eq $false) {
            $connectionhost = Get-VMHost $oldhost.Name
                       
            # Check state of host. If in Maintenance Mode, task complete. If not in maintenance mode, get a count of the powered on VMs. Once the count reaches 
            # reaches 0 ([powered-on] - 1[vra] - 1[dsva] = 0), initiate gust shutdown on VRA and DSVA
            if ($connectionhost.ConnectionState -eq "Maintenance") {
                Write-Host "$oldhost is now in Maintenance Mode"
                $complete = $true
            }
            else {
                # Get list of VMs that are powered on
				$poweredonvms = $connectionhost | Get-VM | Where-Object {$_.PowerState -eq "PoweredOn"}
                $vra = $poweredonvms | where {$_.name -like $VRASelector}
                $dsva = $poweredonvms | where {$_.name -like $DSVASelector}
                $poweredoncount = ($poweredonvms.count - $vra.count - $dsva.count)
                if ($poweredoncount -eq 0) {
                    Write-Host `n"$poweredoncount VMs powered on."
					if ($vra -ne $null) {
                        Write-Host `n"Shutting down VRA..."
                        $vra | Shutdown-VMGuest -confirm:$false
                    }
                    if ($dsva -ne $null) {
                        Write-Host `n"Shutting down DSVA..."
                        $dsva | Shutdown-VMGuest -confirm:$false
                    }
                    Start-Sleep -Seconds 25 # Allow VM to power off before starting next loop
                }
                else {
                    Write-Host `n"There are $poweredoncount VMs remaining on the host"
                    Start-Sleep -Seconds 60
                }
            }
        }


	 write "  Move to decommision cluster" $oldhost.name
	 Move-VMHost $oldhost -destination $decommissioncluster
  }
}

#TODO add a check to make sure all VRA's are actually powered on
