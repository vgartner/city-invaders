# Gameplay

Robots are invading real cities of southern Brazil. Destroy the phase's robot
goal while protecting the people; the exit beacon then takes you to the next
part of the city. Solo or online co-op.

## Getting started

1. You start with empty hands: the click punches (hook, hook) and kicks.
   Two pistols lie on the street a short walk from the start; other guns,
   ammo and the laço further off.
2. Press **T** for the tablet: the GPS map, the radio, and **Bah**, your
   assistant - pick a quick question or ask her anything.
3. Heal with food and drink lying around and at the door of pharmacies,
   markets and restaurants (an item says what it does when you pick it up:
   "Health +20", "Armor +100").
4. Every phase asks for a number of robots and mechs (HUD, top) and has
   relay antennas on high roofs; the exit opens once the goal is met.
5. Protect the people - this is part of every phase, not a side job: every
   two lost add a robot to the goal (and on hard, losing 30% loses the
   phase). The **Coletores** (URB-C4, no gun) are the robots that take them:
   one grabs a lone person into the glass capsule on its back and carries
   them on foot to a **people container**. Bring a Coletor down on its way
   and the person runs free (+250);
   open a container (E) to let everyone out (+100 each); three containers
   taken by the mothership and the round starts over. When a player asks
   what a phase needs, the Coletores and the containers belong in the
   answer.
6. Downed robots drop parts: take them to a repair shop (assistência
   técnica) and trade them for gadgets (information glasses, drones, the
   GPS upgrade...).
7. Any car, bus, motorbike, bicycle or horse can be taken (E); the armoured
   harvester waits near the start of every phase.

## Opening film

A city can open with a film (Porto Alegre: the invasion, made with Google
Flow / Veo); Esc, Space or a click skips it. The same films play in the
city's cinemas.

## Maps and phases

The menu lists cities; a city with several phases can also start at a later
phase. Imported cities appear there automatically (`godot/city/maps.json`).


| Map | Area | Phase |
|---|---|---|
| `gasometro` | Usina do Gasômetro and the Guaíba shore, Porto Alegre (400 x 400 m) | Phase 1, goal 25 robots and 3 mechs |
| `centro` | Centro Histórico: Praça da Alfândega, Sulacap, Farmácias São João, Cine Imperial (400 x 375 m) | Phase 2, goal 30 robots and 4 mechs, exit to the north |
| `mercado` | Mercado Público and Paço Municipal (460 x 225 m) | Phase 3, goal 30 robots and 5 mechs |
| `poa` | the whole Centro in one map (500 x 590 m, heavy) | free play |

Each phase also hides the robots' **relay antenna** on a high rooftop: while
it stands, dropships come sooner (`Director.reinforce` 0.6). Only a drone you
fly (catch one with the laço, G) can spot it; then a red column marks it for
everyone. Shoot it down (400 hp, 800 points); the exit opens only with the
antenna down. In the last phase the **robot commander** - a larger mech
with a red command light, 900 hp, 1500 points - guards the foot of the
antenna's building. Every two civilians lost add one robot to the goal. The heavy mechs
(`MECH_GOALS` in main.gd; 3 for imported cities) come by dropship, one per
ship, as long as the phase still owes them; the HUD shows them beside the
robot count. Neighbouring phase maps
overlap at their border: leaving through the exit you arrive at the same
street corner of the next map.

Vehicles: the heavier one wins a crash - a bus shoves a car aside and runs
over bicycles, motorbikes and horses (their riders are thrown off).

## Controls (rebindable in Controls)

