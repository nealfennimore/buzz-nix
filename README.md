# buzz-nix

A standalone, portable Nix flake that builds the **buzz relay** (`buzz-relay`, the
crate formerly known as *sprout*) from source and ships a NixOS module to run it.

The relay is the WebSocket server of the [Buzz](https://github.com/block/buzz)
communications platform: a Nostr-flavoured relay that also serves a smart-HTTP
git endpoint and a REST/web surface.

This flake pins:

- buzz source: `github:block/buzz` @ `cbc754cf` (HEAD of `main` at authoring time)
- Rust toolchain: **1.95.0** (the repo's `rust-toolchain.toml`), supplied by
  [`oxalica/rust-overlay`](https://github.com/oxalica/rust-overlay) because
  nixpkgs' default rustc is too old.
- pgschema: **1.7.4** (release binary), used to apply the DB schema.

## What's in the box

| Output | What it is |
| --- | --- |
| `packages.<system>.buzz-relay` (and `.default`) | The `buzz-relay` binary, built from source. |
| `nixosModules.default` | `services.buzz.relay` — systemd service + optional local Postgres/Redis + schema bootstrap. |
| `nixosConfigurations.example` | A minimal, bootable example host with the relay enabled. |
| `checks.x86_64-linux.relay-boot` | A `nixosTest` that boots the relay and proves a NIP-01 round-trip. |
| `devShells.default` | Rust 1.95 + build deps for hacking on the source. |

## Scope (v1)

This packages the **relay + PostgreSQL + Redis** path only — enough to stand up
a working relay. It deliberately leaves out:

- **Typesense** (full-text search). Without it, `search.ensure_collection()`
  logs a non-fatal warning at startup and search queries degrade; everything
  else works.
- **S3 / MinIO** (media + git object storage). The git object-store conformance
  probe is **disabled** by default (`conformanceProbe = false`) so the relay
  starts without an object store. Media uploads and the git-on-object-storage
  features will not function until you wire one up (see *Going further*).

## Quick start

Add the flake as an input and enable the module:

```nix
{
  inputs.buzz-nix.url = "github:orveth/buzz-nix";

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
nix flake check                              # eval the module + example host
nix build .#checks.x86_64-linux.relay-boot   # VM test: boot + NIP-01 round-trip (needs KVM)
```

## Schema bootstrap (important)

The relay does **not** self-apply its database schema (`BUZZ_AUTO_MIGRATE` is
vestigial). The schema is the declarative `schema/schema.sql` in the buzz source,
applied with [`pgschema`](https://github.com/pgschema/pgschema).

The module does this for you in the service's `ExecStartPre` (toggle with
`applySchema`). Two gotchas are handled:

1. **pgschema's embedded PostgreSQL.** `pgschema apply` normally downloads and
   runs an embedded PostgreSQL to validate the desired-state schema. That path is
   broken on NixOS (generic dynamically-linked binaries) and needs network at
   runtime. The module passes `--plan-host` pointing at the live target DB so
   pgschema validates against it instead — fully offline and store-pure.
2. **`CREATE INDEX CONCURRENTLY` on partitioned tables.** pgschema emits
   `CONCURRENTLY` for new indexes, which Postgres rejects on partitioned tables.
   The module pre-creates the one such index non-concurrently first (mirrors
   upstream `scripts/dev-setup.sh`).

If you manage the schema out of band, set `services.buzz.relay.applySchema = false`
and apply `schema/schema.sql` yourself with pgschema (or `psql -f` against a fresh
database).

## TLS reverse proxy

The relay speaks plain HTTP/WS on `:3000`. Terminate TLS at a reverse proxy and
forward with WebSocket upgrade. `relayUrl` should be the public `wss://` URL.

### Caddy

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

## Cloud deployment punchlist

For an AWS (or any cloud) deployment, you provide:

- **Domain + `relayUrl`** — a hostname (`relay.example.com`) with DNS pointing at
  the host, and `relayUrl = "wss://<domain>"`.
- **TLS reverse proxy** — Caddy or nginx in front of `:3000` (above). Keep
  `:8080`/`:9102` internal.
- **Secrets** via `environmentFile` / `privateKeyFile`:
  - `BUZZ_RELAY_PRIVATE_KEY` (stable relay identity) — required to lock down.
  - `BUZZ_GIT_HOOK_HMAC_SECRET` (>= 32 chars) if you want a fixed git-hook secret
    rather than the per-boot random one.
  - S3/MinIO keys (`BUZZ_S3_*`) once you enable media/object storage.
- **Datastore choice** — keep the provisioned local Postgres/Redis, or set
  `provisionPostgresql = false` / `provisionRedis = false` and point
  `databaseUrl` / `redisUrl` (and the `pgHost`/`pgPort`/`pgUser` used by the
  schema step) at managed RDS / ElastiCache.
- **Lockdown toggles** — `requireAuthToken`, `requireRelayMembership`,
  `ownerPubkey` as above.

## Going further: search and media

These are out of scope for v1 but here's the shape of adding them later via
`extraEnv` (and your own service definitions / containers):

- **Typesense (search):** run Typesense, then set `TYPESENSE_URL` and
  `TYPESENSE_API_KEY` in `extraEnv`. The relay creates its collection on startup.
- **S3 / MinIO (media + git object store):** run MinIO (or use S3), set
  `BUZZ_S3_ENDPOINT`, `BUZZ_S3_BUCKET`, and the access/secret keys (keys via
  `environmentFile`), and flip `conformanceProbe = true` to gate startup on the
  object store satisfying the relay's conditional-write requirement.

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
| `database` | `buzz` | Provisioned database name. |
| `applySchema` | `true` | Apply `schema/schema.sql` with pgschema in `ExecStartPre`. |
| `pgHost`/`pgPort`/`pgUser`/`pgPasswordFile` | local socket / `buzz` | Connection for the schema step. |
| `pgschemaPackage` | pinned 1.7.4 | Override the pgschema binary. |
| `extraEnv` | `{}` | Extra non-secret env (e.g. `TYPESENSE_URL`, `RUST_LOG`). |

## Ports

| Port | Use |
| --- | --- |
| 3000 | App: WebSocket + REST + web UI |
| 8080 | Health: `/_liveness`, `/_readiness` |
| 9102 | Prometheus metrics: `/metrics` |
