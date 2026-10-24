#!/usr/bin/env python3
"""Decode Godot 4.7 native profiler captures; times are not sampled monitors.

python3 tools/devagent/profile_report.py /tmp/profile.jsonl [--label LABEL] [--json OUTPUT]
The capture records native-call profiling too: inclusive/callback costs can
 overlap, so never sum them as a CPU total. Frame numbers can be adjacent to
 DevAgent recorder rows; inspect neighbouring frames when correlating them.
"""
import argparse
import json
from pathlib import Path


def parse_messages(messages):
    signatures, frames, resources = {}, [], []
    label = "unknown"
    for message in messages:
        kind = message["method"]
        if kind == "capture_start":
            signatures = {}
            label = message.get("label", "unknown")
        elif kind == "servers:function_signature":
            name, key = message["data"]
            signatures[int(key)] = name
        elif kind == "servers:memory_usage":
            data = message["data"]
            if len(data) != int(data[0]) + 1 or int(data[0]) % 4:
                raise ValueError("Unexpected Godot resource usage format")
            resources = [dict(zip(("path", "format", "type", "bytes"), data[i:i + 4]))
                         for i in range(1, len(data), 4)]
        elif kind == "servers:profile_frame":
            data = message["data"]
            if len(data) < 8:
                raise ValueError("Truncated native profiler frame")
            index = 7
            for _ in range(int(data[6])):
                index += 2 + int(data[index + 1])
            count = int(data[index])
            index += 1
            if count % 5 or len(data) != index + count:
                raise ValueError("Unexpected native profiler layout; expected Godot 4.7 five-field functions")
            functions = []
            for i in range(index, len(data), 5):
                key, calls, own, total, internal = data[i:i + 5]
                functions.append({"function": signatures.get(int(key), f"unknown:{key}"),
                                  "calls": int(calls), "self_ms": own * 1000,
                                  "total_ms": total * 1000, "internal_ms": internal * 1000})
            frames.append({"label": label, "frame": int(data[0]), "frame_ms": data[1] * 1000,
                           "process_ms": data[2] * 1000, "physics_ms": data[3] * 1000,
                           "script_ms": data[5] * 1000, "functions": functions})
    return {"frames": frames, "resources": resources}


def read_messages(path):
    with open(path) as stream:
        for line in stream:
            if not line.endswith("\n"):
                break  # an in-progress capture may end in a partially flushed line
            yield json.loads(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("capture", type=Path)
    ap.add_argument("--label", help="exact capture_start label to select")
    ap.add_argument("--json", type=Path, help="save decoded data")
    args = ap.parse_args()
    result = parse_messages(read_messages(args.capture))
    frames = [f for f in result["frames"] if args.label is None or f["label"] == args.label]
    print(f"{len(frames)} native profiler frames; inclusive/callback costs overlap, do not sum them as CPU totals")
    for f in sorted(frames, key=lambda r: -r["frame_ms"])[:8]:
        print(f"\n{f['label']} frame {f['frame']}: {f['frame_ms']:.2f} ms, "
              f"process {f['process_ms']:.2f}, physics {f['physics_ms']:.2f}")
        for fn in sorted(f["functions"], key=lambda r: -r["total_ms"])[:5]:
            print(f"  {fn['total_ms']:8.3f} ms ({fn['calls']} calls) {fn['function']}")
    if result["resources"]:
        print("\nLargest rendering resources (tracked allocation bytes, not resident system RAM):")
        for resource in sorted(result["resources"], key=lambda r: -r["bytes"])[:15]:
            print(f"  {resource['bytes'] / 1048576:8.1f} MiB {resource['format']} {resource['path']}")
    if args.json:
        args.json.write_text(json.dumps({"frames": frames, "resources": result["resources"]}, indent=2))


if __name__ == "__main__":
    main()
