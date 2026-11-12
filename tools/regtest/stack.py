#!/usr/bin/env python3
"""Run BULL's isolated Nigiri chains with rootless Podman."""

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.request
import urllib.error

import yaml


STATE = Path(os.environ.get("BULL_REGTEST_STATE", Path.home() / ".local/share/bull-regtest"))
NIGIRI = STATE / "nigiri"
COMPOSE = STATE / "compose.yml"
LOCK = Path(__file__).with_name("images.json")
SERVICES = (
    "bitcoin", "liquid", "electrs", "electrs-liquid", "electrum-ws",
    "chopsticks", "chopsticks-liquid", "esplora", "esplora-liquid",
)


def run(*args, capture=False, stdin=None):
    if args[0] == "podman":
        args = ("podman", "--cgroup-manager=cgroupfs", *args[1:])
    environment = None
    if args[0] in ("podman", "podman-compose"):
        # Rootless cgroupfs needs no session bus. Disable D-Bus autolaunch only
        # for this command and its children; leave the host session untouched.
        environment = {**os.environ, "DBUS_SESSION_BUS_ADDRESS": "disabled"}
    return subprocess.run(args, check=True, text=True, capture_output=capture, input=stdin, env=environment).stdout


def compose(*args, capture=False):
    return run("podman-compose", "--podman-args=--cgroup-manager=cgroupfs",
               "-p", "bull-regtest", "-f", str(COMPOSE), *args, capture=capture)


