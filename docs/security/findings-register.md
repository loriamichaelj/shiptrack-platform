# Findings register

One register per repository, in the same format in all three. Every CRITICAL and HIGH finding has an
owner and a disposition. Findings come from Security Hub CSPM, GuardDuty, Inspector, IAM Access
Analyzer, and the out-of-band scans (Trivy, Checkov, pip-audit, gitleaks).

Do not put account IDs, ARNs, DNS names, or host and instance IDs in this file; use placeholders such
as `<ACCOUNT_ID>` and `<ALB_DNS>` (platform design §6.12).

| ID | Source | Resource | Severity | Owner (platform/legacy/modern) | Disposition (remediate / accepted-legacy-AP / false-positive / risk-accepted) | Ticket | Due |
|---|---|---|---|---|---|---|---|
