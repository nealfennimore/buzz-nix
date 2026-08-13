# Deploying the buzz relay on AWS (NixOS)

A practical, operator-neutral guide to running the buzz relay on a single AWS
EC2 NixOS instance.

This document is the **AWS infrastructure layer**: instance sizing, security
groups, the object store decision, backups, and the deploy sequence. It
complements:

- [`README.md`](../README.md) — the module, its options, and the local
  Postgres/Redis/MinIO/TLS wiring.
- [`DEPLOY-RUNBOOK.md`](../DEPLOY-RUNBOOK.md) — the step-by-step operational
  runbook for the TLS-on-a-domain path built around
  `nixosConfigurations.publicExample`.
- [`examples/aws-public-ip.nix`](../examples/aws-public-ip.nix) — a concrete,
  copy-and-edit host for the no-domain (public-IP) start described below.

Everything here maps to real `services.buzz.relay.*` options; see the README's
option table for the full list.

## The shape of the deployment

One EC2 box runs the relay plus its backing services under systemd:

| Component | Port | Exposure |
| --- | --- | --- |
| Relay app (WS + REST + web UI) | `3000` | public **only** on the no-domain path; loopback behind the proxy on the TLS path |
| Health (`/_liveness`, `/_readiness`) | `8080` | loopback — never expose |
| Prometheus metrics (`/metrics`) | `9102` | loopback — never expose |
| PostgreSQL | `5432` | loopback |
| Redis | `6379` | loopback |
| TLS proxy (Caddy) | `80` + `443` | public — **only** when `tls.enable = true` |

The relay binds its backing datastores to `127.0.0.1`; they are never network
services. The only things that should ever face the internet are **either** the
TLS proxy on 80/443 (domain path) **or** the app port 3000 (no-domain path) —
never both, and never the health/metrics/datastore ports.

