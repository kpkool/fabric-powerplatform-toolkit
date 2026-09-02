# Power Platform Delegated Subnet Validator

`Test-PowerPlatformDelegatedSubnet.ps1` is a read-only PowerShell validator for
troubleshooting Power Platform virtual network injection connectivity to a
destination such as a Microsoft Fabric Warehouse SQL endpoint.

The script follows the Microsoft-documented diagnostic flow:

1. Confirm Power Platform diagnostic permissions.
2. Discover the environment region and linked network-injection policy.
3. Test DNS, TCP, and TLS from each requested delegated subnet region.
4. Confirm that the TCP diagnostic source belongs to the reported subnet CIDR.
5. Write a human-readable transcript and machine-readable JSON summary.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7.
- Power Platform Administrator permissions in the target tenant.
- Read access to the Power Platform enterprise policy and delegated VNets.
- The `Microsoft.PowerPlatform.EnterprisePolicies` PowerShell module.
- The target environment ID, tenant ID, complete destination FQDN, port, and
  every Azure region configured in the network-injection policy.

Install the required modules once if they are not already available:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser
```

Confirm module discovery:

```powershell
Get-Module -ListAvailable Microsoft.PowerPlatform.EnterprisePolicies |
  Sort-Object Version -Descending |
  Select-Object -First 1 Name, Version, Path
```

## Parameter Values

| Parameter         | Value to provide                                                             |
| ----------------- | ---------------------------------------------------------------------------- |
| `EnvironmentId`   | Complete Power Platform environment ID                                       |
| `TenantId`        | Microsoft Entra tenant GUID                                                  |
| `Destination`     | Complete target FQDN without `https://`, `tcp:`, a port, or a trailing slash |
| `Regions`         | Every Azure region configured in the Power Platform network-injection policy |
| `Port`            | Destination TCP port, such as `1433` for a Fabric Warehouse SQL endpoint     |
| `OutputDirectory` | Local directory where the transcript and JSON summary should be written      |

For a Fabric Warehouse, copy the full SQL connection string host from Fabric.
The hostname ends in `.datawarehouse.fabric.microsoft.com`, and the Warehouse
item name is used separately as the database name by SQL clients and connectors.

## Run the Validator

Clone the repository and open PowerShell in its root directory:

```powershell
git clone https://github.com/kpkool/fabric-powerplatform-toolkit.git
Set-Location ./fabric-powerplatform-toolkit/delegated-subnet-validator
```

Authenticate to the customer tenant and Azure subscription:

```powershell
$tenantId = '<tenant-guid>'
$subscriptionId = '<subscription-guid>'

Connect-AzAccount `
  -Tenant $tenantId `
  -Subscription $subscriptionId
```

Set the customer-specific values and run the script:

```powershell
$environmentId = '<power-platform-environment-id>'
$destination = '<complete-server-name>.datawarehouse.fabric.microsoft.com'
$regions = @('<primary-azure-region>', '<paired-azure-region>')
$evidenceDirectory = Join-Path $PWD 'evidence'

& ./Test-PowerPlatformDelegatedSubnet.ps1 `
  -EnvironmentId $environmentId `
  -TenantId $tenantId `
  -Destination $destination `
  -Regions $regions `
  -Port 1433 `
  -OutputDirectory $evidenceDirectory

$LASTEXITCODE
```

Use Azure region names such as `eastus` and `westus`, not Power Platform
geography names such as `unitedstates`.

If the script needs to force a fresh Power Platform authentication session, add
`-ForceAuth`.

## First-Login AccessToken Error

Some versions of `Microsoft.PowerPlatform.EnterprisePolicies` can return this
error immediately after an interactive sign-in:

```text
Cannot convert the "System.Object[]" value of type "System.Object[]" to type
"System.Security.SecureString" for parameter "AccessToken".
```

This is a module authentication-output error. It occurs before the diagnostic
HTTP request is created, so it does not prove an invalid environment ID, a
permission failure, or a blocked network path. The interactive sign-in usually
completed and cached the required token; rerunning the same read-only cmdlet in
the same PowerShell process should then use that token.

The validator detects only this exact binding error and retries the affected
read-only command once. Other errors are not retried. When testing the Microsoft
cmdlet directly, rerun the identical command once after `Logged In...`:

```powershell
Get-EnvironmentRegion `
  -EnvironmentId $environmentId `
  -TenantId $tenantId
```

