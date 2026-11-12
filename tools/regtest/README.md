# Local regtest stack

This development stack uses rootless Podman and Nigiri's Bitcoin/Liquid configuration. It is intended for disposable regtest funds. The exchange is an in-memory interaction simulator; it does not settle orders or maintain a financial ledger.

Requirements: Nigiri 0.5.17, Podman, podman-compose, Python 3.11 with PyYAML. Images are pinned by digest in `images.json`. Bitcoin Core 31 is used because Bark 0.8.1 requires it. Elements uses Liquid's relay floor of 0.1 sat/vB and accepts discounted confidential transactions, matching the Liquid mainnet/testnet relay defaults and Boltz's fee policy. Bark and Boltz use separate compatible CLN versions, each connected to a shared liquidity peer.

Build the ancillary RecoverBull and Payjoin executables with `python3 tools/regtest/build-services.py` before starting the stack. The builder verifies pinned source revisions and uses Rust 1.99.0 for RecoverBull and Rust 1.95.0 for Payjoin. Install these toolchains explicitly beforehand. Executables, source checkouts and private TLS material stay in the local state directory.

```sh
python3 tools/regtest/stack.py up
python3 tools/regtest/stack.py status
python3 tools/regtest/stack.py mine 1
python3 tools/regtest/stack.py mine --liquid 1
python3 tools/regtest/stack.py faucet ADDRESS AMOUNT_BTC
python3 tools/regtest/stack.py rpc --wallet bull-regtest getbalance
python3 tools/regtest/stack.py ln getinfo
python3 tools/regtest/stack.py bark wallet/balance
python3 tools/regtest/stack.py bark --peer wallet/balance
python3 tools/regtest/stack.py down
```

`up` prepares configuration, starts services, loads the funding and Boltz wallets, funds Boltz and Lightning, establishes bidirectional channels, initializes the Bark provider and two Bark wallets, and waits for indexers and service APIs. `bootstrap` repeats initialization on an already running stack. It preserves wallets and channels, and mines blocks as needed for development funding. `down` preserves volumes and chain state.

State defaults to `~/.local/share/bull-regtest`; override with `BULL_REGTEST_STATE`. Service wallet material stays in Podman volumes. The launcher reads its own Bark API token directly into memory and sends it in the HTTP authorization header. It deliberately refuses mnemonic API routes.

All host ports bind to `127.0.0.1`:

| Service | Endpoint |
| --- | --- |
| Bitcoin RPC | `http://127.0.0.1:18443` |
| Liquid RPC | `http://127.0.0.1:18884` |
| Bitcoin / Liquid Electrum | `tcp://127.0.0.1:50000`, `tcp://127.0.0.1:50001` |
| Bitcoin / Liquid Esplora API | `http://127.0.0.1:30000`, `http://127.0.0.1:30001` |
| Bitcoin / Liquid faucet | `http://127.0.0.1:3000/faucet`, `http://127.0.0.1:3001/faucet` |
| Bitcoin / Liquid explorer | `http://127.0.0.1:5000`, `http://127.0.0.1:5001` |
| Bark provider | `http://127.0.0.1:3535` |
| Bark wallet / peer REST | `http://127.0.0.1:3538`, `http://127.0.0.1:3539` |
| Boltz API | `http://127.0.0.1:9001/v2` |
| Boltz sidecar WS / API | `ws://127.0.0.1:9004`, `http://127.0.0.1:9005` |
| Dummy exchange | `http://127.0.0.1:8088` |
| Integration controller | `http://127.0.0.1:8099` |
| RecoverBull | `http://127.0.0.1:8098` |
| RecoverBull restricted SOCKS proxy | `127.0.0.1:59051` |
| Payjoin mailrooms | `https://localhost:8040`, `https://127.0.0.1:8041` |

RPC credentials are Nigiri's public development defaults `admin1:123`. Boltz's CLN connections use mutual TLS with certificates generated inside its dedicated volume. The default Liquid policy asset is `5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225`, matching the supported native Boltz regtest chain.

The controller verifies both chain networks, funds bounded regtest requests, mines and waits for indexers, and provides Lightning invoice/payment operations without returning preimages. It also serves the public Payjoin test certificate. The two Payjoin mailrooms use the PDK revision pinned by the Dart client and a locally generated certificate. RecoverBull uses its official server behind a SOCKS proxy restricted to the fixture hostname `regtest.recoverbull.onion`; this exercises SOCKS transport without joining Tor.

