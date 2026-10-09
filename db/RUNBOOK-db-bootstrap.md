# Runbook: bootstrap the ShipTrack database

Run this once after the platform database is applied and before the first legacy deploy. It creates
the `shiptrack` database, the `shiptrack_migrator` and `shiptrack_app` roles, and the `shiptrack`
schema. It is the only manual database step. It is safe to run again, and running it again with new
secret values is how a rotated password reaches the database.

The database is private, and GitHub-hosted runners cannot reach it. There are two ways to run it:

- **The `db-bootstrap` workflow in `shiptrack-legacy`** (the route used in this account, which has no
  CloudShell). It dispatches an SSM document to one legacy host, which fetches this repository's
  `db/bootstrap.sql` at a commit the workflow pins and checks against a SHA-256, reads the three
  secrets itself, and runs the SQL. Nothing secret passes through the workflow. See legacy ADR-0011.
  Run it after the first legacy `terraform-apply` and before the first deploy.
- **An AWS CloudShell VPC environment**, below, where CloudShell is available. No bastion host is
  needed.

Both run the same SQL and end with the same checks.

Variables used below. Set them to your values; none of them belong in a committed file.

| Variable | Value |
|---|---|
| `AWS_REGION` | the platform region |
| `DB_HOST` | `rds_endpoint` from the SSM contract: `aws ssm get-parameter --name /shiptrack/platform/rds_endpoint --query Parameter.Value --output text` |
| `MASTER_SECRET_ARN` | the RDS-managed master secret (Terraform output `master_secret_arn`) |
| `MIGRATOR_SECRET_ARN`, `APP_SECRET_ARN` | `db_migrator_secret_arn` and `db_app_secret_arn` from the SSM contract |

## 1. Open a CloudShell VPC environment

1. In the console, open CloudShell and choose **Create VPC environment**.
2. Select the platform VPC, one **private-app** subnet, and the `shiptrack-db-client` security
   group. That group is the only one the database accepts connections from.
3. Wait for the environment to start.

## 2. Install the client and the RDS certificate bundle

```sh
sudo dnf install -y postgresql17
curl -fsSLo /tmp/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

## 3. Fetch the passwords into shell variables

The commands print nothing. Do not `echo` the variables or turn on `set -x`.

```sh
set +o history
MASTER_USER=$(aws secretsmanager get-secret-value --secret-id "$MASTER_SECRET_ARN" --query SecretString --output text | jq -r .username)
export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$MASTER_SECRET_ARN" --query SecretString --output text | jq -r .password)
MIGRATOR_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$MIGRATOR_SECRET_ARN" --query SecretString --output text | jq -r .password)
APP_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_ARN" --query SecretString --output text | jq -r .password)
```

## 4. Run the script

Get `bootstrap.sql` into the environment (clone this repository, or upload the file), then:

```sh
psql "host=$DB_HOST port=5432 dbname=postgres user=$MASTER_USER sslmode=verify-full sslrootcert=/tmp/rds-global-bundle.pem" \
  -v ON_ERROR_STOP=1 \
  -v migrator_password="$MIGRATOR_PASSWORD" \
  -v app_password="$APP_PASSWORD" \
  -f db/bootstrap.sql
```

A second run prints `schema "shiptrack" already exists, skipping` and nothing else.

## 5. Verify

```sh
psql "host=$DB_HOST port=5432 dbname=shiptrack user=$MASTER_USER sslmode=verify-full sslrootcert=/tmp/rds-global-bundle.pem" <<'SQL'
\du shiptrack_*
SELECT schema_name, schema_owner FROM information_schema.schemata WHERE schema_name = 'shiptrack';
SELECT has_schema_privilege('shiptrack_app', 'shiptrack', 'USAGE')  AS app_can_use,
       has_schema_privilege('shiptrack_app', 'shiptrack', 'CREATE') AS app_can_create;
SHOW max_connections;
SQL
```

Expect both roles listed with their connection limits (150 and 200), the schema owned by
`shiptrack_migrator`, `app_can_use = t`, and `app_can_create = f`.

Record the `max_connections` value. If it differs from the `db_max_connections` default, set the
variable and apply, so consumers size their pools against the real value.

## 6. Clean up

```sh
unset PGPASSWORD MASTER_USER MIGRATOR_PASSWORD APP_PASSWORD
history -c
set -o history
```

Then delete the CloudShell VPC environment.

## Rotating the application passwords

1. Increase `db_secret_version` in the environment's variables and apply through the pipeline. New
   passwords are written to the two secrets.
2. Run this runbook again from step 3. The script sets both roles to the new passwords.
3. Restart the services that cache the old passwords.

## If something fails

| Symptom | Cause |
|---|---|
| `connection timed out` | The environment is not in a private-app subnet, or `shiptrack-db-client` is not attached |
| `certificate verify failed` | The bundle is missing or the host name differs from `DB_HOST` |
| `permission denied to ...` when granting the migrator role | The master user is not `rds_superuser`; check the master secret's `username` |
| `password authentication failed` for the application | The script was not run after the secrets were last written |
