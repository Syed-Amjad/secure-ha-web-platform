# ---------------------------------------------------------------------------
# ⚠ EVERY rule expression is scoped with local.host_filter.
#
# Cloudflare WAF, rate-limiting and geo rules are ZONE-WIDE. A rule written
# without a hostname condition also applies to syedamjad.com — so a geo-challenge
# rule would start challenging visitors to your portfolio, and you would find out
# from a support message rather than a dashboard.
#
# local.host_filter is defined in main.tf as:
#   http.host eq "lab.syedamjad.com"
# ---------------------------------------------------------------------------

locals {
  # http.request.uri.query is the RAW query string — Cloudflare does not decode
  # it. "?id=1'%20OR%20'1'='1" arrives as literally that, so `contains "' or '"`
  # never matches: the field holds "'%20or%20'". Decode first, then lower() for
  # case-insensitive matching. Both are Rules-language transformation functions
  # and are available on the Free plan.
  decoded_query = "lower(url_decode(http.request.uri.query))"
}

resource "cloudflare_ruleset" "waf_managed" {
  zone_id = var.cloudflare_zone_id
  name    = "Managed WAF - ${var.project}"
  kind    = "zone"
  phase   = "http_request_firewall_managed"

  # FREE PLAN. The Cloudflare Managed Ruleset (efb7b8c9…) and OWASP Core Ruleset
  # (4814384a…) are Pro-and-above; deploying them on a Free zone fails with
  # "not entitled to execute this managed ruleset". The Free Managed Ruleset is
  # the entitled substitute — a narrow set of high-severity signatures
  # (Log4j, Shellshock and similar), NOT general OWASP coverage.
  #
  # On Pro: restore the two rules above and delete the SQLi rule in the custom
  # ruleset below, which exists only to cover this gap.
  #
  # Confirm the ID against your own zone before applying:
  #   curl -s -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
  #     "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets" \
  #     | jq -r '.result[] | select(.kind=="managed") | "\(.id)  \(.name)"'
  #
  # Deliberately NOT scoped with local.host_filter. Cloudflare deploys this
  # ruleset zone-wide by default on Free plans, and this resource takes over the
  # phase entrypoint — scoping it to lab.syedamjad.com would strip the protection
  # from the apex. The host filter exists to stop rules that *harm* normal
  # visitors (geo challenges, admin blocks); exploit signatures do not.
  rules {
    action = "execute"
    action_parameters {
      id = "77454fe2d30c4220b5701f6fdfb893ba" # Cloudflare Free Managed Ruleset
    }
    expression  = "true"
    enabled     = true
    description = "Cloudflare Free Managed Ruleset (zone-wide)"
  }
}

resource "cloudflare_ruleset" "geo" {
  zone_id = var.cloudflare_zone_id
  name    = "Custom firewall - ${var.project}"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  # managed_challenge, NOT block.
  #
  # Hard-blocking whole countries also blocks legitimate users behind a VPN and
  # customers who are travelling, and you only discover it through a support
  # ticket. A challenge stops automation while letting a real person through.
  rules {
    action      = "managed_challenge"
    expression  = "(${local.host_filter} and not ip.geoip.country in {${join(" ", formatlist("\"%s\"", var.geo_allowed_countries))}})"
    description = "Challenge traffic outside served regions"
    enabled     = true
  }

  rules {
    action      = "block"
    expression  = "(${local.host_filter} and http.request.uri.path contains \"/admin\" and not ip.src in {${var.admin_ip}})"
    description = "Admin paths restricted to known addresses"
    enabled     = true
  }

  # FREE PLAN gap-filler. The Free Managed Ruleset carries no SQLi signatures, so
  # the injection check in the README returns 200 without this rule.
  #
  # Be honest about what this is: string matching, not the grammar-aware detection
  # the OWASP Core Ruleset does. It catches the demo payload and naive scanners;
  # it does not catch an attacker who encodes or fragments the query. Delete it on
  # Pro and let the real ruleset do the work. Record the distinction in
  # docs/DR-test-results.md rather than claiming OWASP coverage.
  rules {
    action      = "block"
    expression  = "(${local.host_filter} and (${local.decoded_query} contains \"union select\" or ${local.decoded_query} contains \"' or '\" or ${local.decoded_query} contains \"or 1=1\" or ${local.decoded_query} contains \"sleep(\"))"
    description = "Block naive SQL injection patterns (Free plan substitute for OWASP)"
    enabled     = true
  }
}

resource "cloudflare_ruleset" "rate_limit" {
  zone_id = var.cloudflare_zone_id
  name    = "Rate limiting - ${var.project}"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules {
    action = "block"

    # FREE PLAN limits: one rate-limiting rule per zone, counting period fixed at
    # 10s, mitigation timeout fixed at 10s. period = 60 fails with
    # "not entitled to use the period 60, can only use a period among [10]".
    #
    # On Pro: period = 60, mitigation_timeout = 600 — i.e. 10 attempts per minute
    # then a 10-minute lockout, which is the control this project intends. What is
    # below is 10 per 10s with a 10s lockout: it still stops a credential-stuffing
    # loop, but a patient attacker gets 60/minute rather than 10.
    ratelimit {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 10
      requests_per_period = 10
      mitigation_timeout  = 10
    }

    expression  = "(${local.host_filter} and http.request.uri.path eq \"/login\")"
    description = "10 login attempts per 10s per IP (Free plan floor)"
    enabled     = true
  }
}

# Authenticated Origin Pulls — the ALB then accepts TLS connections only when
# the client presents Cloudflare's origin certificate. Combined with the ALB
# security group locked to Cloudflare's ranges, this closes the bypass path
# completely: knowing the ALB hostname is no longer enough.
resource "cloudflare_authenticated_origin_pulls" "main" {
  zone_id = var.cloudflare_zone_id
  enabled = true
}

# Force TLS between Cloudflare and the origin. "Flexible" mode would show a
# padlock in the browser while sending plaintext HTTP to your ALB.
resource "cloudflare_zone_settings_override" "main" {
  zone_id = var.cloudflare_zone_id

  settings {
    ssl                      = "full"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    tls_1_3                  = "on"
    automatic_https_rewrites = "on"
    security_header {
      enabled            = true
      include_subdomains = false
      max_age            = 31536000
      nosniff            = true
      preload            = false
    }
  }
}
