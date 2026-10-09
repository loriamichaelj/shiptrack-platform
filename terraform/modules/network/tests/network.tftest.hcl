# Offline: the provider is mocked, so nothing contacts AWS. Checks the design's §6.2 values.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

override_data {
  target = data.aws_availability_zones.available
  values = { names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"] }
}

variables {
  role_prefix      = "testowner-dev-shiptrack"
  logs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
}

run "subnets_match_the_design" {
  command = plan

  assert {
    condition     = [for s in aws_subnet.public : s.cidr_block] == ["10.40.0.0/24", "10.40.1.0/24", "10.40.2.0/24"]
    error_message = "Public subnets must be 10.40.0-2.0/24."
  }

  assert {
    condition     = [for s in aws_subnet.private_app : s.cidr_block] == ["10.40.16.0/20", "10.40.32.0/20", "10.40.48.0/20"]
    error_message = "Private-app subnets must be 10.40.16/32/48.0/20."
  }

  assert {
    condition     = [for s in aws_subnet.private_data : s.cidr_block] == ["10.40.64.0/24", "10.40.65.0/24", "10.40.66.0/24"]
    error_message = "Private-data subnets must be 10.40.64-66.0/24."
  }

  assert {
    condition     = [for s in aws_subnet.public : s.availability_zone] == ["us-east-1a", "us-east-1b", "us-east-1c"]
    error_message = "Subnets must use the first three AZs."
  }
}

run "subnet_tags_match_the_design" {
  command = plan

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.tags["kubernetes.io/role/elb"] == "1"])
    error_message = "Public subnets need kubernetes.io/role/elb=1."
  }

  assert {
    condition = alltrue([
      for s in aws_subnet.private_app :
      s.tags["kubernetes.io/role/internal-elb"] == "1" && s.tags["karpenter.sh/discovery"] == "shiptrack"
    ])
    error_message = "Private-app subnets need kubernetes.io/role/internal-elb=1 and karpenter.sh/discovery=shiptrack."
  }

  assert {
    condition = alltrue([
      for s in concat(aws_subnet.private_app, aws_subnet.private_data) :
      !contains(keys(s.tags), "kubernetes.io/role/elb")
    ])
    error_message = "Only the public subnets may carry kubernetes.io/role/elb."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private_data : !contains(keys(s.tags), "karpenter.sh/discovery")])
    error_message = "Private-data subnets must not be discoverable by Karpenter."
  }
}

run "single_nat_is_the_default" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "The default is one NAT gateway."
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 0
    error_message = "Interface endpoints are off by default."
  }
}

run "per_az_nat" {
  command = plan

  variables {
    nat_gateway_mode = "per_az"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "per_az mode needs one NAT gateway per AZ."
  }
}

run "interface_endpoints_when_enabled" {
  command = plan

  variables {
    enable_interface_endpoints = true
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 11
    error_message = "Eleven interface endpoints are expected."
  }
}

run "flow_logs_follow_the_design" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.name == "/shiptrack/vpc/flow-logs" && aws_cloudwatch_log_group.flow_logs.retention_in_days == 14
    error_message = "Flow logs go to /shiptrack/vpc/flow-logs for 14 days."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.kms_key_id == var.logs_kms_key_arn
    error_message = "The flow-log group must use the logs key."
  }

  assert {
    condition     = aws_iam_role.flow_logs.name == "testowner-dev-shiptrack-platform-flow-logs"
    error_message = "The flow-log role must be named under the role prefix."
  }
}

run "security_groups_follow_the_contract" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb) == 1 && alltrue([for r in aws_vpc_security_group_ingress_rule.alb : r.from_port == 80])
    error_message = "The ALB group opens port 80 only until TLS is enabled."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.db_client_to_db.from_port == 5432 && aws_vpc_security_group_ingress_rule.db_from_clients.from_port == 5432
    error_message = "The database path is PostgreSQL on 5432."
  }
}

run "tls_opens_443" {
  command = plan

  variables {
    enable_tls = true
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb) == 2
    error_message = "enable_tls adds port 443."
  }
}

run "rejects_a_small_vpc" {
  command = plan

  variables {
    vpc_cidr = "10.40.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}
