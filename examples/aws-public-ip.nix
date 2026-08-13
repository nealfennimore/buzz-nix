# Example AWS NixOS host: buzz relay on a PUBLIC IP, no domain, no TLS.
#
# This is the "first light" / no-domain start described in docs/aws-deploy.md:
# the relay is exposed directly on :3000 over plain ws://, locked down to relay
# members, with media + git objects on MANAGED AWS S3 (not the bundled MinIO)
# and a daily Postgres dump to the same bucket. The box is disposable/resizable;
# all durable state is in Postgres + S3.
#
# The desktop app and CLI work over ws://<IP>:3000. The web UI needs a domain
# (browsers require a secure context, i.e. wss://) — when you want it, see the
# "WHEN YOU GET A DOMAIN" block at the bottom and docs/aws-deploy.md.
#
# ── How to use ────────────────────────────────────────────────────────────────
# Add this module to a nixosSystem alongside buzz-nix's module, e.g. in flake.nix:
#
#   nixosConfigurations.buzz-relay = nixpkgs.lib.nixosSystem {
#     system = "x86_64-linux";              # aarch64-linux for Graviton
#     modules = [
#       buzz-nix.nixosModules.default       # the buzz relay module
#       ./examples/aws-public-ip.nix        # this file
#     ];
#     specialArgs = { inherit nixpkgs; };   # for the amazon-image import below
#   };
#
# Replace every <PLACEHOLDER> and provide the secret files (see comments).
# ──────────────────────────────────────────────────────────────────────────────

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Standard AWS / EC2 NixOS host profile (cloud-init, growpart, ENA, etc).
    # `modulesPath` resolves to your nixpkgs' nixos/modules, so this works
    # without threading nixpkgs through specialArgs.
    "${modulesPath}/virtualisation/amazon-image.nix"
  ];

  # ── The relay ───────────────────────────────────────────────────────────────
  services.buzz.relay = {
    enable = true;

    # PUBLIC-IP START (no domain, no TLS). NIP-42 AUTH binds to relayUrl, so set
    # it to the box's Elastic IP. The relay is the public surface directly here.
    relayUrl     = "ws://<ELASTIC-IP>:3000";   # REPLACE <ELASTIC-IP>
    bindAddr     = "0.0.0.0:3000";             # listen on all interfaces (no proxy in front)
    openFirewall = true;                       # opens :3000 in the host firewall
    tls.enable   = false;                      # no Let's Encrypt without a domain

    # Backing datastores: provision Postgres + Redis locally (both bound to
    # 127.0.0.1 by the module). Full-text search runs inside Postgres.
    provisionPostgresql = true;
    provisionRedis      = true;

    # OBJECT STORE: managed AWS S3, NOT the bundled MinIO (archived/unmaintained
    # upstream; see docs/aws-deploy.md). With provisionMinio = false the module
    # does NOT set BUZZ_S3_* for you — supply the full S3 config in environmentFile:
    #
    #   /run/secrets/buzz-relay.env
    #   ---------------------------------------------------------------
    #   BUZZ_RELAY_PRIVATE_KEY=<openssl rand -hex 32>   # 64 hex chars, stable relay identity
    #   BUZZ_S3_ENDPOINT=https://s3.<region>.amazonaws.com
    #   BUZZ_S3_BUCKET=<your-bucket>
    #   BUZZ_S3_ACCESS_KEY=<iam-access-key-id>          # S3-scoped IAM user
    #   BUZZ_S3_SECRET_KEY=<iam-secret-access-key>
    #   # optional: BUZZ_GIT_HOOK_HMAC_SECRET=<openssl rand -hex 32>   # >=32 chars
    #   ---------------------------------------------------------------
    provisionMinio  = false;
    environmentFile = "/run/secrets/buzz-relay.env";          # REPLACE / provide file

    # The git object-store conformance probe asserts S3 conditional-write behavior
    # (If-None-Match: * -> 412) at startup and is FATAL on failure. AWS S3 can
    # return 409 instead of 412 under concurrency, so VALIDATE your bucket's
    # behavior before turning this on (see docs/aws-deploy.md). Leave false until
    # then; flip to true once verified to fail fast on a misconfigured store.
    conformanceProbe = false;

    # LOCKDOWN: anyone can connect, only members can publish/upload.
    requireAuthToken       = true;             # REST surface needs a token
    requireRelayMembership = true;             # every authed request checked against relay_members
    ownerPubkey = "<YOUR-64-CHAR-HEX-PUBKEY>"; # REPLACE; bootstrapped as owner on first start
    # requireRelayMembership needs a stable signing key — provided above as
    # BUZZ_RELAY_PRIVATE_KEY in environmentFile.
  };

  # ── Daily Postgres backup -> the same S3 bucket ─────────────────────────────
  # Postgres (events) + S3 (media + git) are the only durable state, so a daily
  # pg_dump to S3 makes the box disposable. Restore on a fresh box with:
  #   aws s3 cp s3://<bucket>/pg-backups/buzz-<ts>.sql.gz - | gunzip | psql buzz
  # TEST a restore once before relying on it. Turn ON S3 bucket versioning too.
  systemd.services.buzz-pg-backup = {
    description = "Daily pg_dump of the buzz database to S3";
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      EnvironmentFile = "/run/secrets/buzz-relay.env";  # provides BUZZ_S3_BUCKET + AWS creds
    };
    path = [ pkgs.postgresql pkgs.awscli2 pkgs.gzip ];
    script = ''
      set -euo pipefail
      ts=$(date -u +%Y%m%dT%H%M%SZ)
      pg_dump buzz | gzip | aws s3 cp - "s3://$BUZZ_S3_BUCKET/pg-backups/buzz-$ts.sql.gz"
    '';
  };
  systemd.timers.buzz-pg-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; Persistent = true; };
  };

  # ── Standard AWS NixOS host bits ────────────────────────────────────────────
  networking.hostName = "buzz-relay";

  # Open ONLY the relay app port. Backing services (health 8080, metrics 9102,
  # Postgres, Redis) stay bound to 127.0.0.1 — never opened here.
  # (services.buzz.relay.openFirewall = true already opens 3000; listed for clarity.)
  networking.firewall.allowedTCPPorts = [ 22 3000 ];

  # Docker/CNI veth interfaces clobber the EC2 metadata route via dhcpcd; deny
  # them so the instance keeps its metadata route (nixpkgs#109389).
  networking.dhcpcd.denyInterfaces = [ "veth*" ];

  # amazon-image.nix wires its own boot/network init; disable the legacy
  # amazon-init unit so it doesn't fight cloud-init / the declarative config.
  virtualisation.amazon-init.enable = false;

  # SSH: key-only, no passwords, restrict :22 to your admin CIDR in the AWS
  # security group (not here).
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA...REPLACE-WITH-YOUR-PUBLIC-KEY"   # REPLACE
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Keep the Nix store from growing without bound on a long-lived box.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Match the NixOS release you first deployed; do not bump casually.
  system.stateVersion = "24.11";

  # ── WHEN YOU GET A DOMAIN: switch to TLS (wss://) ───────────────────────────
  # The web UI needs a secure context (wss://), so add a domain to unlock it.
  # Replace the relay block above with the TLS variant below, then create a DNS
  # A/AAAA record for the domain -> Elastic IP, change the security group to open
  # 80 + 443 and CLOSE 3000, and redeploy. (Do the first cert against Let's
  # Encrypt STAGING to avoid burning the prod rate limit on a typo.)
  #
  #   services.buzz.relay = {
  #     enable   = true;
  #     relayUrl = "wss://relay.<DOMAIN>";        # MUST match tls.domain (NIP-42 binds to it)
  #     bindAddr = "127.0.0.1:3000";              # only the proxy reaches the relay now
  #     openFirewall = false;                     # tls.enable opens 80/443 instead of 3000
  #     tls = {
  #       enable    = true;
  #       domain    = "relay.<DOMAIN>";
  #       acmeEmail = "<you@example.com>";        # a real address; ACME fails otherwise
  #     };
  #     # ...everything else (provision*, S3 environmentFile, lockdown) unchanged...
  #   };
  #
  # And update the firewall to match the proxy:
  #   networking.firewall.allowedTCPPorts = [ 22 80 443 ];
}
