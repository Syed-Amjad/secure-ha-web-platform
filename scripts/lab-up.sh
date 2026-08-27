#!/usr/bin/env bash
# Start of day. See section 0.4 — do NOT terraform destroy overnight, or you
# rebuild the infrastructure without the state inside it and reseed the database
# every morning.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../terraform"

echo "==> Restoring NAT gateways"
terraform apply -var nat_enabled=true -auto-approve

IDS=$(terraform output -json instance_ids | jq -r '.[]' | tr '\n' ' ')
echo "==> Starting: $IDS"
# shellcheck disable=SC2086
aws ec2 start-instances --instance-ids $IDS >/dev/null
# shellcheck disable=SC2086
aws ec2 wait instance-running --instance-ids $IDS

# Public IPs change on restart, so the inventory has to be rebuilt before
# Ansible can reach anything.
echo "==> Regenerating inventory"
"$HERE/gen-inventory.sh"

echo "==> Waiting for SSH"
sleep 30

cd "$HERE/../ansible"
if ansible all -m ping; then
  echo "==> All hosts reachable."
else
  cat <<'EOF'

Some hosts did not answer. Usual causes, in order of likelihood:

  1. The SSH agent has no key loaded, so ProxyJump cannot authenticate the
     second hop:
       eval "$(ssh-agent -s)" && ssh-add ~/.ssh/ha-lab.pem
  2. Instances are still booting — wait 30s and retry.
  3. Your public IP changed, so the bastion security group no longer admits you:
       curl -4 ifconfig.me
     then update admin_cidr and re-apply.
EOF
  exit 1
fi
