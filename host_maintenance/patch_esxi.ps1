##############################################
#
# PowerCLI Script to Patch - Upgrade ESXi Hosts
# 
# Mike Breclaw @ Navisite
#
##############################################

 
 
function Disconnect{
    Disconnect-viserver -Force -Confirm:$false
    Exit
}
 
 
function scan_entity{
    param(
    [parameter (Mandatory = $true)]
    [String] $BaselineName, 
    [Parameter (Mandatory = $true)] $targetCluster
    )
    $targetBaseline = Get-Baseline -Name $BaselineName
    Write-host `n`n "Checking compliance of cluster" $targetCluster "against" $BaselineName "..." `n 
    foreach($vmhost in $Hosts) {
        $compliance = Get-Compliance -Entity $vmhost -Baseline $Baseline -Detailed
        Switch ($compliance.status)
        {
            Unknown {Write-Host "Scanning "$vmhost"..."; Scan-Inventory -Entity $vmhost; Write-Host}
            Compliant {}
		    NonCompliant {}
        }
	Write-Host "Host" $vmhost.name "is "$compliance.status
   }
}
 

function remediate_host{
    param(
    [parameter(Mandatory = $true)] 
    [String]$BaselineName
    )
   
    $targetBaseline = Get-Baseline -Name $BaselineName
   
    $hostList = $Hosts | Sort-Object -Property Name
    $hostCount = 1
    Write-Host `n`n "*******************************************"`n
    ForEach ($vmhost in $hostList) {
        $vmHostName = $vmhost.Name
        Write-Host "[" $hostCount "]" $vmhost.name 
        $hostCount++
    }

    $HostSelected = Read-Host `n "Which host do you want to remediate (1, 2, 3, ...)"
    Write-Host "*******************************************"`n
    $targetHost = $HostList[$HostSelected-1]
   
    #  Enter_host_Maintenance_Mode ($targetHost) << This is NCD's zerto induced host maintenance mode script / function originally written by Swapnill.  <<pass whatever parameters are neccessary for this to run
    if ($targetHost.ConnectionState -ne "Maintenance") {
        $targetHostName = $targetHost.Name
        Write-Host "$targetHostName did not go into maintenance mode.  Fix the issue and try again."
    }
    else{
       Remediate-Inventory -Entity $targetHost -Baseline $targetBaseline -Confirm:$false
       Write-host "Removing host" $targetHost.name "from Maintenance Mode..."
       Set-vmhost $targethost -State Connected > $null
    }
    Disconnect
}


function remediate_cluster{
    param(
    [parameter(Mandatory = $true)] 
    [String]$targetCluster,
    [parameter(Mandatory = $true)]
    [String] $baselineName
    ) 

    foreach ($targetHost in $Hosts){
        #Enter_host_Maintenance_Mode ($targetHost)   # << This is NCD's zerto induced host maintenance mode script / function originally written by Swapnill.  <<pass whatever parameters are neccessary for this to run
        if ($targethost.State -ne "Maintenance"){ 
	       {Write-Host $targethost.name " did not go into maintenance mode.  Fix the issue and try again."}
        }   
        else{
            Remediate-Inventory -Entity $targetHost -Baseline $targetBaseline -Confirm:$false

            # Remove selected host from Maintenance mode
            write-host "Removing host" $targetHost.name "from Maintenance Mode"
            Get-VMHost -Name $targetHost | set-vmhost -ConnectionState Connected > $Null
            Start-Sleep -Seconds 30
            $zertoVM = Get-vm -Name "ZVRA-*" 
            if ($zertoVM.PowerState = 'PoweredOff'){
                Start-VM -VM $zertoVM
            }
        }
    }
}


### Start Main here
# Initialize and add snappins:
if ((Get-PSSnapin -Name "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue) -eq $Null){
    Add-PsSnapin "VMware.*"
}

# Select which vCenter you want to connect to

Write-host "Select which vCenter to connect to:" `n
Write-Host "[ 1 ] an01-1-vc1"
Write-Host "[ 2 ] an01-m-vc"
Write-Host "[ 3 ] sa01-1-vc1"
Write-Host "[ 4 ] sa01-m-vc"
Write-Host "[ 5 ] re01-1-vc1"
Write-Host "[ 6 ] re01-m-vc"
Write-Host "[ 7 ] wo01-1-vc1"
Write-Host "[ 8 ] wo01-m-vc"
Write-Host "[ 9 ] anqa-1-vc1"
Write-Host "[ 10 ] anqa-m-vc"

$vCenterList = Read-Host `n "Select a vCenter Server (1, 2, 3, ...)"
 
Switch ($vCenterList) {

    1   {$vcenter = "an01-1-vc1.vcloud-int.net"; break}
    2   {$vcenter = "an01-m-vc.vcloud-int.net"; break}
    3   {$vcenter = "sa01-1-vc1.vcloud-int.net"; break}
    4   {$vcenter = "sa01-m-vc.vcloud-int.net"; break}
    5   {$vcenter = "re01-1-vc1.vcloud-int.net"; break}
    6   {$vcenter = "re01-m-vc.vcloud-int.net"; break}
    7   {$vcenter = "wo01-1-vc1.vcloud-int.net"; break}
    8   {$vcenter = "wo01-m-vc.vcloud-int.net"; break}
    9   {$vcenter = "anqa-1-vc1.vcloudqa-int.net"; break}
    10   {$vcenter = "anqa-m-vc.vcloudqa-int.net"; break}

}

# Connect to selected vCenter

Write-Host "Connecting to " $vCenter "..."
connect-viserver $vCenter


# Get the clusters in the vcenter

$ClusterList = Get-Cluster | Sort-Object -Property Name
$ClusterCount = 1
Write-Host `n`n "*******************************************"`n
ForEach ($Cluster in $ClusterList) {
    $ClusterName = $Cluster.Name
    Write-Host "[" $ClusterCount "]" $Cluster.name 
    $ClusterCount++
}
$ClusterSelected = Read-Host `n "In which cluster do you want to do patching (1, 2, 3, ...)"
Write-Host "*******************************************"`n
$targetCluster = $ClusterList[$ClusterSelected-1]


# Get the hosts in the cluster

$Hosts = Get-VMHost -Location $targetCluster

# Get all the available previously built baselines

Write-Host "Collecting baselines..."
$BaselineList = Get-baseline 
$BaselineCount = 1
foreach ($baseline in $BaselineList){
    Write-Host "[" $BaselineCount "]" $Baseline.name
    $BaselineCount++
}

# Select Baseline and build if neccessary

$BaselineSelected = Read-Host `n "Which baseline do you want to remediate to or '999' if not listed"
   #if($BaselineSelected -eq 999) {Write-Host "You will need to build a baseline in vCenter then run this script again."
      #Disconnect} 
   #else
Write-Host "*******************************************"`n
$Baseline = $baselineList[$BaselineSelected-1]
$BaselineName = $Baseline.Name
Attach-Baseline -Baseline $Baseline -Entity $targetCluster


Scan_entity $BaselineName $targetCluster


# Get action option

Write-Host `n `n `n "Options:"
Write-Host "[1] Remediate the cluster"
Write-Host "[2] Remidiate an individual host in the cluster"
Write-Host "[3] Quit"
$option = Read-Host `n "What do you want to do" 
Switch ($option)
{
    1 {remediate_cluster $targetCluster $BaselineName}
    2 {remediate_host $BaselineName}
    3 {Disconnect}
}
