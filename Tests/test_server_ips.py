import contextlib
from http.client import IncompleteRead
import io
import ipaddress
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import URLError

from Scripts import server_ips


EXAMPLE_URL = "https://inventory.example.com/servers.json"


class ServerIPsTests(unittest.TestCase):
    def run_script(self, payload, *args):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(server_ips, "urlopen", return_value=io.BytesIO(payload)) as fetch:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                result = server_ips.main([EXAMPLE_URL, *args])
        fetch.assert_called_once_with(EXAMPLE_URL, timeout=30)
        return result, output.getvalue(), errors.getvalue()

    def test_raw_output_preserves_order_duplicates_and_ipv6_spelling(self):
        payload = {
            "server-a": {"ip_all": "192.0.2.7, 2001:0db8::1,192.0.2.7"},
            "server-b": {"ip_all": "192.0.2.4"},
            "server-c": {"ip_all": ""},
        }
        result, output, errors = self.run_script(json.dumps(payload).encode())
        self.assertEqual(result, 0)
        self.assertEqual(output, "192.0.2.7\n2001:0db8::1\n192.0.2.7\n192.0.2.4\n")
        self.assertEqual(errors, "")

    def test_merge_is_exact_for_both_families_and_does_not_fill_gaps(self):
        addresses = [
            "192.0.2.7", "192.0.2.4", "192.0.2.6", "192.0.2.5", "192.0.2.4",
            "192.0.2.10", "192.0.2.12", "2001:db8::2", "2001:db8::3",
        ]
        result, output, errors = self.run_script(
            json.dumps({"server": {"ip_all": ",".join(addresses)}}).encode(), "--merge"
        )
        self.assertEqual(result, 0)
        self.assertEqual(errors, "")
        self.assertEqual(output.splitlines(), [
            "192.0.2.4/30", "192.0.2.10/32", "192.0.2.12/32", "2001:db8::2/127",
        ])
        covered = {address for prefix in output.splitlines() for address in ipaddress.ip_network(prefix)}
        self.assertEqual(covered, {ipaddress.ip_address(address) for address in addresses})

    def test_invalid_or_empty_inventory_fails_without_partial_output(self):
        for payload in [
            b"not JSON", b"null", b"{}", b'{"server": {"ip_all": ""}}',
            b'{"server": {"ip_all": "192.0.2.1,not-an-ip"}}',
            b'{"server": {"ip_all": ["192.0.2.1"]}}',
            b'{"good": {"ip_all": "192.0.2.1"}, "missing": {}}',
            b'{"server": {"ip_all": "192.0.2.1,fe80::1%en0"}}',
            b'[{"ip_all": "192.0.2.1"}]',
        ]:
            with self.subTest(payload=payload):
                result, output, errors = self.run_script(payload)
                self.assertEqual(result, 1)
                self.assertEqual(output, "")
                self.assertTrue(errors.startswith("Error: "))

    def test_network_error_is_reported_without_a_traceback(self):
        for error in [URLError("unavailable"), IncompleteRead(b"{", 10)]:
            with self.subTest(error=error):
                output, errors = io.StringIO(), io.StringIO()
                with patch.object(server_ips, "urlopen", side_effect=error):
                    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                        result = server_ips.main([EXAMPLE_URL])
                self.assertEqual(result, 1)
                self.assertEqual(output.getvalue(), "")
                self.assertTrue(errors.getvalue().startswith("Error: "))
                self.assertNotIn("Traceback", errors.getvalue())

    def test_bundled_example_runs_without_network_access(self):
        example = Path(__file__).resolve().parents[1] / "Scripts/examples/servers.json"
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = server_ips.main([example.as_uri(), "--merge"])
        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue(), "192.0.2.4/30\n2001:db8::2/127\n")
        self.assertEqual(errors.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
