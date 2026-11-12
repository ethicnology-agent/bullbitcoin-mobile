#!/usr/bin/env python3
"""Bounded regtest utilities for mobile integration tests, never an exchange."""

import json
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time
import signal
import sys
import urllib.request
from uuid import uuid4


POLICY_ASSET = "5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225"


def post(url, body, headers=None, timeout=120):
    request = urllib.request.Request(url, json.dumps(body).encode(),
                                     {"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def rpc(network, method, params=None):
    if network not in ("bitcoin", "liquid"):
        raise ValueError("Unknown chain")
    port = 18443 if network == "bitcoin" else 18884
    result = post(f"http://{network}:{port}/wallet/bull-regtest",
                  {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []},
                  {"Authorization": "Basic YWRtaW4xOjEyMw=="})
    if result.get("error"):
        raise RuntimeError("Regtest RPC failed")
    return result["result"]


def lightning(node, method, params=None):
    token = Path(f"/data/{node}/regtest/regtest-controller.rune").read_text().strip()
    return post(f"http://{node}:3010/v1/{method}", params or {}, {"Rune": token})


def verify_networks():
    for network, expected in (("bitcoin", "regtest"), ("liquid", "liquidregtest")):
        if rpc(network, "getblockchaininfo")["chain"] != expected:
            raise RuntimeError("Unexpected chain")
    if rpc("liquid", "getsidechaininfo")["pegged_asset"] != POLICY_ASSET:
        raise RuntimeError("Unsupported policy asset")
    for node in ("cln-peer", "boltz-cln"):
        if lightning(node, "getinfo")["network"] != "regtest":
            raise RuntimeError("Unexpected Lightning network")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/payjoin/certificate":
            try:
                certificate = Path("/data/mailrooms/cert.der").read_bytes()
                self.respond(200, {"certificate": base64.b64encode(certificate).decode("ascii")})
            except OSError:
                self.respond(503, {"error": "Payjoin fixture unavailable"})
            return
        if self.path != "/health":
            self.respond(404, {"error": "Unknown utility"})
            return
        try:
            verify_networks()
            self.respond(200, {"service": "regtest-controller", "network": "regtest"})
        except (OSError, RuntimeError, ValueError, KeyError):
            self.respond(503, {"error": "Regtest services unavailable"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16384:
                raise ValueError("Invalid request size")
            body = json.loads(self.rfile.read(length))
            verify_networks()
            if self.path == "/mine":
                network = body["network"]
                count = body.get("count", 1)
                if type(count) is not int or not 1 <= count <= 6:
                    raise ValueError("Invalid block count")
                address = rpc(network, "getnewaddress")
                rpc(network, "generatetoaddress", [count, address])
                height = rpc(network, "getblockcount")
                indexer = "electrs" if network == "bitcoin" else "electrs-liquid"
                indexer_port = 30000 if network == "bitcoin" else 30001
                deadline = time.monotonic() + 20
                while True:
                    with urllib.request.urlopen(f"http://{indexer}:{indexer_port}/blocks/tip/height", timeout=5) as response:
                        indexed = int(response.read())
                    if indexed >= height:
                        break
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Indexer tip unavailable")
                    time.sleep(0.1)
                self.respond(200, {"height": height})
            elif self.path == "/faucet":
                network = body["network"]
                address = body["address"]
                amount = body["amount_sat"]
                prefix = ("bcrt1",) if network == "bitcoin" else ("el1", "ert1")
                if not isinstance(address, str) or not address.lower().startswith(prefix):
                    raise ValueError("Regtest address required")
                if type(amount) is not int or not 1 <= amount <= 5000000:
                    raise ValueError("Invalid funding amount")
                txid = rpc(network, "sendtoaddress", [address, amount / 100000000])
                self.respond(200, {"txid": txid})
            elif self.path == "/lightning/invoice":
                amount = body["amount_sat"]
                if type(amount) is not int or not 1000 <= amount <= 1000000:
                    raise ValueError("Invalid invoice amount")
                invoice = lightning("cln-peer", "invoice", {
                    "amount_msat": amount * 1000, "label": "mobile-" + str(uuid4()),
                    "description": "BULL regtest validation",
                })
                self.respond(200, {"invoice": invoice["bolt11"]})
            elif self.path == "/lightning/pay":
                invoice = body["invoice"]
                if not isinstance(invoice, str) or not invoice.lower().startswith("lnbcrt"):
                    raise ValueError("Regtest invoice required")
                target = rpc("bitcoin", "getblockcount")
                deadline = time.monotonic() + 120
                while any(lightning(node, "getinfo")["blockheight"] < target
                          for node in ("cln-peer", "boltz-cln")):
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Lightning tip unavailable")
                    time.sleep(0.2)
                payment = lightning("cln-peer", "pay", {"bolt11": invoice, "retry_for": 30})
                # A preimage and payment secret must never leave this utility.
                self.respond(200, {"status": payment["status"]})
            else:
                self.respond(404, {"error": "Unknown utility"})
        except (OSError, RuntimeError, ValueError, TypeError, KeyError):
            self.respond(400, {"error": "Regtest utility request failed"})


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = ThreadingHTTPServer(("0.0.0.0", 8099), Handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()
