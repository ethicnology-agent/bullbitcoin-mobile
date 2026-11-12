#!/usr/bin/env python3
"""Exercise isolated regtest services without displaying wallet material."""

import json
import time
from uuid import uuid4

import stack


def main():
    stack.wait_ready()
    stack.wait_indexers()
    stack.wait_services()
    for sender_peer in (False, True):
        invoice = stack.lightning(not sender_peer, "invoice", "1000000",
                                  "smoke-" + str(uuid4()), "regtest-smoke")["bolt11"]
        payment = stack.lightning(sender_peer, "pay", invoice)
        if payment["status"] != "complete":
            raise RuntimeError("Lightning payment did not settle")
    if stack.bark("GET", "wallet/balance")["spendable_sat"] < 200000:
        stack.bark("POST", "boards/board-amount", {"amount_sat": 1000000})
        stack.mine(False, 3)
        stack.wait_indexers()
        stack.bark("POST", "wallet/sync", {})
    receiver = stack.bark("POST", "wallet/addresses/next", {}, peer=True)["address"]
    before = stack.bark("GET", "wallet/balance", peer=True)["spendable_sat"]
    stack.bark("POST", "wallet/send", {"destination": receiver, "amount_sat": 100000})
    stack.bark("POST", "wallet/sync", {}, peer=True)
    after = stack.bark("GET", "wallet/balance", peer=True)["spendable_sat"]
    if after < before + 100000:
        raise RuntimeError("Ark transfer not received")
    address = stack.rpc(False, "getnewaddress", wallet="bull-regtest")
    stack.bark("POST", "wallet/offboard/all", {"address": address}, peer=True)
    stack.mine(False, 3)
    if stack.rpc(False, "getreceivedbyaddress", address, wallet="bull-regtest") <= 0:
        raise RuntimeError("Ark offboard did not reach Bitcoin")
    print(json.dumps({"lightning_bidirectional": True, "ark_transfer": True,
                      "ark_offboard": True, "services": "ready"}))


if __name__ == "__main__":
    main()