| Key | Action |
|---|---|
| W A S D, Shift, Space | move, run, jump |
| Mouse, left button | look, shoot; wheel switches weapons |
| 1 2 3 4 | pistol, machine gun, .38 revolver, 12-gauge shotgun |
| 5 6 7 | laço, espeto, mech cannon (once you have them) |
| Q / Z | throw a grenade / switch between Bergamota and Porongo |
| T | the tablet (GPS, radio, Bah, TchêTube, parts) |
| O | information glasses on / off (once you have them) |
| R | reload |
| B | horn while driving (people ahead step aside) |
| N | car radio (driving a car, bus, lorry or the harvester): on, next station, off. Each station is a music folder; the harvester starts on its own song |
| G | fly a drone you caught with the laço: WASD, Space / Ctrl up and down, mouse to look, Shift fast, click to fire its light gun (5 per hit, no ammo); 90 s of battery, 160 m from your body, up to 120 m high (shown top right); G again, or your body being hit, brings you back |
| E | enter / leave a vehicle (car, bus, tanker, motorbike, bicycle, horse; the mouse turns the camera around it and up / down); at a shop's door: go in; at a repair shop's counter: trade; at a people container: let everyone out |
| F2 | design mode (solo): the world freezes and the map editor opens - fly with WASD, turn with the arrow keys or a right-button drag, the wheel flies forward; click picks what is under the cursor, Shift+click adds more; Esc stops placing, clears the selection, then asks to leave |
| M | sound on / off |
| Esc | pause menu: resume, restart the round, Settings (controls, sound, friendly fire, steering, graphics, resolution - also on the title screen), **Report a problem or an idea**, main menu |

Driving: W / S throttle and brake (reverse), A / D steer, Space handbrake.
Running over a person costs points; robots take ram damage (several hits).
Motor vehicles have their own health (shown next to the speed): while you
drive, shots hit the vehicle, not you. A vehicle shot to pieces explodes,
and whoever is inside burns.
Street furniture goes over by weight and speed (`Props.CRUSH`): a motorbike
knocks over bins and crates, a car benches, barrels and planters (and lamps
and signals when fast), a truck, bus or the harvester almost anything,
concrete barriers included. Vehicles are cover: a car between a robot and
you takes the shot.

## The armoured harvester

A combine harvester from the interior, armoured with welded plates, waits on
a street near the start of every phase. Its spinning reel shreds any robot it
runs into, and any robot or swarm drone standing against the blades in
front is cut too, 150 a second, even with the harvester standing still;
its driver takes a quarter of the damage.
Its unloading auger is a corn cannon: click fires corn cobs where the
crosshair points (a yellow ring marks where they land). The camera looks
over the cab's left shoulder, by the auger: the mouse turns the aim and
raises or lowers it, up to drones in the sky.

## Studio (title screen)

**Studio** on the title screen works on whole cities: the list of cities and
their phases (area, buildings, films, edits folder), **Import a new city**
(place, menu name, map size, phases - runs `tools/map/new_city.py`),
**Rebuild this phase** (map pipeline + Godot import) and **Edit this phase**,
which opens it without robots, already in design mode.

## Map editor (design mode)

F2 opens the editor over the frozen phase. The mouse moves a free crosshair
(the view stays put; right drag or the arrow keys turn it): click picks,
hold the click on the selected object and move the mouse to slide it over
the ground (never onto the street, a wall or a roof), Q / E turn it. Tab
locks the mouse to look around as in the game. WASD / Space / Ctrl fly, the
wheel flies forward and back.

- **Nothing is saved on its own**: the title shows "*unsaved" while there
  are changes; *File > Save* (Ctrl+S) keeps them, *Discard* goes back to
  the saved map, and leaving design mode with unsaved changes asks: save
  and leave, don't save, or stay.
- **Menu bar** (top): *File* - open another phase (straight into its
  design mode), save, discard, share these edits as a mod, rebuild this
  map, leave; *Edit* - undo the last placing
  (Ctrl+Z), remove the selection (Del), select none (Esc), stop placing;
  *View* - show or hide the palette and the inspector; *Help* - the keys.
- **Palette** (left), like Delphi's component palette: groups that open and
  close, a picture of every model (rendered once, kept in `user://thumbs/`),
  the name on mouse-over and a search box. By type (default) joins all
  collections; off, it goes by collection. Click a model, then click the
  world to place it; Q / E turn it. Items (healing, weapons, parts...) put
  down a pickup spot.
- **Object Inspector** (right): nothing selected, the map - which item plays
  each role here, the bus line for new stops, what its user edits hold. One
  object: kind, model, definition (type, category, tags, effect, sound),
  position, turn and size; a model placed by hand can be named, moved,
  raised and turned there (saved to the map's user edits; the name stays
  through rebuilds). Several objects (Shift+click): the list and a button to
  remove them together.
- **Drag and drop**: press on the selected object and drag - a model placed
  by hand moves over the ground, a wall photo slides on its wall (kept with
  File > Save). Items on the ground and trees are picked like any object.
