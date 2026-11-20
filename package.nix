{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  cmake,
  openssl,
  aws-lc,
  git,
  stdenv,
}:

# buzz-relay — the WebSocket relay binary of the Buzz communications platform
# (the crate formerly known as "sprout"). This derivation builds ONLY the
# `buzz-relay` and `buzz-admin` binaries out of the workspace.
#
# `rustPlatform` is expected to be built from the Rust 1.98 toolchain supplied
# by rust-overlay (see flake.nix). The workspace pins Rust 1.98.1 via
# rust-toolchain.toml.
#
# To bump: copy the upstream Cargo.lock at the new tag over ./Cargo.lock, set
# `version`, `rev` and the source `hash`, then update gitSourceHashes below.

let
  # cargo records every crate that comes from a git source in Cargo.lock, and
  # importCargoLock needs a hash for each one. All crates from one repository
  # come from one revision, so they share one vendor hash. The crate list is
  # read from Cargo.lock, so a bump changes only the hashes here. A new git
  # repository in Cargo.lock fails evaluation until it gets an entry.
  #
  # relay-v0.3.0 pins:
  #   * Mesh-LLM/mesh-llm at tag v0.76.2 (47 crates),
  #   * launchbadge/sqlx at rev c3735abf (7 crates, sqlx 0.9.0 pre-release),
  #   * tlongwell-block/rust-s3, a Block fork that patches `aws-creds`.
  gitSourceHashes = {
    "Mesh-LLM/mesh-llm" = "sha256-xbyNjc2oInEkmQWkGDAslCM/cNhAVjE4xcpVLFixlLE=";
    "launchbadge/sqlx" = "sha256-ylINKXS/op4is32tx1GYot9AOYw5yTzBtePyzQeKTUA=";
    "tlongwell-block/rust-s3" = "sha256-QAAm1phmeLFtDRgfDCoHijN1ce/rYzh18KziOUbL+hw=";
  };

  # "git+https://github.com/OWNER/REPO(.git)?query#rev" -> "OWNER/REPO"
  repoOf =
    source:
    lib.removeSuffix ".git" (
      lib.head (lib.splitString "?" (lib.removePrefix "git+https://github.com/" source))
    );

  gitPackages = lib.filter (p: lib.hasPrefix "git+" (p.source or "")) (
    lib.importTOML ./Cargo.lock
  ).package;
in

rustPlatform.buildRustPackage {
  pname = "buzz-relay";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    # tag relay-v0.3.0
    rev = "75d38b6c2d5f357348288ded8c15aba15f765ea5";
    hash = "sha256-low8rKfT7qSY4qswpQgEkEZ+TmhQ6IIQzgVmrPViF6g=";
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = lib.listToAttrs (
      map (p: lib.nameValuePair "${p.name}-${p.version}" gitSourceHashes.${repoOf p.source}) gitPackages
    );
  };

  # Build the relay and the admin CLI out of the workspace, and nothing else.
  #
  # buzz-admin carries the migration runner: buzz-db embeds the ordered
  # `migrations/*.sql` files at compile time via
  # `sqlx::migrate!("../../migrations")`, so `buzz-admin migrate` needs no files
  # at runtime. The NixOS module runs it in the relay's ExecStartPre. This is
  # upstream's own migration path (`just migrate` -> `buzz-admin migrate`), and
  # the only one that produces a complete schema: `schema/schema.sql` has
  # drifted from `migrations/` and is missing tables such as `git_repo_names`.
  cargoBuildFlags = [
    "-p"
    "buzz-relay"
    "--bin"
    "buzz-relay"
    "-p"
    "buzz-admin"
    "--bin"
    "buzz-admin"
  ];

  # The workspace's tests need a live Postgres/Redis and pull in the mesh-llm
  # dev-dependencies; neither is appropriate for a sandboxed package build.
  doCheck = false;

  nativeBuildInputs = [
    pkg-config
    cmake
    git
  ];

  # openssl is defensive: the relay's TLS paths use rustls, but some transitive
  # crates can still link openssl depending on feature resolution.
  #
  # aws-lc: relay-v0.3.0 pulls in aws-lc-sys (the rustls aws-lc-rs backend).
  # The build environment sets AWS_LC_SYS_USE_SYSTEM=1, so the crate links the
  # nixpkgs aws-lc instead of building its vendored copy, and the build fails
  # without it.
  buildInputs = [
    openssl
    aws-lc
  ];

  # rust-s3 / openssl-sys discovery.
  env = {
    OPENSSL_NO_VENDOR = "1";
  };

  meta = {
    description = "WebSocket relay server for the Buzz communications platform (buzz-relay)";
    homepage = "https://github.com/block/buzz";
    license = lib.licenses.asl20;
    mainProgram = "buzz-relay";
    platforms = lib.platforms.linux;
  };
}
