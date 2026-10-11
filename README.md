# shiptrack-platform

The shared, long-lived infrastructure of the ShipTrack EC2-to-EKS migration, and the control point
for the cutover: the ALB weights that move traffic between `shiptrack-legacy` and
`shiptrack-modern`. It also holds the validation tooling that defines "correct" for both stacks.

- Design: [`docs/DESIGN.md`](docs/DESIGN.md)
- Decisions: [`docs/ADR.md`](docs/ADR.md)
- First-time setup, including the manual OIDC provider and seed role: [`bootstrap/README.md`](bootstrap/README.md)
- Database bootstrap: [`db/RUNBOOK-db-bootstrap.md`](db/RUNBOOK-db-bootstrap.md)
- Findings register: [`docs/security/findings-register.md`](docs/security/findings-register.md)

Nothing is applied from a workstation. Every AWS change is a GitHub Actions workflow that assumes
an OIDC role, with a reviewer approving each apply. This repository is public, so no account ID, ALB
address, host ID, or secret value is committed (design §6.12); `scrub.yml` fails a pull request that
adds one.

## The other repositories

| Repository | Role |
|---|---|
| [`shiptrack-legacy`](https://github.com/loriamichaelj/shiptrack-legacy) | The "before" stack: a FastAPI app on EC2 behind this ALB, with deliberate anti-patterns |
| [`shiptrack-modern`](https://github.com/loriamichaelj/shiptrack-modern) | The "after" stack: the same API on EKS, fixing each anti-pattern |

Both read what this repository publishes through the SSM contract under `/shiptrack/platform/`
(`terraform/modules/contract`). They never read this repository's Terraform state.

## Layout

| Path | What it holds |
|---|---|
| `bootstrap/` | State bucket, state key, the workload permission boundary, and the nine pipeline roles. Applied only by `bootstrap-apply.yml` |
| `terraform/modules/` | `network`, `kms`, `database`, `storage`, `ingress`, `observability`, `contract`, `security-services` |
| `terraform/envs/dev/` | The environment that wires the modules together |
| `db/` | `bootstrap.sql` (database, roles, schema) and its runbook |
| `validation/simulator/` | The carrier event simulator: creates shipments, sends lifecycles with duplicates and out-of-order events, and records a ledger |
| `scripts/` | `terraform-ci.sh`, the plan and apply wrapper that masks identifiers in logs |

## Workflows

| Workflow | Runs | Does |
|---|---|---|
| `bootstrap-apply.yml` | by hand, `bootstrap` environment | Creates the state bucket on the first run, then the boundary and roles |
| `terraform-pr.yml` | pull requests | Format, validate, tflint, Checkov, Trivy, and a plan comment with addresses and actions only |
| `terraform-apply.yml` | push to `dev`, or by hand, `dev` environment | Plans and applies `terraform/envs/dev`; a reviewer approves each run |
| `scrub.yml` | pull requests | gitleaks plus rules for account IDs and ALB DNS names |
| `simulator-ci.yml` | pull requests touching the simulator | Lint and tests |
| `inspect-account.yml` | by hand | Read-only list of the account's security services by name and status |
| `unlock-state.yml` | by hand, `dev` environment | Removes a stale state lock, given its ID. Refuses a lock with another ID or one younger than 30 minutes (ADR-0025) |

## Opening both UIs side by side

The ALB's address serves legacy: the weighted rules send all traffic to it until the cutover moves
weights. To open the modern UI beside it without the test-routing headers, set the `PREVIEW_CIDRS`
repository variable to a JSON list of the addresses that may reach it, for example
`["203.0.113.7/32"]`, and run `terraform-apply`. That adds a listener on port 8080 that forwards
everything to modern. Then:

- legacy: `http://<ALB address>/ui/`
- modern: `http://<ALB address>:8080/ui/`

The variable is not committed, because it names a person's address. Left unset, nothing is created,
and `0.0.0.0/0` is refused. The listener is outside the cutover weights (ADR-0026). Unset the
variable and apply to remove it.

## Status

| Phase | State |
|---|---|
| P0 Bootstrap | Done and applied |
| P6a Terraform workflows | Done and in use |
| P6 scrub and local checks | Done: `scrub.yml`, `.gitleaks.toml`, `.pre-commit-config.yaml`, `.tflint.hcl`, `.checkov.yaml` |
| P1 Network and KMS | Done and applied |
| P2 Database | Done and applied; the database is bootstrapped (see the runbook) |
| P3 Storage and ingress | Done and applied; weights are 100% legacy, 0% modern |
| P5 Observability and contract | Done and applied |
| P4 Security services | Partly applied. Config is adopted and recording; Inspector EC2 scanning is stuck enabling, and a few resources are still pending (ADR-0022) |
| P6b Drift and validation workflows | Not on `dev`. Written on a branch and deferred; `drift.yml`, `validation.yml`, `validation-ci.yml` |
| P7 Validation tooling | The simulator is on `dev` and has seeded the legacy stack. The contract suite and k6 scenarios are on the P6b branch, not on `dev` |
| P8 Runbooks | Not started; written after the builds are complete |

## Local checks

These need no AWS credentials.

```sh
terraform fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false && terraform -chdir=terraform/envs/dev validate
for m in terraform/modules/*/; do terraform -chdir="$m" init -backend=false && terraform -chdir="$m" test; done   # offline plan tests
tflint --recursive
checkov --config-file .checkov.yaml -d terraform   # one -d per run: repeated -d scans only the first
actionlint
```

`bootstrap/tests/moto.sh` runs the real bootstrap script against a moto server. `db/tests/bootstrap.sh`
runs `bootstrap.sql` twice against a throwaway PostgreSQL 17 container (it needs Docker) and checks
that the second run changes nothing.
