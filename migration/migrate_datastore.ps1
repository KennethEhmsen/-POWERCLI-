# MigrateDatastore.ps1
# Curtis Salinas, 2011
# Twitter: @virtualcurtis
# Blog: virtualcurtis.wordpress.com

param(
    [Parameter(Mandatory = $True)] [String] $Vcenter,
    [Parameter(Mandatory = $True)] [String] $sourceDatastore,
    [Parameter(Mandatory = $True)] [String] $destinationDatastore
)

Function InitializePCLI {
    <#
    .Description
    Initialize the PowerCLI Modules required to run the script and connect to the VIServer.
    .Example
    InitializePCLI -VIServer MyVIServer

    Successfully connected to MyVIServer
	#>
    param(
        [String] $VIServer
    )
 
    $VCenter = $VIServer

    # add VMware PS snapin
    if (-not (Get-PSSnapin VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) {
        Add-PSSnapin VMware.VimAutomation.Core
    }
  
    # Set PowerCLI to single server mode
    Set-PowerCLIConfiguration -DefaultVIServerMode Single -Confirm:$False
  
    Write-Host `n"Connecting to vCenter...$VIServer"

    Do {
        Try {
            $StopLoop = $True
            Connect-VIServer -Server $VCenter -EA Stop
        } Catch {
            Write-Host "Connection to vCenter failed.`nPlease verify ADDRESS, USER NAME, and PASSWORD"
            $VCenter = Read-Host "Please enter valid vcenter address"
            $StopLoop = $False
        }
    } Until ($StopLoop -eq $True)
}

