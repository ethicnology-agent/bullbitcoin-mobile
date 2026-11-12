#!/usr/bin/env python3
"""Run a build with a private Rustup bind mount; leave host tools unchanged."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inside(directory, command):
    metadata = json.loads((directory / "metadata.json").read_text())
    namespace = os.readlink("/proc/self/ns/mnt")
    if namespace == metadata["namespace"] or os.getuid() != metadata["uid"]:
        raise RuntimeError("A private mount namespace with the original UID is required")
    (directory / "namespace").write_text(namespace)
    executable = Path(metadata["rustup"])
    subprocess.run(["mount", "--bind", str(directory / "proxy"), str(executable)], check=True)
    if executable.stat().st_ino != (directory / "proxy").stat().st_ino:
        raise RuntimeError("The private Rustup bind did not take effect")
    environment = {**os.environ, "RUSTUP_TOOLCHAIN": metadata["version"], "RUSTUP_AUTO_INSTALL": "0",
                   "BULL_REGTEST_RUST_DIRECTORY": str(directory), "BULL_REGTEST_RUST_VERSION": metadata["version"]}
    checks = [(["rustc", "--version"], metadata["version"]),
              ([str(executable), "run", "stable", "rustc", "--version"], metadata["version"]),
              ([str(executable), "run", "stable-x86_64-unknown-linux-gnu", "rustc", "--version"], metadata["version"]),
              (["rustc", "+stable", "--version"], metadata["version"]),
              ([str(executable), "run", "1.85.1", "rustc", "--version"], "1.85.1")]
    for arguments, expected in checks:
        actual = subprocess.check_output(arguments, env=environment, text=True).strip()
        if not actual.startswith(f"rustc {expected} "):
            raise RuntimeError("The actual Rust compiler does not match the build pin")
        print(actual, flush=True)
    return subprocess.run(command, env=environment).returncode


def clean_namespace(namespace):
    def owned():
        result = []
        for process in Path("/proc").iterdir():
            if not process.name.isdigit():
                continue
            try:
                if process.stat().st_uid == os.getuid() and os.readlink(process / "ns/mnt") == namespace:
                    result.append(int(process.name))
            except (OSError, PermissionError):
                pass
        return result
    for pid in owned():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 10
    while owned() and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid in owned():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inside", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("Provide the build command after --")
    if args.inside:
        return inside(args.inside, command)
    executable = Path.home() / ".cargo/bin/rustup"
    if executable.read_bytes()[:4] != b"\x7fELF":
        raise RuntimeError("Use this wrapper with the host Rustup binary, or use the project tool image")
    version = re.search(r'ARG RUST_VERSION="([0-9.]+)"', Path("Containerfile.tools").read_text())[1]
    original = digest(executable)
    with tempfile.TemporaryDirectory(prefix="bull-regtest-rust-") as temporary:
        directory = Path(temporary)
        shutil.copy2(executable, directory / "rustup.real")
        proxy = Path(__file__).with_name("pinned_rust_proxy.py").read_text()
        proxy = proxy.replace("__RUSTUP_REAL__", repr(str(directory / "rustup.real")))
        proxy = proxy.replace("__RUST_VERSION__", repr(version))
        (directory / "proxy").write_text(proxy)
        (directory / "proxy").chmod(0o700)
        (directory / "metadata.json").write_text(json.dumps({
            "uid": os.getuid(), "namespace": os.readlink("/proc/self/ns/mnt"),
            "rustup": str(executable), "version": version,
        }))
        try:
            result = subprocess.run(["unshare", "--user", "--map-current-user", "--mount", "--keep-caps",
                                     "--propagation", "private", sys.executable, str(Path(__file__).resolve()),
                                     "--inside", str(directory), "--", *command]).returncode
        finally:
            if (directory / "namespace").exists():
                clean_namespace((directory / "namespace").read_text())
        if digest(executable) != original:
            raise RuntimeError("The host Rustup changed outside the private build namespace")
        return result


if __name__ == "__main__":
    sys.exit(main())
