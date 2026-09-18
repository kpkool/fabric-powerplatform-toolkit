<!-- markdownlint-disable MD010 -->

# Fabric and Power Platform Toolkit

Public PowerShell tools for Microsoft Fabric and Power Platform networking.
Examples are parameterized and contain no customer-specific identifiers.

## Managed Environment Setup

Use this guide when a new Power Platform environment, such as **Testing
Managed**, must reach the same Microsoft Fabric Warehouse as an existing working
environment, such as **Development Managed**.

> A matching `500 / BadGateway` error doesn't prove the same root cause. Check
> the new environment's policy link and both delegated Azure regions before
> changing networking. A network pass also doesn't prove connector identity,
> Warehouse authorization, row-level security, or Copilot Studio execution.

### Can two environments reuse the same subnet?

**Yes, through the same enterprise policy.** Microsoft documents that multiple
Power Platform environments can share one subnet-injection enterprise policy
and its delegated subnets. Size each subnet for the combined environment load.

**No, across different enterprise policies.** A delegated subnet can't be
reused in multiple enterprise policies. A separate policy requires its own
dedicated subnet in every required Azure region.

Use a shared policy only when both environments are intended to share the same
DNS, routing, NSG, firewall, egress, and change boundary. A shared policy has
these operational effects:

- Both environments consume IP addresses from the same delegated subnets.
- A subnet, DNS, route, NSG, or firewall change can affect both environments.
- Early release cycle environments can't share a policy with other environments.

Choose separate policies and subnets when environment isolation, independent
change windows, or smaller failure domains are required. This is an architecture
choice, not a Power Platform requirement.

Microsoft currently estimates 6-10 IP addresses per nonproduction environment
and 25-30 per production environment, plus five Azure-reserved addresses per
subnet. Include growth and failover capacity in both regional subnets. See the
[official sizing and reuse guidance][vnet-overview].

## Setup Sequence

### 1. Confirm environment readiness

Before linking **Testing Managed**, confirm:

- The environment exists and [Managed Environments][managed-environments] is
  enabled. Power Platform VNet support requires a managed environment.
- Its type is supported: Production, Sandbox, Developer, or Default. Trial and
  Dataverse for Teams environments aren't supported.
- Its Power Platform geography matches the enterprise policy.
- The Azure subscription is associated with the Power Platform tenant.
- The operator has Power Platform Administrator and sufficient Azure read or
  network permissions for the enterprise policy and its network resources.
- The SQL Server connector is allowed by every data policy applicable to the
  environment. If any applicable policy blocks it, the connector remains blocked.

