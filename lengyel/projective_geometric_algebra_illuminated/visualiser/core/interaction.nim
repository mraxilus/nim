## Track a drag gesture from one scene item to another, and apply the operation it makes.
##
## **The press target chooses the scheme; the button chooses whether you are asked.** A drag
## begins only when the press lands on a pickable item — press on empty space is left for
## camera orbit or pan instead, so the two schemes never compete for one click. The left
## button then decides for you and the right asks, over the *same* set of choices; neither
## reaches anything the other cannot.
##
## What a drag applies is decided at release, from the operands, not from the button that
## started it. A button naming an operation is what this used to do, and it put a third of
## the vocabulary behind a middle button most trackpads lack while leaving the whole
## vocabulary invisible: nothing on screen said what right-drag meant. So the operands say
## instead — `proposalFor` reads the two grades — and the drag *shows* its answer as a ghost
## before committing it, which is the self-revelation the gesture had none of.
##
## Hover is tracked independently of dragging, every frame, purely so the item a drag would
## start from can be shown before any button is pressed.
##
## A *hold* is the touch counterpart, where there are no buttons to name an operation with:
## press an item and keep still, and once the press has lasted `SECONDS_LONG_PRESS` it
## selects that item. The elapsed fraction lives here rather than in either presentation
## layer, because how long a hold takes and whether one is due are rules about this gesture,
## not about a timer -- and because both are what the item's own marker is drawn part-built
## from, which is the only reason a half-second wait is bearable.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../../pga
import ./[camera, format, mesh, objects, picking, scene]



#[ Gesture Configuration ]#

# Every `now` this module takes is **seconds**, on whatever monotonic clock the caller
#   owns, and it is the same clock `scene.addItem` records a birth on -- one reading
#   threaded through a whole release rather than two that could disagree. Named in the
#   constants below rather than left to a comment: the browser's own clock reads in
#   milliseconds, and while the durations here were named for those, the desktop passed
#   seconds against them and its dwell menu quietly needed 450 seconds to open.

const SECONDS_DWELL_MENU* = 0.45
  ## Hold a drag **still** over its target this long and the choice menu opens.
  ##   Still, not merely present: the clock restarts whenever the cursor moves further than
  ##   `PIXELS_TAP_SLOP` from where it last settled, so time spent crossing a target does
  ##   not count toward opening a menu over it. This was measured, not supposed -- while
  ##   the clock ran on presence alone, a slow finger crossing the ground plane tripped it
  ##   mid-drag and the construction it was in the middle of ended up building nothing.
  ##   Longer than a threshold triggered on its own would dare be, and deliberately so:
  ##   a reader who wants the menu without waiting presses the right button instead, so
  ##   this only has to be slow enough never to fire on a hesitation. The usual failure of
  ##   a dwell menu is popping up at someone who was still moving.

const SECONDS_LONG_PRESS* = 0.50
  ## Hold a touch this long on an item to select it.
  ##   Long enough that a tap, or the first instant of a drag meant to orbit the camera,
  ##   never matures into one; short enough that a deliberate hold does not feel stuck.
  ##   The wait is only tolerable because it is *shown* -- `progressHold` below drives the
  ##   item's own marker being drawn part-built, so a hold reads as filling rather than as
  ##   nothing happening. A hold with no feedback at this duration reads as a broken tap.

const SECONDS_SWELL_GROW* = 0.12
  ## Take this long to swell a touched item's marker clear of the finger, before its own
  ## fill begins.
  ##   Its own phase ahead of the fill rather than folded into it, so the marker is
  ##   already at the size it will fill at when it starts filling -- a bar that grows and
  ##   fills at once is two motions saying one thing, and the growing wins. Quick enough
  ##   to read as the marker getting out of the way rather than as a delay before anything
  ##   happens, which is what a press must never feel like.
  ##   It does lengthen a press end to end, to `SECONDS_SWELL_GROW + SECONDS_LONG_PRESS`;
  ##   the fill keeps its whole duration, so the part a reader watches is unchanged.

const SECONDS_SWELL_SHRINK* = 0.15
  ## Take this long to settle a swollen marker back to its true size after the finger
  ## lifts.
  ##   Slower than the grow: the grow is getting out of the way and wants to be over, while
  ##   this is the marker arriving at what it will stay as, and an outline that snaps to its
  ##   final size reads as a second marker replacing the first.

const PIXELS_TAP_SLOP* = 12.0
  ## Move a press further than this and it stops being a press.
  ##   **Which scheme the gesture enters**, not merely whether it was a tap: a press that
  ##   stays inside this matures into a selection, and one that leaves it becomes a
  ##   construction drag where it landed on an item and a camera move where it did not.
  ##   That is why it sits beside the two durations above rather than in either
  ##   presentation layer -- it decides the same kind of thing they do. It lived in
  ##   `glue.js` while it only meant "tap or orbit"; deciding the scheme is a rule about
  ##   the gesture.
  ##   Sized for a fingertip rather than a mouse: a finger rolls a few pixels on contact
  ##   even when its owner meant to hold perfectly still, and a threshold tight enough for
  ##   a mouse would make long-press unreachable on a touchscreen.

const PIXELS_CLICK_SLOP* = 6.0
  ## Move a *pointer* press further than this and it stops being a click.
  ##   Deliberately not `PIXELS_TAP_SLOP`, which is sized for a fingertip: a mouse resting
  ##   on a desk does not roll, so a pointer that wandered six pixels was being moved on
  ##   purpose, and a fingertip's allowance here would swallow the short deliberate drags
  ##   between two objects that happen to overlap on screen.
  ##   Lived in `glue.js` as `MOUSE_CLICK_MAX_MOVE` while only the browser had a click to
  ##   disambiguate; deciding whether a press was a click is a rule about the gesture, and
  ##   the desktop needs the same answer.

