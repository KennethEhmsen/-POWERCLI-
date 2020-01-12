param(
    [parameter(Mandatory=$true)][String]$vcd,
    [parameter(Mandatory=$true)][String]$NSXManager,
    [parameter(Mandatory=$true)][String]$orgName
    )

Connect-ciserver $vcd
$NSXCredentials = Get-Credential -Message "Enter NSX Credentials"
$NSXUsername = $NSXCredentials.username
$NSXPassword = $NSXCredentials.GetNetworkCredential().password
$TargetVersion = "6.2.4"

Write-Host "Get org :"$orgName
$org = get-org -Name $orgName

$edgeList = @()
$orgNameret = $org.name
$orgIdArray = $org.id -split ':'
$orgId = $orgIdArray[3]
Write-Host $orgId

### Create authorization string and store in $head
$nsxAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($NSXUsername + ":" + $NSXPassword))
$nsxHead = @{"Authorization"="Basic $nsxAuth"}

##Get total number of edges
$nsxRequest = "https://$NSXManager/api/4.0/edges?tenant=$orgId"
Write-Host $nsxRequest
$nsxr = Invoke-WebRequest -Uri $nsxRequest -Headers $nsxHead -ContentType "application/xml" -ErrorAction:Stop
if ($nsxr.StatusCode -eq "200")
{
    Write-Host -BackgroundColor:Black -ForegroundColor:Green Status: Connected to $NSXManager successfully.
}

[xml]$rxml = $nsxr.Content
foreach( $edge in $rxml.edgesummaries.edgesummary )
{
    $n = @{} | select Name, Id, Version
    $n.Name = $edge.name
    $n.Id = $edge.id
    $n.Version = $edge.appliancesSummary.vmVersion
    $edgeList += $n
}

Write-Host 'Print edge list for '$orgName
$NSXEdgeRequest = "https://$NSXManager/api/4.0/edges"
Write-Host 'EdgeList -- '$edgeList
foreach( $edge in $edgeList )
{
    if ($edge.Version -ne $TargetVersion)
    {
        Write-Host $edge
        Write-Host
        $response = Read-Host "NSX Redeploy the following edge: "$edge.name" (y/N)"
        Write-Host $response
        if ($response -eq 'y' -or $response -eq 'yes')
        {
            $RedeployRequest = $NSXEdgeRequest+"/"+$edge.id+"?action=upgrade"
            Write-Host $RedeployRequest
            $r = Invoke-WebRequest -URI $RedeployRequest -Method Post -Headers $nsxHead -ContentType "application/xml" -Body $sxml.OuterXML -ErrorAction:Stop
        }
    }
}

Disconnect-ciserver -confirm:$false -server $vcd
