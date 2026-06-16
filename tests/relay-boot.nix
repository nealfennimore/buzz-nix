# nixosTest: boot buzz-relay against local postgres + redis (provisioned by the
# module), apply the schema in ExecStartPre, then prove a NIP-01 round-trip over
# the WebSocket:
#   connect -> receive NIP-42 AUTH challenge -> send signed kind:22242 AUTH ->
#   publish a kind:1 EVENT (expect OK true) -> REQ it back (expect EVENT + EOSE).
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
        requireAuthToken = false; # open relay, dev keypair
        conformanceProbe = false; # no S3 — skip the fatal probe
        # provisionPostgresql + provisionRedis default true.
      };

      # Give the VM enough memory for postgres + the relay.
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;

      environment.systemPackages = [ pyEnv ];
    };

  testScript = ''
    start_all()

    relay.wait_for_unit("postgresql.service")
    relay.wait_for_unit("redis-buzz.service")

    # The relay's ExecStartPre applies the schema with pgschema, then the relay
    # binds :3000 and serves the health router on :8080.
    relay.wait_for_unit("buzz-relay.service")
    relay.wait_for_open_port(3000)

    # Health endpoint sanity.
    relay.wait_until_succeeds("${lib.getExe pkgs.curl} -fsS http://127.0.0.1:8080/_readiness", timeout=60)

    # Confirm the schema actually landed (events table exists).
    relay.succeed(
        "sudo -u buzz psql -tAc \"select to_regclass('public.events')\" | grep -q events"
    )

    # NIP-01 round-trip over the WebSocket.
    print(relay.succeed("${pyEnv}/bin/python ${nip01Client}"))
  '';
}
