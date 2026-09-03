## Bridge interactive RGA panel to WebGL front end, compiled through Nim's JS backend.
##
## Every join, meet, attitude, support, expansion, projection, pick and drag browser
## offers is computed by same modules desktop draws through.
##   `pga`, `objects`, `mesh`, `camera`, `scene`, `picking`, `interaction` and
##   `storyboard`.
##   Only presentation (WebGL calls, DOM, pointer input) is JS's own, as OpenGL/SDL/Dear
##   ImGui are desktop's presentation over same CPU-side geometry.
## Full parity with desktop.
##   Add point, apply any catalogue operation to two picked operands, drag from one object
##   onto another to derive third, edit any object's label, palette slot, visibility or
##   raw coefficients, remove object, save or load scene, and orbit/pan/dolly camera by
##   drag or typed numbers.
##   Entire surface `panel.nim` lays out for Dear ImGui, offered as exported procs
##   hand-written presentation layer drives.
## Not carried over: `scene.toCstring`, `format.appendMagnitude` and every desktop-only
## diagnostic.
##   Arena accounting and SDL/OpenGL loop timing depend on C FFI or on addresses JS has
##   no notion of.
##   What coefficient should read as is this project's rule, so `nimFormatNumber` answers
##   from `format.formatMagnitude` rather than JS `toFixed`.
##   Browser diagnostics substitute (frame time via `requestAnimationFrame`, JS heap where
##   available) covers same purpose without pretending to same numbers.
## Desktop's file-path save/load becomes browser download/upload of identical `.rgascene`
## binary; see `scene.nim`.
##   This module exposes raw per-item fields rather than bytes, since packing IEEE-754
##   doubles by hand in Nim/JS would reinvent browser's `DataView`.
##
## Browser entry point; see `visualiser.nim`'s "Render Paths" table for module split.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../../pga
import ../core/[
  algebra_trace, algebra_view, boundary, camera, format, framing, help, history,
  interaction, marker, orrery, picking, ramp, scene, selection, storyboard, tessellate,
  timings,
]



var g_scratch: DrawScratch
  ## Hold where tessellation step assembles ribbon pieces before emitting them.
  ##   Fixed buffer rather than desktop's frame arena, which casts pointer over global and
  ##   carves typed slices, neither possible on JS backend.
  ##   Sized by `LINES_GRID_MAX`, most one-piece chords grid family can lay.


proc performanceNow(): float {.importjs: "performance.now()".}
  ## Read page's monotonic clock, in milliseconds.
  ##   Bridge's one piece of interop beyond exports: per-phase draw timings bracket work
  ##   inside one call, which single caller-supplied reading cannot.
  ##   Confined to timing; no rule may read it.


type
  FlatBuffer = ref object of RootObj
    ## Define opaque handle on JS `Float32Array`, never constructed in Nim.
    ##   Page's own memory, filled from here.
    ##     `seq[float32]` on this backend is JS `Array` of boxed doubles, converted element
    ##     by element into staging `Float32Array` `gl.bufferData` wants, paid per frame
    ##     purely as representation.
    ##     Written straight into typed array, `uploadBuffer` hands it to driver untouched.
    ##   Narrowing to `float32` moves from upload to fill; uploaded bytes are identical.

  FlatFloats = object
    ## Define flat buffer at full capacity, and how much of it this frame filled.
    ##   Allocated once at cap matching mesh is bounded by, never grown: fixed-capacity
    ##   rule `mesh.nim`'s caps state.
    values: FlatBuffer
    used: int

proc newFlatBuffer(count: int): FlatBuffer {.importjs: "new Float32Array(#)".}
proc `[]=`(buffer: FlatBuffer; index: int; value: float32) {.importjs: "#[#] = #".}
proc prefix(buffer: FlatBuffer; count: int): FlatBuffer {.importjs: "#.subarray(0, #)".}
  ## Report first `count` entries as view.
  ##   No copy, and `instanceof Float32Array` still holds, so `glue.js` uploads it with
  ##   nothing in between.

proc initFlatFloats(capacity: int): FlatFloats =
  ## Reserve flat buffer of `capacity` floats, empty.
  FlatFloats(values: newFlatBuffer(capacity), used: 0)

proc view(flat: FlatFloats): FlatBuffer = flat.values.prefix(flat.used)
  ## Report just part this frame filled, for upload.
  ##   One small view object per buffer per frame, seven in all, against whole buffer of
  ##   element-by-element conversion it replaces.

proc `[]=`(flat: var FlatFloats; index: int; value: float32) = flat.values[index] = value
  ## Write one float into flat buffer.



#[ Panel State ]#

# Read `SettingsFurniture` from `camera`, shared with desktop's hold.


type SettingsOverlay = tuple
  ## Define everything overlay's shared draw extent and view-projection depend on.
  ##   Camera's whole placement and viewport asked about.
  target_x, target_y, target_z: float
  distance, azimuth, elevation, degrees_field_of_view: float
  width, height: int

type ShapedMarker = tuple
  ## Define one shaped marker beside everything it was shaped from; see `g_shaped_marker`.
  slot: int
  width, height: int
  progress: float
  is_touch: bool
  swell: float
  travel: float
  settings: SettingsOverlay
  marker: ref Marker ## Boxed, and box is point.
    ##   `Marker` is wide variant object (two pulse runs, loop, both bands), and JS backend
    ##   deep-copies every value assignment through `nimCopy`.
    ##   Stored by value, memo's store-and-read copies marker twice and costs as much as
    ##   shaping it replaces; behind ref, one copy at store, none at read.


type SettingsScene = tuple
  ## Define everything scene's own meshes are built from.
  ##   `SettingsFurniture`'s rule, one layer out: two frames agreeing here draw same scene
  ##   records, so second may keep first's.
  ##   Furniture tuple is carried whole, since it names camera, framebuffer height and
  ##   field of view: everything `drawExtentFor` reads.
  ##     It also names two furniture toggles scene does not read; over-approximation
  ##     costing one rebuilt frame when reader switches grid off.
  ##   `aspect` is here because view-projection matrix reads it and furniture does not.
  ##   `revision` is scene's own; see `scene.revision`.
  ##   Three things are guards instead; see `nimBuildFrame`.
  ##     Ghost or drag preview standing (moves with pointer), debug layer on (draws
  ##     cursor's ray), appear animation running.
  furniture: SettingsFurniture
  aspect: float
  revision: int
  revision_selection: int ## `selection.revision`, never selection itself.
    ## Comparing and copying `ITEMS_MAX` ints per frame is capacity-scaled work for scene
    ## of five.
  is_algebra_shown: bool


var
  g_scene: Scene
  g_camera: Camera
  g_trace: AlgebraTrace ## Scratch debug layer records into.
    ## Held and reused rather than declared per frame, being `ITEMS_MAX` entries long; see
    ## `algebra_view.addFrameTrace`.
  g_meshes_furniture, g_meshes: MeshSet ## Meshes held at module scope and reused every
    ## frame via `clearMeshes`.
    ## `clearMeshes` resets each mesh's `count_vertices`, not storage, mirroring
    ## `visualiser.nim`'s `MESHES`/`MESHES_FURNITURE`.
    ## As `nimBuildFrame` locals, each call reallocates and zero-fills whole fixed
    ## storage regardless of object count: `MeshSet` reserves it up front, and JS backend
    ## has no stack allocation.
  g_settings_scene = none(SettingsScene) ## What scene meshes standing in `g_meshes` were
    ## built from, or none before first build.
    ## Furniture's hold, one layer out; see `SettingsScene` and `FrameData.is_scene_held`.
  g_settings_furniture = none(SettingsFurniture) ## What furniture standing in
    ## `g_meshes_furniture` was built from, or none before first build.
    ## See `FrameData.is_furniture_held`.
  g_count_grid_segments = 0 ## How many ribbon segments ground grid alone was last built
    ## from, axes' fixed share excluded.
    ## Kept beside furniture rather than recounted: held frame draws grid it had and
    ## should report that grid's count rather than zero.
  g_settings_overlay = none(SettingsOverlay) ## What `g_scale_overlay`/`g_vp_overlay` were
    ## derived from, or none before first derivation.
  g_scale_overlay: DrawExtent ## Draw extent overlay calls share; see `ensureViewOverlay`.
  g_vp_overlay: Matrix4 ## View-projection those same calls share.
  g_box_marker: ref Marker = new(Marker) ## One box every shaping fills.
    ## Allocated once.
    ##   `Marker` reserves every marker kind's fixed arrays, so `new` per shaping is
    ##   kilobytes allocated and zeroed per selected object per frame.
    ## `markerFor` fills caller storage, so one box serves every call and
    ## `nimSelectionPulse` reads back what `nimSelectionMarker` filled.
  g_shaped_marker = none(ShapedMarker) ## Marker `nimSelectionMarker` last shaped, with
    ## everything it was shaped from.
    ## `nimSelectionPulse` asked same question in same frame reads answer instead of
    ## shaping again.
    ## Sound because overlay draws each slot marker-then-pulse back to back in one
    ## synchronous pass, and marker call always shapes fresh and overwrites this.
    ##   Key carries every non-scene input, so pulse asked at other settings shapes for
    ##   itself.
  g_interaction = Interaction(is_enabled: true) ## Picking and drag, always live here.
    ## No storyboard-capture mode to switch them off for.
  g_placed: array[ITEMS_MAX, Placed] ## What algebra says about each live slot.
    ## Placed once per edit, emitted every frame.
    ##   Nothing in `tessellate.Placed` reads camera, so placement stays true while view
    ##   orbits; recomputing every orbit frame is most of moving frame; figures in
    ##   `PROVENANCE.md`.
    ## Held for scene's slots only: ghost and drag preview move with pointer, so both are
    ## placed where drawn.
    ## Dead slots hold whatever last occupant left; every walk skips them.
  g_placed_revision = -1 ## Scene revision `g_placed` was filled at; -1 before first fill.
  g_born_last = 0.0 ## Latest birth stamp `stampBorn` has written.
    ## What says scene has stopped animating.
    ##   Every item fades in over `mesh.ANIMATION_SECONDS` from its stamp, so frame past
    ##   this plus window draws every item at full progress and next draws it identically:
    ##   condition scene hold needs.
    ## Watermark rather than scan of all `ITEMS_MAX` stamps per frame; only rises.
  g_borns: array[ITEMS_MAX, float] ## Birth stamps, one per slot, moment item is added.
    ## Read by `nimBuildFrame` so it animates in as desktop's newly-added item does.
  g_selection: Selection ## Items picked right now, in pick order.
    ## Each ringed by presentation layer's `refreshOverlay`.
    ## Replaced by every construction path, driven by touch/click gestures through
    ## `nimSelectOnly`/`nimSelectToggle`/`nimSelectClear`.
    ## Presentation layer keeps no list: pick order names operands, so it lives in
    ## `selection.nim`.
  g_operations: OperationMemory ## Which operation each arity's picker opens on.
    ## Carried from last apply.
  g_clock_pulse: PulseClock ## Each selected object's orientation-pulse phase, carried
    ## between frames.
    ## See `selection.PulseClock` for why phase off clock teleports.
  g_seconds_step_pulse: float ## How long frame being drawn is, for that clock.
    ## Held because `nimTickPulse` takes one reading and every `nimSelectionPulse` after
    ## it in same frame must advance by same step.
  g_tween_camera: CameraTween ## Carries camera toward whatever is being built or edited.
    ## See `camera.CameraTween`; aimed and advanced inside `nimBuildFrame`, from same rule
    ## desktop uses.
  g_history: History ## Undo/redo timeline of scene-content edits.
    ## Scoped as `visualiser.HISTORY` is; see `history.nim`.
    ## Seeded via `initHistory` wherever `g_scene` is replaced (`nimInit`, `nimLoadDemo`,
    ## `nimSceneClear`).
  g_ghost = none(Multivector) ## Multivector open edit session is staging.
    ## Rendered every frame like live object but never added to `g_scene`:
    ## `nimSceneSlots`, undo, save, picking never see it.
    ## Serves both session modes, composing and editing.
    ## None where no session is open, or last committed or was abandoned.
  g_preview = none(Preview) ## What open apply control would build.
    ## Ghosted while reader is choosing, as drag's rubber-band does.
    ## Own slot rather than `g_ghost`'s, so which shows is decided by `staged` in Nim.
    ## Written by `nimGhostOperation`, dropped by `nimClearPreview`.

const INK_GHOST = Ink.Guide
  ## Tint ghost in this palette slot, muted, reusing `Ink.Guide`'s "construction helper" role.


proc toRgbSeq(c: Rgba): seq[float32] = @[c.red, c.green, c.blue]
  ## Format colour as `[r, g, b]` triple, for caller formatting CSS colour string itself.


func countOverlay(mesh: Mesh): int =
  ## Count how many of one mesh's vertices are its overlay run, drawn with no depth test.
  ##   Zero where nothing asked to be drawn over; see `mesh.Mesh.index_overlay`.
  if mesh.index_overlay.isNone: return 0
  max(0, mesh.count_vertices - clamp(mesh.index_overlay.get, 0, mesh.count_vertices))