const SECONDS_CLICK* = 0.35
  ## Release a pointer press within this of its landing and it is still a click.
  ##   A press held longer over an object was being held there, which is what opens the
  ##   dwell menu at `SECONDS_DWELL_MENU` -- comfortably past this, so no press can
  ##   ever be both. Was `MOUSE_CLICK_MAX_MS` in `glue.js`, for the same reason as above.

const PIXELS_MENU_REACH* = 76.0
  ## Distance from the menu's centre to the centre of each of its four wedges.
  ##   Wide enough that a wedge clears the cursor and the object under it, and that each
  ##   is comfortably past WCAG 2.5.8's 24-pixel target once `PIXELS_MENU_DEADZONE` is
  ##   subtracted; short enough to stay one wrist movement, since the menu opens mid-drag
  ##   and the hand is already committed.

const PIXELS_MENU_DEADZONE* = 26.0
  ## Inside this distance of the menu's centre, the cursor has chosen nothing.
  ##   The way out of an opened menu without committing anything, and the reason a dwell
  ##   menu is safe to open unasked: it opens *centred on the cursor*, so the reader who
  ##   did not want it is already in the deadzone and releasing costs them nothing.

const
  HEIGHT_MENU_WEDGE* = 30.0
    ## Height of one wedge. Past WCAG 2.5.8's 24-pixel target on its short axis, which is
    ## the axis that binds; the long one comes from the label the wedge holds, measured by
    ## whichever render path is drawing it rather than guessed at from a character count.
  PADDING_MENU_WEDGE* = 22.0
    ## Slack around a wedge's label, so a short name still reads as a button rather than
    ## as text lying loose on the scene.
  ROUNDING_MENU_WEDGE* = 6.0 ## Corner radius of a wedge.
  RADIUS_MENU_CENTRE* = 5.0
    ## Dot marking the menu's own centre, where nothing is chosen. Drawn well inside
    ## `PIXELS_MENU_DEADZONE` so it reads as a mark rather than as the boundary itself.
  ALPHA_MENU_WEDGE* = 0.94 ## Opacity of a wedge that can be chosen.
  ALPHA_MENU_UNOFFERED* = 0.30
    ## Opacity of one that makes nothing, which is drawn rather than dropped: a gap where
    ## a wedge should be is unreadable, and the point of a fixed compass is that a choice
    ## never moves.



#[ Type Definitions ]#

type
  DragOperation* {.pure.} = enum ## Name an operation a released drag may apply.
    Join, ## Wedge: the object through both operands.
    Meet, ## Antiwedge: where the two operands cross.
    Project, ## Orthogonal projection of the object dragged from onto the one dragged to.

  DragChoice* {.pure.} = enum ## Name everything a released drag may resolve to.
    ## The three operations plus the way out to the rest of the catalogue. Separate from
    ## `DragOperation` because `More` applies nothing itself -- it hands both operands to
    ## the apply section, which is what turns this gesture from a dead end into a ramp.
    Join, Meet, Project, More

  Compass* {.pure.} = enum ## Name where a choice sits in the menu, always.
    ## A fixed position per choice, with unoffered ones left as gaps rather than packed
    ## out. Packing would move a choice from pair to pair, and a menu whose items move is
    ## one nobody ever learns to reach without reading it.
    North, East, South, West

  Key* {.pure.} = enum ## Name a key the 3D view itself reacts to, in neither backend's naming.
    ## SDL names these by scancode and the DOM by `KeyboardEvent.key`; each render path
    ## translates its own into this and asks `actionFor` below, exactly as each translates
    ## its own mouse-button numbering into `PointerButton`. Only keys the *view* reacts to
    ## are here -- the accelerators that reach the timeline and the panels stay where they
    ## already are, since those are reached from anywhere rather than from the canvas.
    Left, Right, Up, Down, BracketLeft, BracketRight, Minus, Plus, Enter, Home

  KeyAction* {.pure.} = enum ## Name what a key does to the view.
    OrbitLeft, OrbitRight, OrbitUp, OrbitDown,
    PanLeft, PanRight, PanUp, PanDown,
    DollyIn, DollyOut,
    FocusPrevious, FocusNext,
    SelectFocused, ## Alone, or added to the selection where shift is held.
    FrameAll ## Return the camera to where it started.

  Hold* = object ## Hold a press that will select its item once it has lasted long enough.
    slot*: int ## Item pressed, and the one whose marker fills as the press matures.
    started*: float ## When the press landed, on the same clock every caller passes as `now`.
    is_taken*: bool ## Whether this hold's maturity has already been acted on.
      ## The one-shot lives here rather than beside the caller, because a hold now
      ## outlives its own release: a flag the release handler resets goes stale while the
      ## hold is still settling, the maturity test is still true, and the selection fires
      ## a *second* time and undoes itself. Measured -- a hold of 1.62 s selected its item
      ## and then lost it within 50 ms of the lift. Whether a hold is *due* was already
      ## this module's to say; whether anyone has done anything about it belongs with it.
    released*: Option[float] ## When the finger lifted, if it has.
      ## A hold outlives its own maturity: the marker stays swollen for as long as the
      ## finger is down, however long that is, and only settles once this says it may.
      ## Without it the swell had to be a function of the fill and was therefore back to
      ## its true size at exactly the moment the selection landed -- shrinking while the
      ## reader was still deciding, and gone when it mattered.

  Interaction* = object ## Hold cursor, drag and press state between frames.
    is_enabled*: bool ## Whether picking and overlay run at all; off during storyboard capture.
    cursor*: ScreenPosition ## Last known cursor position, in window pixels.
    index_hover*: Option[int] ## Item nearest cursor this frame, regardless of dragging.
    is_hover_backdrop*: bool ## Whether what is hovered is a plane at horizon -- the whole
      ## sky, which every ray meets, so this is true wherever nothing else is under the
      ## cursor and a sky is in the scene.
      ##   Recorded at `updateHover`, where the scene is already in hand, so that
      ## `beginDrag` and `endDrag` can refuse it without being handed the scene as well.
      ## **Refusing it is what keeps the camera working**: a press on empty space becomes
      ## an orbit precisely because `beginDrag` fails when nothing is hovered, and a sky
      ## is hovered everywhere. See `beginDrag`.
    index_focus*: Option[int] ## Item the **keyboard** stands on, which each render path
      ## draws with the same marker hover uses -- so a reader who has never touched a
      ## pointer can still see where they are, and the focus indicator is machinery that
      ## was already built and tested rather than a second one invented for it.
      ##   Separate from `index_hover` rather than sharing it: `updateHover` recomputes
      ## hover from the cursor every single frame, so a keyboard focus stored there would
      ## be erased before it could be drawn once.
    is_dragging*: bool ## Whether a construction drag is in progress. Not an
      ## `Option[DragOperation]` as it once was: what a drag applies is decided at release
      ## from the operands, so a field holding an operation could only have held a
      ## placeholder -- a sentinel smuggled into a value's own range.
    index_source*: int ## Item drag started from; meaningful only while `is_dragging`.
    index_destination*: Option[int] ## Item the drag points at, latched the moment its menu
      ## opens; see `destinationOf`, which is what every reader of this should ask instead.
    pressed*: ScreenPosition ## Where the last pointer press landed, whatever it became.
    started*: float ## When that press landed, on the same clock every caller passes as
      ## `now`. Read only through `isClick`.
    is_press_still*: bool ## Whether the last press has stayed inside `PIXELS_CLICK_SLOP`
      ## of where it landed. Latched rather than recomputed from the cursor each time it
      ## is asked: a pointer that swung out and came back was still dragged, and a reading
      ## taken at release alone would call that a click.
      ##   Stated as *still* rather than as *moved* so that the default is false: a press
      ## that never went through `beginPress` -- a caller that forgot, a drag a test drives
      ## by hand -- is then never mistaken for a click, whatever the clock happens to read.
    hold*: Option[Hold] ## Press maturing into a selection, if one is in progress.
    is_over_target*: bool ## Whether the drag currently points at an item that is not its
      ## own source. Distinct from `proposal` being none, which it also is over a pair
      ## that makes nothing -- and those two want opposite feedback, one neutral and one
      ## a warning, so the rubber-band's own tint needs to tell them apart.
    proposal*: Option[DragChoice] ## What a plain release would commit right now.
    preview*: Option[Multivector] ## What that proposal would make, for each render path to
      ## ghost. None where the drag is over nothing, over its own source, or over a pair
      ## that makes nothing -- and *that* is the case worth drawing nothing for, since it
      ## is the only warning before a refused release.
    is_menu_forced*: bool ## Whether this drag asks for the menu without waiting, which is
      ## what the right button means. Set at `beginDrag` and read every frame after.
    entered*: float ## When the cursor last settled over a target, for the dwell to run
      ## from. Restarted both when the hovered item changes and when the cursor moves
      ## away from `settled`, so the dwell measures being still rather than being present.
    settled*: ScreenPosition ## Where the cursor was when `entered` was last restarted;
      ## what movement is measured against to decide the dwell has been interrupted.
    menu*: Option[ScreenPosition] ## Where the choice menu is open, if it is.



