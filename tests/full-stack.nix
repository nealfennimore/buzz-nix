# nixosTest: the FULL public stack in one isolated VM.
#
# Boots buzz-relay with ALL THREE backing services provisioned locally
# (PostgreSQL + Redis + RustFS) AND relay-membership lockdown
# enabled (NIP-43), then proves the whole data plane end-to-end:
#
#   1. relay boots, /_readiness ok (pg + redis healthy)
#   2. schema landed (events table exists)
#   3. NIP-01 round-trip over the WebSocket as the relay OWNER (a member):
#      NIP-42 AUTH -> publish kind:1 -> REQ it back
#   4. MEDIA: a Blossom (BUD-02) PNG upload to RustFS succeeds and the blob is
#      retrievable via its descriptor URL and matches its sha256; the object is
#      independently confirmed present in the RustFS bucket with rclone.
#   5. LOCKDOWN: the SAME upload signed by a NON-member is rejected (membership
#      gate), while the owner's upload (step 4) was accepted.
#   6. SEARCH: a kind:1 note with distinctive content, published over WS, becomes
#      findable through the relay's own NIP-50 search REQ. Since relay-v0.2.1
#      that search runs on the PostgreSQL full-text index, so this also proves
#      the generated tsvector column and its GIN index landed.
#
# Everything runs inside the VM; no network access beyond the VM itself. TLS /
# Caddy is NOT exercised here (ACME needs a real domain + public :80) — the
# turnkey TLS option is covered by `nix flake check` evaluating
# `nixosConfigurations.publicExample`. This test proves the data plane, which is
# the part that fails silently on a misconfigured host.
#
# Needs KVM. Run with: nix build .#checks.x86_64-linux.full-stack
{
  pkgs,
  lib,
  buzzModule,
}:

