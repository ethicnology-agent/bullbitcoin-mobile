"""Verify fresh configuration without starting or changing any containers."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


class StackConfigurationTest(unittest.TestCase):
    def invoke(self, directory, command):
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("stack.py")), command],
            env={**os.environ, "BULL_REGTEST_STATE": directory},
            capture_output=True, text=True, timeout=20,
        )

    def test_fresh_prepare_pins_images_and_keeps_every_host_port_on_loopback(self):
        with tempfile.TemporaryDirectory(prefix="bull-regtest-config-") as directory:
            first = self.invoke(directory, "prepare")
            self.assertEqual(first.returncode, 0, first.stderr)
            configuration = Path(directory) / "compose.yml"
            original = configuration.read_text()
            second = self.invoke(directory, "prepare")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(configuration.read_text(), original)
            services = yaml.safe_load(original)["services"]
            for name, service in services.items():
                with self.subTest(service=name):
                    self.assertIn("@sha256:", service["image"])
                    for port in service.get("ports", []):
                        self.assertTrue(port.startswith("127.0.0.1:"))
            self.assertEqual(
                services["recoverbull-proxy"]["ports"],
                ["127.0.0.1:59051:9051"],
            )
            self.assertIn("-acceptdiscountct=1", services["liquid"]["command"])
            self.assertEqual(services["bitcoin"]["user"], "0:0")

    def test_up_refuses_missing_ancillary_binaries_before_preparing_resources(self):
        with tempfile.TemporaryDirectory(prefix="bull-regtest-preflight-") as directory:
            result = self.invoke(directory, "up")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("build-services.py first", result.stderr)
            self.assertFalse((Path(directory) / "compose.yml").exists())
            self.assertFalse((Path(directory) / "nigiri").exists())


if __name__ == "__main__":
    unittest.main()
