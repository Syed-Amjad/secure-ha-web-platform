output "alb_dns_name" {
  description = "ALB hostname. Cloudflare CNAMEs to this. Hitting it directly should time out — that is the point."
  value       = aws_lb.main.dns_name
}

output "site_url" {
  value = "https://${var.domain_name}"
}

output "bastion_public_ip" {
  description = "Changes on every stop/start — which is why gen-inventory.sh exists."
  value       = aws_instance.bastion.public_ip
}

output "web_private_ips" {
  value = aws_instance.web[*].private_ip
}

output "db_primary_private_ip" {
  value = aws_instance.db_primary.private_ip
}

output "db_replica_private_ip" {
  value = aws_instance.db_replica.private_ip
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "web_tg_arn" {
  description = "Target group ARN — used by the runbook's describe-target-health check."
  value       = aws_lb_target_group.web.arn
}

output "admin_cidr" {
  value = var.admin_cidr
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.id
}

output "kms_key_id" {
  value = aws_kms_key.backups.arn
}

# Consumed by scripts/lab-up.sh and scripts/lab-down.sh.
output "instance_ids" {
  description = "Every stoppable instance, for the overnight start/stop scripts."
  value = concat(
    aws_instance.web[*].id,
    [
      aws_instance.db_primary.id,
      aws_instance.db_replica.id,
      aws_instance.bastion.id,
    ]
  )
}

output "web_instance_ids" {
  description = "Web nodes only — pass one of these to ha-failover-drill.sh."
  value       = aws_instance.web[*].id
}