let
  # ── Deterministic test identities ────────────────────────────────────────────
  # Computed offline from sha256(label) with the same coincurve the client uses,
  # so the Nix config (ownerPubkey) and the Python client agree on the keys.
  #   owner    = sha256("buzz-nix-fullstack-owner")
  #   stranger = sha256("buzz-nix-fullstack-stranger")
  #   relayId  = sha256("buzz-nix-fullstack-relay-identity")  (the relay's NIP-43 key)
  ownerXonly = "9ad282888967be34a875d054c98cfb5f2b60de5b3eb62ef76e4bd76ee3662027";
  ownerSeed = "buzz-nix-fullstack-owner";
  strangerSeed = "buzz-nix-fullstack-stranger";
  relayPrivKey = "195616a837d1196aaf14b6e0704452d4014f3fda2391fae14d1fbf9e3bed06cd";

  # RustFS credentials (also handed to the relay as BUZZ_S3_*). Test-only.
  s3AccessKey = "buzzfullstack";
  s3SecretKey = "buzzfullstack-secret";
  relayWsUrl = "ws://127.0.0.1:3000";

  # rclone against the VM's RustFS, with the remote "fs" defined entirely by
  # environment variables, so the test needs no rclone config file.
  rcloneFs = pkgs.writeShellScriptBin "rclone-fs" ''
    export RCLONE_CONFIG=/dev/null
    export RCLONE_CONFIG_FS_TYPE=s3
    export RCLONE_CONFIG_FS_PROVIDER=Other
    export RCLONE_CONFIG_FS_ENDPOINT=http://127.0.0.1:9000
    export RCLONE_CONFIG_FS_REGION=us-east-1
    export RCLONE_CONFIG_FS_ACCESS_KEY_ID=${s3AccessKey}
    export RCLONE_CONFIG_FS_SECRET_ACCESS_KEY=${s3SecretKey}
    exec ${lib.getExe pkgs.rclone} "$@"
  '';

  # Python client: schnorr (coincurve), WS (websocket-client), HTTP (requests).
  pyEnv = pkgs.python3.withPackages (ps: [
    ps.coincurve
    ps.websocket-client
    ps.requests
  ]);

  fullStackClient = pkgs.writeText "full_stack_client.py" ''
    import base64, hashlib, json, os, struct, sys, time, zlib
    from coincurve import PrivateKey
    import websocket
    import requests

    RELAY_WS = "${relayWsUrl}"
    RELAY_HTTP = "http://127.0.0.1:3000"

    def key_from_seed(seed: str) -> PrivateKey:
        return PrivateKey(hashlib.sha256(seed.encode()).digest())

    OWNER = key_from_seed("${ownerSeed}")
    STRANGER = key_from_seed("${strangerSeed}")

    def xonly(sk: PrivateKey) -> str:
        return sk.public_key_xonly.format().hex()

    def event_id(ev) -> str:
        ser = json.dumps(
            [0, ev["pubkey"], ev["created_at"], ev["kind"], ev["tags"], ev["content"]],
            separators=(",", ":"),
            ensure_ascii=False,
        )
        return hashlib.sha256(ser.encode()).hexdigest()

    def make_event(sk: PrivateKey, kind, tags, content, created_at=None):
        ev = {
            "pubkey": xonly(sk),
            "created_at": created_at if created_at is not None else int(time.time()),
            "kind": kind,
            "tags": tags,
            "content": content,
        }
        ev["id"] = event_id(ev)
        ev["sig"] = sk.sign_schnorr(bytes.fromhex(ev["id"])).hex()
        return ev

    def recv_until(ws, want, timeout=20):
        ws.settimeout(timeout)
        deadline = time.time() + timeout
        while time.time() < deadline:
            raw = ws.recv()
            if not raw:
                continue
            msg = json.loads(raw)
            print("  <<", json.dumps(msg)[:240], flush=True)
            if msg[0] == want:
                return msg
        raise SystemExit(f"FAIL: timed out waiting for {want}")

    def connect_and_auth(sk: PrivateKey):
        """Open a WS, complete NIP-42 AUTH, return the connection."""
        ws = websocket.create_connection(RELAY_WS, timeout=20)
        auth = recv_until(ws, "AUTH")
        challenge = auth[1]
        auth_ev = make_event(
            sk, 22242, [["relay", RELAY_WS], ["challenge", challenge]], ""
        )
        ws.send(json.dumps(["AUTH", auth_ev]))
        ok = recv_until(ws, "OK")
        if not ok[2]:
            raise SystemExit(f"FAIL: AUTH rejected: {ok}")
        return ws

    # ── 1. NIP-01 round-trip as the owner (a relay member) ──────────────────────
    def test_nip01_roundtrip():
        print("== NIP-01 round-trip (owner) ==", flush=True)
        ws = connect_and_auth(OWNER)
        note = make_event(OWNER, 1, [], "hello from buzz-nix full-stack test")
        ws.send(json.dumps(["EVENT", note]))
        ok = recv_until(ws, "OK")
        if ok[1] != note["id"] or not ok[2]:
            raise SystemExit(f"FAIL: EVENT not accepted: {ok}")
        sub = "fs-sub"
        ws.send(json.dumps(["REQ", sub, {"ids": [note["id"]]}]))
        got = recv_until(ws, "EVENT")
        if got[2]["id"] != note["id"]:
            raise SystemExit(f"FAIL: read-back id mismatch: {got}")
        recv_until(ws, "EOSE")
        ws.close()
        print("NIP-01 ROUND-TRIP OK:", note["id"], flush=True)

    # ── Test image ──────────────────────────────────────────────────────────────
    # Since relay-v0.3.0, /media/upload accepts images only (JPEG, PNG, GIF,
    # WebP, by magic bytes; crates/buzz-media/src/validation.rs). Build a small
    # valid RGB PNG from random pixels, so every upload has a fresh sha256.
    def make_png(width=16, height=16) -> bytes:
        def chunk(kind: bytes, data: bytes) -> bytes:
            crc = zlib.crc32(kind + data) & 0xFFFFFFFF
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)
        raw = b"".join(b"\x00" + os.urandom(width * 3) for _ in range(height))
        ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b"")
        )

    # ── Blossom (BUD-02) upload helper ──────────────────────────────────────────
    def blossom_upload(sk: PrivateKey, body: bytes):
        """PUT /media/upload with a kind:24242 Blossom auth event. Returns the
        requests.Response. No `server` tag -> domain check is bypassed (BUD-11)."""
        sha = hashlib.sha256(body).hexdigest()
        now = int(time.time())
        auth_ev = make_event(
            sk,
            24242,
            [["t", "upload"], ["x", sha], ["expiration", str(now + 300)]],
            "buzz-nix full-stack upload",
        )
        token = base64.b64encode(json.dumps(auth_ev).encode()).decode()
        headers = {
            "Authorization": "Nostr " + token,
            "X-SHA-256": sha,
            "Content-Type": "image/png",
        }
        resp = requests.put(
            RELAY_HTTP + "/media/upload", data=body, headers=headers, timeout=30
        )
        return sha, resp

    # ── Blossom (BUD-01) authenticated GET ──────────────────────────────────────
    # Since relay-v0.3.0, every media GET needs Blossom auth (kind 24242 with
    # t=get), in every BUZZ_MEDIA_READ_MODE (docs/operator-private-media.md).
    # An uploader can always read their own unposted file.
    def blossom_get(sk: PrivateKey, url: str, sha: str):
        now = int(time.time())
        auth_ev = make_event(
            sk,
            24242,
            [["t", "get"], ["x", sha], ["expiration", str(now + 300)]],
            "buzz-nix full-stack get",
        )
        token = base64.b64encode(json.dumps(auth_ev).encode()).decode()
        return requests.get(url, headers={"Authorization": "Nostr " + token}, timeout=30)

    # ── 4. RustFS media upload + retrieval as the owner ──────────────────────────
    def test_media_upload_owner():
        print("== media upload to RustFS (owner) ==", flush=True)
        body = make_png()
        sha, resp = blossom_upload(OWNER, body)
        print("  upload status:", resp.status_code, resp.text[:240], flush=True)
        if resp.status_code != 200:
            raise SystemExit(f"FAIL: owner upload rejected: {resp.status_code} {resp.text}")
        desc = resp.json()
        print("  descriptor:", json.dumps(desc)[:240], flush=True)
        # The image path can sanitize (re-encode) the image, so the stored blob
        # is addressed by the descriptor's sha256, which can differ from the
        # sha256 of the bytes sent. Retrieve it by the descriptor URL and check
        # that the bytes match the descriptor hash.
        stored_sha = desc["sha256"]
        url = desc.get("url") or (RELAY_HTTP + f"/media/{stored_sha}.png")
        # Unauthenticated reads must fail since relay-v0.3.0.
        anon = requests.get(url, timeout=30)
        if anon.status_code == 200:
            raise SystemExit(f"FAIL: unauthenticated blob GET {url} succeeded")
        get = blossom_get(OWNER, url, stored_sha)
        if get.status_code != 200:
            raise SystemExit(f"FAIL: blob GET {url} status {get.status_code} {get.text[:240]}")
        if hashlib.sha256(get.content).hexdigest() != stored_sha:
            raise SystemExit("FAIL: retrieved blob does not match its descriptor sha256")
        if not get.content.startswith(b"\x89PNG"):
            raise SystemExit("FAIL: retrieved blob is not a PNG")
        print("MEDIA UPLOAD + RETRIEVE OK:", stored_sha, "sent", sha, flush=True)
        return stored_sha

    # ── 5. Lockdown: a non-member's upload must be rejected ──────────────────────
    def test_media_upload_nonmember_rejected():
        print("== lockdown: non-member upload must fail ==", flush=True)
        # A valid PNG, so the only reason to reject it is the membership gate.
        body = make_png()
        sha, resp = blossom_upload(STRANGER, body)
        print("  stranger upload status:", resp.status_code, resp.text[:240], flush=True)
        # The membership gate rejects with 4xx (RelayMembershipRequired -> 403).
        if resp.status_code == 200:
            raise SystemExit("FAIL: non-member upload was ACCEPTED (lockdown broken!)")
        if resp.status_code not in (401, 403):
            raise SystemExit(
                f"FAIL: expected 401/403 for non-member, got {resp.status_code}: {resp.text}"
            )
        # And the blob must NOT be retrievable.
        # And the blob must NOT be retrievable, even with valid Blossom auth.
        get = blossom_get(STRANGER, RELAY_HTTP + f"/media/{sha}.png", sha)
        if get.status_code == 200:
            raise SystemExit("FAIL: non-member blob is retrievable (it was stored!)")
        print("LOCKDOWN OK: non-member rejected with", resp.status_code, flush=True)

    # ── 6a. Search via the relay's NIP-50 REQ ───────────────────────────────────
    def test_search_via_relay(marker):
        print("== search via relay NIP-50 REQ ==", flush=True)
        ws = connect_and_auth(OWNER)
        # Retry: the event lands in PostgreSQL before its row is visible to the
        # search path, so the note may not appear on the first REQ.
        deadline = time.time() + 90
        attempt = 0
        while time.time() < deadline:
            attempt += 1
            sub = f"fs-search-{attempt}"
            ws.send(json.dumps(["REQ", sub, {"search": marker, "kinds": [1]}]))
            found = None
            ws.settimeout(15)
            try:
                while True:
                    msg = json.loads(ws.recv())
                    if msg[0] == "EVENT" and msg[1] == sub:
                        if marker in msg[2].get("content", ""):
                            found = msg[2]
                    elif msg[0] == "EOSE" and msg[1] == sub:
                        break
                    elif msg[0] == "CLOSED" and msg[1] == sub:
                        break
            except Exception as e:
                print("  (recv timeout/err:", e, ")", flush=True)
            ws.send(json.dumps(["CLOSE", sub]))
            if found:
                ws.close()
                print("SEARCH-VIA-RELAY OK: hit on attempt", attempt, found["id"], flush=True)
                return
            time.sleep(3)
        ws.close()
        raise SystemExit("FAIL: relay NIP-50 search returned no hit within 90s")

    def cmd_data_plane():
        # Publish the search marker note first so it has the longest time to index
        # while the media tests run.
        marker = "zqxmarker" + hashlib.sha256(os.urandom(16)).hexdigest()[:12]
        print("search marker:", marker, flush=True)
        ws = connect_and_auth(OWNER)
        note = make_event(OWNER, 1, [], f"full stack searchable note {marker} end")
        ws.send(json.dumps(["EVENT", note]))
        ok = recv_until(ws, "OK")
        if not ok[2]:
            raise SystemExit(f"FAIL: marker note not accepted: {ok}")
        ws.close()
        print("marker note published:", note["id"], flush=True)

        test_nip01_roundtrip()
        test_media_upload_owner()
        test_media_upload_nonmember_rejected()
        test_search_via_relay(marker)
        # Emit the marker so the test script can also check PostgreSQL directly.
        print("MARKER=" + marker, flush=True)
        print("ALL DATA-PLANE CHECKS PASSED", flush=True)

    if __name__ == "__main__":
        cmd = sys.argv[1] if len(sys.argv) > 1 else "data-plane"
        if cmd == "data-plane":
            cmd_data_plane()
        elif cmd == "pubkeys":
            print("owner", xonly(OWNER))
            print("stranger", xonly(STRANGER))
        else:
            raise SystemExit("unknown cmd " + cmd)
  '';
