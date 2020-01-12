param(
    [parameter(Mandatory=$true)] $target_cluster,
    [parameter(Mandatory=$true)] $data_center,
    [parameter(Mandatory=$true)] $ci_server,
    [parameter(Mandatory=$true)] $vi_server
    )

add-pssnapin VMware.VimAutomation.Core
add-pssnapin Vmware.VimAutomation.Cloud

$sweeper_table = @{"an01-1-zone01" = "ac708cee-eed4-474d-94f5-928c5238cb6b";
                   "an01-1-zone02" = "c509c282-3cb5-460f-859f-aeaa2c3b7daf";
                   "ch01-1-zone01" = "8505d318-433e-43db-93d3-acdd3a4a91d2";
                   "ch01-1-zone02" = "10458576-9507-4e54-92c0-73ccff30b44e";
                   "wo01-1-zone01" = "026d6e8b-b669-4410-836b-98031621d88d";
                   "wo01-1-zone02" = "bb26e01c-2a1a-4277-94ef-3dd60ca5e6b4";
                   "re01-1-zone01" = "cf4b4b2d-773b-4e3d-905b-13f2ca8ea176";
                   "re01-1-zone02" = "c7745025-7f13-4662-9df8-4d368b504eed";
                    }
$sweeper_gw_table = @{"an01-1-zone01" = "vse-Sweeper (8f81e9f6-3664-4fed-b0f1-a89e4dbd53a2)-0";
                      "an01-1-zone02" = "vse-Sweeper02-vAppNet (41afcaec-fc18-4bca-b8a6-0104d7d04b0c)-0";
                      "ch01-1-zone01" = "vse-Sweeper-vAppNet (28ae3986-1649-485e-87d3-8137875de10c)-0";
                      "ch01-1-zone02" = "vse-Sweeper02-vAppNet2 (55ff834b-febe-4e31-8305-db41a3d24bdb)-0";
                      "wo01-1-zone01" = "vse-Sweeper01-vAppNet1 (c753ab31-4854-40d7-9c95-f6a7fd3fecf3)-0";
                      "wo01-1-zone02" = "vse-Sweeper02-vAppNet (207e7473-7b9d-4ac0-b69f-8cea335cc86a)-0";
                      "re01-1-zone01" = "vse-Sweeper01-vAppNet (6070c999-4915-4fe0-80b5-3c520f428c86)-0";
                      "re01-1-zone02" = "vse-Sweeper02-vAppNet (5c454a66-d6b2-4457-aa08-7a530ea5ae6f)-0";
                      }

$SMTPServer = $data_center + "-smtp1.vcloud-int.net"
$EmailFrom = “dl-nav-cld-alerts@twcable.com”
$EmailTo = “dl-nav-cld-alerts@twcable.com”
$Subject = “$data_center $target_cluster vxlan sweeper alert”
$Body = ""

$error_count = 0

connect-viserver $vi_server
connect-ciserver $ci_server

#1 get all hosts
$hosts_to_sweep = get-vmhost -location $target_cluster -state "Connected"

#2 get THE edge GW VM
$edge_gw_vm = get-vm -name $sweeper_gw_table.($target_cluster)
    
#2.5 get the sweeper vm
$sweeper_cvm = get-civm -id ("urn:vcloud:vm:" + $sweeper_table.($target_cluster))
$sweeper_vm = get-vm $sweeper_cvm.ToVirtualMachine()

#3 vMotion sweeper to the host containing edge gateway
$start_host = get-vmhost $edge_gw_vm.vmhost
move-vm -vm $sweeper_vm -destination $start_host
$hosts_to_sweep = $hosts_to_sweep | ?{$_ -ne $start_host}
$test_address = "192.168.128.1"

#4 test ping the edge gateway
if (Test-Connection -count 10 -Quiet $test_address){
	Write-Host "Ping edge GW on same host $start_host PASS"
}else{
	Write-Host "Ping edge GW on same host $start_host FAILED"
    $body += "Ping edge GW on same host $start_host FAILED `r`n"
	}

#5 vmotion sweeper to all other hosts in cluster and test
foreach ($vmhost in $hosts_to_sweep) {
    $moved_vm = move-vm -vm $sweeper_vm -destination $vmhost
    if($moved_vm.vmhost -eq $vmhost) {
        if(Test-Connection -count 10 -Quiet $test_address){
            Write-Host "Ping edge GW on $vmhost PASS"
        }else{
		    Write-Host "Ping edge GW on $vmhost FAILED"
            $body += "Ping edge GW from $vmhost FAILED `r`n"
            $error_count +=1
		}
	}
}
if($error_count -eq $hosts_to_sweep){
    #5.5 if error on all hosts, move edge gw to different host and re-test
    $moved_vm = move-vm -vm $edge_gw_vm -destination $hosts_to_sweep[0]
    if($moved_vm.vmhost -eq $hosts_to_sweep[0]) {
        $hosts_to_sweep = get-vmhost -location $target_cluster -state "Connected"
        $new_host = get-vmhost $moved_vm.vmhost
        $hosts_to_sweep = $hosts_to_sweep | ?{$_ -ne $new_host}
        $body +="Moved edge gw to $new_host"
        foreach ($vmhost in $hosts_to_sweep) {
            $moved_vm = move-vm -vm $sweeper_vm -destination $vmhost
            if($moved_vm.vmhost -eq $vmhost) {
                if(Test-Connection -count 10 -Quiet $test_address){
                    Write-Host "Ping edge GW on $vmhost PASS"
                    $body += "Ping edge GW on $vmhost PASS `r`n"
                }else{
                    Write-Host "Ping edge GW on $vmhost FAILED"
                    $body += "Ping edge GW from $vmhost FAILED `r`n"
                }
            }
        }
    }
}

#6 email report
if ($body.Length -ne 0) {
    $Message = New-Object Net.Mail.MailMessage($EmailFrom, $EmailTo, $Subject, $Body)
    $SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer)
    $SMTPClient.Send($Message)
}

#7 Write the event
write-eventlog -source "Navicloud" -logname "application" -EntryType "Information" -EventId 888 -message "$target_cluster sweeper executed"
