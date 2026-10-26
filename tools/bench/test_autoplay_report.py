"""Regression tests for separating final position holds from exploration."""
import unittest
from autoplay_report import stationary_tail, pipeline_changes, render_validity


def row(t, x=0, z=0):
    return {"t": t, "x": x, "z": z, "frame_ms": 20}


class PositionHoldTests(unittest.TestCase):
    def test_long_final_hold(self):
        rows = [row(0, 10), row(1, 2), row(2, .2), row(18, .1), row(22)]
        self.assertEqual(stationary_tail(rows), 2)

    def test_brief_stop_is_not_reported(self):
        self.assertIsNone(stationary_tail([row(0, 10), row(10), row(12)]))

    def test_return_to_old_location_is_not_a_contiguous_hold(self):
        self.assertIsNone(stationary_tail([row(0), row(10, 10), row(20)]))

    def test_whole_stationary_recording(self):
        self.assertEqual(stationary_tail([row(0), row(20)]), 0)

    def test_empty_or_single_frame(self):
        self.assertIsNone(stationary_tail([]))
        self.assertIsNone(stationary_tail([row(0)]))


class PipelineCounterTests(unittest.TestCase):
    def test_neighbouring_counter_changes(self):
        rows = [{"pipeline_draw": x} for x in [10, 10, 12, 12]]
        self.assertEqual(pipeline_changes(rows, 1)["pipeline_draw"], 2)
        self.assertEqual(pipeline_changes(rows, 2)["pipeline_draw"], 2)

    def test_old_recordings_have_no_pipeline_fields(self):
        self.assertEqual(pipeline_changes([row(0), row(20)], 0), {})

    def test_counter_reset_is_not_a_negative_compilation(self):
        self.assertEqual(pipeline_changes([{"pipeline_draw": 10}, {"pipeline_draw": 0}], 1)["pipeline_draw"], 0)


class DrawabilityTests(unittest.TestCase):
    def test_old_capture_is_unverified(self):
        self.assertFalse(render_validity({"columns": ["t"], "rows": [[0]]})["known"])

    def test_hidden_interval_rejects_render_comparison(self):
        rec = {"columns": ["window_can_draw"], "rows": [[True], [False], [True]]}
        self.assertEqual(render_validity(rec), {"known": True, "valid": False,
                                               "non_drawable_intervals": 1, "frames": 3})

    def test_visible_capture_and_empty_capture(self):
        self.assertTrue(render_validity({"columns": ["window_can_draw"], "rows": [[True]]})["valid"])
        self.assertFalse(render_validity({"columns": ["window_can_draw"], "rows": []})["known"])

    def test_partial_or_non_boolean_samples_are_not_silently_valid(self):
        for rows in [[[True], []], [[True], [1]], [[True], [None]]]:
            self.assertFalse(render_validity({"columns": ["window_can_draw"], "rows": rows})["known"])


if __name__ == "__main__":
    unittest.main()
