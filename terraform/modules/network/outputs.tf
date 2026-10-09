output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, one per AZ."
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Private-app subnet IDs, one per AZ."
  value       = aws_subnet.private_app[*].id
}

output "private_data_subnet_ids" {
  description = "Private-data subnet IDs, one per AZ."
  value       = aws_subnet.private_data[*].id
}

output "sg_alb_id" {
  description = "ID of the ALB security group."
  value       = aws_security_group.alb.id
}

output "sg_db_client_id" {
  description = "ID of the database-client security group."
  value       = aws_security_group.db_client.id
}

output "sg_db_id" {
  description = "ID of the database security group."
  value       = aws_security_group.db.id
}