#[ Operation Vocabulary ]#

type PointerButton* {.pure.} = enum ## Name a physical mouse button, however numbered.
  ## Neither backend's own numbering: SDL and the DOM count the three buttons
  ## differently (SDL 1/2/3 left/middle/right, the DOM 0/1/2 left/middle/right), so each
  ## render path translates its own numbers into this and asks `isMenuForcedBy` below.
  ## That keeps *which button does what* stated once, while leaving each path the
  ## translation only it can do.
  Left, Middle, Right


func actionFor*(key: Key; is_shifted: bool): KeyAction =
  ## Say what one key does to the view, with and without shift.
  ##   **The binding table**, stated once. `help.nim` renders its keyboard rows out of this
  ##   rather than transcribing them, so rebinding a key rewrites the help with it -- the
  ##   same arrangement that has kept the drag rows honest across two rebindings.
  ##   Arrows orbit and shift+arrows pan, which is the convention every 3D tool a reader
  ##   has met already uses. **Tab is deliberately absent**: cycling objects with it while
  ##   the view has focus is the tempting binding, and it risks a keyboard trap -- WCAG
  ##   2.1.2, also Level A -- so traversal took the brackets instead and Tab keeps meaning
  ##   "next control" everywhere. Fixing 2.1.1 by breaking 2.1.2 is not a fix.
  ##   Total by construction: every key does something in both shift states, so no caller
  ##   has an unhandled case and the suite can walk the whole table.
  case key
  of Key.Left: (if is_shifted: KeyAction.PanLeft else: KeyAction.OrbitLeft)
  of Key.Right: (if is_shifted: KeyAction.PanRight else: KeyAction.OrbitRight)
  of Key.Up: (if is_shifted: KeyAction.PanUp else: KeyAction.OrbitUp)
  of Key.Down: (if is_shifted: KeyAction.PanDown else: KeyAction.OrbitDown)
  of Key.BracketLeft: KeyAction.FocusPrevious
  of Key.BracketRight: KeyAction.FocusNext
  of Key.Minus: KeyAction.DollyOut
  of Key.Plus: KeyAction.DollyIn
  of Key.Enter: KeyAction.SelectFocused
  of Key.Home: KeyAction.FrameAll


func nameOf*(key: Key): string =
  ## Name a key as a reader would say it, for the help table to print.
  case key
  of Key.Left: "left"
  of Key.Right: "right"
  of Key.Up: "up"
  of Key.Down: "down"
  of Key.BracketLeft: "["
  of Key.BracketRight: "]"
  of Key.Minus: "-"
  of Key.Plus: "+"
  of Key.Enter: "enter"
  of Key.Home: "home"


