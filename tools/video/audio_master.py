"""Final web-video audio mastering and measurement of the encoded AAC, not PCM alone."""
import json
import math
from pathlib import Path
import re
import shutil
import subprocess

TARGET_LUFS = -16.0
MAX_TRUE_PEAK_DBTP = -1.0


def audio_tool():
    executable = shutil.which('ffmpeg')
    if not executable:
        raise RuntimeError('FFmpeg on PATH is required for final loudness and true-peak QA, including AVFoundation edits')
    return executable


def measure(path, report):
    result = subprocess.run([audio_tool(), '-hide_banner', '-nostdin', '-i', str(path), '-map', '0:a:0',
                             '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json',
                             '-f', 'null', '-'], capture_output=True, text=True, check=True)
    Path(report).write_text(result.stderr)
    matches = re.findall(r'\{\s*"input_i".*?\}', result.stderr, re.S)
    if not matches:
        raise RuntimeError('No EBU R128 loudness report in '+str(report))
    stats = json.loads(matches[-1])
    values = dict(integrated_lufs=float(stats['input_i']), true_peak_dbtp=float(stats['input_tp']),
                  loudness_range_lu=float(stats['input_lra']))
    if not all(math.isfinite(v) for v in values.values()):
        raise RuntimeError('Silent or unmeasurable final audio: '+str(values))
    return values, stats


def verify(values):
    if values['true_peak_dbtp'] > MAX_TRUE_PEAK_DBTP:
        raise RuntimeError('Encoded audio exceeds -1 dBTP: '+str(values))
    if abs(values['integrated_lufs']-TARGET_LUFS) > 1.0:
        raise RuntimeError('Encoded audio is outside -16 LUFS ±1 LU: '+str(values))


def master(source, destination):
    folder = destination.parent
    before, stats = measure(source, folder/'audio_before.log')
    attempts = []
    # Leave AAC reconstruction headroom and measure after encoding. Retry from
    # the original mix, never from an already normalised/re-encoded attempt.
    for i, ceiling in enumerate([-1.5, -2.0, -2.5], 1):
        output = folder/f'audio_master_attempt_{i}.mp4'
        graph = (f'loudnorm=I=-16:TP={ceiling}:LRA=11:measured_I={stats["input_i"]}:'
                 f'measured_TP={stats["input_tp"]}:measured_LRA={stats["input_lra"]}:'
                 f'measured_thresh={stats["input_thresh"]}:offset={stats["target_offset"]}:linear=true')
        with (folder/f'audio_master_attempt_{i}.log').open('w') as log:
            subprocess.run([audio_tool(), '-hide_banner', '-nostdin', '-y', '-i', str(source),
                            '-map', '0:v:0', '-map', '0:a:0', '-c:v', 'copy', '-af', graph,
                            '-ar', '48000', '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart',
                            str(output)], stdout=log, stderr=subprocess.STDOUT, check=True)
        after, _ = measure(output, folder/f'audio_master_measure_{i}.log')
        attempts.append(dict(limiter_ceiling_dbtp=ceiling, measured=after))
        try:
            verify(after)
        except RuntimeError:
            continue
        if destination.exists():
            raise FileExistsError('Refusing to overwrite a completed video: '+str(destination))
        output.rename(destination)
        qa = dict(target_lufs=TARGET_LUFS, maximum_true_peak_dbtp=MAX_TRUE_PEAK_DBTP,
                  before=before, after=after, attempts=attempts)
        (folder/'AUDIO_QA.json').write_text(json.dumps(qa, indent=2))
        for attempt in folder.glob('audio_master_attempt_*.mp4'):
            attempt.unlink()
        return qa
    raise RuntimeError('Could not meet encoded loudness/true-peak limits: '+str(attempts))
