# Offline: the provider is mocked, so nothing contacts AWS.
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

run "keys_rotate_and_wait_30_days" {
  command = plan

  assert {
    condition = alltrue([
      aws_kms_key.data.enable_key_rotation,
      aws_kms_key.secrets.enable_key_rotation,
      aws_kms_key.logs.enable_key_rotation,
    ])
    error_message = "Every key must have rotation enabled."
  }

  assert {
    condition = alltrue([
      aws_kms_key.data.deletion_window_in_days == 30,
      aws_kms_key.secrets.deletion_window_in_days == 30,
      aws_kms_key.logs.deletion_window_in_days == 30,
    ])
    error_message = "Every key must have a 30-day deletion window."
  }
}

run "aliases_follow_the_design" {
  command = plan

  assert {
    condition = alltrue([
      aws_kms_alias.data.name == "alias/shiptrack-data",
      aws_kms_alias.secrets.name == "alias/shiptrack-secrets",
      aws_kms_alias.logs.name == "alias/shiptrack-logs",
    ])
    error_message = "Aliases must be alias/shiptrack-data, -secrets, and -logs."
  }
}
