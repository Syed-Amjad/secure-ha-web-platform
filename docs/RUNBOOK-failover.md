# Runbook — Failover

Written to be followed **by someone who did not build this**, at 3 a.m., without
asking anyone. If you cannot hand this to a colleague and have them succeed, it
is not finished.

**Before you start:** note the time. Every step below asks you to record one.

---

## Scenario A — A web node is unhealthy

### Symptoms

- ALB target group shows 1 of 2 targets unhealthy
- Response times roughly double (one node carrying all traffic)
- `curl https://lab.syedamjad.com/healthz` still returns 200

### Impact

**None to users, if the other node is healthy.** The ALB stops sending traffic
to a target after 2 consecutive failed checks at 15-second intervals, so worst
case is roughly 30 seconds of some requests failing.

### Action

```bash
# 1. Which target is down?
aws elbv2 describe-target-health \
  --target-group-arn "$(cd terraform && terraform output -raw web_tg_arn 2>/dev/null || \
     aws elbv2 describe-target-groups --names ha-web-platform-web-tg \
       --query 'TargetGroups[0].TargetGroupArn' --output text)"

# 2. Get onto it through the bastion
ssh -J ubuntu@<BASTION_IP> ubuntu@<WEB_PRIVATE_IP>

# 3. Work down the stack, in this order
systemctl status webapp          # the application first
systemctl status nginx           # then the proxy
curl -s localhost:8080/healthz   # then the local path end to end
sudo journalctl -u webapp -n 100 --no-pager
sudo tail -50 /var/log/nginx/webapp.error.log
```

### Most common causes, in order

| Symptom | Cause | Fix |
|---|---|---|
| `webapp` inactive | Process died, usually OOM on t3.small | `systemctl restart webapp`, then check `dmesg -T \| grep -i oom` |
| nginx running, app not | Systemd unit failed after a config change | `journalctl -u webapp -n 50` |
| Both running, health check still failing | firewalld rule lost after a manual change | `firewall-cmd --list-all` — port 8080 must be allowed from the VPC |
| Health check failing intermittently | `/healthz` is being rate limited | Confirm `location = /healthz` has **no** `limit_req` |

### If you cannot fix it in 10 minutes

Stop debugging and restore capacity first:

```bash
aws ec2 reboot-instances --instance-ids <ID>
# still broken after 3 minutes → rebuild it
cd terraform && terraform taint 'aws_instance.web[0]' && terraform apply
cd ../ansible && ansible-playbook site.yml --limit web
```

**Record:** time detected, time restored, number of failed user requests.

---

## Scenario B — The database primary is lost

This is the one that matters. Read the whole section before typing anything.

### Symptoms

- Application returns database errors; `/db` shows `"reachable": false`
- `SHOW REPLICA STATUS\G` on the replica shows `Replica_IO_Running: Connecting`

### Decide first: is the primary actually gone?

**Do not promote a replica whose primary is merely slow.** Two writable
databases is worse than one unavailable one — you get split-brain, and merging
divergent data afterwards is manual, error-prone work.

```bash
# From the bastion
ping -c3 <PRIMARY_PRIVATE_IP>
aws ec2 describe-instance-status --instance-ids <PRIMARY_ID>
ssh -J ubuntu@<BASTION_IP> ubuntu@<PRIMARY_PRIVATE_IP> systemctl status mysql
```

**Promote only if** the instance is stopped/terminated, or mysqld will not start
and the cause is not fixable within your RTO target.

### Step 1 — Fence the old primary

If it is reachable at all, make sure it cannot accept writes if it comes back:

```bash
sudo systemctl stop mysql
sudo systemctl disable mysql   # so a reboot does not resurrect it silently
```

Skipping this is how you end up with two primaries.

### Step 2 — Confirm the replica has caught up (this determines your RPO)

```sql
-- On the replica
SHOW REPLICA STATUS\G
```

Read these:

| Field | What it means |
|---|---|
| `Seconds_Behind_Source` | `0` or `NULL`-with-`Retrieved_Gtid_Set == Executed_Gtid_Set` means nothing was lost |
| `Retrieved_Gtid_Set` | What arrived from the primary |
| `Executed_Gtid_Set` | What has been applied |

**If `Retrieved` is ahead of `Executed`, wait.** The replica is still applying
transactions it already has, and those are transactions you would otherwise
throw away. Anything in `Retrieved` but never applied — or never retrieved — is
your data loss. **That difference is your measured RPO. Write it down.**