var
  # Hold one flat buffer per primitive, refilled in place every frame.
  #   Fresh sequences would be allocations per frame feeding collector for data living
  #   one frame.
  #   Consumer uploads or reads within same frame and holds nothing across two.
  g_flat_ribbon = initFlatFloats(RIBBONS_MAX*16)
  g_flat_furniture = initFlatFloats(RIBBONS_MAX*16)
  g_flat_point = initFlatFloats(VERTICES_MAX*7)
  g_flat_ring = initFlatFloats(RINGS_MAX*14)
  g_flat_disc = initFlatFloats(DISCS_MAX*13)
  g_flat_dome = initFlatFloats(DOMES_MAX*8)
  g_flat_runs = initFlatFloats((DISCS_MAX + DOMES_MAX)*3)
  g_flat_view: seq[float32] = newSeq[float32](16)


proc flattenRibbonsInto(ribbons: RibbonMesh; dest: var FlatFloats) =
  ## Interleave one frame's ribbon records for instanced upload, sixteen floats each.
  ##   Tail xyz, head xyz, width, fog, tail rgba, head rgba: `RibbonRecord`'s field order,
  ##   which attribute setup in `glue.js` reads back apart.
  dest.used = ribbons.count * 16
  for i in 0 ..< ribbons.count:
    template r: untyped = ribbons.records[i]
    dest[16*i + 0] = r.tail_x
    dest[16*i + 1] = r.tail_y
    dest[16*i + 2] = r.tail_z
    dest[16*i + 3] = r.head_x
    dest[16*i + 4] = r.head_y
    dest[16*i + 5] = r.head_z
    dest[16*i + 6] = r.width
    dest[16*i + 7] = r.fog
    dest[16*i + 8] = r.tail_red
    dest[16*i + 9] = r.tail_green
    dest[16*i + 10] = r.tail_blue
    dest[16*i + 11] = r.tail_alpha
    dest[16*i + 12] = r.head_red
    dest[16*i + 13] = r.head_green
    dest[16*i + 14] = r.head_blue
    dest[16*i + 15] = r.head_alpha


proc flattenDiscsInto(discs: DiscMesh; dest: var FlatFloats) =
  ## Interleave one frame's disc records for instanced upload, thirteen floats each.
  ##   Centre xyz, first arm xyz, second arm xyz, fill rgba: `DiscRecord`'s field order.
  dest.used = discs.count * 13
  for i in 0 ..< discs.count:
    template r: untyped = discs.records[i]
    dest[13*i + 0] = r.centre_x
    dest[13*i + 1] = r.centre_y
    dest[13*i + 2] = r.centre_z
    dest[13*i + 3] = r.arm_first_x
    dest[13*i + 4] = r.arm_first_y
    dest[13*i + 5] = r.arm_first_z
    dest[13*i + 6] = r.arm_second_x
    dest[13*i + 7] = r.arm_second_y
    dest[13*i + 8] = r.arm_second_z
    dest[13*i + 9] = r.fill_red
    dest[13*i + 10] = r.fill_green
    dest[13*i + 11] = r.fill_blue
    dest[13*i + 12] = r.fill_alpha


proc flattenRingsInto(rings: RingMesh; dest: var FlatFloats) =
  ## Interleave one frame's ring records for instanced upload, fourteen floats each.
  ##   `DiscRecord`'s thirteen in same order, then width, so ring and disc attribute
  ##   setups in `glue.js` differ by one trailing attribute.
  dest.used = rings.count * 14
  for i in 0 ..< rings.count:
    template r: untyped = rings.records[i]
    dest[14*i + 0] = r.centre_x
    dest[14*i + 1] = r.centre_y
    dest[14*i + 2] = r.centre_z
    dest[14*i + 3] = r.arm_first_x
    dest[14*i + 4] = r.arm_first_y
    dest[14*i + 5] = r.arm_first_z
    dest[14*i + 6] = r.arm_second_x
    dest[14*i + 7] = r.arm_second_y
    dest[14*i + 8] = r.arm_second_z
    dest[14*i + 9] = r.red
    dest[14*i + 10] = r.green
    dest[14*i + 11] = r.blue
    dest[14*i + 12] = r.alpha
    dest[14*i + 13] = r.width


proc flattenDomesInto(domes: DomeMesh; dest: var FlatFloats) =
  ## Interleave one frame's dome records for instanced upload, eight floats each.
  ##   Centre xyz, radius, rgba: `DomeRecord`'s field order.
  dest.used = domes.count * 8
  for i in 0 ..< domes.count:
    template r: untyped = domes.records[i]
    dest[8*i + 0] = r.centre_x
    dest[8*i + 1] = r.centre_y
    dest[8*i + 2] = r.centre_z
    dest[8*i + 3] = r.radius
    dest[8*i + 4] = r.red
    dest[8*i + 5] = r.green
    dest[8*i + 6] = r.blue
    dest[8*i + 7] = r.alpha


proc flattenWashRunsInto(washes: WashRuns; dest: var FlatFloats) =
  ## Interleave wash draw order, three floats per run: kind ordinal, first, count.
  dest.used = washes.count * 3
  for i in 0 ..< washes.count:
    dest[3*i + 0] = float32(ord(washes.runs[i].kind))
    dest[3*i + 1] = float32(washes.runs[i].first)
    dest[3*i + 2] = float32(washes.runs[i].count)


proc stampBorn(slot: int; born: float) =
  ## Record when item in `slot` arrived, and carry watermark with it.
  ##   One door birth stamps go through, so `g_born_last` cannot fall behind stamp written
  ##   directly, which would let scene hold engage over item still fading in.
  g_borns[slot] = born
  g_born_last = max(g_born_last, born)


proc flattenInto(mesh: Mesh; dest: var FlatFloats) =
  ## Interleave one primitive's vertices as `x, y, z, r, g, b, a, ...` into `dest`.
  ##   Ready for `gl.bufferData`.
  dest.used = mesh.count_vertices * 7
  for i in 0 ..< mesh.count_vertices:
    template v: untyped = mesh.vertices[i]
    dest[7*i + 0] = v.x
    dest[7*i + 1] = v.y
    dest[7*i + 2] = v.z
    dest[7*i + 3] = v.red
    dest[7*i + 4] = v.green
    dest[7*i + 5] = v.blue
    dest[7*i + 6] = v.alpha



#[ Setup ]#

proc placeSeeds(now: float) =
  ## Build same default scene desktop opens on with no saved scene.
  ##   Five seeds, nothing derived; mirrors `visualiser.main`'s startup.
  ##   Arrives as replay, like demo and loaded file: watching it build states that these
  ##   were placed one at time and everything else is derived from them.
  g_scene.restoreFrom(initScene())
  constructSeeds(g_scene, now)
  g_scene.replayFrom(now)
  for slot in 0 ..< g_scene.len: stampBorn(slot, g_scene.bornAt(slot))


proc nimInit(now: cfloat) {.exportc.} =
  ## Build default interactive scene and place camera at default orbit desktop opens on.
  placeSeeds(float(now))
  g_camera = initCameraDefault()
  g_selection.clear()
  g_history.initHistory(g_scene, g_camera)


proc nimLoadDemo(scale_ordinal: cint; now: cfloat; width, height: cint) {.exportc.} =
  ## Replace current scene with orrery, as ordinary live items.
  ##   One-click preset, every object as editable, removable and pickable as anything
  ##   built by hand, free slots there to build in.
  ##   Heaviest scene this build draws, at largest size, which is what demo is for.
  ##     Storyboard is unchanged and still what `visualiser --storyboard` captures; see
  ##     `orrery` and `storyboard.STEPS`.
  ##   Scene and camera come from `orrery.showOrrery`, which desktop's `--demo` calls too.
  ##     Preset is one copy shared by both front-ends; left here is only what this side
  ##     keeps of its own about scene.
  ##   `scale_ordinal` names one of `orrery.ScaleOrrery`'s three sizes; see `nimDemoItems`.
  let clock = float(now)
  showOrrery(g_scene, g_camera, int(width), int(height), ScaleOrrery(scale_ordinal), clock)
  for slot in 0 ..< g_scene.len: stampBorn(slot, g_scene.bornAt(slot))
  g_selection.clear()
  g_history.initHistory(g_scene, g_camera)


proc nimDemoScales(): seq[cint] {.exportc.} =
  ## Report every size demo can be loaded at, smallest first, as `nimLoadDemo` ordinals.
  ##   Page builds one button per entry rather than carrying its own list.
  for scale in ScaleOrrery: result.add(cint(ord(scale)))


proc nimDemoItems(scale_ordinal: cint): cint {.exportc.} =
  ## Report how many items demo comes to at one size, for button that loads it.
  cint(itemsOf(ScaleOrrery(scale_ordinal)))


proc nimDemoScaleDefault(): cint {.exportc.} = cint(ord(SCALE_ORRERY_DEFAULT))
  ## Report which size demo opens on when nobody has asked for another.



#[ Scene Inspection ]#

proc nimSceneCount(): cint {.exportc.} = cint(g_scene.len)
  ## Report how many items are alive in scene.


proc nimSceneCapacity(): cint {.exportc.} = cint(ITEMS_MAX)
  ## Report fixed number of item slots this build reserves.


proc nimSceneRevision(): cint {.exportc.} =
  ## Report how many times scene's drawn content has changed; see `scene.revision`.
  ##   For presentation layer holding something derived from scene: object-pool strip
  ##   redraws its cells when this moves and at no other time.
  cint(g_scene.revision)


proc nimSceneSlots(): seq[cint] {.exportc.} =
  ## Report every live slot, in slot order.
  ##   Same dense-position-to-slot mapping `panel.layoutOperation`'s combo boxes rely on.
  ##   Walks slots directly rather than through `pairs`: that iterator yields `Item` per
  ##   live slot, and under JS backend constructing `Item` copies whole `Scene` by value.
  for slot in 0 ..< g_scene.bound:
    if g_scene.isAlive(slot): result.add(cint(slot))


proc nimSceneSlotsCreated(): seq[cint] {.exportc.} =
  ## Report every live slot, oldest creation first, for `glue.js`'s scene writer.
  ##   Slot order and creation order part company once anything is removed; version-3
  ##   file promises latter.
  ##   Own export rather than reordering `nimSceneSlots`, whose callers want dense
  ##   positions their combo boxes index.
  var slots: array[ITEMS_MAX, int]
  let count = g_scene.slotsCreated(slots)
  for position in 0 ..< count: result.add(cint(slots[position]))


proc nimIsAlive(slot: cint): bool {.exportc.} = g_scene.isAlive(int(slot))
  ## Report whether slot holds live item.


proc nimItemLabel(slot: cint): cstring {.exportc.} =
  ## Report item's display label, by slot.
  cstring(toText(g_scene.labelAt(int(slot))))


proc nimItemInk(slot: cint): cint {.exportc.} = cint(g_scene.inkAt(int(slot)))
  ## Report item's palette slot, by slot.


proc nimItemVisible(slot: cint): bool {.exportc.} = g_scene.isVisible(int(slot))
  ## Report item's visibility, by slot.


proc nimItemBorn(slot: cint): cfloat {.exportc.} = cfloat(g_borns[int(slot)])
  ## Report moment item was added, by slot, on same clock as every `now` here.
  ##   Lets browser's Objects panel sort by recency.


proc nimItemShapeWord(slot: cint): cstring {.exportc.} =
  ## Report item's shape, by slot, in words `scene.shapeText` names it.
  ##   Same words desktop status line uses, same call.
  cstring(shapeText(g_scene.geometryOf(int(slot))))


proc nimItemCoefficients(slot: cint): seq[float] {.exportc.} =
  ## Report all sixteen basis coefficients of item's multivector, in library's `Basis` order.
  ##   Same order `scene.saveScene`/`loadScene` and `panel.layoutCoefficients` use.
  let geometry = g_scene.geometryOf(int(slot))
  result = newSeq[float](ord(Basis.high) + 1)
  for b in Basis: result[ord(b)] = geometry[b]


proc nimFormatNumber(value: float): cstring {.exportc.} =
  ## Format one number for field, to same four significant digits desktop's drag widget shows.
  ##   3.5 reads `3.5`, not `3.5000`.
  ##   Every editable number goes through here.
  ##     Exported rather than left to JS `toFixed`: how many digits number is worth is
  ##     decision about this project's numbers.
  ##   `format.formatMagnitude` rather than `format.appendMagnitude`, whose `snprintf`
  ##   needs C runtime; suite holds two to same answer.
  cstring(formatMagnitude(value))


proc nimFormatMultivector(slot: cint): cstring {.exportc.} =
  ## Format item's multivector for display, by slot, through `scene.multivectorText`.
  ##   Same writer desktop panel's item line uses; library's `$` writes at library's `%G`,
  ##   not this project's four significant digits.
  cstring(multivectorText(g_scene.geometryOf(int(slot))))



#[ Scene Mutation ]#

proc nimDefaultLabel(): cstring {.exportc.} = cstring(&"m{g_scene.len}")
  ## Report label freshly composed object starts out carrying.
  ##   For pre-filling edit session.


proc nimDefaultInk(): cint {.exportc.} = cint(g_scene.inkNext)
  ## Report palette slot freshly composed object starts out carrying.
  ##   Cycled as every construction path cycles it.


