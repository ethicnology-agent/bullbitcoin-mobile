"""Check that a headless Podman command leaves no private D-Bus daemon."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
from uuid import uuid4


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launcher", type=Path, default=Path(__file__).with_name("stack.py"))
    launcher = parser.parse_args().launcher.resolve()
    marker = str(uuid4())
    environment = {**os.environ, "BULL_REGTEST_DBUS_PROBE": marker}
    environment.pop("DBUS_SESSION_BUS_ADDRESS", None)
    result = subprocess.run(
        [sys.executable, "-c",
         "import importlib.util,sys; "
         "spec=importlib.util.spec_from_file_location('fixture',sys.argv[1]); "
         "module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); "
         "module.run('podman','ps','--format','{{.Names}}',capture=True)", str(launcher)],
        env=environment, capture_output=True, timeout=20,
    )
    orphans = []
    for process in Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            if (process / "comm").read_text().strip() != "dbus-daemon":
                continue
            values = (process / "environ").read_bytes().split(b"\0")
            if ("BULL_REGTEST_DBUS_PROBE=" + marker).encode() not in values:
                continue
            if (process / "status").read_text().split("PPid:")[1].splitlines()[0].strip() != "1":
                continue
            orphans.append(int(process.name))
            # This unique marker belongs only to the completed probe command.
            os.kill(int(process.name), signal.SIGTERM)
        except OSError:
            pass
    if result.returncode:
        raise RuntimeError("The read-only Podman probe failed")
    if orphans:
        raise RuntimeError(f"The completed Podman probe left {len(orphans)} D-Bus orphan(s)")
    print("Headless Podman completed without a surviving private D-Bus daemon")


if __name__ == "__main__":
    main()