### Step 3 — Promote

```sql
-- On the replica
STOP REPLICA;
RESET REPLICA ALL;             -- forget the old source permanently
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only       = OFF;

-- Verify
SELECT @@read_only, @@super_read_only;   -- both must be 0
```

Make it survive a reboot, or the next restart silently reverts to read-only and
you debug it twice:

```bash
sudo sed -i 's/^read_only.*/read_only = OFF/;s/^super_read_only.*/super_read_only = OFF/' \
  /etc/mysql/mysql.conf.d/zz-ha.cnf
```

### Step 4 — Repoint the application

```bash
cd ansible
ansible-playbook site.yml --limit web \
  -e "db_primary_private_ip=<REPLICA_PRIVATE_IP>" \
  -e "app_db_password=<PASSWORD>"
```

Confirm end to end:

```bash
curl -s https://lab.syedamjad.com/db     | jq
curl -s https://lab.syedamjad.com/write  | jq   # must return "written": true
```

**Record: time of loss → time writes resumed. That is your measured RTO.**

### Step 5 — You now have no replica

Say this out loud, because it is the step people forget in the relief of being
back up. **You are one failure from an outage with no standby.**

Rebuild a replica the same day:

```bash
cd terraform && terraform taint aws_instance.db_primary && terraform apply
cd ../ansible && ansible-playbook site.yml --limit db_primary
# then reverse the roles in the inventory so the new node is the replica
```

---

## Scenario C — Restore from backup

Use when data is lost or corrupted rather than a host being down. This is the
only path that helps against accidental `DELETE`, a bad migration, or ransomware
— none of which the replica protects you from, because **the replica faithfully
replicates the mistake.**

```bash
export BACKUP_BUCKET=$(cd terraform && terraform output -raw backup_bucket)

# Always dry-run into a throwaway container first
./scripts/restore-verify.sh
```

Then restore for real:

```bash
aws s3 ls "s3://${BACKUP_BUCKET}/logical/"
aws s3 cp "s3://${BACKUP_BUCKET}/logical/mysql-<STAMP>.sql.gz" .
aws s3 cp "s3://${BACKUP_BUCKET}/logical/mysql-<STAMP>.sql.gz.sha256" .
sha256sum -c mysql-<STAMP>.sql.gz.sha256      # never skip this

scp -o "ProxyJump ubuntu@<BASTION_IP>" mysql-<STAMP>.sql.gz ubuntu@<DB_IP>:/tmp/
ssh -J ubuntu@<BASTION_IP> ubuntu@<DB_IP>
gunzip -c /tmp/mysql-<STAMP>.sql.gz | sudo mysql
```

**The dump contains `SET @@GLOBAL.GTID_PURGED`.** Restoring onto a server with
existing GTID history fails. Clear it first:

```sql
RESET BINARY LOGS AND GTIDS;   -- MySQL 8.0.22+; older: RESET MASTER
```

After a restore, **replication is broken** — the replica's GTID set no longer
matches. Rebuild the replica from the same dump rather than hoping.

---

## Scenario D — Locked out of everything

### You cannot SSH to the bastion

Almost always your public IP changed:

```bash
curl -4 ifconfig.me
# differs from admin_cidr → update terraform.tfvars and:
cd terraform && terraform apply -target=aws_security_group.bastion
```

### You cannot SSH to a private node, but the bastion is fine

```bash
ssh-add -l                       # is the key actually loaded?
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/ha-lab.pem
ssh -vv -J ubuntu@<BASTION> ubuntu@<PRIVATE_IP>
```

If the second hop fails on `channel 0: open failed`, check
`AllowTcpForwarding yes` on the **bastion** — ProxyJump *is* TCP forwarding, and
hardening it to `no` turns the jump host into a dead end.

### fail2ban banned you

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip <YOUR_IP>
```

Your address and the VPC are in `ignoreip`, so this should not happen — if it
did, `admin_cidr` was wrong when the playbook ran.

### The site is down but AWS looks healthy

Check the Cloudflare side, in this order:

1. Is the DNS record still proxied (orange cloud)?
2. Did a WAF or geo rule start matching your own traffic? Check the Security
   Events log.
3. Is Authenticated Origin Pulls enabled while the ALB cannot present the
   expected certificate?
4. **Did a rule get added without the `http.host` filter?** Then it is also
   affecting `syedamjad.com` — check your portfolio too.