func isMenuForcedBy*(button: PointerButton): Option[bool] =
  ## Say whether a button starts a construction drag, and whether that drag asks to choose
  ## rather than be chosen for.
  ##   None for a button that starts no drag at all. Middle is now such a button: `project`
  ##   used to live there, which put a third of the vocabulary behind hardware most
  ##   trackpads do not have. It lives in the menu instead, so nothing is unreachable.
  ##   Both buttons run the same operations and differ only in whether the reader is
  ##   asked -- redundancy for different expertise, not a mode split, which is exactly why
  ##   it is safe where a button-per-operation mapping was not.
  case button
  of PointerButton.Left: some(false)
  of PointerButton.Right: some(true)
  of PointerButton.Middle: none(bool)


func toDrag*(choice: DragChoice): Option[DragOperation] =
  ## Read a choice as the operation it applies, if it applies one.
  case choice
  of DragChoice.Join: some(DragOperation.Join)
  of DragChoice.Meet: some(DragOperation.Meet)
  of DragChoice.Project: some(DragOperation.Project)
  of DragChoice.More: none(DragOperation)


func compassOf*(choice: DragChoice): Compass =
  ## Place a choice in the menu. Fixed for the life of the program; see `Compass`.
  ##   North is the default a plain release takes most often, so the commonest choice is
  ##   also the one nearest the cursor's own resting direction.
  case choice
  of DragChoice.Join: Compass.North
  of DragChoice.Meet: Compass.East
  of DragChoice.Project: Compass.South
  of DragChoice.More: Compass.West


func labelOf*(choice: DragChoice): string =
  ## Name a choice as its wedge says it, in the words the help table already uses.
  case choice
  of DragChoice.Join: "join"
  of DragChoice.Meet: "meet"
  of DragChoice.Project: "project"
  of DragChoice.More: "more…"


func inkOf*(choice: DragChoice): Ink =
  ## Tint a choice, for its wedge and for the rubber-band pointing at it.
  ##   Named here rather than in either render path, which each kept their own copy of
  ##   this table with a comment telling the next reader to check the other one.
  case choice
  of DragChoice.Join: Ink.Jade
  of DragChoice.Meet: Ink.Rose
  of DragChoice.Project: Ink.Olive
  of DragChoice.More: Ink.Guide


func offsetOf(compass: Compass): tuple[x, y: float] =
  ## Point from the menu's centre toward one wedge, one reach away, in screen pixels.
  ##   Screen y grows downward, so south is positive.
  case compass
  of Compass.North: (0.0, -PIXELS_MENU_REACH)
  of Compass.East: (PIXELS_MENU_REACH, 0.0)
  of Compass.South: (0.0, PIXELS_MENU_REACH)
  of Compass.West: (-PIXELS_MENU_REACH, 0.0)


func anchorOf*(centre: ScreenPosition; choice: DragChoice): ScreenPosition =
  ## Place one wedge on screen, given where its menu opened.
  let offset = offsetOf(compassOf(choice))
  ScreenPosition(x: centre.x + offset.x, y: centre.y + offset.y, depth: centre.depth)


func choiceAt*(centre, cursor: ScreenPosition): Option[DragChoice] =
  ## Say which wedge of a menu opened at `centre` the cursor stands in, if any.
  ##   Wedges are quadrants rather than discs, so every direction outside the deadzone
  ##   belongs to exactly one of them and there is no gap between two to release into by
  ##   accident. Distance past the deadzone is not bounded either: overshooting a wedge
  ##   still picks it, which is what makes a fast confident throw work.
  let
    dx = cursor.x - centre.x
    dy = cursor.y - centre.y
  if dx*dx + dy*dy < PIXELS_MENU_DEADZONE*PIXELS_MENU_DEADZONE: return none(DragChoice)
  let compass =
    if abs(dx) > abs(dy): (if dx > 0.0: Compass.East else: Compass.West)
    else: (if dy > 0.0: Compass.South else: Compass.North)
  for choice in DragChoice:
    if compassOf(choice) == compass: return some(choice)
  none(DragChoice)


func toOperation*(drag: DragOperation): Operation =
  ## Translate drag's own vocabulary to library's operation catalogue.
  case drag
  of DragOperation.Join: Operation.Wedge
  of DragOperation.Meet: Operation.WedgeAnti
  of DragOperation.Project: Operation.ProjectOrthogonal


func resultOf*(choice: DragChoice; m, n: Multivector): Option[Multivector] =
  ## Work out what a choice would make of these two operands, if it makes anything.
  ##   None for `More`, which applies nothing itself, and none wherever the result has no
  ##   drawable shape. That one test covers both ways a construction comes to nothing: a
  ##   pair of the wrong grades, whose join or meet lands on a scalar or antiscalar, and a
  ##   pair already lying on each other, whose result is zero. Measured rather than
  ##   assumed: `objects.shape` reads `grade`, which already tolerances a near-zero away,
  ##   so a line of magnitude 1e-14 reports no grade and no shape without a second test
  ##   here to catch it.
  let drag = toDrag(choice)
  if drag.isNone: return
  let derived = applyOperation(drag.get.toOperation, m, n)
  if shape(derived).isNone: return
  some(derived)


func isOffered*(choice: DragChoice; m, n: Multivector): bool =
  ## Report whether a choice would make something of these two operands.
  ##   `More` is always offered: handing a pair to the apply section is worth doing
  ##   whatever the three named operations make of them, and it is the only route from
  ##   this gesture to the rest of the catalogue.
  choice == DragChoice.More or resultOf(choice, m, n).isSome


func proposalFor*(m, n: Multivector): Option[DragChoice] =
  ## Choose what a plain release should make of these two operands, if anything.
  ##   A plain order, not a ranking: measured over every ordered pair of point, line and
  ##   plane, **at most one of join and meet is ever drawable**, so there is never a tie
  ##   between them to arbitrate, and `project` picks up the pairs where neither is. The
  ##   suite pins that, because it is the whole reason this can be an order rather than a
  ##   table of nine cases.
  ##   None for a pair that makes nothing at all -- a plane dragged onto a point is one --
  ##   which is why this is an `Option` and why a release on such a pair refuses rather
  ##   than inventing something to add.
  for choice in [DragChoice.Join, DragChoice.Meet, DragChoice.Project]:
    if isOffered(choice, m, n): return some(choice)
  none(DragChoice)


