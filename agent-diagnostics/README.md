# Agent Diagnostics

Small, independent PowerShell probes for HTTPS, MCP tool discovery, Azure AI
Search retrieval, and offline response-boundary review. They do not change the
existing subnet validator or VNet injection toggle and do not deploy resources.

## Start Offline

Requires Windows PowerShell 5.1 or PowerShell 7 and .NET HTTP support. No extra
modules or sign-in are required for local tests:

```powershell
& ./agent-diagnostics/tests/Test-AgentDiagnostics.ps1
Import-Module ./agent-diagnostics/AgentDiagnostics.psm1 -Force
Get-AgentResponseAssessment -ToolInvoked Yes -BackendOutcome Success `
  -AgentOutput Content -ChannelOutput Empty
```

The example produces `REVIEW_CHANNEL_DELIVERY`, a review pointer, not a diagnosed
root cause. Unknown or contradictory observations remain inconclusive.

## Choose a Probe

| Function                      | Requests                                                   | Proves only                                                                     |
| ----------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `Test-AgentHttpsEndpoint`     | GET to the supplied endpoint                               | Whether an HTTP response was received; a successful HTTPS exchange includes TLS |
| `Test-AgentMcpServer`         | Initialize, initialized notification, paginated tools/list | Whether this bounded client can discover tools                                  |
| `Test-AgentSearchIndex`       | Search POST, projecting only the key field                 | Whether a chosen key appears in the top results of one text query               |
| `Get-AgentResponseAssessment` | None                                                       | Which boundary to review given operator-supplied observations                   |

**Before any service request:** obtain endpoint-owner approval, confirm the
execution host and approved read-only operation, and use synthetic inputs.
Even GET and MCP discovery can produce service logs, cost, or server-side effects.
No utility acquires a token or changes environment configuration.

## Later Service Checks

These examples are instructions for an approved later run, not part of local
validation. Replace placeholders in memory, outside this public working tree.
An operator supplies the correct endpoint, authorization headers, permissions,
and any required proxy configuration. Use the service's supported authentication;
never disable authentication, certificate validation, or network controls.

```powershell
$endpoint = [uri](Read-Host 'Approved full HTTPS endpoint')
$headers = @{}
Test-AgentHttpsEndpoint -Endpoint $endpoint -Headers $headers
Test-AgentMcpServer -Endpoint $endpoint -Headers $headers
```

Populate `$headers` from an approved in-memory credential source if required.
Do not type credentials into command history, put them in a URI, use transcription,
or store them in the repository. Headers are not emitted in assessment objects.
The full MCP endpoint can include a path; query strings, fragments, and embedded
credentials are rejected. Redirects are not followed and cookies are disabled.
Normal certificate validation and revocation checking remain enabled.

### Optional MCP Invocation

Discovery does **not** call a tool. Calling one requires both `-AllowToolCall`
and `-ToolName`, followed by confirmation:

```powershell
Test-AgentMcpServer -Endpoint $endpoint -Headers $headers `
  -AllowToolCall -ToolName '<approved-tool-name>' -ToolArguments @{} -WhatIf
```

`-WhatIf` still performs initialization and discovery; it suppresses **only**
the tool call. Remove it only after approving the exact tool, arguments, identity,
and possible effects. Do not rely on a tool name or read-only annotation as a
security control. No tool call is retried automatically.

This is a smoke probe pinned to protocol `2025-03-26`, not a general MCP SDK or
conformance validator. It negotiates that version, propagates the session header,
requires a `202` initialized acknowledgement, and accepts JSON or Streamable HTTP
SSE responses. It stops on another negotiated version. It does not implement
legacy standalone SSE, OAuth negotiation, server-initiated request handling,
resumability, or DELETE session cleanup. The server may retain a session until
expiry. Use a full MCP client for those requirements. See the
[transport](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
and [lifecycle](https://modelcontextprotocol.io/specification/2025-03-26/basic/lifecycle)
contracts. Copilot Studio transport and authentication must also match its
[current MCP integration requirements](https://learn.microsoft.com/microsoft-copilot-studio/mcp-add-existing-server-to-agent).

### Known-Document Search

Use the **service root**, an existing index, a retrievable key field, and a
synthetic document with an agreed expected key:

```powershell
Test-AgentSearchIndex -Endpoint '<approved-search-service-root>' `
  -IndexName '<existing-index>' -Headers $headers -SearchText '<synthetic-query>' `
  -KeyField '<retrievable-key-field>' -ExpectedKey '<expected-document-key>'
```

This uses the documented
[Search POST API, version 2024-07-01](https://learn.microsoft.com/rest/api/searchservice/documents/search-post?view=rest-searchservice-2024-07-01)
with `search`, `select`, and `top`. The default top is 5, configurable from 1 to 50.
A missing key means **not in these top results**, not absent from the index.
It does not test vector search, semantic ranking, ingestion, content correctness,
agent grounding, or Copilot Studio's connection identity. Validate the separate
[Copilot Studio Search knowledge configuration](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-azure-ai-search)
when that is the actual integration path.

## Read Results Carefully

Each call returns an object with `Kind`, `ObservedUtc`, `ExecutionLocation`,
`LocationVerified`, `Status`, `Gates`, and `ApplicationAcceptance`.

- Gate statuses: `PASSED`, `FAILED`, `INCONCLUSIVE`, or `NOT_TESTED`.
- Aggregate: failed gate wins; otherwise skipped or inconclusive gates make the
  aggregate inconclusive. Successful discovery alone is therefore inconclusive
  because invocation was deliberately not tested.
- An HTTPS `401` can prove transport while failing the HTTP endpoint gate.
  DNS, TCP, and TLS are not timed or diagnosed independently.
- Default request timeout is 20 seconds (1-120 configurable), response body limit
  is 1 MiB, and MCP list pagination is capped at 5 pages (1-20 configurable).
  Timeout is per request, not the whole multipage assessment.
- `ExecutionLocation` is self-reported: `Workstation`, `AzureHost`,
  `PowerPlatformRuntime`, or `Unknown`. `LocationVerified` is always false.
  A workstation pass does not prove a platform runtime's identity or network path.
- Nonempty tool content is not proof of correct or authorized data.
  `ApplicationAcceptance` always remains `NOT_TESTED`; verify the real agent and
  published channel separately using the intended user identity.
- Configuration errors throw. Service failures return structured gates; they do
  not set a process exit code. CI callers must explicitly evaluate the result.

No response payloads, endpoints, credentials, or request IDs are included in
returned assessments. Do not add raw response logging. Keep any separately
collected evidence only in the approved private evidence system.

## Local Verification

The standalone suite uses in-memory mocks and a TCP loopback HTTP fixture only.
`-AllowLoopbackHttp` is exclusively for these local synthetic checks; HTTPS stays
mandatory for remote endpoints. The suite covers response review, RPC ID matching,
SSE parsing, discovery and optional call handling, Search key selection, unsafe
URIs, unauthorized responses, redirects, malformed bodies, response limits, and
timeouts. It is not live service, TLS interoperability, or deployment validation.

Before public release, follow [contribution review](../CONTRIBUTING.md), including
the feature proposal and a current protocol/API compatibility review.
