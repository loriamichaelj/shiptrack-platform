# Offline: the provider is mocked, so nothing contacts AWS.
mock_provider "aws" {}

variables {
  pod_bucket_name = "shiptrack-pod-test"
}

run "the_document_is_named_and_typed" {
  command = plan

  assert {
    condition     = aws_ssm_document.reset_data.name == "ShipTrack-ResetData" && aws_ssm_document.reset_data.document_type == "Command"
    error_message = "The document must be the Command document ShipTrack-ResetData."
  }
}

run "it_refuses_without_the_typed_confirmation" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_ssm_document.reset_data.content).parameters.confirm.allowedPattern == "^delete-all-shipments$"
      && !can(jsondecode(aws_ssm_document.reset_data.content).parameters.confirm.default)
    )
    error_message = "confirm must match ^delete-all-shipments$ exactly and must have no default."
  }
}

run "the_bucket_defaults_to_the_proof_of_delivery_bucket_and_the_seed_is_yes_or_no" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_ssm_document.reset_data.content).parameters.podBucket.default == "shiptrack-pod-test"
      && jsondecode(aws_ssm_document.reset_data.content).parameters.seed.allowedValues == ["yes", "no"]
    )
    error_message = "podBucket must default to the proof-of-delivery bucket, and seed must be yes or no."
  }
}

run "it_carries_the_sql_and_the_script" {
  command = plan

  assert {
    condition = (
      strcontains(one(jsondecode(aws_ssm_document.reset_data.content).mainSteps).inputs.runCommand[0], "DELETE FROM shiptrack.shipments")
      && strcontains(one(jsondecode(aws_ssm_document.reset_data.content).mainSteps).inputs.runCommand[0], "bash /tmp/shiptrack-reset-data.sh")
    )
    error_message = "The document must embed db/reset-data.sql and scripts/reset-data.sh."
  }
}

run "only_a_shiptrack_document_name_is_accepted" {
  command = plan

  variables {
    document_name = "Other-ResetData"
  }

  expect_failures = [var.document_name]
}
