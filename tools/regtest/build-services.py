#!/usr/bin/env python3
"""Build the pinned ancillary services without changing global toolchains."""

import os
from pathlib import Path
import shutil
import subprocess

import stack


def run(*command, cwd=None, env=None):
    subprocess.run(command, cwd=cwd, env=env, check=True)


def source(name, url, revision):
    directory = stack.STATE / "sources" / name
    if not directory.exists():
        directory.mkdir(parents=True)
        run("git", "init", str(directory))
        run("git", "-C", str(directory), "fetch", "--depth=1", url, revision)
        run("git", "-C", str(directory), "checkout", "--detach", "FETCH_HEAD")
    actual = subprocess.check_output(["git", "-C", str(directory), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise RuntimeError(f"Preserve existing {name} checkout: a different revision is checked out")
    return directory


def main():
    server = source("recoverbull-server", "https://github.com/SatoshiPortal/recoverbull-server.git",
                    "cf1e8c5e40e0ce30a402e6f71d6bad5208b1f464")
    environment = {**os.environ, "CARGO_BUILD_JOBS": "2"}
    run("cargo", "+1.99.0", "build", "--locked", cwd=server,
        env={**environment, "CARGO_TARGET_DIR": str(server / "target")})
    mailrooms = Path(__file__).with_name("payjoin_mailrooms")
    target = stack.STATE / "build/mailrooms"
    run("cargo", "+1.95.0", "build", "--locked", "--manifest-path", str(mailrooms / "Cargo.toml"),
        env={**environment, "CARGO_TARGET_DIR": str(target)})
    binaries = stack.STATE / "bin"
    binaries.mkdir(parents=True, exist_ok=True)
    for original, name in ((server / "target/debug/recoverbull", "recoverbull"),
                           (target / "debug/bull-regtest-mailrooms", "mailrooms")):
        temporary = binaries / (name + ".tmp")
        shutil.copy2(original, temporary)
        temporary.replace(binaries / name)
    stack.prepare_certificates()


if __name__ == "__main__":
    main()
