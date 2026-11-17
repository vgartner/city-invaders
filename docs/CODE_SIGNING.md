# Code signing policy

The Windows setup and executable are **not code-signed yet**: Windows
SmartScreen asks for confirmation the first time ("More info", then "Run
anyway"). The project is applying for free code signing for open source
projects from the [SignPath Foundation](https://signpath.org/); this page is
the policy that programme asks for, and it gets the attribution line the
Foundation requires once the application is accepted.

## What is signed

Only files built from this repository by its own build
(`.github/workflows/build-release.yml`, [BUILDING.md](BUILDING.md)): the
Windows setup `CityInvaders-<version>-setup.exe` and the game executable
`CityInvaders.exe`, with the product name "City Invaders" and the release's
version in their metadata. Godot's runtime inside the executable is the
official export template of the Godot version the project uses (MIT
licence). The game and map packages (`.pck`) are data, not executables;
the setup and the game check each one's SHA-256 against the release's
catalog.

## Team roles

| Role | Who |
|---|---|
| Committers and reviewers | [@vgartner](https://github.com/vgartner) |
| Approvers (each signing request, each release) | [@vgartner](https://github.com/vgartner) |

Changes from other contributors come as pull requests and are reviewed by a
committer before they are merged ([CONTRIBUTING.md](../CONTRIBUTING.md)).
Every team member uses multi-factor authentication on GitHub. A release is
built only when a committer starts the build by hand, and it stays a draft
until an approver publishes it.

## Privacy

This program will not transfer any information to other networked systems
unless specifically requested by the user or the person installing or
operating it. What a request sends:

- **The setup and the game's Maps screen** download the game and map files
  of the release from GitHub.
- **Asking Bah a typed question** (tablet) sends the question and a little
  game context (map, health, weapon, objective) to the project's server.
- **Report a problem or an idea** (pause menu) sends the text, the map and
  position, and the picture of the game if it is left ticked.
- **Mods** (title screen, map editor): listing, installing or sharing mods
  talks to the project's server.
- **Playing with others** connects to the host the player chooses.

Each install has a random id for these requests; no name, account or
personal data is sent. Details: [ONLINE.md](ONLINE.md).

## Uninstalling

The Windows setup registers an uninstaller (*Settings > Apps*, "City
Invaders"). Downloaded maps and the settings are in the game's user data
folder (`%APPDATA%\Godot\app_userdata\City Invaders`).
