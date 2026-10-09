# VPC, subnets, NAT, endpoints, flow logs, and the shared security groups (design §6.2).

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394: only the first three zones are used (design §6.2); subnets are created per index
  state = "available"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
  az_index = { for i, az in local.azs : az => i }
  region   = data.aws_region.current.region
  account  = data.aws_caller_identity.current.account_id

  # public /24 at 0-2, private-app /20 at 16, 32, 48, private-data /24 at 64-66 (for the default /16).
  public_cidrs       = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_app_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 1)]
  private_data_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 64)]

  nat_azs = var.nat_gateway_mode == "per_az" ? local.azs : [local.azs[0]]

  interface_endpoints = var.enable_interface_endpoints ? toset([
    "ecr.api", "ecr.dkr", "sts", "logs", "secretsmanager", "sqs",
    "ssm", "ssmmessages", "ec2messages", "kms", "eks-auth",
  ]) : toset([])

  alb_ports = var.enable_tls ? [80, 443] : [80]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name_prefix }
}

# The default security group carries no rules, so nothing can use it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-default-unused" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name_prefix }
}

resource "aws_subnet" "public" {
  count = 3

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private_app" {
  count = 3

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private_app_cidrs[count.index]

  tags = {
    Name                              = "${var.name_prefix}-private-app-${local.azs[count.index]}"
    Tier                              = "private-app"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.karpenter_discovery_tag
  }
}

resource "aws_subnet" "private_data" {
  count = 3

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private_data_cidrs[count.index]

  tags = {
    Name = "${var.name_prefix}-private-data-${local.azs[count.index]}"
    Tier = "private-data"
  }
}

# --- NAT ----------------------------------------------------------------------------------------

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = { Name = "${var.name_prefix}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[local.az_index[each.key]].id

  tags = { Name = "${var.name_prefix}-${each.key}" }
}

# --- Routing ------------------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = 3

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per AZ so that per_az mode sends each AZ to its own NAT gateway. In single mode
# every table points at the one gateway.
resource "aws_route_table" "private_app" {
  count = 3

  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-private-app-${local.azs[count.index]}" }
}

resource "aws_route" "private_app_nat" {
  count = 3

  route_table_id         = aws_route_table.private_app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.nat_gateway_mode == "per_az" ? local.azs[count.index] : local.azs[0]].id
}

resource "aws_route_table_association" "private_app" {
  count = 3

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# The data tier has no route to the internet: the database needs none.
resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-private-data" }
}

resource "aws_route_table_association" "private_data" {
  count = 3

  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private_data.id
}

# --- VPC endpoints ------------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.private_app[*].id, [aws_route_table.private_data.id])

  tags = { Name = "${var.name_prefix}-s3" }
}

resource "aws_security_group" "endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name_prefix = "${var.name_prefix}-endpoints-"
  description = "Interface VPC endpoints: HTTPS from inside the VPC"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-endpoints" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = var.enable_interface_endpoints ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from the VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private_app[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-${each.key}" }
}

# --- Flow logs ----------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338: flow logs are kept 14 days to limit cost (design §6.2)
  name              = "/${var.name_prefix}/vpc/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

data "aws_iam_policy_document" "flow_logs_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.role_prefix}-platform-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_trust.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
}

# --- Shared security groups (the cross-repo network contract) -----------------------------------
# App repos must not add rules to these groups; they create their own groups that allow ingress
# from the ALB group.

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5: the ALB attaches it (P3)
  name_prefix = "${var.name_prefix}-alb-"
  description = "ShipTrack ALB"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  #checkov:skip=CKV_AWS_260: the ALB is public by design; var.allowed_ingress_cidrs narrows it (risk R-01)
  for_each = {
    for pair in setproduct(var.allowed_ingress_cidrs, local.alb_ports) :
    "${pair[0]}:${pair[1]}" => { cidr = pair[0], port = pair[1] }
  }

  security_group_id = aws_security_group.alb.id
  description       = "HTTP(S) from the allowed CIDRs"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "alb" {
  security_group_id = aws_security_group.alb.id
  description       = "Anything inside the VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_security_group" "db_client" {
  #checkov:skip=CKV2_AWS_5: legacy instances and modern nodes attach it in their own repos
  name_prefix = "${var.name_prefix}-db-client-"
  description = "Attach to anything that connects to the database"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-db-client" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5: RDS attaches it (P2)
  name_prefix = "${var.name_prefix}-db-"
  description = "ShipTrack RDS PostgreSQL"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-db" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "db_client_to_db" {
  security_group_id            = aws_security_group.db_client.id
  description                  = "PostgreSQL to the database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_clients" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from database clients only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db_client.id
}