If the second attempt fails, retain the complete second error and record the
loaded versions before troubleshooting permissions or networking:

```powershell
Get-Module Microsoft.PowerPlatform.EnterprisePolicies, Az.Accounts |
  Select-Object Name, Version, Path
```

## Expected Output

The script writes two files:

```text
evidence/
  power-platform-vnet-<UTC timestamp>.log
  power-platform-vnet-<UTC timestamp>.json
```

A complete network pass returns process exit code `0` and ends with:

```text
Verdict: NETWORK_PATH_PASSED
OverallPassed: True
```

Every requested region must report all of the following as `True`:

- `DnsSuccess`
- `TcpSuccess`
- `TlsTcpConnectivity`
- `TlsWithCrlSuccess`
- `TcpContainerInSubnet`
- `Passed`

Any failed final gate returns process exit code `1`. Review the top-level
`PrimaryFailureCode` and each failed region's `FailureMessage` and `NextAction`.

Common final codes include:

| Failure code                   | Meaning                                                       |
| ------------------------------ | ------------------------------------------------------------- |
| `PERMISSION_FAILED`            | The operator permission test did not pass                     |
| `LINKED_POLICY_UNAVAILABLE`    | The linked enterprise policy could not be confirmed           |
| `REGIONAL_CONTEXT_UNAVAILABLE` | The delegated subnet mapping was not returned                 |
| `DNS_RESOLUTION_FAILED`        | DNS returned a final negative result                          |
| `TCP_CONNECTIVITY_FAILED`      | TCP returned a final negative result                          |
| `TLS_TRANSPORT_FAILED`         | TCP passed separately, but the TLS test could not maintain it |
| `TLS_CRL_VALIDATION_FAILED`    | TLS certificate validation with CRL checking failed           |
| `SOURCE_CIDR_MISMATCH`         | The diagnostic source was outside the reported subnet CIDR    |

Codes ending in `_DIAGNOSTIC_UNAVAILABLE` mean that the diagnostic command did
not return a final test result. Retain its correlation IDs and retry with the
same inputs. Do not treat a diagnostic service error as proof that customer DNS,
NSG, firewall, or routing blocked the request.

## Interpretation

If every region passes, freeze speculative network changes and continue at the
application layer. Validate:

- The connector's authenticated Microsoft Entra identity.
- The exact Fabric Warehouse server and database name.
- Fabric capacity state and workspace/item permissions.
- Row-level security identity mapping.
- The actual Server, Database, and Query inputs shown in the Copilot Studio tool
  activity.

A TCP pass proves transport reachability only. It does not prove SQL login,
database authorization, or successful connector execution.

## Privacy and Security

The repository contains no customer-specific IDs, hostnames, credentials, IP
addresses, or evidence. However, files generated when the script runs can contain:

- Tenant, subscription, environment, VNet, and subnet identifiers.
- Customer destination hostnames.
- Private and resolved IP addresses and subnet CIDRs.
- Error details and Microsoft correlation IDs.

Store generated evidence only in an approved customer location. Review and
redact it before sharing. Do not commit customer evidence, access tokens,
credentials, query results, or sensitive data to this public repository.
The default `evidence/` directory and timestamped validator outputs are excluded
by [`.gitignore`](../.gitignore) as an additional safeguard.

## Proof Boundary

The script can prove DNS, TCP, CRL-enabled TLS, and diagnostic source placement
for the requested delegated subnet regions at the observation time. A failed
check isolates a layer but does not identify the exact customer rule or resource
that caused it.

The script does not prove:

- Microsoft Entra authentication to a Fabric Warehouse.
- Warehouse database or object authorization.
- Row-level security behavior.
- Copilot Studio SQL action execution.

## Official Documentation

- [Get-EnvironmentRegion](https://learn.microsoft.com/powershell/module/microsoft.powerplatform.enterprisepolicies/get-environmentregion)
- [Protect secrets in Azure PowerShell](https://learn.microsoft.com/powershell/azure/protect-secrets)
- [Troubleshoot virtual network issues in Power Platform](https://learn.microsoft.com/troubleshoot/power-platform/administration/virtual-network)
- [Power Platform virtual network support overview](https://learn.microsoft.com/power-platform/admin/vnet-support-overview)
- [Microsoft Fabric Warehouse connectivity](https://learn.microsoft.com/fabric/data-warehouse/connectivity)

## License

Licensed under the [Apache License 2.0](../LICENSE).