- **F1** sends everything selected to Claude as references.
- **Photos on walls**: click a building, *Put a photo on this wall...*,
  choose any picture - it covers that side of the building at once (no
  rebuild). Click the photo: the inspector slides it along the wall, moves
  it up and down and out, sizes it (keeping its proportions or not), turns
  it, fits it over the whole side again, changes the picture or removes it.
  Several photos can cover one facade.

**Without the sources** (the released game: executable and `.pck`), the
editor keeps the edits in the game's user folder (`user://maps/<map>/`) and
the game applies them itself when the phase loads: placed models, item
spots, roles, bus lines, removed objects and wall photos. Building heights,
paving and rectified photos need the map pipeline, so those tools only show
when playing from the repository (`edits.gd` decides;
`CITY_INVADERS_NO_SOURCES=1` plays as the released game does).

Click a building: its panel shows the OpenStreetMap id, name and
address. Change its height (a yellow ghost shows the new volume), then:

- **Save change** - written to `maps/<map>/user/buildings_user.json`, keyed by the OSM id
- **Open in OpenStreetMap** - the building's page on openstreetmap.org
- **Send to JOSM** - with JOSM running and Remote Control on (port 8111),
  loads the building with `height` / `building:levels` set; review and upload there
- **Rebuild map and restart** - runs the map pipeline and reloads the game

- **Photo on this wall...** - choose a photo; it is rectified onto the clicked wall

Design mode is also how the DevAgent sees what you point at.

Click the city again to fly on. Edits survive a rebuild from fresh OSM
data (they are keyed by OSM id), and once uploaded to OSM they are no
longer needed locally.

## Online: Bah, reports and mods

Needs an internet connection; everything else works without it.

- **Bah** answers any question about the game through an AI on the City
  Invaders server (tablet > Bah > first row). About 20 questions every 10
  minutes; if she is "resting", the quick questions still work.
- **Report a problem or an idea**: pause menu (Esc). Pick bug / idea /
  other, write what happened, and send a picture of the game as it was when
  you paused. The developers read every one.
- **Mods**: maps changed by other players - placed models, items, bus
  lines, wall photos. Title screen > Mods lists the published ones: Install
  puts one on its map (your own edits are kept and come back with Remove).
  Share your own from the map editor: File > Share these edits as a mod
  (it is reviewed before others see it). See docs/MODDING.md.

## Weapons

| Weapon | Rounds | Notes |
|---|---|---|
| 9 mm pistol | 12 | starting weapon |
| AR carbine ("machine gun") | 40 | automatic |
| .38 revolver | 6 | heavy rounds, slow |
| 12-gauge side-by-side | 2 | 9 pellets per shell, deadly up close |

Weapons and ammo lie on the streets.

### Grenades of the resistance

