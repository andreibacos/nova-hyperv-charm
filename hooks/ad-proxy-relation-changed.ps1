# Copyright 2014-2018 Cloudbase Solutions Srl
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging


try {
    Import-Module JujuHooks
    Import-Module JujuUtils
    Import-Module ComputeHooks

    $renameReboot = Rename-JujuUnit
    if ($renameReboot) {
        Invoke-JujuReboot -Now
    }

    $cfg = Get-JujuCharmConfig

    $required = @{
        'ad-domain' = $null
        'ad-username' = $null
        'ad-password' = $null
        'ad-ip' = $null
        'ad-ou' = $null
        'ad-group' = $null
        'ad-service-account' = $null
    }

    $optionalContext = @{
        'ad-netbios-options' = $null
    }

    $ctx = Get-JujuRelationContext -Relation "ad-proxy" -RequiredContext $required -OptionalContext $optionalContext
    if (!$ctx.Count) {
        Write-JujuWarning "AD proxy relation data not received"
        exit 0
    }

    Write-JujuWarning "ctx: $($ctx | out-string)"

    $ad_ip = $ctx['ad-ip']
    $domain = $ctx['ad-domain']
    $service_account = $ctx['ad-service-account']
    $domain_user = $ctx['ad-username']
    $username = "{0}\{1}" -f @($domain, $domain_user)
    $p = Get-UnmarshaledObject $ctx['ad-password'] | ConvertTo-SecureString -asPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($username, $p)
    $domain_group = $ctx['ad-group']
    $domain_ou = $ctx['ad-ou']

    if (!((Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain)) {
        
        if ($ctx['ad-netbios-options']) {
            set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces\tcpip* `
                -Name NetbiosOptions -Value $ctx['ad-netbios-options']
        }

        Set-DnsClientServerAddress -InterfaceAlias * -ServerAddresses $ad_ip

        if($domain_ou) {
            Write-JujuWarning "External AD -> Joining AD OU: $domain_ou"
            $join_ad_result = Add-Computer -DomainName $domain -Credential $credential -OUPath $domain_ou -PassThru
        } else {
            Write-JujuWarning "External AD -> AD OU not provided"
            $join_ad_result = Add-Computer -DomainName $domain -Credential $credential -PassThru
        }
        if ($join_ad_result.HasSucceeded){
            Write-JujuWarning "External AD -> Joined AD domain, rebooting"
            Invoke-JujuReboot -Now
        }
    } else {
        Write-JujuWarning "Computer is already part of a domain"
    }

    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    $computer = [System.Net.Dns]::GetHostName()
    Add-LocalGroupMember -Group Administrators -Member $username -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group Administrators -Member "$domain\$service_account$" -ErrorAction SilentlyContinue
    Grant-Privilege -User $username -Grant SeServiceLogonRight
    Grant-Privilege -User "$domain\$service_account$" -Grant SeServiceLogonRight

    $constraintsList = @("Microsoft Virtual System Migration Service", "cifs")
    $settings = @{
        'joined_ad' = $true
        'computername' = $computer
        'constraints' = Get-MarshaledObject $constraintsList
    }
    
    Set-JujuRelation -Settings $settings
        
    $ctx = Get-JujuRelation 
    Write-JujuWarning "ctx: $($ctx | out-string)"

    if ($ctx["ad_conf_complete_$computer"]) {
        Write-JujuWarning "ad_conf_complete is true. Configuring live migration"
        klist -lh 0 -li 0x3e7 purge
        gpupdate /force
        Enable-LiveMigration
        Set-VMHost -MaximumVirtualMachineMigrations $cfg['max-concurrent-live-migrations'] `
                   -MaximumStorageMigrations $cfg['max-concurrent-live-migrations']


        Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos
        foreach ($s in @("nova-compute", "neutron-hyperv-agent", "neutron-ovs-agent")) { 
            $service = gwmi win32_service -filter "name='$s'"
            if (($service) -and ($service.startname.tolower() -ne "$domain\$service_account$".tolower())) {
                if ($service.state -eq "Running"){
                    $service.stopservice()
                    $service.change($null,$null,$null,$null,$null,$null,"$domain\$service_account$",$null)
                    $service.startservice()
                } else {
                    $service.change($null,$null,$null,$null,$null,$null,"$domain\$service_account$",$null)
                }
            }
        }
    }

    Invoke-ConfigChangedHook
} catch {
    Write-HookTracebackToLog $_
    exit 1
}

