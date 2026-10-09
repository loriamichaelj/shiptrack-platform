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
