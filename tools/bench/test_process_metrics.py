import ctypes
import os
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO

from process_metrics import ProcessMetrics, RUsageV2
from autoplay_bench import capture
from autoplay_report import companion_path, counter_delta, print_diagnostics


class MetricsTests(unittest.TestCase):
    def test_apple_v2_layout(self):
        self.assertEqual(ctypes.sizeof(RUsageV2), 160)
        self.assertEqual(RUsageV2.phys_footprint.offset, 72)
        self.assertEqual(RUsageV2.diskio_bytesread.offset, 144)

    @unittest.skipUnless(sys.platform == "darwin", "macOS native sampler")
    def test_real_process_memory(self):
        result = ProcessMetrics(os.getpid()).sample()
        self.assertTrue(result["available"], result)
        self.assertGreater(result["footprint_mb"], 0)
        self.assertGreater(result["rss_mb"], 0)

    def test_missing_or_reset_counters_not_reported_as_zero(self):
        self.assertIsNone(counter_delta([], "pageins"))
        self.assertIsNone(counter_delta([{"available": True, "pageins": n} for n in (10, 5)], "pageins"))
        self.assertEqual(counter_delta([{"available": True, "pageins": n} for n in (10, 15)], "pageins"), 5)

    def test_portable_recording_path(self):
        self.assertEqual(companion_path("/tmp/run/run.json", "recording.json"), "/tmp/run/recording.json")
        self.assertEqual(companion_path("/tmp/run/run.json", "/old/recording.json"), "/old/recording.json")

    def test_unavailable_gpu_and_old_captures(self):
        buffer = StringIO()
        with redirect_stdout(buffer):
            print_diagnostics({"counts": {}}, {"telemetry": [{"gpu_ms": None, "nodes_by_type": {}}]}, "/tmp/run.json")
            print_diagnostics({"counts": {}}, {}, "/tmp/old.json")
        self.assertIn("0/1 usable", buffer.getvalue())
        self.assertIn("not recorded in this older run", buffer.getvalue())

    def test_runner_does_not_touch_another_active_run(self):
        class OtherRun:
            def __init__(self):
                self.calls = []
            def call(self, method, **params):
                self.calls.append(method)
                return {"active": True}
        agent = OtherRun()
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "new"
            with self.assertRaises(RuntimeError):
                capture(agent, output)
            self.assertFalse(output.exists())
        self.assertEqual(agent.calls, ["autoplay_status"])


if __name__ == "__main__":
    unittest.main()