proc nimAddItem(
  coefficients: seq[float]; label: cstring; ink_ordinal: cint; now: cfloat
): cint {.exportc.} =
  ## Commit composing edit session as fresh scene object.
  ##   Takes label and palette slot session staged; both are editable before commit,
  ##   unlike every other construction path.
  ##   Builds `geometry` coefficient by coefficient rather than reusing `nimSceneAddRaw`.
  ##     That one skips `g_history.record`, stamps `g_borns` to 0.0 and never touches
  ##     `g_selection`, all three of which user-driven add must do.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  result = cint(g_scene.addItem(geometry, $label, Ink(ink_ordinal), float(now)))
  stampBorn(int(result), float(now))
  g_selection.selectOnly(int(result))
  g_history.record(g_scene, g_camera)


proc nimCommitItem(
  slot: cint; coefficients: seq[float]; label: cstring; ink_ordinal: cint
) {.exportc.} =
  ## Commit editing session onto item it was opened against.
  ##   Writes every staged field at once and records history exactly once.
  ##   "Edit committed" boundary `history.nim` asks of continuous widgets: timeline gains
  ##   one entry per save rather than one per frame of input.
  let index = int(slot)
  var geometry = g_scene.geometryOf(index)
  for b in Basis: geometry[b] = coefficients[ord(b)]
  g_scene.setGeometryAt(index, geometry)
  toChars($label, g_scene.labelAt(index))
  g_scene.setInk(index, Ink(ink_ordinal))
  g_history.record(g_scene, g_camera)


type OperationResult = object ## Define what applying catalogue operation produced.
  created_slot: cint ## Slot derived object was added at.
  message: cstring ## Outcome, for display as desktop panel's status line.
  shape_word: cstring ## What derived object turned out to be.


proc nimApplyOperation(
  operation_ordinal, slot_first, slot_second: cint; now: cfloat
): OperationResult {.exportc.} =
  ## Derive fresh object by applying catalogue operation to two picked operands.
  ##   As `panel.layoutOperation`'s apply button does.
  let
    operation = Operation(operation_ordinal)
    operand_first = g_scene.geometryOf(int(slot_first))
    operand_second = g_scene.geometryOf(int(slot_second))
    derived = applyOperation(operation, operand_first, operand_second)
    anchor = creationAnchor(operation, operand_first, operand_second, derived)
    name_first = toText(g_scene.labelAt(int(slot_first)))
    name_second = toText(g_scene.labelAt(int(slot_second)))
    label = notationSubstituted(operation, name_first, name_second)
    slot_created =
      g_scene.addItem(derived, label, g_scene.takeInk(), float(now), anchor)
  g_operations.remember(operation)
  g_clock_pulse.forget(slot_created) # Fresh object starts its comet at head.
  stampBorn(slot_created, float(now))
  g_selection.selectOnly(slot_created)
  g_history.record(g_scene, g_camera)
  let shape_word = shapeText(derived)
  OperationResult(
    created_slot: cint(slot_created),
    message: cstring(&"{label} gave {shape_word}."),
    shape_word: cstring(shape_word),
  )


proc nimOperationRemembered(arity: cint): cint {.exportc.} =
  ## Report operation picker of this arity should open on.
  ##   Whatever was last applied at that arity, or catalogue's first choice.
  cint(ord(g_operations.lastOf(if arity == 0: Arity.One else: Arity.Two)))


proc nimGhostOperation(operation_ordinal, slot_first, slot_second: cint): bool
  {.exportc.} =
  ## Stage what applying operation to these operands would build, as ghost.
  ##   Ghost appearance open edit session wears, without touching scene or undo timeline.
  ##   Picker previews its answer moment one is chosen rather than once apply is pressed.
  ##   Through `scene.previewApplying`, so ghost carries anchor and operands camera keeps
  ##   in view, same construction drag offers.
  ##   False, and no preview, where either operand is gone or pair makes nothing drawable.
  g_preview = g_scene.previewApplying(
    Operation(operation_ordinal), int(slot_first), int(slot_second)
  )
  g_preview.isSome


proc nimClearPreview() {.exportc.} =
  ## Drop whatever apply control was previewing, for one that has gone off screen.
  ##   Own call: presentation layer knows section has collapsed or picker has closed.
  g_preview = none(Preview)


proc staged(): Option[Preview] =
  ## Resolve what this build offers as not-yet-committed.
  ##   Open edit session's geometry, else whatever apply control is previewing, else
  ##   nothing.
  ##   Session wins: session is being typed into, preview is passive reading of two
  ##   pickers.
  ##   Sibling is `panel.staged`; fix both or neither.
  if g_ghost.isSome: return some(previewStaging(g_ghost.get))
  g_preview


proc nimSetVisible(slot: cint; is_visible: bool) {.exportc.} =
  ## Rewrite item's visibility, by slot.
  g_scene.setVisible(int(slot), is_visible)
  g_history.record(g_scene, g_camera)


proc nimSetLabel(slot: cint; text: cstring) {.exportc.} =
  ## Rewrite item's display label, by slot.
  toChars($text, g_scene.labelAt(int(slot)))


proc nimSetInk(slot: cint; ink_ordinal: cint) {.exportc.} =
  ## Rewrite item's palette slot, by slot.
  g_scene.setInk(int(slot), Ink(ink_ordinal))
  g_history.record(g_scene, g_camera)


proc nimSetCoefficient(slot, basis_index: cint; value: cfloat) {.exportc.} =
  ## Rewrite one basis coefficient of item's multivector, by slot.
  var geometry = g_scene.geometryOf(int(slot))
  geometry[Basis(basis_index)] = float(value)
  g_scene.setGeometryAt(int(slot), geometry)


proc nimRemoveItem(slot: cint) {.exportc.} =
  ## Drop item from scene, freeing its slot for reuse.
  ##   Drops slot from selection too: freed slot goes straight to next add, so pick left
  ##   behind would reattach to unrelated new object.
  g_scene.removeItem(int(slot))
  g_selection.pruneDead(g_scene)
  g_history.record(g_scene, g_camera)



#[ Ghost Preview ]#

proc nimSetGhost(coefficients: seq[float]) {.exportc.} =
  ## Rewrite staged ghost multivector wholesale, from open session's JS-side state array.
  ##   On every `input` event, so preview tracks keystroke rather than blur.
  ##   `nimBuildFrame` reads it next frame and draws it tinted `INK_GHOST`, muted.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  g_ghost = some(geometry)


proc nimDescribeCoefficients(coefficients: seq[float]): cstring {.exportc.} =
  ## Report same `shape: equation` line item row shows, for staged multivector with no slot.
  ##   Composed row then previews exactly what it reads as once committed.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  cstring(shapeText(geometry) & ": " & multivectorText(geometry))


proc nimClearGhost() {.exportc.} =
  ## Discard ghost, so `nimBuildFrame` stops drawing it.
  ##   Called once session commits or is abandoned.
  g_ghost = none(Multivector)



#[ Catalogue Metadata ]#

proc nimOperationCount(): cint {.exportc.} = cint(COUNT_OPERATION)
  ## Report how many catalogue operations exist.


proc nimOperationNotation(index: cint): cstring {.exportc.} =
  ## Report Nth catalogue operation's notation, symbols alone.
  ##   English name after them is several times wider and pushes picker's popover past
  ##   hand's reach on phone.
  ##   From one table both render paths read.
  cstring(notationSymbolic(Operation(index)))


proc nimOperationArity(index: cint): cint {.exportc.} =
  ## Report 0 for operation reading one operand, 1 for one reading two.
  ##   Matches `panel.layoutOperation`'s disabling of second operand picker.
  cint(lut_operation_to_arity[Operation(index)])


proc nimBasisCount(): cint {.exportc.} = cint(ord(Basis.high) + 1)
  ## Report how many basis coefficients multivector carries in this build's dimension.


proc nimBasisName(index: cint): cstring {.exportc.} = cstring(lut_basis_to_name[Basis(index)])
  ## Report Nth basis element's name.


proc nimBasisGrade(index: cint): cint {.exportc.} = cint(ord(Basis(index).grade))
  ## Report Nth basis element's grade, for grouping coefficient grid.


proc nimInkChoosableSlots(): seq[int] {.exportc.} =
  ## List palette slots colour picker may offer, as whole-palette ordinals.
  ##   For `nimInkName` and `nimInkColor`.
  ##   Structural slots left out: object wearing backdrop, world axis or selection outline
  ##   is invisible or reads as something it is not.
  for index in 0 ..< COUNT_INK_CATEGORICAL: result.add(ord(inkCategorical(index)))


proc nimInkName(index: cint): cstring {.exportc.} = lut_ink_to_name[Ink(index)]
  ## Report Nth palette entry's name.


proc nimInkColor(index: cint): seq[float32] {.exportc.} = toRgbSeq(Ink(index).colour)
  ## Report Nth palette entry's colour, as `[r, g, b]` triple.


proc nimBackdropColor(): seq[float32] {.exportc.} = toRgbSeq(Ink.Backdrop.colour)
  ## Report canvas backdrop's colour, as `[r, g, b]` triple.


const INK_POOL_FREE = Ink.Grid
  ## Mirror `panel.INK_POOL_FREE`, duplicated since `panel` is desktop-only.
  ##   Palette's recessive furniture colour, which is what free object-pool slot is.


var g_flat_pool: seq[float32] = newSeq[float32](ITEMS_MAX*3)
  ## Hold what `nimPoolCellColors` writes, kept across calls so it never allocates.


proc nimPoolCellColors(): seq[float32] {.exportc.} =
  ## Report object-pool strip's colours, one `[r, g, b]` triple per slot in slot order.
  ##   Cell wears ink of whatever object holds it and free one stays recessive; mirrors
  ##   `panel.layoutDiagnosticsObjectPool`'s cell loop.
  ##   Capacity, not watermark: strip whose subject is how much room is left has to show
  ##   room.
  ##   Fills kept buffer rather than growing fresh sequence: runs inside panel's per-frame
  ##   refresh.
  for slot in 0 ..< ITEMS_MAX:
    let colour =
      if g_scene.isAlive(slot): g_scene.inkAt(slot).colour else: INK_POOL_FREE.colour
    g_flat_pool[3*slot] = colour.red
    g_flat_pool[3*slot + 1] = colour.green
    g_flat_pool[3*slot + 2] = colour.blue
  g_flat_pool



#[ Render Metrics ]#

proc nimRenderLineWidths(): seq[float32] {.exportc.} =
  ## Report `[point_size, furniture_line_width, object_line_width]`.
  ##   Browser's `gl.uniform1f`/`gl.lineWidth` then draw at sizes desktop's `renderer.nim`
  ##   does, without hand-copied literal.
  @[SIZE_POINT, WIDTH_LINE_FURNITURE, WIDTH_LINE_OBJECT]


proc nimRampTree(): seq[float32] {.exportc.} =
  ## Report diagnostics tree's colour ramp, six floats per step.
  ##   Row's label rgb then value rgb, `STEPS_RAMP_TREE` steps from sliver of frame to
  ##   half of it.
  ##   Exported as every derived value is: `ramp.nim` is table `tools/check_ramp`
  ##   regenerates from CET-I1, and second copy in presentation layer would drift.
  for i in 0 ..< STEPS_RAMP_TREE:
    let (label, value) = (RAMP_TREE_LABEL[i], RAMP_TREE_VALUE[i])
    result.add([
      float32(label[0]), float32(label[1]), float32(label[2]),
      float32(value[0]), float32(value[1]), float32(value[2]),
    ])


proc nimDiscCorners(): seq[float32] {.exportc.} =
  ## Report disc fan's static corner buffer, uploaded once at start-up.
  ##   `mesh.discCorners`, one source desktop uploads from too, so browser carries no
  ##   table drifting from `mesh.expandDiscVertex`.
  discCorners()


proc nimRingCorners(): seq[float32] {.exportc.} =
  ## Report ring's static corner buffer, uploaded once at start-up.
  ##   Same one-source rule as `nimDiscCorners`, against `mesh.expandRingVertex`.
  ringCorners()


proc nimDomeCorners(): seq[float32] {.exportc.} =
  ## Report dome's static unit-sphere corner buffer, uploaded once at start-up.
  ##   Same rule, against `mesh.expandDomeVertex`.
  domeCorners()


proc nimOverlayMetrics(): seq[float32] {.exportc.} =
  ## Report `[overlay_line_width, selected_alpha, hover_alpha]`.
  ##   Browser's SVG overlay then strokes markers and drag rubber-band at weights
  ##   desktop's `visualiser.drawMarker` does.
  ##   Marker's size is not here: depends on shape marked, and comes back from
  ##   `nimSelectionMarker`.
  ##   Neither is orientation pulse's, shaped into outline `nimSelectionPulse` reports and
  ##   filled rather than stroked.
  @[WIDTH_MARKER, ALPHA_MARKER_SELECTED, ALPHA_MARKER_HOVER]



