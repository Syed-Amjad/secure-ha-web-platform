# Secure High-Availability Web Platform

Load-balanced application across two AZs, MySQL primary–replica with GTID
replication, encrypted backups with a **verified restore**, and a Cloudflare WAF
in front — with the failover actually drilled and the recovery numbers written
down.

Full explanation of *why* each decision is made: [`../01-secure-ha-web-platform.md`](../01-secure-ha-web-platform.md).
This README is the operating manual; that document is the reasoning.

---

## Read this first

The guide contains the code inline. This tree is that code, completed and made
runnable. **A few things were fixed or filled in along the way — you should know
which, because they differ from what the guide shows.**

### Gaps filled

The guide gives ~14 files inline; the repository layout calls for ~35. Written
from scratch here: `variables.tf`, `outputs.tf`, `network.tf` (VPC, subnets,
IGW, routing), `compute.tf`, `iam.tf`, `acm.tf`, `main.tf`, `prod.tfvars`, the
KMS key, target-group attachments, `site.yml`, every role's `tasks/`, `handlers/`
and `defaults/`, the demo application, the runbook, and this file.

### Corrections made

| # | Issue in the guide | What was done |
|---|---|---|
| 1 | `common_hardening` used `ansible.builtin.dnf` (RHEL) while everything else is Ubuntu | Converted to `apt`. firewalld kept, so `firewall-cmd --get-default-zone` in the acceptance checklist still works. |
| 2 | The firewalld rule allowed SSH from `admin_cidr` on **every** host | Private nodes receive SSH from the **bastion's private IP** after ProxyJump, not from your address — the original would have locked Ansible out on the second run. SSH sources are now per-host: `admin_cidr` on the bastion, `vpc_cidr` elsewhere. |
| 3 | Web/DB security groups had SSH from `var.admin_cidr` in §3, replaced by a bastion rule in §0.2 | Merged — only the bastion SG rule exists. |
| 4 | `alb.tf` referenced `aws_subnet.public_a` / `public_b`, but `network.tf` uses `count` | Unified on `aws_subnet.public[*]`. |
| 5 | `aws_kms_key.backups` and `aws_acm_certificate_validation.main` were referenced but never defined | Both written. |
| 6 | Cloudflare rules were zone-wide, and §0.3 warns to add a hostname filter to every one | Applied via `local.host_filter` — **every** rule expression is scoped. |
| 7 | Fresh Ubuntu MySQL creates pre-GTID "anonymous" transactions, so `SOURCE_AUTO_POSITION = 1` fails with a confusing error 1236 on a brand-new server | Binary logs and GTIDs are reset once, before any schema is created, guarded by a marker file. |
| 8 | `require_secure_transport = ON` means the app's TCP connection must use TLS | The app connects with TLS. It accepts MySQL's self-signed certificate — encryption without server authentication. Noted in the code and in `DR-test-results.md`. |
| 9 | nginx `limit_req` needs the real client IP, but Cloudflare and the ALB both sit in front | `set_real_ip_from` covers the Cloudflare ranges **and** the VPC hop. |

### Not from the guide, added because they are needed

`scripts/bootstrap-tfstate.sh` (Terraform cannot create the bucket holding its
own state) and `scripts/update-cloudflare-ranges.sh` (the guide says fetch the
ranges rather than hardcode them; this writes the Terraform and Ansible copies
from one fetch so they cannot drift).

---

## Prerequisites

```bash
sudo apt update
sudo apt install -y ansible mysql-client jq dos2unix docker.io unzip
sudo usermod -aG docker "$USER"       # log out of WSL and back in
ansible-galaxy collection install -r ansible/requirements.yml
```

Terraform, AWS CLI and git are assumed present.

**Four WSL2 things that will cost you an afternoon each:**

| Issue | Fix |
|---|---|
| Repo on `/mnt/c/` — 9p is slow and permissions surface as `0777` | Keep it at `~/projects/ha-web-platform` |
| SSH keys on `/mnt/c/` — `chmod 600` does not stick | Keys in `~/.ssh/`, `chmod 600` there |
| CRLF → `bad interpreter: /bin/bash^M` | `git config --global core.autocrlf input`, then `dos2unix scripts/*.sh` |
| Clock skew after Windows sleep → `SignatureDoesNotMatch` | `sudo hwclock -s` |

---

## First run, in order

