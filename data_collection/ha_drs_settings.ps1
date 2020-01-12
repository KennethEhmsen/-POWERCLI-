param(
    [parameter(Mandatory=$true)]
    $cluster
)

get-cluster $cluster | Select-Object Name, drsmode, @{N="DrsVmotionRate";E={$_.extensiondata.configuration.drsconfig.vmotionrate}}, @{N="HaEnabled";E={$_.extensiondata.configuration.dasconfig.enabled}}, @{N="HaHostMonitoring";E={$_.extensiondata.configuration.dasconfig.hostmonitoring}}