proc ensurePlaced() =
  ## Refresh `g_placed`, whole placing side for every live slot, where scene has moved.
  ##   Placing side reads no camera, so camera move never reaches this; only edit does.
  ##   Called by frame build and by hover pick, which can run before build on frame where
  ##   scene has just changed, so whichever comes first fills it.
  if g_placed_revision == g_scene.revision: return
  # Re-place only slots stamped since last fill: one per edit, all after restore.
  #   Re-placing every slot per edit is whole frame at capacity; figures in
  #   `PROVENANCE.md`.
  for slot in 0 ..< g_scene.bound:
    if g_scene.isAlive(slot) and g_scene.revisionPlacingAt(slot) > g_placed_revision:
      g_placed[slot] = placeObject(
        g_scene.geometryOf(slot), g_scene.anchorOverrideAt(slot),
      )
  g_placed_revision = g_scene.revision


proc ensureViewOverlay(width, height: int) =
  ## Refresh draw extent and view-projection overlay calls share.
  ##   `g_scale_overlay` and `g_vp_overlay`, derived only when camera or viewport changed.
  ##   Every overlay call (anchor, each marker, each pulse, hover ring) would otherwise
  ##   derive both for itself, each derivation running `camera.frame`'s joins twice.
  ##     Within one frame all are same answer: functions of placement and viewport alone,
  ##     which is what key holds.
  ##   Callers read globals rather than copies: returning pair deep-copies `DrawExtent`
  ##   full of multivectors per call on JS backend, cache hit or not.
  let settings: SettingsOverlay = (
    g_camera.target.x, g_camera.target.y, g_camera.target.z, g_camera.distance,
    g_camera.azimuth, g_camera.elevation, g_camera.degrees_field_of_view,
    width, height,
  )
  if g_settings_overlay.isNone or g_settings_overlay.get != settings:
    g_settings_overlay = some(settings)
    g_scale_overlay = g_camera.drawExtentFor(height)
    g_vp_overlay = g_camera.initMatrixViewProjection(float(width)/float(height))


#[ Camera ]#

proc nimCameraOrbit(turn, rise: cfloat) {.exportc.} =
  ## Rotate camera about its target by turn (azimuth) and rise (elevation), radians.
  g_tween_camera.abandon()
  camera.orbit(g_camera, float(turn), float(rise))


proc nimCameraDolly(factor: cfloat) {.exportc.} =
  ## Scale camera's distance from target by factor.
  g_tween_camera.abandon()
  camera.dolly(g_camera, float(factor))


proc nimCameraDollyAt(factor: cfloat; width, height: cint) {.exportc.} =
  ## Scale camera's distance from target by factor, toward whatever cursor is over.
  ##   See `interaction.dollyAtCursor`.
  ##   Reads cursor this build tracks (`nimUpdateCursor`), so caller aiming zoom (wheel at
  ##   pointer, pinch at midpoint) says where by moving cursor there first, as picking
  ##   does.
  g_tween_camera.abandon()
  # Read through overlay cache.
  #   Wheel arrives in bursts, and each notch would derive fresh extent and matrix for
  #   camera that only changes as result of notch.
  ensureViewOverlay(int(width), int(height))
  # Read through frame's placements.
  #   `dollyAtCursor` asks `anchorZoomAt` what cursor is over, which is full pick.
  ensurePlaced()
  g_interaction.dollyAtCursor(
    g_camera, g_scene, float(factor), g_scale_overlay, g_vp_overlay,
    int(width), int(height), g_placed,
  )


proc nimCameraPan(across, up: cfloat) {.exportc.} =
  ## Slide camera's target sideways and vertically in its view plane.
  ##   Rate reading of pan, for caller with only step to give; `nimCameraPanAt` is what
  ##   drag uses.
  g_tween_camera.abandon()
  camera.pan(g_camera, float(across), float(up))


proc nimCameraPanAt(
  before_x, before_y, after_x, after_y: cfloat; width, height: cint
) {.exportc.} =
  ## Slide view so world point under `before` comes to lie under `after`.
  ##   See `interaction.panAcross`.
  ##   Both ends of pointer's step rather than its length: grab needs where it started.
  g_tween_camera.abandon()
  panAcross(
    g_camera, ScreenPosition(x: float(before_x), y: float(before_y)),
    ScreenPosition(x: float(after_x), y: float(after_y)), int(width), int(height),
  )


proc nimCameraAzimuth(): cfloat {.exportc.} = cfloat(g_camera.azimuth)
  ## Report angle about world up, in radians.
proc nimCameraElevation(): cfloat {.exportc.} = cfloat(g_camera.elevation)
  ## Report angle above horizontal plane, in radians.
proc nimCameraDistance(): cfloat {.exportc.} = cfloat(g_camera.distance)
  ## Report distance from target, in world units.
proc nimCameraFov(): cfloat {.exportc.} = cfloat(g_camera.degrees_field_of_view)
  ## Report vertical field of view, in degrees.
proc nimCameraTarget(): seq[float32] {.exportc.} =
  ## Report point camera orbits around, as `[x, y, z]` triple.
  @[cfloat(g_camera.target.x), cfloat(g_camera.target.y), cfloat(g_camera.target.z)]


proc nimSetCameraAzimuth(v: cfloat) {.exportc.} =
  ## Rewrite angle about world up, in radians.
  g_tween_camera.abandon()
  g_camera.azimuth = float(v)


proc nimSetCameraElevation(v: cfloat) {.exportc.} =
  ## Rewrite angle above horizontal plane, in radians.
  ##   Clamped to bound `panel.layoutView`'s drag widget uses.
  g_tween_camera.abandon()
  g_camera.elevation = clamp(float(v), -ELEVATION_LIMIT, ELEVATION_LIMIT)


proc nimSetCameraDistance(v: cfloat) {.exportc.} =
  ## Rewrite distance from target, in world units.
  ##   Held off one bound orbit distance has; see `camera.distanceHeld`.
  g_tween_camera.abandon()
  g_camera.distance = distanceHeld(float(v))


proc nimSetCameraFov(v: cfloat) {.exportc.} = g_camera.degrees_field_of_view = float(v)
  ## Rewrite vertical field of view, in degrees.


proc nimSetCameraTarget(x, y, z: cfloat) {.exportc.} =
  ## Rewrite point camera orbits around.
  g_tween_camera.abandon()
  g_camera.target = Position(x: float(x), y: float(y), z: float(z))


proc nimCameraLimits(): seq[float32] {.exportc.} =
  ## Report bounds camera placement is held to, for caller offering numeric input.
  ##   Elevation either side of horizon, and one floor orbit distance has.
  ##   No third entry: nothing bounds how far out camera may orbit; see
  ##   `camera.DISTANCE_LIMIT_NEAR`.
  @[cfloat(ELEVATION_LIMIT), cfloat(DISTANCE_LIMIT_NEAR)]



#[ Picking And Drag ]#

const SLOT_NONE = -1'i32
  ## Cross `{.exportc.}` boundary as "no slot".
  ##   `cint` cannot carry `Option[int]` into JS, so every exported proc reporting optional
  ##   slot translates through this one constant at its return.
  ##   Everything on this side of that translation stays `Option[int]`.


proc nimUpdateCursor(x, y: cfloat) {.exportc.} =
  ## Forward to `interaction.updateCursor`.
  interaction.updateCursor(g_interaction, float(x), float(y))


proc nimSetCameraDragging(is_dragging: bool) {.exportc.} =
  ## Say whether pointer gesture is moving camera right now.
  ##   Orbit or pan drag, or two fingers on canvas.
  ##   What that means for hover is `interaction.updateHover`'s to say.
  g_interaction.is_dragging_camera = is_dragging


proc nimUpdateHover(width, height: cint) {.exportc.} =
  ## Forward to `interaction.updateHover`.
  # Charge to record rather than phase.
  #   Runs from event handler, so frame reporting it is next one.
  #   Accumulated: pointer can move many times between two frames.
  let ms_entered_hover = nowMilliseconds()
  # Read through overlay cache.
  #   Each move would rebuild view matrix for camera that cannot have changed, since
  #   hover skips while camera moves.
  ensureViewOverlay(int(width), int(height))
  # Read through frame's placements, so pick ranks what was drawn.
  #   `ensurePlaced` first, since pick can be first of two to run after edit.
  ensurePlaced()
  interaction.updateHover(
    g_interaction, g_scene, g_camera, g_scale_overlay, g_vp_overlay,
    int(width), int(height), g_placed,
  )
  recordThisFrame().ms_hover_pick += nowMilliseconds() - ms_entered_hover


proc nimHoverSlot(): cint {.exportc.} =
  ## Report slot hovered, or `SLOT_NONE` where nothing is.
  if g_interaction.index_hover.isSome: cint(g_interaction.index_hover.get) else: SLOT_NONE


proc nimIsHoverBackdrop(): bool {.exportc.} = g_interaction.is_hover_backdrop
  ## Report whether what is hovered is whole sky, plane at horizon.
  ##   True wherever nothing else is under pointer and such plane is in scene.
  ##   One hovered thing that must not act like one: starts no drag (see
  ##   `interaction.beginDrag`), and tap on it means "empty space" to touch flow.


proc nimClearHover() {.exportc.} =
  ## Discard whatever is hovered.
  ##   Touch has no continuous pointer position: `nimUpdateHover` runs only at touch-down
  ##   point, so once finger lifts last reading would sit stale and hover ring would keep
  ##   drawing, reading as second selected object.
  g_interaction.index_hover = none(int)


proc nimSelectionSlots(): seq[int] {.exportc.} =
  ## List picked slots in pick order.
  ##   `refreshOverlay` rings each, object rows tick their checkboxes.
  for position in 0 ..< g_selection.len: result.add(g_selection.at(position))


proc nimSelectionCount(): cint {.exportc.} = cint(g_selection.len)
  ## Count picked items.


proc nimSelectionArity(): cint {.exportc.} = cint(ord(g_selection.impliedArity))
  ## Report arity current selection implies; see `selection.impliedArity`.
  ##   Matches `nimOperationArity`'s convention: 0 unary, 1 binary.


proc nimSelectOnly(slot: cint) {.exportc.} = g_selection.selectOnly(int(slot))
  ## Replace whole selection with one slot.


proc nimSelectToggle(slot: cint) {.exportc.} = g_selection.toggle(int(slot))
  ## Add slot to end of selection, or drop it where already picked.
  ##   Pick order names operands m and n.


proc nimSelectClear() {.exportc.} = g_selection.clear()
  ## Drop every pick.


proc nimSelectionAllHidden(): bool {.exportc.} =
  ## Forward to `selection.isAllHidden`.
  g_selection.isAllHidden(g_scene)


proc nimAnimationMilliseconds(): cint {.exportc.} = cint(ANIMATION_MILLISECONDS)
  ## Report how long this build eases animation for.
  ##   Same `mesh` constant added object grows over, so presentation layer's transitions
  ##   run to it.


proc nimUndo(): bool {.exportc.} =
  ## Move scene back one step on its edit timeline; report whether there was earlier step.
  ##   Puts view back where that step was made from.
  ##   Clears selection on success, since restored snapshot's slot numbers may not match.
  ##   Abandons standing camera tween too, or aim it carried drags view off placement just
  ##   restored; same pairing `panel.stepHistory` makes.
  result = g_history.undo(g_scene, g_camera)
  if result:
    g_selection.clear()
    g_tween_camera.abandon()


proc nimRedo(): bool {.exportc.} =
  ## Move scene forward one step on its edit timeline; report whether there was later step.
  ##   View and all; clears selection and abandons tween as `nimUndo` does.
  result = g_history.redo(g_scene, g_camera)
  if result:
    g_selection.clear()
    g_tween_camera.abandon()


proc nimCanUndo(): bool {.exportc.} =
  ## Report whether `nimUndo` would move anywhere, so UI can disable its undo button.
  g_history.canUndo


proc nimCanRedo(): bool {.exportc.} =
  ## Report whether `nimRedo` would move anywhere, mirroring `nimCanUndo`.
  g_history.canRedo


proc nimDragKindForButton(dom_button: cint): cint {.exportc.} =
  ## Say what pointer button starts.
  ##   `SLOT_NONE` for no drag, otherwise ordinal of `interaction.MenuArming` drag from
  ##   that button carries.
  ##   Only numbering is this build's own: `PointerEvent.button` counts 0 left, 1 middle,
  ##   2 right; each render path translates into `interaction.PointerButton` and asks one
  ##   shared rule.
  let button = case dom_button
    of 0: some(PointerButton.Left)
    of 1: some(PointerButton.Middle)
    of 2: some(PointerButton.Right)
    else: none(PointerButton)
  if button.isNone: return SLOT_NONE
  let arming = armingOf(button.get)
  if arming.isNone: SLOT_NONE else: cint(ord(arming.get))


proc nimRevealsMenuOnButton(dom_button: cint): bool {.exportc.} =
  ## Say whether click of this pointer button brings selection menu up with it.
  ##   Same translation as `nimDragKindForButton`; what button means is `interaction`'s.
  case dom_button
  of 0: revealsMenuOn(PointerButton.Left)
  of 1: revealsMenuOn(PointerButton.Middle)
  of 2: revealsMenuOn(PointerButton.Right)
  else: false


proc nimRevealsWithoutPicking(has_selection, is_menu_shown: bool): bool {.exportc.} =
  ## Say whether menu-revealing click should only reveal, leaving selection alone.
  ##   Forwards to `interaction.revealsWithoutPicking`; desktop asks identical question.
  revealsWithoutPicking(has_selection, is_menu_shown)


