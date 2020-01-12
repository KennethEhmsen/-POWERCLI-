$HostReport = @()

Get-VMHost | %{
   $HN = $_
   $Report = "" | select Cluster, Hostname, version, Build, manufacture, Model, cpu_Mhz, cpu_model, Logical_cpu_num, core_num, TotalMemoryMB, ip_address, P_nic, HyperthreadingEnabled,Profile, EVCMode
   $Report.Cluster = (Get-Cluster -VMHost $HN).Name
   $Report.Hostname = $_
   $Report.version = $_.Version
   $Report.Build = $_.Build
   $Report.manufacture = $_.ExtensionData.Hardware.SystemInfo.Vendor
   $Report.Model = $_.Model
   $Report.cpu_Mhz = $_.ExtensionData.Summary.Hardware.CpuMhz
   $Report.cpu_model = $_.ExtensionData.Summary.Hardware.CpuModel
   $Report.Logical_cpu_num = $_.ExtensionData.Summary.Hardware.NumCpuThreads
   $Report.core_num = $_.ExtensionData.Hardware.CpuInfo.NumCpuCores
   $Report.TotalMemoryMB = $_.MemoryTotalMB
   $Report.ip_address = ($_.NetworkInfo.VirtualNic | where {$_.name -eq "vmk0"}).ip
   $Report.P_nic = $_.ExtensionData.Config.Network.Pnic.count
   $Report.HyperthreadingEnabled = $_.ExtensionData.Config.HyperThread.Active
   $Report.Profile = (Get-VMHostProfile).Name
   $Report.EVCMode = (Get-Cluster -VMHost $HN).ExtensionData.Summary.CurrentEVCModeKey
   $HostReport += $Report
}
$HostReport