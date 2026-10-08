data "aws_iam_policy_document" "legacy_plan" {
  source_policy_documents = [
    data.aws_iam_policy_document.state_plan["legacy"].json,
    data.aws_iam_policy_document.token_read.json,
  ]
}

data "aws_iam_policy_document" "legacy_apply" {
  source_policy_documents = [
    data.aws_iam_policy_document.state_apply["legacy"].json,
    data.aws_iam_policy_document.deny_platform_key_changes.json,
  ]

  statement {
    sid       = "ComputeAndScaling"
    actions   = ["ec2:*", "autoscaling:*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.r]
    }
  }

  # Hard limit of the legacy design: no SSH, no key pairs.
  statement {
    sid       = "DenyKeyPairs"
    effect    = "Deny"
    actions   = ["ec2:CreateKeyPair", "ec2:ImportKeyPair"]
    resources = ["*"]
  }

  statement {
    sid = "ParametersAndDocuments"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:DeleteParameters",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:LabelParameterVersion",
    ]
    resources = ["${local.ssm_prefix}/legacy/*"]
  }

  statement {
    sid = "ShipTrackDocuments"
    actions = [
      "ssm:CreateDocument",
      "ssm:UpdateDocument",
      "ssm:UpdateDocumentDefaultVersion",
      "ssm:DeleteDocument",
      "ssm:ModifyDocumentPermission",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
    ]
    resources = ["arn:${local.p}:ssm:${local.r}:${local.a}:document/ShipTrack-*"]
  }

  statement {
    sid     = "ArtifactBucket"
    actions = ["s3:*"]
    resources = [
      "arn:${local.p}:s3:::shiptrack-legacy-artifacts-*",
      "arn:${local.p}:s3:::shiptrack-legacy-artifacts-*/*",
    ]
  }

  statement {
    sid     = "LogGroups"
    actions = ["logs:*"]
    resources = [
      "arn:${local.p}:logs:${local.r}:${local.a}:log-group:/shiptrack/legacy/*",
      "arn:${local.p}:logs:${local.r}:${local.a}:log-group:/shiptrack/legacy/*:*",
    ]
  }

  statement {
    sid = "Alarms"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:EnableAlarmActions",
      "cloudwatch:DisableAlarmActions",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = ["arn:${local.p}:cloudwatch:${local.r}:${local.a}:alarm:shiptrack-legacy-*"]
  }

  # Log groups are encrypted with the platform logs key.
  statement {
    sid       = "UseLogsKeyForLogGroups"
    actions   = ["kms:DescribeKey", "kms:CreateGrant"]
    resources = [local.all_keys_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["logs.${local.r}.amazonaws.com"]
    }
  }

  # Every role must carry the workload boundary.
  statement {
    sid       = "CreateRolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy"]
    resources = ["arn:${local.p}:iam::${local.a}:role/shiptrack-legacy-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid       = "AttachApprovedPolicies"
    actions   = ["iam:AttachRolePolicy"]
    resources = ["arn:${local.p}:iam::${local.a}:role/shiptrack-legacy-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values = [
        "arn:${local.p}:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:${local.p}:iam::aws:policy/CloudWatchAgentServerPolicy",
        "arn:${local.p}:iam::${local.a}:policy/shiptrack-legacy-*",
      ]
    }
  }

  statement {
    sid = "ManageRoles"
    actions = [
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:${local.p}:iam::${local.a}:role/shiptrack-legacy-*"]
  }

  statement {
    sid = "ManagePolicies"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = ["arn:${local.p}:iam::${local.a}:policy/shiptrack-legacy-*"]
  }

  statement {
    sid = "InstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = ["arn:${local.p}:iam::${local.a}:instance-profile/shiptrack-legacy-*"]
  }

  statement {
    sid       = "PassRoleToEc2"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.p}:iam::${local.a}:role/shiptrack-legacy-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid       = "AutoScalingServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["autoscaling.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "legacy_deploy" {
  source_policy_documents = [data.aws_iam_policy_document.token_read.json]

  statement {
    sid       = "UploadReleases"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.p}:s3:::shiptrack-legacy-artifacts-*/*"]
  }

  statement {
    sid       = "RunShipTrackDocuments"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.p}:ssm:${local.r}::document/ShipTrack-*", "arn:${local.p}:ssm:${local.r}:${local.a}:document/ShipTrack-*"]
  }

  statement {
    sid       = "TargetLegacyInstances"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.p}:ec2:${local.r}:${local.a}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Stack"
      values   = ["legacy"]
    }
  }

  statement {
    sid = "ReadCommandResults"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:ListCommands",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "FindInstances"
    actions   = ["autoscaling:DescribeAutoScalingGroups", "ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["${local.ssm_prefix}/*"]
  }

  statement {
    sid       = "RecordCurrentRelease"
    actions   = ["ssm:PutParameter"]
    resources = ["${local.ssm_prefix}/legacy/current_release"]
  }
}
