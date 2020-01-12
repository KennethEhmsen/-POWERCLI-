<#
.MYNGC_REPORT
.LABEL
display customer name with vms on host
.DESCRIPTION
Connect to VCD and correlate vm with customer org
#>

param
(
   [Parameter(Mandatory=$true)][VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$vParam
)

# This is here to get the clear text
# password out of memory to pass to
# the basic auth header in web api requests
function Decrypt-SecureString {
    param(
        [Parameter(ValueFromPipeline=$true,Mandatory=$true,Position=0)]
        [System.Security.SecureString]
        $sstr
    )

    $marshal = [System.Runtime.InteropServices.Marshal]
    $ptr = $marshal::SecureStringToBSTR( $sstr )
    $str = $marshal::PtrToStringBSTR( $ptr )
    $marshal::ZeroFreeBSTR( $ptr )
    $str
}

# Connect to the NSX api and retrieve all of the edge
# gateways and return the xml object
function get_all_edges {
    param(
	[parameter(Mandatory=$true)] $user,
    [parameter(Mandatory=$true)] $pass,
    [parameter(Mandatory=$true)] $vsm
    )

    $auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($user + ":" + $pass))
    $head = @{"Authorization"="Basic $auth"}
    $uri = "https://$vsm/api/3.0/edges?pageSize=1024"
    $response = Invoke-WebRequest -Uri $uri -Headers $head -ContentType "application/xml" -ErrorAction:Stop -UseBasicParsing
    [xml]$rxml = $response.Content
    return $rxml
}

# Pass in the VM name, XML object list of edge GW's
# and the connection object to VCD and return the
# organization object that the vm belongs to
function get_vse_org {
    param(
	    [parameter(Mandatory=$true)] $vm,
        [parameter(Mandatory=$true)] $edges,
        [parameter(Mandatory=$true)] $cc
        )
    foreach ($edge in $edges.pagedEdgeList.edgePage.edgeSummary) {
        if (($edge.name -eq $vm.trimend("-0")) -or ($edge.name -eq $vm.trimend("-1")) ) {
            $org_id = $edge.tenantId
        }
        if($org_id){
            $c_org = get-org -server $cc -id ("urn:vcloud:org:" + $org_id)
        }
        if($c_org){
            return $c_org
        }
    }
}

# Main
# Takes a VMHost object as parameter
# Retrieves the vm objects running on the vmhost
# Connects to VCD and matches the vm object to the civm object
# Determines the organization based on the civm object
#
# If VM's with "vse-" prefix are running on the host
# - use the VCD creds to connect to NSX
# - retrieve ALL of the edge gw's from NSX
# - match the VM name to the edge GW from NSX
# - get the org id from the edge GW list
# - get the org name by id

$result = @()
$cred = $Host.UI.promptforcredential("vcd creds","Enter user pass for vcd","", "")
#substring for current datacenter
$vcd = ($global:defaultviserver.name[0..6] -join "") + "vcd.vcloud-int.net"
$ci = connect-ciserver -server $vcd -credential $cred -org System
# Filter out all the GI/Zerto/Trend/NSX Protector as these are Navi VM's
$vms = get-vm -location $vParam | where {$_.powerstate -eq "PoweredOn"} | where {($_.name -notlike "Guest Introspection*") -and ($_.name -notlike "Trend Micro*") -and ($_.name -notlike "Z-VRA*") -and ($_.name -notlike "nsx_protector*")}
$xml_list = $null
# Determine if there are edge GW's in the vm list
foreach ($vm in $vms){
    if($vm.name.startsWith("vse-")){
        # get all of the edges for filtering
        $xml_list = get_all_edges $cred.username (Decrypt-SecureString $cred.password) (($global:defaultviserver.name[0..6] -join "") + "vc1vsm.vcloud-int.net")
        break
    }
}

# Try to link the name to an org (customer) in VCD
foreach ($vm in $vms){
    $row = "" | Select VM, Customer, ResourcePool, PowerState
    $row.PowerState = $vm.PowerState
    if($vm.ResourcePool){
        $row.ResourcePool = $vm.ResourcePool.name
    }
    $org = $null
    $cid = ($vm.name).substring($vm.name.LastIndexOf("(")+1).trimend(")")
    if($cid){
        $cvm = get-civm -server $ci -id ("urn:vcloud:vm:" + ($vm.name).substring($vm.name.LastIndexOf("(")+1).trimend(")")) -erroraction ignore

        if($cvm){
            $org = get-org -server $ci $cvm.org
        }
    }
    if($org){
		$row.VM = $vm.name
		$row.Customer = $org.fullname
		$result += $row
    }else{
        $row.VM = $vm.name
        if ($vm.name.startsWith("vse-")){
            $org = get_vse_org $vm.name $xml_list $ci
            if($org){
                $row.Customer = $org.fullname
            }
            else{
                $row.Customer = "Unknown"
            }
        }
        else {
            $row.Customer = "Unknown"
        }
        $result += $row
    }
}
disconnect-ciserver -server $ci -confirm:$false
$result | select VM, Customer, ResourcePool, PowerState
