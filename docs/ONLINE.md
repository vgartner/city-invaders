# Online: Bah's AI, reports and mods

The game talks to one small server, `server/` in this repository (Node +
TypeScript, SQLite), hosted on VGData. Everything else in the game works
without it.

## In the game

`godot/scripts/online.gd` is an autoload (`Online`). Its settings are in
`godot/assets/online.json`:

```json
{"base": "https://api.cityinvaders.vgdata.net", "game_key": "ci-public-2026-10"}
```

`game_key` ships with the game, so it is not a secret: it only keeps random
scanners away (the server's `GAME_CLIENT_KEY` must match). For a local
server, start the game with `CITY_INVADERS_API=http://127.0.0.1:8787`.

Each install gets a random id (`user://online.json`); nothing personal is
sent.

- **Bah, for real**: tablet > Bah > "Pergunte o que quiser à Bah" opens a
  line to type in. The question goes to `POST /api/bah/chat` with a little
  context (map, health, weapon, parts, objective), and the answer shows on
  the tablet. The quick questions (`bah_faq.json`) still work offline.
- **Report a problem or an idea**: Pause menu > Report. Bug / idea / other,
  a text, and a picture of the game as it was when you paused (optional) go
  to `POST /api/feedback` with the map and your position.
- **Mods**: map editor > File > Share these edits as a mod uploads them
  (`POST /api/mods`, published after a review); title screen > Mods lists,
  installs and removes them. docs/MODDING.md.

## On the server

`server/README.md` has the API, the environment variables and the deploy
steps for VGData. Reports, mods (published after a review) and Bah's
conversations are read through the admin API or the MCP endpoint, which
Claude connects to:

```bash
claude mcp add --transport http city-invaders https://api.cityinvaders.vgdata.net/mcp --header "Authorization: Bearer <ADMIN_TOKEN>"
```
