# DR Test Results

**This file is the point of the project.** Everything else is an architecture
diagram, and architecture diagrams are free. Measured recovery numbers are not.

Fill in a row every time you run a drill. Do not tidy the failures out — a table
that only contains successes tells a reader you deleted the interesting rows.

Environment: `us-east-1`, two AZs, MySQL 8.0 on EC2 with GTID replication,
Cloudflare Free plan in front of an ALB. Raw terminal captures are in
[`evidence/`](evidence/).

---

## Failover drills

| # | Date (UTC) | Drill | RTO measured | RPO measured | Failed requests | Notes |
|---|---|---|---|---|---|---|
| 1 | 2026-08-27 12:04 | Web node loss (`web-1` / `i-0befb…` stopped) | **0s** full outage; **28s** degraded | 0 | 7 of 69 (89.86%) | No two failures consecutive — the surviving node served throughout |
| 2 | 2026-08-27 12:09 | Web node loss (`web-2` / `i-07ac8…` stopped) | **0s** full outage; **27s** degraded | 0 | 7 of 68 (89.71%) | Within 1s of drill 1 — detection time is deterministic, not luck |
| 3 | — | DB primary loss → replica promoted | not performed | — | — | Manual procedure in [`RUNBOOK-failover.md`](RUNBOOK-failover.md); left as future work |
| 4 | 2026-08-27 12:31 | Restore from S3 backup | **1s** restore; 24s end-to-end incl. download and container start | ≤ 5h (nightly schedule) | n/a | Two harness defects found and fixed before this passed — findings 5 and 6 |

### Reading the web-node numbers honestly

"89.86% availability" undersells what happened, and a reader who only sees that
number will draw the wrong conclusion.

**There was never a second where the site was down.** The failed probes are
interleaved with successful ones — no two are consecutive. With one of two nodes
dead, the ALB kept round-robining into the corpse until its health check caught
up, so roughly half of requests failed during that window while the other half
were served normally. The correct characterisation is a **28-second degraded
window at ~50% error rate**, not a 28-second outage.

**The window is exactly the configured detection time.** `terraform/alb.tf` sets
`interval = 15` and `unhealthy_threshold = 2`, so worst-case detection is 30
seconds. Both drills landed at 27–28s. That is the knob: shortening it trades
faster failover for more health-check traffic and more sensitivity to transient
blips.

**Two distinct failure modes appeared, in the order you would predict.** The
first two failures in each drill were `502` — the instance was still shutting
down, so the ALB received a connection reset from a dying backend. The remaining
five were `000` (client-side timeout at 2s) — the instance was fully gone, its
packets blackholed, and the ALB sat waiting for a backend that no longer existed.

**How each number is obtained**

- **Web node RTO** — `scripts/ha-failover-drill.sh` prints total probes, failed
  probes and availability. Full-outage RTO is the count of *consecutive* non-200
  seconds; the degraded window is first-failure to last-failure.
- **DB RTO** — wall-clock from stopping mysqld on the primary to the first
  successful write against the promoted replica (`/write` returns
  `"written": true`).
- **DB RPO** — the gap between `Retrieved_Gtid_Set` and `Executed_Gtid_Set` on
  the replica at the moment of promotion, converted to transactions. Zero if
  they matched.
- **Restore RTO** — the `recovery time NNs` line at the end of
  `scripts/restore-verify.sh`.

---

## Backup restore verification log

Every run of `scripts/restore-verify.sh`. A backup you have never restored is a
hypothesis, and a restore you ran once six months ago is a memory.

| Date (UTC) | Backup file | Size | SHA256 verified | Restore time | Schemas | Tables | `visits` rows | mysqlcheck | Result |
|---|---|---|---|---|---|---|---|---|---|
| 2026-08-27 12:03 | `mysql-20260827T072435Z.sql.gz` | 279,871 B | ✅ `OK` | — | — | — | — | — | **Harness failure** — readiness race, finding 5 |
| 2026-08-27 12:30 | `mysql-20260827T072435Z.sql.gz` | 279,871 B | ✅ `OK` | **1s** | 1 | 1 | 5 | ⚠️ never ran — finding 6 | Restore verified; integrity check silently skipped |
| *pending* | | | | | | | | | Re-run after the finding 6 fix, for a genuinely complete row |

