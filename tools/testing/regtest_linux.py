#!/usr/bin/env python3
"""Run the real GTK integration app with a private Secret Service and data."""

import argparse
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from xml.sax.saxutils import escape


def call(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE, timeout=5).strip()


def dbus(path, method, *arguments):
    return call("gdbus", "call", "--session", "--dest", "org.freedesktop.secrets",
                "--object-path", path, "--method", method, *arguments)


def run_session(root, target):
    if root.resolve() != root or root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077:
        raise RuntimeError("The integration root is not private and owned")
    if os.environ.get("BULL_REGTEST_RUN_DIRECTORY") != str(root):
        raise RuntimeError("Start the parent Linux integration runner")
    for name, child in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")):
        path = root / child
        if os.environ.get(name) != str(path) or path.resolve() != path or path.stat().st_uid != os.getuid():
            raise RuntimeError("The integration paths escaped their private root")
    keyrings = root / "data/keyrings"
    if keyrings.resolve() != keyrings or keyrings.stat().st_mode & 0o077:
        raise RuntimeError("The private keyring directory is not ready")
    address = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not re.fullmatch(re.escape(f"unix:path={root}/bus") + r"(?:,guid=[a-f0-9]+)?", address):
        raise RuntimeError("The integration session bus is not private")
    if not stat.S_ISSOCK((root / "bus").stat().st_mode) or os.environ.get("GNOME_KEYRING_CONTROL"):
        raise RuntimeError("The integration bus or keyring control is not isolated")
    daemon = subprocess.Popen([
        "gnome-keyring-daemon", "--foreground", "--unlock", "--components=secrets",
        "--control-directory", str(root / "keyring-control"),
    ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        daemon.stdin.write(secrets.token_hex(32).encode())
        daemon.stdin.close()
        deadline = time.monotonic() + 15
        while True:
            if daemon.poll() is not None:
                raise RuntimeError("The private keyring daemon exited before verification")
            try:
                owner = call("gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
                             "--object-path", "/org/freedesktop/DBus", "--method",
                             "org.freedesktop.DBus.GetConnectionUnixProcessID", "org.freedesktop.secrets")
                found = re.fullmatch(r"\(uint32 (\d+),\)", owner)
                if found is None or int(found[1]) != daemon.pid:
                    raise RuntimeError("Secret Service is not owned by this runner")
                alias = dbus("/org/freedesktop/secrets", "org.freedesktop.Secret.Service.ReadAlias", "default")
                collection = re.fullmatch(r"\(objectpath '([^']+)',\)", alias)
                if collection is None or collection[1] == "/":
                    if time.monotonic() < deadline:
                        time.sleep(0.1)
                        continue
                    raise RuntimeError("The private default keyring is unavailable")
                locked = dbus(collection[1], "org.freedesktop.DBus.Properties.Get",
                              "org.freedesktop.Secret.Collection", "Locked")
                if locked != "(<false>,)":
                    if time.monotonic() < deadline:
                        time.sleep(0.1)
                        continue
                    raise RuntimeError("The private default keyring is locked")
                break
            except subprocess.CalledProcessError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("The private Secret Service did not become ready") from None
                time.sleep(0.1)
        # A disposable canary verifies read/write access without querying BULL's
        # attributes or any host collection. The private bus has no activators.
        previous = subprocess.run(["secret-tool", "lookup", "fixture", "bull-regtest"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if previous.returncode != 1:
            raise RuntimeError("A fresh private keyring unexpectedly contained the isolation canary")
        subprocess.run(["secret-tool", "store", "--label=BULL regtest isolation", "fixture", "bull-regtest"],
                       input=b"fixture-only", check=True, stdout=subprocess.DEVNULL)
        if call("secret-tool", "lookup", "fixture", "bull-regtest") != "fixture-only":
            raise RuntimeError("Private Secret Service canary did not round-trip")
        subprocess.run(["fvm", "dart", "run", "tools/gen_all_test.dart"], check=True)
        return subprocess.run([
            "fvm", "flutter", "test", "--no-pub", target, "-d", "linux",
            "--dart-define=BULL_REGTEST_VALIDATION=true", "--reporter=expanded",
        ]).returncode
    finally:
        if daemon.poll() is None:
            daemon.terminate()
            try:
                daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default="integration_test/all_test.dart")
    parser.add_argument("--session", type=Path)
    args = parser.parse_args()
    for binary in ("fvm", "clang++", "cmake", "ninja", "pkg-config", "xvfb-run", "dbus-run-session",
                   "gnome-keyring-daemon", "gdbus", "secret-tool", "xdg-user-dir"):
        if shutil.which(binary) is None:
            raise RuntimeError(f"Install the project's Linux integration prerequisite: {binary}")
    java = os.environ.get("JAVA_HOME")
    if java is None or not (Path(java) / "include/jni.h").is_file():
        raise RuntimeError("Set JAVA_HOME to the project's pinned JDK before running the JNI plugins")
    target = Path(args.target)
    if target.parent != Path("integration_test") or not target.name.endswith("_test.dart"):
        raise ValueError("Select an integration_test/*_test.dart entrypoint")
    if args.session is not None:
        return run_session(args.session, args.target)
    with tempfile.TemporaryDirectory(prefix="bull-regtest-integration-") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        for path in ("data", "data/keyrings", "config", "cache", "runtime", "documents", "tmp", "keyring-control"):
            (root / path).mkdir(mode=0o700, exist_ok=True)
        (root / "config/user-dirs.dirs").write_text(f'XDG_DOCUMENTS_DIR="{root}/documents"\n')
        config = root / "dbus.conf"
        # No service directories: no host daemon may be activated on this bus.
        config.write_text(
            '<busconfig><type>session</type><listen>unix:path=' + escape(str(root / 'bus')) +
            '</listen><auth>EXTERNAL</auth><policy context="default">'
            '<allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/>'
            '</policy></busconfig>'
        )
        environment = dict(os.environ)
        for name in ("GNOME_KEYRING_CONTROL", "DBUS_SESSION_BUS_ADDRESS", "DBUS_STARTER_ADDRESS",
                     "DBUS_STARTER_BUS_TYPE", "TEST_ALICE_MNEMONIC", "TEST_BOB_MNEMONIC"):
            environment.pop(name, None)
        environment.update({
            "XDG_DATA_HOME": str(root / "data"), "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_CACHE_HOME": str(root / "cache"), "XDG_RUNTIME_DIR": str(root / "runtime"),
            "TMPDIR": str(root / "tmp"), "BULL_REGTEST_RUN_DIRECTORY": str(root),
            "GSETTINGS_BACKEND": "memory", "NO_AT_BRIDGE": "1", "GDK_BACKEND": "x11",
        })
        command = ["xvfb-run", "--auto-servernum", "--auth-file", str(root / ".Xauthority"),
                   "dbus-run-session", "--config-file", str(config), "--",
                   sys.executable, str(Path(__file__).resolve()), "--session", str(root),
                   "--target", args.target]
        process = subprocess.Popen(command, env=environment, start_new_session=True)
        try:
            return process.wait(timeout=3600)
        finally:
            # Only this runner's process group, including its private display.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


if __name__ == "__main__":
    sys.exit(main())
