variable "path_prefix" {
  description = "SSM path under which the contract is published."
  type        = string
  default     = "/shiptrack/platform"
}

# One attribute per key in design §6.9. An object type, not a map, so a missing key is an error at
# plan time and nobody can publish a partial contract by accident. Secret values are never part of
# the contract: only ARNs.
variable "contract" {
  description = "The values published to SSM for the legacy and modern repositories."
  type = object({
    vpc_id                  = string
    vpc_cidr                = string
    public_subnet_ids       = list(string)
    private_app_subnet_ids  = list(string)
    private_data_subnet_ids = list(string)
    sg_alb_id               = string
    sg_db_client_id         = string
    alb_arn                 = string
    alb_dns_name            = string
    listener_arn            = string
    tg_legacy_arn           = string
    tg_modern_arn           = string
    base_url                = string
    rds_endpoint            = string
    rds_port                = string
    db_name                 = string
    db_max_connections      = string
    db_app_secret_arn       = string
    db_migrator_secret_arn  = string
    kms_data_key_arn        = string
    kms_secrets_key_arn     = string
    kms_logs_key_arn        = string
    pod_bucket_name         = string
    pod_bucket_arn          = string
    sns_sev1_arn            = string
    sns_sev2_arn            = string
    permission_boundary_arn = string
    test_token_secret_arn   = string
    state_bucket_name       = string
  })
}
