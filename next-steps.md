# Next steps — verification and teardown

Seven proofs, sequenced so the destructive ones come last. Each produces a number
or a status code that belongs in [`docs/DR-test-results.md`](docs/DR-test-results.md)
— the file that turns an architecture diagram into evidence.

This is the README's "Proving it works" section, reordered, with your own values
filled in and the gaps closed.

---

## Your environment

| | |
|---|---|
| Bastion | `$BASTION` — changes on every stop/start, exported at start of day |
| DB primary | `10.20.10.144` |
| DB replica | `10.20.11.69` |
| web-1 | `10.20.10.251` — `i-0befb513b32f48ef9` |
| web-2 | `10.20.11.250` — `i-07ac8b767309b70ce` |
| Backup bucket | `ha-web-platform-db-backups-965096109714` |
| ALB hostname | `ha-web-platform-alb-1457563835.us-east-1.elb.amazonaws.com` |
| Site | `https://lab.syedamjad.com` |

Private IPs and instance IDs survive a stop/start. Only `bastion_public_ip`
changes — the start-of-day block below re-reads it into `$BASTION`, which every
`ssh -J` command in this file uses.

---

## Progress

| | Test | Result |
|---|---|---|
| ✅ | 1. Replication is replicating | Both threads `Yes`, `Seconds_Behind_Source: 0` |
| ✅ | 2. WAF blocks injection | `403` after the `url_decode()` fix |
| ✅ | 3. Login is rate limited | 11 × `200`, then `429` for the remaining 19 |
| ✅ | 4. ALB refuses to answer directly | `curl: (28) Connection timed out after 10047 ms`, `exit=28` |
| ✅ | 5. Replica refuses a write | Error 1290 on `/write`; `/db` shows `server_id: 2`, `super_read_only: true` |
| ◐ | 6. Backup and verified restore | Restore **passed** — checksum `OK`, 5 rows, recovery time **1s**. Integrity check was a silent no-op (finding 6); fixed, one re-run needed for a complete row |
| ✅ | 7. Failover drill | web-1: 7/69 failed, 89.86%. web-2: 7/68, 89.71%. **0s full outage**, ~28s degraded — matches `interval 15 × threshold 2` |

> **Test 6 does not need the lab running.** `restore-verify.sh` only touches S3
> and Docker — the EC2 instances can be stopped. It is the one test you can do
> before `lab-up.sh` or after `lab-down.sh`.

Outstanding from test 3: check **Security → Events** to confirm whether Cloudflare
or nginx returned the 429. Eleven successes is consistent with either — Cloudflare
allows 10 per 10s, and nginx's `burst=5` across two alternating nodes lands in the
same range. Re-trigger the loop, then while still blocked:

```bash
curl -sD- -o /dev/null https://lab.syedamjad.com/login | grep -iE 'HTTP/|^server:|cf-mitigated|cf-ray'
```

An nginx-generated 429 says `Server: nginx`; a Cloudflare one says
`Server: cloudflare` and usually carries `cf-mitigated`.

---

## Start of day

```bash
source ~/.ha-lab/cf-token.sh
cd ~/projects/ha-web-platform
./scripts/lab-up.sh
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/ha-lab.pem
export BASTION=$(cd terraform && terraform output -raw bastion_public_ip)
```

If `lab-up.sh` reports hosts unreachable, your home IP changed overnight and the
bastion security group no longer admits you:

```bash
curl -4 ifconfig.me
# update BOTH admin_cidr (with /32) and admin_ip (bare) in terraform/prod.auto.tfvars
cd terraform && terraform apply
```

Both values move together — `admin_cidr` gates SSH, `admin_ip` gates the
Cloudflare `/admin` rule.

## End of day

```bash
source ~/.ha-lab/cf-token.sh    # lab-down.sh runs terraform apply
./scripts/lab-down.sh
```

---

## Before you start

Four things must be true. Right now the platform is one playbook run short —
`nginx_app` has never completed on either web node, so nothing serves the site.

- [ ] **The playbook is green.** All five hosts at `failed=0`, including the
      `Assert replication is healthy` task.
- [ ] **The Cloudflare token is in your shell** — `source ~/.ha-lab/cf-token.sh`.
      Anything that runs `terraform` needs it.
- [ ] **Your SSH key is in the agent** — `ssh-add -l` lists `ha-lab.pem`.
      ProxyJump cannot authenticate the second hop without it.
- [ ] **Docker is running in WSL** — `docker info` succeeds. Test 6 restores into
      a throwaway container.

```bash
cd ~/projects/ha-web-platform/ansible
ansible-playbook site.yml -e @~/.ha-lab/db-secrets.yml
```

