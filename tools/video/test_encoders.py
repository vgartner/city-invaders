"""Portable encoder acceptance tests, using generated media rather than game assets."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from ffmpeg_backend import FFmpegBackend, select_encoder
from render_presentation import movie_index, verify_refinements
from audio_master import master, measure, verify


class InteractionQATests(unittest.TestCase):
    def test_drone_damage_must_happen_during_the_attack(self):
        take = dict(scene='film_drone', samples=[
            dict(t=0, drone=[0, 55, -20], drone_target=dict(health=100)),
            dict(t=10, drone=[0, 55, -20], drone_target=dict(health=50)),
            dict(t=16, drone=[0, 55, -20], drone_target=dict(health=50)),
            dict(t=19, drone=[0, 55, -20], drone_target=dict(health=50)),
        ])
        with self.assertRaisesRegex(AssertionError, 'during the drone attack'):
            verify_refinements(take)
        take['samples'][-1]['drone_target']['health'] = 30
        verify_refinements(take)


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe') and importlib.util.find_spec('PIL'),
                     'FFmpeg, FFprobe and Pillow are required')
class PortableEncoderTests(unittest.TestCase):
    def test_auto_falls_back_without_macos_tools(self):
        with patch('ffmpeg_backend.sys.platform', 'linux'):
            self.assertEqual(select_encoder('auto'), 'ffmpeg')
            with self.assertRaisesRegex(RuntimeError, 'macOS'):
                select_encoder('avfoundation')
        self.assertEqual(select_encoder('ffmpeg'), 'ffmpeg')

    def test_missing_tools_fail_before_recording(self):
        with patch('ffmpeg_backend.shutil.which', return_value=None):
            with self.assertRaisesRegex(RuntimeError, 'ffmpeg and ffprobe'):
                select_encoder('ffmpeg')

    def test_audio_quality_gate_rejects_clipping_and_wrong_loudness(self):
        with self.assertRaisesRegex(RuntimeError, '-1 dBTP'):
            verify(dict(true_peak_dbtp=0, integrated_lufs=-16))
        with self.assertRaisesRegex(RuntimeError, 'LUFS'):
            verify(dict(true_peak_dbtp=-2, integrated_lufs=-30))

    def test_marker_trim_captions_audio_fades_and_decoded_frames(self):
        from PIL import Image, ImageStat
        with tempfile.TemporaryDirectory(prefix='video-encoder-') as directory:
            root = Path(directory)
            backend = FFmpegBackend()
            raw = root/'raw.avi'
            backend.run([backend.ffmpeg, '-hide_banner', '-nostdin', '-y', '-f', 'lavfi', '-i',
                         'testsrc2=size=320x180:rate=30:duration=2', '-f', 'lavfi', '-i',
                         'sine=frequency=440:duration=2', '-c:v', 'mjpeg', '-q:v', 4, '-pix_fmt', 'yuvj420p',
                         '-c:a', 'pcm_s16le', '-ac', 2, '-shortest', raw], root/'fixture.log')
            take = root/'source_take.json'
            take.write_text(json.dumps(dict(scene='fixture', missing_pickups=[], events=[])))
            log = root/'game.log'
            log.write_text('VIDEO_TAKE_START {"drawn_frame":15}\nVIDEO_TAKE_END '+json.dumps({'log': str(take)})+'\n')
            movie_index(raw, log, 1, root)
            index = json.loads((root/'index.json').read_text())
            self.assertEqual(len(index['frames']), 30)
            self.assertGreater(index['frames'][0][0], 0)
            capture = json.loads((root/'capture_qa.json').read_text())
            self.assertGreater(capture['audio_rms'], 100)
            clips = []
            for i in range(2):
                folder = root/str(i); folder.mkdir()
                clip = folder/'clip.mp4'
                backend.encode(raw, root/'index.json', root/'audio.wav', clip, 'Porto Alegre', 'Vídeo de teste')
                audit = backend.audit(clip)
                (folder/'audit.json').write_text(json.dumps(audit))
                self.assertEqual(audit['frames'], 30)
                self.assertEqual(audit['audio_tracks'], 1)
                self.assertEqual((audit['width'], audit['height']), (320, 180))
                self.assertAlmostEqual(audit['duration_s'], 1, places=3)
                clips.append(clip)
            final = root/'final.mp4'
            backend.join(clips, final)
            audit = backend.audit(final)
            self.assertEqual(audit['frames'], 60)
            self.assertEqual(audit['fps'], 30)
            self.assertAlmostEqual(audit['container_duration_s'], 2, places=3)
            self.assertEqual(audit['audio_tracks'], 1)
            mastered = root/'mastered.mp4'
            audio = master(final, mastered, 2)
            verify(audio['after'])
            self.assertLessEqual(audio['after']['true_peak_dbtp'], -1.0)
            self.assertAlmostEqual(audio['after']['integrated_lufs'], -16, delta=1)
            mastered_audit = backend.audit(mastered)
            self.assertEqual(mastered_audit['frames'], 60)
            self.assertAlmostEqual(mastered_audit['container_duration_s'], 2, places=3)
            boundary = root/'cut.png'
            backend.frame(final, 1, boundary)
            self.assertLess(max(ImageStat.Stat(Image.open(boundary).convert('RGB')).mean), 2)


if __name__ == '__main__':
    unittest.main()
