# Ideas and plans

A running list of game ideas from play-testing sessions, so none get lost.
Status: **open** (not started), **planned** (agreed, next up), **partial**,
**done**. Newest additions at the top of each section.

## Economy: robot parts, repair shops, gadgets

- **done** (first version) Robots drop parts: trooper 1-2 *circuits*, mech a *power core*
  and circuits, drone an *optical lens*, Coletor a *capsule module*. They lie
  ~30 s, pulled in when you pass close. Lost on death (Hard).
- **partial** (counter placeholder, 5 offers) Electronics repair shops (*assistência técnica*): OSM
  `shop=electronics|mobile_phone|computer` points become shops; trade parts
  for gadgets: tower detector (beeps faster towards the nearest antenna),
  longer drone battery, armour, ammo, guns; or money (score / buying food at
  the Mercado Público). Few part types, one value - not a spreadsheet.
- **done** GPS **routes** on the tablet: the player picks where to go (from a
  list - the exit, a repair shop, the farroupilha camp, a landmark, a spotted
  antenna) and the map draws the way there along the streets (road graph
  shortest path), turn by turn.
  With the information glasses on, the route is projected on the view too
  (the corner map shows through the glasses already).
- **open** Map bounds that end just past the outer road loop: an import
  widens its bounds to the next ring of roads (today `--ring` only keeps the
  traffic inside the loops, and skips maps where they are too small).
- **open** Mods in the game: share your map edits as a mod (zip of
  `user://maps/<map>/`), browse the published ones and install them (the
  server side is done, docs/ONLINE.md).
- **open** The **tablet** (bought / built at a repair shop) holds apps: GPS
  (today's map), music (the radio), camera (photos - use to be found), and
  later apps installed at repair shops with parts. GPS upgrades show more:
  robots, drones, mechs, antennas, people containers. Notifications with a
  sound (e.g. a Coletor took someone). A gaúcho-flavoured gadget design.
- **open** The GPS shows shops, pharmacies, restaurants, petrol stations from
  OSM; later OSM POIs place the matching building model / interior set
  automatically (pharmacy, petrol station, cinema, repair shop...).
- **done** **Mala de garupa** (saddle bag): without it the pockets hold 4
  robot parts, with it 30; two lie about each map (an item), half the horses
  carry one behind the saddle; lost on death. Next: take it off a horse.

## Gadgets: glasses, tablet apps

- **open** **Smart glasses** (*óculos*): worn, they lay information over
  the world that is normally hidden - the street map in a corner, robot
  outlines and health through walls nearby, the Coletor's captive, spotted
  antennas as markers on the horizon, Bah's tips as a line of text, parts on
  the ground highlighted. Found or bought at a repair shop; a battery like the
  drone's; upgrades show more (the glasses version of the tablet's GPS).
