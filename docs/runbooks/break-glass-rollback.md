# Break-glass rollback

Use this when an incident cannot wait for a pull request and an apply: users are getting errors or
wrong answers from modern, and all traffic must go back to legacy now.

It needs no AWS CLI and no console. The design (§7) assumed a person with an admin role running
`aws elbv2` commands; here the same change is a GitHub Actions workflow behind the `dev`
environment's reviewer, so the person who can approve a deploy can roll back (ADR-0028).

## Do it

1. In `shiptrack-platform`, open **Actions**, then **rollback-cutover**, then **Run workflow**, on
   `dev`.
2. Give a one-line **reason**. The run page is public, so no addresses and no identifiers.
3. Leave **dry_run** off. (Turn it on to see what would change and change nothing; use it to
   rehearse.)
4. Approve the `dev` environment when the run waits.

It takes about a minute. The run summary lists, for the default action and each weighted rule, the
weights before and after, and ends with `all weighted routing is legacy 100, modern 0`. If it ends
any other way, treat the rollback as not done.

## What it changes, and what it does not

Changes: the weights of every ALB rule and listener default action that forwards to both target
groups: the UI rule (priority 90), the track rule (priority 100), and the listener's default action.
Stickiness settings are kept; only weights are rewritten.

Does not change:

- the header rules for tests (priorities 10 and 20), or the preview listener on port 8080
- Terraform state, so `var.cutover` and the ALB now disagree
- modern's pods, workers, or queues: keep the workers running until the events queue drains
  (modern design §9.2)
- the database schema or any data. After wave 3 step 4 (the contract migration) there is no way
  back to legacy, and this workflow is not a way around it.

## Afterwards, within 24 hours

The nightly `check-drift.yml` reports the difference as an issue titled "Drift detected: platform/dev"
until it is reconciled (design risk R-06). Open a pull request that sets the weights in
`terraform/envs/dev/terraform.tfvars` to what the ALB now has:

```diff
 cutover = {
-  track   = { legacy = <was>, modern = <was> }
-  default = { legacy = <was>, modern = <was> }
+  track   = { legacy = 100, modern = 0 }
+  default = { legacy = 100, modern = 0 }
 }
```

Its plan should show no changes: the ALB already matches. Merge it, and the drift issue closes
itself on the next clean nightly plan. Then write the incident record below.

## If GitHub Actions is unavailable

`scripts/rollback-cutover.sh` is the same code. Anyone with credentials that can modify the ALB can
run it with `AWS_REGION` set (add `DRY_RUN=true` first to see the change). No such credential is
kept on a workstation by design, so this is for an account administrator, not the normal path.

## Rehearse it

Run the workflow with **dry_run** on before wave 1, from `dev`, and confirm the summary lists the
two weighted rules and the default action. Do it again after any change to the ingress module.

## Incident record

Store in `shiptrack-modern` under `docs/migration/`, scrubbed of addresses and identifiers.

```markdown
## Rollback <date>

- Started by: <person>, run <link>
- Trigger: <alarm or symptom, and the step in progress>
- Weights before: track <l/m>, default <l/m>
- Time from decision to confirmed rollback: <minutes>
- Reconciling pull request: <link>
- Cause: <known | unknown yet>
- Follow-up: <issues or pull requests>
```