Then confirm the load balancer is alternating:

```bash
for i in $(seq 1 10); do curl -s https://lab.syedamjad.com/ | grep -o 'ip-10-20-[0-9-]*'; done
```

Both `ip-10-20-10-251` (web-1) and `ip-10-20-11-250` (web-2) should appear.

> **The README is wrong here.** It says the node name alternates between `web-1`
> and `web-2`. The app reports `socket.gethostname()`, which on EC2 is the
> private-DNS name — `web-1` / `web-2` exist only as Terraform `Name` tags and
> never reach the operating system. Grep for the `ip-10-20-*` form instead.

### Why this order, not the README's

Two tests mutate the lab: test 5 repoints an app node at the replica, and test 7
stops an EC2 instance. The README interleaves them with the read-only checks.
Running them in the order below captures every non-destructive proof first, so a
surprise in test 7 never invalidates evidence you already gathered.

---

## 1. Replication is actually replicating

Checks the fields, not the vibe. Also the precondition for tests 5, 6 and 7 — a
broken replica invalidates all three.

```bash
ssh -J ubuntu@$BASTION ubuntu@10.20.11.69 \
  "sudo mysql -e 'SHOW REPLICA STATUS\G'" | \
  grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error'
```

**Pass:** both `Replica_IO_Running` and `Replica_SQL_Running` say `Yes`,
`Seconds_Behind_Source` is `0`, and every `Last_*Error` line is empty.

**If it fails:** `Last_IO_Error` naming error 1236 means the GTID reset did not
run before the replica connected. An access-denied error means the primary and
replica hold different `repl` passwords — re-run the full playbook, never with
`--limit`.

---

## 2. The WAF blocks an injection attempt

Proves traffic genuinely passes through Cloudflare's rule engine before reaching
your origin.

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://lab.syedamjad.com/?id=1'%20OR%20'1'='1"
```

**Pass:** `403`. Confirm in the dashboard under **Security → Events** — the entry
should name the rule *Block naive SQL injection patterns*.

> **Be precise about what this proves.**
> On your Free plan this block comes from the hand-written custom rule, not the
> OWASP Core Ruleset — that one is Pro-only and refused to deploy. The rule
> matches the substring `' or '`. It stops the demo payload and naive scanners;
> it does not do the grammar-aware detection OWASP does, and an attacker who
> encodes the query walks past it.
>
> Say exactly that in the write-up. "Cloudflare WAF blocked SQLi" would be
> overclaiming, and it is the kind of thing an interviewer probes.

---

## 3. Login is rate limited

Two independent limiters sit in this path. Knowing which one fired is the
interesting part.

```bash
for i in $(seq 1 30); do
  curl -s -o /dev/null -w '%{http_code} ' https://lab.syedamjad.com/login
done; echo
```

**Pass:** a run of `200`s followed by `429`s for the remainder. Expect the switch
between the 6th and 12th request.

**Which limiter fired:**

- **Cloudflare** caps 10 requests per 10 seconds at the edge — the Free plan will
  not accept the 60-second period the project intended.
- **nginx** caps `/login` at `5r/m` with `burst=5 nodelay`, *per node*, and the
  ALB alternates nodes, so that budget is effectively doubled.

Check **Security → Events**. Entries there mean Cloudflare stopped it; an empty
log means the request reached nginx and nginx returned the 429. Both are real
defence in depth — record which one you observed.

**Afterwards:** Cloudflare holds the block for 10 seconds. Wait that out before
the next test or you will attribute a stale 429 to the wrong thing.

Bonus artifact — evidence the fail2ban jail is live rather than merely installed:

```bash
ssh -J ubuntu@$BASTION ubuntu@10.20.10.251 \
  'sudo fail2ban-client status nginx-limit-req'
```

---

## 4. The ALB refuses to answer directly

The check people skip. Without it the WAF is decorative — anyone who finds the
ALB hostname bypasses Cloudflare entirely.

```bash
curl -m 10 "https://ha-web-platform-alb-1457563835.us-east-1.elb.amazonaws.com/healthz"
echo "exit=$?"
```

**Pass:** `Connection timed out` and `exit=28`. The security group admits only
Cloudflare's ranges, so your packets are dropped with no reply at all.

**If it fails:** anything other than a timeout is a finding. A TLS certificate
error means the SG let you through and only the certificate name stopped you —
still a bypass. A `200` means the origin is fully exposed. Re-check the ALB
security group against `cloudflare_ipv4_ranges` and re-run
`./scripts/update-cloudflare-ranges.sh`.

A timeout is a boring screenshot but a strong one. Capture the `exit=28` line —
it is unambiguous in a way a blank terminal is not.

---

## 5. The replica refuses a write

Proves `super_read_only` is doing real work — the replica cannot silently diverge
from the primary.

The README says "against a repointed app" without saying how. The app reads
`DB_HOST` from `/etc/webapp.env`, which points at the primary. Repoint **one**
node and curl it locally, rather than repointing both and hoping the ALB picks
the right one.

**Baseline first** — confirm the write path works before breaking it:

```bash
curl -s https://lab.syedamjad.com/write | jq
# {"written": true}
```

**Repoint web-2 at the replica:**

```bash
ssh -J ubuntu@$BASTION ubuntu@10.20.11.250

