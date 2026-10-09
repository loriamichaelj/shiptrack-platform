# Offline: the provider is mocked, so nothing contacts AWS.
mock_provider "aws" {}

variables {
  contract = {
    vpc_id                  = "vpc-mock"
    vpc_cidr                = "10.40.0.0/16"
    public_subnet_ids       = ["subnet-p1", "subnet-p2", "subnet-p3"]
    private_app_subnet_ids  = ["subnet-a1", "subnet-a2", "subnet-a3"]
    private_data_subnet_ids = ["subnet-d1", "subnet-d2", "subnet-d3"]
    sg_alb_id               = "sg-alb"
    sg_db_client_id         = "sg-client"
    alb_arn                 = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/mock/0"
    alb_dns_name            = "alb.mock.test"
    listener_arn            = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/mock/0/0"
    tg_legacy_arn           = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/legacy/0"
    tg_modern_arn           = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/modern/0"
    base_url                = "http://alb.mock.test"
    rds_endpoint            = "db.mock.test"
    rds_port                = "5432"
    db_name                 = "shiptrack"
    db_max_connections      = "400"
    db_app_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:shiptrack/dev/db/app-AbCdEf"
    db_migrator_secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:shiptrack/dev/db/migrator-AbCdEf"
    kms_data_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000a"
    kms_secrets_key_arn     = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000b"
    kms_logs_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000c"
    pod_bucket_name         = "shiptrack-pod-mock"
    pod_bucket_arn          = "arn:aws:s3:::shiptrack-pod-mock"
    sns_sev1_arn            = "arn:aws:sns:us-east-1:123456789012:shiptrack-alerts-sev1"
    sns_sev2_arn            = "arn:aws:sns:us-east-1:123456789012:shiptrack-alerts-sev2"
    permission_boundary_arn = "arn:aws:iam::123456789012:policy/mock-workload-boundary"
    test_token_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:shiptrack/dev/test-routing-token-AbCdEf"
    state_bucket_name       = "shiptrack-tfstate-mock"
  }
}

run "every_key_in_the_design_is_published" {
  command = plan

  assert {
    condition = toset(keys(aws_ssm_parameter.contract)) == toset([
      "vpc_id", "vpc_cidr", "public_subnet_ids", "private_app_subnet_ids", "private_data_subnet_ids",
      "sg_alb_id", "sg_db_client_id", "alb_arn", "alb_dns_name", "listener_arn",
      "tg_legacy_arn", "tg_modern_arn", "base_url", "rds_endpoint", "rds_port", "db_name",
      "db_max_connections", "db_app_secret_arn", "db_migrator_secret_arn",
      "kms_data_key_arn", "kms_secrets_key_arn", "kms_logs_key_arn",
      "pod_bucket_name", "pod_bucket_arn", "sns_sev1_arn", "sns_sev2_arn",
      "permission_boundary_arn", "test_token_secret_arn", "state_bucket_name",
    ])
    error_message = "The contract must publish exactly the 29 keys in design §6.9."
  }
}

run "names_types_and_tier_follow_the_design" {
  command = plan

  assert {
    condition = alltrue([
      for k, p in aws_ssm_parameter.contract : p.name == "/shiptrack/platform/${k}" && p.tier == "Standard"
    ])
    error_message = "Every parameter is /shiptrack/platform/<key> in the Standard tier."
  }

  assert {
    condition = alltrue([
      aws_ssm_parameter.contract["public_subnet_ids"].type == "StringList",
      aws_ssm_parameter.contract["private_app_subnet_ids"].type == "StringList",
      aws_ssm_parameter.contract["private_data_subnet_ids"].type == "StringList",
      aws_ssm_parameter.contract["vpc_id"].type == "String",
      aws_ssm_parameter.contract["rds_port"].type == "String",
    ])
    error_message = "The three subnet lists are StringList; everything else is String."
  }
}

run "no_parameter_is_a_secure_string" {
  command = plan

  assert {
    condition     = alltrue([for p in aws_ssm_parameter.contract : p.type != "SecureString"])
    error_message = "Secret values are never published: only ARNs, as plain parameters."
  }
}

run "subnet_lists_are_comma_separated" {
  command = plan

  assert {
    condition     = nonsensitive(aws_ssm_parameter.contract["public_subnet_ids"].value) == "subnet-p1,subnet-p2,subnet-p3"
    error_message = "StringList values are comma-separated."
  }
}

# A contract with a missing key is rejected by the variable's object type ("attributes ... are
# required"). The test framework cannot expect a type error, so this is checked by hand:
#   terraform plan -var 'contract={vpc_id="x"}'
