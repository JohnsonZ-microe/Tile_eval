#!/usr/bin/env python3
"""tile-logs-sync receiver (Windows side).

Listens for tarballs pushed by the ECE VDI and unpacks each one into
D:\\Documents\\ChatGPT\\LNS_DSE\\Tile_eval\\logs\\<tag>\\.

Guarantees:
  * only accepts POST /push/<tag>.tgz with the shared X-Sync-Token header
  * <tag> must match ^[A-Za-z0-9][A-Za-z0-9._-]*$
  * every tar member must live under <tag>/ (no absolute paths, no "..")
  * extraction goes to a staging dir first; the live dir is replaced only
    after the whole archive verified, so a torn transfer never corrupts logs
  * identical content is skipped (HTTP 409), so re-pushing is harmless
  * nothing is ever executed

Usage:
  python receiver.py [--port 8000] [--dest <dir>] [--config <file>]
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DEST = r"D:\Documents\ChatGPT\LNS_DSE\Tile_eval\logs"
# keep the shared secret out of the git working tree
_CONFIG_HOME = os.environ.get("LOCALAPPDATA") or HERE
DEFAULT_CONFIG = os.path.join(_CONFIG_HOME, "tile-logs-sync", "sync_config.json")
SCRIPT_NAME = "vdi_push_logs.sh"
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")
MAX_BYTES = 512 * 1024 * 1024
LOCK = threading.Lock()

CFG = {"token": "", "dest": DEFAULT_DEST, "port": 8000}


def load_config(path):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        CFG.update({k: data[k] for k in ("token", "dest", "port") if k in data})
    else:
        CFG["token"] = hashlib.sha256(os.urandom(32)).hexdigest()[:24]
        save_config(path)
        print("created %s with a fresh token" % path, flush=True)


def save_config(path):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(CFG, fh, indent=1)


def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def validate_members(tf, tag):
    """Return list of members after checking every path stays under tag/."""
    members = tf.getmembers()
    if not members:
        raise ValueError("empty archive")
    for m in members:
        name = m.name.replace("\\", "/")
        if name.startswith("/") or name.startswith("../") or "/../" in name:
            raise ValueError("unsafe path: %r" % m.name)
        parts = [p for p in name.split("/") if p not in ("", ".")]
        if not parts or parts[0] != tag:
            raise ValueError("member outside %s/: %r" % (tag, m.name))
        if m.issym() or m.islnk():
            raise ValueError("links are not allowed: %r" % m.name)
    return members


def install(tar_bytes, tag):
    """Verify + extract into DEST/<tag>. Returns (status, detail)."""
    dest_root = CFG["dest"]
    target = os.path.join(dest_root, tag)
    os.makedirs(dest_root, exist_ok=True)

    digest = sha256_bytes(tar_bytes)
    staging = tempfile.mkdtemp(prefix=".staging-%s-" % tag, dir=dest_root)
    try:
        with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz") as tf:
            members = validate_members(tf, tag)
            if hasattr(tarfile, "data_filter"):
                tf.extractall(staging, members=members, filter="data")
            else:  # pragma: no cover - older python
                tf.extractall(staging, members=members)
        extracted = os.path.join(staging, tag)
        if not os.path.isdir(extracted):
            raise ValueError("archive root %s/ missing after extract" % tag)

        files = {}
        for root, _dirs, names in os.walk(extracted):
            for n in names:
                full = os.path.join(root, n)
                rel = os.path.relpath(full, extracted).replace("\\", "/")
                files[rel] = os.path.getsize(full)

        record = {"tag": tag, "sha256": digest, "pushed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                  "files": files, "bytes": len(tar_bytes)}
        with open(os.path.join(extracted, ".sync.json"), "w", encoding="utf-8") as fh:
            json.dump(record, fh, indent=1)

        prev = os.path.join(target, ".sync.json")
        if os.path.exists(prev):
            try:
                with open(prev, "r", encoding="utf-8") as fh:
                    if json.load(fh).get("sha256") == digest:
                        shutil.rmtree(staging, ignore_errors=True)
                        return 409, "identical content already present"
            except Exception:
                pass

        # Merge, do not replace: the local logs dir may hold extra files
        # (manifest.json, checks.json, ...) produced by the local pipeline.
        with LOCK:
            added = overwritten = 0
            for root, _dirs, names in os.walk(extracted):
                for n in names:
                    src = os.path.join(root, n)
                    rel = os.path.relpath(src, extracted)
                    dst = os.path.join(target, rel)
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    if os.path.exists(dst):
                        overwritten += 1
                    else:
                        added += 1
                    shutil.copy2(src, dst)
        shutil.rmtree(staging, ignore_errors=True)
        return 200, "merged %d files (%d new, %d overwritten, %d bytes)" % (
            len(files) + 1, added, overwritten, len(tar_bytes))
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


class Handler(BaseHTTPRequestHandler):
    server_version = "TileLogsSync/1.0"
    protocol_version = "HTTP/1.1"

    def _send(self, code, text):
        body = text.encode("utf-8", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/ping"):
            return self._send(200, "TileLogsSync alive; dest=%s\n" % CFG["dest"])
        if path in ("/" + SCRIPT_NAME, "/script"):
            script = os.path.join(HERE, SCRIPT_NAME)
            if not os.path.exists(script):
                return self._send(404, "script not bundled\n")
            with open(script, "r", encoding="utf-8") as fh:
                text = fh.read()
            # hand out a copy that already knows the endpoint and token
            text = text.replace("PUSH_TOKEN=${PUSH_TOKEN:-}",
                                "PUSH_TOKEN=%s" % CFG["token"])
            body = text.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/x-shellscript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            log("GET %s from %s" % (path, self.client_address[0]))
            return None
        return self._send(404, "not found\n")

    def do_POST(self):
        path = self.path.split("?")[0]
        m = re.match(r"^/push/([^/]+)\.tgz$", path)
        if not m:
            return self._send(404, "expected POST /push/<tag>.tgz\n")
        tag = m.group(1)
        if not TAG_RE.match(tag):
            return self._send(400, "bad tag\n")
        token = (self.headers.get("X-Sync-Token") or "").strip()
        if not CFG["token"] or token != CFG["token"]:
            log("REJECT bad token from %s" % self.client_address[0])
            return self._send(401, "bad token\n")

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return self._send(400, "empty body\n")
        if length > MAX_BYTES:
            return self._send(413, "too large\n")

        chunks, got = [], 0
        while got < length:
            buf = self.rfile.read(min(65536, length - got))
            if not buf:
                break
            chunks.append(buf)
            got += len(buf)
        if got != length:
            return self._send(400, "short read %d/%d\n" % (got, length))

        try:
            code, detail = install(b"".join(chunks), tag)
        except Exception as exc:
            log("FAIL %s from %s: %s" % (tag, self.client_address[0], exc))
            return self._send(422, "rejected: %s\n" % exc)
        log("%s %s from %s: %s" % ("OK" if code == 200 else "SKIP", tag,
                                   self.client_address[0], detail))
        return self._send(code, detail + "\n")

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--dest", default=None)
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    args = ap.parse_args()

    load_config(args.config)
    if args.dest:
        CFG["dest"] = args.dest
    if args.port:
        CFG["port"] = args.port
    save_config(args.config)

    os.makedirs(CFG["dest"], exist_ok=True)
    log("dest     : %s" % CFG["dest"])
    log("port     : %d" % CFG["port"])
    log("token    : %s" % CFG["token"])
    log("bootstrap: curl -fsS http://<this-host>:%d/%s -o ~/%s"
        % (CFG["port"], SCRIPT_NAME, SCRIPT_NAME))
    ThreadingHTTPServer(("0.0.0.0", CFG["port"]), Handler).serve_forever()


if __name__ == "__main__":
    main()
