# Certificate issuance and DNS validation, fully automated.
#
# The guide walks through doing this by hand with `aws acm request-certificate`.
# That works, but it is a manual step you would have to repeat every rebuild —
# so it is wired up here instead. The manual path stays valid if you prefer it.

resource "aws_acm_certificate" "main" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.project}-cert" }
}

# The validation record MUST NOT be proxied. An orange-clouded validation CNAME
# resolves to Cloudflare's edge instead of the value ACM is looking for, and the
# certificate sits in PENDING_VALIDATION forever.
resource "cloudflare_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = each.value.type
  value   = each.value.value # cloudflare provider v5 renames this to `content`
  ttl     = 60
  proxied = false # DNS only — grey cloud
  comment = "ACM DNS validation for ${var.domain_name}"

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in cloudflare_record.acm_validation : r.hostname]

  timeouts {
    create = "10m"
  }
}

# The site record itself IS proxied — that is what puts the WAF in the path.
resource "cloudflare_record" "site" {
  zone_id = var.cloudflare_zone_id
  name    = replace(var.domain_name, ".${data.cloudflare_zone.main.name}", "")
  type    = "CNAME"
  value   = aws_lb.main.dns_name
  ttl     = 1    # 1 == automatic, required when proxied
  proxied = true # orange cloud
  comment = "Managed by Terraform — ${var.project}"
}

data "cloudflare_zone" "main" {
  zone_id = var.cloudflare_zone_id
}
