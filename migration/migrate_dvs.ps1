<#
.SYNOPSIS  Change portgroup to a dvs based switch
.DESCRIPTION The function will change all attached portgroups 
  to their dvs equivalent.
.NOTES  Author:  Kelby Valenti
.PARAMETER vms
  Specify the vms for which you want to change the portgroup
.PARAMETER dvs
  Specify the dvs to use
.EXAMPLE
  PS> .\migrate_dvs -vms $vms -dvs $dvs
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
	$dvs
)


function Get-dvPgFreePort{
  <#
.SYNOPSIS  Get free ports on a dvSwitch portgroup
.DESCRIPTION The function will return 1 or more
  free ports on a dvSwitch portgroup
.NOTES  Author:  Luc Dekens
.PARAMETER PortGroup
  Specify the portgroup for which you want to retrieve
  free ports
.EXAMPLE
  PS> Get-dvPgFreePort -PortGroup $pg
#>

  param(
  [CmdletBinding()]
  [string]$dvsName,
  [string]$PortGroup
  )

  $nicTypes = "VirtualE1000","VirtualE1000e","VirtualPCNet32",
  "VirtualVmxnet","VirtualVmxnet2","VirtualVmxnet3" 
  $ports = @{}

  $pg = Get-VirtualPortGroup -Distributed -VirtualSwitch $dvsName -Name $PortGroup
  $pg.ExtensionData.PortKeys | %{$ports.Add($_,$pg.Name)}

  Get-View $pg.ExtensionData.Vm | %{
    $nic = $_.Config.Hardware.Device | 
    where {$nicTypes -contains $_.GetType().Name -and
      $_.Backing.GetType().Name -match "Distributed"}
    $nic | %{$ports.Remove($_.Backing.Port.PortKey)}
  }

  if($Number -gt $ports.Keys.Count){
    $Number = $ports.Keys.Count
  }
  ($ports.Keys | Sort-Object)
}


#Change dvs
$PORTS = @{}
$vms | Get-NetworkAdapter | % {
   if ($PORTS.containskey($_.NetworkName) -eq $false) {
      $PORTS.Add($_.NetworkName, (Get-dvPgFreePort -dvsName $dvs -PortGroup $_.NetworkName))
   }
   write $_.NetworkName
   write $distributedswitch
   write $PORTS

   $key, $PORTS[$_.NetworkName] = $PORTS[$_.NetworkName]
   write $key
   $_ | Set-NetworkAdapter -Confirm:$false -PortKey $key -DistributedSwitch $dvs
}