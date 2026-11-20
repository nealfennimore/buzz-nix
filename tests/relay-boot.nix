# nixosTest: boot buzz-relay against local postgres + redis (provisioned by the
# module), migrate the schema in ExecStartPre, then prove a NIP-01 round-trip
# over the WebSocket:
#   connect -> receive NIP-42 AUTH challenge -> send signed kind:22242 AUTH ->
#   publish a kind:1 EVENT (expect OK true) -> REQ it back (expect EVENT + EOSE).
#
# The schema assertions guard two separate ways the ExecStartPre has been wrong:
#   * pgschema converging on schema.sql every start, which left the declared
#     partitions detached and then dropped the relay's runtime-created ones,
#     deleting every stored event on restart (covered by the partition and
#     restart-survival checks);
#   * bootstrapping schema.sql, a snapshot that has drifted from migrations/ and
#     is missing git_repo_names (covered by the migration-completeness checks).
#
# Then RESTART the relay and REQ the same event again — the regression test for
# a schema step that destroys data on restart.
#
# Fully isolated; needs KVM. Run with: nix build .#checks.x86_64-linux.relay-boot
{
  pkgs,
  lib,
  buzzModule,
}:

let
  # NIP-01 / NIP-42 client: schnorr signing via coincurve, WS via websocket-client.
  pyEnv = pkgs.python3.withPackages (ps: [
    ps.coincurve
    ps.websocket-client
  ]);

  relayUrl = "ws://127.0.0.1:3000";

  nip01Client = pkgs.writeText "nip01_roundtrip.py" ''
    import hashlib, json, os, time, sys
    from coincurve import PrivateKey
    from coincurve.utils import get_valid_secret
    import websocket

    RELAY_URL = "${relayUrl}"

    # Deterministic-ish keypair for the test.
    sk = PrivateKey(hashlib.sha256(b"buzz-nix-test-key").digest())
    pk_xonly = sk.public_key_xonly.format().hex()  # 32-byte x-only pubkey hex

    def sign(sk, msg32: bytes) -> str:
        return sk.sign_schnorr(msg32).hex()

    def event_id(ev) -> str:
        ser = json.dumps(
            [0, ev["pubkey"], ev["created_at"], ev["kind"], ev["tags"], ev["content"]],
            separators=(",", ":"),
            ensure_ascii=False,
        )
        return hashlib.sha256(ser.encode()).hexdigest()

    def make_event(kind, tags, content):
        ev = {
            "pubkey": pk_xonly,
            "created_at": int(time.time()),
            "kind": kind,
            "tags": tags,
            "content": content,
        }
        ev["id"] = event_id(ev)
        ev["sig"] = sign(sk, bytes.fromhex(ev["id"]))
        return ev

    def recv_until(ws, want, timeout=20):
        ws.settimeout(timeout)
        deadline = time.time() + timeout
        while time.time() < deadline:
            raw = ws.recv()
            if not raw:
                continue
            msg = json.loads(raw)
            print("  <<", json.dumps(msg)[:200], flush=True)
            if msg[0] == want:
                return msg
        raise SystemExit(f"FAIL: timed out waiting for {want}")

    print("connecting to", RELAY_URL, "as", pk_xonly, flush=True)
    ws = websocket.create_connection(RELAY_URL, timeout=20)

    # 1) Expect the NIP-42 AUTH challenge.
    auth = recv_until(ws, "AUTH")
    challenge = auth[1]
    print("got challenge", challenge, flush=True)

    # 2) Reply with a signed kind:22242 AUTH event.
    auth_ev = make_event(
        22242,
        [["relay", RELAY_URL], ["challenge", challenge]],
        "",
    )
    ws.send(json.dumps(["AUTH", auth_ev]))
    ok = recv_until(ws, "OK")
    if not ok[2]:
        raise SystemExit(f"FAIL: AUTH rejected: {ok}")
    print("AUTH accepted", flush=True)

    if len(sys.argv) > 1 and sys.argv[1] == "verify":
        # Verify mode (post-restart): REQ a previously stored event by id and
        # expect it back. Proves stored events survive a service restart.
        want_id = sys.argv[2]
        ws.send(json.dumps(["REQ", "buzznix-verify", {"ids": [want_id]}]))
        got = recv_until(ws, "EVENT")
        if got[2]["id"] != want_id:
            raise SystemExit(f"FAIL: post-restart read-back id mismatch: {got}")
        recv_until(ws, "EOSE")
        print("RESTART SURVIVAL OK: read back", want_id, flush=True)
        ws.close()
        print("PASS", flush=True)
        raise SystemExit(0)

    # 3) Publish a kind:1 note.
    note = make_event(1, [], "hello from buzz-nix nixosTest")
    ws.send(json.dumps(["EVENT", note]))
    ok = recv_until(ws, "OK")
    if ok[1] != note["id"] or not ok[2]:
        raise SystemExit(f"FAIL: EVENT not accepted: {ok}")
    print("EVENT stored:", note["id"], flush=True)

    # 4) REQ it back by id and expect the same event, then EOSE.
    sub = "buzznix-sub"
    ws.send(json.dumps(["REQ", sub, {"ids": [note["id"]]}]))
    got = recv_until(ws, "EVENT")
    if got[2]["id"] != note["id"]:
        raise SystemExit(f"FAIL: read-back id mismatch: {got}")
    recv_until(ws, "EOSE")
    print("ROUND-TRIP OK: published and read back", note["id"], flush=True)
    ws.close()

    # Hand the event id to the test driver for the post-restart verify pass.
    with open("/tmp/buzznix-event-id", "w") as f:
        f.write(note["id"])
    print("PASS", flush=True)
  '';