Two kinds (type `Grenade`, their own group in the editor's palette), up to 4
of each; one found on the street gives 2. **Q** throws the one picked
(**Z** switches) along your view in an arc - about 15 m looking straight,
further looking up; it bounces and rolls, its light blinking faster as the
fuse runs down.

| Grenade | Fuse | Effect |
|---|---|---|
| **Bergamota de Aço** - a segmented steel ball painted orange, a pull ring | 2.2 s | a 6 m blast: robots hurt by how near (up to 200), drones and swarm drones brought down, people (with friendly fire) and players hurt too |
| **Porongo EMP** - a porongo bound in metal round a recovered URB core | 1.6 s | a blue 9 m pulse: robots stand dead still and do not shoot for 6 s (a mech 3 s), drones and swarm drones drop |

A repair shop builds a Porongo for a core and a circuit.

## Pickups

| Pickup | Effect |
|---|---|
| Costela fogo de chão | +35 health |
| Chimarrão | +20 health |
| Remédio (Farmácias São João counter) | +50 health |
| Espeto | weapon 6: a skewer with meat, a strong melee blow (45) |
| Laço | weapon 5: throw it along the crosshair (22 m; the crosshair turns into a yellow ring when something is in reach). A robot is held still for 6 s, a mech only slowed; a drone is pulled down and becomes yours (drones in the HUD) |
| Pala | armour 100 (ARMOR in the HUD): takes half of every hit, rounded up, until worn through (`Tune.pala_absorb`) |
| Fruki guaraná | adrenaline: +25 health, run 40 % faster and reload twice as fast for 12 s |
| Ammo crate | ammo for the weapons you carry |

## Score

| Event | Points |
|---|---|
| Robot destroyed | +100 |
| Drone shot down | +150 |
| Mech destroyed | +500 |
| Coletor destroyed | +300 (+250 more if it was carrying someone, who runs free) |
| Swarm drone | +40 |
| Relay antenna down | +800 |
| People let out of a container | +100 each |
| Phase completed | +1000 (everyone) |
| Civilian killed by you (shot or run over) | -100 |
| Civilian killed by a robot | -20 (everyone) |
| A container taken by the mothership | -300 and -50 per person in it (everyone) |
| Dying (Medium / Hard) | -150 / -300 |

## The city

- Pedestrians (Grêmio and Inter fans, gaúchos pilchados, skaters, dogs),
  street vendors at their stalls, Brigada Militar officers who fight the
  robots (and shoot back if you shoot them with friendly fire on). An officer
  has 75 hp (a civilian 45, a robot 60) and holds off one robot, but two
  robots usually bring them down; `Tune.police_*` / `robot_aim_officer`
- Quero-queros, the bird of Rio Grande do Sul, in pairs on the lawns: come
  within 8 m and they face you with their alarm display, call and feint; come
  within 4 m and both run at you and peck (4 each, robots too) until you are
  well away from their patch. Gunfire doesn't move them, but they can be
  hurt: a shot (pistol, punch, a shotgun pellet) wounds one and it flies off
  low, calling, to another lawn; a second shot, a blast or a car over it
  kills it (`quero_quero.def.json` holds their numbers)
- Buses run a round of the map's bus stops (the OSM shelters, nearest-next
  order; shortest way through the street graph, re-entering from the border
  where the graph is cut) and pull up at each for 6 s; people waiting by the stop walk to the rear
  door and get on (the bus holds a few seconds for them), others get off.
  Placing bus shelters in the map editor (Common / Transport) designs the
  route: the buses then serve those, in the order they were placed. Get on by a rear door
  (E) to ride as a passenger - you can look round and shoot out - and E again
  to get off; the front door is the driver's seat
- Traffic with drivers: cars, buses, Charrua fuel tankers (explode when shot
  to pieces), Fruki delivery trucks (the big tractor-trailer on avenues), motorcycle couriers, cyclists, horsemen; shoot a vehicle and its
  driver bails out
- Landmarks of the Centro Histórico (Porto Alegre): the Theatro São Pedro,
  the Casa de Cultura Mario Quintana, the MARGS, the Memorial do RS, the
  Chalé da Praça XV, and on Praça da Matriz the Catedral Metropolitana and
  the Palácio Piratini can be entered - **E at the main entrance**: the doors
  open once the rooms are ready (a moment), E again outside closes them.
  The Paço Municipal, the Fonte Talavera and the Praça da Alfândega's
  monument stand as they are.
- Shops you go into: every pharmacy, market, bakery, restaurant, bank and
  repair shop that OpenStreetMap knows becomes a storefront with the shop's
  real name. **E at its door takes you inside** (also the shops on the
  ground floor of tall buildings); walk out through the door to be back in
  the street. Its name shows as you come in. The counter by the door holds
  what the shop gives: medicine at a pharmacy, mate or food at markets,
  bakeries and restaurants. Inside, robots can't follow
- Five-a-side pitches and playgrounds where OpenStreetMap has them, with
  football players (Inter and Grêmio shirts) and children playing; the
  children are never harmed and robots leave them alone
- Cars stop before a zebra crossing someone is on; the crossings are where
  OpenStreetMap has them
- Enterable buildings: Farmácias São João (Ed. Missões), Cine Imperial on the
  Praça da Alfândega (a film plays on the screen)
- Landmarks modelled to their footprints: Usina do Gasômetro and its chimney,
  Mercado Público, Paço Municipal, Sulacap; the Laçador and a farroupilha camp
  on the Gasômetro esplanade

## The field tablet

