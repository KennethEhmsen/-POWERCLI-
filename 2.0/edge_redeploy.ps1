
param(
    [parameter(Mandatory=$true)][String]$NSXManager,
    [parameter(Mandatory=$false)][String[]]$omitEdges = @()
    )

Write-Host $omitEdges
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

$NSXCredentials = Get-Credential -Message "Enter NSX Credentials"
$Username = $NSXCredentials.username
$Password = $NSXCredentials.GetNetworkCredential().password

#$Username = "admin"
#$Password = "default"
#$NSXManager = "nsx01.gcp.local"
$TargetVersion = "6.2.4"

Write-Host $Username
Write-Host $Password
### Create authorization string and store in $head
$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Username + ":" + $Password))
$head = @{"Authorization"="Basic $auth"}

##Get total number of edges
$Request = "https://$NSXManager/api/4.0/edges"
$r = Invoke-WebRequest -Uri ($Request+"?startIndex=0&pageSize=1") -Headers $head -ContentType "application/xml" -ErrorAction:Stop
if ($r.StatusCode -eq "200")
{
    Write-Host -BackgroundColor:Black -ForegroundColor:Green Status: Connected to $NSXManager successfully.
}
$TotalNumberOfEdges = ([xml]$r.content).pagedEdgeList.edgePage.pagingInfo.totalCount
Write-Host $TotalNumberOfEdges

##Get all edges
$r = Invoke-WebRequest -Uri ($Request+"?startIndex=0&pageSize="+$TotalNumberOfEdges) -Headers $head -ContentType "application/xml" -ErrorAction:Stop
[xml]$rxml = $r.Content
$Edges = @()
foreach ($EdgeSummary in $rxml.pagedEdgeList.edgePage.edgeSummary)
{
 $n = @{} | select Name, Id, Version
 $n.Name = $edgeSummary.Name
 $n.Id = $edgeSummary.objectId
 $n.Version = $edgeSummary.appliancesSummary.vmVersion
 $Edges += $n
}
Write-Host $Edges
##Upgrade all edges
foreach ($Edge in $Edges)
{
    ## only edges not in the list
    if ( -Not ($omitEdges -contains $Edge.id) )
    {
        if ($Edge.Version -ne $TargetVersion)
        {
            ## Upgrade edge
            Write-Host "Upgrading Edge" $Edge.Name
            Write-Host "Upgrading Edge-Id" $Edge.Id
            $Uri = "https://$NSXManager/api/4.0/edges"+"/"+$Edge.Id+"?action=upgrade"
	    Write-Host "Start time.... $(Get-Date)"
            $r = Invoke-WebRequest -URI $Uri -Method Post -Headers $head -ContentType "application/xml" -Body $sxml.OuterXML -ErrorAction:Stop
	    Write-Host "End time.... $(Get-Date)"
        }
    }
}

