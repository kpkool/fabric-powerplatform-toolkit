#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checks = @(
    [pscustomobject]@{
        Name = 'PowerShell'
        Available = $PSVersionTable.PSVersion -ge [version]'5.1'
        Purpose = 'Run local preparation and Power Platform diagnostics'
    }
    foreach ($commandName in @('az', 'bicep', 'checkov')) {
        [pscustomobject]@{
            Name = $commandName
            Available = $null -ne (Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            Purpose = switch ($commandName) {
                'az' { 'Later Azure CLI inventory and approved deployments' }
                'bicep' { 'Standalone local IaC compilation; Azure CLI Bicep is an alternative not checked here' }
                'checkov' { 'Local IaC security scanning before deployment review' }
            }
        }
    }
    foreach ($moduleName in @('Az.Accounts', 'Microsoft.PowerPlatform.EnterprisePolicies')) {
        [pscustomobject]@{
            Name = $moduleName
            Available = $null -ne (Get-Module -ListAvailable -Name $moduleName | Select-Object -First 1)
            Purpose = 'Later authenticated Power Platform subnet diagnostics'
        }
    }
)

[pscustomobject]@{
    Checks = $checks
    AllListedToolsFound = @($checks | Where-Object { -not $_.Available }).Count -eq 0
    Scope = 'Local command and module discovery only; versions and execution compatibility are not validated'
    CloudReadiness = 'NOT_TESTED'
    ApplicationAcceptance = 'NOT_TESTED'
}