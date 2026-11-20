# Buzz relay deploy runbook (AWS, public wss://)

Paint-by-numbers for standing up the buzz relay on a single AWS instance from
this flake. The `nixosConfigurations.publicExample` host in `flake.nix` is the
reference config; this runbook is the operational sequence around it.

Pick the fork first:
- **tailnet** (private): skip TLS/DNS/ACME, set `relayUrl = "ws://<tailnet-ip>:3000"`,
  `bindAddr = "0.0.0.0:3000"`, no Caddy. Members join by being on the tailnet.
  Simplest, nothing public. (Good for a private/team setup.)
- **public** (this runbook): `wss://relay.<domain>` with Caddy + Let's Encrypt,
  reachable from anywhere, membership gates writes.

## Order matters: DNS before deploy

ACME (Let's Encrypt) issues the cert on first boot by proving you control the
domain. The DNS record must already resolve to the instance, so:

1. **Allocate an Elastic IP** in AWS (so the address is stable before the box exists).
2. **Create the DNS record:** `A` (and `AAAA` if v6) for `relay.<domain>` to that EIP.
   Let it propagate. If DNS is not resolving when the relay first boots, Caddy's
   first cert request fails and the relay will not serve TLS.
3. **Use the Let's Encrypt staging endpoint for the first deploy** so a DNS or
   config misconfig does not burn the production issuance rate limit (LE prod is
   ~5 failures/account/hour). Point Caddy's CA at staging, confirm the whole stack
   comes up, then flip to prod and redeploy for the real cert.

## 1. Secrets (two files, never in the Nix store)

Generate and place these on the instance at `/run/secrets/` (manual scp for a
first deploy; move to sops-nix / agenix once it works):

```
# buzz-relay.env  (read by the relay)
BUZZ_RELAY_PRIVATE_KEY=<openssl rand -hex 32>      # 64 hex chars, the relay identity
BUZZ_S3_ACCESS_KEY=<openssl rand -hex 16>
BUZZ_S3_SECRET_KEY=<openssl rand -hex 32>
BUZZ_GIT_HOOK_HMAC_SECRET=<openssl rand -hex 32>   # optional, >=32 chars, for git hooks

# buzz-rustfs.env  (read by RustFS + the bucket bootstrap)
RUSTFS_ACCESS_KEY=<same value as BUZZ_S3_ACCESS_KEY>
RUSTFS_SECRET_KEY=<same value as BUZZ_S3_SECRET_KEY>
```

Note the duplication: systemd EnvironmentFile cannot alias keys across services,
so the RustFS credentials appear under both their `RUSTFS_*` names and the relay's
`BUZZ_S3_*` names, with identical values.

File hygiene (the classic foot-guns):
- `chmod 0400` and `chown` each file to the relay's service user. The module loads
  them via systemd `EnvironmentFile`, which is read before ExecStart, so the values
  are present at startup (the relay unit also orders after the provisioned services).
- The `tls.acmeEmail` (set in the host config, step 2) must be a real address or
  Let's Encrypt issuance fails; with the wrong/empty value the failure is quiet.

## 2. Fill in the host config

In your copy of the `publicExample` host, replace:
- `relayUrl` and `tls.domain` to `relay.<your-domain>` (they must match; NIP-42 binds to it).
- `tls.acmeEmail` to a real contact.
- `ownerPubkey` to your 64-char hex pubkey (this is the relay owner; bootstraps membership).
- the `boot.loader` / `fileSystems` skeleton to the real instance layout (see step 3).

`requireAuthToken`, `requireRelayMembership`, and the three `provision*` flags are
already set true in `publicExample`; `conformanceProbe = true` gates startup on
RustFS's conditional-write support (validated by the flake's full-stack VM test).

## 3. Build the AMI and launch

Build a NixOS AMI from the host config with nixos-generators (amazon format) or
the nixpkgs `amazonImage` profile:

```
nix run github:nix-community/nixos-generators -- \
  -f amazon -c ./public-host.nix -o ./result-ami
```

**Match the architecture to the instance you will launch.** Build x86_64 for an
Intel/AMD instance, aarch64 for Graviton. A mismatch is a silent boot failure
(the instance never comes up, with no clear error), so this bites quietly.

`nixos-generators -f amazon` emits a disk image (VHD), not a registered AMI. Land
it in EC2:
1. Upload the image to an S3 bucket.
2. `aws ec2 import-snapshot` from that object, wait for it to complete.
3. `aws ec2 register-image` against the resulting snapshot (set the right
   architecture and ENA support) to get an AMI id.

(Simpler alternative if you have a NixOS base AMI: launch it, copy the flake, and
`nixos-rebuild switch --flake .#publicExample` in place. No import/register dance,
just slower; same end state.)

Then launch an instance from the AMI:
- attach the **Elastic IP** from the DNS step,
- **security group** inbound: `443` (TLS) + `80` (ACME HTTP-01 redirect) + `22` (admin).
  The module sets `openFirewall = false` and binds the relay to loopback, so Caddy
  on 80/443 is the only public surface; the SG is the network gate.
- size for the stack: relay + Postgres + Redis + RustFS on one box
  (a 4 GB / 2 vCPU instance is a comfortable floor; size up for real traffic).

(Alternative: launch a stock NixOS AMI, copy the flake, and
`nixos-rebuild switch --flake .#publicExample` in place. Same result, slower.)

## 4. First boot does the rest

On boot the module: applies pending DB migrations via `buzz-admin migrate`, brings up
pg/redis/rustfs, bootstraps the `buzz-media` bucket, runs the
conditional-write conformance probe, and Caddy obtains the Let's Encrypt cert for
`relay.<domain>`. All four services come up under systemd.

## 5. Verify (gate cutover on these)

```
curl -fsS https://relay.<domain>/_liveness        # 200
curl -fsS https://relay.<domain>/_readiness       # ready
# connect a client (desktop app / CLI) to wss://relay.<domain> and authenticate
```

Then as owner, add the first members (their pubkeys) so they can write.

## 6. Onboard the team (~5 min each)

Per person: install the desktop app or the `buzz` CLI, generate a keypair
(`BUZZ_PRIVATE_KEY`), the owner adds their pubkey to membership, connect to
`wss://relay.<domain>`. Optionally each runs their own buzz-acp agent locally
(its own keypair + persona + workdir + model key) pointed at the same relay.

## Security posture (public path)

Layered, right-sized for a team relay that is internet-reachable but not a public service:

- **App layer (the real gate):** `requireRelayMembership` + `ownerPubkey` means only
  members publish/upload; `requireAuthToken` gates the REST surface; the git and
  media endpoints are NIP-98 authenticated. So "public" means anyone can *connect*
  over TLS, but only members can *write*.
- **Proxy layer:** Caddy terminates TLS. Add a rate-limit there as cheap DoS
  insurance on the open port (the one surface the internet can hit).
- **Network layer:** leave the security group open on 443 for a genuinely public
  relay. If you IP-allowlist the SG instead, you have built "private with TLS,"
  which is essentially the tailnet option with extra steps; pick tailnet if that
  is what you actually want.
- **Object store caveat:** the provisioned RustFS is a single local instance, bound
  to `127.0.0.1` behind the membership gate. It has no replication. For durable
  object storage, use an external/managed S3 (`provisionRustfs = false`, point
  `BUZZ_S3_*` at it).

## Rollback

Deployments are NixOS generations: `nixos-rebuild switch --rollback` reverts the
config. Data lives in the Postgres + RustFS volumes, so snapshot the EBS volume
before a risky change. Keep the relay private key and S3 secrets stable across
rebuilds or you orphan identities and stored blobs.
