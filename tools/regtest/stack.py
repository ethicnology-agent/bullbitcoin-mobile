#!/usr/bin/env python3
"""Run BULL's isolated Nigiri chains with rootless Podman."""

import argparse
import json
import os
import re
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
# Built locally by build-services.py from these pinned sources, so they are
# named by revision instead of pinned by registry digest. scuttle is
# Bitcoin Jungle's fork of Second's bark: the Ark server with expiry payouts
# (captaind, watchmand), its wallet daemon (barkd) and posd. crash-cache is
# BULL's Sentry-compatible crash report collector.
SCUTTLE = ("https://github.com/Bitcoin-Jungle/scuttle.git", "c031d0b7bfd24d21d92c4f9d338321cbe7e63ba6")
CRASH_CACHE = ("https://github.com/ethicnology/crash-cache.git", "ae657408c9c1c10677929827baae23da72690333")
SCUTTLE_IMAGE = f"localhost/bull-regtest-scuttle:{SCUTTLE[1][:12]}"
CRASH_CACHE_IMAGE = f"localhost/bull-regtest-crash-cache:{CRASH_CACHE[1][:12]}"
# Blockstream's electrs for Bitcoin: Nigiri's predates POST /txs/package,
# which bark needs to broadcast boards (electrs.Dockerfile).
ELECTRS = ("https://github.com/Blockstream/electrs.git", "6cad780be93835b962af735171fae872f9526503")
ELECTRS_IMAGE = f"localhost/bull-regtest-electrs:{ELECTRS[1][:12]}"
LOCAL_IMAGES = (SCUTTLE_IMAGE, CRASH_CACHE_IMAGE, ELECTRS_IMAGE)
POSTGRES_IMAGE = "docker.io/library/postgres:18-alpine"
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
    # scuttle's captaind requires Core 31 or later; Nigiri 0.5.17 still
    # embeds Core 30. 32.1 is what scuttle's deployments run.
    services["bitcoin"]["image"] = "ghcr.io/getumbrel/docker-bitcoind:v32.1"
    # chopsticks (Nigiri's faucet and Esplora proxy) uses Core's unnamed
    # default wallet, which Core 31 and later no longer create. `up` makes
    # it (see ensure_default_wallet); bitcoind loads it and the funding
    # wallet on every start.
    services["bitcoin"]["command"] = ["-wallet=bull-regtest", "-wallet="]
    # The explorers read their API from the browser: loopback by default, a
    # public Esplora when the stack is hosted.
    services["esplora"]["environment"] = {
        "API_URL": os.environ.get("BULL_REGTEST_ESPLORA_URL", "http://localhost:3000")}
    services["esplora-liquid"]["environment"] = {
        "API_URL": os.environ.get("BULL_REGTEST_LIQUID_ESPLORA_URL", "http://localhost:3001")}
    # Same arguments as Nigiri's electrs, on a current build (see ELECTRS).
    services["electrs"]["image"] = ELECTRS_IMAGE
    services["electrs"]["entrypoint"] = ["/usr/local/bin/electrs"]
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
        "ark-postgres": {
            "image": POSTGRES_IMAGE,
            "environment": {"POSTGRES_DB": "captaind", "POSTGRES_USER": "captaind",
                            "POSTGRES_PASSWORD": "captaind"},
            "volumes": ["ark-postgres:/var/lib/postgresql"], "restart": "on-failure",
        },
        "captaind": {
            "image": SCUTTLE_IMAGE,
            "entrypoint": ["sh", "/app/start-captaind.sh"],
            "volumes": ["captaind:/data/captaind", "cln:/data/cln:ro",
                        str(Path(__file__).with_name("captaind.toml").resolve()) + ":/root/captaind/captaind.toml:ro",
                        str(Path(__file__).with_name("start-captaind.sh").resolve()) + ":/app/start-captaind.sh:ro"],
            "ports": ["3535:3535"], "depends_on": ["cln", "ark-postgres"], "restart": "on-failure",
        },
        "watchmand": {
            "image": SCUTTLE_IMAGE,
            "entrypoint": ["sh", "/app/start-watchmand.sh"],
            "volumes": ["watchmand:/data/watchmand", "captaind:/data/captaind:ro",
                        str(Path(__file__).with_name("watchmand.toml").resolve()) + ":/root/watchmand/watchmand.toml:ro",
                        str(Path(__file__).with_name("start-watchmand.sh").resolve()) + ":/app/start-watchmand.sh:ro"],
            "depends_on": ["captaind"], "restart": "on-failure",
        },
        "bark": {
            "image": SCUTTLE_IMAGE,
            "entrypoint": ["/usr/local/bin/barkd"],
            "command": ["--host", "0.0.0.0", "--port", "3000"],
            "environment": {"BARKD_NO_UI": "true"},
            "ports": ["3538:3000"],
            "volumes": ["bark:/root"], "restart": "on-failure",
        },
        # posd's own barkd: it issues the invoices of sales and Lightning
        # addresses and forwards each payment to the store owner's mailbox.
        "posd-barkd": {
            "image": SCUTTLE_IMAGE,
            "entrypoint": ["/usr/local/bin/barkd"],
            "command": ["--host", "0.0.0.0", "--port", "3000"],
            "environment": {"BARKD_NO_UI": "true"},
            "volumes": ["posd-barkd:/root"], "depends_on": ["captaind"], "restart": "on-failure",
        },
        "posd-postgres": {
            "image": POSTGRES_IMAGE,
            "environment": {"POSTGRES_DB": "posd", "POSTGRES_USER": "posd", "POSTGRES_PASSWORD": "posd"},
            "volumes": ["posd-postgres:/var/lib/postgresql"], "restart": "on-failure",
        },
        "posd": {
            "image": SCUTTLE_IMAGE,
            "entrypoint": ["sh", "/app/start-posd.sh"],
            "environment": {
                "POSD__BRANDS__BITCOINJUNGLE__PUBLIC_URL":
                    os.environ.get("BULL_REGTEST_POSD_URL", "http://127.0.0.1:3080"),
                "POSD__BRANDS__BULLBITCOIN__PUBLIC_URL":
                    os.environ.get("BULL_REGTEST_POSD_BULL_URL", "http://localhost:3080"),
            },
            "volumes": ["posd-barkd:/data/posd-barkd:ro",
                        str(Path(__file__).with_name("posd.toml").resolve()) + ":/root/posd/posd.toml:ro",
                        str(Path(__file__).with_name("start-posd.sh").resolve()) + ":/app/start-posd.sh:ro"],
            "ports": ["3080:3080"], "depends_on": ["captaind", "posd-barkd", "posd-postgres", "bitcoin"],
            "restart": "on-failure",
        },
        "crash-cache-postgres": {
            "image": POSTGRES_IMAGE,
            "environment": {"POSTGRES_DB": "crash_cache", "POSTGRES_USER": "crash_cache",
                            "POSTGRES_PASSWORD": "crash_cache"},
            "volumes": ["crash-cache-postgres:/var/lib/postgresql"], "restart": "on-failure",
        },
        "crash-cache": {
            "image": CRASH_CACHE_IMAGE,
            "environment": {
                "DATABASE_URL": "postgresql://crash_cache:crash_cache@crash-cache-postgres:5432/crash_cache",
                "CRASH_CACHE_HOST": "0.0.0.0", "CRASH_CACHE_PORT": "3000",
                # crash-cache requires every setting. Its small profile, with
                # reports processed every 10 seconds instead of every minute.
                "DATABASE_POOL_SIZE": "10", "DATABASE_POOL_TIMEOUT_SECS": "20",
                "MAX_COMPRESSED_PAYLOAD_BYTES": "50 * 1024",
                "MAX_UNCOMPRESSED_PAYLOAD_BYTES": "200 * 1024",
                "WORKER_INTERVAL_SECS": "10", "WORKER_REPORTS_BATCH_SIZE": "100",
                "MAX_CONCURRENT_COMPRESSIONS": "4",
                "RATE_LIMIT_REQUESTS_PER_SEC": "800", "RATE_LIMIT_PER_IP_PER_SEC": "30",
                "RATE_LIMIT_PER_PROJECT_PER_SEC": "500", "RATE_LIMIT_BURST_MULTIPLIER": "2",
                "ANALYTICS_FLUSH_INTERVAL_SECS": "10", "ANALYTICS_RETENTION_DAYS": "30",
                "ANALYTICS_BUFFER_SIZE": "20000",
            },
            "ports": ["8097:3000"], "depends_on": ["crash-cache-postgres"], "restart": "on-failure",
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
            "ports": ["9004:9004", "9005:9005"],
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
    # Each node's peer port on the host, so Lightning nodes outside the stack
    # can connect and open channels.
    for node, port in (("cln", 19735), ("cln-peer", 29735), ("boltz-cln", 39735)):
        services[node]["ports"] = [f"{port}:9735"]
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
            "SECRET_MAX_LENGTH": "128", "CANARY": "🐦",
            "RATE_LIMIT_COOLDOWN": "1", "RATE_LIMIT_MAX_ATTEMPTS": "3",
            "ATTEMPTS_SNAPSHOT_TTL_SECONDS": "30", "RATE_LIMIT_MEMORY_BUDGET_MB": "512",
        }, "ports": ["8098:3000"],
    }
    # One Boltz URL, as in production: the backend and the sidecar each serve
    # part of the /v2 API, so the gateway routes by path in front of both.
    services["boltz-gateway"] = {
        "image": python_image, "command": ["python3", "/app/gateway.py"],
        "volumes": [str(Path(__file__).with_name("boltz_gateway.py").resolve()) + ":/app/gateway.py:ro"],
        "ports": ["9001:9001"], "depends_on": ["boltz"], "restart": "on-failure",
    }
    services["recoverbull-proxy"] = {
        "image": python_image, "command": ["python3", "/app/proxy.py"],
        "volumes": [str(Path(__file__).with_name("recoverbull_proxy.py").resolve()) + ":/app/proxy.py:ro"],
        "ports": ["59051:9051"], "depends_on": ["recoverbull"],
    }
    for name, service in services.items():
        image = service["image"]
        if image in LOCAL_IMAGES:
            pass
        elif image not in pins:
            run("podman", "pull", image)
            info = json.loads(run("podman", "image", "inspect", image, capture=True))[0]
            pins[image] = info["RepoDigests"][0]
        if image not in LOCAL_IMAGES:
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
                                      "volumes": {name: {} for name in ("cln", "cln-peer", "boltz-cln", "captaind", "ark-postgres", "watchmand", "bark", "bark-peer", "posd-barkd", "posd-postgres", "crash-cache-postgres", "boltz", "boltz-postgres", "recoverbull")}},
                                     sort_keys=False))
    used = {service["image"] for service in services.values()}
    pins = {image: pin for image, pin in pins.items() if pin in used}
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