For a multiregion geography, the enterprise policy must use a delegated VNet and
subnet in both mapped Azure regions. For example, the current United States
mapping is `eastus` and `westus`. Always verify the current mapping in
[Microsoft's supported-region table][vnet-overview].

### 2. Collect authoritative values

Use IDs from the environment, Azure, and Fabric records. Don't infer IDs from
display names or reuse credentials from another environment.

```powershell
$tenantId = '<tenant-guid>'
$subscriptionId = '<subscription-guid>'
$developmentEnvironmentId = '<development-managed-environment-id>'
$testingEnvironmentId = '<testing-managed-environment-id>'
$policyArmId = '/subscriptions/<subscription-guid>/resourceGroups/<resource-group>/providers/Microsoft.PowerPlatform/enterprisePolicies/<policy-name>'
$warehouseServer = '<complete-server-name>.datawarehouse.fabric.microsoft.com'
$warehouseDatabase = '<warehouse-item-name>'
$regions = @('<primary-azure-region>', '<paired-azure-region>')
$evidenceDirectory = '<approved-private-evidence-directory>'
```

Copy the complete SQL connection-string host from the Fabric Warehouse. The
Warehouse item name is the connector's database value. Don't build either value
from a shortened hostname.

### 3. Install tools and authenticate

```powershell
git clone https://github.com/kpkool/fabric-powerplatform-toolkit.git
Set-Location ./fabric-powerplatform-toolkit

Install-Module Az.Accounts -Scope CurrentUser
Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser

Connect-AzAccount `
	-Tenant $tenantId `
	-Subscription $subscriptionId

az login --tenant $tenantId
az account set --subscription $subscriptionId
```

Confirm the Azure resource providers are registered. Registration is normally
already complete when reusing an existing policy.

```powershell
az provider show `
	--namespace Microsoft.Network `
	--query registrationState `
	--output tsv

az provider show `
	--namespace Microsoft.PowerPlatform `
	--query registrationState `
	--output tsv
```

Both commands should return `Registered`. A subscription owner or contributor
must register a provider if it isn't registered.

### 4. Compare Development and Testing without changing them

Run the toolkit's read-only status action:

```powershell
$developmentStatus = `
	./vnet-injection-toggle/Set-PowerPlatformVnetInjection.ps1 `
		-Action Status `
		-EnvironmentId $developmentEnvironmentId `
		-TenantId $tenantId

$testingStatus = `
	./vnet-injection-toggle/Set-PowerPlatformVnetInjection.ps1 `
		-Action Status `
		-EnvironmentId $testingEnvironmentId `
		-TenantId $tenantId

$developmentStatus
$testingStatus

[pscustomobject]@{
	TestingLinked = $testingStatus.InjectionLinked
	SamePolicy = $developmentStatus.PolicyArmId -eq $testingStatus.PolicyArmId
	DevelopmentPolicy = $developmentStatus.PolicyArmId
	TestingPolicy = $testingStatus.PolicyArmId
}
```

Verify that Development reports the expected enterprise policy. Then route the
Testing environment by its observed state:

| Testing state                 | Action                                                  |
| ----------------------------- | ------------------------------------------------------- |
| Not linked                    | Validate and link the exact approved enterprise policy  |
| Linked to the approved policy | Don't relink; run both-region validation                |
| Linked to another policy      | Stop and confirm the intended design before changing it |
| Status lookup fails           | Retain the error; don't report injection as disabled    |

### 5. Validate the shared enterprise policy

Inspect the existing policy before adding another environment:

```powershell
$policy = az resource show `
	--ids $policyArmId `
	--api-version 2020-10-30-preview | ConvertFrom-Json

$policy | Select-Object id, location, kind
$policy.properties.networkInjection.virtualNetworks | Format-List
```

Require `kind: NetworkInjection`. The output must identify the approved VNet and
dedicated subnet in every required Azure region.

Check each subnet returned by the policy:

```powershell
$vnetId = '<vnet-resource-id-from-policy>'
$subnetName = '<delegated-subnet-name-from-policy>'
$subnetId = "$vnetId/subnets/$subnetName"

az network vnet subnet show `
	--ids $subnetId `
	--query '{id:id,prefix:addressPrefix,prefixes:addressPrefixes,delegations:delegations[].serviceName,nsg:networkSecurityGroup.id,routeTable:routeTable.id}' `
	--output jsonc

az network vnet show `
	--ids $vnetId `
	--query '{id:id,location:location,dnsServers:dhcpOptions.dnsServers}' `
	--output jsonc
```

Repeat for both regional subnets. Confirm:

- Delegation is `Microsoft.PowerPlatform/enterprisePolicies`.
- The subnet is dedicated to the enterprise policy.
- Both regional subnets have sufficient IP capacity for Development, Testing,
  and expected growth.
- DNS, NSG, route table, Azure Firewall or NVA, and return routing are complete
  in both regions.

For a public Fabric Warehouse path, [Microsoft documents][warehouse-connectivity]
outbound TCP `1433`, both the `PowerBI` and `Sql` service tags, and `MSSQL/TDS`
handling on protocol-aware firewalls. The Warehouse TDS FQDN alone isn't a
complete replacement for the service-tag requirements.

#### Apply the delegated-subnet NSG rules

Apply these outbound rules to the NSG on **each** regional delegated subnet. Use
unique priorities that are evaluated before any custom outbound deny. The
`PowerBI` rule needs both `443` and `1433`: Warehouse can use Power BI dedicated
infrastructure for its HTTPS dependencies and TDS front end. The `Sql` rule
covers the documented Warehouse SQL path on `1433`.

```powershell
$nsgResourceGroup = '<network-resource-group>'
$nsgName = '<delegated-subnet-nsg>'
$delegatedSubnetPrefix = '<delegated-subnet-cidr>'
$powerBiRulePriority = 300 # Replace with an approved unused priority.
$sqlRulePriority = 310     # Replace with an approved unused priority.

az network nsg rule list `
	--resource-group $nsgResourceGroup `
	--nsg-name $nsgName `
	--query "[].{priority:priority,name:name,direction:direction,access:access,destination:destinationAddressPrefix,ports:destinationPortRanges}" `
	--output table

az network nsg rule create `
	--resource-group $nsgResourceGroup `
	--nsg-name $nsgName `
	--name Allow-Out-Fabric-PowerBI `
	--priority $powerBiRulePriority `
	--direction Outbound `
	--access Allow `
	--protocol Tcp `
	--source-address-prefixes $delegatedSubnetPrefix `
	--source-port-ranges '*' `
	--destination-address-prefixes PowerBI `
	--destination-port-ranges 443 1433 `
	--description 'Allow delegated Power Platform egress to Power BI and Fabric Warehouse.'

az network nsg rule create `
	--resource-group $nsgResourceGroup `
	--nsg-name $nsgName `
	--name Allow-Out-Fabric-Sql `
	--priority $sqlRulePriority `
	--direction Outbound `
	--access Allow `
	--protocol Tcp `
	--source-address-prefixes $delegatedSubnetPrefix `
	--source-port-ranges '*' `
	--destination-address-prefixes Sql `
	--destination-port-ranges 1433 `
	--description 'Allow delegated Power Platform egress to Fabric Warehouse SQL.'
```

Repeat the commands with the second region's resource group, NSG, and delegated
subnet CIDR. If the network standard uses regional service-tag variants, include
the environment home region, Fabric capacity region, and corresponding paired
regions described in the [Fabric service-tag guidance][fabric-service-tags].
Don't replace service tags with current endpoint IP addresses.

A permissive Azure Firewall rule can't override a restrictive subnet NSG. A
subnet NSG deny can stop the flow before it reaches the firewall, so empty
firewall logs don't prove that the route bypassed Azure Firewall.

#### Apply the Azure Firewall rules

If a UDR sends delegated-subnet egress through Azure Firewall, permit the same
flow there. Use the existing approved rule collection and source each rule from
the delegated subnet CIDRs. Apply this in every regional egress path.

| Scope                                         | Azure Firewall protocol | Destination FQDNs                                                                                                                                                                              | Port   |
| --------------------------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| **Required: Warehouse TDS**                   | `MSSQL`                 | `*.datawarehouse.fabric.microsoft.com`, `*.datawarehouse.pbidedicated.windows.net`, `*.datawarehouse.pbidedicated.microsoft.com`, `*.pbidedicated.windows.net`, `*.pbidedicated.microsoft.com` | `1433` |
| **Required: Power BI APIs**                   | `HTTPS`                 | `api.powerbi.com`, `*.analysis.windows.net`, `*.pbidedicated.windows.net`                                                                                                                      | `443`  |
| **Required: Power BI portal and Power Query** | `HTTPS`                 | `*.powerbi.com`, `*.powerquery.microsoft.com`, `content.powerapps.com`, `gatewayadminportal.azure.com`                                                                                         | `443`  |
| **Required: Fabric portal**                   | `HTTPS`                 | `*.fabric.microsoft.com`                                                                                                                                                                       | `443`  |
| **Required: Power BI storage and telemetry**  | `HTTPS`                 | `*.blob.core.windows.net`, `dc.services.visualstudio.com`                                                                                                                                      | `443`  |
| **Workload-specific: OneLake**                | `HTTPS`                 | `*.onelake.dfs.fabric.microsoft.com`, `*.onelake.blob.fabric.microsoft.com`                                                                                                                    | `443`  |

The Warehouse TDS row is the data path for this connector. The HTTPS rows are
the current required Fabric platform and Power BI general-use destinations;
apply the rows used by traffic that traverses this firewall. The OneLake row is
needed only when the solution also uses the OneLake DFS or Blob APIs.

Also review Microsoft's linked identity endpoints and any workload-specific
required endpoints in the [Fabric URL allowlist][fabric-allowlist] and
[Power BI URL allowlist][power-bi-allowlist]. Don't copy optional consumer,
survey, or support URLs into a production allowlist without a business need.

This parameterized example applies the rules to a **classic Azure Firewall**.
For a firewall managed by Azure Firewall Policy, add the same rule intents to
the existing rule collection group through its approved IaC or change workflow;
don't replace or detach the policy.

```powershell
$firewallResourceGroup = '<firewall-resource-group>'
$firewallName = '<azure-firewall-name>'
$applicationRuleCollection = '<approved-application-rule-collection>'
$applicationRuleCollectionPriority = 500 # Replace with an approved unused priority.
$delegatedSubnetPrefixes = @('<primary-delegated-cidr>', '<paired-delegated-cidr>')

$warehouseFqdns = @(
	'*.datawarehouse.fabric.microsoft.com',
	'*.datawarehouse.pbidedicated.windows.net',
	'*.datawarehouse.pbidedicated.microsoft.com',
	'*.pbidedicated.windows.net',
	'*.pbidedicated.microsoft.com'
)

$fabricPowerBiHttpsFqdns = @(
	'api.powerbi.com',
	'*.analysis.windows.net',
	'*.pbidedicated.windows.net',
	'*.powerbi.com',
	'*.powerquery.microsoft.com',
	'content.powerapps.com',
	'gatewayadminportal.azure.com',
	'*.fabric.microsoft.com',
	'*.blob.core.windows.net',
	'dc.services.visualstudio.com',
	'*.onelake.dfs.fabric.microsoft.com',
	'*.onelake.blob.fabric.microsoft.com'
)

az extension add --name azure-firewall --upgrade

az network firewall application-rule create `
	--resource-group $firewallResourceGroup `
	--firewall-name $firewallName `
	--collection-name $applicationRuleCollection `
	--priority $applicationRuleCollectionPriority `
	--action Allow `
	--name Allow-Fabric-Warehouse-TDS `
	--protocols mssql=1433 `
	--source-addresses $delegatedSubnetPrefixes `
	--target-fqdns $warehouseFqdns

az network firewall application-rule create `
	--resource-group $firewallResourceGroup `
	--firewall-name $firewallName `
	--collection-name $applicationRuleCollection `
	--priority $applicationRuleCollectionPriority `
	--action Allow `
	--name Allow-Fabric-PowerBI-HTTPS `
	--protocols https=443 `
	--source-addresses $delegatedSubnetPrefixes `
	--target-fqdns $fabricPowerBiHttpsFqdns
```

Don't configure Warehouse SQL as `HTTPS:1433`. Use `MSSQL:1433`, and don't apply
HTTPS TLS inspection to the TDS connection. If the firewall uses service-tag
network rules instead of SQL-aware application rules, allow `PowerBI` on TCP
`443` and `1433` and `Sql` on TCP `1433` from both delegated subnet CIDRs. Follow
one approved firewall control model and confirm its effective rule processing.

TCP `11000-11999` applies to the different Fabric SQL database endpoint
(`*.database.fabric.microsoft.com`) when redirect connection policy is used. It
isn't part of this Fabric Warehouse rule set.

After deployment, verify the effective NSG rules, routes, Azure Firewall allows
and denies, DNS answers, and both regional validator results. For a TLS failure,
use `Test-TLSHandshake` and verify the server presents a publicly trusted
certificate. Permit the certificate authority's live CRL or OCSP destinations
when revocation checking is enforced; derive them from the presented chain
rather than maintaining a guessed static list. Keep the UTC test window and
Azure Firewall correlation evidence with the onboarding record.

### 6. Link Testing Managed

Run this only when Testing isn't linked and the policy passed the checks above.
Preview the change first:

```powershell
./vnet-injection-toggle/Set-PowerPlatformVnetInjection.ps1 `
	-Action Enable `
	-EnvironmentId $testingEnvironmentId `
	-TenantId $tenantId `
	-PolicyArmId $policyArmId `
	-WhatIf
```

Run the approved change:

```powershell
./vnet-injection-toggle/Set-PowerPlatformVnetInjection.ps1 `
	-Action Enable `
	-EnvironmentId $testingEnvironmentId `
	-TenantId $tenantId `
	-PolicyArmId $policyArmId `
	-TimeoutSeconds 1800
```

Microsoft documents up to 30 minutes of unavailability or instability while
connections initialize after enabling or disabling subnet injection. Use an
approved change window and wait for propagation.

Rerun `-Action Status`. Require:

- `InjectionLinked: True`
- The exact approved `PolicyArmId`
- The expected environment region
- A `Succeeded` environment operation in Power Platform admin center history

### 7. Validate both delegated regions

Run the read-only validator from a managed workstation. Power Platform runs the
tests from the delegated subnet context; the workstation doesn't need to be in
either VNet.

```powershell
& ./delegated-subnet-validator/Test-PowerPlatformDelegatedSubnet.ps1 `
	-EnvironmentId $testingEnvironmentId `
	-TenantId $tenantId `
	-Destination $warehouseServer `
	-Regions $regions `
	-Port 1433 `
	-OutputDirectory $evidenceDirectory

$LASTEXITCODE
```

Network acceptance requires exit code `0`, `Verdict: NETWORK_PATH_PASSED`, and
all of these values as `True` in every region:

- `DnsSuccess`
- `TcpSuccess`
- `TlsTcpConnectivity`
- `TlsWithCrlSuccess`
- `TcpContainerInSubnet`
- `Passed`

A diagnostic API timeout is inconclusive. Retain its correlation ID and retry
with the same inputs; don't make a speculative network change.

### 8. Validate the actual Copilot Studio action

Complete application acceptance only after both regions pass:

1. Confirm the Fabric capacity is active.
2. Confirm every applicable Power Platform data policy permits the SQL Server
   connector.
3. Create or select the approved Microsoft Entra connection in Testing Managed.
   Don't copy another environment's credentials or connection reference.
4. Grant that identity only the required Fabric item, Warehouse, SQL object, and
   row-level permissions.
5. Configure the tool's Server as the complete Warehouse FQDN and Database as the
   Warehouse item name. Use fixed approved values rather than AI-generated ones.
6. Run a bounded smoke query:

   ```sql
   SELECT DB_NAME() AS database_name, USER_NAME() AS database_user;
   ```

7. Verify the expected database and identity are returned. Record the UTC time,
   environment, conversation or run ID, connection identity, and result.
8. Correlate the run with Fabric Warehouse Query Insights or the approved SQL
   audit source and firewall logs where enabled.

Declare Testing Managed ready only when both gates pass:

| Gate        | Required evidence                                                                            |
| ----------- | -------------------------------------------------------------------------------------------- |
| Network     | Every delegated region passes DNS, TCP, TLS, and source-CIDR checks                          |
| Application | The actual Copilot Studio SQL action returns the expected result using the intended identity |

## Recovery-Only Relink

Don't disable and reenable subnet injection just because the user-facing error
matches an earlier incident. Relink only under an approved maintenance window
when evidence or Microsoft Support identifies stale subnet metadata, or when a
supported network change requires it.

Capture the current policy ARM ID first. The toggle's Disable action unlinks the
environment but doesn't delete the policy, VNet, or subnet.

```powershell
$before = ./vnet-injection-toggle/Set-PowerPlatformVnetInjection.ps1 `
	-Action Status `
	-EnvironmentId $testingEnvironmentId `
	-TenantId $tenantId

if ($before.PolicyArmId -ne $policyArmId) {
	throw "Testing Managed isn't linked to the approved rollback policy."
}

./vnet-injection-toggle/Set-PowerPlatformVnetInjection.ps1 `
	-Action Disable `
	-EnvironmentId $testingEnvironmentId `
	-TenantId $tenantId `
	-WhatIf
```

After approval, run Disable without `-WhatIf`, wait for completion, then run
Enable with the captured `$policyArmId`. Repeat Status, both-region validation,
and the Copilot Studio acceptance test.

If changing VNet DNS, Microsoft instructs administrators to unlink all
environments from the shared policy, make the DNS change, wait 30 minutes, and
then reenable subnet injection. This is an important shared-subnet blast radius.

## Failure Routing

| Result                            | Check next                                                                       |
| --------------------------------- | -------------------------------------------------------------------------------- |
| Link missing                      | Link the exact approved enterprise policy                                        |
| Wrong environment region          | Verify the environment ID and required Azure region pair                         |
| Regional usage unavailable        | Policy allocation, subnet capacity, operation history, correlation IDs           |
| DNS failed                        | VNet DNS, forwarding, zones or records, complete hostname                        |
| TCP `1433` failed                 | NSG, UDR, firewall or NVA, service tags, MSSQL rule, return path                 |
| TLS failed after TCP passed       | TLS inspection, public certificate chain, CRL or OCSP access, protocol handling  |
| Source CIDR mismatch              | Linked policy, selected region, stale or unexpected runtime placement            |
| Network passed but Copilot failed | Data policy, connection identity, Fabric permissions, RLS, capacity, tool inputs |

## Tools

| Tool                                                               | Mode           | Purpose                                                                              |
| ------------------------------------------------------------------ | -------------- | ------------------------------------------------------------------------------------ |
| [Delegated subnet validator](delegated-subnet-validator/README.md) | Read-only      | Test Power Platform regional DNS, TCP, TLS, and delegated-subnet source placement    |
| [VNet injection toggle](vnet-injection-toggle/README.md)           | State-changing | Show, enable, or disable the enterprise-policy link for a Power Platform environment |

Start with the read-only validator. Use the toggle only for an approved change,
maintenance operation, or controlled A/B test with a rollback plan.

## Official Documentation

- [Set up virtual network support for Power Platform][vnet-setup]
- [Power Platform VNet support overview, regions, sizing, and reuse][vnet-overview]
- [Troubleshoot Power Platform virtual network issues][vnet-troubleshooting]
- [Enable-SubnetInjection][enable-injection]
- [Disable-SubnetInjection][disable-injection]
- [Fabric Warehouse connectivity][warehouse-connectivity]
- [Fabric service tags][fabric-service-tags]
- [Fabric URL allowlist][fabric-allowlist]
- [Power BI URL allowlist][power-bi-allowlist]
- [Azure Firewall SQL FQDN filtering][azure-firewall-sql-fqdn]
- [Combined effect of Power Platform data policies][combined-data-policies]

## Privacy

The source contains no customer IDs, endpoints, credentials, or evidence. Runtime
output can contain tenant, environment, network, endpoint, IP, and correlation
data. Store it only in an approved location and never commit it to this public
repository.

## License

Licensed under the [Apache License 2.0](LICENSE).

[azure-firewall-sql-fqdn]: https://learn.microsoft.com/azure/firewall/sql-fqdn-filtering
[combined-data-policies]: https://learn.microsoft.com/power-platform/admin/dlp-combined-effect-multiple-policies
[disable-injection]: https://learn.microsoft.com/powershell/module/microsoft.powerplatform.enterprisepolicies/disable-subnetinjection?view=pa-ps-latest
[enable-injection]: https://learn.microsoft.com/powershell/module/microsoft.powerplatform.enterprisepolicies/enable-subnetinjection?view=pa-ps-latest
[fabric-allowlist]: https://learn.microsoft.com/fabric/security/fabric-allow-list-urls
[fabric-service-tags]: https://learn.microsoft.com/fabric/security/security-service-tags
[managed-environments]: https://learn.microsoft.com/power-platform/admin/managed-environment-overview
[power-bi-allowlist]: https://learn.microsoft.com/fabric/security/power-bi-allow-list-urls
[vnet-overview]: https://learn.microsoft.com/power-platform/admin/vnet-support-overview
[vnet-setup]: https://learn.microsoft.com/power-platform/admin/vnet-support-setup-configure
[vnet-troubleshooting]: https://learn.microsoft.com/troubleshoot/power-platform/administration/virtual-network
[warehouse-connectivity]: https://learn.microsoft.com/fabric/data-warehouse/connectivity
