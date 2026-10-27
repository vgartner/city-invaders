#!/usr/bin/env python3
"""Prepare a solo gameplay-video scene; the take runs on the game's clock.

python3 tools/devagent/stage.py --list
python3 tools/devagent/stage.py usina_walk --take --wait
python3 tools/devagent/stage.py street_battle
"""
import argparse
import json
import time
from devagent import DevAgent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', nargs='?')
    parser.add_argument('--port', type=int, default=24691)
    parser.add_argument('--allow-player-game', action='store_true', help='Explicitly allow staging on port 24690')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--take', action='store_true')
    parser.add_argument('--wait', action='store_true')
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--clear', action='store_true')
    parser.add_argument('--status', action='store_true')
    parser.add_argument('--drop', action='store_true')
    args = parser.parse_args()
    if args.port == 24690 and not args.allow_player_game and not (args.list or args.status):
        parser.error('The player game is protected: use an isolated test on port 24691')
    d = DevAgent(port=args.port, timeout=240)
    if args.list:
        scenes = d.call('stage')['scenes']
        for name, scene in scenes.items():
            print(f"{name}: {scene['title']}" + (' [scripted take]' if 'take' in scene else ' [manual]'))
        return
    if args.stop:
        print(json.dumps(d.call('take', on=False), indent=2)); return
    if args.clear:
        print(json.dumps(d.call('stage_clear'), indent=2)); return
    if args.status:
        print(json.dumps(d.call('take_status'), indent=2)); return
    if args.drop:
        print(json.dumps(d.call('stage_drop'), indent=2)); return
    if not args.name:
        parser.error('Choose a scene or --list')
    print(json.dumps(d.call('stage', name=args.name), indent=2), flush=True)
    if args.take:
        print(json.dumps(d.call('take'), indent=2), flush=True)
        if args.wait:
            # Polling observes progress only; no wall-clock movement commands.
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                status = d.call('take_status')
                if not status['running']:
                    print(json.dumps(status, indent=2)); return
                time.sleep(.5)
            raise TimeoutError('Take exceeded the 10-minute wall-time safety limit')


if __name__ == '__main__':
    main()
