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

db_engine_version        = "17.10"
db_instance_class        = "db.t3.medium"
db_allocated_storage     = 50
db_max_allocated_storage = 200
db_multi_az              = false
db_backup_window         = "05:00-06:00"
db_maintenance_window    = "sun:07:00-sun:08:00"
db_secret_version        = 1
db_max_connections       = 400
