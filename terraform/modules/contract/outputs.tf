output "parameter_names" {
  description = "Names of the published parameters."
  value       = sort([for p in aws_ssm_parameter.contract : p.name])
}
