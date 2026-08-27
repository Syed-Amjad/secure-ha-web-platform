#!/usr/bin/env python3
"""
Minimal demonstration application for the HA web platform.

Shipped as a static file rather than a Jinja template on purpose: the inline CSS
uses braces, which collide with Jinja's {{ }} delimiters. Anything configurable
arrives through the environment file instead, which is the right place for it.

Deliberately stdlib-only apart from PyMySQL (installed from apt), so there is no
pip, no virtualenv and no build step on the node. It exists to prove the tiering
works end to end, not to be a real product:

  GET /         node identity + a live query against the database tier
  GET /db       raw JSON — the read path from the app tier to MySQL
  GET /write    the write path — succeeds on the primary, FAILS on the replica
  GET /login    rate-limit target; nginx returns 429 before this is reached
  GET /healthz  answered by nginx directly and never reaches this process
"""

import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pymysql

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_NAME = os.environ.get("DB_NAME", "appdb")
DB_USER = os.environ.get("DB_USER", "appuser")
DB_PASS = os.environ.get("DB_PASS", "")
PORT = int(os.environ.get("APP_PORT", "3000"))

HOSTNAME = socket.gethostname()


# The database sets require_secure_transport = ON, so every TCP connection must
# negotiate TLS. Passing a non-empty ssl dict switches PyMySQL to TLS.
#
# Honest limitation: with no CA supplied, this ENCRYPTS the connection but does
# not AUTHENTICATE the server — it accepts MySQL's auto-generated self-signed
# certificate. That is fine inside a private subnet reachable only from the web
# security group. In production you would distribute /var/lib/mysql/ca.pem and
# pass ssl={"ca": "/etc/ssl/mysql-ca.pem"} so the client verifies who it is
# talking to.
SSL_OPTS = {"check_hostname": False}


def _connect():
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        connect_timeout=3,
        read_timeout=3,
        ssl=SSL_OPTS,
    )


def db_status():
    """Read path. Never raises — an unreachable database must surface as a
    visible error string, not a 500 that hides which tier actually broke."""
    try:
        conn = _connect()
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM visits")
            count = cur.fetchone()[0]
            cur.execute(
                "SELECT @@hostname, @@server_id, @@read_only, @@super_read_only"
            )
            host, server_id, ro, sro = cur.fetchone()
        conn.close()
        return {
            "reachable": True,
            "rows_in_visits": count,
            "mysql_hostname": host,
            "server_id": server_id,
            "read_only": bool(ro),
            "super_read_only": bool(sro),
        }
    except Exception as exc:  # noqa: BLE001 - surface the real cause
        return {"reachable": False, "error": "%s: %s" % (type(exc).__name__, exc)}


def record_visit():
    """Write path. Succeeds against the primary; against the replica it returns
    ERROR 1290 (--super-read-only), which is exactly the screenshot the guide
    asks for in section 10."""
    try:
        conn = _connect()
        with conn.cursor() as cur:
            cur.execute("INSERT INTO visits (node) VALUES (%s)", (HOSTNAME,))
        conn.commit()
        conn.close()
        return {"written": True}
    except Exception as exc:  # noqa: BLE001
        return {"written": False, "error": "%s: %s" % (type(exc).__name__, exc)}


PAGE = """<!doctype html>
<meta charset="utf-8"><title>HA Web Platform</title>
<style>
 body{font:16px/1.6 system-ui,-apple-system,sans-serif;max-width:44rem;
      margin:4rem auto;padding:0 1rem;color:#18181b}
 code,pre{background:#f4f4f5;padding:.15em .4em;border-radius:3px}
 pre{padding:1rem;overflow-x:auto}
 .ok{color:#15803d;font-weight:600}
 .bad{color:#b91c1c;font-weight:600}
 @media (prefers-color-scheme:dark){
   body{background:#09090b;color:#e4e4e7}
   code,pre{background:#18181b}
 }
</style>
<h1>HA Web Platform</h1>
<p>Served by <code>__NODE__</code></p>
<p>Database tier: <span class="__CLASS__">__STATE__</span></p>
<pre>__DETAIL__</pre>
<p>Reload to watch the load balancer alternate between nodes.
   <a href="/db">/db</a> &middot; <a href="/write">/write</a></p>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "app/1.0"
    sys_version = ""

    def _send(self, code, body, content_type="application/json"):
        payload = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        path = self.path.split("?", 1)[0]

        if path == "/healthz":
            self._send(200, json.dumps({"status": "ok", "node": HOSTNAME}))

        elif path == "/db":
            self._send(200, json.dumps(db_status(), indent=2))

        elif path == "/write":
            self._send(200, json.dumps(record_visit(), indent=2))

        elif path == "/login":
            # Exists purely as a rate-limit target. nginx caps it per-node and
            # Cloudflare caps it at 10/min at the edge before that.
            self._send(200, json.dumps({"login": "stub", "node": HOSTNAME}))

        elif path == "/":
            db = db_status()
            reachable = db.get("reachable", False)
            html = (
                PAGE.replace("__NODE__", HOSTNAME)
                .replace("__CLASS__", "ok" if reachable else "bad")
                .replace("__STATE__", "reachable" if reachable else "UNREACHABLE")
                .replace("__DETAIL__", json.dumps(db, indent=2))
            )
            self._send(200, html, "text/html; charset=utf-8")

        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):  # noqa: N802
        if self.path.split("?", 1)[0] == "/login":
            self._send(200, json.dumps({"login": "stub", "node": HOSTNAME}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, fmt, *args):
        # nginx already logs every request. Duplicating it into the journal only
        # fills the disk.
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
