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

    foreach ($s in @("nova-compute", "neutron-hyperv-agent", "neutron-ovs-agent")) { 
        $service = gwmi win32_service -filter "name='$s'"
        if (($service) -and ($service.startname.tolower() -ne "localsystem".tolower())) {
            if ($service.state -eq "Running"){
                $service.stopservice()
                $service.change($null,$null,$null,$null,$null,$null,"localsystem",$null)
                $service.startservice()
            } else {
                $service.change($null,$null,$null,$null,$null,$null,"localsystem",$null)
            }
        }
    }

    $ctx = Get-JujuRelation
    
    $domain = $ctx['ad-domain']
    $domain_user = $ctx['ad-username']
    $username = "{0}\{1}" -f @($domain, $domain_user)
    $p = Get-UnmarshaledObject $ctx['ad-password'] | ConvertTo-SecureString -asPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($username, $p)

    Write-JujuWarning "External AD -> Leaving External AD domain: $domain"
    if (Confirm-IsInDomain $domain) {
        try {
            Remove-Computer -UnjoinDomaincredential $credential -PassThru -Verbose -Force
            #Invoke-JujuReboot -Now
        } catch {
            Write-JujuWarning "Could not remove computer from AD, manual intervention may be needed"
            Write-HookTracebackToLog $_
        }
    }

} catch {
    Write-HookTracebackToLog $_
    exit 1
}