def prepare():
    NIGIRI.mkdir(parents=True, exist_ok=True)
    binary = shutil.which("nigiri") or str(Path.home() / ".local/bin/nigiri")
    version = run(binary, "--datadir", str(NIGIRI), "version", capture=True)
    if "Version: 0.5.17" not in version:
        raise RuntimeError("Nigiri 0.5.17 is required")
    source = yaml.safe_load((NIGIRI / "docker-compose.yml").read_text())
    pins = json.loads(LOCK.read_text()) if LOCK.exists() else {}
    services = {name: source["services"][name] for name in SERVICES}
    # Bark 0.8.1 requires Core 31; Nigiri 0.5.17 still embeds Core 30.
    services["bitcoin"]["image"] = "ghcr.io/getumbrel/docker-bitcoind:v31.0"
    # Match Liquid's relay floor and Boltz's Elements fee policy.
    services["liquid"]["command"] = ["-datadir=config", "-minrelaytxfee=0.00000100", "-acceptdiscountct=1"]
    services.update({
        "cln": {
            "image": "docker.io/secondark/cln-hold:v26.06.10-efc7d5f",
            "hostname": "cln", "entrypoint": ["sh", "/app/start-cln.sh"], "restart": "on-failure",
            "environment": {"BITCOIN_RPCCONNECT": "bitcoin:18443",
                            "BITCOIN_RPCUSER": "admin1", "BITCOIN_RPCPASSWORD": "123",
                            "CLN_LOG_LEVEL": "info"},
            "volumes": ["cln:/root/.lightning",
                        str(Path(__file__).with_name("start-cln.sh").resolve()) + ":/app/start-cln.sh:ro"],
            "depends_on": ["bitcoin"],
        },
        "captaind": {
            "image": "docker.io/secondark/captaind:0.8.1",
            "entrypoint": ["sh", "/app/start-captaind.sh"],
            "volumes": ["captaind:/data/captaind", "postgres:/var/lib/postgresql/data",
                        "cln:/data/cln", str(Path(__file__).with_name("captaind.toml").resolve())
                        + ":/root/captaind/captaind.toml:ro",
                        str(Path(__file__).with_name("start-captaind.sh").resolve()) + ":/app/start-captaind.sh:ro"],
            "ports": ["3535:3535"], "depends_on": ["cln"], "restart": "on-failure",
        },
        "bark": {
            "image": "docker.io/secondark/bark:0.8.1",
            "entrypoint": ["/usr/local/bin/barkd"],
            "command": ["--no-ui", "--host", "0.0.0.0", "--port", "3000"],
            "ports": ["3538:3000"],
            "volumes": ["bark:/root"], "restart": "on-failure",
        },
        "exchange": {
            "image": "docker.io/library/python:3.11-slim-bookworm",
            "command": ["python3", "/app/exchange.py", "--host", "0.0.0.0"],
            "volumes": [str(Path(__file__).with_name("exchange.py").resolve()) + ":/app/exchange.py:ro"],
            "ports": ["8088:8088"],
        },
        "boltz-postgres": {
            "image": "docker.io/library/postgres:18-alpine",
            "environment": {"POSTGRES_DB": "boltz", "POSTGRES_USER": "boltz",
                            "POSTGRES_PASSWORD": "boltz"},
            "volumes": ["boltz-postgres:/var/lib/postgresql"],
        },
        "boltz": {
            "image": "docker.io/boltz/boltz:v3.13.0",
            "command": ["--datadir", "/data/boltz", "--configpath", "/config/boltz.toml"],
            "volumes": ["boltz:/data/boltz", "boltz-cln:/data/cln:ro",
                        str(Path(__file__).with_name("boltz.toml").resolve()) + ":/config/boltz.toml:ro"],
            "ports": ["9001:9001", "9004:9004", "9005:9005"],
            "depends_on": ["bitcoin", "liquid", "boltz-cln", "boltz-postgres"],
            "restart": "on-failure",
        },
    })
    services["bark-peer"] = {
        **services["bark"], "ports": ["3539:3000"],
        "volumes": ["bark-peer:/root"],
    }
    services["cln-peer"] = {
        **services["cln"], "hostname": "cln-peer",
        "volumes": ["cln-peer:/root/.lightning",
                    str(Path(__file__).with_name("start-cln.sh").resolve()) + ":/app/start-cln.sh:ro"],
    }
    services["boltz-cln"] = {
        **services["cln"], "hostname": "boltz-cln",
        "image": "docker.io/secondark/cln-hold:v26.04.1",
        "volumes": ["boltz-cln:/root/.lightning",
                    str(Path(__file__).with_name("start-cln.sh").resolve()) + ":/app/start-cln.sh:ro"],
    }
    for node in ("cln-peer", "boltz-cln"):
        services[node]["environment"] = {
            **services[node]["environment"],
            "CLN_EXTRAS": "--clnrest-port=3010 --clnrest-host=0.0.0.0 --clnrest-protocol=http",
        }
    services["controller"] = {
        "image": "docker.io/library/python:3.11-slim-bookworm",
        "command": ["python3", "/app/controller.py"],
        "volumes": [str(Path(__file__).with_name("controller.py").resolve()) + ":/app/controller.py:ro",
                    "cln-peer:/data/cln-peer:ro", "boltz-cln:/data/boltz-cln:ro",
                    "bark:/data/bark:ro", "bark-peer:/data/bark-peer:ro",
                    str(STATE / "mailrooms") + ":/data/mailrooms:ro"],
        "ports": ["8099:8099"], "depends_on": ["bitcoin", "liquid", "cln-peer", "boltz-cln"],
    }
    python_image = "docker.io/library/python:3.11-slim-bookworm"
    services["mailrooms"] = {
        "image": python_image, "command": ["/app/mailrooms"],
        "volumes": [str(STATE / "bin/mailrooms") + ":/app/mailrooms:ro",
                    str(STATE / "mailrooms") + ":/data"],
        "ports": ["8040:8040", "8041:8041"],
    }
    services["recoverbull"] = {
        "image": python_image, "command": ["/app/recoverbull"],
        "volumes": [str(STATE / "bin/recoverbull") + ":/app/recoverbull:ro", "recoverbull:/data"],
        "environment": {
            "DATABASE_URL": "/data/recoverbull.sqlite3", "SERVER_ADDRESS": "0.0.0.0:3000",
            "SECRET_MAX_LENGTH": "128", "CANARY": "BULL regtest fixture",
            "RATE_LIMIT_COOLDOWN": "1", "RATE_LIMIT_MAX_ATTEMPTS": "3",
            "ATTEMPTS_SNAPSHOT_TTL_SECONDS": "30", "RATE_LIMIT_MEMORY_BUDGET_MB": "512",
        }, "ports": ["8098:3000"],
    }
    services["recoverbull-proxy"] = {
        "image": python_image, "command": ["python3", "/app/proxy.py"],
        "volumes": [str(Path(__file__).with_name("recoverbull_proxy.py").resolve()) + ":/app/proxy.py:ro"],
        "ports": ["59051:9051"], "depends_on": ["recoverbull"],
    }
    for name, service in services.items():
        image = service["image"]
        if image not in pins:
            run("podman", "pull", image)
            info = json.loads(run("podman", "image", "inspect", image, capture=True))[0]
            pins[image] = info["RepoDigests"][0]
        service["image"] = pins[image]
        service["container_name"] = f"bull-regtest-{name}"
        service["stop_grace_period"] = "60s"
        service["ports"] = [f"127.0.0.1:{port}" for port in service.get("ports", [])]
        service["volumes"] = [str(NIGIRI / volume[2:]) if volume.startswith("./") else volume
                              for volume in service.get("volumes", [])]
        # Root in a rootless container maps to the invoking host user.
        service.pop("user", None)
        if name in ("bitcoin", "liquid"):
            service["user"] = "0:0"
    COMPOSE.write_text(yaml.safe_dump({"version": "3.8", "services": services,
                                      "volumes": {name: {} for name in ("cln", "cln-peer", "boltz-cln", "captaind", "postgres", "bark", "bark-peer", "boltz", "boltz-postgres", "recoverbull")}},
                                     sort_keys=False))
    LOCK.write_text(json.dumps(pins, indent=2) + "\n")
    print(f"Configuration: {COMPOSE}")