**The backup path itself passed cleanly on every attempt**: `mysqldump` taken,
gzip integrity verified, SHA-256 computed and uploaded alongside the archive to a
versioned S3 bucket encrypted with a customer-managed KMS key, and
`sha256sum -c` confirmed `OK` after download. Only the *verification harness* was
broken. That distinction matters — the data was always recoverable; the tool that
proves it was not.

**The backup timer survives the overnight shutdown.** `mysql-backup.timer` sets
`Persistent=true`, so a run missed while the instances were stopped fires on next
boot instead of being silently skipped. Confirmed by backup timestamps of
`11:30Z` and `06:32Z` against a schedule of `02:30Z` — those are catch-up runs.
Worth noting because the cost-saving `lab-down.sh` pattern would otherwise
quietly disable the backups it was built alongside.

---

## Security control verification

| Control | Test | Result | Date |
|---|---|---|---|
| GTID replication healthy | `SHOW REPLICA STATUS` | `Replica_IO_Running: Yes`, `Replica_SQL_Running: Yes`, `Seconds_Behind_Source: 0`, no errors | 2026-08-27 |
| Replica rejects writes | `/write` against a repointed app node | Error **1290**, `super_read_only: true`, `server_id: 2` | 2026-08-25 |
| WAF blocks injection | `?id=1' OR '1'='1` | **403** | 2026-08-27 |
| Login rate limiting | 30 × `GET /login` | 8 × `200`, then `429` — Cloudflare **error 1015** | 2026-08-27 |
| **Origin cannot be reached directly** | `curl` the ALB hostname | **timeout, exit 28** | 2026-08-27 |
| fail2ban `nginx-limit-req` jail | `fail2ban-client status` | *pending* | — |

### Notes on what these prove, and what they do not

**The WAF block is a hand-written rule, not OWASP.** The Cloudflare Managed
Ruleset and OWASP Core Ruleset are Pro-and-above; deploying them on this Free
zone fails with *"not entitled to execute this managed ruleset"*. The substitute
is a custom rule matching four literal substrings after `url_decode()`. It stops
the demo payload and naive scanners. It does **not** do grammar-aware detection,
and an attacker who encodes or fragments the query walks past it. Claiming
"Cloudflare WAF blocked SQLi" here would be overclaiming.

**Rate limiting is looser than intended, for the same reason.** The Free plan
accepts only a 10-second counting period and a 10-second mitigation timeout; the
design called for 10 requests per minute with a 10-minute lockout. What is
deployed still stops a credential-stuffing loop, but a patient attacker gets
~60/minute rather than 10.

One request returned `200` in the middle of the blocked run. Cloudflare counts
per `["ip.src", "cf.colo.id"]` — the counter is per data centre and eventually
consistent, so a request reaching a different colo, or arriving before the
counter propagated, is not blocked. Expected behaviour for distributed edge rate
limiting, not a misconfiguration.

**The origin bypass test is the one that matters most.** A WAF an attacker can
skip is decorative. `exit 28` — a timeout, not a rejection — means packets to the
ALB are dropped outright for any source outside Cloudflare's published ranges.

---

## Observations worth recording

### What went wrong during drills

Six defects in the codebase, all found by running it rather than reading it.

**1. `nginx_app` handler written as a `block:`.** Ansible handlers do not support
blocks — the block's name is never registered, so `notify: reload nginx` aborted
the first playbook run with *"The requested handler 'reload nginx' was not
found"*. Fixed with two tasks sharing `listen: reload nginx`, which preserves the
validate-then-reload ordering the original intended.

**2. `mysql_replica` worked exactly once.** The `stopreplica` task sat inside the
`when: not gtid_reset_marker.stat.exists` block, so it ran only on first
configuration. Every subsequent run reached `CHANGE REPLICATION SOURCE TO` with
the replication threads still running, which MySQL rejects — and `no_log: true`
on that task hid the message entirely. Fixed by stopping replication
unconditionally before reconfiguring. The tell was that the role's own reset
tasks were *skipping*, which meant a marker file existed, which meant this was
not a first run.

**3. Cloudflare Free plan refused two controls.** Documented above and
substituted rather than quietly dropped.

**4. The replacement SQLi rule matched nothing.** It returned `200` on its first
test. Cloudflare's `http.request.uri.query` is the **raw** query string, so
`contains "' or '"` was being evaluated against `'%20or%20'` and could never
fire. Fixed by wrapping the field in `url_decode()`. A WAF rule that silently
matches nothing is worse than no rule at all, because the dashboard shows it
deployed and green.

