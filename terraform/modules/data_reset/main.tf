# Deletes every shipment and its proof-of-delivery files, and can seed five demo shipments (ADR-0034).
# The workflow ops-reset-data.yml dispatches it to the legacy hosts one at a time, behind the dev
# environment and a typed confirmation: the database is private, and a legacy host is the one place
# a workflow can reach it from. The document carries its own copy of the SQL and the script, so a
# reset needs no deploy on either stack.

locals {
  sql    = file("${path.module}/../../../db/reset-data.sql")
  script = file("${path.module}/../../../scripts/reset-data.sh")
}

resource "aws_ssm_document" "reset_data" {
  name            = var.document_name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Delete every shipment and its proof-of-delivery files, and optionally seed five"
    parameters = {
      confirm = {
        type           = "String"
        description    = "Must be delete-all-shipments"
        allowedPattern = "^delete-all-shipments$"
      }
      podBucket = {
        type           = "String"
        description    = "The proof-of-delivery bucket"
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
        default        = var.pod_bucket_name
      }
      seed = {
        type          = "String"
        description   = "Whether to create five demo shipments afterwards"
        allowedValues = ["yes", "no"]
        default       = "yes"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "run"
      inputs = {
        runCommand = [join("\n", [
          "set -euo pipefail",
          "cat >/tmp/shiptrack-reset-data.sql <<'SHIPTRACK_EOF_SQL'",
          local.sql,
          "SHIPTRACK_EOF_SQL",
          "chmod 0644 /tmp/shiptrack-reset-data.sql",
          "cat >/tmp/shiptrack-reset-data.sh <<'SHIPTRACK_EOF_SCRIPT'",
          local.script,
          "SHIPTRACK_EOF_SCRIPT",
          "bash /tmp/shiptrack-reset-data.sh '{{ confirm }}' '{{ podBucket }}' '{{ seed }}'",
          "rm -f /tmp/shiptrack-reset-data.sh /tmp/shiptrack-reset-data.sql",
        ])]
      }
    }]
  })
}