in
pkgs.testers.runNixOSTest {
  name = "buzz-relay-boot";

  nodes.relay =
    { ... }:
    {
      imports = [ buzzModule ];

      services.buzz.relay = {
        enable = true;
        bindAddr = "127.0.0.1:3000";
        relayUrl = relayUrl;
        requireAuthToken = false; # open relay
        conformanceProbe = false; # no S3 — skip the fatal probe
        # provisionPostgresql + provisionRedis default true.

        # relay-v0.3.0 refuses to start without a signing key. Test-only key,
        # sha256("buzz-nix-relay-boot-identity").
        privateKeyFile = "/etc/buzz/relay-key.env";
      };

      environment.etc."buzz/relay-key.env".text = ''
        BUZZ_RELAY_PRIVATE_KEY=${builtins.hashString "sha256" "buzz-nix-relay-boot-identity"}
      '';

      # Give the VM enough memory for postgres + the relay.
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;

      environment.systemPackages = [ pyEnv ];
    };

  testScript = ''
    start_all()

    relay.wait_for_unit("postgresql.service")
    relay.wait_for_unit("redis-buzz.service")

    # The relay's ExecStartPre runs `buzz-admin migrate`, then the relay
    # binds :3000 and serves the health router on :8080.
    relay.wait_for_unit("buzz-relay.service")
    relay.wait_for_open_port(3000)

    # Health endpoint sanity.
    relay.wait_until_succeeds("${lib.getExe pkgs.curl} -fsS http://127.0.0.1:8080/_readiness", timeout=60)

    # Confirm the schema actually landed (events table exists).
    relay.succeed(
        "sudo -u buzz psql -tAc \"select to_regclass('public.events')\" | grep -q events"
    )

    # Confirm the declared partitions are ATTACHED to the parent. pgschema-based
    # bootstraps created them as detached plain tables, leaving `events` with no
    # partitions and forcing the relay to improvise its own at runtime.
    attached = relay.succeed(
        "sudo -u buzz psql -tAc \"select count(*) from pg_partition_tree('events') where isleaf\""
    ).strip()
    assert int(attached) >= 8, f"expected >= 8 attached events partitions, got {attached}"

    # `buzz-admin migrate` must have run to completion, not partially. sqlx
    # records one row per applied migration in _sqlx_migrations and marks
    # failures with success = false; a half-migrated database is the failure
    # mode that leaves the relay serving traffic against a schema it expects to
    # be complete.
    applied = relay.succeed(
        "sudo -u buzz psql -tAc \"select count(*) from _sqlx_migrations where success\""
    ).strip()
    assert int(applied) >= 28, f"expected >= 28 applied migrations, got {applied}"

    failed = relay.succeed(
        "sudo -u buzz psql -tAc \"select count(*) from _sqlx_migrations where not success\""
    ).strip()
    assert failed == "0", f"{failed} migrations recorded as failed"

    # The git smart-HTTP repo-name registry must exist. The relay holds no
    # per-repo filesystem state: it resolves every repo through git_repo_names
    # and hydrates an ephemeral bare repo from object storage per request, so a
    # missing table breaks all git reads and writes at runtime rather than at
    # boot. It comes from migrations/0002_git_repo_names.sql, which is NOT
    # reflected in schema/schema.sql — so this assertion is what distinguishes a
    # real `buzz-admin migrate` from bootstrapping that stale snapshot.
    assert relay.succeed(
        "sudo -u buzz psql -tAc \"select to_regclass('public.git_repo_names') is not null\""
    ).strip() == "t", "git_repo_names table missing after migrations"

    # Its shape matters as much as its presence: repo names are unique per
    # community, and owner_pubkey is what separates an idempotent re-announce
    # from a name collision.
    cols = relay.succeed(
        "sudo -u buzz psql -tAc \"select string_agg(column_name, ',' order by column_name) "
        "from information_schema.columns where table_name = 'git_repo_names'\""
    ).strip()
    assert cols == "community_id,created_at,owner_pubkey,repo_id", f"unexpected git_repo_names columns: {cols}"

    pk = relay.succeed(
        "sudo -u buzz psql -tAc \"select string_agg(a.attname, ',' order by a.attname) "
        "from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey) "
        "where i.indrelid = 'git_repo_names'::regclass and i.indisprimary\""
    ).strip()
    assert pk == "community_id,repo_id", f"unexpected git_repo_names primary key: {pk}"

    # ── git pre-receive hook toolchain (regression) ──────────────────────────
    # The relay writes a `#!/usr/bin/env bash` pre-receive hook into every bare
    # repo and git receive-pack runs it with this unit's environment. On NixOS
    # the unit PATH is exactly systemd.services.buzz-relay.path, with no system
    # default merged in, so a tool that is absent there is absent for the hook.
    # The hook is fail-closed. When it cannot run, every push is rejected:
    #   remote: env: 'bash': No such file or directory
    #   ! [remote rejected] main -> main (pre-receive hook declined)
    # The relay still boots, serves NIP-01 and passes every check above, so
    # nothing else in this test detects the loss.
    # `systemctl show -p Environment` prints one line, `Environment=A=1 B=2`,
    # and can quote the values. Drop the property name and the quotes, then take
    # the PATH assignment out of the remaining whitespace-separated entries.
    unit_env = relay.succeed("systemctl show buzz-relay.service -p Environment")
    unit_path = None
    for entry in unit_env.replace("Environment=", " ", 1).replace('"', " ").split():
        if entry.startswith("PATH="):
            unit_path = entry[len("PATH="):]
    assert unit_path, f"buzz-relay.service exposes no PATH: {unit_env}"

    # bash is the interpreter. The rest are the commands in the hook body.
    for tool in ["bash", "git", "curl", "openssl", "sed", "mktemp", "date", "sort", "cat", "rm"]:
        relay.succeed(
            "${pkgs.bash}/bin/bash -c 'export PATH=" + unit_path + f"; command -v {tool}'"
        )
    print("pre-receive hook toolchain present on the buzz-relay unit PATH.")

    # NIP-01 round-trip over the WebSocket.
    print(relay.succeed("${pyEnv}/bin/python ${nip01Client}"))
    event_id = relay.succeed("cat /tmp/buzznix-event-id").strip()

    # ── Restart survival (regression) ────────────────────────────────────────
    # The old pgschema ExecStartPre dropped the relay's runtime partitions
    # (CASCADE) on every restart, deleting all stored events. The migrator now
    # runs on EVERY start, so this also proves it is non-destructive and
    # idempotent rather than merely skipped.
    relay.systemctl("restart buzz-relay.service")
    relay.wait_for_unit("buzz-relay.service")
    relay.wait_for_open_port(3000)
    relay.wait_until_succeeds("${lib.getExe pkgs.curl} -fsS http://127.0.0.1:8080/_readiness", timeout=60)

    # The second migrate run must have been a no-op. Total rows are compared
    # against the successful count from before the restart; those were equal
    # then (zero failures), so any drift here means the restart either
    # re-applied a migration or recorded a new failure.
    reapplied = relay.succeed(
        "sudo -u buzz psql -tAc \"select count(*) from _sqlx_migrations\""
    ).strip()
    assert reapplied == applied, f"migration rows changed across restart: {applied} -> {reapplied}"

    # The event row must still be in Postgres...
    surviving = relay.succeed("sudo -u buzz psql -tAc \"select count(*) from events\"").strip()
    assert int(surviving) >= 1, f"events wiped by restart: count={surviving}"

    # ...and still served over the wire.
    print(relay.succeed(f"${pyEnv}/bin/python ${nip01Client} verify {event_id}"))
  '';
}
