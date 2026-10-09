# Non-secret, non-identifying values only. The owner and the role prefix come from the workflows
# as TF_VAR_owner and TF_VAR_role_prefix.
aws_region  = "us-east-1"
environment = "dev"
cost_center = "shiptrack-migration"

vpc_cidr                   = "10.40.0.0/16"
nat_gateway_mode           = "single"
enable_interface_endpoints = false
allowed_ingress_cidrs      = ["0.0.0.0/0"]
enable_tls                 = false
