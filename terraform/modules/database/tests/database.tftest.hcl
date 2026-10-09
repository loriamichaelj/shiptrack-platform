# Offline: the AWS provider is mocked, so nothing contacts AWS. The random provider is real because
# mocked providers cannot serve ephemeral resources; it makes no network calls.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  role_prefix       = "testowner-dev-shiptrack"
  subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
  security_group_id = "sg-db"
  data_key_arn      = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000a"
  secrets_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000b"
  logs_key_arn      = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000c"
}

run "instance_follows_the_design" {
  command = plan

  assert {
    condition = alltrue([
      aws_db_instance.this.engine == "postgres",
      startswith(aws_db_instance.this.engine_version, "17."),
      aws_db_instance.this.instance_class == "db.t4g.medium",
      aws_db_instance.this.storage_type == "gp3",
      aws_db_instance.this.allocated_storage == 50,
      aws_db_instance.this.max_allocated_storage == 200,
      !aws_db_instance.this.multi_az,
    ])
    error_message = "Engine, class, storage, and Multi-AZ must match design §6.4."
  }

  assert {
    condition = alltrue([
      aws_db_instance.this.storage_encrypted,
      aws_db_instance.this.kms_key_id == var.data_key_arn,
      !aws_db_instance.this.publicly_accessible,
      aws_db_instance.this.deletion_protection,
      !aws_db_instance.this.skip_final_snapshot,
      aws_db_instance.this.copy_tags_to_snapshot,
      aws_db_instance.this.backup_retention_period == 7,
      aws_db_instance.this.auto_minor_version_upgrade,
      aws_db_instance.this.ca_cert_identifier == "rds-ca-rsa2048-g1",
    ])
    error_message = "Encryption, privacy, protection, and backups must match design §6.4."
  }

  assert {
    condition = alltrue([
      aws_db_instance.this.manage_master_user_password,
      aws_db_instance.this.master_user_secret_kms_key_id == var.secrets_key_arn,
    ])
    error_message = "RDS must manage the master password, encrypted with the secrets key."
  }

  assert {
    condition = alltrue([
      aws_db_instance.this.database_insights_mode == "standard",
      aws_db_instance.this.monitoring_interval == 60,
      toset(aws_db_instance.this.enabled_cloudwatch_logs_exports) == toset(["postgresql", "upgrade"]),
    ])
    error_message = "Database Insights standard, 60 s enhanced monitoring, and the two log exports are required."
  }
}

run "parameters_follow_the_design" {
  command = plan

  assert {
    condition = alltrue([
      anytrue([for p in aws_db_parameter_group.this.parameter : p.name == "rds.force_ssl" && p.value == "1"]),
      anytrue([for p in aws_db_parameter_group.this.parameter : p.name == "log_min_duration_statement" && p.value == "500"]),
      anytrue([for p in aws_db_parameter_group.this.parameter : p.name == "idle_in_transaction_session_timeout" && p.value == "60000"]),
    ])
    error_message = "The parameter group must force TLS and set the two timeouts."
  }
}

run "secrets_follow_the_design" {
  command = plan

  assert {
    condition = alltrue([
      aws_secretsmanager_secret.db["app"].name == "shiptrack/dev/db/app",
      aws_secretsmanager_secret.db["migrator"].name == "shiptrack/dev/db/migrator",
      aws_secretsmanager_secret.db["app"].kms_key_id == var.secrets_key_arn,
      aws_secretsmanager_secret.db["migrator"].kms_key_id == var.secrets_key_arn,
    ])
    error_message = "Secret names and key must match design §6.4."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.db["app"].secret_string_wo_version == 1
    error_message = "Secrets are written through the write-only argument, versioned by db_secret_version."
  }
}

run "log_groups_and_role_are_named_correctly" {
  command = plan

  assert {
    condition = alltrue([
      aws_cloudwatch_log_group.exports["postgresql"].name == "/aws/rds/instance/shiptrack-db/postgresql",
      aws_cloudwatch_log_group.exports["postgresql"].retention_in_days == 14,
      aws_cloudwatch_log_group.exports["postgresql"].kms_key_id == var.logs_key_arn,
    ])
    error_message = "Exported logs must go to the RDS log group, kept 14 days, under the logs key."
  }

  assert {
    condition     = aws_iam_role.monitoring.name == "testowner-dev-shiptrack-platform-rds-monitoring"
    error_message = "The monitoring role must be named under the role prefix."
  }
}

run "rejects_another_major_version" {
  command = plan

  variables {
    engine_version = "16.4"
  }

  expect_failures = [var.engine_version]
}