def prepare_certificates():
    directory = STATE / "mailrooms"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not (directory / "key.pem").exists():
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
            "-subj", "/CN=BULL regtest", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-keyout", str(directory / "key.pem"), "-out", str(directory / "cert.pem"), capture=True)
        (directory / "key.pem").chmod(0o600)
    constraints = run("openssl", "x509", "-in", str(directory / "cert.pem"),
                      "-noout", "-ext", "basicConstraints", capture=True)
    if "CA:FALSE" not in constraints:
        run("openssl", "req", "-x509", "-new", "-key", str(directory / "key.pem"), "-days", "3650",
            "-subj", "/CN=BULL regtest", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
            "-addext", "basicConstraints=critical,CA:FALSE", "-out", str(directory / "cert.pem"), capture=True)
    run("openssl", "x509", "-in", str(directory / "cert.pem"), "-outform", "DER",
        "-out", str(directory / "cert.der"), capture=True)


def rpc(liquid, *args, wallet=None):
    service = "liquid" if liquid else "bitcoin"
    binary = "elements-cli" if liquid else "bitcoin-cli"
    flags = ["-datadir=config"] if liquid else []
    if wallet is not None:
        flags.append(f"-rpcwallet={wallet}")
    output = run("podman", "exec", f"bull-regtest-{service}", binary, *flags, *args, capture=True)
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return output.strip()


def lightning(peer, *args, node=None):
    service = node or ("cln-peer" if peer else "cln")
    return json.loads(run("podman", "exec", f"bull-regtest-{service}",
                          "lightning-cli", "--regtest", "--json", "--notifications=none",
                          *args, capture=True))


def ensure_wallet(liquid, name):
    if name in rpc(liquid, "listwallets"):
        return
    existing = {item["name"] for item in rpc(liquid, "listwalletdir")["wallets"]}
    rpc(liquid, "loadwallet" if name in existing else "createwallet", name)


def bark(method, path, body=None, peer=False):
    if "mnemonic" in path.lower():
        raise RuntimeError("Mnemonic exposure is not supported by the launcher")
    # Read only the token created by this stack. Keep it in memory and HTTP
    # headers; never place it in arguments, output or an additional file.
    service = "bull-regtest-bark-peer" if peer else "bull-regtest-bark"
    port = 3539 if peer else 3538
    token = run("podman", "exec", service, "cat",
                "/root/.bark/auth_token", capture=True).strip()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/v1/" + path.lstrip("/"),
        None if body is None else json.dumps(body).encode(),
        {"Content-Type": "application/json", "Authorization": "Bearer " + token},
        method=method,
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        payload = response.read()
        return json.loads(payload) if payload else None


def mine(liquid, count):
    address = rpc(liquid, "getnewaddress", wallet="bull-regtest")
    return rpc(liquid, "generatetoaddress", str(count), address)