func inkOfDrag*(interaction: Interaction): Ink =
  ## Tint the rubber-band of the drag in progress by what releasing it would do.
  ##   Three states, and the middle one is the reason this is not just `inkOf(proposal)`:
  ##   crossing empty space is neutral, standing over a pair that makes nothing wears the
  ##   reserved `Ink.Invalid` magenta, and standing over one that makes something wears
  ##   that operation's own colour. The warning arrives *before* the release rather than
  ##   as a message after it, which is the whole point of previewing at all -- and it is
  ##   never colour alone, since the ghost simultaneously fails to appear.
  if not interaction.is_over_target: Ink.Guide
  elif interaction.proposal.isNone: Ink.Invalid
  else: inkOf(interaction.proposal.get)


func notation*(drag: DragOperation): string =
  ## Name drag operation for messages, in library's own ASCII notation.
  case drag
  of DragOperation.Join: "^"
  of DragOperation.Meet: "v"
  of DragOperation.Project: "->"



#[ Cursor And Hover ]#

proc updateCursor*(interaction: var Interaction; x, y: float) =
  ## Record cursor's latest window position, and note whether a press has become a drag.
  interaction.cursor = ScreenPosition(x: x, y: y, depth: 0.0)
  if interaction.is_press_still:
    let
      dx = interaction.cursor.x - interaction.pressed.x
      dy = interaction.cursor.y - interaction.pressed.y
    if dx*dx + dy*dy > PIXELS_CLICK_SLOP*PIXELS_CLICK_SLOP:
      interaction.is_press_still = false


proc updateHover*(
  interaction: var Interaction; scene: Scene;
  camera: Camera; view_projection: Matrix4; width, height: int
) =
  ## Recompute item nearest cursor, so overlay and drag-start agree on what stands under it.
  interaction.index_hover =
    if interaction.is_enabled:
      pickNearest(scene, camera, view_projection, width, height, interaction.cursor)
    else:
      none(int)
  # Noted here because this is where the scene is in hand; see `is_hover_backdrop`.
  interaction.is_hover_backdrop =
    interaction.index_hover.isSome and
    scene.geometryOf(interaction.index_hover.get).isHorizonPlane



#[ Keyboard ]#

proc applyAction*(
  interaction: var Interaction; camera: var Camera; scene: Scene; action: KeyAction
): Option[int] =
  ## Carry out one keyboard action, and report which item the caller should select.
  ##   Moves the camera and the focus itself, because both are its own state; **does not
  ##   touch the selection**, which each render path owns differently (a `Panel` field
  ##   on one, a module global on the other). Reporting a slot rather than selecting it
  ##   also leaves the caller to read its own shift state and decide between replacing the
  ##   selection and adding to it -- see `KeyAction.SelectFocused`.
  ##   None for every action but a select, and for a select with nothing focused, which is
  ##   what a reader gets for pressing enter before walking anywhere.
  case action
  of KeyAction.OrbitLeft: camera.orbit(-TURN_PRESS, 0.0)
  of KeyAction.OrbitRight: camera.orbit(TURN_PRESS, 0.0)
  of KeyAction.OrbitUp: camera.orbit(0.0, RISE_PRESS)
  of KeyAction.OrbitDown: camera.orbit(0.0, -RISE_PRESS)
  of KeyAction.PanLeft: camera.pan(PAN_PRESS, 0.0)
  of KeyAction.PanRight: camera.pan(-PAN_PRESS, 0.0)
  of KeyAction.PanUp: camera.pan(0.0, -PAN_PRESS)
  of KeyAction.PanDown: camera.pan(0.0, PAN_PRESS)
  of KeyAction.DollyIn: camera.dolly(1.0/FACTOR_DOLLY_PRESS)
  of KeyAction.DollyOut: camera.dolly(FACTOR_DOLLY_PRESS)
  of KeyAction.FocusPrevious: interaction.index_focus = scene.slotStepped(
    interaction.index_focus, -1
  )
  of KeyAction.FocusNext: interaction.index_focus = scene.slotStepped(
    interaction.index_focus, 1
  )
  of KeyAction.SelectFocused:
    if interaction.index_focus.isSome and scene.isAlive(interaction.index_focus.get):
      return interaction.index_focus
  of KeyAction.FrameAll:
    # The placement both builds open at, so "home" means the same thing as starting again.
    camera = initCameraDefault()
  none(int)


proc pruneFocus*(interaction: var Interaction; scene: Scene) =
  ## Drop a keyboard focus whose item has gone, the same guard the selection already keeps.
  ##   A slot carried across frames may be freed by any other input path between them, and
  ##   a focus left pointing at a dead one would have its marker drawn off freed storage.
  if interaction.index_focus.isSome and not scene.isAlive(interaction.index_focus.get):
    interaction.index_focus = none(int)



#[ Hold Lifecycle ]#

proc beginHold*(interaction: var Interaction; slot: int; now: float) =
  ## Start a press on `slot` that will select it once it has lasted long enough.
  interaction.hold = some(
    Hold(slot: slot, started: now, is_taken: false, released: none(float))
  )


proc releaseHold*(interaction: var Interaction; now: float) =
  ## Note that the finger has lifted, starting the marker's settle back to its true size.
  ##   Distinct from `cancelHold` on purpose. This is a press ending the way a press is
  ##   meant to, so its marker settles; cancelling is a press that stopped being one --
  ##   moved into a camera gesture, interrupted by a second finger, escaped -- and that
  ##   snaps away, because there is nothing left for a settle to be about.
  ##   Recording the moment rather than clearing the hold outright: the swell still has a
  ##   phase left to run, and `swellHold` retires the hold once it is spent.
  if interaction.hold.isNone or interaction.hold.get.released.isSome: return
  interaction.hold.get.released = some(now)


