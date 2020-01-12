Function Get-DatastoreMountInfo {
	[CmdletBinding()]
	Param (
		[Parameter(ValueFromPipeline=$true)]
		$Datastore
	)
	Process {
		$AllInfo = @()
		if (-not $Datastore) {
			$Datastore = Get-Datastore
		}
		Foreach ($ds in $Datastore) {  
			if ($ds.ExtensionData.info.Vmfs) {
				$hostviewDSDiskName = $ds.ExtensionData.Info.vmfs.extent[0].diskname
				if ($ds.ExtensionData.Host) {
					$attachedHosts = $ds.ExtensionData.Host | where {$_.MountInfo.Mounted -ne $null}
					
					Foreach ($VMHost in $attachedHosts) {
						write $VMHost.name
						$hostview = Get-View $VMHost.Key -property ConfigManager.StorageSystem,Name
						$hostviewDSState = $VMHost.MountInfo.Mounted
						$StorageSys = Get-View $HostView.ConfigManager.StorageSystem -Property StorageDeviceInfo.ScsiLun
						$devices = $StorageSys.StorageDeviceInfo.ScsiLun
						Foreach ($device in $devices) {
							$Info = "" | Select Datastore, VMHost, Lun, Mounted, State
							if ($device.canonicalName -eq $hostviewDSDiskName) {
								$hostviewDSAttachState = ""
								if ($device.operationalState[0] -eq "ok") {
									$hostviewDSAttachState = "Attached"							
								} elseif ($device.operationalState[0] -eq "off") {
									$hostviewDSAttachState = "Detached"							
								} else {
									$hostviewDSAttachState = $device.operationalstate[0]
								}
								$Info.Datastore = $ds.Name
								$Info.Lun = $hostviewDSDiskName
								$Info.VMHost = $hostview.Name
								$Info.Mounted = $HostViewDSState
								$Info.State = $hostviewDSAttachState
								$AllInfo += $Info
							}
						}
					}
				}
			}
		}
		$AllInfo
	}
}

Function Detach-Datastore {
	[CmdletBinding()]
	Param (
		[Parameter(ValueFromPipeline=$true)]
		$Datastore
	)
	Process {
		if (-not $Datastore) {
			Write-Host "No Datastore defined as input"
			Exit
		}
		Foreach ($ds in $Datastore) {
			$hostviewDSDiskName = $ds.ExtensionData.Info.vmfs.extent[0].Diskname
			if ($ds.ExtensionData.Host) {
				$attachedHosts = $ds.ExtensionData.Host

				Foreach ($VMHost in $attachedHosts) {
					$hh = Get-VMhost -Id $VMHost.Key
					#Ignore pre 5.1 hosts (could go lower, if tested)
					if ($hh.build -gt 799732 -and ($hh.ConnectionState -eq "Connected" -or $hh.ConnectionState -eq 'Maintenance')) {
						$hostview = Get-View $VMHost.Key -Property Name,configmanager.storagesystem
						$StorageSys = Get-View $HostView.ConfigManager.StorageSystem -Property StorageDeviceInfo.ScsiLun
						$devices = $StorageSys.StorageDeviceInfo.ScsiLun
						Foreach ($device in $devices) {
							if ($device.canonicalName -eq $hostviewDSDiskName -and $device.operationalState[0] -eq "ok") {
								$LunUUID = $Device.Uuid
								Write-Host "Detaching LUN $($Device.CanonicalName) from host $($hostview.Name)..."
								$StorageSys.DetachScsiLun($LunUUID);
							}
						}
					}
				}
			}
		}
	}
}

