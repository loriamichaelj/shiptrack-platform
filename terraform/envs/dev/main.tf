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