The box is **disposable and resizable**: all durable state lives in PostgreSQL
(events) and the object store (media + git objects). Treat the instance as
cattle — see [Backups and disposability](#backups-and-disposability).

## Instance sizing

Start small. The relay itself is light; the footprint comes from running
Postgres + Redis + Caddy alongside it on one box.

| Workload | Suggested instance | Notes |
| --- | --- | --- |
| **Minimal** (relay + Postgres + Redis + Caddy, **no agents on the box**) | **`t3.medium`** (2 vCPU / 4 GB) | A comfortable floor for a team relay. Resize up anytime. |
| Scale / agents on the box | `t3.large`+ (or a memory-optimised type) | Only if you run agent processes on the same instance or need headroom for Postgres under real traffic. |

Agents are clients: they connect to the relay like any member and normally run
elsewhere (laptops, a separate box). If you keep them off the relay host, the
minimal size is plenty.

Because the instance is disposable, **right-size by starting at `t3.medium` and
bumping the instance type later** if Postgres needs more room. A
stop/change-type/start cycle preserves the root EBS volume.

**Root EBS:** gp3, encrypted. Budget ~100 GB to comfortably hold the Nix store,
Postgres data, and the on-disk git working state. (Media and
git *objects* live in the object store, not on the box.)

**Architecture:** build the NixOS image for the instance you launch — x86_64 for
Intel/AMD, aarch64 for Graviton. A mismatch is a *silent* boot failure (the
instance never comes up, no clear error), so confirm it up front.

## Networking

### Elastic IP (allocate first)

Allocate an Elastic IP and associate it with the instance. A stable address is a
prerequisite for both paths:

- **Domain path:** the DNS `A`/`AAAA` record must point at a stable address
  before first boot so ACME can issue the certificate.
- **No-domain path:** `relayUrl` embeds the address, and NIP-42 AUTH is bound to
  it. If the address changes, every client's auth target changes with it.

Allocate the EIP **before** you create the box so the address exists when you
fill in DNS / `relayUrl`.

### Security group

Pick the rule set to match your path. Backing services stay internal in both
cases — they are bound to loopback, so no security-group rule should ever open
`8080`, `9102`, `5432`, `6379`, or `8108`.

**TLS path (you have a domain):**

| Port | Source | Why |
| --- | --- | --- |
| `443` | `0.0.0.0/0` | TLS — clients connect here over `wss://` |
| `80` | `0.0.0.0/0` | ACME HTTP-01 challenge + HTTP→HTTPS redirect |
| `22` | your admin CIDR | SSH — restrict to known addresses |

With `tls.enable = true` the module sets `openFirewall = false` and Caddy on
80/443 is the only public surface. The relay's `:3000` stays on loopback.

**No-domain path (public IP, no TLS yet):**

| Port | Source | Why |
| --- | --- | --- |
| `3000` | `0.0.0.0/0` (or a client CIDR) | The relay app — clients connect over `ws://<EIP>:3000` |
| `22` | your admin CIDR | SSH — restrict to known addresses |

Here `openFirewall = true` opens `3000` and the relay is the public surface
directly. If you can scope `3000` to a known client CIDR, do — it narrows the
exposure without committing to TLS.

Egress: allow all (the box reaches the object store, ACME, and package
substituters outbound).

## Object store: use managed AWS S3

The relay needs an S3-compatible object store for media uploads and the git
object-store (content-addressed) path. **For an AWS deployment, use managed AWS
S3.** Set `provisionMinio = false` and point the relay at S3 via the
`environmentFile`.

### Why managed S3 over the bundled MinIO

The module can provision a local MinIO (`provisionMinio = true`), and that is a
fine choice for local development or a throwaway staging box. For a real AWS
deploy, prefer managed S3:

- **The bundled MinIO is unmaintained.** nixpkgs marks `minio` insecure: the
  AGPL MinIO server is upstream-archived as of 2026 and will not receive further
  patches. Two 2026 advisories illustrate the risk surface — CVE-2025-62506
  (service-account privilege bypass) and CVE-2026-33322 (OIDC JWT confusion).
  Both are *inert* in the buzz configuration (it uses neither MinIO
  service-accounts nor OIDC, and binds MinIO to `127.0.0.1` behind the
  membership gate), so the immediate risk in a single-tenant, members-only relay
  is small — but shipping a permanently-unpatched server as durable
  infrastructure is not a good long-term footing.
- **AWS S3 is a verified drop-in for how buzz uses object storage.** The relay
  uses **path-style** addressing and **conditional writes** —
  `If-None-Match: *` and `If-Match`, expecting a `412 Precondition Failed` on
  conflict and a returned `ETag`. AWS S3 supports all of these, so it satisfies
  the git content-addressed path, not just media. No presigned URLs, multipart,
  or OIDC are required.
- **Garage / SeaweedFS are not yet proven for the git path.** They work for
  media-only object storage, but their conditional-write / `412` behavior on the
  content-addressed path is unverified here. Don't put the git object-store path
  on them without validating that behavior first.

### Wiring managed S3

With `provisionMinio = false`, the module does **not** set `BUZZ_S3_ENDPOINT` or
`BUZZ_S3_BUCKET` for you (those are only injected on the MinIO path). You supply
the full S3 configuration yourself via the secret `environmentFile`:

```
BUZZ_S3_ENDPOINT=https://s3.<region>.amazonaws.com
BUZZ_S3_BUCKET=<your-bucket>
BUZZ_S3_ACCESS_KEY=<iam-access-key-id>
BUZZ_S3_SECRET_KEY=<iam-secret-access-key>
```

(The `s3Bucket` module option is only used to name the bucket the *MinIO*
bootstrap creates; on the managed-S3 path the bucket name comes from
`BUZZ_S3_BUCKET` in the env file. You can leave `s3Bucket` at its default.)

Create a **dedicated IAM user scoped to just this bucket** and use its keys.
A least-privilege policy grants object read/write/delete on the bucket plus the
bucket-level operations the relay needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::<your-bucket>"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<your-bucket>/*"
    }
  ]
}
```

(An EC2 instance profile with the same policy is an alternative to a static key
pair; the relay reads `BUZZ_S3_ACCESS_KEY`/`BUZZ_S3_SECRET_KEY` from the env
file, so the static-key route is the straightforward one to start.)

### Validate conditional-write behavior before enabling the probe

The relay can gate startup on an object-store conformance probe
(`conformanceProbe = true`), which asserts the conditional-write contract. Under
concurrency, S3 implementations sometimes return `409 Conflict` where the relay
expects `412 Precondition Failed`. **Validate your bucket's conditional-write
behavior (`If-None-Match: *` → `412` vs `409`) before turning
`conformanceProbe = true` on**, so a strict probe doesn't refuse to start
against an otherwise-working bucket. Once you've confirmed the behavior, enabling
the probe makes a misconfigured object store fail fast at boot rather than
failing silently on the first upload.

## TLS and the relay URL

`relayUrl` is advertised in NIP-11 and is the host NIP-42 AUTH binds to. It must
match what clients actually connect to.

**With a domain (recommended for anything public):** turn on the built-in TLS
proxy. Caddy obtains and renews a Let's Encrypt certificate on 80/443 and
forwards to the relay, upgrading WebSocket connections transparently:

```nix
services.buzz.relay = {
  relayUrl     = "wss://relay.example.com";  # must be wss:// on tls.domain
  bindAddr     = "127.0.0.1:3000";           # only the proxy reaches the relay
  openFirewall = false;                      # tls.enable opens 80/443 instead
  tls = {
    enable    = true;
    domain    = "relay.example.com";          # DNS must resolve here (ACME HTTP-01 on :80)
    acmeEmail = "admin@example.com";          # a real address; ACME fails otherwise
  };
};
```

The module asserts that `relayUrl` is `wss://` on `tls.domain` — a mismatch
breaks AUTH, so it's caught at evaluation.

