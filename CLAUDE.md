# CLAUDE.md

Claude Code reads this file; every other agent reads AGENTS.md. The
instructions are the same for all of them and live there:

@AGENTS.md

Claude Code specifics:

- `.mcp.json` starts the DevAgent as MCP tools (`city-invaders-devagent`:
  `launch_game`, `start_solo`, `screenshot`, `say`, ...). They act on the port
  in `DEVAGENT_PORT` (default 24690, the player's game) - for your own tests
  prefer the CLI with `DEVAGENT_PORT=24691`, as AGENTS.md describes.
- Keep project knowledge in the repository docs, not in Claude's memory:
  other contributors use other agents.