Function Migrate-VMConfig {
    <#
    .Description
    Script to evacuate virtual disks and/or VM config files from a given datastore; does not move the entire VM and all its disks if they reside elsewhere. Created 12-Dec-2012 by vNugglets.com.
    .Example
    EvacuateDatastore.ps1 -SourceDatastore datastoreToEvac -DestDatastore destinationDatastore

    Move virtual disks and/or VM config files (if any) from source datastore to the destination datastore
	#>

    param(
        [parameter(Mandatory = $true)][string]$SourceDatastore,
        [parameter(Mandatory = $true)][string]$DestDatastore
    )

    $strSrcDatastore = $SourceDatastore
    $strDestDatastore = $DestDatastore

    ## Get the .NET view of the source datastore
    $viewSrcDatastore = Get-View -ViewType Datastore -Property Name -Filter @{"Name" = "^${strSrcDatastore}$"}
    ## Get the linked view that contains the list of VMs on the source datastore
    $viewSrcDatastore.UpdateViewData("Vm.Config.Files.VmPathName", "Vm.Config.Hardware.Device", "Vm.Config.Template", "Vm.Runtime.Host", "Vm.Name")
    ## Get the .NET view of the destination datastore
    $viewDestDatastore = Get-View -ViewType Datastore -Property Name -Filter @{"Name" = "^${strDestDatastore}$"}
    ## Create a VirtualMachineMovePriority object for the RelocateVM task; 0 = defaultPriority, 1 = highPriority, 2 = lowPriority (per http://pubs.vmware.com/vsphere-51/index.jsp?topic=%2Fcom.vmware.wssdk.apiref.doc%2Fvim.VirtualMachine.MovePriority.html)
    $specVMMovePriority = New-Object VMware.Vim.VirtualMachineMovePriority -Property @{"value__" = 1}
    ## Create empty arrays to track templates and VMs
    $arrVMList = $arrTemplateList = @()

    ## For each VM managed object, sort into separate arrays based on whether it is a VM or a template
    $viewSrcDatastore.LinkedView.Vm | ForEach-Object {
        ## If object is a template, add to template array
        if ($_.Config.Template -eq "True") {
			$arrTemplateList += $_
		} else {
			$arrVMList += $_
		}
    }

    ## For each VM object, initiate the RelocateVM_Task() method; for each template object, initiate the RelocateVM() method
    $arrVMList, $arrTemplateList | ForEach-Object {$_} | ForEach-Object {
        $viewVMToMove = $_
        ## Create a VirtualMachineRelocateSpec object for the RelocateVM task
        $specVMRelocate = New-Object Vmware.Vim.VirtualMachineRelocateSpec
        ## Create an array containing all the virtual disks for the current VM/template
        $arrVirtualDisks = $viewVMToMove.Config.Hardware.Device | Where-Object {$_ -is [VMware.Vim.VirtualDisk]}
        ## If the VM/template's config files reside on the source datastore, set this to the destination datastore (if not specified, the config files are not moved)
        if ($viewVMToMove.Config.Files.VmPathName.Split("]")[0].Trim("[") -eq $strSrcDatastore) {
            $specVMRelocate.Datastore = $viewDestDatastore.MoRef
        } ## end if

        ## For each VirtualDisk for this VM/template, make a VirtualMachineRelocateSpecDiskLocator object (to move disks that are on the source datastore, and leave other disks on their current datastore)
        ## But first, make sure the VM/template actually has any disks
        if ($arrVirtualDisks) {
            foreach ($oVirtualDisk in $arrVirtualDisks) {
                $oVMReloSpecDiskLocator = New-Object VMware.Vim.VirtualMachineRelocateSpecDiskLocator -Property @{
                    ## If this virtual disk's filename matches the source datastore name, set the VMReloSpecDiskLocator Datastore property to the destination datastore's MoRef, else, set this property to the virtual disk's current datastore MoRef
                    DataStore = if ($oVirtualDisk.Backing.Filename -match $strSrcDatastore) {$viewDestDatastore.MoRef}
                                else {$oVirtualDisk.Backing.Datastore}
                    DiskID = $oVirtualDisk.Key
                } ## end new-object
                $specVMRelocate.disk += $oVMReloSpecDiskLocator
            } ## end foreach
        } ## end if

        ## Determine if template or VM, then perform necessary relocation steps
        if ($viewVMToMove.Config.Template -eq "True") {
            ## Gather necessary objects to mark template as a VM (VMHost where template currently resides and default, root resource pool of the cluster)
            $viewTemplateVMHost = Get-View -Id $_.Runtime.Host -Property Parent
            $viewTemplateResPool = Get-View -ViewType ResourcePool -Property Name -SearchRoot $viewTemplateVMHost.Parent -Filter @{"Name" = "^Resources$"}
            ## Mark the template as a VM
            $_.MarkAsVirtualMachine($viewTemplateResPool.MoRef, $viewTemplateVMHost.MoRef)
            ## Relocate the template synchronously (i.e. one at a time)
            $viewVMToMove.RelocateVM($specVMRelocate, $specVMMovePriority)
            ## Convert VM back to template
            $viewVMToMove.MarkAsTemplate()
        } else {
            ## Initiate the RelocateVM task (asynchronously)
            $viewVMToMove.RelocateVM_Task($specVMRelocate, $specVMMovePriority)
        }
    } ## end foreach-object
}

InitializePCLI -VIServer $Vcenter

Write-Host "Environment loaded and successfully connected to $Vcenter"`n

$sourceDS = Get-Datastore $sourceDatastore
$destinationDS = Get-Datastore $destinationDatastore
$proceedWithMigration = $False

# Confirm space is available on destination datastore
if ((($sourceDS | Get-View).Summary.Capacity) -le (($destinationDS | Get-View).Summary.Capacity)) {
    if (((($sourceDS | Get-View).Summary.Capacity) - (($sourceDS | Get-View).Summary.FreeSpace)) -le (($destinationDS | Get-View).Summary.FreeSpace)) {
        $proceedWithMigration = $True
    }
}

if ($proceedWithMigration -eq $True) {
    Write-Host "Begin Migration..."
    Migrate-VMConfig -SourceDatastore $sourceDS -DestDatastore $destinationDS
}

# Disconnect from the vCenter server session
Disconnect-VIServer $Vcenter -Force -Confirm:$False
Write-Host "Disconnected from..." $Vcenter
