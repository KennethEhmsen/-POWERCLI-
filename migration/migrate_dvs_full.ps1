<#
.SYNOPSIS  Migrate specified vms to dvs from nexus in the same cluster
.DESCRIPTION The function will migrate specified vms to dvs from nexus
  in the same cluster
.NOTES  Author:  Kelby Valenti
.PARAMETER vms
  Specify the vms for migration
.PARAMETER cluster
  Specify the cluster to use
.PARAMETER dvs
  Specify the dvs to use
.PARAMETER bouncehost
  Specify the bouncehost to use
.EXAMPLE
  PS> $vms | .\migrate_dvs_full -vms $vms -dvs $dvs -cluster $cluster -bouncehost $bouncehost
#>
param(
    [parameter(
		Position=0,
		Mandatory=$true,
		ValueFromPipeline=$true)
	]
    $vms,
	[parameter(
		Mandatory=$true)
 	]
	$dvs,
	[parameter(
		Mandatory=$true)
 	]
	$cluster,
	[parameter(
		Mandatory=$true)
 	]
	$bouncehost
)

#Migrate vms to bounce host
$vms  | move-vm -Destination (get-vmhost $bouncehost)

#Change dvs
$vms | .\migrate_dvs.ps1 -dvs $dvs

#Migrate converted vms to dvshosts
$dvshosts = Get-VMHost -DistributedSwitch $dvs | where {$_.parent.Name -eq $cluster -and $_.Name -ne $bouncehost -and $_.connectionstate -eq ‘Connected’}
$vms | move-vm -Destination ($dvshosts | get-random)
$vms

