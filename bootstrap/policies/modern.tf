data "aws_iam_policy_document" "modern_plan" {
  source_policy_documents = [data.aws_iam_policy_document.state_plan["modern"].json]
}

data "aws_iam_policy_document" "modern_apply" {
  source_policy_documents = [
    data.aws_iam_policy_document.state_apply["modern"].json,
    data.aws_iam_policy_document.deny_platform_key_changes.json,
  ]

  statement {
    sid = "ClusterAndData"
    actions = [
      "ec2:*",
      "autoscaling:*",
      "eks:*",
      "ecr:*",
      "sqs:*",
      "events:*",
      "aps:*",
      "kms:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.r]
    }
  }

  statement {
    sid = "Parameters"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:DeleteParameters",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:LabelParameterVersion",
    ]
    resources = ["${local.ssm_prefix}/modern/*"]
  }

  statement {
    sid     = "LogGroups"
    actions = ["logs:*"]
    resources = [
      "arn:${local.p}:logs:${local.r}:${local.a}:log-group:/aws/eks/shiptrack/*",
      "arn:${local.p}:logs:${local.r}:${local.a}:log-group:/aws/eks/shiptrack/*:*",
      "arn:${local.p}:logs:${local.r}:${local.a}:log-group:/aws/containerinsights/shiptrack/*",
      "arn:${local.p}:logs:${local.r}:${local.a}:log-group:/aws/containerinsights/shiptrack/*:*",
      "arn:${local.p}:logs:${local.r}:${local.a}:log-group:/shiptrack/modern/*",
      "arn:${local.p}:logs:${local.r}:${local.a}:log-group:/shiptrack/modern/*:*",
    ]
  }

  statement {
    sid = "AlarmsAndDashboards"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:PutCompositeAlarm",
      "cloudwatch:EnableAlarmActions",
      "cloudwatch:DisableAlarmActions",
      "cloudwatch:PutDashboard",
      "cloudwatch:DeleteDashboards",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = [
      "arn:${local.p}:cloudwatch:${local.r}:${local.a}:alarm:shiptrack-modern-*",
      "arn:${local.p}:cloudwatch::${local.a}:dashboard/shiptrack-modern-*",
    ]
  }

  # Every role must carry the workload boundary.
  statement {
    sid       = "CreateRolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy"]
    resources = ["arn:${local.p}:iam::${local.a}:role/${local.rp}-modern-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid       = "AttachApprovedPolicies"
    actions   = ["iam:AttachRolePolicy"]
    resources = ["arn:${local.p}:iam::${local.a}:role/${local.rp}-modern-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values = [
        "arn:${local.p}:iam::aws:policy/*",
        "arn:${local.p}:iam::${local.a}:policy/${local.rp}-modern-*",
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
    resources = ["arn:${local.p}:iam::${local.a}:role/${local.rp}-modern-*"]
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
    resources = ["arn:${local.p}:iam::${local.a}:policy/${local.rp}-modern-*"]
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
    resources = ["arn:${local.p}:iam::${local.a}:instance-profile/${local.rp}-modern-*"]
  }

  statement {
    sid       = "PassRolesToServices"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.p}:iam::${local.a}:role/${local.rp}-modern-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "eks.amazonaws.com",
        "ec2.amazonaws.com",
        "pods.eks.amazonaws.com",
        "events.amazonaws.com",
        "aps.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "autoscaling.amazonaws.com",
        "spot.amazonaws.com",
        "scraper.aps.amazonaws.com",
      ]
    }
  }
}

data "aws_iam_policy_document" "modern_release" {
  statement {
    sid = "PushAndPullTheApplicationImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:${local.p}:ecr:${local.r}:${local.a}:repository/shiptrack/app"]
  }

  statement {
    sid       = "GetRegistryToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "modern_deploy" {
  source_policy_documents = [data.aws_iam_policy_document.token_read.json]

  statement {
    sid       = "DescribeTheCluster"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.p}:eks:${local.r}:${local.a}:cluster/shiptrack"]
  }

  statement {
    sid       = "ReadParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["${local.ssm_prefix}/*"]
  }
}