proc cancelHold*(interaction: var Interaction) =
  ## Abandon a press in progress, selecting nothing.
  ##   What the caller reaches for when the finger moved into a camera gesture, a second
  ##   finger landed, the press was released early, or the user pressed escape.
  interaction.hold = none(Hold)


func progressHold*(interaction: Interaction; now: float): float =
  ## Report how far a press in progress has matured, from 0 at the press to 1 once it is
  ## due; 0 where no press is in progress.
  ##   Clamped at both ends, so a caller may keep asking after the press is due and after
  ##   the clock has jumped, and still get something it can draw.
  ##   Linear, deliberately, and not through `mesh.easeOutCubic` as every other animation
  ##   here is: this is a clock being shown rather than a transition being softened, and an
  ##   eased clock reads as stalling just before it fires -- exactly where a user is
  ##   deciding whether the hold is working.
  ##   Starts only once `SECONDS_SWELL_GROW` has passed, so the marker is already at the
  ##   size it will fill at before it begins filling; see `swellHold`.
  if interaction.hold.isNone: return 0.0
  let elapsed = now - interaction.hold.get.started - SECONDS_SWELL_GROW
  max(0.0, min(1.0, elapsed/SECONDS_LONG_PRESS))


func swellHold*(interaction: Interaction; now: float): float =
  ## Report how far a touched item's marker is swollen clear of the finger, from 0 at its
  ## true size to 1 fully out; 0 where no press is in progress.
  ##   **On its own clock, not on the fill's.** Four phases, and only the middle two are
  ## about the fill at all:
  ##
  ##   | Phase | While | Swell |
  ##   |-------|-------|-------|
  ##   | grow | the first `SECONDS_SWELL_GROW` | 0 rising to 1 |
  ##   | fill | the `SECONDS_LONG_PRESS` after that | 1 |
  ##   | held | however long the finger stays down past maturity | 1 |
  ##   | settle | `SECONDS_SWELL_SHRINK` after the lift | 1 falling to 0 |
  ##
  ##   The *held* phase is the point of the whole arrangement. The swell used to be a half
  ## sine over the fill, which put the marker back at its true size at exactly the moment
  ## the selection landed -- shrinking while the reader was still deciding, and gone when
  ## it mattered. It now stays out until the finger says otherwise, for as long as that
  ## takes.
  ##   Eased at both ends through `mesh.easeOutCubic`, unlike `progressHold` beside it:
  ## these are transitions being softened, where that is a clock being shown.
  if interaction.hold.isNone: return 0.0
  let hold = interaction.hold.get
  if hold.released.isSome:
    let settling = (now - hold.released.get)/SECONDS_SWELL_SHRINK
    return 1.0 - easeOutCubic(clamp(settling, 0.0, 1.0))
  easeOutCubic(clamp((now - hold.started)/SECONDS_SWELL_GROW, 0.0, 1.0))


func isHoldSpent*(interaction: Interaction; now: float): bool =
  ## Report whether a released hold has finished settling and may be forgotten.
  ##   Asked by the caller that owns the frame loop, so a hold retires on a frame boundary
  ## rather than inside whichever query happened to be asked last. A hold still under a
  ## finger is never spent, however long it has been held.
  ##   Stated against `swellHold` rather than against `SECONDS_SWELL_SHRINK` a second time,
  ## which is `isHoldMature`'s rule and for the same reason: two comparisons against one
  ## duration are two chances to disagree, and here they genuinely would -- subtracting two
  ## large timestamps loses enough precision that a hold released at 1005.62 and asked at
  ## 1005.77 measures 0.14999999999997 against a 0.15 shrink.
  interaction.hold.isSome and interaction.hold.get.released.isSome and
    swellHold(interaction, now) <= 0.0


func isHoldMature*(interaction: Interaction; now: float): bool =
  ## Report whether a press in progress has lasted long enough to select its item.
  ##   Stated against `progressHold` rather than against the elapsed time again, so the
  ##   moment the marker finishes filling is the same moment the selection lands. Two
  ##   comparisons against the same duration would be two chances to disagree.
  interaction.hold.isSome and progressHold(interaction, now) >= 1.0


proc takeHold*(interaction: var Interaction; now: float): Option[int] =
  ## Report the slot a matured hold selects, **exactly once**, and nothing on any later
  ## call; none while the hold is still filling, and none where there is no hold at all.
  ##   The one call a frame loop needs, replacing "is it mature" asked beside a flag the
  ## caller kept for "have I already acted on that". Those two facts have to agree, and
  ## they stopped agreeing the moment a hold began outliving its own release: the caller
  ## cleared its flag on the lift while the hold was still settling and still mature, so
  ## the next frame selected the item a second time and toggled it straight back off. A
  ## 1.62-second hold selected its item and lost it within 50 ms of the finger leaving.
  ##   Taking it does not end it. The hold stays for its swell to settle out of -- what is
  ## spent is the *selection*, not the gesture.
  if interaction.hold.isNone or interaction.hold.get.is_taken: return
  if not isHoldMature(interaction, now): return
  interaction.hold.get.is_taken = true
  some(interaction.hold.get.slot)



#[ Drag Lifecycle ]#

func destinationOf*(interaction: Interaction): Option[int] =
  ## Say which item the drag in progress points at, for its release to build with.
  ##   Hover while no menu is open, and the item the menu opened over once one is. That
  ##   second case is not a refinement: a menu opens *centred on the cursor*, so reaching
  ##   out to a wedge necessarily takes the cursor off the item, and a destination read
  ##   from hover would go none at exactly the moment the release needs it.
  ##   None over the sky, the same refusal `beginDrag` makes at the other end of the
  ##   gesture: a release over the backdrop stays "released over empty space; nothing
  ##   done" rather than quietly taking the whole sky as an operand.
  if interaction.menu.isSome: interaction.index_destination
  elif interaction.is_hover_backdrop: none(int)
  else: interaction.index_hover