def ensure_default_wallet():
    """Give bitcoind the unnamed wallet chopsticks needs.

    Core refuses to create a wallet with an empty name but still loads one:
    a wallet.dat at the top of the wallet directory. Create a named wallet
    and move its file there.
    """
    if "" in rpc(False, "listwallets"):
        return
    if not any(item["name"] == "" for item in rpc(False, "listwalletdir")["wallets"]):
        rpc(False, "createwallet", "chopsticks-default")
        rpc(False, "unloadwallet", "chopsticks-default")
        run("podman", "exec", "bull-regtest-bitcoin", "sh", "-c",
            "cd /data/.bitcoin/regtest/wallets && mv chopsticks-default/wallet.dat wallet.dat"
            " && rm -rf chopsticks-default", capture=True)
    rpc(False, "loadwallet", "")


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
    initialize_scuttle()
    initialize_controller()
    wait_services()
    print("Bitcoin, Liquid, Lightning, scuttle (Ark, posd), Boltz, crash-cache and dummy exchange initialized")


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


def initialize_scuttle():
    """Give watchmand its sweep address, posd its wallet, crash-cache a project."""
    try:
        run("podman", "exec", "bull-regtest-watchmand", "test", "-s", "/data/watchmand/sweep_address", capture=True)
    except subprocess.CalledProcessError:
        address = rpc(False, "getnewaddress", wallet="bull-regtest")
        run("podman", "exec", "-i", "bull-regtest-watchmand", "sh", "-c",
            "umask 077; cat > /data/watchmand/sweep_address.tmp && mv /data/watchmand/sweep_address.tmp /data/watchmand/sweep_address",
            stdin=address)
    # The token stays inside posd-barkd's container.
    barkd = ("curl -sf -H \"Authorization: Bearer $(cat /root/.bark/auth_token)\" "
             "-H 'Content-Type: application/json' http://127.0.0.1:3000/api/v1/")
    deadline = time.monotonic() + 120
    while True:
        try:
            wallet = json.loads(run("podman", "exec", "bull-regtest-posd-barkd", "sh", "-c", barkd + "wallet", capture=True))
            break
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            if time.monotonic() > deadline:
                raise RuntimeError("posd's barkd did not start")
            time.sleep(2)
    if wallet.get("fingerprint") is None:
        body = json.dumps({"network": "regtest", "ark_server": "http://captaind:3535",
                           "chain_source": {"esplora": {"url": "http://chopsticks:3000"}}})
        run("podman", "exec", "bull-regtest-posd-barkd", "sh", "-c",
            barkd + "wallet/create -X POST -d '" + body + "'", capture=True)
    dsn = STATE / "crash-cache-dsn"
    if not dsn.exists():
        output = run("podman", "exec", "bull-regtest-crash-cache", "crash-cache", "project", "create",
                     "bull-regtest", capture=True)
        line = next(item for item in output.splitlines() if "DSN" in item)
        # The DSN names the container's own listen address; give the host's.
        value = re.sub(r"@[^/]+/", "@127.0.0.1:8097/", line.split("DSN:", 1)[1].strip(), count=1)
        dsn.write_text(value + "\n")
    print("crash-cache DSN: " + dsn.read_text().strip())


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
            for url in ("http://127.0.0.1:3080/api/v1/openapi.json", "http://127.0.0.1:8097/health"):
                with urllib.request.urlopen(url, timeout=5):
                    pass
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
        for image in LOCAL_IMAGES:
            if subprocess.run(["podman", "image", "exists", image]).returncode != 0:
                raise RuntimeError(f"Build {image} with tools/regtest/build-services.py first")
        prepare()
        # chopsticks exits without Core's unnamed wallet: make it, and the
        # funding wallet, before everything else.
        compose("up", "-d", "bitcoin")
        deadline = time.monotonic() + 180
        while True:
            try:
                ensure_wallet(False, "bull-regtest")
                ensure_default_wallet()
                break
            except subprocess.CalledProcessError:
                if time.monotonic() > deadline:
                    raise RuntimeError("bitcoind did not start")
                time.sleep(2)
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
