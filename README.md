# buzz-nix

A standalone, portable Nix flake that builds the **buzz relay** (`buzz-relay`, the
crate formerly known as *sprout*) from source and ships a NixOS module to run it.

The relay is the WebSocket server of the [Buzz](https://github.com/block/buzz)
communications platform: a Nostr-flavoured relay that also serves a smart-HTTP
git endpoint and a REST/web surface.

This flake pins:

- buzz source: `github:block/buzz` @ `relay-v0.2.1` (`6e5c462a`)
- Rust toolchain: **1.95.0** (the repo's `rust-toolchain.toml`), supplied by
  [`oxalica/rust-overlay`](https://github.com/oxalica/rust-overlay) because
  nixpkgs' default rustc is too old.

## What's in the box

| Output | What it is |
| --- | --- |
| `packages.<system>.buzz-relay` (and `.default`) | The `buzz-relay` binary, built from source. |
| `nixosModules.default` | `services.buzz.relay` — systemd service + optional local Postgres/Redis/MinIO + turnkey TLS (Caddy) + schema bootstrap. |
| `nixosConfigurations.example` | A minimal, bootable example host with the relay enabled. |
| `nixosConfigurations.publicExample` | The full public-stack reference: all three backing services + TLS + lockdown. The AWS deploy starting point. |
| `checks.x86_64-linux.relay-boot` | A `nixosTest` that boots the relay (Postgres + Redis) and proves a NIP-01 round-trip. |
| `checks.x86_64-linux.full-stack` | A `nixosTest` that boots the **whole stack** (Postgres + Redis + MinIO + lockdown) and proves NIP-01, a MinIO media upload+retrieve, non-member rejection, and full-text search. |
| `devShells.default` | Rust 1.95 + build deps for hacking on the source. |

## Scope (v1)

This packages the **relay + PostgreSQL + Redis** path — enough to stand up a
working relay. Full-text search needs no extra service: since `relay-v0.2.1` the
relay searches a generated `tsvector` column in PostgreSQL, which the schema
bootstrap creates. It deliberately leaves out:

- **S3 / MinIO** (media + git object storage) is **optional and off by default**
  (`provisionMinio = false`). The git object-store conformance probe is also
  disabled by default (`conformanceProbe = false`) so the relay starts without an
  object store. Media uploads and git-on-object-storage features will not function
  until you wire one up. Flip `provisionMinio = true` to provision a local MinIO
  and wire it in automatically (see *Going further: media*).

## Quick start

Add the flake as an input and enable the module:

```nix
{
  inputs.buzz-nix.url = "github:nealfennimore/buzz-nix";

  outputs = { self, nixpkgs, buzz-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        buzz-nix.nixosModules.default
        ({ ... }: {
          services.buzz.relay = {
            enable = true;
            relayUrl = "wss://relay.example.com";   # what clients connect to
            openFirewall = false;                    # terminate TLS at a proxy instead
          };
        })
        # ... your host config ...
      ];
    };
  };
}
```

The default package resolves automatically to the `buzz-relay` this flake builds
for your host's system — no extra wiring needed.

With the defaults, the module also provisions a local PostgreSQL (database `buzz`,
peer auth over the Unix socket) and a local Redis on `127.0.0.1:6379`, and applies
the schema before the relay starts.

## Building / testing locally

```bash
nix build .#buzz-relay                       # build the binary
nix flake check                              # eval the module + example hosts + run VM tests
nix build .#checks.x86_64-linux.relay-boot   # VM test: boot + NIP-01 round-trip (needs KVM)
nix build .#checks.x86_64-linux.full-stack   # VM test: full stack + media + search + lockdown (needs KVM; heavier)
```

## Schema migrations (important)

The relay does **not** self-migrate (`BUZZ_AUTO_MIGRATE` is vestigial). The
module runs upstream's own migration runner, `buzz-admin migrate`, in the
service's `ExecStartPre` on every start (toggle with `applySchema`).

`buzz-admin` is built from the same source as the relay. `buzz-db` embeds the
ordered `migrations/*.sql` files into the binary at compile time with
`sqlx::migrate!("../../migrations")`, so the step reads no files at runtime and
needs no network. It records what it applied in `_sqlx_migrations` and runs only
the pending versions:

- A fresh database gets the full schema.
- An up-to-date database is a no-op.
- An upgraded relay applies only its new migrations.

Nothing is ever dropped, so running it on every start is safe.

Use `services.buzz.relay.applySchema = false` only if you run `buzz-admin
migrate` yourself before the relay starts.

### Do not converge against `schema/schema.sql`

`schema/schema.sql` looks like the source of truth and is not. Two earlier
versions of this module treated it as one, and both were wrong:

1. **`pgschema apply --auto-approve` on every start — destroyed data.** `events`
   and `delivery_log` are range-partitioned, and the relay creates monthly
   partitions (for example `events_2026_08`) at runtime via
   `ensure_future_partitions`. pgschema (≤ 1.7.4) does not round-trip
   `CREATE TABLE ... PARTITION OF`, so the declared partitions came up detached,
   and it then read the relay's runtime partitions as drift and emitted
   `DROP TABLE ... CASCADE` — **deleting every stored event on every restart**.
2. **Bootstrapping `schema.sql` once with `psql` — incomplete schema.**
   Non-destructive, but `schema.sql` is a snapshot that has drifted from
   `migrations/`. It is missing `git_repo_names` (`migrations/0002`), the
   registry every git smart-HTTP read and write resolves through. A relay booted
   that way passes readiness and serves NIP-01, then fails on the first git
   operation.

The `relay-boot` VM test asserts against both failure modes: the declared
partitions must be attached, `_sqlx_migrations` must be complete with no
failures, `git_repo_names` must exist with the right primary key, and a
published event must survive a service restart.

## TLS reverse proxy

The relay speaks plain HTTP/WS on `:3000`. Terminate TLS at a reverse proxy and
forward with WebSocket upgrade. `relayUrl` should be the public `wss://` URL.

### Turnkey TLS (built-in Caddy)

The module can stand the proxy up for you. Flip on `tls.enable`, give it the
domain, and you get a Caddy vhost on `:80`/`:443` that obtains and renews a
Let's Encrypt certificate automatically and reverse-proxies to the relay (Caddy
forwards WebSocket upgrades transparently):

```nix
services.buzz.relay = {
  enable = true;
  relayUrl = "wss://relay.example.com";   # must be wss:// on the tls.domain host
  bindAddr = "127.0.0.1:3000";            # only the proxy needs to reach the relay
  openFirewall = false;                   # 80/443 are opened by tls.enable instead

  tls = {
    enable = true;
    domain = "relay.example.com";          # DNS must resolve here (ACME HTTP-01 on :80)
    acmeEmail = "admin@example.com";       # optional: Let's Encrypt contact
    # proxy = "caddy";                      # the default and only built-in proxy
  };
};
```

`tls.enable` opens firewall ports `80` and `443`, and the module asserts that
`relayUrl` is `wss://` on `tls.domain` (NIP-42 binds AUTH to that host, so a
mismatch breaks auth). Cert + ACME-account state persists in Caddy's default
`/var/lib/caddy`. Keep `:8080`/`:9102` internal.

Prefer nginx, a different ACME setup, or an external load balancer (e.g. an AWS
ALB terminating TLS)? Leave `tls.enable` off and wire the proxy yourself with
the manual blocks below, pointing it at the relay's `port`.

### Caddy (manual)

```caddy
relay.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

Caddy proxies WebSocket upgrades transparently and provisions a certificate
automatically.

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name relay.example.com;
    # ssl_certificate / ssl_certificate_key ...

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
    }
}
```

Health checks live on `:8080` (`/_liveness`, `/_readiness`) and Prometheus
metrics on `:9102` (`/metrics`) — keep those internal.

## Locking the relay down

For first light the relay runs "open": no REST token required and, if no signing
key is provided, it uses a hardcoded dev keypair. To run it for real:

```nix
services.buzz.relay = {
  enable = true;
  relayUrl = "wss://relay.example.com";

  requireAuthToken = true;                 # REST requests need a token
  requireRelayMembership = true;           # every authed request checked against relay_members
  ownerPubkey = "<64-char-hex pubkey>";    # bootstrapped as owner on first start
  privateKeyFile = "/run/secrets/buzz-relay-key.env";  # stable signing identity
};
```

`privateKeyFile` (or `environmentFile`) is a systemd `EnvironmentFile` so secrets
never enter the Nix store. It must contain at least:

```
BUZZ_RELAY_PRIVATE_KEY=<64-char-hex secret key>
```

`requireRelayMembership = true` requires both `ownerPubkey` and a stable
`privateKeyFile`/`environmentFile`, enforced by module assertions and by the
relay at startup (an ephemeral key would make NIP-43 events unverifiable after a
restart).

## Full public stack (AWS reference)

`nixosConfigurations.publicExample` is the complete, public-facing reference: a
single host that provisions **all three backing services** (Postgres + Redis +
MinIO), terminates TLS with the built-in **Caddy** proxy on a domain
with an automatic Let's Encrypt cert, and **locks the relay down** to relay
members (NIP-43). It is the recommended starting point for an AWS deploy — copy
it and adjust.

The whole data plane in that config (relay + Postgres + Redis +
MinIO + lockdown, including a media upload to MinIO and a full-text search) is
exercised in one isolated VM by `checks.x86_64-linux.full-stack`, so the path
that fails silently on a misconfigured host is proven before you ship.

To stand it up:

1. **Edit the config** — set `ownerPubkey` to your 64-char hex pubkey, change
   `relay.example.com` / `acmeEmail` to your domain and contact, and replace the
   disk/filesystem stanza with the real instance (for AWS, build the image with
   `nixos-generators -f amazon` or the `amazonImage` profile rather than the
   placeholder grub/ext4 block).
2. **Point DNS** — an A/AAAA record for the domain at the instance. ACME's
   HTTP-01 challenge needs port `80` reachable from the internet, and clients
   reach `:443`; the security group must allow both. The relay's own ports
   (`3000` app, `8080` health, `9102` metrics, `9000`/`9001` MinIO) stay bound
   to `127.0.0.1` — do **not** expose them.
3. **Provide the secret files** (never in the Nix store — use sops-nix, agenix,
   or cloud-init to write them):
   - `/run/secrets/buzz-relay.env`:
     ```
     BUZZ_RELAY_PRIVATE_KEY=<64-char-hex secret key>
     BUZZ_S3_ACCESS_KEY=<minio user>
     BUZZ_S3_SECRET_KEY=<minio password>
     # optional: BUZZ_GIT_HOOK_HMAC_SECRET=<>= 32 chars>
     ```
   - `/run/secrets/buzz-minio.env`:
     ```
     MINIO_ROOT_USER=<minio user, == BUZZ_S3_ACCESS_KEY>
     MINIO_ROOT_PASSWORD=<>= 8 chars, == BUZZ_S3_SECRET_KEY>
     ```

> **MinIO security note.** nixpkgs has marked `minio` **insecure** — upstream
> abandoned the project and several 2026 CVEs (including unauthenticated object
> writes) will not be fixed (see `pkgs.minio.meta.knownVulnerabilities`).
> `publicExample` and the full-stack test allow it explicitly via
> `nixpkgs.config.permittedInsecurePackages`, because a single-tenant relay where
> only relay members can write blobs (it binds to `127.0.0.1` behind the
> membership gate) is a much smaller exposure than a public S3. **For a hardened
> deploy, prefer a managed / external S3** (set `provisionMinio = false` and put
> `BUZZ_S3_*` in `environmentFile`, e.g. pointing at AWS S3), or override
> `services.buzz.relay.minioPackage` with a maintained S3-compatible server
> (Garage, SeaweedFS). Keep MinIO bound to `127.0.0.1` regardless.

### Cloud deployment punchlist

If you build a config from scratch instead of `publicExample`, you provide:

- **Domain + `relayUrl`** — a hostname (`relay.example.com`) with DNS pointing at
  the host, and `relayUrl = "wss://<domain>"`.
- **TLS** — either the turnkey `tls.enable` (Caddy, above), Caddy/nginx wired by
  hand, or an external load balancer terminating TLS. Keep `:8080`/`:9102`
  internal.
- **Secrets** via `environmentFile` / `privateKeyFile`:
  - `BUZZ_RELAY_PRIVATE_KEY` (stable relay identity) — required to lock down.
  - `BUZZ_GIT_HOOK_HMAC_SECRET` (>= 32 chars) if you want a fixed git-hook secret
    rather than the per-boot random one.
  - S3/MinIO keys (`BUZZ_S3_*`) once you enable media/object storage.
- **Datastore choice** — keep the provisioned local Postgres/Redis, or set
  `provisionPostgresql = false` / `provisionRedis = false` and point
  `databaseUrl` / `redisUrl` at managed RDS / ElastiCache. The migration step
  reads the same `databaseUrl`, so there is nothing else to repoint.
- **Lockdown toggles** — `requireAuthToken`, `requireRelayMembership`,
  `ownerPubkey` as above.

## Going further: media

Search needs no configuration. Media and object storage stay bring-your-own.

- **Search:** `relay-v0.2.1` searches PostgreSQL directly. The `events` table
  carries a generated `search_tsv` column with a GIN index, both created by the
  schema bootstrap, and NIP-50 `search` filters run against it. Earlier releases
  used a separate Typesense service. That service is gone, and so are the
  `provisionTypesense`, `typesenseUrl`, `typesenseApiKeyFile`, and
  `typesensePackage` options. Delete them from your host config and delete the
  Typesense API key secret they pointed at.
- **S3 / MinIO (media + git object store):** the module can provision a local
  MinIO instance and wire it into the relay automatically, or you can bring
  your own external S3-compatible store.

  **Provisioned (local MinIO):** flip `provisionMinio = true`. The module
  starts MinIO bound to `127.0.0.1:9000`, runs a oneshot that creates the
  bucket (default `buzz-media`), and sets `BUZZ_S3_ENDPOINT` / `BUZZ_S3_BUCKET`
  in the relay automatically. You supply credentials via two files:

  1. `minioCredentialsFile` (EnvironmentFile for MinIO itself):
     ```
     MINIO_ROOT_USER=<username>
     MINIO_ROOT_PASSWORD=<password-at-least-8-chars>
     ```
  2. The relay's `environmentFile` must also carry the same credentials under
     the relay's key names. systemd EnvironmentFile cannot alias keys across
     services, so both pairs are required:
     ```
     BUZZ_S3_ACCESS_KEY=<same username>
     BUZZ_S3_SECRET_KEY=<same password>
     ```

  ```nix
  services.buzz.relay = {
    enable = true;
    relayUrl = "wss://relay.example.com";
    provisionMinio = true;
    minioCredentialsFile = "/run/secrets/buzz-minio.env";
    # environmentFile must also contain BUZZ_S3_ACCESS_KEY / BUZZ_S3_SECRET_KEY.
    environmentFile = "/run/secrets/buzz-relay.env";
    # Once MinIO is running, gate startup on the conditional-write probe:
    # conformanceProbe = true;
  };
  ```

  The provisioned MinIO satisfies the relay's `If-None-Match: *` conditional
  PUT requirement for the git object-store path, so you can safely enable
  `conformanceProbe = true` once the store is in place.

  **External S3 / MinIO:** leave `provisionMinio = false`, set
  `BUZZ_S3_ENDPOINT`, `BUZZ_S3_BUCKET`, `BUZZ_S3_ACCESS_KEY`, and
  `BUZZ_S3_SECRET_KEY` yourself via `environmentFile` (or `extraEnv` for the
  non-secret endpoint/bucket), and flip `conformanceProbe = true` to gate
  startup on the object store being ready.

## Module options

`services.buzz.relay.*`:

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the relay on. |
| `package` | this flake's `buzz-relay` | Override the binary. |
| `relayUrl` | *(required)* | Public `wss://` URL advertised in NIP-11. |
| `bindAddr` | `0.0.0.0:3000` | `BUZZ_BIND_ADDR`. |
| `port` | `3000` | App port (firewall + derived defaults). |
| `healthPort` / `metricsPort` | `8080` / `9102` | Health and metrics ports. |
| `openFirewall` | `false` | Open `port` in the firewall. |
| `tls.enable` | `false` | Stand up a TLS reverse proxy (Caddy) on 80/443 with an auto Let's Encrypt cert. Opens 80+443. |
| `tls.domain` | `""` | Public hostname the proxy serves and gets a cert for. Required when `tls.enable`. Must match `relayUrl`'s host. |
| `tls.acmeEmail` | `null` | Contact email for the ACME (Let's Encrypt) account. |
| `tls.proxy` | `"caddy"` | Reverse proxy to configure (only `caddy` supported by the turnkey path). |
| `dataDir` | `/var/lib/buzz` | Relay state (git name index under `repos/`). |
| `user` / `group` | `buzz` / `buzz` | Service identity. |
| `requireAuthToken` | `false` | Require a token on REST requests. |
| `requireRelayMembership` | `false` | Enforce `relay_members` on every authed request. |
| `ownerPubkey` | `null` | 64-char hex owner pubkey (bootstrapped as owner). |
| `privateKeyFile` | `null` | EnvironmentFile with `BUZZ_RELAY_PRIVATE_KEY`. |
| `environmentFile` | `null` | EnvironmentFile for any secret env. |
| `conformanceProbe` | `false` | Run the fatal S3 conformance probe at startup. |
| `databaseUrl` | local socket | `DATABASE_URL` for the relay. |
| `redisUrl` | `redis://127.0.0.1:6379` | `REDIS_URL`. |
| `provisionPostgresql` | `true` | Provision a local Postgres (db `buzz`, peer auth). |
| `provisionRedis` | `true` | Provision a local Redis on 127.0.0.1:6379. |
| `provisionMinio` | `false` | Provision a local MinIO on 127.0.0.1:9000, create the bucket, and wire `BUZZ_S3_ENDPOINT`/`BUZZ_S3_BUCKET` into the relay. |
| `minioPackage` | `pkgs.minio` | MinIO package to run when provisioning. Must support `If-None-Match: *` conditional PUT. |
| `minioCredentialsFile` | `null` | EnvironmentFile with `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`. Required when `provisionMinio = true`. |
| `s3Bucket` | `buzz-media` | Bucket name created in MinIO and wired as `BUZZ_S3_BUCKET`. |
| `minioPort` | `9000` | MinIO S3 API port (used to build `BUZZ_S3_ENDPOINT`). |
| `minioConsolePort` | `9001` | MinIO web console port (bound to 127.0.0.1). |
| `database` | `buzz` | Provisioned database name. |
| `applySchema` | `true` | Run `buzz-admin migrate` in `ExecStartPre` on every start. Idempotent; applies only pending migrations. |
| `extraEnv` | `{}` | Extra non-secret env (e.g. `RUST_LOG`, `BUZZ_DB_POOL_SIZE`). |

## Ports

| Port | Use |
| --- | --- |
| 80 / 443 | TLS reverse proxy (Caddy) — only when `tls.enable = true`; the only public surface in that mode |
| 3000 | App: WebSocket + REST + web UI |
| 8080 | Health: `/_liveness`, `/_readiness` |
| 9102 | Prometheus metrics: `/metrics` |
| 9000 / 9001 | MinIO S3 API / console (local, `127.0.0.1`) — only when `provisionMinio = true` |