proc nimHelpEntries(): seq[cstring] {.exportc.} =
  ## Report every help entry flat, four strings each.
  ##   Tab, action, outcome, and `"touch"` or `""`.
  ##   Flat rather than array of records, as `nimSelectionMarker` is: object crossing this
  ##   boundary is second shape to keep in step.
  ##   Entries are `help.lut_help_entries`, which desktop panel renders too.
  for entry in lut_help_entries:
    result.add([
      cstring(titleOf(entry.path)), cstring(entry.action), cstring(entry.outcome),
      cstring(if entry.is_touch: "touch" else: ""),
    ])


proc nimHelpDescriptions(): seq[cstring] {.exportc.} =
  ## Report what each tab is about, flat, two strings each.
  ##   Tab's title and its one-line description.
  ##   Own export rather than fifth string on `nimHelpEntries`, which is per row.
  ##   Keyed by title entries carry, so presentation layer joins on string it groups rows
  ##   by.
  for path in HelpPath:
    result.add([cstring(titleOf(path)), cstring(descriptionOf(path))])


proc nimBeginHold(slot: cint; now: cfloat) {.exportc.} =
  ## Forward to `interaction.beginHold`.
  interaction.beginHold(g_interaction, int(slot), float(now))


proc nimCancelHold() {.exportc.} =
  ## Forward to `interaction.cancelHold`.
  interaction.cancelHold(g_interaction)


proc nimHoldSlot(): cint {.exportc.} =
  ## Report which item press in progress is filling, or `SLOT_NONE` where none is.
  if g_interaction.hold.isSome: cint(g_interaction.hold.get.slot) else: SLOT_NONE


proc nimTakeMaturedHold(now: cfloat): cint {.exportc.} =
  ## Forward to `interaction.takeHold`.
  ##   Slot matured hold selects, reported exactly once, or `SLOT_NONE` where nothing to
  ##   take.
  ##   One question rather than "is it mature" beside caller's flag; see `takeHold`.
  let taken = interaction.takeHold(g_interaction, float(now))
  if taken.isNone: SLOT_NONE else: cint(taken.get)


proc nimReleaseHold(now: cfloat) {.exportc.} =
  ## Forward to `interaction.releaseHold`.
  interaction.releaseHold(g_interaction, float(now))


proc nimSwellHold(now: cfloat): cfloat {.exportc.} =
  ## Forward to `interaction.swellHold`.
  cfloat(interaction.swellHold(g_interaction, float(now)))


proc nimIsHoldSpent(now: cfloat): bool {.exportc.} =
  ## Forward to `interaction.isHoldSpent`.
  interaction.isHoldSpent(g_interaction, float(now))


proc nimHoldProgress(now: cfloat): cfloat {.exportc.} =
  ## Forward to `interaction.progressHold`.
  ##   Exported rather than left to subtraction in presentation layer: how long hold takes
  ##   is rule about gesture.
  cfloat(progressHold(g_interaction, float(now)))


proc nimHoldMature(now: cfloat): bool {.exportc.} =
  ## Forward to `interaction.isHoldMature`.
  isHoldMature(g_interaction, float(now))


func keyFor(code: string): Option[Key] =
  ## Translate one DOM `KeyboardEvent.code` into key view knows it by, if it is one.
  ##   `code`, not `key`: names physical key, as desktop's scancodes do, so W is same key
  ##   under hand on every layout.
  ##     `key` binds browser to whatever layout prints (AZERTY names desktop's Z) and
  ##     changes under shift, which means "faster".
  ##   What each key does is `interaction.motionFor` and `interaction.actionFor`'s.
  case code
  of "KeyW": some(Key.W)
  of "KeyA": some(Key.A)
  of "KeyS": some(Key.S)
  of "KeyD": some(Key.D)
  of "KeyQ": some(Key.Q)
  of "KeyE": some(Key.E)
  of "KeyF": some(Key.F)
  of "ShiftLeft", "ShiftRight": some(Key.Shift)
  of "ArrowLeft": some(Key.Left)
  of "ArrowRight": some(Key.Right)
  of "ArrowUp": some(Key.Up)
  of "ArrowDown": some(Key.Down)
  of "BracketLeft": some(Key.BracketLeft)
  of "BracketRight": some(Key.BracketRight)
  of "Minus": some(Key.Minus)
  # Map `Equal` to plus: physical key most layouts print `+` on carries `=`.
  of "Equal": some(Key.Plus)
  of "Enter": some(Key.Enter)
  of "Home": some(Key.Home)
  else: none(Key)


proc nimKeyBound(code: cstring): bool {.exportc.} =
  ## Report whether view answers this key at all.
  ##   Caller then knows whether to keep browser's default for it: arrow scrolling page
  ##   under canvas is case that matters.
  keyFor($code).isSome


proc nimKeyDown(code: cstring): cint {.exportc.} =
  ## Take one key press; report slot caller should select, or `SLOT_NONE`.
  ##   Holds it for `nimDriveHeld`, and carries out whatever it does at press.
  ##   One entry point for both kinds of binding, so `glue.js` carries no opinion about
  ##   which keys move view.
  ##   Idempotent on key already down, which is what auto-repeat sends; re-run action is
  ##   harmless for all four.
  let key = keyFor($code)
  if key.isNone: return SLOT_NONE
  g_interaction.holdKey(key.get)
  let action = actionFor(key.get)
  if action.isNone:
    # Abandon tween: key moving camera is camera move like any other.
    g_tween_camera.abandon()
    return SLOT_NONE
  let slot = applyAction(g_interaction, g_camera, g_scene, action.get)
  # Let go of goal standing offer holds, so next frame aims afresh.
  #   Framing is standing offer's job (`framing.offerAim`).
  if action.get == KeyAction.FrameSelection: g_tween_camera.release()
  else: g_tween_camera.abandon()
  if slot.isNone: SLOT_NONE else: cint(slot.get)


proc nimKeyUp(code: cstring) {.exportc.} =
  ## Take one key release, so whatever it was moving stops.
  let key = keyFor($code)
  if key.isSome: g_interaction.releaseKey(key.get)


proc nimReleaseKeysAll() {.exportc.} =
  ## Let go of every held key, for page that has stopped being told about releases.
  ##   Window losing focus, tab going to background; without it camera moves forever.
  g_interaction.releaseKeysAll()


proc nimDriveHeld(seconds: cfloat) {.exportc.} =
  ## Move camera by every held key, for one frame of `seconds`.
  ##   See `interaction.driveHeld`.
  ##   Abandons tween only when something is held, so frame with no key down leaves ease
  ##   alone.
  if g_interaction.keys_held.len == 0: return
  g_interaction.driveHeld(g_camera, float(seconds))
  g_tween_camera.abandon()


proc nimFocusSlot(): cint {.exportc.} =
  ## Report which item keyboard stands on, or `SLOT_NONE`.
  if g_interaction.index_focus.isSome: cint(g_interaction.index_focus.get) else: SLOT_NONE


proc nimTapSlop(): cfloat {.exportc.} = cfloat(PIXELS_TAP_SLOP)
  ## Report how far press may move and still be press; see `interaction.PIXELS_TAP_SLOP`.


proc nimBeginPress(now: cfloat) {.exportc.} =
  ## Forward to `interaction.beginPress`; every press goes through it, camera ones too.
  interaction.beginPress(g_interaction, float(now))


proc nimIsClick(now: cfloat): bool {.exportc.} =
  ## Forward to `interaction.isClick`.
  ##   Reached directly only for press over empty space, which begins no drag and has no
  ##   `nimEndDrag` to report through.
  isClick(g_interaction, float(now))


proc nimBeginDrag(arming_ordinal: cint; now: cfloat): bool {.exportc.} =
  ## Forward to `interaction.beginDrag`.
  ##   Arming as ordinal rather than flag: three of them, two reachable from mouse.
  ##   `nimDragArmingOnDwell` names one touch uses.
  let arming = MenuArming(clamp(int(arming_ordinal), ord(low(MenuArming)), ord(high(MenuArming))))
  interaction.beginDrag(g_interaction, arming, float(now))


proc nimDragArmingOnDwell(): cint {.exportc.} =
  ## Report arming pointer with no second button starts drag with: touch alone.
  ##   Exported rather than literal in glue: enum reordered in `interaction.nim` must not
  ##   leave number here meaning something else.
  cint(ord(MenuArming.OnDwell))


proc nimUpdateDrag(now: cfloat) {.exportc.} =
  ## Forward to `interaction.updateDrag`.
  ##   Once per frame, after `nimUpdateHover`, before frame reading preview is built,
  ##   order `visualiser.renderFrame` runs them in.
  interaction.updateDrag(g_interaction, g_scene, float(now))


proc nimCancelDrag() {.exportc.} =
  ## Forward to `interaction.cancelDrag`.
  interaction.cancelDrag(g_interaction)


proc nimDragActive(): bool {.exportc.} = g_interaction.is_dragging
  ## Report whether drag is in progress.


proc nimDragSourceSlot(): cint {.exportc.} = cint(g_interaction.index_source)
  ## Report item drag started from; meaningful only while `nimDragActive()`.
  ##   Mirrors `interaction.index_source`, field already paired with that guard.


proc nimDragTint(): seq[float32] {.exportc.} =
  ## Report colour rubber-band wears right now, as `[r, g, b]` triple.
  ##   From `interaction.inkOfDrag`, so this file keeps no copy of operation-to-ink table.
  toRgbSeq(inkOfDrag(g_interaction, g_scene.inkNext).colour)


proc nimDragComet(width, height: cint): seq[float32] {.exportc.} =
  ## Report drag band's head flat, `[x0, y0, x1, y1, ...]`, as one closed outline.
  ##   For overlay to fill over band.
  ##   Shaped by `marker.cometFor`, aimed from where drag source is drawn (plane's creation
  ##   anchor included) at this module's cursor rather than presentation layer's.
  ##     Geometry belongs on side owning gesture.
  ##   Empty where no drag is in flight, source's anchor is behind eye, or cursor rests on
  ##   anchor.
  if not g_interaction.is_dragging: return
  # Read through overlay cache and by-slot readers.
  #   Runs per frame of every drag; fresh extent and matrix plus whole-scene copy through
  #   `g_scene[slot]` would be paid each time.
  ensureViewOverlay(int(width), int(height))
  let anchor = anchorFor(
    g_scene.geometryOf(g_interaction.index_source),
    g_scene.anchorOverrideAt(g_interaction.index_source), g_scale_overlay,
  )
  if anchor.isNone: return
  let screen = projectToScreen(g_vp_overlay, int(width), int(height), anchor.get)
  if not screen.isInFront: return
  let comet = cometFor(screen, g_interaction.cursor)
  if comet.isNone: return
  for point in comet.get: result.add([cfloat(point.x), cfloat(point.y)])


proc nimMenuMetrics(): seq[float32] {.exportc.} =
  ## Report sizes choice menu is drawn at.
  ##   Wedge height, label padding, corner rounding, border thickness, centre-dot radius,
  ##   opacity of offered wedge then unoffered one.
  ##   Same arrangement `nimOverlayMetrics` uses for marker's sizes.
  @[
    float32(HEIGHT_MENU_WEDGE), float32(PADDING_MENU_WEDGE),
    float32(ROUNDING_MENU_WEDGE), float32(WIDTH_MENU_WEDGE_BORDER),
    float32(RADIUS_MENU_CENTRE),
    float32(ALPHA_MENU_WEDGE), float32(ALPHA_MENU_UNOFFERED),
  ]


proc nimDragMenuOpen(): bool {.exportc.} = g_interaction.menu.isSome
  ## Report whether choice menu is open on drag in progress.


proc nimDragMenuCentre(): seq[float32] {.exportc.} =
  ## Report where open menu is centred, in canvas pixels, or empty where none is.
  if g_interaction.menu.isNone: return
  @[float32(g_interaction.menu.get.x), float32(g_interaction.menu.get.y)]


proc nimDragMenuLabels(): seq[cstring] {.exportc.} =
  ## Name every wedge, in `DragChoice` order, order layout below is in.
  for choice in DragChoice: result.add(cstring(labelOf(choice)))


proc nimDragMenuLayout(): seq[float32] {.exportc.} =
  ## Lay open menu out, three floats per wedge in `DragChoice` order.
  ##   Centre x and y in canvas pixels, then offered as 1 or 0.
  ##   Flat as `nimSelectionMarker` is.
  ##   No hue: label wears `--ink`; `interaction.inkOf` answers for rubber-band and
  ##   drawer's legend.
  ##   Empty where no menu is open.
  if g_interaction.menu.isNone: return
  let
    centre = g_interaction.menu.get
    over = destinationOf(g_interaction)
    is_pair_live =
      over.isSome and over.get != g_interaction.index_source and
      g_scene.isAlive(over.get) and g_scene.isAlive(g_interaction.index_source)
  for choice in DragChoice:
    let
      at = anchorOf(centre, choice)
      is_offered =
        choice == DragChoice.More or
        (is_pair_live and isOffered(
          choice, g_scene.geometryOf(g_interaction.index_source),
          g_scene.geometryOf(over.get),
        ))
    result.add([float32(at.x), float32(at.y), float32(ord(is_offered))])