```bash
# 0. Move the tree into the Linux filesystem — not /mnt/c
mv ha-web-platform ~/projects/ && cd ~/projects/ha-web-platform
chmod +x scripts/*.sh
dos2unix scripts/*.sh            # if it came from Windows

# 1. Billing alarm BEFORE provisioning anything
aws budgets create-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget '{"BudgetName":"ha-lab","BudgetLimit":{"Amount":"40","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'

# 2. SSH key pair
aws ec2 create-key-pair --key-name ha-lab \
  --query KeyMaterial --output text > ~/.ssh/ha-lab.pem
chmod 600 ~/.ssh/ha-lab.pem

# 3. Fill in your values
cp terraform/environments/prod.tfvars terraform/prod.auto.tfvars
curl -4 ifconfig.me              # → admin_cidr (with /32) and admin_ip (without)
$EDITOR terraform/prod.auto.tfvars

# 4. Cloudflare API token — exported, never written to a file
export TF_VAR_cloudflare_api_token='...'

# 5. Refresh Cloudflare's edge ranges
./scripts/update-cloudflare-ranges.sh

# 6. Provision
cd terraform && terraform init && terraform apply
cd ..

# 7. Generate the inventory and load your key into the agent
./scripts/gen-inventory.sh
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/ha-lab.pem

# 8. Configure everything
cd ansible
ansible all -m ping
ansible-playbook site.yml \
  -e "repl_password=$(openssl rand -base64 24)" \
  -e "app_db_password=$(openssl rand -base64 24)"
```

> **Save those two generated passwords.** You will need them to re-run the
> playbook, and regenerating them mid-project breaks replication. Put them in
> `ansible-vault` rather than your shell history:
> `ansible-vault create group_vars/all/vault.yml`

Then open `https://lab.syedamjad.com` and reload a few times — the node name
should alternate between `web-1` and `web-2`.

---

## Daily rhythm

```bash
./scripts/lab-up.sh       # start of day: NAT back, instances started, inventory regenerated
./scripts/lab-down.sh     # end of day:   instances stopped, NAT released
```

**Do not `terraform destroy` overnight.** It rebuilds the infrastructure but not
the state inside it — you would lose the MySQL data, the replication setup and
every Ansible-applied change, and reseed the database every morning.

Stopping instances keeps EBS, so data, packages, configuration, firewalld rules
and fail2ban jails all survive. Only the public IPv4 addresses change, which is
exactly what `gen-inventory.sh` regenerates.

Roughly **$20 for a week** with NAT paused overnight, **$30** if left running.

---

## Proving it works

```bash
# Replication health — check the fields, not the vibe
ssh -J ubuntu@<BASTION> ubuntu@<REPLICA_IP> \
  "sudo mysql -e 'SHOW REPLICA STATUS\G'" | \
  grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error'

# The replica must REFUSE a write — screenshot this
curl -s https://lab.syedamjad.com/write | jq     # against a repointed app

# Verified restore
export BACKUP_BUCKET=$(cd terraform && terraform output -raw backup_bucket)
./scripts/restore-verify.sh

# Failover drill
./scripts/ha-failover-drill.sh https://lab.syedamjad.com/healthz \
  "$(cd terraform && terraform output -json web_instance_ids | jq -r '.[0]')"

# Rate limit — expect 429 after ~10
for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code} ' https://lab.syedamjad.com/login; done

# WAF — expect a block
curl -s -o /dev/null -w '%{http_code}\n' "https://lab.syedamjad.com/?id=1'%20OR%20'1'='1"

# The ALB must NOT answer directly — this is the check people skip
curl -m 10 "https://$(cd terraform && terraform output -raw alb_dns_name)/healthz"
```

**Write every result into [`docs/DR-test-results.md`](docs/DR-test-results.md).**
That file is the single most persuasive artifact in the project — it is evidence
rather than assertion.

---

## Tearing down

```bash
cd terraform && terraform destroy

# Then check nothing lingers — an orphaned EIP or volume bills quietly
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]'
aws ec2 describe-volumes --filters Name=status,Values=available
```

---

## Layout

```
ha-web-platform/
├── terraform/
│   ├── main.tf providers.tf variables.tf outputs.tf
│   ├── network.tf security_groups.tf compute.tf alb.tf acm.tf
│   ├── s3_backups.tf iam.tf cloudflare.tf
│   └── environments/prod.tfvars
├── ansible/
│   ├── ansible.cfg site.yml requirements.yml inventory.ini.example
│   ├── group_vars/all/{main,cloudflare}.yml  group_vars/bastion.yml
│   └── roles/
│       ├── common_hardening/  ← firewalld default-deny, sshd, sysctl, fail2ban
│       ├── nginx_app/         ← nginx rate limiting + the demo app
│       ├── mysql_primary/     ← GTID source, repl user, app schema
│       ├── mysql_replica/     ← super_read_only, auto-position replication
│       └── backup/            ← backup script, systemd timer, IAM-based S3 access
├── scripts/
│   ├── bootstrap-tfstate.sh        ← run once, before enabling remote state
│   ├── lab-up.sh / lab-down.sh     ← daily start and stop
│   ├── gen-inventory.sh            ← rebuild inventory from Terraform outputs
│   ├── update-cloudflare-ranges.sh ← keep the two allowlists in sync
│   ├── backup-mysql.sh             ← runs on the primary via systemd timer
│   ├── restore-verify.sh           ← run from WSL; needs Docker
│   └── ha-failover-drill.sh
└── docs/
    ├── RUNBOOK-failover.md
    └── DR-test-results.md          ← the file that proves it works
```
