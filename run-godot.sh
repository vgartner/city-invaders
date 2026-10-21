#!/bin/bash
# Launch City Invaders (Godot) on macOS. The DevAgent is always on
# (127.0.0.1:24690 only), so a running session can be inspected and driven by
# tools/devagent/devagent.py while someone plays.
cd "$(dirname "$0")/godot"
exec godot --path . "$@" -- --devagent
