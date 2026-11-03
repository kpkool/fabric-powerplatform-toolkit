# Private Search Agent Network Preparation

**Design worksheet, not deployment instructions.** Use this guide to prepare an
isolated Copilot Studio reference lab with private Azure AI Search. An App Service
MCP host is optional. This is not a production availability design or proof that a
particular private MCP connector configuration works. Verify against current
Microsoft Learn documentation before implementation.

## Information to Confirm

Keep completed values and evidence in approved private storage, not this repo.

| Input                   | Required decision or evidence                                                                  | Owner                     |
| ----------------------- | ---------------------------------------------------------------------------------------------- | ------------------------- |
| Scope                   | Tenant, subscription, isolated resource group, naming and tags                                 | Azure owner               |
| Environment             | Dedicated Power Platform environment, geography, Managed Environment and licensing eligibility | Power Platform owner      |
| Regional mapping        | Every Azure region required for that environment geography                                     | Power Platform owner      |
| Existing infrastructure | Reuse versus create; existing policy, VNet, DNS, firewall and route owners                     | Network owner             |
| Address plan            | Nonoverlapping VNet/subnet ranges, equal PP subnet capacity, growth allowance                  | IPAM owner                |
| DNS                     | Azure-provided or custom DNS; zone ownership, links and forwarding paths                       | DNS owner                 |
| Connectivity            | Reachable paths from every required runtime region and deployment runner                       | Network owner             |
| Security                | Connector/harness, authentication on each hop, DLP, least-privilege roles                      | Security and agent owners |
| Operations              | Budget ceiling, duration, maintenance window, rollback and cleanup owner                       | Lab owner                 |

