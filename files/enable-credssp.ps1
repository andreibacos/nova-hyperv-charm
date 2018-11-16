Param(
    [string]$Username,
    [string]$Password,
    [string]$DomainName
)

$sec = ConvertTo-SecureString -AsPlainText -Force $Password
$credentials = New-Object System.Management.Automation.PSCredential ("$Username", $sec)

function Start-WaitForCredSSP {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$DomainName,
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.PSCredential]$Credential,
        [int]$RetryInterval=5,
	[int]$RetryCount=10
    )

    $LocalNode = (Get-WmiObject Win32_ComputerSystem).Name
    Invoke-Expression ("setspn -A WSMAN/$LocalNode $LocalNode")
    Invoke-Expression ("setspn -A WSMAN/$LocalNode.$DomainName $LocalNode")
    Invoke-Expression ("klist purge")

    $CredSSPOK = $false
    $retry = 0

    Write-Warning "Starting WaitForCredSSP"

    While (-not ($CredSSPOK)){
        start-sleep $RetryInterval
	$retry++
        Write-Warning "Attempting to authenticate using CredSSP, attempt $retry out of $RetryCount"
        $Session = New-PSSession -authentication CredSSP -Credential $Credential -ErrorAction SilentlyContinue
        If ($Session) {
            $CredSSPOK = Invoke-Command -ErrorAction SilentlyContinue -Session $Session -ScriptBlock{
                return "ok"
            }
            Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
        }
	if ($retry -ge $RetryCount) {
	    Write-Warning "Maximum attempts reached, giving up."
	    return
	}
    }
    Write-Warning "Successfully authenticated using CredSSP"
}

Start-WaitForCredSSP -DomainName $DomainName -Credential $credentials