- **partial** (app done, two videos) **TchêTube** app on the tablet: a video player with the game's
  own videos (made in Flow). Next: its own icon, unlock a video per phase. Video ideas:
  - *Telejornal do Interior*: a news bulletin - "robôs pousaram no Gasômetro",
    the anchor in front of the Guaíba, eyewitnesses with chimarrão
  - *Como laçar um drone* - a gaúcho tutorial, the laçador explains the
    technique (an in-game hint in disguise)
  - *Receita de churrasco de campanha* while robots pass in the background
  - *Defesa Civil*: how to reach a shelter, where the meeting points are
  - *Os mechs da Borges*: phone footage of a mech walking down Av. Borges de
    Medeiros (the next phase's teaser)
  - *Gaitaço contra os invasores*: a gaita concert at the Farroupilha camp
  - *Previsão do tempo*: the weather girl, the swarms as "nuvens de drones"
  - *Unboxing do tablet de campo* by a teenage influencer
  - Each phase cleared unlocks one video (a reason to replay).
- **open** Notifications on the tablet (card slides in from the top, the
  art's template is in `gadgets/tablet/ui/`), Camera, Tracker, Messages and
  Settings apps.

## Editing without the sources

- **done** (first version) Map editing in the released game: edits go to
  `user://maps/<map>/` and the game applies placed models, item spots,
  roles, bus lines, removed objects and wall photos at runtime. Next: share
  a phase's edits as one file (a "mod"), heights without the pipeline.

## Bah - the in-game assistant

- **done** (FAQ, on the tablet) A tablet app "Bah" (the player's AI assistant): "Olá, eu sou a
  Bah, tua assistente de IA - como posso te ajudar?" and a menu of questions
  and answers about the game (what to do, what each item is for, how to
  carry more - the mala de garupa...). First as a FAQ, no AI.
- **open** Later a real chat: an online service the game talks to, with an
  LLM whose context is the game's own docs (`docs/*.md`, entity
  definitions), answering in the player's language. Needs a server holding
  the API key (never in the game), rate limits and cost control, and an
  offline fallback to the FAQ.
- **open** Prompts for the app icons and interface art of the tablet.

## Data-driven objects (types, inheritance, links)

- **partial** (items done: docs/ENTITIES.md) Entity definitions next to each model (`<model>.def.json`):
  `type` + `extends` (e.g. Pickup -> Healing -> Churrasco), attributes (heal,
  sounds, behaviour, collision, points) and tags (`bus_stop`, `healing`,
  `weapon`, `shield`). The Studio palette by type across collections; the
  game reads the definition when an object is placed, so the Director knows
  what it is; links are attributes pointing at other objects (a bus line =
  ordered list of stop ids).
- **open** Per-map choice of the object for each role in the Studio: for POA
  the *mala de garupa* is the backpack, *churrasco* the medkit, *Fruki* the
  adrenaline shot - nothing hard-coded.
- **open** Bus lines in the Studio: which bus runs which route, stops placed
  by hand (today: one route = shelters in placement order).
- **open** Map packs: a map can bring its own radio stations, loading music,
  cut scenes (`maps/<map>/music`, `maps/<map>/video`), falling back to the
  collection's.

## Enemies and invasion

- **open** A second ship (or the mothership) drops Coletores and swarms, so
  they don't appear out of nowhere.
- **done** (placeholder models)
  Coletores bring captives to a transport ship that flies them to
  one of several **people containers** hidden on the map (like the
  antennas). Full (e.g. 10 people on Easy), the mothership lifts it away:
  points lost plus another penalty; 3 containers lost = **game over**.
  Players must find containers and free the people (open them).
- **partial** Mech cannon: blast, crater and rubble pile (placeholder boxes);
  next: rubble models, buildings that collapse at points marked in the Studio.
- **open** Defence against swarms (they kill too fast): a shotgun spread
  bonus vs. small targets, a jammer gadget from the repair shop, the laço
  catching one drone out of the swarm, an EMP grenade.
- **done** Coletor, Enxame, several antennas, people running from robots as
  a hint, crowd bubble and groups.

## Weapons and moves

- **done** Kick model (a leg: bombacha, bota campeira, espora) for the unarmed
  attack - every blow is a kick (front, sometimes from the side).
- **done** First-person fists from the CC0 "fps arms (rigged only)" rig
  (OpenGameArt, MakeHuman base), posed and animated by
  `tools/blender/fists_viewmodel.py`. Next: a shirt sleeve, a better hook.
- **partial** Espeto (barbecue skewer) as a weapon: model delivered
  (`espeto_churrasco_arsenal_fps_v2`).

## Places and models to request

- **partial** (place_kinds.json: fuel, pharmacy, hospital, market,
  restaurant, repair shop) Import knows what each building is from OSM and
  places a fitting model (the fuel station) or a sign, items and GPS
  pictograms. Next: generic models per kind (a pharmacy, a supermarket, a
  bank), interiors for them, more kinds (bank, school, church, police).

- **done** Usina do Gasômetro and its chimney (117 m) as hand-made landmarks:
  open hall, two galleries, stairs, terrace; placed at their map spots
  ("at" / "yaw" in the user edits).
- **done** Mercado Público with seven reusable stalls (*bancas*, 72 placed),
  aisles, the upper gallery and stairs (a layout landmark, scaled 0.8 to
  its OSM footprint). Next: vendors and shoppers at the layout's markers.
- **partial** Interiors as ready "sets" (prefabs): office, pharmacy, cinema,
  supermarket, clothes shop... (first pack delivered: six interiors).
- **open** Free CC0 sources to reuse: Poly Haven (realistic), Kenney Food
  Kit / Furniture Kit, KayKit Furniture Bits, Quaternius (FBX/OBJ).

## Maps and performance

- **open** Background crowd for distance (impostors), POI crowds (stops,
  plazas, market, waterfront, camp), people reacting to the invasion.
- **open** Load time (~50 s): investigate.