proc nimDragMenuHighlighted(): cint {.exportc.} =
  ## Report which wedge cursor stands in as `DragChoice` ordinal, or `SLOT_NONE` at centre.
  ##   From `interaction.choosing`, same call release resolves through and ghost is shaped
  ##   from.
  let choice = g_interaction.choosing
  if choice.isNone: SLOT_NONE else: cint(ord(choice.get))


type DragResult = object ## Define what ending drag produced.
  created_slot: cint ## Slot added, or `SLOT_NONE` where nothing was.
    ## Over empty space, on own source, on pair making nothing, or on `more…`.
  message: cstring ## Outcome, for display as desktop panel's status line.
  is_more: bool ## Whether release chose `more…`.
    ## Builds nothing and leaves both operands selected for apply section.
  clicked_slot: cint ## Item press that never became drag came down on.
    ## `SLOT_NONE` for every actual drag.
    ## Caller selects it, alone or added where shift is held.


proc nimEndDrag(now: cfloat): DragResult {.exportc.} =
  ## End drag in progress, applying whatever release resolved to.
  ##   Straight into `interaction.endDrag` for everything it reports, adding only this
  ##   build's business: birth clock, selection, history entry.
  ##   `scene.toText` reads labels same on both backends; `$toCstring` is empty under JS.
  let outcome = interaction.endDrag(g_interaction, g_scene, float(now))
  if outcome.index_clicked.isSome:
    # Report press that never moved rather than act on it.
    #   Replace or join selection is shift key's to say, and caller reads that.
    return DragResult(
      created_slot: SLOT_NONE, clicked_slot: cint(outcome.index_clicked.get)
    )
  if outcome.index_created.isSome:
    let slot = outcome.index_created.get
    stampBorn(slot, float(now))
    g_selection.selectOnly(slot)
    g_history.record(g_scene, g_camera)
    return DragResult(
      created_slot: cint(slot), message: cstring(outcome.message), clicked_slot: SLOT_NONE
    )
  if outcome.choice == some(DragChoice.More) and outcome.operands.isSome:
    # Select both operands in drag order, which apply section reads as m then n.
    #   Way out of gesture's three operations into rest of catalogue.
    g_selection.selectOnly(outcome.operands.get.source)
    g_selection.toggle(outcome.operands.get.destination)
    return DragResult(
      created_slot: SLOT_NONE, message: cstring(outcome.message), is_more: true,
      clicked_slot: SLOT_NONE,
    )
  DragResult(
    created_slot: SLOT_NONE, message: cstring(outcome.message), clicked_slot: SLOT_NONE
  )


proc nimGridMetrics(width, height: cint): seq[float32] {.exportc.} =
  ## Report `[size_cell, world_per_pixel]` for ground grid as drawn right now.
  ##   Cell's size in world units, and how much world one screen pixel spans at height
  ##   grid is laid at.
  ##   `[0, 0]` where no ground is drawn (eye above fog's reach), read as "no scale to
  ##   show".
  ##   Exported as `nimRenderLineWidths` is: number reader is shown has to be number grid
  ##   was built with; both from `mesh.sizeCellGridAt`, which `addGrid` reads.
  ##   Through `ensureViewOverlay`, so extent is overlay's own, built at CSS height.
  ##     Scale bar is drawn in pixels pointer works in; see `glue.js`.
  ensureViewOverlay(int(width), int(height))
  template scale: DrawExtent = g_scale_overlay
  let size_cell = sizeCellGridAt(scale.extent_furniture, scale)
  if size_cell.isNone: return @[0.0'f32, 0.0'f32]
  # Measure at ground point below eye, where reported cell is laid.
  #   Pixel spans more world further away.
  let below = position(wedgeAnti(
    wedge(scale.eye_point, toMultivector(Direction(x: 0, y: 0, z: -1))), groundPlane()
  ))
  let at = if below.isSome: below.get else: scale.eye
  @[float32(size_cell.get), float32(worldPerPixelAt(at, scale))]


