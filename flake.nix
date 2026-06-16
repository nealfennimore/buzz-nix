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

      # rustPlatform built from the repo-pinned Rust 1.95 toolchain. nixpkgs'
      # default rustc is too old (1.92 at time of writing); rust-overlay supplies
      # 1.95 reproducibly.
      mkRustPlatform =
        pkgs:
        let
          toolchain = pkgs.rust-bin.stable."1.95.0".default;
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
          };

          devShells.default = pkgs.mkShell {
            packages = [
              (pkgs.rust-bin.stable."1.95.0".default)
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
    };
}
