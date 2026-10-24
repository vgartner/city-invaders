import unittest
from profile_report import parse_messages


def frame(key=0):
    return {"method": "servers:profile_frame", "data": [10, .02, .01, .005, 1 / 60, .001,
            1, "audio", 2, "mix", .0001, 5, key, 2, .0002, .0005, .0001]}


class NativeProfileTests(unittest.TestCase):
    def test_units_and_server_sections(self):
        messages = [{"method": "servers:function_signature", "data": ["player::switch", 0]}, frame()]
        parsed = parse_messages(messages)["frames"][0]
        self.assertEqual(parsed["frame_ms"], 20)
        self.assertEqual(parsed["functions"][0]["total_ms"], .5)
        self.assertEqual(parsed["functions"][0]["function"], "player::switch")

    def test_signature_ids_restart_per_capture(self):
        messages = [{"method": "capture_start", "label": "before"},
                    {"method": "servers:function_signature", "data": ["cold", 0]}, frame(),
                    {"method": "capture_start", "label": "after"},
                    {"method": "servers:function_signature", "data": ["warm", 0]}, frame()]
        frames = parse_messages(messages)["frames"]
        self.assertEqual([f["functions"][0]["function"] for f in frames], ["cold", "warm"])

    def test_rejects_truncated_function_payload(self):
        message = frame()
        message["data"].pop()
        with self.assertRaises(ValueError):
            parse_messages([message])

    def test_resource_usage(self):
        resources = parse_messages([{"method": "servers:memory_usage",
            "data": [4, "res://texture.png", "2048x2048 RGBA8", "Texture2D", 16777216]}])["resources"]
        self.assertEqual(resources[0]["bytes"], 16777216)


if __name__ == "__main__":
    unittest.main()
