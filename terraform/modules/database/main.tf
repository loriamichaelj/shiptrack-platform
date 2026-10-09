# RDS PostgreSQL and the application credentials (design §6.4). The master password is managed by
# RDS in Secrets Manager. The application and migrator passwords are generated as ephemeral values
# and written with write-only arguments, so they never enter Terraform state.

data "aws_caller_identity" "current" {}

locals {
  identifier = "${var.name_prefix}-db"
  account    = data.aws_caller_identity.current.account_id
  logs       = ["postgresql", "upgrade"]

  # Secret names the rest of the platform refers to: the plan role may read shiptrack/dev/db/*.
  secrets = {
    migrator = { name = "shiptrack/${var.environment}/db/migrator", username = "shiptrack_migrator" }
    app      = { name = "shiptrack/${var.environment}/db/app", username = "shiptrack_app" }
  }
}

resource "aws_db_subnet_group" "this" {
  name        = local.identifier
  description = "ShipTrack private-data subnets"
  subnet_ids  = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name        = local.identifier
  family      = var.parameter_group_family
  description = "ShipTrack PostgreSQL: TLS required, slow-query log, idle transactions ended"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }
}

# RDS creates its log groups on first export. Creating them here sets retention and encryption.
resource "aws_cloudwatch_log_group" "exports" {
  #checkov:skip=CKV_AWS_338: database logs are kept 14 days to limit cost (design §6.4)
  for_each = toset(local.logs)

  name              = "/aws/rds/instance/${local.identifier}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_key_arn
}

data "aws_iam_policy_document" "monitoring_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "${var.role_prefix}-platform-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_trust.json
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

data "aws_partition" "current" {}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_157: Multi-AZ is the multi_az variable, off by default for cost (risk R-05)
  identifier     = local.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = var.data_key_arn

  # The shiptrack database, its roles, and its schema are created by db/bootstrap.sql.
  username                      = "shiptrack_master"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.secrets_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az
  parameter_group_name   = aws_db_parameter_group.this.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  iam_database_authentication_enabled = true
  auto_minor_version_upgrade          = true
  deletion_protection                 = true
  skip_final_snapshot                 = false
  final_snapshot_identifier           = "${local.identifier}-final"
  copy_tags_to_snapshot               = true
  backup_retention_period             = var.backup_retention_days
  backup_window                       = var.backup_window
  maintenance_window                  = var.maintenance_window

  database_insights_mode                = "standard"
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.data_key_arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.monitoring.arn
  enabled_cloudwatch_logs_exports       = local.logs

  depends_on = [
    aws_cloudwatch_log_group.exports,
    aws_iam_role_policy_attachment.monitoring,
  ]
}

# --- Application credentials ---------------------------------------------------------------------

ephemeral "random_password" "db" {
  for_each = local.secrets

  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  #checkov:skip=CKV2_AWS_57: rotation is a bump of db_secret_version followed by a bootstrap.sql run (design §6.4)
  for_each = local.secrets

  name       = each.value.name
  kms_key_id = var.secrets_key_arn
}

resource "aws_secretsmanager_secret_version" "db" {
  for_each = local.secrets

  secret_id = aws_secretsmanager_secret.db[each.key].id
  secret_string_wo = jsonencode({
    username = each.value.username
    password = ephemeral.random_password.db[each.key].result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = "shiptrack"
    engine   = "postgres"
  })
  secret_string_wo_version = var.db_secret_version
}
