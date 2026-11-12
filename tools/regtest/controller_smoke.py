"""Verify real controller mining waits for the matching chain's indexer."""

import json
import urllib.request


def main():
    for network, port in (("bitcoin", 30000), ("liquid", 30001)):
        request = urllib.request.Request(
            "http://127.0.0.1:8099/mine",
            json.dumps({"network": network, "count": 1}).encode(),
            {"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            mined = json.load(response)["height"]
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/blocks/tip/height", timeout=5,
        ) as response:
            indexed = int(response.read())
        if type(mined) is not int or indexed < mined:
            raise RuntimeError("Controller returned before its chain was indexed")
        print(f"Controller mining and indexed tip verified: {network}")


if __name__ == "__main__":
    main()
