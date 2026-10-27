# City Invaders

A co-op first-person shooter set in real cities of southern Brazil, built
from open data: OpenStreetMap streets and buildings, Mapillary and Wikimedia
Commons photos on the facades, real terrain. Robots invade Porto Alegre;
protect the people, drive whatever you find, drink a chimarrão.

Made with [Godot 4.7](https://godotengine.org). Solo or online co-op.

- Phase 1: Usina do Gasômetro and the Guaíba shore
- Phase 2: Centro Histórico (Mercado Público, Paço Municipal, Praça da Alfândega)

## Quick start

You need [Git LFS](https://git-lfs.com) (`brew install git-lfs`, then
`git lfs install` once) and [Godot 4.7](https://godotengine.org). The models,
textures, sounds and the Porto Alegre maps (~4 GB) come through Git LFS from the
project's own server, `lfs.cityinvaders.vgdata.net` - no account needed.

```bash
git clone https://github.com/vgartner/city-invaders.git
cd city-invaders
# import once (a few minutes), then play
cd godot && godot --headless --path . --import && cd ..
./run-godot.sh
```

To rebuild a map from its OpenStreetMap data and photos, see
[docs/MAP_PIPELINE.md](docs/MAP_PIPELINE.md).

## Documentation

| Document | For |
|---|---|
| [docs/GAMEPLAY.md](docs/GAMEPLAY.md) | controls, weapons, pickups, score, what's in the city |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the game is put together: scripts, networking, collision layers, landmarks |
| [docs/MAP_PIPELINE.md](docs/MAP_PIPELINE.md) | turning a real city into a map; your own photos, heights and models |
| [docs/ASSETS.md](docs/ASSETS.md) | model conventions, rigs and clips, the Blender scripts |
| [docs/DEVAGENT.md](docs/DEVAGENT.md) | driving the game from scripts and AI assistants for testing |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | frame-rate budget, graphics preset, batching, agent LOD, how to measure |
| [docs/BUILDING.md](docs/BUILDING.md) | exporting a release (Windows `.exe`) |
| [docs/LICENSING.md](docs/LICENSING.md) | the licences of the data and assets |
| [AGENTS.md](AGENTS.md), [docs/AGENTS.md](docs/AGENTS.md) | for AI coding agents (Codex, Claude Code, Cursor...): rules, testing in the game, a file index, setup per tool |
| [docs/ROADMAP.md](docs/ROADMAP.md) | cities as chains of maps, automatic import, the map editor |
| [CONTRIBUTING.md](CONTRIBUTING.md) | how to contribute maps, models and code |
| [godot/assets/CREDITS.md](godot/assets/CREDITS.md) | asset sources and licences |

## Repository layout

- `godot/` – the game (`scripts/`, `assets/`, `city/` for generated maps)
- `tools/` – map pipeline (Python) and `tools/blender/` model scripts
- `maps/<map>/` – per-map data, settings (`build.json`) and your additions (`user/`)

## Data licences

- Map data © OpenStreetMap contributors (ODbL)
- Street-level imagery © Mapillary contributors (CC-BY-SA 4.0)
- Landmark photos: Wikimedia Commons contributors (see `maps/*/facades/commons_credits.txt`)
- Elevation: Copernicus GLO-30 DEM

Code: GNU GPL v3 ([LICENSE](LICENSE)); assets and maps: CC BY-SA 4.0; see [docs/LICENSING.md](docs/LICENSING.md).
