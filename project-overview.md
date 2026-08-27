# Project overview — what this is and why each piece exists

A companion to [`next-steps.md`](next-steps.md), which is the *how*. This is the
*why*, written to revise from.

---

## What the project actually is

A web platform that survives losing a server, keeps its database consistent, can
be restored from backup, and sits behind a firewall that has been tested — with
**the recovery numbers written down**.

The thing worth understanding: **the infrastructure is not the deliverable.**
Anyone can draw a diagram with two web servers and a load balancer. What almost
nobody does is stop the server and measure how long the site was down. That
measurement is the deliverable, and it lives in
[`docs/DR-test-results.md`](docs/DR-test-results.md).

That is why the project's tests matter more than its Terraform.

---

## The request path

What happens when someone visits `https://lab.syedamjad.com`:

```
  Browser
    │
    │  TLS #1
    ▼
  Cloudflare edge ──────────── WAF rules, rate limiting, geo challenge,
    │                          DDoS absorption, HSTS
    │  TLS #2 (ACM certificate)
    ▼
  ALB  (public subnets, both AZs) ─── security group: ONLY Cloudflare's IP ranges
    │                                  health checks every 15s
    │  HTTP
    ├──────────────┐
    ▼              ▼
  web-1          web-2          (private subnets, no public IP, one per AZ)
  10.20.10.251   10.20.11.250
    │              │
    │  nginx :8080 — rate limits, reads real client IP from CF-Connecting-IP
    │  app.py :3000 — bound to 127.0.0.1, unreachable from the network
    │              │
    └──────┬───────┘
           │  TLS
           ▼
  MySQL primary  10.20.10.144  ── writes
           │
           │  GTID replication
           ▼
  MySQL replica  10.20.11.69   ── super_read_only, refuses writes
           │
           ▼
  S3 backups (encrypted with KMS, versioned, lifecycle-managed)
```

Every arrow is a place something can be locked down, and every box is a place
something can fail. The tests in `next-steps.md` each probe one of them.

---

## The admin path, and what a bastion is

This is the part worth understanding properly, because it is the single most
common thing to get wrong in a cloud build.

### The problem

The web and database servers have **no public IP address at all**. Look at
[`terraform/compute.tf`](terraform/compute.tf):

```hcl
resource "aws_instance" "web" {
  subnet_id                   = aws_subnet.private[count.index].id
  associate_public_ip_address = false
}
```

There is no route from the internet to `10.20.10.251`. You could know its
address, its SSH port, and its username, and still have no path to it. A server
that is not addressable has, from the internet's point of view, an attack surface
of zero.

That is exactly what you want — and it creates an obvious problem: **you still
have to administer these machines.**

### The bad answers

- *Give them public IPs and lock down the security group.* Now every server is
  internet-facing, every server needs SSH hardened, and a single security group
  mistake exposes the database.
- *Put a VPN in.* Correct, but heavy for a lab.

### The bastion answer

Put **one** small, hardened, disposable host in a public subnet whose only job is
to be a door. Nothing runs on it. It stores nothing. If it were destroyed you
would `terraform apply` and get a new one in ninety seconds.

The access rules form a chain, each link narrow:

| Hop | Who is allowed | Where it's defined |
|---|---|---|
| You → bastion | SSH **only** from `admin_cidr` — your home IP as a `/32` | `aws_security_group.bastion` |
| Bastion → web/db | SSH **only** from the bastion's security group | `aws_security_group.web` / `.db` |
| ALB → web | HTTP **only** from the ALB's security group | `aws_security_group.web` |
| web → db | MySQL **only** from the web security group | `aws_security_group.db` |

Note what those rules reference: **security groups, not IP addresses**. "Allow
SSH from whatever is in the bastion security group" keeps working when the
bastion is replaced and its IP changes. That is the AWS-native way to express
"these two tiers may talk", and it is why the rules survive every stop/start.

`admin_cidr` is deliberately validated in
[`terraform/variables.tf`](terraform/variables.tf):

```hcl
validation {
  condition     = var.admin_cidr != "0.0.0.0/0"
  error_message = "admin_cidr must not be 0.0.0.0/0 — that defeats the entire bastion design."
}
```

Because the tempting shortcut, at 11pm when your ISP has changed your address, is
to open it to the world — and then the bastion is just a server with SSH exposed
to the internet, which is the thing you built it to avoid.

### Why SSH "just worked" through it

```bash
ssh -J ubuntu@$BASTION ubuntu@10.20.11.250
```

`-J` is **ProxyJump**. OpenSSH connects to the bastion, asks it to open a plain
TCP tunnel to `10.20.11.250:22`, and then runs a *complete, separate* SSH
handshake with the web node through that tunnel.

The important consequence, and the reason this pattern is safe:

> **Your private key never touches the bastion.** The bastion carries encrypted
> bytes it cannot read. Authentication to the final host happens end to end,
> between your laptop and that host.

That is why `ssh-add ~/.ssh/ha-lab.pem` is a prerequisite. The second hop
authenticates against the key held in `ssh-agent` **on your machine** — the agent
answers a cryptographic challenge; the key itself is never transmitted.

Compare the old, bad habit: `scp` your `.pem` onto the bastion and SSH from
there. Now the key to every server in your estate is sitting on the one host that
is exposed to the internet. Compromise the bastion, own everything. The
ProxyJump version has no such property.

Ansible does exactly the same thing. [`scripts/gen-inventory.sh`](scripts/gen-inventory.sh)
writes this into the inventory:

```ini
[web:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -J ubuntu@<BASTION>'
```

