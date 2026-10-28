"""Portable encoding of indexed Movie Maker frames with the game's trimmed WAV."""
import json
import os
from fractions import Fraction
from pathlib import Path
import shutil
import subprocess
import sys


def select_encoder(requested):
    native = sys.platform == 'darwin' and Path('/usr/bin/swiftc').exists() and Path('/usr/bin/avconvert').exists()
    choice = ('avfoundation' if native else 'ffmpeg') if requested == 'auto' else requested
    if choice == 'avfoundation' and not native:
        raise RuntimeError('AVFoundation needs macOS, swiftc and avconvert; use --encoder ffmpeg')
    if choice == 'ffmpeg' and not (shutil.which('ffmpeg') and shutil.which('ffprobe')):
        raise RuntimeError('Install ffmpeg and ffprobe on PATH to use --encoder ffmpeg')
    return choice


class FFmpegBackend:
    def __init__(self, font=None):
        self.ffmpeg = shutil.which('ffmpeg')
        self.ffprobe = shutil.which('ffprobe')
        self.font = font

    def run(self, args, log):
        with Path(log).open('w') as output:
            subprocess.run(list(map(str, args)), stdout=output, stderr=subprocess.STDOUT, check=True)

    def caption(self, path, meta, title, subtitle):
        from PIL import Image, ImageDraw, ImageFont
        candidates = [self.font, '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
                      str(Path(os.environ.get('WINDIR', 'C:/Windows')) / 'Fonts/arialbd.ttf'),
                      '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 'DejaVuSans-Bold.ttf']
        scale = meta['width'] / 1920
        for candidate in filter(None, candidates):
            try:
                large = ImageFont.truetype(str(candidate), max(10, round(44 * scale)))
                small = ImageFont.truetype(str(candidate), max(8, round(25 * scale)))
                break
            except OSError:
                continue
        else:
            raise RuntimeError('No caption font found; pass --font /path/to/font.ttf')
        image = Image.new('RGBA', (meta['width'], meta['height']))
        draw = ImageDraw.Draw(image)
        h = meta['height']
        draw.rectangle((40*scale, h-275*scale, 1190*scale, h-150*scale), fill=(5, 5, 5, 184))
        draw.text((65*scale, h-262*scale), title, font=large, fill='white')
        draw.text((65*scale, h-205*scale), subtitle, font=small, fill='white')
        image.save(path)

    def encode(self, raw, index, audio, clip, title, subtitle):
        meta = json.loads(Path(index).read_text())
        frames, fps = meta['frames'], meta['fps']
        caption = clip.parent / 'caption.png'
        self.caption(caption, meta, title, subtitle)
        enable = '1' if title == 'CITY INVADERS' else 'lt(t,4)'
        graph = f"[1:v]format=rgba,fade=t=in:st=0:d=0.333333:alpha=1[c];[0:v][c]overlay=0:0:shortest=1:enable='{enable}'[v]"
        args = [self.ffmpeg, '-hide_banner', '-nostdin', '-y', '-f', 'image2pipe', '-framerate', fps,
                '-c:v', 'mjpeg', '-i', 'pipe:0', '-loop', 1, '-framerate', fps, '-i', caption,
                '-i', audio, '-filter_complex_threads', 1, '-filter_complex', graph,
                '-map', '[v]', '-map', '2:a:0', '-c:v', 'libx264', '-preset', 'fast', '-crf', 20,
                '-threads', 4, '-pix_fmt', 'yuv420p', '-r', fps, '-frames:v', len(frames),
                '-c:a', 'aac', '-b:a', '192k', '-ar', 48000, '-t', len(frames)/fps,
                '-movflags', '+faststart', clip]
        with Path(raw).open('rb') as source, (clip.parent/'encode.log').open('w') as log:
            process = subprocess.Popen(list(map(str, args)), stdin=subprocess.PIPE, stdout=log, stderr=log)
            try:
                for offset, size in frames:
                    source.seek(offset)
                    process.stdin.write(source.read(size))
            finally:
                process.stdin.close()
                status = process.wait()
            if status:
                raise subprocess.CalledProcessError(status, args)

    def audit(self, path):
        result = subprocess.run([self.ffprobe, '-v', 'error', '-count_frames', '-show_streams',
                                 '-show_format', '-of', 'json', str(path)], capture_output=True, text=True, check=True)
        info = json.loads(result.stdout)
        video = next(s for s in info['streams'] if s['codec_type'] == 'video')
        audio = [s for s in info['streams'] if s['codec_type'] == 'audio']
        # Decode both streams strictly: readable metadata is not a successful encode.
        self.run([self.ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-xerror', '-err_detect', 'explode',
                  '-i', path, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'], Path(path).with_suffix('.decode.log'))
        assert audio and all(int(s.get('nb_read_frames', 0)) > 0 for s in audio), 'Empty audio track'
        return dict(duration_s=float(video['duration']), container_duration_s=float(info['format']['duration']),
                    frames=int(video['nb_read_frames']), fps=float(Fraction(video['avg_frame_rate'])),
                    width=video['width'], height=video['height'], audio_tracks=len(audio))

    def frame(self, path, seconds, destination):
        # Decode from the start and select the requested frame, not a nearby keyframe.
        self.run([self.ffmpeg, '-hide_banner', '-nostdin', '-y', '-i', path, '-ss', seconds,
                  '-frames:v', 1, '-update', 1, destination], Path(destination).with_suffix('.log'))

    def join(self, clips, destination):
        args = [self.ffmpeg, '-hide_banner', '-nostdin', '-y']
        graph, order, total = [], [], 0.0
        for i, clip in enumerate(clips):
            args += ['-i', clip]
            duration = float(json.loads((clip.parent/'audit.json').read_text())['duration_s'])
            total += duration
            graph += [f'[{i}:v]setpts=PTS-STARTPTS,fade=t=in:st=0:d=0.3,fade=t=out:st={duration-0.3}:d=0.3[v{i}]',
                      f'[{i}:a]asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.133333,afade=t=out:st={duration-0.133333}:d=0.133333[a{i}]']
            order += [f'[v{i}][a{i}]']
        graph += [''.join(order) + f'concat=n={len(clips)}:v=1:a=1[video][sound]']
        fps = json.loads((clips[0].parent/'audit.json').read_text())['fps']
        args += ['-filter_complex_threads', 1, '-filter_complex', ';'.join(graph), '-map', '[video]',
                 '-map', '[sound]', '-c:v', 'libx264', '-preset', 'fast', '-crf', 20, '-threads', 4,
                 '-pix_fmt', 'yuv420p', '-r', fps, '-c:a', 'aac', '-b:a', '192k', '-ar', 48000,
                 '-t', total, '-movflags', '+faststart', destination]
        self.run(args, destination.parent/'join.log')
