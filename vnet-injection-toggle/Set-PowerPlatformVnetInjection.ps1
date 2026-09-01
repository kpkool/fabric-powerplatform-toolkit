[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Status', 'Enable', 'Disable')]
    [string]$Action = 'Status',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentId,

    [string]$TenantId,

    [string]$PolicyArmId,

    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 1800,

    [switch]$ForceAuth,

    [switch]$NoWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($InputObject -and $InputObject.PSObject.Properties[$Name]) {
        return $InputObject.PSObject.Properties[$Name].Value
    }
    return $null
}

function Get-InjectionStatus {
    $parameters = @{
        EnvironmentId = $EnvironmentId
        ErrorAction    = 'Stop'
    }
    if ($TenantId) { $parameters.TenantId = $TenantId }
    if ($ForceAuth) { $parameters.ForceAuth = $true }

    try {
        $region = @(Get-EnvironmentRegion @parameters | Where-Object { $_ -is [string] }) |
            Select-Object -Last 1
        $policy = @(
            Get-SubnetInjectionEnterprisePolicy @parameters |
                Where-Object {
                    $null -ne $_ -and
                    $_ -isnot [string] -and
                    $_.PSObject.Properties['Kind']
                }
        ) | Select-Object -Last 1
    }
    catch {
        throw "Unable to determine subnet-injection status for environment '$EnvironmentId'. $($_.Exception.Message)"
    }

    $properties = Get-PropertyValue -InputObject $policy -Name 'Properties'
    [pscustomobject]@{
        ObservedUtc       = (Get-Date).ToUniversalTime().ToString('o')
        EnvironmentId     = $EnvironmentId
        EnvironmentRegion = $region
        InjectionLinked   = [bool]$policy
        PolicyName        = Get-PropertyValue -InputObject $policy -Name 'ResourceName'
        PolicyArmId       = Get-PropertyValue -InputObject $policy -Name 'ResourceId'
        PolicyKind        = Get-PropertyValue -InputObject $policy -Name 'Kind'
        PolicyHealth      = Get-PropertyValue -InputObject $properties -Name 'healthStatus'
    }
}

$module = Get-Module -ListAvailable Microsoft.PowerPlatform.EnterprisePolicies |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $module) {
    throw 'Microsoft.PowerPlatform.EnterprisePolicies is not discoverable. Install it with: Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser'
}

# Module 0.19.1 reads these globals before checking whether they exist.
if (-not (Test-Path variable:Global:InPesterExecution)) {
    $Global:InPesterExecution = $false
}
if (-not (Test-Path variable:Global:PrereqsChecked)) {
    $Global:PrereqsChecked = $false
}

Import-Module $module.Path -Force -ErrorAction Stop

switch ($Action) {
    'Status' {
        Get-InjectionStatus
    }
    'Enable' {
        if (-not $PolicyArmId) {
            throw '-PolicyArmId is required when -Action Enable is used.'
        }

        $target = "environment '$EnvironmentId' using policy '$PolicyArmId'"
        if ($PSCmdlet.ShouldProcess($target, 'Enable Power Platform subnet injection')) {
            $parameters = @{
                EnvironmentId  = $EnvironmentId
                PolicyArmId    = $PolicyArmId
                TimeoutSeconds = $TimeoutSeconds
                ErrorAction    = 'Stop'
            }
            if ($TenantId) { $parameters.TenantId = $TenantId }
            if ($ForceAuth) { $parameters.ForceAuth = $true }
            if ($NoWait) { $parameters.NoWait = $true }

            try {
                $result = @(Enable-SubnetInjection @parameters)
                $succeeded = @($result | Where-Object { $_ -is [bool] }) |
                    Select-Object -Last 1
                if ($succeeded -ne $true) {
                    throw "Enable-SubnetInjection did not return True. Returned: $($result -join '; ')"
                }
            }
            catch {
                throw "Failed to enable subnet injection for '$EnvironmentId'. $($_.Exception.Message)"
            }

            [pscustomobject]@{
                ObservedUtc   = (Get-Date).ToUniversalTime().ToString('o')
                Action        = 'Enable'
                EnvironmentId = $EnvironmentId
                PolicyArmId   = $PolicyArmId
                NoWait        = [bool]$NoWait
                Succeeded     = $true
            }
        }
    }
    'Disable' {
        $target = "environment '$EnvironmentId'"
        if ($PSCmdlet.ShouldProcess($target, 'Disable Power Platform subnet injection')) {
            $parameters = @{
                EnvironmentId  = $EnvironmentId
                TimeoutSeconds = $TimeoutSeconds
                ErrorAction    = 'Stop'
            }
            if ($TenantId) { $parameters.TenantId = $TenantId }
            if ($ForceAuth) { $parameters.ForceAuth = $true }
            if ($NoWait) { $parameters.NoWait = $true }

            try {
                $result = @(Disable-SubnetInjection @parameters)
                $succeeded = @($result | Where-Object { $_ -is [bool] }) |
                    Select-Object -Last 1
                if ($succeeded -ne $true) {
                    throw "Disable-SubnetInjection did not return True. Returned: $($result -join '; ')"
                }
            }
            catch {
                throw "Failed to disable subnet injection for '$EnvironmentId'. $($_.Exception.Message)"
            }

            [pscustomobject]@{
                ObservedUtc   = (Get-Date).ToUniversalTime().ToString('o')
                Action        = 'Disable'
                EnvironmentId = $EnvironmentId
                NoWait        = [bool]$NoWait
                Succeeded     = $true
            }
        }
    }
}