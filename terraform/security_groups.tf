# Security groups reference EACH OTHER rather than CIDR ranges wherever possible.
# That is the capability no IP-based firewall has: the rule authorises a ROLE,
# survives instance replacement and autoscaling, and keeps the tiering correct
# even if a subnet is misconfigured.

# ---------------------------------------------------------------------------
# ALB — public ingress on 443, from Cloudflare's ranges ONLY.
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Public HTTPS ingress, restricted to the Cloudflare edge"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.cloudflare_ipv4_ranges # NOT 0.0.0.0/0
    description = "HTTPS from Cloudflare edge only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-alb-sg" }
}

# ---------------------------------------------------------------------------
# Bastion — the only host in the account with an SSH port open to the internet,
# and only to one address.
# ---------------------------------------------------------------------------
resource "aws_security_group" "bastion" {
  name        = "${var.project}-bastion-sg"
  description = "SSH jump host"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr] # your address /32 — never 0.0.0.0/0
    description = "SSH from admin address only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-bastion-sg" }
}

# ---------------------------------------------------------------------------
# Web tier — reachable from the ALB, and administratively from the bastion.
# Never from the internet.
# ---------------------------------------------------------------------------
resource "aws_security_group" "web" {
  name        = "${var.project}-web-sg"
  description = "Application tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Application port from the ALB only"
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
    description     = "SSH via bastion only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-web-sg" }
}

# ---------------------------------------------------------------------------
# Database tier — from the web tier, plus self-reference for replication.
#
# `self = true` means "any instance carrying THIS security group," which is how
# the primary and replica reach each other without hardcoding private IPs that
# change on instance replacement.
# ---------------------------------------------------------------------------
resource "aws_security_group" "db" {
  name        = "${var.project}-db-sg"
  description = "Database tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
    description     = "MySQL from application tier"
  }

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    self        = true
    description = "Replication between primary and replica"
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
    description     = "SSH via bastion only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-db-sg" }
}
