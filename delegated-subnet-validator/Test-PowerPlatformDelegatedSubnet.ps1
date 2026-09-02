[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$Destination,

    [Parameter(Mandatory)]
    [string[]]$Regions,

    [string]$TenantId,

    [ValidateRange(1, 65535)]
    [int]$Port = 1433,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'evidence'),

    [switch]$ForceAuth
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:diagnosticErrors = [System.Collections.Generic.List[object]]::new()

function Test-IsAccessTokenArrayBindingError {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = $ErrorRecord.Exception.Message
    return (
        $message -match "parameter 'AccessToken'" -and
        $message -match 'System\.Object\[\]' -and
        $message -match 'System\.Security\.SecureString'
    )
}

function Invoke-PowerPlatformCommand {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    try {
        return @(& $Action)
    }
    catch {
        if (-not (Test-IsAccessTokenArrayBindingError -ErrorRecord $_)) {
            throw
        }

        Write-Warning 'Power Platform authentication completed but returned an invalid token wrapper. Retrying this read-only command once.'
        return @(& $Action)
    }
}

function Invoke-EvidenceStep {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    Write-Host "`n=== $Name ==="
    try {
        $result = @(Invoke-PowerPlatformCommand -Action $Action)
        $result | Format-List * | Out-Host
        [pscustomobject]@{
            Succeeded = $true
            Result    = $result
            Error     = $null
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $correlationIds = @(
            [regex]::Matches(
                $errorMessage,
                '(?i)(?:Correlation ID|CorrelationId|serviceRequestId)[^0-9a-f]*([0-9a-f-]{36})'
            ) |
                ForEach-Object { $_.Groups[1].Value } |
                Select-Object -Unique
        )
        $script:diagnosticErrors.Add([pscustomobject]@{
            ObservedUtc    = (Get-Date).ToUniversalTime().ToString('o')
            Step           = $Name
            Error          = $errorMessage
            CorrelationIds = $correlationIds
        })
        Write-Host "FAILED [$Name]: $errorMessage" -ForegroundColor Red
        if ($correlationIds.Count -gt 0) {
            Write-Host "Correlation IDs: $($correlationIds -join ', ')" -ForegroundColor Yellow
        }
        [pscustomobject]@{
            Succeeded = $false
            Result    = @()
            Error     = $errorMessage
        }
    }
}

function Get-ResultObject {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Step,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    @($Step.Result | Where-Object {
        $null -ne $_ -and
        $_ -isnot [string] -and
        $_.PSObject.Properties.Name -contains $PropertyName
    }) | Select-Object -Last 1
}

function Test-IpInCidr {
    param(
        [string]$IpAddress,
        [string]$Cidr
    )

    if (-not $IpAddress -or -not $Cidr -or $Cidr -notmatch '/') {
        return $false
    }

    try {
        $cidrParts = $Cidr.Split('/')
        $addressBytes = [Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
        $networkBytes = [Net.IPAddress]::Parse($cidrParts[0]).GetAddressBytes()
        $prefixLength = [int]$cidrParts[1]
    }
    catch {
        return $false
    }

    if (
        $addressBytes.Length -ne $networkBytes.Length -or
        $prefixLength -lt 0 -or
        $prefixLength -gt ($addressBytes.Length * 8)
    ) {
        return $false
    }

    for ($bitIndex = 0; $bitIndex -lt $prefixLength; $bitIndex++) {
        $byteIndex = [Math]::Floor($bitIndex / 8)
        $bitMask = 1 -shl (7 - ($bitIndex % 8))
        if (($addressBytes[$byteIndex] -band $bitMask) -ne ($networkBytes[$byteIndex] -band $bitMask)) {
            return $false
        }
    }

    return $true
}

if (-not (Get-Module -ListAvailable -Name Microsoft.PowerPlatform.EnterprisePolicies)) {
    throw 'Microsoft.PowerPlatform.EnterprisePolicies is not discoverable in PSModulePath. Verify Get-Module -ListAvailable first; if absent, run Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser.'
}

# Module v0.19.1 reads these globals without first checking whether they exist.
if (-not (Test-Path variable:Global:InPesterExecution)) {
    $Global:InPesterExecution = $false
}
if (-not (Test-Path variable:Global:PrereqsChecked)) {
    $Global:PrereqsChecked = $false
}

Import-Module Microsoft.PowerPlatform.EnterprisePolicies
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$transcriptPath = Join-Path $OutputDirectory "power-platform-vnet-$timestamp.log"
$summaryPath = Join-Path $OutputDirectory "power-platform-vnet-$timestamp.json"
$commonParameters = @{}
if ($TenantId) {
    $commonParameters.TenantId = $TenantId
}

$transcriptStarted = $false
try {
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    $transcriptStarted = $true

    Write-Host 'Power Platform delegated-subnet validation'
    Write-Host "ObservedUtc: $((Get-Date).ToUniversalTime().ToString('o'))"
    Write-Host "EnvironmentId: $EnvironmentId"
    Write-Host "Destination: $Destination`:$Port"
    Write-Host "Regions: $($Regions -join ', ')"

    $permissionParameters = @{} + $commonParameters
    if ($ForceAuth) {
        $permissionParameters.ForceAuth = $true
    }

    $permissionStep = Invoke-EvidenceStep -Name 'Diagnostic permissions' -Action {
        Test-AccountPermissions @permissionParameters
    }
    $environmentRegionStep = Invoke-EvidenceStep -Name 'Environment region' -Action {
        Get-EnvironmentRegion -EnvironmentId $EnvironmentId @commonParameters
    }
    $policyStep = Invoke-EvidenceStep -Name 'Linked subnet-injection enterprise policy' -Action {
        Get-SubnetInjectionEnterprisePolicy -EnvironmentId $EnvironmentId @commonParameters
    }

    $permissionValue = @($permissionStep.Result | Where-Object { $_ -is [bool] }) | Select-Object -Last 1
    $policyObject = @($policyStep.Result | Where-Object { $_ -isnot [string] }) | Select-Object -Last 1
    $regionSummaries = @()

    foreach ($region in $Regions) {
        Write-Host "`n######## REGION: $region ########"
        $usageStep = Invoke-EvidenceStep -Name "Environment usage ($region)" -Action {
            Get-EnvironmentUsage -EnvironmentId $EnvironmentId -Region $region @commonParameters
        }

        $dnsStep = Invoke-EvidenceStep -Name "DNS resolution ($region)" -Action {
            Test-DnsResolution -EnvironmentId $EnvironmentId -HostName $Destination -Region $region @commonParameters
        }
        $tcpStep = Invoke-EvidenceStep -Name "TCP connectivity ($region)" -Action {
            Test-NetworkConnectivity -EnvironmentId $EnvironmentId -Destination $Destination -Port $Port -Region $region @commonParameters
        }

        if (-not $usageStep.Succeeded) {
            $usageStep = Invoke-EvidenceStep -Name "Environment usage retry after TCP diagnostic provisioning ($region)" -Action {
                Get-EnvironmentUsage -EnvironmentId $EnvironmentId -Region $region @commonParameters
            }
        }

        if (-not $dnsStep.Succeeded) {
            $dnsStep = Invoke-EvidenceStep -Name "DNS resolution retry after TCP diagnostic provisioning ($region)" -Action {
                Test-DnsResolution -EnvironmentId $EnvironmentId -HostName $Destination -Region $region @commonParameters
            }
        }

        $tlsStep = Invoke-EvidenceStep -Name "TLS handshake ($region)" -Action {
            Test-TLSHandshake -EnvironmentId $EnvironmentId -Destination $Destination -Port $Port -Region $region @commonParameters
        }

        if (-not $tlsStep.Succeeded) {
            $tlsStep = Invoke-EvidenceStep -Name "TLS handshake retry ($region)" -Action {
                Test-TLSHandshake -EnvironmentId $EnvironmentId -Destination $Destination -Port $Port -Region $region @commonParameters
            }
        }

        # Any diagnostic can be the request that finishes provisioning the regional runtime.
        # Recheck incomplete evidence once after the full sequence has run.
        if (-not $usageStep.Succeeded) {
            $usageStep = Invoke-EvidenceStep -Name "Environment usage final retry ($region)" -Action {
                Get-EnvironmentUsage -EnvironmentId $EnvironmentId -Region $region @commonParameters
            }
        }
        if (-not $dnsStep.Succeeded) {
            $dnsStep = Invoke-EvidenceStep -Name "DNS resolution final retry ($region)" -Action {
                Test-DnsResolution -EnvironmentId $EnvironmentId -HostName $Destination -Region $region @commonParameters
            }
        }
        if (-not $tcpStep.Succeeded) {
            $tcpStep = Invoke-EvidenceStep -Name "TCP connectivity final retry ($region)" -Action {
                Test-NetworkConnectivity -EnvironmentId $EnvironmentId -Destination $Destination -Port $Port -Region $region @commonParameters
            }
        }
        if (-not $tlsStep.Succeeded) {
            $tlsStep = Invoke-EvidenceStep -Name "TLS handshake final retry ($region)" -Action {
                Test-TLSHandshake -EnvironmentId $EnvironmentId -Destination $Destination -Port $Port -Region $region @commonParameters
            }
        }

        $usageObject = Get-ResultObject -Step $usageStep -PropertyName 'SubnetIpRange'
        $dnsObject = Get-ResultObject -Step $dnsStep -PropertyName 'Success'
        $tcpObject = Get-ResultObject -Step $tcpStep -PropertyName 'TCPSuccess'
        $tlsObject = Get-ResultObject -Step $tlsStep -PropertyName 'TCPConnectivity'
        $tlsWithCrl = if (
            $tlsObject -and
            $tlsObject.PSObject.Properties.Name -contains 'SSLWithCRL'
        ) { $tlsObject.SSLWithCRL } else { $null }
        $tlsWithCrlSuccess = [bool](
            $tlsWithCrl -and
            $tlsWithCrl.PSObject.Properties.Name -contains 'Success' -and
            $tlsWithCrl.Success -eq $true
        )
        $subnetCidr = if ($usageObject) { [string]$usageObject.SubnetIpRange } else { $null }
        $tcpContainerIp = if ($tcpObject) { [string]$tcpObject.ContainerIpAddress } else { $null }
        $containerInSubnet = Test-IpInCidr -IpAddress $tcpContainerIp -Cidr $subnetCidr
        $regionPassed = [bool](
            $usageObject -and
            $dnsObject -and
            $dnsObject.Success -eq $true -and
            $tcpObject -and
            $tcpObject.TCPSuccess -eq $true -and
            $tlsObject -and
            $tlsObject.TCPConnectivity -eq $true -and
            $tlsWithCrlSuccess -and
            $containerInSubnet
        )
        $failureCode = $null
        $failureMessage = $null
        $nextAction = $null
        if (-not $usageObject) {
            $failureCode = 'REGIONAL_CONTEXT_UNAVAILABLE'
            $failureMessage = "Power Platform did not return the delegated-subnet mapping for '$region'."
            $nextAction = 'Verify the policy region mapping, subnet delegation/service association link, available subnet IPs, and retained correlation IDs. Do not infer a network block.'
        }
        elseif (-not $dnsObject) {
            $failureCode = 'DNS_DIAGNOSTIC_UNAVAILABLE'
            $failureMessage = "The DNS diagnostic did not return a final result for '$region'."
            $nextAction = 'Retry with identical inputs. If service errors persist, retain correlation IDs for Microsoft Support; do not change DNS from this run alone.'
        }
        elseif ($dnsObject.Success -ne $true) {
            $failureCode = 'DNS_RESOLUTION_FAILED'
            $failureMessage = "DNS resolution returned Success=False for '$region'."
            $nextAction = 'Inspect VNet DNS, forwarders, private DNS links/records, and the returned addresses for this exact FQDN.'
        }
        elseif (-not $tcpObject) {
            $failureCode = 'TCP_DIAGNOSTIC_UNAVAILABLE'
            $failureMessage = "The TCP diagnostic did not return a final result for '$region'."
            $nextAction = 'Retry with identical inputs. If service errors persist, retain correlation IDs for Microsoft Support; do not change NSG or firewall policy from this run alone.'
        }
        elseif ($tcpObject.TCPSuccess -ne $true) {
            $failureCode = 'TCP_CONNECTIVITY_FAILED'
            $failureMessage = "TCP connectivity to $Destination`:$Port returned False for '$region'."
            $nextAction = 'Correlate the UTC test window and delegated CIDR through NSG priority, UDR next hop, firewall/NVA session logs, SNAT, and return routing.'
        }
        elseif (-not $tlsObject) {
            $failureCode = 'TLS_DIAGNOSTIC_UNAVAILABLE'
            $failureMessage = "The TLS diagnostic did not return a final result for '$region'."
            $nextAction = 'Retry with identical inputs. If service errors persist, retain correlation IDs for Microsoft Support; do not change TLS policy from this run alone.'
        }
        elseif ($tlsObject.TCPConnectivity -ne $true) {
            $failureCode = 'TLS_TRANSPORT_FAILED'
            $failureMessage = "TCP passed separately, but the TLS diagnostic did not maintain TCP connectivity in '$region'."
            $nextAction = 'Inspect firewall/NVA session resets, TLS interception, SNAT, and symmetric return routing at the test timestamp.'
        }
        elseif (-not $tlsWithCrlSuccess) {
            $failureCode = 'TLS_CRL_VALIDATION_FAILED'
            $failureMessage = "TLS reached the endpoint, but certificate validation with CRL checking failed in '$region'."
            $nextAction = 'Bypass TLS inspection for the Warehouse path and verify publicly trusted chain plus CRL/OCSP reachability; do not weaken certificate validation.'
        }
        elseif (-not $containerInSubnet) {
            $failureCode = 'SOURCE_CIDR_MISMATCH'
            $failureMessage = "The TCP diagnostic source '$tcpContainerIp' is outside delegated CIDR '$subnetCidr'."
            $nextAction = 'Do not claim delegated-subnet execution. Verify environment/region mapping and retain the evidence for Microsoft Support if repeatable.'
        }

        $regionSummaries += [pscustomobject]@{
            Region                 = $region
            VnetId                 = if ($usageObject) { $usageObject.VnetId } else { $null }
            SubnetName             = if ($usageObject) { $usageObject.SubnetName } else { $null }
            SubnetCidr             = $subnetCidr
            DnsSuccess             = if ($dnsObject) { $dnsObject.Success } else { $false }
            DnsServers             = if ($dnsObject) { @($dnsObject.DnsServers) } else { @() }
            ResolvedIpAddresses    = if ($dnsObject) { @($dnsObject.IPAddresses) } else { @() }
            TcpSuccess             = if ($tcpObject) { $tcpObject.TCPSuccess } else { $false }
            TcpContainerIp         = $tcpContainerIp
            TlsTcpConnectivity     = if ($tlsObject) { $tlsObject.TCPConnectivity } else { $false }
            TlsWithCrlSuccess      = $tlsWithCrlSuccess
            TlsSslErrors           = if ($tlsWithCrl) { [string]$tlsWithCrl.SslErrors } else { $null }
            TlsContainerIp         = if ($tlsObject) { $tlsObject.ContainerIpAddress } else { $null }
            TcpContainerInSubnet   = $containerInSubnet
            FailureCode            = $failureCode
            FailureMessage         = $failureMessage
            NextAction             = $nextAction
            Passed                 = $regionPassed
        }
    }

    $overallPassed = [bool](
        $permissionValue -eq $true -and
        $environmentRegionStep.Succeeded -and
        $policyObject -and
        $policyObject.Kind -eq 'NetworkInjection' -and
        @($regionSummaries | Where-Object { -not $_.Passed }).Count -eq 0
    )
    $firstFailedRegion = @($regionSummaries | Where-Object { -not $_.Passed }) |
        Select-Object -First 1
    $primaryFailureCode = if ($permissionValue -ne $true) {
        'PERMISSION_FAILED'
    }
    elseif (-not $environmentRegionStep.Succeeded) {
        'ENVIRONMENT_REGION_UNAVAILABLE'
    }
    elseif (-not $policyObject) {
        'LINKED_POLICY_UNAVAILABLE'
    }
    elseif ($policyObject.Kind -ne 'NetworkInjection') {
        'POLICY_KIND_MISMATCH'
    }
    elseif ($firstFailedRegion) {
        $firstFailedRegion.FailureCode
    }
    else {
        $null
    }
    $verdict = if ($overallPassed) { 'NETWORK_PATH_PASSED' } else { 'NETWORK_PATH_NOT_PROVEN' }
    $correlationIds = @(
        $script:diagnosticErrors |
            ForEach-Object { @($_.CorrelationIds) } |
            Where-Object { $_ } |
            Select-Object -Unique
    )

    $summary = [pscustomobject]@{
        ObservedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        EnvironmentId      = $EnvironmentId
        TenantId           = $TenantId
        Destination        = $Destination
        Port               = $Port
        PermissionPassed   = ($permissionValue -eq $true)
        EnvironmentRegion  = @($environmentRegionStep.Result | Where-Object { $_ -is [string] }) | Select-Object -Last 1
        PolicyFound        = [bool]$policyObject
        PolicyName         = if ($policyObject) { $policyObject.ResourceName } else { $null }
        PolicyKind         = if ($policyObject) { $policyObject.Kind } else { $null }
        PolicyResourceId   = if ($policyObject) { $policyObject.ResourceId } else { $null }
        PolicyHealthStatus = if ($policyObject) { $policyObject.Properties.healthStatus } else { $null }
        Regions            = $regionSummaries
        DiagnosticErrors   = $script:diagnosticErrors
        CorrelationIds     = $correlationIds
        Verdict            = $verdict
        PrimaryFailureCode = $primaryFailureCode
        ProofBoundary      = @(
            'A passing region proves DNS, TCP 1433, CRL-enabled TLS, and TCP diagnostic source placement in the reported delegated subnet at the observation time.',
            'A failed check isolates a layer but does not identify the exact NSG, UDR, firewall/NVA, DNS, proxy, or return-path defect.',
            'This script does not prove Fabric Warehouse authentication, authorization, RLS, or Copilot Studio SQL action execution.'
        )
        OverallPassed      = $overallPassed
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding utf8
    Write-Host "`n=== FINAL VERDICT ==="
    Write-Host "Verdict: $verdict"
    Write-Host "OverallPassed: $overallPassed"
    Write-Host "PrimaryFailureCode: $primaryFailureCode"
    $regionSummaries |
        Select-Object Region, DnsSuccess, TcpSuccess, TlsTcpConnectivity,
            TlsWithCrlSuccess, TcpContainerInSubnet, Passed, FailureCode |
        Format-Table -AutoSize | Out-Host
    $failedRegions = @($regionSummaries | Where-Object { -not $_.Passed })
    if ($failedRegions.Count -gt 0) {
        Write-Host 'Failure details:' -ForegroundColor Red
        $failedRegions |
            Select-Object Region, FailureCode, FailureMessage, NextAction |
            Format-List | Out-Host
    }
    elseif ($overallPassed) {
        Write-Host 'Network path passed. Freeze network changes and continue with connector identity, exact Warehouse name, Fabric permissions, RLS, and Copilot action input validation.' -ForegroundColor Green
    }
    if ($correlationIds.Count -gt 0) {
        Write-Host "Correlation IDs retained: $($correlationIds -join ', ')" -ForegroundColor Yellow
    }
    Write-Host "Transcript: $transcriptPath"
    Write-Host "JSON summary: $summaryPath"
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}

if (-not $overallPassed) {
    exit 1
}

exit 0