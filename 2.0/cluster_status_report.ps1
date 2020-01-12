. ./cluster_status.ps1

$errors = generate_report -datacenters (@("an","ch","wo","re"))


write-host "report:"
if ($errors.count -gt 0) {
    foreach ($error in $errors) {
        write-host $error
    }
}