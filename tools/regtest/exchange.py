#!/usr/bin/env python3
"""Disposable BULL API simulator. No trading, real credentials or settlement."""

import argparse
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import signal
import sys
from uuid import uuid4


def now():
    return datetime.now(timezone.utc).isoformat()


class Exchange:
    def __init__(self):
        self.orders = {}
        self.scenario = "pending"
        self.preferences = {"currency": "CAD", "language": "en"}

    def dispatch(self, method, params):
        if method in ("getRate", "getIndexRateHistory"):
            if method == "getRate":
                return {"element": {"indexPrice": 10000000, "precision": 2}}
            window = params["element"]
            end = datetime.fromtimestamp(int(window["toDate"]) / 1000, timezone.utc)
            return {"element": {"precision": 2, "rates": [
                {"periodStart": (end - timedelta(days=1)).isoformat(), "indexPrice": 9990000},
                {"periodStart": end.isoformat(), "indexPrice": 10000000},
            ]}}
        if method == "getUserSummary":
            return {"userNumber": 1, "userId": "dummy-user", "groups": ["KYC_IDENTITY_VERIFIED", "CONSENT_SCAM_WARNING"],
                    "profile": {"firstName": "Regtest", "lastName": "Developer"},
                    "email": "developer@example.invalid", "balances": [
                        {"amount": 10000, "currencyCode": "CAD"},
                        {"amount": 10000, "currencyCode": "USD"}],
                    "dca": {"isActive": False}, "autoBuy": {"isActive": False, "addresses": {}},
                    "payjoinReceiveEnabled": False, **self.preferences}
        if method in ("listAnnouncements", "listMyRecipients"):
            return {"elements": []}
        if method == "listOrderSummaries":
            return {"elements": list(self.orders.values())}
        if method == "saveUserPreferences":
            self.preferences.update({key: value for key, value in params.items()
                                     if key in ("currency", "language")})
            return {"success": True}
        if method == "registerResponsibilityConsent":
            return {"success": True}
        if method == "getBestSwapOption":
            amount = Decimal(str(params["amount"]))
            if not amount.is_finite() or amount <= 0:
                raise ValueError("Invalid amount")
            if params["inNetwork"] not in ("bitcoin", "liquid", "lightning") or params["outNetwork"] not in ("bitcoin", "liquid", "lightning"):
                raise ValueError("Invalid network")
            fixed_in = params.get("isInAmountFixed", True)
            incoming = amount if fixed_in else amount / Decimal("0.99")
            outgoing = amount * Decimal("0.99") if fixed_in else amount
            currency = lambda network: "LBTC" if network == "liquid" else "BTC"
            return {"inAmount": float(incoming), "outAmount": float(outgoing),
                    "inPaymentProcessorCurrencyCode": currency(params["inNetwork"]),
                    "outPaymentProcessorCurrencyCode": currency(params["outNetwork"]),
                    "orderFees": [{"percent": 1}], "warning": []}
        if method in ("createOrderSwap", "createOrderBuy", "sellToRecipient", "createWithdrawalOrder"):
            order_id = str(uuid4())
            swap = method == "createOrderSwap"
            buy = method in ("createOrderBuy", "createWithdrawalOrder")
            amount = float(params.get("amount", params.get("bitcoinAmount", 0.001)))
            fiat = params.get("fiatCurrency", "CAD")
            payment_method = {"bitcoin": "Bitcoin On-Chain", "liquid": "Liquid Network",
                              "lightning": "Lightning Invoice (BOLT11)"}
            order = {"orderId": order_id, "orderNumber": len(self.orders) + 1,
                     "orderType": "Swap" if swap else "Buy Bitcoin" if buy else "Sell Bitcoin",
                     "payinAmount": amount if swap or not buy else params.get("fiatAmount", 100),
                     "payoutAmount": amount * 0.99 if swap else amount if buy else 99,
                     "payinCurrency": "LBTC" if params.get("inNetwork") == "liquid" else "BTC" if swap or not buy else fiat,
                     "payoutCurrency": "LBTC" if params.get("outNetwork") == "liquid" else "BTC" if swap or buy else fiat,
                     "payinMethod": payment_method.get(params.get("inNetwork", "bitcoin")) if swap or not buy else f"{fiat} Balance",
                     "payoutMethod": payment_method.get(params.get("outNetwork", params.get("network", "bitcoin"))) if swap or buy else f"{fiat} Balance",
                     "orderStatus": "Awaiting confirmation", "payinStatus": "Awaiting payment",
                     "payoutStatus": "Not started", "message": {"code": "created"},
                     "createdAt": now(), "confirmationDeadline":
                         (datetime.now(timezone.utc) + timedelta(minutes=30)).isoformat(),
                     "exchangeRateAmount": 100000, "exchangeRateCurrency": fiat}
            # Optional real regtest destinations enable the app's send screen.
            # State transitions remain simulated and never infer settlement.
            for key, env in (("bitcoinAddress", "DUMMY_BITCOIN_ADDRESS"),
                             ("liquidAddress", "DUMMY_LIQUID_ADDRESS"),
                             ("lightningInvoice", "DUMMY_LIGHTNING_INVOICE")):
                if os.environ.get(env):
                    order[key] = os.environ[env]
            self.orders[order_id] = order
            return order
        if method in ("getOrderSwapSummary", "getOrderSummary", "refreshOrderSummary", "confirmOrderSummary"):
            order = self.orders[params["orderId"]]
            if method == "confirmOrderSummary":
                order["orderStatus"] = "In progress"
            if self.scenario == "completed":
                order.update(orderStatus="Completed", payinStatus="Completed", payoutStatus="Completed",
                             completedAt=now(), sentAt=now(), message={"code": "completed"})
            elif self.scenario == "expired":
                order.update(orderStatus="Expired", message={"code": "expired"})
            return order
        raise LookupError("Method not simulated")


class Handler(BaseHTTPRequestHandler):
    exchange = Exchange()

    def log_message(self, *_):
        pass  # Never log credentials, addresses or request bodies.

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"service": "dummy-exchange", "simulated": True,
                                 "scenario": self.exchange.scenario})
        else:
            self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        request_id = None
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 65536:
                self.send_json(413, {"error": "Invalid request size"})
                return
            request = json.loads(self.rfile.read(length))
            if self.path == "/__scenario":
                scenario = request["scenario"]
                if scenario not in ("pending", "completed", "expired", "rate-limited", "unavailable"):
                    raise ValueError("Unknown scenario")
                self.exchange.scenario = scenario
                self.send_json(200, {"scenario": scenario})
                return
            request_id = request.get("id")
            if self.exchange.scenario == "rate-limited":
                self.send_json(429, {"error": "Simulated rate limit"})
                return
            if self.exchange.scenario == "unavailable":
                self.send_json(503, {"error": "Simulated service outage"})
                return
            result = self.exchange.dispatch(request["method"], request.get("params", {}))
            self.send_json(200, {"jsonrpc": "2.0", "id": request_id, "result": result})
        except LookupError:
            self.send_json(200, {"jsonrpc": "2.0", "id": request_id,
                                 "error": {"code": -32601, "message": "Method or order not simulated"}})
        except (ValueError, TypeError, AttributeError, InvalidOperation):
            self.send_json(400, {"jsonrpc": "2.0", "id": request_id,
                                 "error": {"code": -32602, "message": "Invalid request"}})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8088)
    args = parser.parse_args()
    server = HTTPServer((args.host, args.port), Handler)
    print(json.dumps({"host": args.host, "port": server.server_port, "simulated": True}), flush=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        server.serve_forever()
    finally:
        server.server_close()
