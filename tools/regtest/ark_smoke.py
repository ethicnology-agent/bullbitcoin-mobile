"""Verify the real Bark fixture API before running its BULL phone journey."""

import json
import urllib.request
import urllib.error

import stack


def utility(path, body):
    request = urllib.request.Request(
        "http://127.0.0.1:8099/ark/" + path,
        json.dumps(body).encode(), {"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        response = json.load(error)
        allowed = {"deposit_not_observed", "deposit_address_mismatch", "board_amount_mismatch",
                   "board_not_broadcast", "board_not_spendable", "peer_transfer_not_observed"}
        reason = response.get("reason")
        raise RuntimeError("Ark fixture failed: " + (reason if reason in allowed else "upstream_or_invalid_request")) from None


def main():
    stack.wait_ready()
    fixture = utility("funding-address", {})
    if fixture["deposit_sat"] != 150000 or not fixture["address"].startswith("bcrt1"):
        raise RuntimeError("Unexpected Ark deposit fixture")
    txid = stack.rpc(False, "sendtoaddress", fixture["address"], "0.0015", wallet="bull-regtest")
    stack.mine(False, 3)
    stack.wait_indexers()
    board = utility("board", {"run_id": fixture["run_id"], "deposit_txid": txid})
    if not board["deposit_confirmed"] or not board["board_spendable"] or board["amount_sat"] != 100000:
        raise RuntimeError("The confirmed deposit or new board was not verified")
    address = stack.rpc(False, "getnewaddress", wallet="bull-regtest")
    offboard = utility("offboard", {"run_id": fixture["run_id"], "address": address})
    if offboard["transferred_sat"] != 100000:
        raise RuntimeError("Unexpected Ark peer transfer amount")
    stack.mine(False, 3)
    stack.wait_indexers()
    received = stack.rpc(False, "getreceivedbyaddress", address, wallet="bull-regtest")
    if received < 0.0009:
        raise RuntimeError("Selected Ark VTXOs did not reach the Bitcoin fixture")
    print("Confirmed deposit, new board, Ark peer transfer and selected-VTXO offboard verified")


if __name__ == "__main__":
    main()