proc beginPress*(interaction: var Interaction; now: float) =
  ## Note where and when a pointer press landed, whatever that press turns out to be.
  ##   Every press goes through this -- the ones that start a construction drag and the
  ##   ones that fall through to the camera alike -- because `isClick` below answers the
  ##   same question about both: a click on an object selects it and a click on empty
  ##   space clears the selection, and neither is a drag.
  ##   Call it **at the press**, before `beginDrag` -- not from inside `beginDrag`, which
  ##   a touch path only reaches once the finger has already travelled far enough to stop
  ##   being a tap, and which would then re-anchor the press mid-gesture and let a short
  ##   deliberate drag report itself as a click.
  ##   Forgetting it fails safe: `is_press_still` is false until this raises it, so the
  ##   gesture behaves exactly as it did before clicks existed rather than reporting one.
  interaction.pressed = interaction.cursor
  interaction.started = now
  interaction.is_press_still = true


func isClick*(interaction: Interaction; now: float): bool =
  ## Report whether the press in progress is still a click rather than a drag.
  ##   Both bounds have to hold: it has not left `PIXELS_CLICK_SLOP` of where it landed,
  ##   and it has not lasted `SECONDS_CLICK`. Asked at the release, by whichever path
  ##   is resolving the press -- `endDrag` for one that started over an object, the render
  ##   path itself for one that started over empty space, which begins no drag to end.
  interaction.is_press_still and now - interaction.started < SECONDS_CLICK


proc beginDrag*(interaction: var Interaction; is_menu_forced: bool; now: float): bool =
  ## Start a construction drag from the item currently hovered.
  ##   Reports whether one actually started, so a caller knows whether to fall back to
  ##   camera orbit or pan instead.
  ##   `is_menu_forced` is what the button chose: false waits for a dwell before offering
  ##   the menu and takes the proposal on a plain release, true offers it at once. Both
  ##   reach the same choices -- see `isMenuForcedBy`.
  ##   Expects `beginPress` to have run for this same press; see its own doc.
  ##   **A plane at horizon is a click and hold target, never a drag handle.** It is drawn
  ##   as a dome over every direction, so it is hovered wherever nothing else is, and a
  ##   press on it starting a construction drag would mean a press on empty space no longer
  ##   falls through to the camera -- orbit and pan would stop working outright the moment
  ##   a sky joined the scene. Refusing it here keeps that fall-through, and costs nothing
  ##   a reader would want: dragging the backdrop *is* moving the view.
  if interaction.index_hover.isNone or interaction.is_hover_backdrop: return false
  interaction.is_dragging = true
  interaction.index_source = interaction.index_hover.get
  interaction.index_destination = none(int)
  interaction.is_menu_forced = is_menu_forced
  interaction.entered = now
  interaction.settled = interaction.cursor
  interaction.menu = none(ScreenPosition)
  interaction.is_over_target = false
  interaction.proposal = none(DragChoice)
  interaction.preview = none(Multivector)
  true


proc cancelDrag*(interaction: var Interaction) =
  ## Abandon drag in progress without applying anything.
  interaction.is_dragging = false
  interaction.menu = none(ScreenPosition)
  interaction.is_over_target = false
  interaction.proposal = none(DragChoice)
  interaction.preview = none(Multivector)


proc updateDrag*(
  interaction: var Interaction; scene: Scene; now: float
) =
  ## Recompute, for the frame just about to draw, what the drag in progress would make and
  ## whether its menu should be open.
  ##   Called after `updateHover`, which is what decides where the drag currently points.
  ##   The preview is `proposalFor`'s own answer applied, so what is ghosted is exactly
  ##   what a plain release commits -- one rule, drawn and then obeyed, rather than a
  ##   preview computed one way and a commit another.
  if not interaction.is_dragging:
    interaction.is_over_target = false
    interaction.proposal = none(DragChoice)
    interaction.preview = none(Multivector)
    interaction.menu = none(ScreenPosition)
    return

  # Latch what the drag points at while no menu is open, so the one that opens is the one
  #   whose destination the wedges will act on.
  if interaction.menu.isNone: interaction.index_destination = interaction.index_hover

  let over = destinationOf(interaction)
  interaction.is_over_target =
    over.isSome and over.get != interaction.index_source and
    scene.isAlive(over.get) and scene.isAlive(interaction.index_source)
  if not interaction.is_over_target:
    # Left the target: the dwell starts again from wherever it next arrives, so pausing
    #   on the way across never counts toward opening a menu somewhere else.
    interaction.proposal = none(DragChoice)
    interaction.preview = none(Multivector)
    interaction.entered = now
    interaction.settled = interaction.cursor
    return

  # Moving restarts the dwell, so what it measures is being *still* rather than being over
  #   something. Without this the clock ran on presence alone, and a slow drag that stayed
  #   over one large object -- a plane's disc spans most of a phone screen -- had the menu
  #   open on it mid-gesture and built nothing on release. Measured on a real finger.
  let
    dx = interaction.cursor.x - interaction.settled.x
    dy = interaction.cursor.y - interaction.settled.y
  if dx*dx + dy*dy > PIXELS_TAP_SLOP*PIXELS_TAP_SLOP:
    interaction.entered = now
    interaction.settled = interaction.cursor

  let
    m = scene.geometryOf(interaction.index_source)
    n = scene.geometryOf(over.get)
  interaction.proposal = proposalFor(m, n)
  interaction.preview =
    if interaction.proposal.isSome: resultOf(interaction.proposal.get, m, n)
    else: none(Multivector)
  if interaction.menu.isNone and
      (interaction.is_menu_forced or now - interaction.entered >= SECONDS_DWELL_MENU):
    interaction.menu = some(interaction.cursor)


