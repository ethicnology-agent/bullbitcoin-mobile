#!/usr/bin/python3
"""Private Rustup proxy: pin stable, preserve BDK, never mutate host tools."""
import os
from pathlib import Path
import subprocess
import sys

real = __RUSTUP_REAL__
pin = __RUST_VERSION__
os.environ["RUSTUP_AUTO_INSTALL"] = "0"
arguments = sys.argv[1:]
tool = Path(sys.argv[0]).name


def channel(value):
    if value == "stable":
        return pin
    if value.startswith("stable-"):
        return pin + value[len("stable"):]
    return value


def output(*args):
    return subprocess.check_output([real, *args], text=True).splitlines()


def satisfied():
    if arguments[:2] == ["toolchain", "install"] and len(arguments) == 3:
        output("run", arguments[2], "rustc", "--version")
        return
    if arguments[:2] in (["target", "add"], ["component", "add"]):
        selected = os.environ.get("RUSTUP_TOOLCHAIN", pin)
        requested = []
        remaining = iter(arguments[2:])
        for value in remaining:
            if value == "--toolchain":
                selected = next(remaining)
            elif value.startswith("-"):
                raise RuntimeError("Unsupported Rustup mutation in a read-only build")
            else:
                requested.append(value)
        installed = output(arguments[0], "list", "--installed", "--toolchain", selected)
        if not requested or any(not any(item == value or item.startswith(value + "-") for item in installed)
                                for value in requested):
            raise RuntimeError("Preinstall the required Rust targets/components before building")
        return
    raise RuntimeError("Rustup mutation is disabled in the private build namespace")


if tool == "rustup":
    if arguments[:1] == ["run"] and len(arguments) >= 2:
        arguments[1] = channel(arguments[1])
    elif arguments[:2] in (["toolchain", "install"], ["toolchain", "uninstall"]):
        if len(arguments) >= 3:
            arguments[2] = channel(arguments[2])
    else:
        for index in range(len(arguments) - 1):
            if arguments[index] == "--toolchain":
                arguments[index + 1] = channel(arguments[index + 1])
    readonly = arguments[:1] in (["run"], ["show"], ["which"], ["--version"], ["-V"], ["help"])
    readonly |= arguments[:2] in (["toolchain", "list"], ["target", "list"], ["component", "list"])
    if not readonly:
        satisfied()
        sys.exit(0)
else:
    if arguments and arguments[0].startswith("+"):
        arguments[0] = "+" + channel(arguments[0][1:])

# argv[0] retains cargo/rustc proxy dispatch. Python preserves CC_* names
# containing hyphens, unlike a POSIX sh wrapper.
os.execve(real, [tool, *arguments], os.environ)
