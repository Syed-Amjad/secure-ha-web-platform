variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "ha-web-platform"
}

variable "region" {
  description = "AWS region. Must match the region the ACM certificate is issued in."
  type        = string
  default     = "us-east-1"
}

variable "azs" {
  description = "Exactly two availability zones. The whole design assumes two."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "This stack is built for exactly two AZs."
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR. Do not reuse 10.0.0.0/16 — overlapping ranges make future peering painful."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "One per AZ. Holds the ALB and the bastion only."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One per AZ. Holds the web and database tiers. No public IPs here."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "nat_enabled" {
  description = <<-EOT
    Overnight cost control ONLY. The deployed architecture is unchanged; this
    pauses egress capacity while every instance is stopped. NAT gateways are
    stateless, so destroying and recreating them loses nothing.
      terraform apply -var nat_enabled=false   # end of day
      terraform apply -var nat_enabled=true    # start of day
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

variable "admin_cidr" {
  description = "Your public egress address as a /32. Never 0.0.0.0/0. Find it with: curl -4 ifconfig.me"
  type        = string

  validation {
    condition     = var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must not be 0.0.0.0/0 — that defeats the entire bastion design."
  }
}

variable "admin_ip" {
  description = "Same address WITHOUT the /32 suffix. Used in Cloudflare rule expressions, which take bare IPs."
  type        = string
}

variable "key_name" {
  description = "Name of an existing EC2 key pair. Create with: aws ec2 create-key-pair --key-name ha-lab --query KeyMaterial --output text > ~/.ssh/ha-lab.pem && chmod 600 ~/.ssh/ha-lab.pem"
  type        = string
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "ubuntu_ami" {
  description = "Optional AMI override. Leave empty to auto-resolve the latest Ubuntu 24.04 LTS."
  type        = string
  default     = ""
}

variable "instance_type_web" {
  type    = string
  default = "t3.small"
}

variable "instance_type_db" {
  type    = string
  default = "t3.small"
}

variable "instance_type_bastion" {
  type    = string
  default = "t3.micro"
}

# ---------------------------------------------------------------------------
# DNS / TLS / Cloudflare
# ---------------------------------------------------------------------------

variable "domain_name" {
  description = "Subdomain served by this stack. NEVER the apex — that serves your portfolio."
  type        = string
  default     = "lab.syedamjad.com"
}

variable "cloudflare_api_token" {
  description = "Scoped token: Zone.DNS Edit + Zone.Zone Settings Edit + Zone.Firewall Services Edit on this zone only."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Zone ID from the Cloudflare dashboard overview page for syedamjad.com."
  type        = string
}

variable "cloudflare_ipv4_ranges" {
  description = <<-EOT
    Cloudflare edge IPv4 ranges. The ALB security group accepts these and nothing
    else — without this the WAF is decorative, because anyone who finds the ALB
    hostname walks straight past it.
    Refresh with: ./scripts/update-cloudflare-ranges.sh
  EOT
  type        = list(string)
  default = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
  ]
}

variable "geo_allowed_countries" {
  description = "ISO country codes served without a challenge. Everything else gets managed_challenge, not block."
  type        = list(string)
  default     = ["PK", "AE", "GB", "US"]
}