Managed Environment status and regional mapping are documented requirements.
For a United States geography, the current setup guide requires `eastus` and
`westus`, including nonproduction. Confirm the actual environment geography;
do not substitute preferred demo regions. Size both delegated subnets using
Microsoft's workload guidance, not an arbitrary sample CIDR.
[Power Platform setup](https://learn.microsoft.com/power-platform/admin/vnet-support-setup-configure)
and [sizing guidance](https://learn.microsoft.com/power-platform/admin/vnet-support-overview#estimating-subnet-size-for-power-platform-environments).

## Proposed Network Roles

| Role                     | Placement and boundary                                                                                                                  | Stage                                   |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| Power Platform egress    | Dedicated subnet in each required regional VNet; delegate to `Microsoft.PowerPlatform/enterprisePolicies`; no app or PE placement there | Foundation                              |
| Private Endpoint subnet  | Separate, nondelegated subnet; reserve capacity for approved service bindings                                                           | Foundation                              |
| App outbound integration | Only if App Service MCP is selected: separate dedicated subnet, delegated to `Microsoft.Web/serverFarms`, in the app's region           | Optional extension                      |
| Enterprise policy        | References the approved PP regional subnets; environment association is a separate change                                               | Foundation, then controlled association |
| Search query PE          | Bind to the actual Search service (`searchService`) after it exists; DNS zone group references the approved zone                        | Service binding                         |
| App inbound PE           | Only if private App Service ingress is selected; not its outbound integration subnet                                                    | Optional service binding                |

Power Platform delegation and policy association follow the
[setup requirements](https://learn.microsoft.com/power-platform/admin/vnet-support-setup-configure).
App Service integration provides **outbound** connectivity, not inbound isolation;
its PE is a separate **inbound** path and cannot use the integration subnet.
See [integration](https://learn.microsoft.com/azure/app-service/overview-vnet-integration)
and [Private Endpoints](https://learn.microsoft.com/azure/app-service/networking/private-endpoint).

**Proposed design:** start with direct Search retrieval. Reserve the optional app
subnet only after host selection; do not purchase a host just to justify MCP.
Search remains an Azure service outside the VNet; its PE network interface is in
the VNet. Private Search needs Basic or higher, not Free.
[Search Private Endpoint guidance](https://learn.microsoft.com/azure/search/service-create-private-endpoint).

## DNS and Routing Worksheet

| Consumer and destination       | Client hostname               | Private DNS zone                    | Required evidence                                          |
| ------------------------------ | ----------------------------- | ----------------------------------- | ---------------------------------------------------------- |
| PP runtime to Search           | `<search>.search.windows.net` | `privatelink.search.windows.net`    | Expected PE IP from every configured PP region             |
| Optional MCP host to Search    | Same Search hostname          | Same approved Search zone           | Expected PE IP and successful retrieval from app runtime   |
| Optional client to App Service | `<app>.azurewebsites.net`     | `privatelink.azurewebsites.net`     | Expected app PE IP, TLS hostname and authenticated request |
| Private app deployment runner  | `<app>.scm.azurewebsites.net` | Same app zone, including SCM record | Runner can deploy without opening public app ingress       |

Use the normal service hostname for TLS, not a raw IP or the `privatelink`
hostname. Search and App Service DNS behavior is documented in their respective
[Search](https://learn.microsoft.com/azure/search/service-create-private-endpoint)
and [App Service](https://learn.microsoft.com/azure/app-service/networking/private-endpoint#dns)
guides. Link zones to the approved consumer VNets when using Azure DNS; with
custom DNS, design forwarding through a reachable resolver. A zone link does
not create network reachability. App Service follows the VNet's DNS settings.
[DNS integration](https://learn.microsoft.com/azure/app-service/overview-vnet-integration#private-endpoints).

**Design decisions still required:** regional PE placement versus approved
cross-region private routes; peering/hub transit; central zone reuse; deployment
runner location. Prefer the existing DNS authority rather than duplicate zones.
Do not assume VNet peering or DNS forwarding already exists.

Record an explicit egress matrix: source subnet/runtime, destination FQDN or
approved tag, protocol/port, purpose, route, policy owner and test. Include HTTPS
to the selected backend, DNS to the chosen resolver, authentication, certificate
validation, deployment/build dependencies and telemetry as applicable. Avoid a
blanket deny or broad allowlist until dependencies are established. App Service
NSG/UDR enforcement depends on which traffic is routed through integration.
[Routing and dependencies](https://learn.microsoft.com/azure/app-service/overview-vnet-integration#routes).

NAT, firewall, Private Resolver and APIM are conditional design choices, not a
mandatory shopping list. For required public calls, approve an explicit outbound
path; Power Platform setup documents NAT for public internet access. NAT is not
an inspection firewall. Do not add a default route to an unavailable appliance.
[Power Platform setup](https://learn.microsoft.com/power-platform/admin/vnet-support-setup-configure).

## Delivery Gates

1. **Approve design:** scope, regional mapping, address plan, DNS authority,
   selected resource list, identity, budget and private evidence location. No
   inventory or deployment is implied by completing this worksheet.
2. **Prepare IaC:** parameterized Bicep, no secrets, references for reused
   resources, local compilation and security scan. Review an incremental
   deployment preview before granting permission to apply.
3. **Establish foundation:** approved networks, subnet roles, routing, DNS zones
   and links, enterprise policy. Validate actual provisioned configuration.
   Associate only the isolated environment in an approved change window.
4. **Bind services:** create the approved synthetic Search service, query PE and
   DNS zone group together with public network access disabled. PE creation
   requires a real service target; it is not a prerequisite that can be completed
   before the target exists. Provision private administration access first.
5. **Accept networking:** from every required PP region, verify DNS returns the
   expected PE address, TCP 443, TLS and diagnostic source placement. Repeat
   relevant checks from the deployment runner and optional host. Verify public
   network access is disabled and an outside-path request is denied; DNS failure
   alone is not sufficient. Record an identity-authorized query separately.
6. **Accept application:** only after network prerequisites pass, configure the
   agent and verify one expected synthetic answer, citation and published-channel
   result. Test unauthorized identity, empty/error handling and a bounded load.
   Add MCP only with a separately accepted exact connector/auth/private path.

Power Platform enable/disable can cause up to 30 minutes of unavailability or
instability. Don't resize active delegated subnets or alter shared DNS as an
incidental lab change. Rollback must restore the prior approved association and
network configuration, not blindly disable a shared environment.
[Change considerations](https://learn.microsoft.com/power-platform/admin/vnet-support-setup-configure).

## Available Checks

Run the local checker from the repository root; it does not install, import
modules, invoke Azure CLI, authenticate, inspect credentials, or send requests:

```powershell
$report = & ./delegated-subnet-validator/Test-NetworkPreparationPrerequisites.ps1
$report.Checks | Format-Table Name, Available, Purpose -Wrap
$report | Select-Object AllListedToolsFound, CloudReadiness, ApplicationAcceptance
```

This checks discoverability only, not versions, executable health, licensing,
permissions, quotas, policy, or configuration. Standalone `bicep` is optional if
the later workflow uses Azure CLI-managed Bicep; a missing check is not by itself
a deployment blocker. Missing tools are reported, never installed automatically.

After separately approved cloud access, use the existing
[regional runtime validator](../../delegated-subnet-validator/README.md) with the
actual full Search FQDN and port `443`, and the
[agent probes](../../agent-diagnostics/README.md) for retrieval and MCP evidence.
These are separate gates, not a single end-to-end pass. Diagnostic runs can create
service-side diagnostic execution and private local evidence; they are not offline.
