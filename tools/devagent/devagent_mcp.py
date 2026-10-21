#!/usr/bin/env python3
"""MCP server exposing the in-game DevAgent to Claude (stdio transport).

Every tool forwards to the game's JSON-RPC channel (godot/scripts/dev_agent.gd)
through tools/devagent/devagent.py. Start the game with the `launch_game` tool, or run
`tools/devagent/devagent.py launch` yourself.
"""
import json
import sys
from pathlib import Path

from mcp.server.mcpserver import Image, MCPServer

sys.path.insert(0, str(Path(__file__).parent))
import devagent  # noqa: E402

server = MCPServer(
    name="city-invaders-devagent",
    instructions=(
        "Drive the City Invaders Godot game for testing: launch it, start a solo "
        "round, teleport the camera, take screenshots, query state, raycast, "
        "scan for see-through slits between buildings, spawn/kill robots and "
        "control the AI Director. Coordinates are Godot metres: X east, "
        "-Z north, Y up; the map spans roughly -150..150 on X and Z."
    ),
)
_agent = devagent.DevAgent()


def _call(method, **params):
    global _agent
    try:
        return _agent.call(method, **params)
    except (ConnectionError, OSError):
        _agent = devagent.DevAgent()   # game restarted: reconnect once
        return _agent.call(method, **params)


def _fmt(result):
    return json.dumps(result, indent=1)


@server.tool()
def launch_game() -> str:
    """Start the game with the DevAgent enabled (no-op if it is already running)."""
    return devagent.launch()


@server.tool()
def start_solo() -> str:
    """Start a solo round if no player exists yet; returns the game state."""
    return _fmt(_call("start_solo"))


@server.tool()
def get_state() -> str:
    """Players (position, yaw, health, ammo), robots, AI Director phase/intensity, FPS."""
    return _fmt(_call("get_state"))


@server.tool()
def perf() -> str:
    """Frame cost: FPS, process / physics / navigation ms, draw calls, objects
    and primitives drawn, node count, and how many pedestrians, vehicles, robots."""
    return _fmt(_call("perf"))


@server.tool()
def teleport(x: float, z: float, y: float = 1.0, yaw: float | None = None, pitch: float | None = None,
             freeze: bool = False) -> str:
    """Move the local player. yaw in degrees (0 = looking north / -Z, 90 = west),
    pitch in degrees (negative looks down). freeze=True disables gravity/input so
    the camera stays where it was put (useful for aerial shots) - the player
    cannot walk until a teleport with freeze=False (or F2 twice) releases it."""
    params = {"x": x, "y": y, "z": z}
    if yaw is not None:
        params["yaw"] = yaw
    if pitch is not None:
        params["pitch"] = pitch
    _call("eval", expr=f"player.set_physics_process({str(not freeze).lower()})")
    return _fmt(_call("teleport", **params))


@server.tool()
def look_at(x: float, z: float, y: float = 1.6) -> str:
    """Turn the camera towards a world point."""
    return _fmt(_call("look_at", x=x, y=y, z=z))


@server.tool()
def screenshot(width: int = 960, crop: list[float] | None = None, hud: bool = True) -> Image:
    """Capture the current frame: optionally crop=[x0, y0, x1, y1] (fractions
    of the frame) and hud=False to hide the overlay; scaled to `width`."""
    params = {"width": width, "hud": hud}
    if crop:
        params["crop"] = crop
    r = _call("screenshot", **params)
    return Image(path=r["path"])


@server.tool()
def raycast(from_xyz: list[float], to_xyz: list[float], mask: int = 1) -> str:
    """Physics ray between two points. mask: 1 world, 2 robots, 4 players."""
    return _fmt(_call("raycast", **{"from": from_xyz, "to": to_xyz, "mask": mask}))


@server.tool()
def scan_gaps(x: float = 0.0, z: float = 0.0, radius: float = 148.0, step: float = 0.5,
              max_width: float = 2.5, limit: int = 30) -> str:
    """Find see-through slits: outdoor points at eye height with walls on two
    opposite sides closer than max_width. Returns clusters sorted by size."""
    return _fmt(_call("scan_gaps", x=x, z=z, radius=radius, step=step, max_width=max_width, limit=limit))


@server.tool()
def spawn_enemy(x: float, z: float, y: float = 0.5, variant: str = "trooper") -> str:
    """Spawn one robot at a position; variant "trooper", "mech" or "drone"."""
    return _fmt(_call("spawn_enemy", x=x, y=y, z=z, variant=variant))


@server.tool()
def pick_building() -> str:
    """Identify the building wall under the player's crosshair (OSM id, name,
    address, height, wall key for tools/map/building_photo.py) and outline it in
    the game with a yellow frame."""
    import building_photo
    aim = _call("aim")
    if not aim.get("hit"):
        return "Nothing under the crosshair."
    x, _, z = aim["pos"]
    info = building_photo.pick(aim["map"], x, z)
    if info["distance_m"] > 3.0:
        return _fmt({"note": "the crosshair is not on a building wall", "aim": aim, "nearest": info})
    _call("mark", **{"from": info["from"], "to": info["to"], "base": info["base_y"], "top": info["top_y"]})
    return _fmt(info)