proc nimAnchorScreen(slot, width, height: cint): seq[float32] {.exportc.} =
  ## Project item's representative point onto screen pixels, as `[x, y, is_in_front]`.
  ##   Point `mesh.anchorFor` and `visualiser.drawInteractionOverlay` use, so browser's
  ##   hover ring and drag rubber-band draw as 2D overlay where desktop draws them.
  ##   Item's drawn centre, through anchor-aware `anchorFor`.
  ##     Plane's disc is centred on stored creation anchor, so band answering from support
  ##     would meet plane nowhere on circle.
  ##   `is_in_front` is 0 or 1: caller draws nothing where 0, matching
  ##   `picking.isInFront`.
  ##     Also 0 where slot no longer holds live item, since every caller reads slot
  ##     carried across frames that can go stale when item is removed.
  ##   Plane at horizon reports middle of view: it has no place in scene, so menu goes to
  ##   centre of frame `marker.markerFrame` draws around it.
  ##   Duplicated by constraint in `visualiser.anchorOfSelection`; fix both or neither.
  if not g_scene.isAlive(int(slot)): return @[0.0'f32, 0.0'f32, 0.0'f32]
  if g_scene.geometryOf(int(slot)).isHorizonPlane:
    return @[0.5'f32*float32(width), 0.5'f32*float32(height), 1.0'f32]
  ensureViewOverlay(int(width), int(height))
  # Read by slot, never `g_scene[slot]`.
  #   `Item` holds `Scene` by value on JS backend, so constructing one copies whole scene.
  let anchor = anchorFor(
    g_scene.geometryOf(int(slot)), g_scene.anchorOverrideAt(int(slot)), g_scale_overlay
  )
  if anchor.isNone: return @[0.0'f32, 0.0'f32, 0.0'f32]
  let screen = projectToScreen(g_vp_overlay, int(width), int(height), anchor.get)
  @[cfloat(screen.x), cfloat(screen.y), (if screen.isInFront: 1.0'f32 else: 0.0'f32)]


proc nimSelectionMarker(
  slot, width, height: cint; progress: cfloat; is_touch: bool; swell: cfloat = 0.0
): seq[float32] {.exportc.} =
  ## Shape this item's selection/hover marker and report it flat, for SVG overlay to stroke.
  ##   `[kind, first, second, third, x0, y0, x1, y1, ...]`.
  ##   `kind` is `marker.MarkerKind`'s ordinal; three header slots after it mean whatever
  ##   that kind needs, so overlay reads fixed prefix then points:
  ##
  ##   | Kind      | first        | second        | third         | Points               |
  ##   |-----------|--------------|---------------|---------------|----------------------|
  ##   | 0 `Ring`  | --           | radius        | swept fraction| centre               |
  ##   | 1 `Rails` | --           | --            | --            | two per drawn piece  |
  ##   | 2 `Loop`  | closed       | --            | --            | around plane         |
  ##   | 3 `Bands` | first closed | first's count | second closed | both bands, in order |
  ##   | 4 `Frame` | closed       | --            | --            | around view          |
  ##
  ##   Point count is whatever is left, except `Bands`, which carries two runs and says
  ##   where first ends.
  ##   `is_touch` says finger is holding and `swell` how far clear of it outline stands.
  ##     `nimSwellHold`'s answer, on its own clock; see `interaction.swellHold`.
  ##   `progress` draws marker part-built for press maturing into selection; pass 1 for
  ##   finished one.
  ##     What partial marker looks like is `marker.markerFor`'s decision.
  ##   Empty where nothing to draw: dead slot, or geometry with no shape.
  ##     Callers read slot carried across frames, so any can go stale when item is removed.
  if not g_scene.isAlive(int(slot)): return
  ensureViewOverlay(int(width), int(height))
  # Shape with slot's current travel, though this call reports no pulse.
  #   Outline is identical either way, and shaping whole marker once lets
  #   `nimSelectionPulse` reuse it.
  #   Clock is not advanced here; that stays pulse call's job.
  let travel = g_clock_pulse.travelAt(int(slot))
  # Shape straight into shared box pulse call reads back.
  #   Nothing allocates or copies `Marker`.
  if not markerFor(
    g_scene.geometryOf(int(slot)), g_scene.anchorOverrideAt(int(slot)), g_scale_overlay,
    g_camera, g_vp_overlay, int(width), int(height), g_box_marker[], float(progress),
    is_touch, travel = some(travel), swell = float(swell),
  ):
    g_shaped_marker = none(ShapedMarker)
    return

  template marker: Marker = g_box_marker[]
  g_shaped_marker = some((
    int(slot), int(width), int(height), float(progress), is_touch, float(swell),
    travel, g_settings_overlay.get, g_box_marker,
  ))
  result = @[cfloat(ord(marker.kind)), 0.0'f32, 0.0'f32, 0.0'f32]
  case marker.kind
  of MarkerKind.Ring:
    result[2] = cfloat(marker.radius)
    result[3] = cfloat(marker.fraction)
    result.add([cfloat(marker.centre.x), cfloat(marker.centre.y)])
  of MarkerKind.Rails:
    for i in 0 ..< marker.count_segment:
      for point in marker.segments[i]:
        result.add([cfloat(point.x), cfloat(point.y)])
  of MarkerKind.Loop:
    result[1] = (if marker.is_closed: 1.0'f32 else: 0.0'f32)
    for i in 0 ..< marker.count_point:
      result.add([cfloat(marker.points[i].x), cfloat(marker.points[i].y)])
  of MarkerKind.Bands:
    result[1] = (if marker.are_closed_band[0]: 1.0'f32 else: 0.0'f32)
    result[2] = cfloat(marker.counts_band[0])
    result[3] = (if marker.are_closed_band[1]: 1.0'f32 else: 0.0'f32)
    for side in 0 .. 1:
      for i in 0 ..< marker.counts_band[side]:
        result.add([
          cfloat(marker.points_band[side][i].x), cfloat(marker.points_band[side][i].y)
        ])
  of MarkerKind.Frame:
    result[1] = 1.0'f32 # Always closed: frame is screen space, never cut by eye.
    for i in 0 ..< marker.count_frame:
      result.add([cfloat(marker.points_frame[i].x), cfloat(marker.points_frame[i].y)])


proc nimTickPulse(now: cfloat) {.exportc.} =
  ## Take frame's clock reading for every orientation pulse on screen.
  ##   Once per frame, before any `nimSelectionPulse`, so each selected object advances by
  ##   same step; clock ticked per call would hand whole step to first slot asked.
  g_seconds_step_pulse = g_clock_pulse.secondsStep(float(now))
  g_clock_pulse.tick(float(now))


proc nimSelectionPulse(
  slot, width, height: cint; progress: cfloat; is_touch: bool; swell: cfloat = 0.0
): seq[float32] {.exportc.} =
  ## Report orientation pulse travelling along this item's marker, flat.
  ##   Run count then each run's point count followed by its points: `[runs, count0, x,
  ##   y, ..., count1, x, y, ...]`.
  ##   Each run is closed outline to fill: run tapers, stroke has one width.
  ##   Own call rather than tail on `nimSelectionMarker`, whose format promises points are
  ##   "whatever is left".
  ##     Marker is still shaped once: that call leaves result in `g_shaped_marker`, and
  ##     this reuses it wherever every input matches.
  ##   Takes same `progress` and `is_touch` marker was asked for, so pulse lies on outline
  ##   actually drawn; swollen marker's pulse swells with it.
  ##   Empty for anything with no orientation: point, plane at horizon, dead slot, no
  ##   shape; see `marker.markerFor`.
  ##   Clock is advanced whether or not run came out.
  ##     Returning early on empty run deadlocks line: every phase starts at 0,
  ##     `samplePulse` clamps on open outline, so rail at phase 0 yields nothing, which
  ##     would skip advance, for ever.
  ##     Plane's loop is closed and wraps, so only lines would stall.
  ##   Mirrors `visualiser.drawSelectionMarker`.
  if not g_scene.isAlive(int(slot)): return
  ensureViewOverlay(int(width), int(height))
  let travel = g_clock_pulse.travelAt(int(slot))
  var held = (ref Marker)(nil)
  if g_shaped_marker.isSome:
    let stored = g_shaped_marker.get
    if stored.slot == int(slot) and stored.width == int(width) and
        stored.height == int(height) and stored.progress == float(progress) and
        stored.is_touch == is_touch and stored.swell == float(swell) and
        stored.travel == travel and stored.settings == g_settings_overlay.get:
      held = stored.marker
  if held == nil:
    # Reuse shared box, dropping its entry: stale key must not outlive overwrite.
    g_shaped_marker = none(ShapedMarker)
    held = g_box_marker
    if not markerFor(
      g_scene.geometryOf(int(slot)), g_scene.anchorOverrideAt(int(slot)), g_scale_overlay,
      g_camera, g_vp_overlay, int(width), int(height), held[], float(progress), is_touch,
      travel = some(travel), swell = float(swell),
    ): return

  template marker: Marker = held[]
  # Advance against length this marker came out at; see `selection.PulseClock`.
  #   Orbiting then changes how fast comet travels and never where it is.
  g_clock_pulse.advance(int(slot), marker.lap, g_seconds_step_pulse)
  if marker.count_run_pulse == 0: return
  result = @[cfloat(marker.count_run_pulse)]
  for run in 0 ..< marker.count_run_pulse:
    result.add(cfloat(marker.counts_pulse[run]))
    for i in 0 ..< marker.counts_pulse[run]:
      result.add([cfloat(marker.pulses[run][i].x), cfloat(marker.pulses[run][i].y)])



#[ Scene Save/Load Primitives ]#

proc nimSceneMagic(): cstring {.exportc.} = cstring(MAGIC_SCENE)
  ## Report four bytes `.rgascene` file opens with, for packer in `glue.js`.


proc nimSceneVersion(): cint {.exportc.} = cint(VERSION_SCENE)
  ## Report format version this build writes, for that packer.
  ##   Exported rather than written again in JavaScript, where literal survives bump and
  ##   browser stamps old version onto new content; see `scene.MAGIC_SCENE`.


proc nimSceneReadsVersion(version: cint): bool {.exportc.} =
  ## Report whether this build can read scene file stamped with this version.
  ##   Rule rather than number: what build reads is range, two literals to drift.
  version >= 0 and version <= int(high(uint8)) and readsSceneVersion(uint8(version))


proc nimSceneClear() {.exportc.} =
  ## Discard live scene and start fresh empty one.
  g_scene.restoreFrom(initScene())
  g_selection.clear()
  g_history.initHistory(g_scene, g_camera)


proc nimSceneAddRaw(
  version: cint; ink_ordinal: cint; is_visible: bool; label: cstring;
  coefficients: seq[float]; count_total: cint; now: cfloat
): cint {.exportc.} =
  ## Add one item straight from parsed `.rgascene` fields, for load path.
  ##   Presentation layer parses bytes into these fields and calls this once per item, in
  ##   file order.
  ##   `version` is file's own; item is carried up by `scene.itemUpgraded`, same chain
  ##   desktop's `loadScene` walks.
  ##     `SLOT_NONE` where no version could have written item: corrupt or foreign file.
  ##   `count_total` is file's whole item count and `now` this frame's clock, so arrival
  ##   is staggered by `scene.bornReplaying`, same rule desktop stamps with.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  let carried = itemUpgraded(
    ItemSaved(
      ink_ordinal: int(ink_ordinal), is_visible: is_visible, label: $label,
      geometry: geometry,
    ),
    uint8(version),
  )
  if carried.isNone: return SLOT_NONE
  # Take how many scene holds as this item's position in file.
  #   Scene was cleared before first of these.
  let born = bornReplaying(g_scene.len, int(count_total), float(now))
  let slot = g_scene.addItem(
    carried.get.geometry, carried.get.label, Ink(carried.get.ink_ordinal), born
  )
  g_scene.setVisible(slot, carried.get.is_visible)
  # Stamp rather than leave alone: slot could hold stale reading from earlier occupant.
  stampBorn(slot, born)
  cint(slot)



#[ Frame Assembly ]#

type FrameData = object
  ## Define one frame's vertex data plus transform it is drawn through.
  ##   Everything caller needs to issue this frame's `gl.drawArrays` calls.
  ribbon_verts, point_verts: FlatBuffer
  ring_records: FlatBuffer ## Fourteen floats per ring, `mesh.RingRecord`'s field order.
    ## One record per rim, where ribbon records per segment were most of all ribbon
    ## traffic; figures in `PROVENANCE.md`.
  disc_records: FlatBuffer ## Thirteen floats per disc, `mesh.DiscRecord`'s field order.
    ## For instanced fan draw.
  dome_records: FlatBuffer ## Eight floats per dome, `mesh.DomeRecord`'s field order.
    ## For instanced sphere draw.
  wash_runs: FlatBuffer ## Translucent pass's draw order, three floats per run.
    ## Kind (`mesh.WashKind` ordinal), first record, count.
    ## Walked in sequence so two washes blend in order scene emitted them; see
    ## `mesh.WashRuns`.
  view_projection: seq[float32]
  furn_ribbon_verts: FlatBuffer ## Ground grid and world axes alone, drawn first.
    ## Built at own thinner width (`mesh.WIDTH_LINE_FURNITURE`), since ribbon carries
    ## width as geometry.
    ## Empty where `is_furniture_held`, meaning "furniture you already have".
  is_scene_held: bool ## Whether scene records are unchanged from last frame.
    ## Every buffer below then already holds what it should and none needs re-uploading.
    ## See `SettingsScene` for what has to match and three states refusing hold.
  is_furniture_held: bool ## Whether furniture is unchanged from last frame.
    ## Caller then keeps buffer it uploaded rather than reading empty `furn_ribbon_verts`
    ## as empty world.
    ## Furniture is function of camera alone, and camera is still for most frames of
    ## ordinary session.
    ##   Furniture is moving frame's largest phase on JS backend (diagnostics scenery row
    ##   is live figure), so still frame skipping it does most of frame less work.
  ms_algebra: float32 ## What debug layer cost, beside `ms_scene` rather than inside it.
    ##   Every multivector frame recorded, drawn in true form; zero where layer is off.
  ms_build, ms_furniture, ms_scene, ms_flatten: float32
    ## Record what this frame's assembly cost, in milliseconds.
    ##   Whole of `nimBuildFrame`, and its three phases: furniture, scene's objects (ghost
    ##   and preview included), and flatten of every mesh into arrays above.
    ##   Phases bridge cannot see (GL upload, SVG overlay) are timed by `glue.js`.
    ##   Held furniture frame reports near-zero furniture.
  cam_eye_x, cam_eye_y, cam_eye_z: float32
  cam_forward_x, cam_forward_y, cam_forward_z: float32
  cam_depth_near, cam_tangent_half_view, cam_height_pixels: float32
    ## Carry what ribbon vertex shader needs of camera.
    ##   Exactly `mesh.DrawScale`'s same-named fields.
    ##   Widening, near clip and screen-constant width run on GPU.
  fog_radius_full, fog_radius_gone: float32
    ## Carry furniture fog's two radii, for ribbon fragment shader's fade of fogged records.
    ##   `mesh.fogFurnitureFor`'s answer for this frame's reach.
  ms_camera, ms_matrix, ms_unaccounted: float32
    ## Record three spans of `nimBuildFrame` that belong to no row.
    ##   `ms_camera` is prologue: focus pruning, tween, `DrawExtent`, `framing.offerAim`.
    ##   `ms_matrix` is view-projection build.
    ##   `ms_unaccounted` is whatever phases fail to cover, shown rather than inferred:
    ##   breakdown whose parts do not sum is worse than coarse one.
  ms_placing, ms_emitting: float32
    ## Cut same milliseconds second way, not stage of its own.
    ##   How frame divided between working out where geometry goes and turning places into
    ##   vertices, which is question this project exists to ask.
    ##   `ms_emitting` is pure by construction: reached through `mesh`, which imports
    ##   `euclid` alone.
    ##   `ms_placing` carries little Euclidean arithmetic inside its loops; see `timings`.
  ms_hover_pick: float32
    ## Record what picking under cursor cost, measured between frames, reported by one after.
    ##   `updateHover` runs from event handlers, so no bracket inside this proc sees it.
    ##   Carried on `timings.FrameRecord`.
  ms_grid, ms_axes: float32
    ## Record what two halves of scenery cost, inside `ms_furniture`.
    ##   Axes are three lines however far camera stands; grid is however many ground reach
    ##   asks for.
  count_grid_segments: int
    ## Count ribbon records ground grid is drawn from, one per lattice line.
    ##   Bounded per family by `mesh.LINES_GRID_MAX`.
    ##   Axes excluded, so budgeted number matches its budget.
  ms_points, ms_lines, ms_planes, ms_sky, ms_ghost, ms_selected: float32
    ## Record what each kind of scene object cost inside `ms_scene`, with counts below.
    ##   Kinds differ by order of magnitude: point is single vertex, plane places rim of
    ##   `mesh.SEGMENTS_CIRCLE_HORIZON` segments.
    ##   `sky` is horizon planes drawn first; `ghost` is staged edit and drag preview
    ##   together; `selected` is overlay tail, drawn again with depth test off.
    ##   Timed by clock read once per object: mark from end of one is start of next.
    ##     Clock's own overhead lands inside `ms_scene`; figures in `PROVENANCE.md`.
  count_points, count_lines, count_planes, count_sky, count_ghost, count_selected: int
    ## Count objects of each kind times above are for.
    ##   Reader can divide: "is one expensive, or are there many?".
  ribbon_over, ring_over, point_over, wash_run_over: int ## How much of each stream's end
    ## is overlay run, drawn after rest with depth test off.
    ## Count of tail rather than index it starts at, so glue subtracts nothing; see
    ## `mesh.Mesh.index_overlay` and `renderer.drawRun`.
    ## Vertices for points, records for ribbons and rings, whole runs for washes.


type SceneCost = object
  ## Define tally of what each kind of scene object cost this frame, and how many there were.
  ##   One clock read per object: mark closing one object opens next.
  ##   Ghost and overlay tail are kinds of their own because neither is scene object
  ##   reader counted.
  ms_points, ms_lines, ms_planes, ms_sky, ms_ghost, ms_selected: float
  count_points, count_lines, count_planes, count_sky, count_ghost, count_selected: int
  mark: float ## When object now being drawn started, on `performanceNow`'s clock.


var g_counts_scene: SceneCost ## What scene meshes standing in `g_meshes` are made of.
  ## Only counts are read back, on held frame; times belong to frame that did work.
  ##   Held frame draws what it had and should say what that is rather than report empty
  ##   scene.
  ## Here rather than in module's `var` block because `SceneCost` is declared just above.


proc openTally(cost: var SceneCost) =
  ## Start tally's clock, so first object measures from here rather than from zero.
  ##   Only where breakdown is being read; see `timings.IS_TALLYING`.
  if isTallying(): cost.mark = performanceNow()


proc chargeTally(cost: var SceneCost; kind: PlacedKind; is_sky, is_ghost, is_selected: bool) =
  ## Charge whatever has been drawn since last mark to kind it belongs to.
  ##   Takes kind placement settled on rather than reading shape again: reading twice is
  ##   second multivector walk per object per frame, on path this tally measures.
  ##   Counts are gathered either way; only times are gated; see `timings.IS_TALLYING`.
  ##     Count is one increment; time is clock read per object, which at capacity is
  ##     sizeable share of frame; figures in `PROVENANCE.md`.
  var spent = 0.0
  if isTallying():
    let now_mark = performanceNow()
    spent = now_mark - cost.mark
    cost.mark = now_mark
  if is_ghost:
    cost.ms_ghost += spent
    cost.count_ghost += 1
    return
  if is_selected:
    cost.ms_selected += spent
    cost.count_selected += 1
    return
  if is_sky:
    cost.ms_sky += spent
    cost.count_sky += 1
    return
  case kind
  of PlacedKind.Nothing: discard # Nothing drawable was drawn, so nothing to charge.
  of PlacedKind.PointAt, PlacedKind.PointToward:
    cost.ms_points += spent
    cost.count_points += 1
  of PlacedKind.LineThrough, PlacedKind.LineAcross:
    cost.ms_lines += spent
    cost.count_lines += 1
  of PlacedKind.PlaneOn, PlacedKind.PlaneEverywhere:
    cost.ms_planes += spent
    cost.count_planes += 1


proc nimBuildFrame(
  aspect, now: cfloat; height_pixels: cint;
  is_axes_shown, is_grid_shown, is_algebra_shown: bool; is_tally_skipped: bool = false
): FrameData {.exportc.} =
  ## Tessellate every visible object in live scene, at camera's current placement.
  ##   Through same `mesh.addObject` dispatch and `camera` transforms desktop draws
  ##   through, every item at full colour as desktop's interactive `assembleMeshes` draws.
  ##   Exceeds sixty-line default.
  ##     Mirrors `visualiser.assembleMeshes`'s two-pass draw-order invariant and packs
  ##     view-projection plus whole `FrameData`, packaging desktop never needs.
  ##     Splitting packaging out would return partial results across extra boundary for no
  ##     reader benefit.
  ##   Draws `g_ghost` too, tinted `INK_GHOST` and muted; see that var.
  # Read one clock per phase boundary, so diagnostics tab shows each step.
  #   `performanceNow` is timing-only.
  let ms_entered = performanceNow()
  # Say once, at top, whether this frame tallies, so whole frame agrees.
  #   Flag read part-way through would mix two frames' worth of instrumentation.
  #   Stated as "skipped" on purpose: Nim default does not survive into JS signature, and
  #   caller omitting it passes `undefined`, falsy, so natural way round would silently
  #   turn measurement off.
  setTallying(not is_tally_skipped)
  # Forget last frame's two sides, and turn record pair over.
  #   What was measured between frames (hover picking) is then readable while this frame
  #   reports it.
  openFrameTimings()
  # Guard focus as selection is guarded: slot carried across frames may have died.
  g_interaction.pruneFocus(g_scene)

  # Carry camera one frame further toward whatever is being worked on, then aim it again.
  #   From what this frame holds, same rule `visualiser.assembleMeshes` applies.
  #   Advancing before `scale` is read keeps furniture extent consistent with where camera
  #   is.
  g_tween_camera.advance(g_camera, float(now), easeOutCubic)
  # Take framebuffer's height, not window's.
  #   Ribbon's width is measured in pixels drawn, and this build renders at
  #   device-pixel-ratio multiple.
  let scale = g_camera.drawExtentFor(int(height_pixels))
  # Recover width of centred box from aspect, since this build is handed that.
  let ghost = staged()
  g_tween_camera.offerAim(
    g_camera, g_scene, g_selection, ghost, scale, int(float(aspect)*float(height_pixels)),
    int(height_pixels), float(now), ANIMATION_SECONDS,
  )

  # Hold furniture where settings match last frame's.
  #   Everything `drawExtentFor` reads, and two toggles: frame whose settings match is
  #   drawing same vertices and may keep them.
  #   Compared exactly: question is "did anything move at all".
  let settings_furniture =
    settingsFurnitureFor(g_camera, int(height_pixels), is_axes_shown, is_grid_shown)
  let is_furniture_held =
    g_settings_furniture.isSome and g_settings_furniture.get == settings_furniture
  let ms_after_camera = performanceNow()
  let ms_before_furniture = ms_after_camera
  var
    ms_grid = 0.0
    ms_axes = 0.0
  if not is_furniture_held:
    g_settings_furniture = some(settings_furniture)
    clearMeshes(g_meshes_furniture)
    # Clock grid and axes apart: axes are three lines, grid is however many ground reaches.
    let ms_before_grid = performanceNow()
    if is_grid_shown:
      addGrid(g_meshes_furniture, g_scratch, scale.extent_furniture, scale)
    # Count between two, so figure is grid's own; see `mesh.addSegmentAcross`.
    g_count_grid_segments = g_meshes_furniture.ribbons.count
    let ms_before_axes = performanceNow()
    if is_axes_shown:
      addAxes(g_meshes_furniture, g_scratch, scale.extent_furniture, scale)
    ms_grid = ms_before_axes - ms_before_grid
    ms_axes = performanceNow() - ms_before_axes
  let ms_after_furniture = performanceNow()

  # Hold scene where settings match last frame's, one layer out from furniture's hold.
  #   Frame whose settings match tessellates same records, so keeps them, flattens and
  #   uploads together: whole scene phase.
  #   Three states refuse hold outright rather than being encoded: ghost or preview
  #   follows pointer; debug layer draws cursor's ray; item inside appear animation is
  #   drawn differently every frame.
  #   Cost of refusing is one rebuilt frame; cost of holding wrongly is frozen picture.
  let settings_scene: SettingsScene = (
    furniture: settings_furniture,
    aspect: float(aspect),
    revision: g_scene.revision,
    revision_selection: g_selection.revision,
    is_algebra_shown: is_algebra_shown,
  )
  let is_scene_settled =
    ghost.isNone and g_interaction.preview.isNone and not is_algebra_shown and
      float(now) >= g_born_last + ANIMATION_SECONDS
  let is_scene_held =
    is_scene_settled and g_settings_scene.isSome and g_settings_scene.get == settings_scene
  if not is_scene_held:
    g_settings_scene = (if is_scene_settled: some(settings_scene) else: none(SettingsScene))

  # Declare tally out here because frame reports it either way.
  #   On held frame times are zero and counts are last frame's, still what scene holds.
  var cost: SceneCost
  var
    ms_before_algebra = ms_after_furniture
    ms_after_algebra = ms_after_furniture
  if is_scene_held:
    cost.count_points = g_counts_scene.count_points
    cost.count_lines = g_counts_scene.count_lines
    cost.count_planes = g_counts_scene.count_planes
    cost.count_sky = g_counts_scene.count_sky
    cost.count_ghost = g_counts_scene.count_ghost
    cost.count_selected = g_counts_scene.count_selected
  # Refresh placement cache only where scene moved; see `ensurePlaced`.
  ensurePlaced()

  if not is_scene_held:
    clearMeshes(g_meshes)
    cost.openTally()
    # Emit horizon plane's dome first, before anything sharing translucent wash pass.
    #   Wash runs draw in append order, unsorted by depth, so dome first guarantees every
    #   ordinary plane's fill blends over it; see `visualiser.assembleMeshes`.
    #   By-slot "At" accessors rather than `pairs`: under JS backend `Item` holds `Scene`
    #   by value, so constructing one per live slot copies entire scene.
    #   To watermark, not capacity: `scene.bound` is high-water mark, which only rises;
    #   sibling walk below takes same bound.
    #   Placed once, emitted every frame: placement already answered sky or not, so walks
    #   sort on `g_placed[slot].kind` rather than reading multivector per slot per walk.
    for slot in 0 ..< g_scene.bound:
      if not g_scene.isAlive(slot) or slot in g_selection: continue
      if g_scene.isVisible(slot):
        # Index in place, never bind to local; see `emitObject`.
        #   `let placed = g_placed[slot]` is deep copy under JS backend, once per object
        #   per frame.
        if g_placed[slot].kind == PlacedKind.PlaneEverywhere:
          let progress = animationProgress(float(now), g_borns[slot])
          discard g_meshes.emitObject(
            g_placed[slot], g_scene.inkAt(slot).colour, scale, progress,
          )
          cost.chargeTally(
            g_placed[slot].kind, is_sky = true, is_ghost = false, is_selected = false,
          )

    for slot in 0 ..< g_scene.bound:
      if not g_scene.isAlive(slot) or slot in g_selection: continue
      if g_scene.isVisible(slot):
        if g_placed[slot].kind != PlacedKind.PlaneEverywhere:
          let progress = animationProgress(float(now), g_borns[slot])
          discard g_meshes.emitObject(
            g_placed[slot], g_scene.inkAt(slot).colour, scale, progress,
          )
          cost.chargeTally(
            g_placed[slot].kind, is_sky = false, is_ghost = false, is_selected = false,
          )

    # Emit open session's staged geometry, or apply control's preview where none.
    #   One ghost for both; `staged` decides order.
    #   Centred on anchor commit stores, so previewed plane stays where ghosted.
    #   `ghost` read once in prologue; nothing since has touched session.
    if ghost.isSome:
      # Place here rather than cache: ghost is not slot and moves with pointer.
      var placed_ghost = placeObject(ghost.get.geometry, ghost.get.anchor)
      discard g_meshes.emitObject(placed_ghost, INK_GHOST.colour.muted(), scale)
      cost.chargeTally(
        placed_ghost.kind, is_sky = false, is_ghost = true, is_selected = false
      )

    # Emit what drag in progress would build, in same ghost ink.
    #   Reader learns one "not committed yet" appearance; mirrors
    #   `visualiser.assembleMeshes`.
    if g_interaction.preview.isSome:
      var placed_preview = placeObject(
        g_interaction.preview.get.geometry, g_interaction.preview.get.anchor,
      )
      discard g_meshes.emitObject(placed_preview, INK_GHOST.colour.muted(), scale)
      cost.chargeTally(
        placed_preview.kind, is_sky = false, is_ghost = true, is_selected = false
      )

    # Emit everything selected last, drawn with depth test off.
    #   Picked object is then never buried.
    #   Mirrors `visualiser.assembleMeshes`.
    markOverlay(g_meshes)
    for position in 0 ..< g_selection.len:
      let slot = g_selection.at(position)
      if not g_scene.isAlive(slot) or not g_scene.isVisible(slot): continue
      let progress = animationProgress(float(now), g_borns[slot])
      discard g_meshes.emitObject(
        g_placed[slot], g_scene.inkAt(slot).colour, scale, progress,
      )
      cost.chargeTally(
        g_placed[slot].kind, is_sky = false, is_ghost = false, is_selected = true
      )

    # Draw algebra's own layer over scene it explains.
    #   Every multivector this frame derived, in true form; `algebra_view.addFrameTrace`,
    #   shared with desktop.
    ms_before_algebra = performanceNow()
    if is_algebra_shown:
      g_meshes.addFrameTrace(
        g_scratch, g_trace, g_scene, g_camera, ghost, g_interaction.cursor, scale,
        width = int(float(aspect)*float(height_pixels)), height = int(height_pixels),
      )
    ms_after_algebra = performanceNow()
    g_counts_scene = cost

  let vp = g_camera.initMatrixViewProjection(float(aspect))
  for row in 0 .. 3:
    for column in 0 .. 3:
      g_flat_view[4*column + row] = vp.at(row, column)

  # Flatten into locals rather than in constructor.
  #   Pack phase then has start and end clock can bracket.
  let ms_after_matrix = performanceNow()
  let ms_before_flatten = ms_after_matrix
  # Hold flatten with tessellation.
  #   Records did not change, so flat buffers already hold exactly what rerun would
  #   write; `glue.js` skips uploads on same flag.
  if not is_scene_held:
    flattenDiscsInto(g_meshes.discs, g_flat_disc)
    flattenRingsInto(g_meshes.rings, g_flat_ring)
    flattenDomesInto(g_meshes.domes, g_flat_dome)
    flattenWashRunsInto(g_meshes.washes, g_flat_runs)
    flattenRibbonsInto(g_meshes.ribbons, g_flat_ribbon)
    flattenInto(g_meshes.points, g_flat_point)
  if is_furniture_held: g_flat_furniture.used = 0
  else: flattenRibbonsInto(g_meshes_furniture.ribbons, g_flat_furniture)
  let ms_done = performanceNow()

  var data = FrameData(
    ring_records: g_flat_ring.view,
    disc_records: g_flat_disc.view,
    dome_records: g_flat_dome.view,
    wash_runs: g_flat_runs.view,
    ribbon_verts: g_flat_ribbon.view,
    point_verts: g_flat_point.view,
    view_projection: g_flat_view,
    furn_ribbon_verts: g_flat_furniture.view,
    is_scene_held: is_scene_held,
    is_furniture_held: is_furniture_held,
    cam_eye_x: float32(scale.eye.x), cam_eye_y: float32(scale.eye.y),
    cam_eye_z: float32(scale.eye.z),
    cam_forward_x: float32(scale.forward.x), cam_forward_y: float32(scale.forward.y),
    cam_forward_z: float32(scale.forward.z),
    cam_depth_near: float32(scale.depth_near),
    cam_tangent_half_view: float32(scale.tangent_half_view),
    cam_height_pixels: float32(scale.height_pixels),
    fog_radius_full: float32(fogFurnitureFor(scale.extent_furniture).radius_full),
    fog_radius_gone: float32(fogFurnitureFor(scale.extent_furniture).radius_gone),
    ms_grid: float32(ms_grid),
    ms_axes: float32(ms_axes),
    count_grid_segments: g_count_grid_segments,
    ms_points: float32(cost.ms_points),
    ms_lines: float32(cost.ms_lines),
    ms_planes: float32(cost.ms_planes),
    ms_sky: float32(cost.ms_sky),
    ms_ghost: float32(cost.ms_ghost),
    ms_selected: float32(cost.ms_selected),
    count_points: cost.count_points,
    count_lines: cost.count_lines,
    count_planes: cost.count_planes,
    count_sky: cost.count_sky,
    count_ghost: cost.count_ghost,
    count_selected: cost.count_selected,
    ms_build: float32(ms_done - ms_entered),
    ms_furniture: float32(ms_after_furniture - ms_before_furniture),
    # Take scene phase as everything between furniture and flatten.
    #   Clearing, both passes, ghost and preview, overlay marking.
    ms_algebra: float32(ms_after_algebra - ms_before_algebra),
    ms_scene: float32(ms_before_algebra - ms_after_furniture),
    ms_flatten: float32(ms_done - ms_before_flatten),
    ms_camera: float32(ms_after_camera - ms_entered),
    ms_matrix: float32(ms_after_matrix - ms_after_algebra),
    # Report what named phases still do not cover.
    #   Never negative: clock going backwards is coarsened timer, not phase running for
    #   less than nothing.
    ms_unaccounted: float32(max(0.0,
      (ms_done - ms_entered) - (ms_after_camera - ms_entered) -
      (ms_after_furniture - ms_before_furniture) - (ms_before_algebra - ms_after_furniture) -
      (ms_after_algebra - ms_before_algebra) - (ms_after_matrix - ms_after_algebra) -
      (ms_done - ms_before_flatten))),
    ms_placing: float32(spentOn(Side.Placing)),
    ms_emitting: float32(spentOn(Side.Emitting)),
    ms_hover_pick: float32(recordLastFrame().ms_hover_pick),
    # Split ribbons in records, washes in whole runs.
    #   Instanced draws take ranges of instances.
    ribbon_over: (if g_meshes.ribbons.index_overlay.isSome:
      max(0, g_meshes.ribbons.count - g_meshes.ribbons.index_overlay.get) else: 0),
    ring_over: (if g_meshes.rings.index_overlay.isSome:
      max(0, g_meshes.rings.count - g_meshes.rings.index_overlay.get) else: 0),
    point_over: countOverlay(g_meshes.points),
    wash_run_over: (if g_meshes.washes.index_overlay.isSome:
      max(0, g_meshes.washes.count - g_meshes.washes.index_overlay.get) else: 0),
  )
  # Stamp whole of proc after record is built.
  #   Overlay scans and record's construction fall past `ms_done`, so tail would belong to
  #   no row; residue widens by same span, so rows still sum.
  let ms_returned = performanceNow()
  data.ms_build = float32(ms_returned - ms_entered)
  data.ms_unaccounted += float32(ms_returned - ms_done)
  data
