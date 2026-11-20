# NixOS module for the Buzz relay (buzz-relay).
#
# Exposes `services.buzz.relay`. Wires up a systemd service that:
#   * has `git` on PATH (the relay shells out to git for smart-HTTP), together
#     with the tools the generated git pre-receive hook runs,
#   * reads secrets from an EnvironmentFile,
#   * depends on PostgreSQL + Redis,
#   * bootstraps the declarative schema with `psql` on first start (ExecStartPre).
#
# It can optionally provision a local PostgreSQL database/user and a local
# Redis instance for a self-contained single-host deployment.
#
# `buzzPackage` is the default package (passed from the flake). Override per
# host with `services.buzz.relay.package`.
{ buzzPackage }:

{ config, lib, pkgs, ... }:

let
  cfg = config.services.buzz.relay;

  # Schema management uses upstream's own migration runner, `buzz-admin
  # migrate`. buzz-db embeds the ordered `migrations/*.sql` files into the
  # binary at compile time (`sqlx::migrate!("../../migrations")`), records what
  # it applied in `_sqlx_migrations`, and runs only the pending versions. That
  # makes it store-pure, offline, idempotent, and safe on every start: it never
  # drops anything, so the relay's runtime-created monthly partitions survive.
  #
  # Two earlier approaches were wrong, both because they treated
  # `schema/schema.sql` as the source of truth:
  #
  #   * `pgschema apply --auto-approve` on every start. pgschema (<= 1.7.4)
  #     does not round-trip `CREATE TABLE ... PARTITION OF`, so the declared
  #     partitions of `events` / `delivery_log` came up DETACHED. The relay
  #     papered over that at runtime (`ensure_future_partitions` creates real
  #     partitions like events_2026_08), and the next start saw those runtime
  #     partitions as drift and emitted `DROP TABLE ... CASCADE` — deleting
  #     every stored event on every restart.
  #   * Bootstrapping `schema.sql` once with psql. Non-destructive, but
  #     `schema.sql` is a snapshot that has drifted from `migrations/`: it is
  #     missing `git_repo_names` (migrations/0002), the registry every git
  #     smart-HTTP read and write resolves through. A relay booted that way
  #     passes readiness and serves NIP-01, then fails on the first git
  #     operation. It also left schema upgrades to be applied by hand.
  buzzAdmin = "${cfg.package}/bin/buzz-admin";

  # Environment passed to the relay (non-secret). Secrets (private key, etc.)
  # come from cfg.environmentFile.
  baseEnv = {
    BUZZ_BIND_ADDR = cfg.bindAddr;
    DATABASE_URL = cfg.databaseUrl;
    REDIS_URL = cfg.redisUrl;
    RELAY_URL = cfg.relayUrl;
    BUZZ_HEALTH_PORT = toString cfg.healthPort;
    BUZZ_METRICS_PORT = toString cfg.metricsPort;
    BUZZ_GIT_REPO_PATH = "${cfg.dataDir}/repos";
    # Skip the fatal S3 conformance probe — there is no object store in
    # the v1 (relay + postgres + redis) profile.
    BUZZ_GIT_CONFORMANCE_PROBE = lib.boolToString cfg.conformanceProbe;
    BUZZ_REQUIRE_AUTH_TOKEN = lib.boolToString cfg.requireAuthToken;
    BUZZ_REQUIRE_RELAY_MEMBERSHIP = lib.boolToString cfg.requireRelayMembership;
  }
  // lib.optionalAttrs (cfg.ownerPubkey != null) { RELAY_OWNER_PUBKEY = cfg.ownerPubkey; }
  # BUZZ_S3_ENDPOINT and BUZZ_S3_BUCKET are non-secret. The access/secret keys
  # are secrets and must come from cfg.environmentFile (never baseEnv).
  // lib.optionalAttrs cfg.provisionRustfs {
    BUZZ_S3_ENDPOINT = rustfsEndpoint;
    BUZZ_S3_BUCKET = cfg.s3Bucket;
  }
  // cfg.extraEnv;

  relayExecStart = lib.getExe cfg.package;

  rustfsEndpoint = "http://127.0.0.1:${toString cfg.rustfsPort}";

  # rclone reads a remote named NAME from RCLONE_CONFIG_NAME_* variables, so
  # the bucket oneshot needs no rclone config file.
  rcloneRemote = name: url: {
    "RCLONE_CONFIG_${lib.toUpper name}_TYPE" = "s3";
    "RCLONE_CONFIG_${lib.toUpper name}_PROVIDER" = "Other";
    "RCLONE_CONFIG_${lib.toUpper name}_ENDPOINT" = url;
    "RCLONE_CONFIG_${lib.toUpper name}_REGION" = "us-east-1";
  };