@server.tool()
def design_mode(enabled: bool | None = None) -> str:
    """Design mode (solo): freeze the world and let the player fly through it
    (F2 in game). Omit `enabled` to toggle."""
    params = {} if enabled is None else {"enabled": enabled}
    return _fmt(_call("design", **params))


@server.tool()
def hold_keys(actions: list[str], seconds: float = 1.0) -> str:
    """Hold game actions (forward, back, left, right, run, jump...) for a while,
    through the same input path as the player's keys: drive, walk, strafe."""
    return _fmt(_call("hold_keys", actions=actions, seconds=seconds))


@server.tool()
def tap(action: str) -> str:
    """Press an action once as a key event (use, reload, weapon_1..4, design)."""
    return _fmt(_call("tap", action=action))


@server.tool()
def audit_ground(tolerance: float = 0.25, limit: int = 20) -> str:
    """List vehicles, pedestrians, robots, parked cars and pickups that are
    sunk into or floating above the surface under them."""
    return _fmt(_call("audit_ground", tolerance=tolerance, limit=limit))


@server.tool()
def errors(limit: int = 15) -> str:
    """The latest script errors from the game log."""
    return _fmt(_call("errors", limit=limit))


@server.tool()
def selection() -> str:
    """What the player clicked in design mode (F2 + left click): kind, name,
    model, position. For a building, also its OSM id and wall key."""
    s = _call("selection")
    if s.get("selected") and s["what"] == "building":
        import building_photo
        x, _, z = s["pos"]
        s["building"] = building_photo.pick(s["map"], x, z)
    return _fmt(s)


@server.tool()
def reload(paths: list[str] | None = None) -> str:
    """Hot reload: after changing models (and re-importing them), re-read these
    res:// files and rebuild the map's props, stalls, landmarks and vendors
    without restarting the game."""
    return _fmt(_call("reload", paths=paths or []))


@server.tool()
def tune(values: dict | None = None) -> str:
    """Live tuning (tune.gd): pass {"vehicle_max_roll_deg": 4} etc.; no values lists them."""
    return _fmt(_call("tune", **(values or {})))


@server.tool()
def move(name: str, x: float | None = None, z: float | None = None, dx: float = 0, dz: float = 0,
         yaw: float | None = None, dyaw: float = 0, save: bool = False) -> str:
    """Move / turn an object live (landmark model name like "posto_charrua", or V12, C50, E3):
    a preview unless save=True, which keeps a placed model's new spot in the map's edits."""
    params = {"name": name, "dx": dx, "dz": dz, "dyaw": dyaw, "save": save}
    for k, v in (("x", x), ("z", z), ("yaw", yaw)):
        if v is not None:
            params[k] = v
    return _fmt(_call("move", **params))


@server.tool()
def inbox(keep: bool = False) -> str:
    """Messages the player wrote to the assistant in the game (F1), with the map,
    their position and what they had selected in design mode."""
    return _fmt(_call("inbox", keep=keep))


@server.tool()
def say(text: str, seconds: float = 12) -> str:
    """Show a message to the player inside the game (top right)."""
    return _fmt(_call("say", text=text, seconds=seconds))


@server.tool()
def clear_mark() -> str:
    """Remove the building outline drawn by pick_building."""
    return _fmt(_call("mark", clear=True))


@server.tool()
def kill_enemies() -> str:
    """Remove all robots."""
    return _fmt(_call("kill_enemies"))


@server.tool()
def set_director(enabled: bool | None = None, phase: str | None = None) -> str:
    """Enable/disable the AI Director or force a phase (BUILD_UP, PEAK, RELAX)."""
    params = {}
    if enabled is not None:
        params["enabled"] = enabled
    if phase is not None:
        params["phase"] = phase
    return _fmt(_call("set_director", **params))


@server.tool()
def set_god(enabled: bool = True) -> str:
    """Make the local player invulnerable."""
    return _fmt(_call("set_god", enabled=enabled))


@server.tool()
def set_sun(elevation: float = 58, azimuth: float = 160, energy: float | None = None) -> str:
    """Move the sun (degrees)."""
    params = {"elevation": elevation, "azimuth": azimuth}
    if energy is not None:
        params["energy"] = energy
    return _fmt(_call("set_sun", **params))


@server.tool()
def inspect(id: str | None = None) -> str:
    """Look inside an NPC (robot "E4", pedestrian/dog "C12", vehicle "V3"; default:
    the one under the player's crosshair): AI state, goal, navigation status and
    automatic diagnoses such as an unreachable goal or jittering on the spot."""
    return _fmt(_call("inspect", **({"id": id} if id else {})))


@server.tool()
def eval_expr(expr: str) -> str:
    """Evaluate a GDScript expression with `main`, `player` and `tree` bound."""
    return _fmt(_call("eval", expr=expr))


@server.tool()
def quit_game() -> str:
    """Close the game."""
    return _fmt(_call("quit"))


if __name__ == "__main__":
    server.run("stdio")