Function Unmount-Datastore {
	[CmdletBinding()]
	Param (
		[Parameter(ValueFromPipeline=$true)] $Datastore,
        [Parameter(ValueFromPipeline=$true)] $vc_server
	)
	Process {
		if (-not $Datastore) {
			Write-Host "No Datastore defined as input"
			Exit
		}
		Foreach ($ds in $Datastore) {
			$hostviewDSDiskName = $ds.ExtensionData.Info.vmfs.extent[0].Diskname
			if ($ds.ExtensionData.Host) {
				$attachedHosts = $ds.ExtensionData.Host
				
				Foreach ($VMHost in $attachedHosts) {
					$hh = Get-VMhost -Id $VMHost.Key -server $vc_server
					if ($VMHost.MountInfo.Mounted -eq $true -and ($hh.ConnectionState -eq "Connected" -or $hh.ConnectionState -eq 'Maintenance')) {
						$hostview = Get-View $VMHost.Key -server $vc_server
						$StorageSys = Get-View $HostView.ConfigManager.StorageSystem -server $vc_server
						Write-Host "Unmounting VMFS Datastore $($DS.Name) from host $($hostview.Name)..."
                        try{
						    $StorageSys.UnmountVmfsVolume($DS.ExtensionData.Info.vmfs.uuid);
                        }
                        catch{
                            write-host "Problem calling UnmountVMFSVolume for datastore: " $ds.Name
                        }
					}
				}
			}
		}
	}
}

Function Mount-Datastore {
	[CmdletBinding()]
	Param (
		[Parameter(ValueFromPipeline=$true)]
		$Datastore
	)
	Process {
		if (-not $Datastore) {
			Write-Host "No Datastore defined as input"
			Exit
		}
		Foreach ($ds in $Datastore) {
			$hostviewDSDiskName = $ds.ExtensionData.Info.vmfs.extent[0].Diskname
			if ($ds.ExtensionData.Host) {
				$attachedHosts = $ds.ExtensionData.Host
				Foreach ($VMHost in $attachedHosts) {
				    if ($VMHost.MountInfo.Mounted -eq $false -and $VMHost.ConnectionState -ne "Disconnected") {
						$hostview = Get-View $VMHost.Key
						$StorageSys = Get-View $HostView.ConfigManager.StorageSystem
						Write-Host "Mounting VMFS Datastore $($DS.Name) on host $($hostview.Name)..."
						$StorageSys.MountVmfsVolume($DS.ExtensionData.Info.vmfs.uuid);
					}
				}
			}
		}
	}
}

Function Attach-Datastore {
	[CmdletBinding()]
	Param (
		[Parameter(ValueFromPipeline=$true)]
		$Datastore
	)
	Process {
		if (-not $Datastore) {
			Write-Host "No Datastore defined as input"
			Exit
		}
		Foreach ($ds in $Datastore) {
			$hostviewDSDiskName = $ds.ExtensionData.Info.vmfs.extent[0].Diskname
			if ($ds.ExtensionData.Host) {
				$attachedHosts = $ds.ExtensionData.Host
				Foreach ($VMHost in $attachedHosts) {
					$hostview = Get-View $VMHost.Key
					$StorageSys = Get-View $HostView.ConfigManager.StorageSystem
					$devices = $StorageSys.StorageDeviceInfo.ScsiLun
					Foreach ($device in $devices) {
						if ($device.canonicalName -eq $hostviewDSDiskName) {
							$LunUUID = $Device.Uuid
							Write-Host "Attaching LUN $($Device.CanonicalName) to host $($hostview.Name)..."
							$StorageSys.AttachScsiLun($LunUUID);
						}
					}
				}
			}
		}
	}
}
#
#Get-Datastore | Get-DatastoreMountInfo | Sort Datastore, VMHost | FT -AutoSize
#
#Get-Datastore IX2ISCSI01 | Unmount-Datastore
#
#Get-Datastore IX2ISCSI01 | Get-DatastoreMountInfo | Sort Datastore, VMHost | FT -AutoSize
#
#Get-Datastore IX2iSCSI01 | Mount-Datastore
#
#Get-Datastore IX2iSCSI01 | Get-DatastoreMountInfo | Sort Datastore, VMHost | FT -AutoSize
#
#Get-Datastore IX2iSCSI01 | Detach-Datastore
#
#Get-Datastore IX2iSCSI01 | Get-DatastoreMountInfo | Sort Datastore, VMHost | FT -AutoSize
#
#Get-Datastore IX2iSCSI01 | Attach-datastore
#
#Get-Datastore IX2iSCSI01 | Get-DatastoreMountInfo | Sort Datastore, VMHost | FT -AutoSize
#