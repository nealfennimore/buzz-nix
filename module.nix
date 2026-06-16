# NixOS module for the Buzz relay (buzz-relay).
#
# Exposes `services.buzz.relay`. Wires up a systemd service that:
#   * has `git` on PATH (the relay shells out to git for smart-HTTP),
#   * reads secrets from an EnvironmentFile,
#   * depends on PostgreSQL + Redis,
#   * applies the declarative schema with `pgschema` in ExecStartPre.
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

  # pgschema is a standalone Go binary published by github.com/pgschema/pgschema
  # (releases redirect to the pgplex/pgschema org). It is NOT in nixpkgs, and it
  # is what upstream's `just migrate` uses to apply schema/schema.sql. We fetch
  # the pinned release binary rather than re-implement the apply step.
  pgschemaVersion = "1.7.4";
  pgschemaBin = pkgs.stdenvNoCC.mkDerivation {
    pname = "pgschema";
    version = pgschemaVersion;
    src =
      let
        plat =
          {
            x86_64-linux = {
              suffix = "linux-amd64";
              hash = "sha256-aCaRotGGmbYzvskE5lJulMPfVrSzZtrxJVRresad5Mg=";
            };
            aarch64-linux = {
              suffix = "linux-arm64";
              hash = "sha256-LYwV87bxHc1g0vhIV8rWU3TaF2EoHpcqrSHX32SjQKw=";
            };
          }
          .${pkgs.stdenv.hostPlatform.system}
            or (throw "pgschema: unsupported system ${pkgs.stdenv.hostPlatform.system}");
      in
      pkgs.fetchurl {
        url = "https://github.com/pgplex/pgschema/releases/download/v${pgschemaVersion}/pgschema-${pgschemaVersion}-${plat.suffix}";
        inherit (plat) hash;
      };
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    installPhase = ''
      runHook preInstall
      install -Dm755 "$src" "$out/bin/pgschema"
      runHook postInstall
    '';
    meta = {
      description = "Declarative schema migration tool for PostgreSQL";
      homepage = "https://github.com/pgschema/pgschema";
      mainProgram = "pgschema";
      platforms = [ "x86_64-linux" "aarch64-linux" ];
    };
  };

  # The schema lives in the buzz source tree, not in the built package, so we
  # pull it straight out of the same source the package was built from.
  schemaSql = "${cfg.package.src}/schema/schema.sql";

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
    # Skip the fatal S3/MinIO conformance probe — there is no object store in
    # the v1 (relay + postgres + redis) profile.
    BUZZ_GIT_CONFORMANCE_PROBE = lib.boolToString cfg.conformanceProbe;
    BUZZ_REQUIRE_AUTH_TOKEN = lib.boolToString cfg.requireAuthToken;
    BUZZ_REQUIRE_RELAY_MEMBERSHIP = lib.boolToString cfg.requireRelayMembership;
  }
  // lib.optionalAttrs (cfg.ownerPubkey != null) { RELAY_OWNER_PUBKEY = cfg.ownerPubkey; }
  // cfg.extraEnv;