sudo sed -i 's/^DB_HOST=.*/DB_HOST=10.20.11.69/' /etc/webapp.env
sudo systemctl restart webapp
curl -s localhost:8080/write | jq
curl -s localhost:8080/db    | jq
```

**Pass — screenshot both:**

- `/write` returns `"written": false` with error **1290**, *"The MySQL server is
  running with the --read-only option so it cannot execute this statement"*.
  MySQL names the weaker `--read-only` flag in that message even when
  `super_read_only` is what actually enforces it — don't read it as the wrong
  flag being set.
- `/db` returns `"read_only": true`, `"super_read_only": true`, and a `server_id`
  different from the primary's. This is the stronger half of the proof.

That pair is the whole proof in two screenshots.

**Revert before test 6.** Leaving web-2 pointed at the replica means half your
traffic silently loses its write path. Re-running the playbook is the safest
revert — it rewrites `/etc/webapp.env` from the template and restarts the service:

```bash
ansible-playbook site.yml -e @~/.ha-lab/db-secrets.yml --limit web
curl -s https://lab.syedamjad.com/write | jq   # back to "written": true
```

---

## 6. A backup that has actually been restored

The differentiator. Almost everyone stops at "the backup script exited 0" — a
backup you have never restored is a hypothesis.

> **There is no backup in S3 yet.** The systemd timer fires at **02:30 UTC daily**
> with up to 15 minutes of random delay. Unless the lab has been running across
> that window, `restore-verify.sh` exits with *no backups found*. Trigger one by
> hand first.

```bash
ssh -J ubuntu@$BASTION ubuntu@10.20.10.144 \
  'sudo systemctl start mysql-backup.service && \
   sudo systemctl status mysql-backup.service --no-pager -l'