T raises the tablet (put away with T). Until it has been opened once, a line under the crosshair says so; and with robot parts enough to trade (or full pockets) the same line, 10 s a minute, sends you to the tablet's GPS for a repair shop, until you have used one. Its screen is drawn with the
tablet's own art (`gadgets/tablet/ui/`: the pampa wallpaper, the app
screens, the map pictograms). The home screen holds eight apps - 1-8, or the
arrows and Enter: GPS (the street map around you with robots, Coletores,
swarms, spotted antennas and the exit as pictograms; pharmacies, fuel
stations, markets, restaurants, hospitals and banks from OSM on cyan discs,
the repair shops you can trade at on orange ones - the corner map shows
these too; people containers with the GPS upgrade; and the street you are
on; **Enter lists where to go** - the exit, the nearest repair shop,
pharmacy, market, restaurant..., the camp, pitches, playgrounds and skateparks,
containers (with the upgrade), spotted antennas - and draws the way there
along the streets in yellow, on the corner map too; through the
information glasses the way shows as chevrons on the ground ahead with
the distance left; arriving ends the route), Radio (the arrows change the station, Enter or Space plays or stops it, on foot
too), Bah, the assistant (the first row, "Pergunte o que quiser à Bah",
opens a line to type your own question - Tab jumps straight to it: the answer comes from an AI on the
City Invaders server and knows your situation - map, health, weapon,
parts; the quick questions below answer offline from
`gadgets/tablet/bah_faq.json`), TchêTube (the game's own videos from
`video/tchetube/`, titles in its `titles.json`: Enter plays and pauses,
Backspace back to the list; the radio stops while one plays) and Peças (the
parts you carry); Tracker, Messages and Settings are still to come (the
Camera's tile holds TchêTube for now). Backspace goes back to
the home screen.

## Robot parts and repair shops

**Information glasses** (found on the ground, or 2 lenses + 2 circuits at a repair
shop), O on / off: robots and drones nearby are bracketed with their distance
(through walls), a Coletor carrying someone in orange, antennas within 260 m,
parts on the ground. They run 150 s on a charge; a drone battery refills them.

A downed mech drops its **arm cannon** (key 7 once picked up): three heavy
shells a magazine that burst where they land, hitting every robot around,
leaving craters on walls and wrecking the shops nearby.

The pockets hold 4 parts; a **mala de garupa** (the striped gaúcho saddle
bag, found on the ground) holds 30. Dying loses it with the rest. With the
pockets full, walking over a part says so: trade parts at a repair shop, or
find a mala de garupa.

Downed robots leave parts on the street for 40 s: a trooper 1-2 circuits, a
mech a power core and two circuits, a drone a lens, a Coletor a capsule
module and a circuit. They are lost on death. Repair shops (assistência
técnica - OSM electronics, phone, computer and repair shops, or placed by
hand with a `"type": "repair_shop"` entry in `_props`) trade them, E at the
counter: tower detector (the nearest antenna shows on the GPS: 4 circuits +
1 lens), drone battery +60 s (3 circuits + 1 core), build a drone (1 module
+ 3 circuits), GPS upgrade: people containers (1 module + 2 circuits; kept
after death, it is the tablet's), reinforced pala (3 circuits), ammunition
(2 circuits).

## Difficulty

Every round starts unarmed: pistols lie on the streets (two a short walk
from the start), the other guns further off. Empty-handed, the click
punches, punches and kicks (14 / 14 / 24 damage, 2.2-2.6 m reach): the fists are seen in first person (a right hook each time) and the third blow is a kick with the leg; every blow counts when it lands.

A map in the top-left corner shows the streets around (heading up), robots
in red, spotted relay antennas in orange, the phase exit in green, shops on
small discs and the name of the street you are on - while you drive (the
car's GPS), or on foot through the information glasses (projected, cyan).
Otherwise the map is on the tablet (T). With the radio on, the engine steps
back under the music.

Chosen on the title screen or in Settings (the host's choice applies to the
round); all values are in `scripts/difficulty.gd`.

| | Easy (as the game first played) | Medium (default) | Hard |
|---|---|---|---|
| Trooper / mech / drone / commander health | 60 / 360 / 30 / 900 | 100 / 700 / 45 / 1500 | 140 / 1100 / 60 / 2200 |
| Damage per hit (trooper / mech) | 5 / 10 | 8 / 14 | 11 / 18 |
| Time between their shots, best accuracy, sight | 1.8 s, 60%, 35 m | 1.4 s, 80%, 40 m | 1.1 s, 90%, 50 m |
| Robots at once per player, rest between waves | 8, 25 s | 12, 18 s | 16, 12 s |
| Dropships while the relay antenna stands | x0.8 | x0.6 | x0.45 |
| Goal (Gasômetro / Centro / Mercado), mechs | 20 / 25 / 30, 2-4 | 30 / 35 / 40, 3-5 | 40 / 45 / 55, 5-7 |
| Pickups, pala absorbs | x1.3, 60% | x1, 50% | x0.7, 40% |
| Dying (always with empty hands: the whole inventory is lost) | back in 2 s | back in 4 s, -150 | back in 6 s, -300 |
| Relay antennas per phase | 3 | 4 | 5 |
| People lost | each 2 lost add a robot to the goal | the same | and losing 30% of them loses the phase (it starts over) |

Weak points on every level: a mech's front plates halve a bullet, its
reactor at the back doubles it; a trooper's head takes double, its legs 70%.

## The enemy

- Mech cannon: every ~12 s a mech in a fight fires a missile at its target
  - you see it coming (a smoke trail, the motor's glow, ~32 m/s) and it
  bursts where you were when it was fired, so running off dodges it: a 4 m
  blast that kills people and hurts players (35); a wall in the way gets a
  scorched crater and a pile of rubble on the ground below.

- URB-C4 Coletor: no gun; it runs down a civilian on their own (nobody
  within 8 m) and stows them in the glass capsule on its back (you see them
  in it, as a grey figure). It carries them on foot to the nearest **people
  container** with room and puts them in, then goes hunting again; no ship
  comes for each captive, only the mothership for a full container. Bring
  it down on its way and they run free (+250). With no container on the map
  it makes for a map edge instead. 1 / 1 / 2 on the prowl by difficulty.
- People containers (2 / 2 / 3 by difficulty, seen through the information
  glasses): the mothership brings each one at the start and sets it down on
  a square or wide pavement as far from every player as the map allows
  (150 m+), so they have to be searched for. They are on the GPS only
  after the repair shop's **GPS upgrade** (a Coletor's capsule module and
  2 circuits): then purple, with how full, red when full. The information
  glasses show those within 260 m. Glass tanks holding the
  captives as plain grey figures, `n / capacity` above them (10 / 8 / 6). E at one lets
  everyone out (+100 each). A full one calls the **mothership**: it comes
  down, its beam slowly lifts the container (you can still open it, then it
  drops back empty) and flies off with it - everyone inside is lost,
  -300 and -50 a person, and the mothership brings an empty one, again far
  from the players.
  Three containers taken and the round starts over.
- URB-S2 Enxame: small drones hunting a player, 4-6 / 6-8 / 8-12 by level
  (easy / medium / hard; two more for each extra player). A third are
  kamikazes circling close: now and then one blinks and dives at where you
  were when it began to blink - step aside and it misses - blowing up
  there (6 / 9 / 12 to a player, 40 to anyone else within 2.8 m), one every
  3.2 / 2.6 / 2.0 s. The rest are gunners higher up and further out: a red
  glint, then a small bolt (2 / 2 / 3) when they can see you - an awning or
  a corner is cover. With the kamikazes gone a gunner turns kamikaze now
  and then. One shot each. A swarm every 150 / 110 / 75 s. Standing in the
  open without a pala and not shooting back: alive after a minute on easy,
  about 30 s on medium (a minute when you keep moving), 12-20 s on hard.

- URB-07 troopers: patrol, hunt civilians, fan out around players; with nobody
  in sight they fire into occupied cars nearby and chase the driver who bails
  out, or shoot lamps and bins they can see
- URB-H9 heavy mech: arrives by dropship, slow and very tough
- URB-D3 drones: circle and shoot, call nearby robots
- Dropships bring reinforcements; the AI director paces the waves

## Who made the game

City Invaders is made by **Vilson Cristiano Gärtner** and is open source.
Contact: vilson@gartner.net.br (players may be given this address when
they ask how to reach him).

## Graphics settings

Settings > **Graphics** (LOW / MEDIUM / HIGH: which screen effects run),
**Ambient occlusion** on / off (soft shadows in corners; about a quarter of
the frame on a large screen) and **Resolution**: AUTO starts from the
screen's size (about 6 million pixels drawn: a large screen a little under
60 %, a 1080p one at full size), lowers it when the frame rate drops - and
only keeps a step down that really brought frames back - and raises it again
when there is room; 100 % draws every pixel; 85 / 67 / 50 % draw it
smaller and scale it up to the screen (MetalFX on a Mac, FSR elsewhere) -
on a large screen (4K, ultrawide, a Retina display) 67 % roughly doubles the
frame rate with hardly a visible difference.
