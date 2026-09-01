# Fabric and Power Platform Toolkit

Public PowerShell tools for Microsoft Fabric and Power Platform networking.
Examples are parameterized and contain no customer-specific identifiers.

## Tools

| Tool                                                               | Mode           | Purpose                                                                              |
| ------------------------------------------------------------------ | -------------- | ------------------------------------------------------------------------------------ |
| [Delegated subnet validator](delegated-subnet-validator/README.md) | Read-only      | Test Power Platform regional DNS, TCP, TLS, and delegated-subnet source placement    |
| [VNet injection toggle](vnet-injection-toggle/README.md)           | State-changing | Show, enable, or disable the enterprise-policy link for a Power Platform environment |

Start with the read-only validator. Use the toggle only for an approved change,
maintenance operation, or controlled A/B test with a rollback plan.

## Privacy

The source contains no customer IDs, endpoints, credentials, or evidence. Runtime
output can contain tenant, environment, network, endpoint, IP, and correlation
data. Store it only in an approved location and never commit it to this public
repository.

## License

Licensed under the [Apache License 2.0](LICENSE).
