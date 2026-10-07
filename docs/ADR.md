# ShipTrack Platform — Architecture Decision Log

Decisions are recorded here, oldest first. Each entry has a status (Planned, Accepted, Superseded) and, once decided, Context, Decision, and Consequences. Entries marked Planned are decisions the design expects to be made during the build.

| # | Title | Status |
|---|---|---|
| 0001 | `security-hub-cspm-scope` | Planned |
| 0002 | `test-routing-header-token` | Planned |
| 0003 | `plan-role-secret-access` | Planned |
| 0004 | `nat-vs-interface-endpoints` | Planned |
| 0005 | `seed-role-and-bootstrap-workflow` | Planned |
| 0006 | `public-repositories` | Planned |
| 0007 | `dev-branch-and-environment` | Planned |

## ADR-0001: security-hub-cspm-scope

**Status:** Planned

**Records:** Security Hub CSPM in scope; the unified Security Hub (GA December 2025) out of scope (design §6.7).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0002: test-routing-header-token

**Status:** Planned

**Records:** Header + token routing instead of a source-IP condition (design §6.6, R-04).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0003: plan-role-secret-access

**Status:** Planned

**Records:** Plan-role access to the DB secrets, its trust surface, and the outcome of the [VERIFY] (design §6.1, R-09).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0004: nat-vs-interface-endpoints

**Status:** Planned

**Records:** O-P1 decision, made from measured data.

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0005: seed-role-and-bootstrap-workflow

**Status:** Planned

**Records:** Manual OIDC provider and seed role, the state-bucket seeding flow, and the plan to narrow or retire the AdministratorAccess seed role (design §6.1, R-10).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0006: public-repositories

**Status:** Planned

**Records:** Public repos, the §6.12 rules, and residual exposure (R-11).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0007: dev-branch-and-environment

**Status:** Planned

**Records:** Development runs on the `dev` branch and `dev` environment; the design's former `main`/`prod` names were replaced with `dev`.

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_
