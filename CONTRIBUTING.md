# Contributing

Contributions that make Fabric and Power Platform connectivity safer, clearer,
or easier to validate are welcome.

## Before You Start

- Check existing issues and pull requests for overlapping work.
- Open a feature request before making a large design or behavioral change.
- Keep examples reusable and parameterized.
- Ground Microsoft product requirements in current Microsoft Learn
  documentation and link the source next to the claim.
- Keep Azure implementation examples CLI-first.

## Public Data Rules

This is a public repository. Never include:

- Tenant, subscription, environment, workspace, policy, VNet, or subnet IDs.
- Customer names, domains, endpoint hostnames, IP addresses, or CIDRs.
- User names, email addresses, service-principal IDs, or connection references.
- Access tokens, secrets, credentials, certificates, or connection strings.
- Query results, firewall logs, screenshots, transcripts, or diagnostic evidence.
- Microsoft support, activity, request, conversation, or correlation IDs.

Replace values with descriptive placeholders such as `<tenant-guid>` or
`<complete-warehouse-fqdn>`. Redact locally before attaching any artifact. The
repository's ignore rules are a guardrail, not permission to store sensitive
files in the working tree.

Use [SECURITY.md](SECURITY.md) for a suspected vulnerability. Do not open a
public issue for security-sensitive details.

## Repository Boundaries

- The delegated-subnet validator is read-only.
- The VNet injection toggle changes an environment only for `Enable` and
  `Disable`, and those actions must retain confirmation and `-WhatIf` support.
- The toolkit does not deploy customer VNets, subnets, enterprise policies,
  firewalls, Fabric items, or Copilot Studio agents.
- Network success must remain separate from connector identity and application
  acceptance.
- Examples must not imply that TCP success proves SQL authentication or data
  authorization.

## Make a Change

1. Fork or clone the repository and create a focused branch.
2. Change only the behavior or documentation needed for the issue.
3. Preserve Windows PowerShell 5.1 and PowerShell 7 compatibility.
4. Add deterministic errors and structured outcomes for script behavior.
5. Update the relevant README when parameters, outputs, requirements, or proof
   boundaries change.
6. Validate locally without using a production or customer environment.

## Local Validation

From the repository root, parse every PowerShell script without executing it:

```powershell
$parseErrors = @()

Get-ChildItem -Recurse -Filter '*.ps1' | ForEach-Object {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $_.FullName,
    [ref]$tokens,
    [ref]$errors
  ) | Out-Null
  $parseErrors += $errors
}

if ($parseErrors.Count -gt 0) {
  $parseErrors | Format-List
  throw 'PowerShell parsing failed.'
}
```

Run Markdown lint and Git whitespace validation:

```powershell
npx --yes markdownlint-cli2 '**/*.md'
git diff --check
```

Review the complete diff for customer data and secrets before committing. Do not
test `Enable` or `Disable` against a live environment solely to validate a code
change.

## Pull Requests

Keep the pull request concise and include:

- The problem and user-visible outcome.
- The proof boundary: what the change does and does not validate.
- Local validation commands and results.
- Current official sources for changed Microsoft requirements.
- A statement confirming that no customer or secret data is included.

Maintainers may ask for smaller scope, stronger evidence, safer defaults, or
additional documentation before merging.