type DragOutcome* = object ## Report everything a released drag did, for the caller to act on.
  message*: string ## What to say happened, whether or not anything was built.
  index_created*: Option[int] ## Item added, where one was; none for every refusal, for a
    ## release that chose nothing, and for `More`, which builds nothing itself.
  choice*: Option[DragChoice] ## What the release resolved to, so a caller can recognise
    ## `More` -- which is otherwise indistinguishable from a refusal, both adding no item.
  operands*: Option[tuple[source, destination: int]] ## The two items, where both were
    ## alive and distinct. What `More` hands to the apply section, and the only reason it
    ## is reported: the drag's own state is cleared by the time a caller reads this.
  index_clicked*: Option[int] ## Item a press that never became a drag came down on, for
    ## the caller to select. None for every actual drag, so a caller may branch on this
    ## alone rather than re-deriving what kind of gesture it just ended.


proc commitChoice*(
  interaction: var Interaction; scene: var Scene; choice: DragChoice; now: float
): DragOutcome =
  ## Apply one choice between the drag's own source and whatever it points at.
  ##   Split out of `endDrag` so a choice picked from the menu and a proposal taken by a
  ##   plain release reach the scene through the identical path.
  ##   Refuses rather than adding an object that draws nothing: a pair whose result has no
  ##   shape produces a message and no item. That is the one outcome a caller has to be
  ##   ready for, and it is why `index_created` is an `Option`. The menu greys the wedges
  ##   this would refuse, so the menu path reaches that refusal only by insisting.
  let over = destinationOf(interaction)
  if over.isNone:
    return DragOutcome(message: "Released over empty space; nothing done.")
  if over.get == interaction.index_source:
    return DragOutcome(message: "Released on its own source; nothing done.")
  if not (scene.isAlive(interaction.index_source) and scene.isAlive(over.get)):
    return DragOutcome(message: "Source or destination no longer exists; nothing done.")

  let
    label_source = toText(scene.labelAt(interaction.index_source))
    label_destination = toText(scene.labelAt(over.get))
    m = scene.geometryAt(interaction.index_source)
    n = scene.geometryAt(over.get)
    operands = some((source: interaction.index_source, destination: over.get))
  if choice == DragChoice.More:
    return DragOutcome(
      message: &"{label_source} and {label_destination} ready to apply.",
      choice: some(choice), operands: operands,
    )

  let
    notation = toDrag(choice).get.notation
    derived = resultOf(choice, m, n)
  if derived.isNone:
    return DragOutcome(
      message:
        &"{label_source} {notation} {label_destination} makes nothing drawable; " &
        "nothing added.",
      choice: some(choice), operands: operands,
    )

  let
    operation = toDrag(choice).get.toOperation
    anchor = creationAnchor(operation, m, n, derived.get)
    index_created = scene.addItem(
      derived.get, &"{label_source} {notation} {label_destination}",
      inkCycled(scene.len), now, anchor,
    )
  DragOutcome(
    message:
      &"{label_source} {notation} {label_destination} gave {shapeText(derived.get)}.",
    index_created: some(index_created), choice: some(choice), operands: operands,
  )


proc endDrag*(
  interaction: var Interaction; scene: var Scene; now: float = 0.0
): DragOutcome =
  ## End the drag in progress, applying whatever the release resolved to.
  ##   **One release rule: a release commits whatever is under the cursor.** With a menu
  ##   open that is the wedge the cursor stands in, and nothing where it went back to the
  ##   centre. With no menu it is `proposalFor`'s own answer, which is exactly what the
  ##   preview has been ghosting all along -- one rule, drawn and then obeyed, rather than
  ##   a preview computed one way and a commit another.
  ##   Resolving the wedge here rather than in each render path is deliberate: the cursor
  ##   and the menu's centre are both already known, so neither path gets a chance to
  ##   disagree about which wedge a release landed in.
  ##   Always clears drag state; the message names the outcome even where nothing was done.
  defer: interaction.cancelDrag()
  if not interaction.is_dragging: return DragOutcome()

  # A press that never moved is a click, not a drag, and a click selects what it came down
  #   on. Answered here rather than in each render path because the drag it abandons was
  #   begun here: the press target chooses the scheme, so the press over an object has to
  #   start a drag eagerly, and *whether it was one* is only knowable at the release.
  #   The button that forces the menu is excluded: it asked for the menu, and offering it
  #   and then quietly selecting instead would make the right button unreliable.
  if not interaction.is_menu_forced and interaction.isClick(now):
    return
      if scene.isAlive(interaction.index_source):
        DragOutcome(index_clicked: some(interaction.index_source))
      else:
        DragOutcome() # Removed under the press; nothing to select and nothing to say.

  if interaction.menu.isSome:
    let choice = choiceAt(interaction.menu.get, interaction.cursor)
    if choice.isNone: return DragOutcome(message: "Released without choosing; nothing done.")
    return commitChoice(interaction, scene, choice.get, now)

  let over = destinationOf(interaction)
  if over.isNone: return DragOutcome(message: "Released over empty space; nothing done.")
  if over.get == interaction.index_source:
    return DragOutcome(message: "Released on its own source; nothing done.")
  if not (scene.isAlive(interaction.index_source) and scene.isAlive(over.get)):
    return DragOutcome(message: "Source or destination no longer exists; nothing done.")

  let proposal = proposalFor(
    scene.geometryOf(interaction.index_source), scene.geometryOf(over.get)
  )
  if proposal.isNone:
    let
      label_source = toText(scene.labelAt(interaction.index_source))
      label_destination = toText(scene.labelAt(over.get))
    return DragOutcome(
      message: &"{label_source} and {label_destination} make nothing drawable; " &
        "nothing added.",
      operands: some((source: interaction.index_source, destination: over.get)),
    )
  commitChoice(interaction, scene, proposal.get, now)
