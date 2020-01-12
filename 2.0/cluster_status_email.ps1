# run this command before configuring server to run the report
#eventcreate.exe /l Application /so NaviCloud /id 777 /d "Cluster Status report executed" /t Information
add-PSSnapin VMware.VimAutomation.Cloud
. ./cluster_status.ps1
. ./mail.ps1

$errors = generate_report -datacenters (@("an","ch","wo","re","sa"))

if ($errors.count -gt 0) {
    $Subject = “NaviCloud Director Health Status”
    $Body = “cluster problem report `r`n`r`n"
    foreach ($error in $errors){
        $body += ($error + "`r`n")
    }
    send_email -subject $Subject -body $Body
}

Write-EventLog -Source "NaviCloud" -logname "Application" -EntryType "Information" -EventId 777 -Message "Cluster Status report executed"
