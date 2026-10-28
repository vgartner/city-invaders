#!/usr/bin/env python3
"""Render independent fixed-time shots and assemble an exact 180-second MP4 on macOS.
Uses a separate game on port 24691, native AVFoundation, and no downloaded media.
Existing completed clips are reused; raw intermediates made here are discarded after QA.
"""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[2]
PLAN = Path(__file__).with_name('presentation.json')


def movie_index(raw, log, duration, folder):
    images, audio = [], []
    meta = {}
    with raw.open('rb') as f:
        def walk(start, end):
            p = start
            while p + 8 <= end:
                f.seek(p)
                tag, size = struct.unpack('<4sI', f.read(8))
                data = p + 8
                if tag in (b'RIFF', b'LIST'):
                    yield from walk(data + 4, min(data + size, end))
                else:
                    yield tag, data, size
                p = data + size + size % 2
        for tag, pos, size in walk(0, raw.stat().st_size):
            if tag == b'avih':
                f.seek(pos)
                values = struct.unpack('<14I', f.read(56))
                meta.update(width=values[8], height=values[9], fps=round(1e6 / values[0]))
            elif tag == b'strf' and size >= 16:
                f.seek(pos)
                fmt, channels, rate, byte_rate, align, bits = struct.unpack('<HHIIHH', f.read(16))
                if fmt == 1:
                    meta['audio'] = dict(channels=channels, rate=rate, byte_rate=byte_rate, align=align, bits=bits)
            elif tag in (b'00dc', b'00db'):
                images.append([pos, size])
            elif tag == b'01wb':
                audio.append([pos, size])
        markers = [json.loads(s.split(' ', 1)[1]) for s in log.read_text().splitlines() if s.startswith('VIDEO_TAKE_START ')]
        end = next(json.loads(s.split(' ', 1)[1]) for s in log.read_text().splitlines() if s.startswith('VIDEO_TAKE_END '))
        take = json.loads(Path(end['log']).read_text())
        start = markers[-1]['drawn_frame']
        frames = images[start:start + duration * meta['fps']]
        assert len(frames) == duration * meta['fps'], 'Incomplete movie'
        assert not take['missing_pickups'], take['missing_pickups']
        for event in take.get('events', []):
            if event['action'] == 'lasso':
                assert event['result'] == 'drone', 'The lasso did not capture a real target'
            if event['action'] == 'drone':
                assert event['result'] == 'flying', 'The captured drone did not launch'
            if event['action'] == 'enter_vehicle':
                assert event['result'] == 'true', 'Vehicle entry failed'
            if event['action'] == 'open_container':
                assert event['result'] == '0 remaining', 'Container rescue failed' 
        (folder / 'take.json').write_text(json.dumps(take, indent=2))
        (folder / 'index.json').write_text(json.dumps(dict(meta, frames=frames)))
        # Validate the Movie Maker PCM format instead of assuming a user mix rate.
        sound = meta['audio']
        assert sound['bits'] == 16 and sound['channels'] == 2
        begin = round(start / meta['fps'] * sound['byte_rate'])
        length = round(len(frames) / meta['fps'] * sound['byte_rate'])
        offset, energy, count, peak = 0, 0, 0, 0
        with wave.open(str(folder / 'audio.wav'), 'wb') as w:
            w.setnchannels(sound['channels']); w.setsampwidth(2); w.setframerate(sound['rate'])
            for pos, size in audio:
                low, high = max(0, begin-offset), min(size, begin+length-offset)
                if high > low:
                    f.seek(pos+low); data = f.read(high-low); w.writeframes(data)
                    values = array.array('h', data)
                    energy += sum(v*v for v in values); count += len(values)
                    peak = max(peak, max(map(abs, values), default=0))
                offset += size
        hashes = []
        for pos, size in frames:
            f.seek(pos); hashes.append(hashlib.sha256(f.read(size)).digest())
        meta.update(frames=len(frames), identical_adjacent=sum(a == b for a, b in zip(hashes, hashes[1:])),
                    audio_rms=math.sqrt(energy / max(1, count)), audio_peak=peak,
                    collected=take.get('collected', []), events=take.get('events', []))
        (folder / 'capture_qa.json').write_text(json.dumps(meta, indent=2))
        return meta