def bootstrap():
    wait_ready()
    for liquid in (False, True):
        for wallet in ("bull-regtest", "boltz"):
            ensure_wallet(liquid, wallet)
    if rpc(False, "getbalance", wallet="bull-regtest") < 10:
        mine(False, 101)
    for liquid in (False, True):
        for funding_wallet in (("boltz", "bull-regtest") if liquid else ("boltz",)):
            balance_args = ["*", "0", "false", "false", "bitcoin"] if liquid else []
            if rpc(liquid, "getbalance", *balance_args, wallet=funding_wallet) < 1:
                address = rpc(liquid, "getnewaddress", wallet=funding_wallet)
                data = json.dumps({"address": address, "amount": 2}).encode()
                port = 3001 if liquid else 3000
                request = urllib.request.Request(f"http://127.0.0.1:{port}/faucet", data,
                                                 {"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=30) as response:
                    if response.status != 200:
                        raise RuntimeError("Nigiri faucet failed")
                mine(liquid, 2)
    deadline = time.monotonic() + 180
    while True:
        try:
            for node in ("cln", "cln-peer", "boltz-cln"):
                lightning(False, "getinfo", node=node)
            break
        except subprocess.CalledProcessError:
            if time.monotonic() > deadline:
                raise RuntimeError("Lightning nodes did not start")
            time.sleep(2)
    for node in ("cln", "cln-peer", "boltz-cln"):
        if not any(output["status"] in ("confirmed", "unconfirmed")
                   for output in lightning(False, "listfunds", node=node)["outputs"]):
            address = lightning(False, "newaddr", node=node)["bech32"]
            rpc(False, "sendtoaddress", address, "0.5", wallet="bull-regtest")
    mine(False, 6)
    deadline = time.monotonic() + 180
    while True:
        if all(any(output["status"] == "confirmed" for output in lightning(False, "listfunds", node=node)["outputs"])
               for node in ("cln", "cln-peer", "boltz-cln")):
            break
        if time.monotonic() > deadline:
            raise RuntimeError("Lightning funding did not confirm")
        time.sleep(2)
    peer_id = lightning(True, "getinfo")["id"]
    for node in ("cln", "boltz-cln"):
        lightning(False, "connect", peer_id, "cln-peer", "9735", node=node)
        if not lightning(False, "listpeerchannels", node=node)["channels"]:
            lightning(False, "-k", "fundchannel", f"id={peer_id}", "amount=10000000",
                      "push_msat=5000000000", node=node)
            mine(False, 6)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if all(any(channel["state"] == "CHANNELD_NORMAL" for channel in lightning(False, "listpeerchannels", node=node)["channels"])
               for node in ("cln", "boltz-cln")):
            break
        time.sleep(2)
    else:
        raise RuntimeError("Lightning channel did not become active")
    wait_indexers()
    initialize_ark()
    initialize_controller()
    wait_services()
    print("Bitcoin, Liquid, Lightning, Bark, Boltz and dummy exchange initialized")


def wait_indexers():
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            for liquid, port in ((False, 30000), (True, 30001)):
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/blocks/tip/height", timeout=5) as response:
                    height = int(response.read())
                if height < rpc(liquid, "getblockcount"):
                    break
            else:
                return
        except (OSError, ValueError):
            pass
        time.sleep(2)
    raise RuntimeError("Electrum indexers did not catch up with the chains")


def initialize_ark():
    deadline = time.monotonic() + 180
    while True:
        try:
            provider = json.loads(run("podman", "exec", "bull-regtest-captaind", "captaind",
                                      "--config", "/root/captaind/captaind.toml", "rpc", "wallet", capture=True))["rounds"]
            break
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            if time.monotonic() > deadline:
                raise RuntimeError("Bark provider did not start")
            time.sleep(2)
    if provider["total_balance"] < 10000000:
        rpc(False, "sendtoaddress", provider["address"], "1", wallet="bull-regtest")
        mine(False, 3)
    for peer in (False, True):
        if bark("GET", "wallet", peer=peer)["fingerprint"] is None:
            bark("POST", "wallet/create", {
                "network": "regtest", "ark_server": "http://captaind:3535",
                "chain_source": {"esplora": {"url": "http://chopsticks:3000"}},
            }, peer=peer)
    if bark("GET", "onchain/balance")["total_sat"] < 1000000:
        address = bark("POST", "onchain/addresses/next", {})["address"]
        rpc(False, "sendtoaddress", address, "0.02", wallet="bull-regtest")
        mine(False, 3)
    wait_indexers()
    bark("POST", "onchain/sync", {})


def initialize_controller():
    for node in ("cln-peer", "boltz-cln"):
        path = "/root/.lightning/regtest/regtest-controller.rune"
        try:
            run("podman", "exec", f"bull-regtest-{node}", "test", "-s", path, capture=True)
        except subprocess.CalledProcessError:
            methods = ["method=getinfo"]
            if node == "cln-peer":
                methods.extend(["method=invoice", "method=pay"])
            rune = lightning(False, "-k", "createrune", "restrictions=" + json.dumps([methods]), node=node)["rune"]
            run("podman", "exec", "-i", f"bull-regtest-{node}", "sh", "-c",
                "umask 077; cat > " + path, stdin=rune)


def wait_services():
    deadline = time.monotonic() + 180
    endpoints = ("http://127.0.0.1:9001/v2/swap/chain", "http://127.0.0.1:8088/health",
                 "http://127.0.0.1:8099/health", "http://127.0.0.1:8098/info")
    while time.monotonic() < deadline:
        try:
            for url in endpoints:
                with urllib.request.urlopen(url, timeout=5) as response:
                    json.load(response)
            for peer in (False, True):
                bark("GET", "wallet/balance", peer=peer)
            trust = ssl.create_default_context(cafile=str(STATE / "mailrooms/cert.pem"))
            for hostname, port in (("localhost", 8040), ("127.0.0.1", 8041)):
                with socket.create_connection((hostname, port), timeout=5) as connection:
                    with trust.wrap_socket(connection, server_hostname=hostname):
                        pass
            return
        except (OSError, ValueError, subprocess.CalledProcessError):
            time.sleep(2)
    raise RuntimeError("Regtest services did not become ready, including RecoverBull and Payjoin TLS")


def wait_ready():
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            bitcoin = rpc(False, "getblockchaininfo")
            liquid = rpc(True, "getblockchaininfo")
            if bitcoin["chain"] != "regtest" or liquid["chain"] != "liquidregtest":
                raise RuntimeError("Unexpected chain")
            print(json.dumps({"bitcoin": bitcoin["blocks"], "liquid": liquid["blocks"],
                              "policyAsset": rpc(True, "getsidechaininfo")["pegged_asset"]}))
            return
        except subprocess.CalledProcessError:
            time.sleep(2)
    raise RuntimeError("Nodes did not become ready within 180 seconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "up", "status", "down", "rpc", "mine", "faucet", "bootstrap", "ln", "bark"])
    parser.add_argument("--liquid", action="store_true")
    parser.add_argument("--peer", action="store_true")
    parser.add_argument("--wallet")
    parser.add_argument("--method", choices=["GET", "POST"], default="GET")
    parser.add_argument("args", nargs="*")
    args = parser.parse_intermixed_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "up":
        for name in ("recoverbull", "mailrooms"):
            if not os.access(STATE / "bin" / name, os.X_OK):
                raise RuntimeError("Build ancillary services with tools/regtest/build-services.py first")
        for name in ("cert.pem", "key.pem", "cert.der"):
            if not (STATE / "mailrooms" / name).is_file():
                raise RuntimeError("Prepare Payjoin TLS with tools/regtest/build-services.py first")
        prepare()
        compose("up", "-d")
        bootstrap()
    elif args.command == "status":
        compose("ps")
        wait_ready()
        wait_indexers()
        wait_services()
    elif args.command == "down":
        compose("down")
    elif args.command == "rpc":
        print(json.dumps(rpc(args.liquid, *args.args, wallet=args.wallet)))
    elif args.command == "ln":
        print(json.dumps(lightning(args.peer, *args.args)))
    elif args.command == "bark":
        if not 1 <= len(args.args) <= 2:
            parser.error("bark requires API_PATH and optional JSON_BODY")
        print(json.dumps(bark(args.method, args.args[0],
                              json.loads(args.args[1]) if len(args.args) == 2 else None, peer=args.peer)))
    elif args.command == "bootstrap":
        bootstrap()
    elif args.command == "mine":
        print(json.dumps(mine(args.liquid, int(args.args[0]) if args.args else 1)))
    elif args.command == "faucet":
        if len(args.args) != 2:
            parser.error("faucet requires ADDRESS AMOUNT_BTC")
        print(json.dumps(rpc(args.liquid, "sendtoaddress", *args.args, wallet="bull-regtest")))


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