**Without a domain (public-IP start):** run plain `ws://` on the app port:

```nix
services.buzz.relay = {
  relayUrl     = "ws://<ELASTIC-IP>:3000";   # NIP-42 binds to this address
  bindAddr     = "0.0.0.0:3000";
  openFirewall = true;                       # opens :3000
  tls.enable   = false;
};
```

The **desktop app and CLI work fine over `ws://<IP>:3000`**. The **web UI needs
a domain / secure context** — browsers require `wss://` (a secure context) for
the client-side key crypto, so the web UI is effectively domain-gated. Plan to
add a domain when you want the web UI; until then the desktop app and CLI cover
it.

See [Going from public-IP to a domain](#going-from-public-ip-to-a-domain) for the
flip.

## Lockdown

For a real relay, gate writes to members. These three options together mean
anyone can *connect*, but only members can *publish/upload*:

```nix
services.buzz.relay = {
  requireAuthToken       = true;   # REST surface needs a token
  requireRelayMembership = true;   # every authed request checked against relay_members
  ownerPubkey            = "<your-64-char-hex-pubkey>";  # bootstrapped as owner on first start
};
```

`requireRelayMembership = true` requires both `ownerPubkey` and a stable signing
key (`BUZZ_RELAY_PRIVATE_KEY` via `environmentFile`, or `privateKeyFile`) — the
module asserts this, and the relay refuses to start otherwise, because an
ephemeral key would make membership events unverifiable after a restart.

## Backups and disposability

Durable state is exactly two things:

1. **PostgreSQL** — events, membership, all relational state.
2. **The object store (S3)** — media uploads and git objects.

Redis is a cache, and the search index lives inside PostgreSQL itself, so
Redis needs no backup. Get Postgres and S3 covered and the instance is truly
disposable.

### Minimal: daily `pg_dump` to the same S3 bucket

The simplest durable Postgres backup is a daily `pg_dump` piped straight to the
S3 bucket you already have, via a systemd timer:

```nix
systemd.services.buzz-pg-backup = {
  serviceConfig = {
    Type = "oneshot";
    User = "postgres";
    EnvironmentFile = "/run/secrets/buzz-relay.env";  # provides BUZZ_S3_BUCKET + AWS creds
  };
  path = [ pkgs.postgresql pkgs.awscli2 pkgs.gzip ];
  script = ''
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    pg_dump buzz | gzip | aws s3 cp - "s3://$BUZZ_S3_BUCKET/pg-backups/buzz-$ts.sql.gz"
  '';
};
systemd.timers.buzz-pg-backup = {
  wantedBy = [ "timers.target" ];
  timerConfig = { OnCalendar = "daily"; Persistent = true; };
};
```

Restore on a fresh box:

```
aws s3 cp s3://<bucket>/pg-backups/buzz-<ts>.sql.gz - | gunzip | psql buzz
```

**Test a restore once before you rely on it.** A backup you have never restored
is a hope, not a backup.

### Turn on S3 bucket versioning

Enable **versioning** on the bucket. It guards every object — media, git
objects, and the Postgres dumps — against accidental delete or overwrite, and is
the cheapest safety net you can add.

### Keep data in a separate lifecycle from the box

This is the rule that makes "disposable box" safe: **put the S3 bucket (and a
managed database, if you adopt one) in a separate Terraform/OpenTofu state — or
mark them `lifecycle { prevent_destroy = true; }` — from the EC2 instance.** Then
resizing, rebuilding, or destroying the box can never take the data with it. The
compute is cattle; the data store is not.

### Upgrade path (when you outgrow the minimal setup)

- **Point-in-time recovery / WAL archiving:** add `wal-g` (or similar)
  continuous WAL archiving to S3 for PITR instead of daily snapshots.
- **Managed database:** move Postgres to RDS — set `provisionPostgresql = false`
  and point `databaseUrl` at the managed endpoint. The migration step reads the
  same `databaseUrl`. You get backups, PITR, and failover from the
  managed service. Do the same for Redis with ElastiCache via `provisionRedis =
  false` + `redisUrl` if you want it off-box too.

## Deploy checklist

Ordered. Items in *(TLS only)* apply only when you're deploying with a domain.

1. **Allocate the Elastic IP.** Associate it with the instance once it exists.
2. **DNS or IP:**
   - *(TLS only)* Create the `A`/`AAAA` record for `relay.<domain>` → EIP and let
     it propagate.
   - *(no-domain)* Note the EIP; it goes straight into `relayUrl`.
3. **Provision the object store:** create the S3 bucket, turn on **versioning**,
   create an S3-scoped IAM user, and capture its keys. Validate the bucket's
   conditional-write (`412` vs `409`) behavior.
4. **Place the secrets** on the box at `/run/secrets/` (manual `scp` for first
   light; move to sops-nix / agenix / cloud-init afterward). `chmod 0400` and
   `chown` each to the `buzz` service user. At minimum:
   `BUZZ_RELAY_PRIVATE_KEY` and the `BUZZ_S3_*` set.
5. **Fill the host config placeholders:** `relayUrl` (and `tls.domain` +
   `acmeEmail` if TLS), `ownerPubkey`, and the disk/filesystem stanza for the
   real instance.
6. *(TLS only)* **First cert via Let's Encrypt staging.** Point Caddy's CA at the
   staging endpoint for the first deploy so a DNS/config typo doesn't burn the
   production issuance rate limit, confirm the stack comes up, then flip to prod
   and redeploy for the real certificate.
7. **Provision the instance.** Build the NixOS image for the right architecture
   (`nixos-generators -f amazon`, or the `amazonImage` profile), import/register
   it as an AMI, and launch — or launch a stock NixOS AMI and rebuild in place
   (next step).
8. **Deploy the system configuration.** Either a remote-activation tool such as
   `deploy-rs`, or build-and-switch in place with
   `nixos-rebuild switch --flake .#<host> --target-host root@<EIP>`. (`sops-nix`,
   `agenix`, or cloud-init are all fine for getting the secret files onto the box
   — pick whichever your workflow already uses.)
9. **Verify** before cutover:
   ```
   curl -fsS http://<host-or-loopback>:8080/_readiness   # ready  (health port; loopback)
   # or, on the TLS path:
   curl -fsS https://relay.<domain>/_readiness           # ready
   ```
   Then connect a client (desktop app or CLI) to the relay URL and authenticate.
10. **Add members.** As the owner, add the first members' pubkeys so they can
    write.
11. **Snapshot the EBS volume** once it's healthy, and before any risky change.

## Going from public-IP to a domain

When you're ready for TLS and the web UI, the change is small. In the host
config:

- `tls.enable = true;` and set `tls.domain` (+ `tls.acmeEmail`).
- `relayUrl = "wss://relay.<domain>";` (must match `tls.domain`).
- `bindAddr = "127.0.0.1:3000";` (the proxy fronts the relay now).
- `openFirewall = false;` (Caddy's 80/443 become the public surface).

Then create the DNS record, update the security group to open 80/443 and close
3000, and redeploy. Existing members reconnect to the `wss://` URL. (The
[`DEPLOY-RUNBOOK.md`](../DEPLOY-RUNBOOK.md) covers the domain/ACME path in full.)