**5. `restore-verify.sh` had a race in its readiness check.** Two identical runs
produced two *different* errors — `ERROR 2002 (socket)` then
`ERROR 1045 (access denied)`. The loop used `mysqladmin ping`, which exits 0 even
on access-denied because the server did respond; and the official MySQL image
runs a temporary server during initialisation which then shuts down. The probe
was succeeding against a server that was about to disappear. Fixed by waiting for
`ready for connections … port: 3306` in the container log plus an authenticated
`SELECT 1`. *The same input producing two different errors is the signature of a
race, not a configuration problem* — that observation is what pointed at the
readiness check instead of at MySQL or Docker.

**6. The integrity check reported success without running.** With the race fixed,
the restore completed — and the script printed `All tables OK` immediately after
`OCI runtime exec failed: exec: "mysqlcheck": executable file not found in
$PATH`. `mysqlcheck` is absent from recent `mysql:8.0` images. The `docker exec`
failed, the pipe carried nothing, `grep -v 'OK$'` exited non-zero on empty input,
and `|| log "All tables OK"` fired **on that failure**.

This is the most instructive defect of the six, because it is the failure mode
this entire project exists to guard against: a verification step that is green
while verifying nothing. A backup you have never restored is a hypothesis — and a
restore whose integrity check silently no-ops is the same hypothesis wearing a
tick mark.

Replaced with `CHECK TABLE` driven from `information_schema`, using the `mysql`
client that is always present. The new code fails loudly on empty output and
prints how many tables it checked, so "checked nothing" can never again render as
"everything is fine".

**6b. The replacement then failed the opposite way.** Because the new block
captures stderr — deliberately, so a real error cannot vanish — it also captured
`mysql: [Warning] Using a password on the command line interface can be
insecure`. That line does not end in `OK`, so it was reported as an integrity
problem. The check had actually passed. Fixed by passing the password through
`MYSQL_PWD` instead of `-p`, which suppresses the warning at source rather than
filtering it afterwards.

Worth recording as its own step: the first attempt produced a **false negative**
(green while checking nothing) and the second a **false positive** (red while
everything was fine). Both are failures of the same discipline — pattern-matching
mixed streams without controlling what is in them.

### An unplanned outage, which was more instructive than the scripted ones

On 2026-08-27 the DB primary (`10.20.10.144`) became SSH-unreachable at the start
of a session while the other four nodes were fine. Ansible reported
`Connection closed by UNKNOWN port 65535`.

That specific message was the diagnosis: it means the ProxyJump *tunnel* was
established — bastion and security groups healthy — but the far end never
completed an SSH handshake. A *timeout* would have meant packets disappearing,
i.e. a firewall or routing fault. Reading which failure had occurred ruled out
the entire network layer immediately and pointed at the host.

A soft reboot (`aws ec2 reboot-instances`) recovered it. Replication then
re-established itself across the unclean primary restart with **no manual
intervention** — both threads `Yes`, `Seconds_Behind_Source: 0`. That is an
unplanned resilience test that did not have to be staged, and it is better
evidence than any of the scripted drills.

### What I would change for a real production deployment

- **Replace the bastion with SSM Session Manager**: no SSH port open anywhere, no
  host to patch, no keys to distribute, every session logged in CloudTrail.
- **Use a managed database** (RDS Multi-AZ) unless there is a specific reason to
  run MySQL on EC2 — automated failover, patching and backups are not worth
  rebuilding by hand.
- **Automate promotion** via Orchestrator or MHA rather than a human following a
  runbook at 3 a.m.
- **Replicate backups cross-region.** Today everything is in one region, so a
  regional failure loses both the platform and its backups.
- **Add monitoring and alerting.** Nothing pages anyone. Replication lag, backup
  age and target-group health should all alert, and none of them do.
- **Shorten the health check** if 28 seconds of degraded service is too long for
  the SLO — and accept the extra probe traffic that buys.

### Residual risks I am accepting in this build

- Application-layer authorisation is out of scope; the demo app has no auth.
- The app trusts MySQL's self-signed certificate — the connection is **encrypted
  but the server is not authenticated**. Acceptable inside a private subnet
  reachable only from the web security group; wrong in production, where you
  would distribute `ca.pem` and verify. See the comment in
  `roles/nginx_app/files/app.py`.
- Single region, single AWS account.
- WAF coverage and rate limiting are constrained by the Cloudflare Free plan, as
  detailed above.
- Database failover is manual and has not yet been drilled (row 3 above).

