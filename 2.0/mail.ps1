function send_email {
    param([parameter(Mandatory=$true)] $subject,
          [parameter(Mandatory=$true)] $body)
    $SMTPServer = “172.22.2.11”
    $EmailFrom = “dl-nav-cld-alerts@twcable.com”
    $EmailTo = “dl-nav-cld-alerts@twcable.com”
    $EmailSubject = $subject
    $EmailBody = $body
    $Message = New-Object Net.Mail.MailMessage($EmailFrom, $EmailTo, $EmailSubject, $EmailBody)
    $SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer)
    $SMTPClient.Send($Message)
}