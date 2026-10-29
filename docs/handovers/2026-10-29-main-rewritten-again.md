# Handover: `main` was rewritten again - move onto it

From: Claude Code session (2026-10-29) · To: Codex (or any agent with a
worktree of this repository) · Owner: Vilson

## What happened

Before the repository goes public, the owner had personal machine details
removed from the whole history. `main` was rewritten and force-pushed once
more:

- a macOS home-folder path (in two docs, `docs/handovers/2026-10-27-gameplay-video.md`
  and `tools/video/README.md`, already gone from the latest version) became `~`;
- every mention of a corporate TLS proxy and its CA bundle path was replaced
  by the text the files have now (proxies are configured through the
  environment: `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE`, or `--ca`);
- **file contents of the tip are identical** (same tree), authors, dates and
  messages unchanged; every commit hash changed. The old tip `6512b27` is now
  `2c8f773` (its own commit became empty and was dropped). Old `fe5a29a`
  ("Version video helper UIDs and record rewritten-main validation") is now
  `fd65bf2`.

New rule in [AGENTS.md](../../AGENTS.md) ("Rules"): no machine-specific paths
or settings in the repository (home folders, a local CA bundle, a company
proxy) - they stay in your own environment.

## What you need to do

Neither of your worktrees has work that isn't on `main`:

- **`video-followups`** (`~/Documents/Codex/city-invaders-video-followups`,
  at the old `fe5a29a`, clean): move it onto the new `main` -
  `git fetch origin && git switch video-followups && git reset --hard origin/main`
  (nothing is lost: everything it had is in `main`), or remove it.
- **`gameplay-video`** (`~/Documents/Codex/city-invaders-gameplay-video`):
  history from before the first rewrite, fully merged. Remove it:
  `git worktree remove ~/Documents/Codex/city-invaders-gameplay-video` and
  `git branch -D gameplay-video`.

Don't push any branch or commit made before this rewrite: it would bring
back the old hashes and the removed paths. Start new work from `origin/main`.

## Also new on `main` since your last session

- **Releases**: one package per map (`maps/<id>.pck`) and a small Windows
  installer that downloads the game and the chosen maps; built by hand with
  the `Build Windows` GitHub workflow. See [docs/BUILDING.md](../BUILDING.md).
  Playing from the sources is unchanged (`scripts/packs.gd` does nothing there).
- Falling leaves are smaller and darker: the yellow discs seen in the v4 video
  were the old leaves. A future re-recording will not show them.
