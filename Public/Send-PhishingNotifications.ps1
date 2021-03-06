#requires -Modules Posh-VirusTotal
#requires -Version 4
function Send-PhishingNotifications ()
{
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true,
        HelpMessage = 'Please provide a .MSG file.')]
        $messagetoparse,

        [parameter(Mandatory = $true,
        HelpMessage = 'Please provide a log path.')]
        $logpath,

        [parameter(Mandatory = $true,
        HelpMessage = "Please provide a 'Send On Behalf of' email address")]
        $From,

        [parameter(ParameterSetName = 'VT',
        HelpMessage = 'Please include the VirusTotal switch to scan files against VT API.')]
        [switch]$VirusTotal,

        [parameter(ParameterSetName = 'VT',
        HelpMessage = 'Please provide your Virus Total API Key')]
        $VTAPIKey
    ) 

    <#
            .SYNOPSIS 
            Takes a .msg file, find a phishing link, does reverse DNS for the IP, and queries whois Databases for abuse contact information

            .DESCRIPTION
            Takes a .MSG file and searches for a link based on a regex pattern
            Takes that link, parses it to find the root DNS name
            Takes the DNS name and finds the IP by doing a reverse DNS lookup
            Takes the IP of the server and parses it for the first octet
            Takes the first octet and finds which whois should be used
            Once it has the whois, it queries their API or scraps their website for their abuse contact information
            Once it has the abuse contact info, it sends them an email from abuse email account with the original attachment - asking them to remove the website
            Sends an email to spam@access.ironport.com
            Sends an email to the Google Anti-Phishing Group anti-phishing-email-reply-discuss@googlegroups.com
            Logs this in the running log file

            .PARAMETER messagetoparse
            Specifices the specific .MSG that someone wants to parse 

            .PARAMETER logpath
            Sets the path to our log file

            .PARAMETER From
            This parameter is used to define who is sending these notificaitons.
            Currently, you must put an email address that you want to "Send on Behalf of".

            .EXAMPLE
            C:\PS> Send-PhishingNotification -meesagetoparse 'C:\Users\UserName\Desktop\PHISING_EMAILS\Dear Email User.msg' -logpath C:\users\username\desktop -From 'abuse@emailaddress.com'
    
    #>

    $ipaddress = @()
    $regexipv6 = '(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))'
    $regexipv4 = '\b((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3} (25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'
    $shorturl = ''
    #Take in .msg file and strip the phishing url

    if ($VirusTotal)
    {
        $AttachmentHash = Expand-MsgAttachment -Path $messagetoparse | Get-FileHash

        foreach ($hash in $AttachmentHash.Hash)
        {
            $VTFileReport = Get-VTFileReport -Resource $hash -APIKey $VTAPIKey

            if ($VTFileReport.ResponseCode -eq 1)
            {
                $result = [System.Windows.Forms.MessageBox]::Show("The following SHA256 hash was already been submitted to VirusTotal.`n $hash", 'Warning', 'Ok', 'Warning')
                Write-LogEntry -type Info -message 'VirusTotal Submission' -Folder $logpath -CustomMessage "Hash has been previously submitted to VirusTotal: $hash"
            }
            if ($VTFileReport.ResponseCode -eq 0)
            {
                $result = [System.Windows.Forms.MessageBox]::Show("The following SHA256 hash has NOT been submitted to VirusTotal. Do you want to upload this file to VirusTotal Now?`n $hash", 'Warning', 'YesNo', 'Warning')

                if ($result -eq $true)
                {
                    $SubmitToVT = Submit-VTFile -File $AttachmentHash.Path -APIKey $VTAPIKey
                }
            }
        }
    }

    $url = Get-URLFromMessage $messagetoparse

    #if the url string has a 'shorturl' from the "shorturls.xml" file, then process seperately
    #shorturls is a static list created from longurl.org\services
    Import-Clixml -Path "$(Split-Path -Path $Script:MyInvocation.MyCommand.Path)\Private\shorturls.xml" | ForEach-Object -Process {
        if ($url -like '$_')
        {
            #call Get-LongUrl to call API to resolve to the normal/long url
            $longurl = Get-LongUrl $url
            Write-Debug -Message "longurl:  $longurl"
            [array]$ipaddress = ([System.Uri]$longurl).Authority
            $url = $longurl
            $shorturl = $true
        }
        else
        {
            $shorturl = $false
        }
    }
     
    if ($shorturl -eq $false)
    {
        #if no 'tinyurl' then parse as normal
        $parsedurl = Get-ParsedURL $url
        [array]$ipaddress = Get-IPaddress $parsedurl
    }

    #for each ipaddress returned from above else statement
    for ($ip = 0;$ip -lt $ipaddress.count;$ip++)
    {
        #based on the ipaddress we are going to get which WHOIS/RDAP to use
        $whoisdb = Get-WhichWHOIS $ipaddress[$ip]
        Write-Debug -Message "$whoisdb"
        Write-Debug -Message "IPADDRESS:  $ipaddress[$ip]"
    
        #based on info from Get-WhichWHOIS we will then begin those specific API calls
        switch ($whoisdb){
            'arin' 
            {
                [array]$abusecontact = Check-ARIN $ipaddress[$ip]
            }
            'ripe' 
            {
                [array]$abusecontact = Check-RIPE $ipaddress[$ip]
            }
            'apnic' 
            {
                $abusecontact = Check-APNIC $ipaddress[$ip]
            }
            'lacnic' 
            {
                [array]$abusecontact = Check-LACNIC $ipaddress[$ip]
            }
            'afrnic' 
            {
                $abusecontact = 'NOCONTACT'
                Write-Host -Object 'CANNOT PARSE AFRNIC'
            }
            $null 
            {
                Write-Host -Object 'UNKNOWN WHOIS'
            }
        }
    }
    #as long as the abusecontact does not equal 'NOCONTACT', send email to that abuse contact
    for ($a = 0;$a -lt $abusecontact.count;$a++)
    {
        if ($abusecontact[$a] -ne 'NOCONTACT') 
        {
            Send-ToAbuseContact -originallink $url -abusecontact $abusecontact[$a] -messagetoattach $messagetoparse -From $From
        }
    }
    #additionally, send to IronPort and Anti-Phishing Working Group email distribution list
    Send-ToIronPort -originallink $url -messagetoattach $messagetoparse -From $From
	
    Send-ToAntiPhishingGroup -trimmedlink $url.Trim('http://') -From $From

    $logpath = "$($logpath)\get_whois.log"
    $logvalue = "$(Get-Date);$url;$parsedurl;$([array]$ipaddress[0]);$whoisdb;$abusecontact;$messagetoparse;"
    Add-Content -Path $logpath -Value $logvalue

    #stop outlook process if still open from send emails using Outlook.Application COM Object
    Start-Sleep -Seconds 3
    Get-Process -Name Outlook | Stop-Process
}