in
{
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

    # ── Auth / lockdown ──────────────────────────────────────────────────────
    requireAuthToken = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Require a valid token on REST API requests (BUZZ_REQUIRE_AUTH_TOKEN).
        When false the relay runs "open" and, if no {option}`privateKeyFile` is
        set, uses a hardcoded dev keypair. Set true for production together with
        {option}`privateKeyFile`.
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
        Required for production / membership enforcement so the relay identity
        survives restarts. Prefer {option}`environmentFile` for multiple secrets.
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
        Run the git object-store (S3/MinIO) A3 conformance probe at startup
        (BUZZ_GIT_CONFORMANCE_PROBE). Fatal on failure. Leave false for the
        v1 profile (no object store). Enable only once you have wired S3/MinIO.
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

    # pgschema connects with standard libpq parameters (it has no DSN flag), so
    # the schema-apply step takes the connection bits separately. Defaults match
    # the provisioned local Postgres over the peer socket.
    pgHost = lib.mkOption {
      type = lib.types.str;
      default = "/run/postgresql";
      description = "Host (or socket dir) pgschema connects to (PGHOST).";
    };
    pgPort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "Port pgschema connects to (PGPORT).";
    };
    pgUser = lib.mkOption {
      type = lib.types.str;
      default = "buzz";
      description = "User pgschema connects as (PGUSER). Peer auth by default.";
    };
    pgPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional file containing the Postgres password for pgschema (read into
        PGPASSWORD for the apply step only). Leave null for peer/socket auth.
      '';
    };

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

    database = lib.mkOption {
      type = lib.types.str;
      default = "buzz";
      description = "Database name to provision when {option}`provisionPostgresql` is true.";
    };

    applySchema = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Apply {file}`schema/schema.sql` with pgschema in ExecStartPre. The relay
        does NOT self-migrate (BUZZ_AUTO_MIGRATE is vestigial), so leave this on
        unless you manage the schema out of band.
      '';
    };

    pgschemaPackage = lib.mkOption {
      type = lib.types.package;
      default = pgschemaBin;
      defaultText = lib.literalExpression "pgschema ${pgschemaVersion} release binary";
      description = "The pgschema package used to apply the schema.";
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
        assertion =
          cfg.requireRelayMembership -> (cfg.privateKeyFile != null || cfg.environmentFile != null);
        message = ''
          services.buzz.relay: requireRelayMembership=true requires a stable signing key.
          Set privateKeyFile (or supply BUZZ_RELAY_PRIVATE_KEY via environmentFile).
        '';
      }
      {
        assertion = cfg.requireAuthToken -> (cfg.privateKeyFile != null || cfg.environmentFile != null);
        message = ''
          services.buzz.relay: requireAuthToken=true requires BUZZ_RELAY_PRIVATE_KEY.
          Set privateKeyFile (or supply it via environmentFile).
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

    # ── The relay service ───────────────────────────────────────────────────
    systemd.services.buzz-relay = {
      description = "Buzz relay (buzz-relay)";
      wantedBy = [ "multi-user.target" ];
      after =
        [ "network-online.target" ]
        ++ lib.optional cfg.provisionPostgresql "postgresql.service"
        ++ lib.optional cfg.provisionRedis "redis-buzz.service";
      requires =
        lib.optional cfg.provisionPostgresql "postgresql.service"
        ++ lib.optional cfg.provisionRedis "redis-buzz.service";
      wants = [ "network-online.target" ];

      # git MUST be on PATH — the relay shells out to it for smart-HTTP
      # (upload-pack / receive-pack / repo hydrate). postgresql client tools are
      # handy for the schema-apply preStart fallback.
      path = [
        pkgs.git
        pkgs.postgresql
      ];

      environment = baseEnv;

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "buzz";
        StateDirectoryMode = "0750";
        WorkingDirectory = cfg.dataDir;

        EnvironmentFile =
          lib.optional (cfg.environmentFile != null) cfg.environmentFile
          ++ lib.optional (cfg.privateKeyFile != null) cfg.privateKeyFile;

        # Apply the declarative schema before the relay starts. pgschema diffs
        # the desired state in schema.sql against the live DB and applies the
        # delta; on a fresh database that is the full create. Idempotent.
        # pgschema has no DSN flag — it takes libpq-style connection parameters.
        ExecStartPre = lib.mkIf cfg.applySchema [
          (pkgs.writeShellScript "buzz-relay-migrate" ''
            set -euo pipefail
            export PGHOST=${lib.escapeShellArg cfg.pgHost}
            export PGPORT=${toString cfg.pgPort}
            export PGUSER=${lib.escapeShellArg cfg.pgUser}
            export PGDATABASE=${lib.escapeShellArg cfg.database}
            ${lib.optionalString (cfg.pgPasswordFile != null) ''
              PGPASSWORD="$(cat ${lib.escapeShellArg (toString cfg.pgPasswordFile)})"
              export PGPASSWORD
            ''}

            # pgschema emits CREATE INDEX CONCURRENTLY for new indexes, which
            # Postgres rejects on partitioned tables. Pre-create the one such
            # index non-concurrently so pgschema sees it as existing and skips
            # the CONCURRENTLY path (mirrors upstream scripts/dev-setup.sh).
            ${pkgs.postgresql}/bin/psql -v ON_ERROR_STOP=0 -q -c \
              "CREATE INDEX IF NOT EXISTS idx_events_parameterized ON events (kind, pubkey, d_tag, deleted_at) WHERE d_tag IS NOT NULL;" \
              2>/dev/null || true

            # IMPORTANT: pgschema validates the desired-state schema by spinning
            # up an *embedded* PostgreSQL it downloads at runtime. That path is
            # broken on NixOS (generic dynamically-linked binaries) and needs
            # network access. Point --plan-host at the live target DB so pgschema
            # uses it for plan validation instead of the embedded server. This
            # keeps the apply fully offline and store-pure.
            ${lib.getExe cfg.pgschemaPackage} apply \
              --host "$PGHOST" \
              --port "$PGPORT" \
              --user "$PGUSER" \
              --db "$PGDATABASE" \
              --plan-host "$PGHOST" \
              --plan-port "$PGPORT" \
              --plan-user "$PGUSER" \
              --plan-db "$PGDATABASE" \
              --file ${schemaSql} \
              --auto-approve
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

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
