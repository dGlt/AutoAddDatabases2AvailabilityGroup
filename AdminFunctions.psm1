function fnGetFileModTime([string]$sFileName) {
  $vFileInfo = get-childitem $sFileName
  return $vFileInfo.lastwritetime 
}

function fnGetFQDN() {
  param (
	  [switch]$swIsEmail = $false
  )
  $oNETIP = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
  if ($swIsEmail -eq $true) {
    [string]$Return1 = "noreply@" + $oNETIP.HostName + "." + $oNETIP.DomainName
  } else {
    [string]$Return1 = $oNETIP.HostName + "." + $oNETIP.DomainName
  }  
  return $Return1
}

# Do not forget to register the eventlogsources in windows before you use this function...
function fnWriteEventLog() {
  param (
    [string]$sNode, 
    [string]$sMessage, 
    [string]$sEventLogSource = "DBA",  
    [int]$iEventID = 1001, 
    [string]$sType = "Error"
  )
  if ( ($sNode) -and ($sMessage) ) {
    [string]$sFormatMessage = "Node: " + $sNode + "`r`n`r`n" + $sMessage
    Write-EventLog -LogName Application -Source $sEventLogSource -EntryType $sType -EventID $iEventID -Message $sFormatMessage
  } else {
    return "ERROR: fnWriteEventLog missing arguments..."
  }
}
  
function fnSendMail()
{
  param (
    [string]$sSMTPSrvrName, 
    [string]$sFrom, 
    [string]$sTo, 
    [string]$sSubject, 
    [string]$sBody, 
    [string]$sAttFileName, 
    [switch]$swIsBodyHTML = $false
  )

  if (($sSMTPSrvrName) -and ($sFrom) -and ($sTo) -and $sSubject) {
  
    # Declare mail objects...
    $oMessage = new-object Net.Mail.MailMessage
    $oSMTP = new-object Net.Mail.SmtpClient($sSMTPSrvrName)

    # Pass values to object...
    $oMessage.From = $sFrom
    $oMessage.To.Add($sTo)
    $oMessage.Subject = $sSubject
    $oMessage.IsBodyHtml = $swIsBodyHTML
    $oMessage.BodyEncoding = ([System.Text.Encoding]::UTF8)
    if ($sBody) { $oMessage.Body = $sBody }

    # Add attachment...
    if ($sAttFileName) {
      $oAttachment = new-object Net.Mail.Attachment($sAttFileName)
      $oMessage.Attachments.Add($oAttachment)
    }

    $oSMTP.Send($oMessage)
    if ($? -eq "True") {
      #fnWriteEventLog -sNode (fnGetFQDN) -sMessage "Email has been sent..." -iEventID 1 -sType "Information"
      return "INFO: Email has been sent..." 
    } else {
      fnWriteEventLog -sNode (fnGetFQDN) -sMessage "Error sending mail..." -iEventID 501
      return "ERROR: Error sending e-mail..."
    }

  } else {
    fnWriteEventLog -sNode (fnGetFQDN) -sMessage "fSendMail argument missing..." -iEventID 501
    return "ERROR: Argument(s) missing. [fnSendMail `"SMTPServerName`" `"From`" `"To`" `"Subject`" `"Body`" (`"AttachFileName`" `"isBodyHTML`")]"
  }
}

function fnSQLCmd([string]$sInstance, [string]$sQuery, [string]$sDatabase) {
  # Register SQPPS Module...
  $oSQLPSModule = Get-Module | Where {$_.name -eq "SQLPS" }
  if ($oSQLPSModule.Count -eq 0) {
    Import-Module "SQLPS" -WarningAction SilentlyContinue
  }

  if ($sDatabase) {
    [string]$sQuery = "Invoke-SqlCmd -ServerInstance " + $sInstance + " -Database " + $sDatabase + " -QueryTimeout 30 -Query `"" + $sQuery + "`" ; if (`$? -eq `$false) { @{`"ERROR0`" = `$error[0]}; @{`"ERROR1`" = `$error[1]} }" 
  } else {
    [string]$sQuery = "Invoke-SqlCmd -ServerInstance " + $sInstance + " -QueryTimeout 30 -Query `"" + $sQuery + "`" ; if (`$? -eq `$false) { @{`"ERROR0`" = `$error[0]}; @{`"ERROR1`" = `$error[1]} }" 
  }
  return Invoke-Expression $sQuery
}

function fnTCPSock([string]$sHostName, [string]$sPort, [string]$sScript) {
  # Convert script string to byte for write stream...
  [byte[]]$byteScript = [System.Text.Encoding]::ASCII.GetBytes($($sScript))
  # Open 4096 Bytes buffer for read stream...
  [byte[]]$byteBuffer = New-Object System.Byte[] 16384
  
  # Connect to host...
  $oTCPSock = New-Object System.Net.Sockets.TcpClient($sHostName, $sPort)
  $oStream = $oTCPSock.GetStream() 
  
  # Feed script(byte) tot write stream...
  $oStream.Write($byteScript, 0, $byteScript.Length)

  # Return read buffer converted to string...
  [string]$sCount = $oStream.Read($byteBuffer, 0, 16384)
  return [System.Text.Encoding]::ASCII.GetString($byteBuffer, 0, $sCount) 

  # Close objects...
  $oResult.Close()
  $oSockTCP.Close()
}
