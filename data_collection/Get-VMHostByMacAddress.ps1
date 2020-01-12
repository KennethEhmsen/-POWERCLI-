function Get-VMHostByMacAddress {
  <#
  .SYNOPSIS
    Retrieves the host with a certain MAC address on a vSphere server.
     
  .DESCRIPTION
    Retrieves the host with a certain MAC address on a vSphere server.
     
  .PARAMETER MacAddress
    Specify the MAC address of the host to search for.
     
  .EXAMPLE
    Get-VMHostByMacAddress -MacAddress 00:0c:29:1d:5c:ec,00:0c:29:af:41:5c
    Retrieves the hosts with MAC addresses 00:0c:29:1d:5c:ec and 00:0c:29:af:41:5c.
     
  .EXAMPLE
    "00:0c:29:1d:5c:ec","00:0c:29:af:41:5c" | Get-VMHostByMacAddress
    Retrieves the hosts with MAC addresses 00:0c:29:1d:5c:ec and 00:0c:29:af:41:5c.
     
  .COMPONENT
    VMware vSphere PowerCLI
     
  .NOTES
    Author:  Robert van den Nieuwendijk
    Date:    17-07-2011
    Version: 1.0
  #>
   
  [CmdletBinding()]
  param(
    [parameter(Mandatory = $true,
               ValueFromPipeline = $true,
               ValueFromPipelineByPropertyName = $true)]
    [string[]] $MacAddress
  )
   
  begin {
    # $Regex contains the regular expression of a valid MAC address
    $Regex = "^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$"
     
    # Get all the hosts
    $HostsView = Get-View -ViewType HostSystem -Property Name,Config.Network
  }
   
  process {
    ForEach ($Mac in $MacAddress) {
      # Check if the MAC Address has a valid format
      if ($Mac -notmatch $Regex) {
        Write-Error "$Mac is not a valid MAC address. The MAC address should be in the format 99:99:99:99:99:99."
      }
      else {    
        $HostsView | `
          ForEach-Object {
            $HostView = $_
            # Search the physical nics
            if ($HostView.Config.Network.Pnic) {
              $HostView.Config.Network.Pnic | Where-Object {
                # Filter the hosts on Mac address
                $_.Mac -eq $Mac
              } | `
              Select-Object -property @{N="VMhost";E={$HostView.Name}},
                Device,
                Mac,
                Portgroup,
                @{N="IpAddress";E={$_.Spec.Ip.IpAddress}},
                @{N="DhcpEnabled";E={$_.Spec.Ip.Dhcp}}
            }
            # Search the virtual nics
            if ($HostView.Config.Network.Vnic) {
              $HostView.Config.Network.Vnic | Where-Object {
                # Filter the hosts on Mac address
                $_.Spec.Mac -eq $Mac
              } | `
              Select-Object -property @{N="VMhost";E={$HostView.Name}},
                Device,
                @{N="Mac";E={$_.Spec.Mac}},
                Portgroup,
                @{N="IpAddress";E={$_.Spec.Ip.IpAddress}},
                @{N="DhcpEnabled";E={$_.Spec.Ip.Dhcp}}
            }
            # Search the console virtual nics
            if ($HostView.Config.Network.ConsoleVnic) {
              $HostView.Config.Network.ConsoleVnic | Where-Object {
                # Filter the hosts on Mac address
                $_.Spec.Mac -eq $Mac
              } | `
              Select-Object -property @{N="VMhost";E={$HostView.Name}},
                Device,
                @{N="Mac";E={$_.Spec.Mac}},
                Portgroup,
                @{N="IpAddress";E={$_.Spec.Ip.IpAddress}},
                @{N="DhcpEnabled";E={$_.Spec.Ip.Dhcp}}
            }
          }
      }
    }
  }
}