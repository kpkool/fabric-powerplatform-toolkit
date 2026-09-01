# Power Platform VNet Injection Toggle

`Set-PowerPlatformVnetInjection.ps1` shows, enables, or disables the enterprise
policy link used for Power Platform virtual network injection.

> **Warning:** `Enable` and `Disable` change a Power Platform environment.
> Microsoft documents that enabling or disabling subnet injection can cause up
> to 30 minutes of unavailability or instability while connections initialize.
> Use an approved maintenance window, capture the current policy ID, and have a
> rollback owner. Do not toggle injection merely because a diagnostic command
> returned a transient error.

## Prerequisites

- PowerShell 7 or Windows PowerShell 5.1.
- Power Platform administrative permissions in the target tenant.
- Access to the enterprise policy used by the environment.
- `Microsoft.PowerPlatform.EnterprisePolicies`.
- `Az.Accounts` for interactive authentication.

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser
```

## Authenticate

```powershell
$tenantId = '<tenant-guid>'
$subscriptionId = '<subscription-guid>'

Connect-AzAccount `
  -Tenant $tenantId `
  -Subscription $subscriptionId
```

## Check Status

Status is the default and does not change the environment:

```powershell
Set-Location ./vnet-injection-toggle

$environmentId = '<power-platform-environment-id>'

./Set-PowerPlatformVnetInjection.ps1 `
  -Action Status `
  -EnvironmentId $environmentId `
  -TenantId $tenantId
```

When linked, the output includes `InjectionLinked: True`, the policy name, ARM
ID, kind, and reported health. If the lookup fails, the script throws the original
module error instead of reporting a false disabled state.

## Enable Injection

The policy ARM ID has this form:

```text
/subscriptions/<subscription-guid>/resourceGroups/<resource-group>/providers/Microsoft.PowerPlatform/enterprisePolicies/<policy-name>
```

Preview the action first:

```powershell
$policyArmId = '/subscriptions/<subscription-guid>/resourceGroups/<resource-group>/providers/Microsoft.PowerPlatform/enterprisePolicies/<policy-name>'

./Set-PowerPlatformVnetInjection.ps1 `
  -Action Enable `
  -EnvironmentId $environmentId `
  -TenantId $tenantId `
  -PolicyArmId $policyArmId `
  -WhatIf
```

Run the approved change. The script prompts for confirmation because the action
is high impact:

```powershell
./Set-PowerPlatformVnetInjection.ps1 `
  -Action Enable `
  -EnvironmentId $environmentId `
  -TenantId $tenantId `
  -PolicyArmId $policyArmId `
  -TimeoutSeconds 1800
```

## Disable Injection

Preview the action first:

```powershell
./Set-PowerPlatformVnetInjection.ps1 `
  -Action Disable `
  -EnvironmentId $environmentId `
  -TenantId $tenantId `
  -WhatIf
```

Run the approved change:

```powershell
./Set-PowerPlatformVnetInjection.ps1 `
  -Action Disable `
  -EnvironmentId $environmentId `
  -TenantId $tenantId `
  -TimeoutSeconds 1800
```

Disabling injection unlinks the environment from its enterprise policy. It does
not delete the policy, VNets, or delegated subnets.

## Asynchronous Operation

By default, Microsoft cmdlets wait for completion. Add `-NoWait` only when an
external process will monitor completion:

```powershell
./Set-PowerPlatformVnetInjection.ps1 `
  -Action Enable `
  -EnvironmentId $environmentId `
  -TenantId $tenantId `
  -PolicyArmId $policyArmId `
  -NoWait
```

After any change, rerun `-Action Status` and then use the
[read-only delegated subnet validator](../delegated-subnet-validator/README.md)
for both configured Azure regions.

## Error Handling

- Missing module: the script provides the exact installation command.
- Missing `PolicyArmId` for enable: the script stops before making a change.
- Module/API failure: the script throws the original error and returns a failing
  process status.
- A returned result other than `True` is treated as a failed operation.

Do not include tenant IDs, policy IDs, tokens, or runtime output in public issues.

## Official Documentation

- [Enable-SubnetInjection](https://learn.microsoft.com/powershell/module/microsoft.powerplatform.enterprisepolicies/enable-subnetinjection)
- [Disable-SubnetInjection](https://learn.microsoft.com/powershell/module/microsoft.powerplatform.enterprisepolicies/disable-subnetinjection)
- [Power Platform virtual network setup](https://learn.microsoft.com/power-platform/admin/vnet-support-setup-configure)
