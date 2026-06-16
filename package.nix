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
# `buzz-relay` binary out of the 24-crate workspace.
#
# `rustPlatform` is expected to be built from the Rust 1.95 toolchain supplied
# by rust-overlay (see flake.nix). The workspace pins Rust 1.95.0 via
# rust-toolchain.toml; nixpkgs' default rustc (1.92 here) is too old.

rustPlatform.buildRustPackage {
  pname = "buzz-relay";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    rev = "cbc754cffb0e14c25b380de6c2d5f8d62c14a183";
    hash = "sha256-nTmTVcxhN3rXg9ZNF1us24+Fy0gGYTgQX0nHizy6XXk=";
  };

  # The workspace depends on two crates from a pinned git rev of
  # github.com/Mesh-LLM/mesh-llm. cargo records ~38 member crates from that
  # repo in Cargo.lock; every git+ source must be hashed here. All entries
  # share the same revision, hence the same vendor hash.
  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "mesh-llm-api-client-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-api-server-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-client-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-config-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-embedded-runtime-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-events-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-gpu-bench-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-guardrails-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-hardware-profile-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-host-runtime-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-identity-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-native-runtime-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-node-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-plugin-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-plugin-manager-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-protocol-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-routing-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-runtime-install-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-sdk-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-skills-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-system-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-types-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-llm-ui-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "mesh-mixture-of-agents-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "model-artifact-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "model-hf-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "model-package-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "model-ref-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "model-resolver-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "openai-frontend-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "skippy-cache-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "skippy-coordinator-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "skippy-ffi-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "skippy-metrics-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "skippy-protocol-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "skippy-runtime-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "skippy-server-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
      "skippy-topology-0.68.0" = "sha256-dOVqWs3hrLaAvoFJ+21L1G+Zkp6LELHtP2bJ4tgkc9U=";
    };
  };

  # Build only the relay binary out of the workspace.
  cargoBuildFlags = [
    "-p"
    "buzz-relay"
    "--bin"
    "buzz-relay"
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
