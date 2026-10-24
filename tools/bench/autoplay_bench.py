#!/usr/bin/env python3
"""Run one existing DevAgent game, safely poll status and keep portable results.

python3 tools/bench/autoplay_bench.py --port 24691 --minutes 3 --output /tmp/bench
Does not launch/quit the game or stop somebody else's autoplay run.
"""
import argparse
import json
import math
from pathlib import Path
import shutil
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "devagent"))
from devagent import DevAgent
from process_metrics import ProcessMetrics


def capture(agent, output, minutes=3, seed=7, interval=1, drive_every=70):
    if not math.isfinite(minutes) or minutes <= 0 or not math.isfinite(interval) or interval <= 0:
        raise ValueError("minutes and sample interval must be finite and positive")
    if agent.call("autoplay_status").get("active"):
        raise RuntimeError("Another autoplay is active; leave it running")
    output.mkdir(parents=True, exist_ok=False)
    host = ProcessMetrics(agent.call("ping")["pid"])
    samples = []
    run_id = None
    start = time.monotonic()
    last = {}
    try:
        reply = agent.call("autoplay", minutes=minutes, seed=seed, drive_every=drive_every)
        if reply.get("autoplay") is not True:
            raise RuntimeError(f"Autoplay did not start: {reply}")
        run_id = reply["run_id"]
        print(f"Started {run_id} for {minutes * 60:.0f} simulation seconds", flush=True)
        deadline = start + minutes * 60 * 4 + 120
        next_print = 0
        while time.monotonic() < deadline:
            now = time.monotonic() - start
            sample = {"wall_s": now, **host.sample()}
            status = agent.call("autoplay_status")
            samples.append(sample)
            if not status["active"]:
                last = status.get("last", {})
                if last.get("run_id") == run_id:
                    break
                if status.get("finishing") and status.get("run_id") == run_id:
                    time.sleep(min(interval, .2))
                    continue
                raise RuntimeError("Run disappeared without a matching completion record")
            if status.get("run_id") != run_id:
                raise RuntimeError("Autoplay was replaced; the replacement was left untouched")
            if now >= next_print:
                print(f"{now:.0f}s wall, {status['elapsed_sim_s']:.1f}s sim, {status['activity']}, "
                      f"shots={status['counts']['shots']}, travel={status['coverage']['foot_m']:.0f} m on foot", flush=True)
                next_print = now + 15
            time.sleep(interval)
        else:
            raise TimeoutError("Autoplay exceeded the wall-time safety limit")
        source = Path(last["run_path"])
        run = json.loads(source.read_text())
        recording = Path(run["recording"])
        shutil.copy2(recording, output / "recording.json")
        run["source_recording"] = run["recording"]
        run["recording"] = "recording.json"
        run["host_metrics"] = "host.json"
        (output / "run.json").write_text(json.dumps(run, indent=2))
        (output / "status.json").write_text(json.dumps(last, indent=2))
        print(f"Finished: {output / 'run.json'}", flush=True)
        return output / "run.json"
    except BaseException:
        if run_id:
            try:
                status = agent.call("autoplay_status")
                if status.get("active") and status.get("run_id") == run_id:
                    agent.call("autoplay", on=False)
            except Exception:
                pass
        raise
    finally:
        (output / "host.json").write_text(json.dumps({"pid": host.pid, "samples": samples,
            "source": "macOS proc_pid_rusage v2; per-process footprint/RSS, page-ins and disk I/O",
            "limits": "low-rate correlation only; page-ins are not proof of swap; memory counters overlap"}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=24690)
    parser.add_argument("--minutes", type=float, default=3)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--drive-every", type=float, default=70)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    capture(DevAgent(port=args.port), args.output, args.minutes, args.seed, args.interval, args.drive_every)


if __name__ == "__main__":
    main()
