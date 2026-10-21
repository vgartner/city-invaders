# tools/

Everything outside the game itself, run with the project's Python
(`tools/.venv/bin/python`, see docs/BUILDING.md) from the repository root.

| Folder | What is in it | More in |
|---|---|---|
| `map/` | the map pipeline: OSM to glb (`osm2gltf.py`, `osmcity.py`), terrain, facade photos (Mapillary, Wikimedia Commons, the cleaning model), `new_city.py` for a new city, `building_photo.py` to rebuild a map and put your own photos and heights on it, `street_audit.py` | docs/MAP_PIPELINE.md |
| `devagent/` | driving a running game: the CLI (`devagent.py`), the MCP server for AI assistants (`devagent_mcp.py`), the in-game F1 channel (`devagent_wait.py`), traces and the see-through test | docs/DEVAGENT.md |
| `bench/` | benchmarks through the DevAgent: a play-through (`play_bench.py`), the kit facades, city mesh cells, the crowd | docs/PERFORMANCE.md |
| `assets/` | scripts that made or fixed assets: synthesised sounds, animation fixes and gait measuring, liveries and team shirts, foliage, the weapon pickups | docs/ASSETS.md |
| `blender/` | Blender scripts: the landmarks, vehicles, view-model weapons, facade baking | docs/ASSETS.md |

The machine-learning steps of the facade cleaning (`map/clean_facades.py`,
`map/crop_landmarks.py`) need torch and run from their own environment
(`~/.local/share/city-invaders-ml` in the examples).