aws s3 ls s3://ha-web-platform-db-backups-965096109714/logical/
```

You should see a `.sql.gz` and its `.sha256` companion. Then run the restore:

```bash
cd ~/projects/ha-web-platform
export BACKUP_BUCKET=ha-web-platform-db-backups-965096109714
./scripts/restore-verify.sh
```

**Pass:** the tail reads `schemas: 1`, `tables: 1`, `visits rows: N`,
`All tables OK`, then `RESTORE VERIFIED — recovery time NNs`. That last number is
your restore RTO.

**If it fails:**

- *Cannot connect to the Docker daemon* → `sudo service docker start`.
- A checksum mismatch is a genuine finding worth writing up rather than retrying
  quietly.
- A `GTID_PURGED` complaint means the scratch container kept state from a
  previous run — `docker rm -f` anything named `restore-verify-*`.

Record every column of the restore table: backup filename, size, checksum
verified, restore seconds, schema and table counts, row count, mysqlcheck result.

---

## 7. Failover drill — the destructive one

Measures the actual gap when a web node dies, rather than asserting there isn't
one. Runs for about two and a half minutes.

```bash
cd ~/projects/ha-web-platform
./scripts/ha-failover-drill.sh https://lab.syedamjad.com/healthz i-0befb513b32f48ef9
```

**Expect failures — that is the honest result.** The target group health-checks
every **15s** and needs **2** consecutive failures, so the ALB takes up to 30
seconds to notice a dead node. It keeps round-robining into it during that
window, so roughly half the probes in those 30 seconds return non-200.

A realistic result is **8–15 failed probes** and **88–94% availability**. RTO is
the count of consecutive non-200 seconds.

**If you see 100%, investigate rather than celebrate.** Zero failures almost
always means the instance had not finished stopping before the observation window
closed. Check the instance state and re-run. A drill that always passes is
measuring nothing.

**Restart the node afterwards** — the script will not do it for you:

```bash
aws ec2 start-instances --instance-ids i-0befb513b32f48ef9
```

Private IPs survive a stop/start, so the Ansible inventory stays valid. Once it
is healthy again, repeat with `i-07ac8b767309b70ce` to fill row 2 of the drill
table — a single drill on a single node is one data point, not a pattern.

> **Row 3 is a different exercise.** "DB primary loss → replica promoted" is not
> covered by this script. It is the manual procedure in
> [`docs/RUNBOOK-failover.md`](docs/RUNBOOK-failover.md), and its RTO is
> wall-clock from stopping mysqld on the primary to the first successful write
> against the promoted replica. Do that one only after tests 1–7 are recorded —
> it leaves the cluster in a promoted state you then have to unwind.

---

## Where each result lands

Fill the row in as you go, not afterwards from memory.

| Test | Goes into | The number that matters |
|---|---|---|
| 1 | Precondition — no row | `Seconds_Behind_Source` |
| 2 | Observations → residual risks | 403, plus the plan-tier caveat |
| 3 | Observations | Request number of the first 429 |
| 4 | Observations | `curl` exit 28 |
| 5 | Observations → what went wrong | MySQL error 1290 |
| 6 | Restore verification log | Restore seconds, row count |
| 7 | Failover drills, rows 1–2 | RTO seconds, failed probes, availability % |

**The section that carries the most weight** is "What went wrong during drills",
and you already have three genuine entries:

1. The nginx `reload nginx` handler written as a `block:`, which handlers do not
   support — aborted the first playbook run with "handler not found".
2. The replica's `stopreplica` trapped inside a first-run-only guard, so
   `CHANGE REPLICATION SOURCE TO` hit running threads on every later run. The
   role worked exactly once.
3. Cloudflare's Free plan refusing both the OWASP Core Ruleset and a 60-second
   rate-limit period, forcing a documented substitution.
4. The replacement SQLi rule returning `200` on its first test: Cloudflare's
   `http.request.uri.query` is the **raw** query string, so `contains "' or '"`
   was being matched against `'%20or%20'` and never fired. Fixed by wrapping the
   field in `url_decode()`. A WAF rule that silently matches nothing is worse
   than no rule, because the dashboard shows it as deployed and green.
5. `restore-verify.sh` failing twice with two *different* errors — `ERROR 2002`
   then `ERROR 1045` — from identical runs. Its readiness loop used
   `mysqladmin ping`, which exits 0 even on access-denied, and the official MySQL
   image runs a temporary server during initialisation that then shuts down. The
   probe was passing against a server about to disappear. Fixed by waiting for
   `ready for connections ... port: 3306` in the container log plus an
   authenticated `SELECT 1`. A non-deterministic failure is the tell: the same
   input producing two different errors means a race, not a config problem.

Those read as someone who debugged the thing. A table of unbroken green reads as
someone who deleted the interesting rows.

Both code fixes are also worth adding as rows 10 and 11 of the README's
"Corrections made" table.

---

## Teardown

Only when you are finished with the evidence. Overnight, use `lab-down.sh`
instead — `terraform destroy` rebuilds infrastructure without the state inside
it, so you would reseed the database every morning.

### Blocker 1 — the backup bucket is not empty

`aws_s3_bucket.backups` has versioning on and no `force_destroy`, so destroy
fails with `BucketNotEmpty`. Current object versions and delete markers both have
to go:

```bash
BUCKET=ha-web-platform-db-backups-965096109714

aws s3 rm "s3://$BUCKET" --recursive

# then the versions and delete markers versioning left behind
for KEY in Versions DeleteMarkers; do
  aws s3api list-object-versions --bucket "$BUCKET" \
    --query "{Objects: $KEY[].{Key:Key,VersionId:VersionId}}" --output json > /tmp/del.json
  grep -q '"Objects": null' /tmp/del.json && continue
  aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/del.json
done
```

### Blocker 2 — the zone settings resource

`cloudflare_zone_settings_override` restores every setting it snapshotted on
destroy, including ones that are read-only on a Free zone. That is the
`sort_query_string_for_cache` error you already hit once. If it reappears, drop
the resource from state and let the settings stand — they are good settings and
nothing is billing for them:

```bash
terraform state rm cloudflare_zone_settings_override.main
```

### The destroy itself

```bash
source ~/.ha-lab/cf-token.sh
cd ~/projects/ha-web-platform/terraform && terraform destroy

# an orphaned EIP or volume bills quietly
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]'
aws ec2 describe-volumes --filters Name=status,Values=available
```

### One thing destroy cannot undo

The HSTS header you enabled is zone-wide, with a one-year max-age. Every browser
that has loaded `syedamjad.com` or `lab.syedamjad.com` will refuse plain HTTP for
that domain for a year, regardless of what Terraform tears down. Not a problem —
just not reversible.
