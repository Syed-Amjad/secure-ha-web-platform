# Shared lookups and locals. Resources live in their own topic files:
#   network.tf  security_groups.tf  compute.tf  alb.tf  acm.tf
#   s3_backups.tf  iam.tf  cloudflare.tf

data "aws_caller_identity" "current" {}

# Latest Ubuntu 24.04 LTS (Noble) published by Canonical.
# Pinning an AMI ID rots; resolving it keeps `terraform apply` working months later.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ubuntu_ami = var.ubuntu_ami != "" ? var.ubuntu_ami : data.aws_ami.ubuntu.id

  # Every Cloudflare rule expression must be scoped to this hostname, or the
  # rule also applies to syedamjad.com — see the warning in section 0.3.
  host_filter = "http.host eq \"${var.domain_name}\""
}