in
{
  imports =
    let
      # relay-v0.2.1 dropped Typesense: full-text search moved into PostgreSQL
      # (crates/buzz-search), and the relay reads neither TYPESENSE_URL nor
      # TYPESENSE_API_KEY.
      typesenseGone = ''
        Removed in relay-v0.2.1. The relay searches PostgreSQL, so it runs no
        Typesense. Delete this option, and delete the Typesense API key secret
        that it points at.
      '';
      # nixpkgs removed the minio package and the services.minio module
      # (2026-11). RustFS replaces MinIO as the local S3 store.
      minioGone = ''
        Removed: nixpkgs no longer ships MinIO. Set
        services.buzz.relay.provisionRustfs = true and
        services.buzz.relay.rustfsCredentialsFile instead. The credentials file
        uses RUSTFS_ACCESS_KEY and RUSTFS_SECRET_KEY, not MINIO_ROOT_USER and
        MINIO_ROOT_PASSWORD. RustFS does not read a MinIO data directory:
        copy the bucket contents across with rclone before you delete it.
      '';
    in
    # A host that still sets one of these options gets a message that says
    # what replaced it, instead of "option does not exist".
    map (opt: lib.mkRemovedOptionModule [ "services" "buzz" "relay" opt ] typesenseGone) [
      "provisionTypesense"
      "typesenseApiKeyFile"
      "typesensePackage"
      "typesenseUrl"
    ]
    ++ map (opt: lib.mkRemovedOptionModule [ "services" "buzz" "relay" opt ] minioGone) [
      "provisionMinio"
      "minioPackage"
      "minioCredentialsFile"
      "minioConsolePort"
    ]
    ++ [
      (lib.mkRenamedOptionModule
        [ "services" "buzz" "relay" "minioPort" ]
        [ "services" "buzz" "relay" "rustfsPort" ]
      )
    ];

  options.services.buzz.relay = {
    enable = lib.mkEnableOption "the Buzz relay (buzz-relay)";

    package = lib.mkOption {
      type = lib.types.package;
      default = buzzPackage;
      defaultText = lib.literalExpression "buzz-nix.packages.\${system}.buzz-relay";
      description = "The buzz-relay package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "buzz";
      description = "User account under which the relay runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "buzz";
      description = "Group under which the relay runs.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/buzz";
      description = ''
        State directory for the relay. Holds the git name-reservation index and
        any ephemeral repo working state under {file}`''${dataDir}/repos`.
      '';
    };

    bindAddr = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:3000";
      example = "127.0.0.1:3000";
      description = "Address the relay's HTTP/WebSocket server binds to (BUZZ_BIND_ADDR).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = ''
        Application port (WS + REST + web UI). Used for firewall opening and
        derived defaults. Keep in sync with {option}`bindAddr` if you change it.
      '';
    };

    healthPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Health-probe port (/_liveness, /_readiness). BUZZ_HEALTH_PORT.";
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9102;
      description = "Prometheus metrics exporter port (/metrics). BUZZ_METRICS_PORT.";
    };

    relayUrl = lib.mkOption {
      type = lib.types.str;
      example = "wss://relay.example.com";
      description = ''
        Public WebSocket URL of this relay, advertised in NIP-11 (RELAY_URL).
        Use the wss:// URL clients connect to (typically your TLS reverse-proxy
        hostname). For first-light without TLS you may use ws://host:3000.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the application {option}`port` in the host firewall.";
    };

    # ── TLS reverse proxy (turnkey public deploy) ─────────────────────────────
    tls = {
      enable = lib.mkEnableOption ''
        a TLS-terminating reverse proxy in front of the relay. Turnkey path for a
        public deployment: stands up a proxy on 80/443 that obtains a Let's
        Encrypt certificate for {option}`tls.domain` and forwards to the relay's
        local {option}`port`, transparently upgrading WebSocket connections.

        OFF by default so dev / single-host (plain ws://host:3000) deployments are
        unaffected. When enabled, {option}`relayUrl` MUST be `wss://<domain>` (the
        host that NIP-42 AUTH is bound to), enforced by an assertion'';

      domain = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "relay.example.com";
        description = ''
          Public hostname the proxy serves and requests a certificate for. DNS
          for this name must resolve to the host (an A/AAAA record) for ACME's
          HTTP-01 challenge on port 80 to succeed. Must match the host in
          {option}`relayUrl`.
        '';
      };

      acmeEmail = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "admin@example.com";
        description = ''
          Contact email for the ACME (Let's Encrypt) account. Optional but
          recommended: Let's Encrypt uses it for expiry warnings and account
          recovery. When set with the Caddy proxy it becomes Caddy's global
          `email` directive.
        '';
      };

      proxy = lib.mkOption {
        type = lib.types.enum [ "caddy" ];
        default = "caddy";
        description = ''
          Which reverse proxy to configure. Only `caddy` is supported by the
          turnkey path today: Caddy handles ACME and WebSocket upgrades with zero
          extra configuration. For nginx, leave {option}`tls.enable` off and
          configure `services.nginx` yourself (see the README), pointing it at
          the relay's {option}`port`.
        '';
      };
    };

    # ── Auth / lockdown ──────────────────────────────────────────────────────
    requireAuthToken = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Require a valid token on REST API requests (BUZZ_REQUIRE_AUTH_TOKEN).
        When false the relay runs "open". Set true for production. The relay
        signing key is required either way (see {option}`privateKeyFile`).
      '';
    };

    requireRelayMembership = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enforce relay-level membership on every authenticated request
        (BUZZ_REQUIRE_RELAY_MEMBERSHIP). Requires both {option}`ownerPubkey` and
        {option}`privateKeyFile` to be set, or the relay refuses to start.
      '';
    };

    ownerPubkey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "npub-as-64-char-hex";
      description = ''
        64-char hex pubkey of the relay owner (RELAY_OWNER_PUBKEY). Bootstrapped
        into relay_members with the owner role on first start.
      '';
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding the relay's stable signing key as
        `BUZZ_RELAY_PRIVATE_KEY=<64-char-hex>` (or any KEY=VALUE the relay reads).
        Loaded via systemd EnvironmentFile so it never lands in the Nix store.
        Since relay-v0.3.0 the relay does not start without this key, so set this
        option or supply BUZZ_RELAY_PRIVATE_KEY through {option}`environmentFile`.
        A stable key keeps the relay identity across restarts. Prefer
        {option}`environmentFile` for multiple secrets.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/buzz-relay.env";
      description = ''
        Path to a systemd EnvironmentFile with secret KEY=VALUE pairs
        (e.g. BUZZ_RELAY_PRIVATE_KEY, BUZZ_GIT_HOOK_HMAC_SECRET, S3 keys).
        Kept out of the Nix store. Takes precedence over values also set in
        {option}`extraEnv`.
      '';
    };

    conformanceProbe = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the git object-store (S3) A3 conformance probe at startup
        (BUZZ_GIT_CONFORMANCE_PROBE). Fatal on failure. Leave false for the
        v1 profile (no object store). Enable only once you have wired S3 (for example provisionRustfs).
      '';
    };

    # ── Datastore wiring ─────────────────────────────────────────────────────
    databaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "postgresql:///buzz?host=/run/postgresql&user=buzz";
      description = ''
        PostgreSQL connection URL (DATABASE_URL) handed to the relay. The default
        uses peer auth over the local socket (the socket dir goes in the `host`
        query parameter, not the authority, so sqlx connects over the socket
        rather than TCP). Matches {option}`provisionPostgresql`. Point this at an
        external Postgres when {option}`provisionPostgresql` is false.
      '';
    };

    # NOTE: the pgHost / pgPort / pgUser / pgPasswordFile options are gone. They
    # existed only to give the old psql/pgschema schema step a connection of its
    # own. `buzz-admin migrate` takes DATABASE_URL, so the migration step and the
    # relay now share exactly one connection string and cannot disagree.

    redisUrl = lib.mkOption {
      type = lib.types.str;
      default = "redis://127.0.0.1:6379";
      description = "Redis connection URL (REDIS_URL).";
    };

    provisionPostgresql = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable a local PostgreSQL with a `buzz` database and `buzz` user (peer
        auth). Disable to point {option}`databaseUrl` at an external Postgres.
      '';
    };

    provisionRedis = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable a local Redis instance on 127.0.0.1:6379. Disable to point
        {option}`redisUrl` at an external Redis.
      '';
    };

    # ── RustFS (S3-compatible object storage) ────────────────────────────────
    provisionRustfs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable a local RustFS (S3-compatible) instance on 127.0.0.1 and wire
        `BUZZ_S3_ENDPOINT` / `BUZZ_S3_BUCKET` into the relay. OFF by default: the
        v1 profile (relay + Postgres + Redis) starts without object storage and
        disables the git object-store conformance probe. Enable this to provision
        a self-contained object store for media uploads and git object storage.

        RustFS replaces MinIO, which nixpkgs removed. It runs through the nixpkgs
        `services.rustfs` module, so the host needs a nixpkgs that has it.

        Requires {option}`rustfsCredentialsFile`. The same credentials
        (RUSTFS_ACCESS_KEY / RUSTFS_SECRET_KEY) must ALSO be supplied to the relay
        as BUZZ_S3_ACCESS_KEY / BUZZ_S3_SECRET_KEY in the relay's
        {option}`environmentFile` — systemd EnvironmentFile cannot alias keys
        across services, so both pairs must appear in their respective files.

        RustFS supports the conditional writes (If-None-Match / If-Match on
        PutObject) that the relay needs, so you can enable
        {option}`conformanceProbe` to gate relay startup on them.
      '';
    };

    rustfsCredentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/buzz-rustfs.env";
      description = ''
        Path to a systemd EnvironmentFile containing the RustFS credentials:

        ```
        RUSTFS_ACCESS_KEY=<access-key>
        RUSTFS_SECRET_KEY=<secret-key>
        ```

        Required when {option}`provisionRustfs` is true. Read at runtime so
        credentials never enter the Nix store. The bucket bootstrap oneshot reads
        the same file.

        The relay needs these same credentials under different key names. You must
        also supply `BUZZ_S3_ACCESS_KEY=<same access key>` and
        `BUZZ_S3_SECRET_KEY=<same secret key>` in the relay's
        {option}`environmentFile`.
      '';
    };

    s3Bucket = lib.mkOption {
      type = lib.types.str;
      default = "buzz-media";
      description = ''
        S3 bucket name to create and use for buzz media and git object storage
        (BUZZ_S3_BUCKET). Used both for the bucket bootstrap oneshot and wired
        into the relay as BUZZ_S3_BUCKET when {option}`provisionRustfs` is true.
      '';
    };

    rustfsPort = lib.mkOption {
      type = lib.types.port;
      default = 9000;
      description = ''
        Port RustFS listens on (S3 API), bound to 127.0.0.1. Used to construct
        BUZZ_S3_ENDPOINT (`http://127.0.0.1:<rustfsPort>`) when
        {option}`provisionRustfs` is true. The RustFS web console stays off.
      '';
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = "buzz";
      description = "Database name to provision when {option}`provisionPostgresql` is true.";
    };

    applySchema = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run `buzz-admin migrate` in ExecStartPre on every start. It applies the
        pending migrations from {file}`migrations/`, which buzz-db embeds into
        the binary at build time, and records them in `_sqlx_migrations`. A
        fresh database gets the full schema, an up-to-date one is a no-op, and
        an upgraded relay applies only its new migrations.

        The relay itself does NOT self-migrate (BUZZ_AUTO_MIGRATE is
        vestigial), so leave this on unless you run the migrator yourself.

        Do NOT replace this with a declarative tool that converges the live
        database against {file}`schema/schema.sql`. That file has drifted from
        {file}`migrations/` (it is missing `git_repo_names`), and converging on
        every start deletes the monthly partitions the relay creates at
        runtime. See the note at the top of this module.
      '';
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''{ RUST_LOG = "buzz_relay=debug"; }'';
      description = "Extra non-secret environment variables for the relay.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.requireRelayMembership -> (cfg.ownerPubkey != null);
        message = "services.buzz.relay: requireRelayMembership=true requires ownerPubkey to be set.";
      }
      {
        # Since relay-v0.3.0 the relay refuses to start without
        # BUZZ_RELAY_PRIVATE_KEY ("BUZZ_RELAY_PRIVATE_KEY must be set"). Older
        # releases fell back to a dev keypair. The module cannot see inside the
        # files, so it checks only that one of them is set.
        assertion = cfg.privateKeyFile != null || cfg.environmentFile != null;
        message = ''
          services.buzz.relay: the relay requires BUZZ_RELAY_PRIVATE_KEY (relay-v0.3.0+).
          Set privateKeyFile, or supply BUZZ_RELAY_PRIVATE_KEY via environmentFile.
          Generate a key with: openssl rand -hex 32
        '';
      }
      {
        assertion = cfg.provisionRustfs -> (cfg.rustfsCredentialsFile != null);
        message = ''
          services.buzz.relay: provisionRustfs=true requires rustfsCredentialsFile.
          Point it at a systemd EnvironmentFile containing RUSTFS_ACCESS_KEY and
          RUSTFS_SECRET_KEY. The same credentials must also appear as
          BUZZ_S3_ACCESS_KEY / BUZZ_S3_SECRET_KEY in the relay's environmentFile.
        '';
      }
      {
        assertion = cfg.tls.enable -> (cfg.tls.domain != "");
        message = "services.buzz.relay: tls.enable=true requires tls.domain to be set (e.g. \"relay.example.com\").";
      }
      {
        # NIP-42 ties AUTH to relayUrl's host, and clients connect to wss://<domain>
        # through the proxy. If relayUrl is not the TLS host, AUTH challenges and
        # the advertised NIP-11 URL won't match what clients actually reach.
        assertion =
          cfg.tls.enable
          -> (lib.hasPrefix "wss://" cfg.relayUrl && lib.hasInfix cfg.tls.domain cfg.relayUrl);
        message = ''
          services.buzz.relay: with tls.enable=true, relayUrl must be the public
          wss:// URL on tls.domain (NIP-42 binds AUTH to this host). Set
          relayUrl = "wss://${if cfg.tls.domain == "" then "<domain>" else cfg.tls.domain}".
          Got relayUrl = "${cfg.relayUrl}".
        '';
      }
    ];

    users.users = lib.mkIf (cfg.user == "buzz") {
      buzz = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        description = "Buzz relay service user";
      };
    };
    users.groups = lib.mkIf (cfg.group == "buzz") { buzz = { }; };

    # ── Local PostgreSQL ────────────────────────────────────────────────────
    services.postgresql = lib.mkIf cfg.provisionPostgresql {
      enable = true;
      ensureDatabases = [ cfg.database ];
      ensureUsers = [
        {
          name = cfg.user;
          ensureDBOwnership = true;
        }
      ];
    };

    # ── Local Redis ─────────────────────────────────────────────────────────
    services.redis.servers.buzz = lib.mkIf cfg.provisionRedis {
      enable = true;
      bind = "127.0.0.1";
      port = 6379;
    };

    # ── Local RustFS (S3-compatible object storage) ─────────────────────────
    # The relay needs S3 conditional writes (If-None-Match and If-Match on
    # PutObject) for safe concurrent git object writes. RustFS supports them,
    # and conformanceProbe tests them at relay start.
    services.rustfs = lib.mkIf cfg.provisionRustfs {
      enable = true;
      environmentFile = cfg.rustfsCredentialsFile;
      settings = {
        RUSTFS_ADDRESS = "127.0.0.1:${toString cfg.rustfsPort}";
        RUSTFS_REGION = "us-east-1";
        # The relay is the only client. Nothing uses the web console.
        RUSTFS_CONSOLE_ENABLE = "false";
        # The update check sends a request to version.rustfs.com at start.
        RUSTFS_CHECK_UPDATE = "false";
      };
    };

    # Bucket bootstrap oneshot: wait until RustFS accepts the credentials, then
    # create the media bucket idempotently. The relay orders itself after this
    # unit, so the bucket exists before the relay writes to it. The S3 client is
    # rclone, because nixpkgs marks minio-client insecure.
    systemd.services.buzz-rustfs-bucket = lib.mkIf cfg.provisionRustfs {
      description = "Create the buzz S3 bucket in local RustFS";
      after = [ "rustfs.service" ];
      requires = [ "rustfs.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = rcloneRemote "rustfs" rustfsEndpoint // {
        RCLONE_CACHE_DIR = "/run/buzz-rustfs-bucket";
        # The unit has no HOME. Without an explicit path, rclone logs errors
        # while it searches for a config directory. The file never exists: the
        # remote comes from the RCLONE_CONFIG_RUSTFS_* variables.
        RCLONE_CONFIG = "/run/buzz-rustfs-bucket/rclone.conf";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = cfg.rustfsCredentialsFile;
        RuntimeDirectory = "buzz-rustfs-bucket";
        ExecStart = pkgs.writeShellScript "buzz-rustfs-bucket-init" ''
          set -euo pipefail
          export RCLONE_CONFIG_RUSTFS_ACCESS_KEY_ID="$RUSTFS_ACCESS_KEY"
          export RCLONE_CONFIG_RUSTFS_SECRET_ACCESS_KEY="$RUSTFS_SECRET_KEY"
          RCLONE=${lib.getExe pkgs.rclone}

          # Listing the buckets fails until RustFS accepts the credentials.
          ok=
          for i in $(${pkgs.coreutils}/bin/seq 1 60); do
            if $RCLONE lsd rustfs: >/dev/null 2>&1; then
              ok=1
              break
            fi
            echo "Waiting for RustFS ($i/60)..."
            ${pkgs.coreutils}/bin/sleep 1
          done
          if [ -z "$ok" ]; then
            echo "RustFS did not become ready in time" >&2
            exit 1
          fi

          # mkdir on an existing bucket succeeds.
          $RCLONE mkdir "rustfs:${cfg.s3Bucket}"
          echo "Bucket ${cfg.s3Bucket} is ready."
        '';
      };
    };

    # ── The relay service ───────────────────────────────────────────────────
    systemd.services.buzz-relay = {
      description = "Buzz relay (buzz-relay)";
      wantedBy = [ "multi-user.target" ];
      after =
        [ "network-online.target" ]
        ++ lib.optional cfg.provisionPostgresql "postgresql.service"
        ++ lib.optional cfg.provisionRedis "redis-buzz.service"
        ++ lib.optional cfg.provisionRustfs "buzz-rustfs-bucket.service";
      requires =
        lib.optional cfg.provisionPostgresql "postgresql.service"
        ++ lib.optional cfg.provisionRedis "redis-buzz.service";
      # RustFS is soft (Wants): the bucket bootstrap must succeed before the
      # relay starts, but if RustFS later fails the relay can continue serving
      # non-media requests.
      wants =
        [ "network-online.target" ]
        ++ lib.optional cfg.provisionRustfs "buzz-rustfs-bucket.service";

      # This list is the ENTIRE PATH of the unit. NixOS emits
      # `Environment=PATH=<these>` and merges in no system default, and every
      # process the relay spawns inherits it. Each entry is load-bearing:
      #
      #   * git — the relay shells out to it for smart-HTTP (upload-pack /
      #     receive-pack / repo hydrate).
      #
      #   * bash, coreutils, gnused, openssl, curl — the git pre-receive hook.
      #     The relay writes `hooks/pre-receive` into every bare repo (upstream
      #     crates/buzz-relay/src/api/git/hook.rs) and git receive-pack runs it.
      #     The script starts with `#!/usr/bin/env bash` and calls mktemp, date,
      #     sort, cat, rm, sed, `openssl dgst` and curl. It is fail-closed: it
      #     rejects the push on any error, so one absent tool blocks all writes.
      #     A missing interpreter rejects every push with
      #     `env: 'bash': No such file or directory`, before the hook body runs.
      #     Do not replace bash with a POSIX shell here. The hook needs
      #     `set -o pipefail`, which dash does not support.
      #
      #   * postgresql — psql. The unit itself does not need it (buzz-admin
      #     talks to Postgres over sqlx). It is kept for `systemctl status`
      #     triage and manual inspection of the live database.
      path = [
        pkgs.git
        pkgs.bash
        pkgs.coreutils
        pkgs.gnused
        pkgs.openssl
        pkgs.curl
        pkgs.postgresql
      ];

      environment = baseEnv;

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStart = relayExecStart;
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "buzz";
        StateDirectoryMode = "0750";
        WorkingDirectory = cfg.dataDir;

        EnvironmentFile =
          lib.optional (cfg.environmentFile != null) cfg.environmentFile
          ++ lib.optional (cfg.privateKeyFile != null) cfg.privateKeyFile;

        # Bring the schema up to date before the relay starts, on EVERY start.
        # `buzz-admin migrate` applies only the migrations recorded as pending
        # in `_sqlx_migrations`, so a fresh database gets the full schema, an
        # up-to-date one is a no-op, and an upgraded relay applies just its new
        # migrations. Nothing is ever dropped, so the relay's runtime-created
        # monthly partitions survive restarts (see the note at the top of this
        # module for the two ways this went wrong before).
        #
        # DATABASE_URL is inherited from the unit's Environment=, and from
        # EnvironmentFile= when the operator overrides it there with a
        # credentialed URL.
        ExecStartPre = lib.mkIf cfg.applySchema [
          (pkgs.writeShellScript "buzz-relay-migrate" ''
            set -euo pipefail
            echo "applying pending buzz migrations"
            ${buzzAdmin} migrate
            echo "migrations up to date"
          '')
        ];

        # Hardening.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    # ── TLS reverse proxy (Caddy) ────────────────────────────────────────────
    # Caddy terminates TLS for cfg.tls.domain, obtains/renews a Let's Encrypt
    # certificate automatically (HTTP-01 over :80), and reverse-proxies to the
    # relay's local app port. WebSocket upgrades are forwarded transparently —
    # reverse_proxy passes through the Upgrade/Connection headers with no extra
    # config. Cert + account state persists in Caddy's default /var/lib/caddy.
    services.caddy = lib.mkIf (cfg.tls.enable && cfg.tls.proxy == "caddy") {
      enable = true;
      email = lib.mkIf (cfg.tls.acmeEmail != null) cfg.tls.acmeEmail;
      virtualHosts.${cfg.tls.domain}.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    };

    networking.firewall.allowedTCPPorts =
      lib.optional cfg.openFirewall cfg.port
      # The proxy needs 80 (ACME HTTP-01 + redirect) and 443 (TLS) reachable.
      ++ lib.optionals cfg.tls.enable [
        80
        443
      ];
  };
}
