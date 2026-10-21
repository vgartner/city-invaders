# Mods

A mod is a map changed by a player and shared with everyone: the models
placed by hand (monuments, a camp, street furniture...), item spots, which
item plays each role on that map (healing, armour...), bus lines, objects
removed and photos put on walls. Anything the map editor saves.

## Making one

1. Start the phase you want to change and press **F2** (design mode, solo).
2. Change it with the editor (docs/GAMEPLAY.md, "Map editor").
3. **File > Share these edits as a mod...**: a name, your name or nickname,
   a version and a short description. The mod is your edits as they are
   now (unsaved ones included).
4. It goes to the City Invaders server and waits for a review; once it is
   published everyone sees it under Mods.

## Installing one

Title screen > **Mods**: the published mods with their author, version and
downloads. **Install** puts one on its map - your own edits of that map are
kept aside - and **Remove** takes it off again, your edits back as they
were. One mod per map at a time. Play the map to see it.

Mods apply in the released game (its edits live in the game's user folder,
`user://maps/<map>/`). Playing from the sources the repository's own edits
are used: start with `CITY_INVADERS_NO_SOURCES=1` to try an installed mod.

## What is inside

A zip with:

| File | What |
|---|---|
| `mod.json` | `{"format": 1, "map", "name", "author", "description", "version"}` |
| `buildings_user.json` | the map's edits (`_props`, `_pickups`, `_roles`, `_remove`, `_photos`, ...) |
| `photos/<image>` | the wall photos (png, jpg, webp) |

Nothing else: a zip with any other file (scripts, models) is refused, so a
mod can't run code. The server checks the zip's size (25 MB at most) and
checksum; the game checks the checksum again before installing.

The code: `godot/scripts/mods.gd` (pack, install, remove), the screens in
`main.gd` (`_show_mods`, `share_mod`), the calls in `online.gd`; the server
side in `server/` (docs/ONLINE.md).
