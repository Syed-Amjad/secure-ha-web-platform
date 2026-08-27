# Copy to prod.auto.tfvars (gitignored) and fill in, or pass with:
#   terraform apply -var-file=environments/prod.tfvars
#
# NEVER commit a filled-in copy of this file — it holds a Cloudflare API token.

project = "ha-web-platform"
region  = "us-east-1"
azs     = ["us-east-1a", "us-east-1b"]

# ---------------------------------------------------------------------------
# Your access. Find your address with:  curl -4 ifconfig.me
# Re-run terraform apply if your ISP gives you a new one.
# ---------------------------------------------------------------------------
admin_cidr = "0.0.0.0/32" # ← REPLACE with YOUR.IP.ADD.RESS/32
admin_ip   = "0.0.0.0"    # ← same address, no /32 (Cloudflare wants a bare IP)

# EC2 key pair name that already exists in this region.
key_name = "ha-lab"

# ---------------------------------------------------------------------------
# DNS / Cloudflare
# Use a SUBDOMAIN. Never the apex — that serves your portfolio.
# ---------------------------------------------------------------------------
domain_name        = "lab.syedamjad.com"
cloudflare_zone_id = "REPLACE_WITH_ZONE_ID"

# Do NOT put the token here. Export it instead so it never reaches a file:
#   export TF_VAR_cloudflare_api_token='...'
# cloudflare_api_token = "..."

geo_allowed_countries = ["PK", "AE", "GB", "US"]

# ---------------------------------------------------------------------------
# Sizing — raise if the app tier feels slow, but t3.small is enough for this.
# ---------------------------------------------------------------------------
instance_type_web     = "t3.small"
instance_type_db      = "t3.small"
instance_type_bastion = "t3.micro"

# Overnight cost control only. See section 0.4.
nat_enabled = true
