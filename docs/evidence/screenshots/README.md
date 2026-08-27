# Screenshot evidence

Captures backing the claims in [`../../DR-test-results.md`](../../DR-test-results.md).
Numbered in the order the tests were run: read-only proofs first, destructive
last.

| File | Shows | Backs |
|---|---|---|
| `01-waf-ratelimit-alb-bypass.png` | SQLi returns `403`; `/login` flips to `429`; ALB direct times out with `exit=28` | Tests 2, 3, 4 |
| `02-ratelimit-cloudflare-1015.png` | `error code: 1015` — Cloudflare's rate limiter, so the request never reached the origin | Test 3 |
| `03-cloudflare-security-rules.png` | Three custom rules, one rate-limiting rule, and the **Free** Managed Ruleset — with the "Upgrade to Pro" prompt visible | Tests 2, 3 |
| `04-cloudflare-security-events.png` | Live block events attributed to *Custom rules* and *Managed rules* | Test 2 |
| `05a-write-baseline-primary.png` | `/write` returns `written: true` against the primary — the control | Test 5 |
| `05b-replica-refuses-write.png` | Same app repointed at the replica: error **1290**, `server_id: 2`, `super_read_only: true` | Test 5 |
| `06-restore-verified.png` | Checksum `OK`, 5 rows restored, `All tables OK (1 checked)`, `RESTORE VERIFIED — recovery time 1s` | Test 6 |
| `07-finding05-restore-race-failure.png` | The same script failing with `ERROR 1045` before the readiness race was fixed | Finding 5 |
| `08-failover-drill-web1.png` | web-1 stopped: 69 probes, 7 failed, 89.86%, no two failures consecutive | Drill 1 |
| `09-failover-drill-web2.png` | web-2 stopped: 68 probes, 7 failed, 89.71% — within 1s of drill 1 | Drill 2 |
| `10-target-health-recovering.png` | One target `initial`, one `healthy` — the ALB mid-recovery | Drill 1 |
| `11-target-health-both-healthy.png` | Both targets `healthy` before the second drill began | Drill 2 |
| `12-target-group-console.png` | Target group: 2 targets, 2 healthy, 0 unhealthy, port 8080 | Architecture |
| `13-ec2-instances-two-azs.png` | Five instances across `us-east-1a` and `us-east-1b`; **only the bastion has a public IP** | Architecture |
| `14-s3-versioning-enabled.png` | Backup bucket with versioning enabled | Backups |
| `15-s3-kms-encryption.png` | SSE-KMS with a customer-managed key, bucket key enabled | Backups |

## Why the failure screenshot is included

`07` shows the restore harness failing. It is here deliberately. The results
document records seven defects found by running the code rather than reading it,
and a screenshot set containing only green output would contradict that.
`06` and `07` are the same command before and after the fix.

## Notes

`13` is the one worth pausing on: the `Public IPv4` column is empty for all four
web and database nodes. Only the `t3.micro` bastion has an address. That is the
whole private-subnet argument in a single column.
