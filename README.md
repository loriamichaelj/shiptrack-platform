# shiptrack-platform

The shared, long-lived infrastructure of the ShipTrack EC2-to-EKS migration, and the control point
for the cutover: the ALB weights that move traffic between `shiptrack-legacy` and
`shiptrack-modern`. It also holds the validation tooling (API contract tests, k6 load tests, the
carrier event simulator) that defines "correct" for both stacks.

- Design: [`docs/DESIGN.md`](docs/DESIGN.md)
- Decisions: [`docs/ADR.md`](docs/ADR.md)
- First-time setup, including the manual OIDC provider and seed role: [`bootstrap/README.md`](bootstrap/README.md)

Nothing is applied from a workstation. Every AWS change is a GitHub Actions workflow that assumes
an OIDC role, with a reviewer approving each apply.

## Status

| Phase | State |
|---|---|
| P0 Bootstrap | `bootstrap/` and `bootstrap-apply.yml` |
| P6a Terraform workflows | `terraform-pr.yml`, `terraform-apply.yml` |
| P6 scrub and local checks | `scrub.yml`, `.gitleaks.toml`, `.pre-commit-config.yaml` |
| P1 Network and KMS | `terraform/modules/network`, `terraform/modules/kms`, `terraform/envs/dev` |
| P2 Database | `terraform/modules/database`, `db/bootstrap.sql`, `db/RUNBOOK-db-bootstrap.md` |
| P3 Storage and ingress | `terraform/modules/storage`, `terraform/modules/ingress` |
| P4, P5, P6b, P7, P8 | not started |
