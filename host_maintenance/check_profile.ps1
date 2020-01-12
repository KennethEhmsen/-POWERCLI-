param(
    [parameter(ValueFromPipeline=$true, Mandatory=$true)]
    $vmhosts
)

$vmhosts | Test-VMHostProfileCompliance | select VMHost, VMHostProfile, IncomplianceElementList | fl
