"""Scene-data contract and protection of the owner's game."""
import contextlib
import io
import json
import math
from pathlib import Path
import unittest
from unittest.mock import patch
import stage


class StageTests(unittest.TestCase):
    def test_presets_and_timeline(self):
        scenes = json.loads((Path(__file__).parents[2] / 'godot/data/video_scenes.json').read_text())
        self.assertEqual(set(scenes), {'usina_walk', 'street_battle', 'grenades_swarm', 'drone_lasso'})
        for scene in scenes.values():
            self.assertEqual(scene['map'], 'gasometro')
            self.assertEqual(len(scene['position']), 3)
            self.assertTrue(all(math.isfinite(x) for x in scene['position']))
            if 'take' not in scene:
                continue
            take = scene['take']
            times = [key['t'] for key in take['look']]
            self.assertEqual(times[0], 0)
            self.assertEqual(times[-1], take['duration_s'])
            self.assertTrue(all(b > a for a, b in zip(times, times[1:])))
            for cue in take['walk']:
                self.assertTrue(0 <= cue['start'] < cue['end'] <= take['duration_s'])
                self.assertTrue(0 < cue['ramp_s'] <= (cue['end'] - cue['start']) / 2)
                self.assertTrue(0 < cue['speed_fraction'] <= 1)

    def test_pickup_route_has_real_targets_and_no_overlapping_walk_cues(self):
        scene = json.loads((Path(__file__).parents[2] / 'godot/data/video_scenes.json').read_text())['usina_walk']
        take = scene['take']
        self.assertEqual(take['expect_pickups'], ['fruki', 'pala'])
        self.assertEqual([cue['pickup'] for cue in take['approach']], take['expect_pickups'])
        self.assertEqual({item['kind'] for item in scene['pickups']}, set(take['expect_pickups']))
        cues = sorted(take['walk'] + take['approach'], key=lambda cue: cue['start'])
        for a, b in zip(cues, cues[1:]):
            self.assertLessEqual(a['end'], b['start'])
        for cue in take['approach']:
            self.assertTrue(0 < cue['speed_mps'] <= 5)
            self.assertTrue(0 <= cue['start'] < cue['end'] <= take['duration_s'])

    def test_player_port_is_protected_before_connecting(self):
        with patch('sys.argv', ['stage.py', 'usina_walk', '--port', '24690']), patch('stage.DevAgent') as client:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stopped:
                stage.main()
            self.assertEqual(stopped.exception.code, 2)
            client.assert_not_called()

    def test_readonly_listing_uses_safe_default_port(self):
        with patch('sys.argv', ['stage.py', '--list']), patch('stage.DevAgent') as client:
            client.return_value.call.return_value = {'scenes': {}}
            stage.main()
            client.assert_called_once_with(port=24691, timeout=240)
            client.return_value.call.assert_called_once_with('stage')


if __name__ == '__main__':
    unittest.main()
