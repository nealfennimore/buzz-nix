{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  cmake,
  openssl,
  git,
  stdenv,
}:

# buzz-relay — the WebSocket relay binary of the Buzz communications platform
# (the crate formerly known as "sprout"). This derivation builds ONLY the
# `buzz-relay` binary out of the 27-crate workspace.
#
# `rustPlatform` is expected to be built from the Rust 1.95 toolchain supplied
# by rust-overlay (see flake.nix). The workspace pins Rust 1.95.0 via
# rust-toolchain.toml; nixpkgs' default rustc (1.92 here) is too old.

let
  # The workspace pulls two crates from github.com/Mesh-LLM/mesh-llm at tag
  # v0.74.0. cargo records 39 member crates of that repo in Cargo.lock, and
  # every git+ source needs a hash here. All 39 come from one revision, so
  # they share one vendor hash.
  meshLlmVersion = "0.74.0";
  meshLlmHash = "sha256-nkt/bTHvc7ACAP2Gx/Px/hGad5ryzWn2eA9isXKF05s=";
  meshLlmCrates = [
    "mesh-llm-api-client"
    "mesh-llm-api-server"
    "mesh-llm-build-info"
    "mesh-llm-client"
    "mesh-llm-config"
    "mesh-llm-embedded-runtime"
    "mesh-llm-events"
    "mesh-llm-gpu-bench"
    "mesh-llm-guardrails"
    "mesh-llm-hardware-profile"
    "mesh-llm-host-runtime"
    "mesh-llm-identity"
    "mesh-llm-native-runtime"
    "mesh-llm-node"
    "mesh-llm-plugin"
    "mesh-llm-plugin-manager"
    "mesh-llm-protocol"
    "mesh-llm-routing"
    "mesh-llm-runtime-install"
    "mesh-llm-sdk"
    "mesh-llm-skills"
    "mesh-llm-system"
    "mesh-llm-types"
    "mesh-llm-ui"
    "mesh-mixture-of-agents"
    "model-artifact"
    "model-hf"
    "model-package"
    "model-ref"
    "model-resolver"
    "openai-frontend"
    "skippy-cache"
    "skippy-coordinator"
    "skippy-ffi"
    "skippy-metrics"
    "skippy-protocol"
    "skippy-runtime"
    "skippy-server"
    "skippy-topology"
  ];

  # relay-v0.2.1 also patches `aws-creds` to a Block fork of rust-s3
  # (github.com/tlongwell-block/rust-s3), so that git source needs its own hash.
  awsCredsHash = "sha256-QAAm1phmeLFtDRgfDCoHijN1ce/rYzh18KziOUbL+hw=";
in

rustPlatform.buildRustPackage {
  pname = "buzz-relay";
  version = "0.2.1";

  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    # tag relay-v0.2.1
    rev = "6e5c462ac524de60d7edb46c66130fd779cc9006";
    hash = "sha256-vc9vMTQzL1NCJTIYasoGq+KCu2Lbdu8Wz7scsyyoiJ8=";
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes =
      lib.genAttrs (map (crate: "${crate}-${meshLlmVersion}") meshLlmCrates) (_: meshLlmHash)
      // {
        "aws-creds-0.39.1" = awsCredsHash;
      };
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
  buildInputs = [ openssl ];

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