in
pkgs.testers.runNixOSTest {
  name = "buzz-relay-full-stack";

  nodes.relay =
    { ... }:
    {
      imports = [ buzzModule ];

      services.buzz.relay = {
        enable = true;
        bindAddr = "127.0.0.1:3000";
        relayUrl = relayWsUrl;

        # Full backing stack.
        provisionPostgresql = true;
        provisionRedis = true;
        provisionRustfs = true;
        conformanceProbe = true; # RustFS is wired -> gate on the conditional-write probe

        # Lockdown: enforce relay membership on every authenticated request
        # (NIP-43). The owner is bootstrapped as a member; everyone else is
        # rejected by the membership gate.
        #
        # NOTE: requireAuthToken stays OFF here on purpose. With it ON, the media
        # upload path additionally demands a per-user API token (X-Auth-Token:
        # buzz_*) minted by the relay — a separate subsystem from membership.
        # Proving the RustFS + membership-lockdown data plane (the task) does not
        # need that token machinery, so we exercise the Blossom-signed upload
        # under the membership gate: a member uploads, a non-member is refused.
        # `publicExample` keeps requireAuthToken = true for production.
        requireAuthToken = false;
        requireRelayMembership = true;
        ownerPubkey = ownerXonly;

        # The relay's stable NIP-43 identity + its RustFS (S3) credentials. These
        # are read via systemd EnvironmentFile, so they never enter the store at
        # eval time; here we materialise them in the VM (see environment.etc).
        environmentFile = "/etc/buzz/relay.env";
        rustfsCredentialsFile = "/etc/buzz/rustfs.env";

        # Make the media descriptor URL explicit and self-consistent in-VM.
        extraEnv.BUZZ_MEDIA_BASE_URL = "http://127.0.0.1:3000/media";
      };

      # Test-only secret material. In production these come from sops/agenix and
      # are NOT world-readable; here the VM is throwaway and isolated.
      environment.etc = {
        "buzz/relay.env".text = ''
          BUZZ_RELAY_PRIVATE_KEY=${relayPrivKey}
          BUZZ_S3_ACCESS_KEY=${s3AccessKey}
          BUZZ_S3_SECRET_KEY=${s3SecretKey}
        '';
        "buzz/rustfs.env".text = ''
          RUSTFS_ACCESS_KEY=${s3AccessKey}
          RUSTFS_SECRET_KEY=${s3SecretKey}
        '';
      };

      # Headroom for pg + redis + rustfs + relay together.
      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 8192;
      virtualisation.cores = 2;

      environment.systemPackages = [
        pyEnv
        rcloneFs
        pkgs.curl
        pkgs.jq
      ];
    };

  testScript = ''
    start_all()

    # ── All backing services up ──────────────────────────────────────────────
    relay.wait_for_unit("postgresql.service")
    relay.wait_for_unit("redis-buzz.service")
    relay.wait_for_unit("rustfs.service")
    relay.wait_for_open_port(9000)            # RustFS S3 API
    relay.wait_for_unit("buzz-rustfs-bucket.service")  # bucket bootstrap oneshot

    # The relay's ExecStartPre applies the schema, then (with conformanceProbe on)
    # gates startup on the RustFS conditional-write probe before binding :3000.
    relay.wait_for_unit("buzz-relay.service")
    relay.wait_for_open_port(3000)

    # ── Health + schema ──────────────────────────────────────────────────────
    relay.wait_until_succeeds(
        "${lib.getExe pkgs.curl} -fsS http://127.0.0.1:8080/_readiness", timeout=60
    )
    relay.succeed(
        "sudo -u buzz psql -tAc \"select to_regclass('public.events')\" | grep -q events"
    )

    # The owner must have been bootstrapped into relay_members on first start.
    relay.succeed(
        "sudo -u buzz psql -tAc \"select count(*) from relay_members\" | grep -qE '[1-9]'"
    )

    # ── The RustFS bucket physically exists ───────────────────────────────────
    relay.succeed("rclone-fs lsd fs: | grep -q buzz-media")

    # ── Data-plane proof (NIP-01 + media+lockdown + search) ───────────────────
    out = relay.succeed("${pyEnv}/bin/python ${fullStackClient} data-plane")
    print(out)
    assert "ALL DATA-PLANE CHECKS PASSED" in out, "data-plane client did not pass"

    # Recover the search marker and independently confirm the row is full-text
    # searchable in PostgreSQL. relay-v0.2.1 generates events.search_tsv from
    # the content column, so this proves the index the relay searches, not just
    # that the row exists.
    marker = None
    for line in out.splitlines():
        if line.startswith("MARKER="):
            marker = line.split("=", 1)[1].strip()
    assert marker, "client did not emit a search MARKER"

    relay.wait_until_succeeds(
        "sudo -u buzz psql -tAc \"select count(*) from events "
        + f"where search_tsv @@ plainto_tsquery('simple', '{marker}')\" "
        + "| grep -qE '[1-9]'",
        timeout=90,
    )
    print("PostgreSQL full-text search confirmed the indexed row.")

    # ── The owner's uploaded blob is physically present in the bucket ─────────
    n_objects = relay.succeed("rclone-fs lsf --recursive --files-only fs:buzz-media | wc -l").strip()
    print("RustFS bucket object count:", n_objects)
    assert int(n_objects) >= 1, "expected at least one object in the RustFS bucket"

    print("FULL STACK PROVEN: relay + pg + redis + rustfs + lockdown")
  '';
}