## Dummy exchange scenarios

The dummy accepts the JSON-RPC calls exercised by BULL account, quote and order models. It provides fixed fake CAD/USD balances and a fixed one-percent quote fee. Each order gets a new ID, including requests that reuse JSON-RPC ID zero. Orders and scenario state disappear when the process restarts.

```sh
curl --fail http://127.0.0.1:8088/health
curl --fail -H 'Content-Type: application/json' -d '{"scenario":"completed"}' http://127.0.0.1:8088/__scenario
```

Scenarios: `pending`, `completed`, `expired`, `rate-limited`, `unavailable`. Optional `DUMMY_BITCOIN_ADDRESS`, `DUMMY_LIQUID_ADDRESS` and `DUMMY_LIGHTNING_INVOICE` environment variables supply development pay-in destinations. A completed response is a simulation, not proof of payment.

## Operational notes

Podman-compose 1.0.3 may recreate dependencies even with `--no-deps --force-recreate`. For a targeted configuration change, remove only the affected container, then run `up -d --no-deps SERVICE`; preserve its volume. If the Bitcoin container is replaced, restart its electrs and Chopsticks consumers because the indexer may retain the old resolved container IP. `status` checks indexer height against its node to detect this condition.

For a physical Android device, keep host services on loopback and use a reserved ADB transport with port forwarding. Do not change Tailscale routes, ACLs or firewall settings to expose development RPCs.

The launcher sets `DBUS_SESSION_BUS_ADDRESS=disabled` only for its Podman commands and their children. Rootless cgroupfs needs no session bus, and disabling autolaunch prevents orphan D-Bus processes from exhausting the shared inotify quota. Set the same environment variable for standalone host tests that invoke Podman. No host session or global configuration is changed.

### Ark wallet fixture

The loopback controller exposes bounded Ark funding, board and offboard operations for the wallet integration runner. It verifies both Bark wallets and providers are on regtest, accepts a confirmed 150,000-sat BULL deposit at a run-owned address, verifies the new 100,000-sat board, transfers that amount to the peer and offboards only the VTXOs received by that run. The final Bitcoin destination belongs to the BULL test wallet. This validates the BULL on-chain boundary with the real Bark provider; it does not claim native Ark custody support in BULL. Controller auth-token volumes are read-only and tokens are never returned.

Run `python3 tools/regtest/ark_smoke.py` to verify this host fixture before the phone journey. Fixtures are serialized and expire after 15 minutes; the controller retains at most 16.

### Android wallet integration

Build only the device ABI with `make android-regtest-debug`, then run `make integration-test-regtest REGTEST_DEVICE=<reserved-adb-serial>`. The regtest debug flavor must identify as `com.bullbitcoin.mobile.regtest.debug`; verify the built APK metadata before installation. Preserve the funded `com.bullbitcoin.mobile.debug` installation and its databases. The runner verifies its application ID before initializing custody, uses a disposable database and generated regtest wallets, and requires loopback ports forwarded through the reserved ADB transport. Remove only forwards owned by that run when releasing the device.

The current work branch uses the agent SDK fork until its seed-compatible Boltz changes are published upstream. The existing `issue_2649` audit intentionally rejects that fork URL; do not weaken it. Before an app PR, publish the Boltz and SDK dependencies upstream and restore the SatoshiPortal SDK URLs. The isolated integration runner configures Payjoin with explicit HTTPS loopback origins on ports 8040/8041 and the public certificate returned by the controller; the default runtime continues to reject regtest. Payjoin sessions store the concrete network in the pending schema 3, with an idempotent repair for the earlier evidence-only schema 3 that preserves existing network evidence. The integration scenarios cover negotiated payments, unfunded participants, concurrent outpoints and reopening the real Payjoin runtime; running the suite on a device is required to validate these scenarios.

Run `fvm dart run tools/regtest/recoverbull_smoke.dart` from the app checkout to verify the pinned RecoverBull client against the actual local server through port `59051`. It stores, fetches and deletes an ephemeral fixture key, with no wallet or key material printed or saved. The server canary must remain `🐦`, as required by the pinned client.
