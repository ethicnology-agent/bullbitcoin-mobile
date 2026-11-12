#!/usr/bin/env python3
"""Bounded regtest utilities for mobile integration tests, never an exchange."""

import json
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time
import signal
import sys
import threading
import urllib.request
import urllib.error
from uuid import uuid4


POLICY_ASSET = "5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225"
ARK_LOCK = threading.Lock()
ARK_RUNS = {}


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


def mine_indexed(network, count):
    address = rpc(network, "getnewaddress")
    rpc(network, "generatetoaddress", [count, address])
    height = rpc(network, "getblockcount")
    indexer, port = ("electrs", 30000) if network == "bitcoin" else ("electrs-liquid", 30001)
    deadline = time.monotonic() + 20
    while True:
        with urllib.request.urlopen(f"http://{indexer}:{port}/blocks/tip/height", timeout=5) as response:
            indexed = int(response.read())
        if indexed >= height:
            return height
        if time.monotonic() >= deadline:
            raise RuntimeError("Indexer tip unavailable")
        time.sleep(0.1)


def bark(method, path, body=None, peer=False):
    allowed = {"wallet/debug-info", "wallet/ark-info", "onchain/addresses/next",
               "onchain/sync", "onchain/utxos", "boards/board-amount", "wallet/sync",
               "wallet/vtxos", "wallet/send", "wallet/addresses/next", "wallet/offboard/vtxos"}
    if path not in allowed:
        raise ValueError("Unknown Bark fixture operation")
    host = "bark-peer" if peer else "bark"
    token = Path(f"/data/{host}/.bark/auth_token").read_text().strip()
    request = urllib.request.Request(
        f"http://{host}:3000/api/v1/{path}",
        None if body is None else json.dumps(body).encode(),
        {"Content-Type": "application/json", "Authorization": "Bearer " + token}, method=method,
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        payload = response.read()
        return json.loads(payload) if payload else None


def verify_ark():
    for peer in (False, True):
        for path in ("wallet/debug-info", "wallet/ark-info"):
            if bark("GET", path, peer=peer)["network"] != "regtest":
                raise RuntimeError("Unexpected Bark network")


def spendable(vtxos):
    return [v for v in vtxos if v["state"]["type"] == "spendable"]


def ark_fixture(path, body):
    verify_ark()
    if path == "/ark/funding-address":
        now = time.monotonic()
        for key in list(ARK_RUNS):
            if now - ARK_RUNS[key]["created"] > 900:
                del ARK_RUNS[key]
        if len(ARK_RUNS) >= 16:
            raise RuntimeError("Too many Ark fixtures")
        address = bark("POST", "onchain/addresses/next", {})["address"]
        run_id = str(uuid4())
        ARK_RUNS[run_id] = {"created": now, "address": address}
        return {"run_id": run_id, "address": address, "deposit_sat": 150000}
    run = ARK_RUNS[body["run_id"]]
    if time.monotonic() - run["created"] > 900:
        raise ValueError("Ark fixture expired")
    if path == "/ark/board":
        txid = body["deposit_txid"]
        if not isinstance(txid, str) or len(txid) != 64 or any(c not in "0123456789abcdef" for c in txid):
            raise ValueError("Invalid deposit transaction")
        if "deposit_txid" in run and run["deposit_txid"] != txid:
            raise ValueError("Fixture deposit already selected")
        if "board_ids" not in run:
            bark("POST", "onchain/sync", {})
            coins = bark("GET", "onchain/utxos")
            deposit = next((coin for coin in coins if coin["outpoint"].startswith(txid + ":")
                            and coin["amount_sat"] == 150000 and coin["confirmation_height"]), None)
            if deposit is None:
                raise RuntimeError("Bark did not observe the confirmed BULL deposit")
            vout = int(deposit["outpoint"].rsplit(":", 1)[1])
            output = rpc("bitcoin", "gettxout", [txid, vout, True])
            if not output or output["scriptPubKey"].get("address") != run["address"]:
                raise RuntimeError("Deposit does not belong to this fixture")
            run["deposit_txid"] = txid
            # The pinned provider charges its 330-sat minimum board fee.
            board = bark("POST", "boards/board-amount", {"amount_sat": 100330})
            if board["amount_sat"] != 100000 or not board["vtxos"]:
                raise RuntimeError("Unexpected Ark board amount")
            run["board_ids"] = set(board["vtxos"])
            funding_txid = board["funding_tx"]["txid"]
            deadline = time.monotonic() + 30
            while True:
                try:
                    rpc("bitcoin", "getrawtransaction", [funding_txid, True])
                    break
                except RuntimeError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("The Ark board funding was not broadcast") from None
                    time.sleep(0.2)
            mine_indexed("bitcoin", 3)
        deadline = time.monotonic() + 60
        while True:
            bark("POST", "wallet/sync", {})
            boarded = [v for v in spendable(bark("GET", "wallet/vtxos")) if v["id"] in run["board_ids"]]
            if {v["id"] for v in boarded} == run["board_ids"] and sum(v["amount_sat"] for v in boarded) == 100000:
                run["boarded"] = True
                return {"deposit_confirmed": True, "board_spendable": True, "amount_sat": 100000}
            if time.monotonic() >= deadline:
                raise RuntimeError("The new Ark board did not become spendable")
            time.sleep(0.5)
    if path == "/ark/offboard":
        address = body["address"]
        if not isinstance(address, str) or not address.startswith("bcrt1") or not rpc("bitcoin", "validateaddress", [address])["isvalid"]:
            raise ValueError("Bitcoin regtest destination required")
        if not run.get("boarded"):
            raise ValueError("Complete the deposit and board first")
        if "offboard_txid" in run:
            if address != run["destination"]:
                raise ValueError("Fixture destination already selected")
            return {"offboard_txid": run["offboard_txid"], "transferred_sat": 100000}
        if "peer_ids" not in run:
            if "transfer_before" not in run:
                run["transfer_before"] = {v["id"] for v in bark("GET", "wallet/vtxos", peer=True)}
                recipient = bark("POST", "wallet/addresses/next", {}, peer=True)["address"]
                bark("POST", "wallet/send", {"destination": recipient, "amount_sat": 100000})
            deadline = time.monotonic() + 60
            while True:
                bark("POST", "wallet/sync", {}, peer=True)
                received = [v for v in spendable(bark("GET", "wallet/vtxos", peer=True)) if v["id"] not in run["transfer_before"]]
                if received and sum(v["amount_sat"] for v in received) == 100000:
                    run["peer_ids"] = [v["id"] for v in received]
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("The Ark peer did not receive this fixture transfer")
                time.sleep(0.5)
        result = bark("POST", "wallet/offboard/vtxos", {"address": address, "vtxos": run["peer_ids"]}, peer=True)
        run["offboard_txid"] = result["offboard_txid"]
        run["destination"] = address
        return {"offboard_txid": run["offboard_txid"], "transferred_sat": 100000}
    raise ValueError("Unknown Ark fixture")


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
            if self.path.startswith("/ark/"):
                if not ARK_LOCK.acquire(blocking=False):
                    self.respond(409, {"error": "Ark fixture busy"})
                    return
                try:
                    self.respond(200, ark_fixture(self.path, body))
                finally:
                    ARK_LOCK.release()
                return
            if self.path == "/mine":
                network = body["network"]
                count = body.get("count", 1)
                if type(count) is not int or not 1 <= count <= 6:
                    raise ValueError("Invalid block count")
                self.respond(200, {"height": mine_indexed(network, count)})
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
        except (OSError, RuntimeError, ValueError, TypeError, KeyError) as error:
            reasons = {
                "Bark did not observe the confirmed BULL deposit": "deposit_not_observed",
                "Deposit does not belong to this fixture": "deposit_address_mismatch",
                "Unexpected Ark board amount": "board_amount_mismatch",
                "The Ark board funding was not broadcast": "board_not_broadcast",
                "The new Ark board did not become spendable": "board_not_spendable",
                "The Ark peer did not receive this fixture transfer": "peer_transfer_not_observed",
            }
            self.respond(400, {"error": "Regtest utility request failed",
                               "reason": reasons.get(str(error), "upstream_or_invalid_request"),
                               "upstream_status": error.code if isinstance(error, urllib.error.HTTPError) else None})


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = ThreadingHTTPServer(("0.0.0.0", 8099), Handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()
