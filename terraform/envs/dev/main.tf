module "kms" {
  source = "../../modules/kms"
}

module "network" {
  source = "../../modules/network"

  role_prefix                = var.role_prefix
  vpc_cidr                   = var.vpc_cidr
  nat_gateway_mode           = var.nat_gateway_mode
  enable_interface_endpoints = var.enable_interface_endpoints
  allowed_ingress_cidrs      = var.allowed_ingress_cidrs
  enable_tls                 = var.enable_tls
  logs_kms_key_arn           = module.kms.logs_key_arn
}

module "database" {
  source = "../../modules/database"

  role_prefix           = var.role_prefix
  environment           = var.environment
  subnet_ids            = module.network.private_data_subnet_ids
  security_group_id     = module.network.sg_db_id
  data_key_arn          = module.kms.data_key_arn
  secrets_key_arn       = module.kms.secrets_key_arn
  logs_key_arn          = module.kms.logs_key_arn
  engine_version        = var.db_engine_version
  instance_class        = var.db_instance_class
  multi_az              = var.db_multi_az
  backup_window         = var.db_backup_window
  maintenance_window    = var.db_maintenance_window
  db_secret_version     = var.db_secret_version
  max_connections       = var.db_max_connections
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
}

module "storage" {
  source = "../../modules/storage"

  data_key_arn       = module.kms.data_key_arn
  logs_key_arn       = module.kms.logs_key_arn
  pod_retention_days = var.pod_retention_days
}

module "ingress" {
  source = "../../modules/ingress"

  environment           = var.environment
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.network.sg_alb_id
  alb_logs_bucket_name  = module.storage.alb_logs_bucket_name
  secrets_key_arn       = module.kms.secrets_key_arn
  cutover               = var.cutover
  ui_stickiness_seconds = var.ui_stickiness_seconds
  domain_name           = var.domain_name
  hosted_zone_name      = var.hosted_zone_name
  enable_waf            = var.enable_waf
}

# --- Values owned by bootstrap, read by data source ---------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy" "workload_boundary" {
  name = "${var.role_prefix}-workload-boundary"
}

data "aws_s3_bucket" "state" {
  bucket = "shiptrack-tfstate-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
}

locals {
  # The alarm descriptions link to the cutover runbook (written in P8), one anchor per alarm.
  runbook_url = "https://github.com/${var.owner}/shiptrack-platform/blob/dev/docs/runbooks/cutover.md"
}

module "observability" {
  source = "../../modules/observability"

  logs_key_arn   = module.kms.logs_key_arn
  alert_emails   = var.alert_emails
  runbook_url    = local.runbook_url
  alb_arn_suffix = module.ingress.alb_arn_suffix
  target_groups = {
    legacy = module.ingress.tg_legacy_arn_suffix
    modern = module.ingress.tg_modern_arn_suffix
  }
  db_instance_id     = module.database.instance_id
  db_max_connections = module.database.max_connections
  cutover            = var.cutover
}

module "contract" {
  source = "../../modules/contract"

  contract = {
    vpc_id                  = module.network.vpc_id
    vpc_cidr                = module.network.vpc_cidr
    public_subnet_ids       = module.network.public_subnet_ids
    private_app_subnet_ids  = module.network.private_app_subnet_ids
    private_data_subnet_ids = module.network.private_data_subnet_ids
    sg_alb_id               = module.network.sg_alb_id
    sg_db_client_id         = module.network.sg_db_client_id
    alb_arn                 = module.ingress.alb_arn
    alb_dns_name            = module.ingress.alb_dns_name
    listener_arn            = module.ingress.listener_arn
    tg_legacy_arn           = module.ingress.tg_legacy_arn
    tg_modern_arn           = module.ingress.tg_modern_arn
    base_url                = module.ingress.base_url
    rds_endpoint            = module.database.endpoint
    rds_port                = tostring(module.database.port)
    db_name                 = module.database.db_name
    db_max_connections      = tostring(module.database.max_connections)
    db_app_secret_arn       = module.database.app_secret_arn
    db_migrator_secret_arn  = module.database.migrator_secret_arn
    kms_data_key_arn        = module.kms.data_key_arn
    kms_secrets_key_arn     = module.kms.secrets_key_arn
    kms_logs_key_arn        = module.kms.logs_key_arn
    pod_bucket_name         = module.storage.pod_bucket_name
    pod_bucket_arn          = module.storage.pod_bucket_arn
    sns_sev1_arn            = module.observability.sns_sev1_arn
    sns_sev2_arn            = module.observability.sns_sev2_arn
    permission_boundary_arn = data.aws_iam_policy.workload_boundary.arn
    test_token_secret_arn   = module.ingress.test_token_secret_arn
    state_bucket_name       = data.aws_s3_bucket.state.id
  }
}

module "security_services" {
  source = "../../modules/security-services"

  role_prefix              = var.role_prefix
  cloudtrail_bucket_name   = module.storage.cloudtrail_bucket_name
  pod_bucket_arn           = module.storage.pod_bucket_arn
  logs_key_arn             = module.kms.logs_key_arn
  sns_sev2_arn             = module.observability.sns_sev2_arn
  enable_pod_data_events   = var.enable_pod_data_events
  enable_guardduty_runtime = var.enable_guardduty_runtime

  config_recorder_name         = var.config_recorder_name
  config_delivery_channel_name = var.config_delivery_channel_name
  manage_access_analyzer       = var.manage_access_analyzer
}

# The account already had a stopped AWS Config recorder and delivery channel, both named "default",
# and AWS allows one of each per region. They are adopted here and then reconfigured by the module
# (this role, all supported types, delivery to the CloudTrail bucket under config/). Once an apply has
# imported them these blocks can be removed (ADR-0022).
import {
  to = module.security_services.aws_config_configuration_recorder.this
  id = var.config_recorder_name
}

import {
  to = module.security_services.aws_config_delivery_channel.this
  id = var.config_delivery_channel_name
}