So `ansible-playbook site.yml` reaches four machines that have no internet
presence, using one door, with the key never leaving your laptop.

### Why yesterday's failure looked the way it did

```
Connection closed by UNKNOWN port 65535
```

That message means the *tunnel* was established — you reached the bastion fine —
but the far end never completed an SSH handshake. It told us instantly that the
bastion and its security groups were healthy and the problem was on
`10.20.10.144` itself. A timeout would have meant something different: packets
disappearing, i.e. a security group or routing fault. Reading which failure you
got is how you skip straight to the real cause.

### What you would use in production instead

**AWS Systems Manager Session Manager.** No SSH port open anywhere, no bastion
host to patch, no keys to distribute, and every session recorded in CloudTrail.
The bastion pattern is correct and worth knowing — Session Manager is what
replaced it.

---

## Layer by layer: why each piece is there

### Two Availability Zones

An AZ is a physically separate datacenter with independent power and cooling.
`us-east-1a` losing power must not take the site with it. So there are two of
everything that matters: two subnets, two web nodes, two NAT gateways, a database
primary in one AZ and its replica in the other.

`variables.tf` enforces exactly two, because the whole design assumes it.

### Public and private subnets

- **Public** — has a route to the internet gateway. Holds *only* the ALB and the
  bastion.
- **Private** — no route in from the internet. Holds the web and database tiers.
  They reach *out* through a NAT gateway (for `apt` updates), but nothing reaches
  *in*.

This split is the foundation everything else rests on.

### The Application Load Balancer

One address for the site, health-checking both web nodes every 15 seconds. When a
node stops answering twice in a row, the ALB stops sending it traffic. **Test 7
measures how long that takes** — roughly 30 seconds, which is why you should
expect failed requests during a drill rather than a perfect score.

### Cloudflare in front

WAF rules, login rate limiting, geo challenge, DDoS absorption, TLS. But all of
that is worthless if an attacker can skip it — so the ALB's security group admits
**only Cloudflare's published IP ranges**. `scripts/update-cloudflare-ranges.sh`
keeps that list current.

**Test 4 is the one people skip**, and it's the one that decides whether the WAF
is real or decorative. A timeout there means there is genuinely no path to your
origin except through Cloudflare.

### MySQL primary and replica, with GTID

The primary accepts writes. The replica continuously replays them. **GTID**
(Global Transaction Identifier) means every transaction carries a globally unique
ID, so the replica can say "send me everything I haven't seen" rather than
"send me from binlog file 4, offset 1857". No filenames, no offsets to write down
and get wrong at 3am during a failover.

The replica runs `super_read_only`, so it cannot be written to even by an admin
account. **Test 5 proves it** — that error 1290 you just captured. Without it, an
application misconfiguration writes to the replica, the two databases silently
diverge, and you discover it weeks later.

### Encrypted backups with a verified restore

Nightly `mysqldump`, gzipped, SHA-256 checksummed, uploaded to a versioned S3
bucket encrypted with a customer-managed KMS key.

**Test 6 is the differentiator.** Almost every portfolio project stops at "the
backup script ran successfully." This one downloads the backup, verifies the
checksum, restores it into a throwaway Docker container, counts the rows and runs
`mysqlcheck` over every table. A backup you have never restored is a hypothesis.

### Host hardening

`firewalld` default-deny, `fail2ban` jails, sshd configuration, kernel sysctls,
and IMDSv2 required on every instance (`http_tokens = "required"`) — that last one
closes the SSRF-to-credential-theft path behind the Capital One breach, in one
line.

---

## Vocabulary

| Term | What it means here |
|---|---|
| **AZ** | Availability Zone — a physically separate datacenter within a region |
| **Bastion / jump host** | The single hardened door into machines with no public IP |
| **ProxyJump (`-J`)** | SSH tunnelling through the bastion, key never leaving your laptop |
| **Security group** | A stateful firewall on an ENI; can reference *other security groups* |
| **NAT gateway** | Lets private instances reach out to the internet; nothing reaches in |
| **ALB** | Layer-7 load balancer; health checks and distributes to targets |
| **GTID** | Globally unique transaction ID — lets a replica resume by identity, not offset |
| **`super_read_only`** | Blocks writes on a replica even from privileged accounts |
| **RTO** | Recovery Time Objective — how long you were down |
| **RPO** | Recovery Point Objective — how much data you lost |
| **WAF** | Web Application Firewall — inspects requests before they reach your origin |
| **IMDSv2** | Session-based instance metadata; blocks the classic SSRF credential theft |

---

## The honest limitations

Worth knowing, because being asked about them and having an answer is the point:

- **Single region, single account.** A regional failure loses the platform *and*
  the backups.
- **Cloudflare Free plan.** No OWASP Core Ruleset, no 60-second rate-limit window.
  Both were substituted and documented rather than glossed over.
- **The app trusts MySQL's self-signed certificate** — the connection is
  encrypted but the server is not authenticated. Fine inside a private subnet;
  wrong in production.
- **Failover is manual.** A human follows `docs/RUNBOOK-failover.md`. Production
  would use automated promotion.
- **Nothing pages anyone.** Replication lag, backup age and target-group health
  should all alert, and don't.
- **A managed database would be the right answer** for most real deployments.
  RDS Multi-AZ gives automated failover, patching and backups. Running MySQL on
  EC2 here is a deliberate choice to learn the mechanics.

Every one of these belongs in `DR-test-results.md`. A project that names its own
weaknesses reads as engineering judgment; one that claims none reads as someone
who hasn't looked.