def run(args, log):
    with log.open('w') as f:
        subprocess.run(list(map(str, args)), stdout=f, stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--only', nargs='*')
    parser.add_argument('--keep-raw', action='store_true')
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    plan = json.loads(PLAN.read_text())
    assert sum(s['duration_s'] for s in plan['shots']) == 180
    media = out / 'media'
    if not media.exists():
        run(['/usr/bin/swiftc', '-O', ROOT/'tools/video/media.swift', '-o', media], out/'compile.log')
    clips = []
    for index, shot in enumerate(plan['shots']):
        folder = out / f'{index+1:02d}_{shot["scene"]}'; folder.mkdir(exist_ok=True)
        clip = folder/'clip.mp4'; clips.append(clip)
        if args.only and shot['scene'] not in args.only:
            continue
        if clip.exists() and (folder/'audit.json').exists():
            print('REUSE', shot['scene'], flush=True); continue
        if shutil.disk_usage(out).free < 1_500_000_000:
            raise RuntimeError('Need at least 1.5 GB free to render the next bounded shot')
        try:
            with socket.create_connection(('127.0.0.1',24691), timeout=.5):
                raise RuntimeError('Port 24691 already belongs to another game')
        except (ConnectionRefusedError, socket.timeout):
            pass
        raw = folder/'raw.avi'; log = folder/'game.log'
        print('RENDER', index+1, shot['scene'], shot['duration_s'], flush=True)
        env = dict(os.environ, DEVAGENT_PORT='24691')
        with log.open('w') as f:
            subprocess.run(['godot','--path',str(ROOT/'godot'),'--windowed','--resolution','1920x1080',
                '--write-movie',str(raw),'--fixed-fps','60','--ignore-error-breaks','--',
                '--devagent','--video-stage='+shot['scene'],'--video-take','--video-quit'],
                env=env,stdout=f,stderr=subprocess.STDOUT,check=True,timeout=1200)
        text = log.read_text()
        if 'SCRIPT ERROR' in text or 'Parse Error' in text:
            raise RuntimeError('Runtime script error in '+str(log))
        movie_index(raw, log, shot['duration_s'], folder)
        run(['/usr/bin/avconvert','--source',folder/'audio.wav','--output',folder/'audio.m4a',
             '--preset','PresetAppleM4A'],folder/'audio.log')
        assert (folder/'audio.m4a').exists()
        run([media,'encode',raw,folder/'index.json',folder/'video.mp4',folder/'audio.m4a',clip,
             shot['title'],shot['subtitle']],folder/'encode.log')
        run([media,'audit',clip],folder/'audit.json')
        audit = json.loads((folder/'audit.json').read_text())
        assert audit['frames'] == shot['duration_s']*60 and audit['audio_tracks'] == 1
        for t in (2,shot['duration_s']/2,shot['duration_s']-2):
            run([media,'frame',clip,str(t),folder/f'frame_{t:g}.png'],folder/'frame.log')
        if not args.keep_raw:
            for path in (raw, folder/'video.mp4',folder/'audio.wav',folder/'audio.m4a'):
                path.unlink()
        print('DONE',shot['scene'],audit,flush=True)
    if args.only:
        return
    final = out/'city_invaders_gameplay_3min.mp4'
    # A successful interaction, not merely a complete frame count, is required.
    for clip in clips:
        take = json.loads((clip.parent / 'take.json').read_text())
        for event in take.get('events', []):
            expected = {'lasso': 'drone', 'drone': 'flying', 'enter_vehicle': 'true', 'open_container': '0 remaining'}.get(event['action'])
            if expected is not None:
                assert event['result'] == expected, (clip.parent.name, event)
    if not final.exists():
        run([media,'join',final,*clips],out/'join.log')
    run([media,'audit',final],out/'FINAL_QA.json')
    audit = json.loads((out/'FINAL_QA.json').read_text())
    assert audit['duration_s'] == 180 and audit['frames'] == 10800 and audit['audio_tracks'] == 1, audit
    shutil.copy(PLAN,out/'chapters.json')
    print('FINAL',final,audit,flush=True)


if __name__ == '__main__':
    main()
