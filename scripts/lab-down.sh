#!/usr/bin/env bash
# End of day. Stops the instances and releases the NAT gateways.
#
# EBS volumes persist across stop/start, so MySQL data, replication state,
# installed packages, firewalld rules and fail2ban jails all survive. Only the
# public IPv4 addresses change — which is what gen-inventory.sh exists for.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../terraform"

IDS=$(terraform output -json instance_ids | jq -r '.[]' | tr '\n' ' ')
echo "==> Stopping: $IDS"
# shellcheck disable=SC2086
aws ec2 stop-instances --instance-ids $IDS >/dev/null
# shellcheck disable=SC2086
aws ec2 wait instance-stopped --instance-ids $IDS
echo "==> All instances stopped."

# NAT gateways cannot be stopped, only destroyed — and they bill continuously at
# roughly $0.045/hr each. They are stateless, so this loses nothing and Terraform
# fixes the routes on the way back up. Saves about $9 across a week.
echo "==> Releasing NAT gateways"
terraform apply -var nat_enabled=false -auto-approve

cat <<'EOF'

Stopped. The ALB and EBS volumes remain — roughly $0.80/day.

The ALB is left running deliberately: recreating it issues a NEW DNS name, which
breaks the Cloudflare CNAME and means re-validating the certificate path. Not
worth $0.54 a night.

Resume tomorrow with:  ./scripts/lab-up.sh
EOF
