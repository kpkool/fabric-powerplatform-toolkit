# Repository Navigation Index

Updated 2026-11-02 against base `11d35601e902bccd90a5b9e07b197078dc687a58`
plus local additions: `agent-diagnostics/` and this index. No paths deleted.

## Owning Areas

| Area                    | Entry Point                                                             | Boundary                                                 |
| ----------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------- |
| Fabric SQL connectivity | [Setup guide](../docs/setup/managed-environment-to-fabric-warehouse.md) | Power Platform to Warehouse/Lakehouse public TDS         |
| Regional network checks | [Validator](../delegated-subnet-validator/README.md)                    | Read-only DNS/TCP/TLS/source-placement validation        |
| Policy association      | [Toggle](../vnet-injection-toggle/README.md)                            | Status or confirmed Enable/Disable                       |
| Agent probes            | [Diagnostics](../agent-diagnostics/README.md)                           | Independent HTTPS/MCP/Search and offline response review |
| Public contributions    | [Contributing](../CONTRIBUTING.md), [security](../SECURITY.md)          | No customer data, identifiers, credentials, or evidence  |

## Navigation and Checks

- Start with the owning README. No common deployment engine exists.
- Agent module exports four probes; HTTP and protocol helpers are private.
  Its test script uses only mocks and loopback HTTP. Run it in PowerShell 5.1
  and 7; parse both `.ps1` and `.psm1` files.
- Run Markdown lint and `git diff --check` per the contribution guide.
- Agent smoke checks never establish application acceptance or execution location.
- Existing network validator and toggle are independent and unchanged by the
  agent utility addition. Customer discovery notes belong outside this repo.
- Network preparation (2026-11-02): [customer-neutral worksheet](../docs/setup/private-search-agent-network-preparation.md)
  and `delegated-subnet-validator/Test-NetworkPreparationPrerequisites.ps1`.
  The new script discovers local tools only, with no cloud calls or installation.
  Networking deployment is outside this toolkit's scope. Two files added; none
  deleted. Existing uncommitted agent diagnostics and root README preserved.
