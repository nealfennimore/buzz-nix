{
  description = "Portable Nix flake for the Buzz relay (buzz-relay) — package + NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      flake-utils,
    }:
    let
      lib = nixpkgs.lib;

      # The relay is Linux-only (systemd module + Linux-only platforms).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # rustPlatform built from the repo-pinned Rust 1.98 toolchain. nixpkgs'
      # default rustc is too old (1.92 at time of writing); rust-overlay supplies
      # 1.98 reproducibly.
      mkRustPlatform =
        pkgs:
        let
          toolchain = pkgs.rust-bin.stable."1.98.1".default;
        in
        pkgs.makeRustPlatform {
          cargo = toolchain;
          rustc = toolchain;
        };

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

      mkBuzzRelay =
        system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.callPackage ./package.nix {
          rustPlatform = mkRustPlatform pkgs;
        };

      perSystem = flake-utils.lib.eachSystem systems (
        system:
        let
          pkgs = mkPkgs system;
          buzz-relay = mkBuzzRelay system;
        in
        {
          packages = {
            inherit buzz-relay;
            default = buzz-relay;
          };

          # `nix build .#checks.<system>.relay-boot` runs a fully isolated VM
          # test that boots the relay against local postgres+redis and asserts a
          # NIP-01 round-trip over the WebSocket. Requires KVM; x86_64-linux only.
          checks = lib.optionalAttrs (system == "x86_64-linux") {
            relay-boot = import ./tests/relay-boot.nix {
              inherit pkgs lib;
              buzzModule = self.nixosModules.default;
            };

            # `nix build .#checks.<system>.full-stack` boots the relay with ALL
            # three backing services (Postgres + Redis + RustFS) plus
            # membership lockdown in one VM and proves the whole data plane:
            # NIP-01 round-trip, a RustFS media upload+retrieve, a non-member
            # upload rejection, and PostgreSQL full-text search. Heavier than relay-boot.
            full-stack = import ./tests/full-stack.nix {
              inherit pkgs lib;
              buzzModule = self.nixosModules.default;
            };
          };

          devShells.default = pkgs.mkShell {
            packages = [
              (pkgs.rust-bin.stable."1.98.1".default)
              pkgs.pkg-config
              pkgs.cmake
              pkgs.openssl
              pkgs.git
            ];
          };
        }
      );
    in
    perSystem
    // {
      # The NixOS module. Import into a host config and set
      # `services.buzz.relay.enable = true`. Its default package resolves to the
      # buzz-relay built by THIS flake for the evaluating host's system, so a bare
      # `imports = [ buzz-nix.nixosModules.default ]` works with no extra wiring.
      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [
            (import ./module.nix {
              buzzPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.buzz-relay;
            })
          ];
        };

      # A complete, VM-testable example host demonstrating a working deployment.
      nixosConfigurations.example = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          (
            { ... }:
            {
              services.buzz.relay = {
                enable = true;
                relayUrl = "wss://relay.example.com";
                bindAddr = "0.0.0.0:3000";
                openFirewall = true;
                # provisionPostgresql / provisionRedis default to true.

                # Required since relay-v0.3.0. The file holds one line,
                # BUZZ_RELAY_PRIVATE_KEY=<openssl rand -hex 32>. Supply it on
                # the host (sops-nix / agenix); it never enters the store.
                privateKeyFile = "/run/secrets/buzz-relay-key.env";
              };

              # Minimal bits to make this a bootable example.
              boot.loader.grub.devices = [ "/dev/sda" ];
              fileSystems."/" = {
                device = "/dev/sda1";
                fsType = "ext4";
              };
              system.stateVersion = "24.11";
            }
          )
        ];
      };

      # The full-stack, public-host reference for an AWS (or any cloud) deploy.
      # Turns EVERYTHING on: local Postgres + Redis + RustFS, a
      # TLS-terminating Caddy in front on 80/443 with a Let's Encrypt cert for
      # the domain, and the relay locked down to relay members (NIP-43).
      #
      # Before deploying, replace the placeholder paths under /run/secrets with
      # real secret files (sops-nix / agenix / cloud-init), set ownerPubkey to
      # your 64-char hex pubkey, point DNS for the domain at the host, and adjust
      # the disk/filesystem stanza to the actual instance. See the README's
      # "Full public stack (AWS reference)" section for the secret file contents.
      nixosConfigurations.publicExample = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          (
            { ... }:
            {
              services.buzz.relay = {
                enable = true;

                # Public identity: the wss:// host clients connect to and that
                # NIP-42 AUTH is bound to. Must match tls.domain.
                relayUrl = "wss://relay.example.com";
                bindAddr = "127.0.0.1:3000"; # only the proxy talks to the relay
                openFirewall = false; # the proxy (80/443) is the only public surface

                # Turnkey TLS: Caddy on 80/443, automatic Let's Encrypt cert.
                tls = {
                  enable = true;
                  domain = "relay.example.com";
                  acmeEmail = "admin@example.com";
                };

                # Full backing stack, all provisioned locally on this host.
                provisionPostgresql = true;
                provisionRedis = true;
                provisionRustfs = true;
                # Object store is wired up, so gate startup on the conditional-write
                # (If-None-Match / If-Match) probe to fail fast if S3 is misconfigured.
                conformanceProbe = true;

                # Lockdown: only relay members may publish/upload (NIP-43).
                requireAuthToken = true;
                requireRelayMembership = true;
                ownerPubkey = "0000000000000000000000000000000000000000000000000000000000000000"; # REPLACE: your 64-char hex pubkey

                # Secrets — never enter the Nix store; supply real files on the host.
                #   buzz-relay.env  : BUZZ_RELAY_PRIVATE_KEY=<64-hex>
                #                     BUZZ_S3_ACCESS_KEY=<rustfs access key>
                #                     BUZZ_S3_SECRET_KEY=<rustfs secret key>
                #                     (optionally BUZZ_GIT_HOOK_HMAC_SECRET=<>=32 chars>)
                #   buzz-rustfs.env : RUSTFS_ACCESS_KEY=<== BUZZ_S3_ACCESS_KEY>
                #                     RUSTFS_SECRET_KEY=<== BUZZ_S3_SECRET_KEY>
                environmentFile = "/run/secrets/buzz-relay.env";
                rustfsCredentialsFile = "/run/secrets/buzz-rustfs.env";
              };

              # Bootable example skeleton — replace for the real instance (an AWS
              # AMI typically uses nixos-generators / the amazonImage profile).
              boot.loader.grub.devices = [ "/dev/sda" ];
              fileSystems."/" = {
                device = "/dev/sda1";
                fsType = "ext4";
              };
              system.stateVersion = "24.11";
            }
          )
        ];
      };
    };
}
