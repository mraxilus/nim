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
## What is ghosted is always **what letting go right now would commit**: the wedge the cursor
## stands in once the right button's wheel is open, and `proposalFor`'s own answer where it
## is not. `Interaction.proposal` holds that one answer, `endDrag` obeys it, and
## `ReleaseEffect` names the three things it can amount to — nothing, a refusal, an object —
## which is what the rubber-band is tinted from.
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

import std/[math, options, strformat]

import ../../pga
import ./[camera, format, mesh, objects, picking, scene]



#[ Gesture Configuration ]#

# Every `now` this module takes is **seconds**, on whatever monotonic clock the caller
#   owns, and it is the same clock `scene.addItem` records a birth on -- one reading
#   threaded through a whole release rather than two that could disagree. Named in the
#   constants below rather than left to a comment: the browser's own clock reads in
#   milliseconds, and while the durations here were named for those, the desktop passed
#   seconds against them and its dwell menu quietly needed 450 seconds to open.

const SECONDS_DWELL_MENU* = 0.75
  ## Hold a drag **still** over its target this long and the choice menu opens, on a
  ## pointer armed `MenuArming.OnDwell` -- which now means touch alone.
  ##   Still, not merely present: the clock restarts whenever the cursor moves further than
  ##   `PIXELS_TAP_SLOP` from where it last settled, so time spent crossing a target does
  ##   not count toward opening a menu over it. This was measured, not supposed -- while
  ##   the clock ran on presence alone, a slow finger crossing the ground plane tripped it
  ##   mid-drag and the construction it was in the middle of ended up building nothing.
  ##   Longer than a threshold triggered on its own would dare be, and deliberately so:
  ##   it only has to be slow enough never to fire on a hesitation. The usual failure of
  ##   a dwell menu is popping up at someone who was still moving.
  ##   **Was 0.45, while a mouse could trip it too.** That number was a compromise: short
  ##   enough not to feel like a wait for a reader who had no other way to reach the menu.
  ##   A mouse now decides by which button went down and never waits at all, so the only
  ##   requirement left is that a finger which paused mid-drag is not answered with a menu
  ##   -- and a finger pauses far more readily than a mouse does. It also sat *under*
  ##   `SECONDS_LONG_PRESS` (0.50), so the two thresholds a stationary finger races were in
  ##   the wrong order; it now stands clear of it.

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

# **There is deliberately no time bound on a click.** One stood here at 0.35 s, to separate
#   a click from a press held to open the dwell menu; the dwell became touch-only and the
#   bound became a way to lose clicks. See `isClick` for what it cost and how that was
#   measured.

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

const PIXELS_MENU_CORNER_FURTHEST* = 103.9
  ## Furthest any wedge's own outer corner sits from the menu centre, **measured**.
  ##   Not derivable here: a wedge is as wide as the label it carries, and only a render path
  ##   knows what its own face laid that out as. Read off the drawn rects in the browser
  ##   build over six different pairs, which all gave the same number -- the four labels are
  ##   fixed, so the widest is too.
  ##   Kept beside the constant it justifies so the next reader can check the slack rather
  ##   than trust it, and so a wider label or a longer reach surfaces here as a number that
  ##   no longer clears `PIXELS_MENU_DISENGAGE` rather than as a menu closing on a wedge.

const PIXELS_MENU_DISENGAGE* = 150.0
  ## Past this distance from its centre, an open menu lets go of the drag entirely.
  ##   What makes a wheel opened on the wrong object recoverable: it closes, the drag stops
  ##   being latched to that destination, and travelling on to another object opens it there
  ##   for the new pair. The source is never touched, so the pair re-aims rather than chains.
  ##   **This bounds `choiceAt`'s overshoot, which was unbounded on purpose** -- "overshooting
  ##   a wedge still picks it, which is what makes a fast confident throw work". Both cannot
  ##   hold at once, and being able to re-aim was chosen over an unbounded throw.
  ##   Sited off `PIXELS_MENU_CORNER_FURTHEST` rather than off the reach, leaving **46 px** of
  ##   clear air past the furthest point a throw could be aiming at: far enough that no
  ##   ordinary overshoot lets go, near enough that re-aiming is one short movement.

const
  HEIGHT_MENU_WEDGE* = 30.0
    ## Height of one wedge. Past WCAG 2.5.8's 24-pixel target on its short axis, which is
    ## the axis that binds; the long one comes from the label the wedge holds, measured by
    ## whichever render path is drawing it rather than guessed at from a character count.
  PADDING_MENU_WEDGE* = 22.0
    ## Slack around a wedge's label, so a short name still reads as a button rather than
    ## as text lying loose on the scene.
  ROUNDING_MENU_WEDGE* = 8.0
    ## Corner radius of a wedge. The selection menu's own button radius: **this menu and
    ## that one are the same control in two postures**, one reached by dragging and one by
    ## picking, so a reader should not have to learn two appearances for it. Was 6 while
    ## the wedges were solid slabs of their own hue.
  WIDTH_MENU_WEDGE_BORDER* = 1.0
    ## Thickness of the hairline round a wedge, matching the selection menu's own buttons.
  RADIUS_MENU_CENTRE* = 5.0
    ## Dot marking the menu's own centre, where nothing is chosen. Drawn well inside
    ## `PIXELS_MENU_DEADZONE` so it reads as a mark rather than as the boundary itself.
  ALPHA_MENU_WEDGE* = 0.96
    ## Opacity of a wedge that can be chosen. Near-solid, since the surface behind it is
    ## now the popover tone rather than the choice's own hue and needs to read as a chip
    ## standing on the scene rather than as a tint over it.
  ALPHA_MENU_UNOFFERED* = 0.45
    ## Opacity of one that makes nothing, which is drawn rather than dropped: a gap where
    ## a wedge should be is unreadable, and the point of a fixed compass is that a choice
    ## never moves. Higher than the 0.30 the coloured slabs wore: a dark chip at 0.30 all
    ## but disappears against a dark scene, and an unreachable choice still has to be
    ## legible enough to say what it would have been.



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

  MenuArming* {.pure.} = enum ## Say how a drag in progress may come to open its menu.
    ## What a pointer chose at the press, held for that drag's whole life. Three states
    ## rather than a "forced" flag, because the flag could only say *now* or *after a
    ## wait* -- and a mouse wants neither: its left button should take the pair's own
    ## answer and never be interrupted by a menu, while its right button asks. Only a
    ## finger, which has no second button to ask with, still waits.
    Never, ## Take the proposal on release; no menu, however long the drag stands still.
    OnDwell, ## Open after `SECONDS_DWELL_MENU` of standing still over the target.
    Always ## Open the moment the drag arrives over a target.

  Compass* {.pure.} = enum ## Name where a choice sits in the menu, always.
    ## A fixed position per choice, with unoffered ones left as gaps rather than packed
    ## out. Packing would move a choice from pair to pair, and a menu whose items move is
    ## one nobody ever learns to reach without reading it.
    North, East, South, West

  Key* {.pure.} = enum ## Name a key the 3D view itself reacts to, in neither backend's naming.
    ## Both render paths name the **physical** key: SDL by scancode, the DOM by
    ## `KeyboardEvent.code`. Each translates its own into this and asks `motionFor` or
    ## `actionFor` below, exactly as each translates its own mouse-button numbering into
    ## `PointerButton`. Physical on both sides so that W is the same key under the hand on
    ## every layout -- the browser used to read `KeyboardEvent.key`, which on AZERTY names
    ## the key the desktop calls Z.
    ##   Only keys the *view* reacts to are here -- the accelerators that reach the timeline
    ## and the panels stay where they already are, since those are reached from anywhere
    ## rather than from the canvas.
    ##   `Shift` is a key here rather than a flag threaded through every call, because it
    ## is held exactly as the movement keys are: one mechanism then carries both which way
    ## the camera goes and how fast, and letting go of shift mid-movement is just another
    ## key release.
    W, A, S, D, Q, E, F,
    Left, Right, Up, Down, BracketLeft, BracketRight, Minus, Plus, Enter, Home, Shift

  Motion* {.pure.} = enum ## Name a way the view keeps moving while a key is held.
    ## Separate from `KeyAction` because the two are answered at different times: a motion
    ## is applied every frame its key is down, by `driveHeld`, and an action happens once,
    ## at the press. A single enum would have left every caller asking which kind it had.
    Forward, Back, Left, Right, Down, Up,
    OrbitLeft, OrbitRight, OrbitUp, OrbitDown,
    DollyIn, DollyOut

  KeyAction* {.pure.} = enum ## Name what one press of a key does to the view.
    FocusPrevious, FocusNext,
    SelectFocused, ## Alone, or added to the selection where shift is held.
    FrameSelection, ## Bring whatever is selected into view, through the framing rule.
    ViewHome ## Return the camera to the placement both builds open at.

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
    proposal*: Option[DragChoice] ## What a release **right now** would commit.
      ## The wedge the cursor stands in while a menu is open, and `proposalFor`'s own answer
      ## where none is -- resolved in the very order `endDrag` resolves it, so what is
      ## previewed and what is committed cannot come apart. None where a release would
      ## commit nothing at all: over no target, or back at an open menu's own centre.
    preview*: Option[Preview] ## What that proposal would make, for each render path to
      ## ghost -- `scene.Preview`, the same construction both apply pickers offer, rather
      ## than a second one written out here.
      ## None where the drag is over nothing, over its own source, over a pair that
      ## makes nothing -- and *that* is the case worth drawing nothing for, since it is the
      ## only warning before a refused release -- and over `More`, which builds nothing
      ## itself and hands the pair to the apply picker instead.
    arming*: MenuArming ## How this drag may come to open its menu, as its own pointer
      ## chose at the press. Set at `beginDrag` and read every frame after.
    entered*: float ## When the cursor last settled over a target, for the dwell to run
      ## from. Restarted both when the hovered item changes and when the cursor moves
      ## away from `settled`, so the dwell measures being still rather than being present.
    settled*: ScreenPosition ## Where the cursor was when `entered` was last restarted;
      ## what movement is measured against to decide the dwell has been interrupted.
    menu*: Option[ScreenPosition] ## Where the choice menu is open, if it is.
    is_dragging_camera*: bool ## Whether a pointer gesture is moving the *camera* right now
      ## -- an orbit or a pan drag, or two fingers on the canvas. Each render path owns its
      ## own drag state and says so here; what it means for hover is `updateHover`'s to say.
      ## Distinct from `is_dragging`, which is a *construction* drag and must keep hovering:
      ## the whole point of that gesture is what it is pointing at.
    keys_held*: set[Key] ## Physical keys down right now, which `driveHeld` moves the camera
      ## by once a frame. A set rather than a per-key flag, so two keys held together
      ## compose without anything having to enumerate the pairs.
      ##   Emptied by `releaseKeysAll` whenever the view stops receiving key releases --
      ## the window losing focus, the reader tabbing into a panel. Not a nicety: the
      ## release for a key held at that moment is delivered to somebody else, and a key
      ## left in here moves the camera forever.
    index_disengaged*: Option[int] ## Target a menu was let go of, while the cursor is still
      ## over it. Without this the wheel would re-open on that same object the very next
      ## frame -- `MenuArming.Always` is due on every frame over a target -- and disengaging
      ## would do nothing but move the menu. Cleared the moment hover reports anything else,
      ## including nothing, so coming back to that object later opens it again.



#[ Operation Vocabulary ]#

type PointerButton* {.pure.} = enum ## Name a physical mouse button, however numbered.
  ## Neither backend's own numbering: SDL and the DOM count the three buttons
  ## differently (SDL 1/2/3 left/middle/right, the DOM 0/1/2 left/middle/right), so each
  ## render path translates its own numbers into this and asks `armingOf` below.
  ## That keeps *which button does what* stated once, while leaving each path the
  ## translation only it can do.
  Left, Middle, Right


func motionFor*(key: Key): Option[Motion] =
  ## Say which way one key keeps moving the view while it is held, or none where it moves
  ## nothing.
  ##   **Half the binding table**, stated once; `actionFor` below is the other half and
  ##   `help.nim` renders its keyboard rows out of both rather than transcribing them, so
  ##   rebinding a key rewrites the help with it -- the same arrangement that has kept the
  ##   drag rows honest across two rebindings.
  ##   **WASD slides the view across the ground and the arrows orbit it**, which is the
  ##   pairing a reader arrives with: every editor that binds WASD at all (Unity, Unreal,
  ##   Godot, Blender's fly mode) means "move" by it, and every map does. Q and E lower and
  ##   raise, which those same four editors agree on. Shift is not here because it changes
  ##   no key's direction -- it multiplies every rate by `FACTOR_HASTE`; see `driveHeld`.
  ##   It used to turn an arrow's orbit into a pan, so shift meant one thing on the arrows
  ##   and nothing anywhere else.
  ##   Total by construction: every key answers, so no caller has an unhandled case and the
  ##   suite can walk the whole table.
  case key
  of Key.W: some(Motion.Forward)
  of Key.S: some(Motion.Back)
  of Key.A: some(Motion.Left)
  of Key.D: some(Motion.Right)
  of Key.Q: some(Motion.Down)
  of Key.E: some(Motion.Up)
  of Key.Left: some(Motion.OrbitLeft)
  of Key.Right: some(Motion.OrbitRight)
  of Key.Up: some(Motion.OrbitUp)
  of Key.Down: some(Motion.OrbitDown)
  of Key.Minus: some(Motion.DollyOut)
  of Key.Plus: some(Motion.DollyIn)
  of Key.F, Key.BracketLeft, Key.BracketRight, Key.Enter, Key.Home, Key.Shift:
    none(Motion)


func actionFor*(key: Key): Option[KeyAction] =
  ## Say what one press of a key does to the view, or none where it does nothing at a press
  ## -- which is every key that moves the view instead; see `motionFor`.
  ##   **Tab is deliberately absent**: cycling objects with it while the view has focus is
  ##   the tempting binding, and it risks a keyboard trap -- WCAG 2.1.2, also Level A -- so
  ##   traversal took the brackets instead and Tab keeps meaning "next control" everywhere.
  ##   Fixing 2.1.1 by breaking 2.1.2 is not a fix.
  ##   **F frames the selection**, which Unity, Godot and Blender (on numpad `.`) all bind;
  ##   Home stays what it was, the placement both builds open at, and the two are different
  ##   enough to deserve different keys.
  case key
  of Key.BracketLeft: some(KeyAction.FocusPrevious)
  of Key.BracketRight: some(KeyAction.FocusNext)
  of Key.Enter: some(KeyAction.SelectFocused)
  of Key.F: some(KeyAction.FrameSelection)
  of Key.Home: some(KeyAction.ViewHome)
  of Key.W, Key.A, Key.S, Key.D, Key.Q, Key.E, Key.Left, Key.Right, Key.Up, Key.Down,
      Key.Minus, Key.Plus, Key.Shift:
    none(KeyAction)


func nameOf*(key: Key): string =
  ## Name a key as a reader would say it, for the help table to print.
  case key
  of Key.W: "w"
  of Key.A: "a"
  of Key.S: "s"
  of Key.D: "d"
  of Key.Q: "q"
  of Key.E: "e"
  of Key.F: "f"
  of Key.Shift: "shift"
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


func armingOf*(button: PointerButton): Option[MenuArming] =
  ## Say whether a button starts a construction drag, and how that drag reaches its menu.
  ##   None for a button that starts no drag at all. Middle is now such a button: `project`
  ##   used to live there, which put a third of the vocabulary behind hardware most
  ##   trackpads do not have. It lives in the menu instead, so nothing is unreachable.
  ##   **A mouse never waits.** Left takes whatever the pair makes and is never interrupted
  ##   by a menu opening under a hand that paused mid-gesture; right asks, from the moment
  ##   it arrives. The two run the same operations and differ only in whether the reader is
  ##   asked -- redundancy for different expertise, not a mode split, which is exactly why
  ##   it is safe where a button-per-operation mapping was not. `MenuArming.OnDwell` is
  ##   reachable from no button at all, and belongs to touch alone; see `MenuArming`.
  case button
  of PointerButton.Left: some(MenuArming.Never)
  of PointerButton.Right: some(MenuArming.Always)
  of PointerButton.Middle: none(MenuArming)


func revealsMenuOn*(button: PointerButton): bool =
  ## Say whether a click of this button brings up the selection menu on what it picked.
  ##   **The left button selects and nothing more.** It used to do both jobs at once --
  ##   select *and* open the menu -- which left a reader who only wanted to pick something
  ##   dismissing a menu they never asked for, and put the menu behind the same button that
  ##   builds. The right button carries it instead, matching where every other tool a reader
  ##   has met keeps a context menu.
  ##   Stated here for the same reason `armingOf` is: both render paths and the help panel
  ##   answer from one rule, so rebinding it rewrites the help with it.
  button == PointerButton.Right


func revealsWithoutPicking*(has_selection, is_menu_shown: bool): bool =
  ## Say whether a menu-revealing click should only reveal, leaving the selection alone.
  ##   A selection already standing with its menu dismissed is a reader who wants that menu
  ##   back, not one who wants to throw the selection away and start again -- so the click
  ##   reveals and picks nothing. With the menu already up there is nothing to reveal, so the
  ##   same click means what it plainly says and picks what it landed on. That pair is also
  ##   the way out: right-click once to get the menu, again to retarget it.
  ##   **Shift never comes here.** Shift means "change the selection", so a shifted click
  ##   always adds or drops and only then reveals; the caller applies that, since only it
  ##   knows the modifier.
  has_selection and not is_menu_shown


func toDrag*(choice: DragChoice): Option[DragOperation] =
  ## Read a choice as the operation it applies, if it applies one.
  case choice
  of DragChoice.Join: some(DragOperation.Join)
  of DragChoice.Meet: some(DragOperation.Meet)
  of DragChoice.Project: some(DragOperation.Project)
  of DragChoice.More: none(DragOperation)


func toOperation*(drag: DragOperation): Operation =
  ## Translate drag's own vocabulary to library's operation catalogue.
  case drag
  of DragOperation.Join: Operation.Wedge
  of DragOperation.Meet: Operation.WedgeAnti
  of DragOperation.Project: Operation.ProjectOrthogonal


func compassOf*(choice: DragChoice): Compass =
  ## Place a choice in the menu. Fixed for the life of the program; see `Compass`.
  ##   North is the default a plain release takes most often, so the commonest choice is
  ##   also the one nearest the cursor's own resting direction.
  case choice
  of DragChoice.Join: Compass.North
  of DragChoice.Meet: Compass.East
  of DragChoice.Project: Compass.South
  of DragChoice.More: Compass.West


proc labelOf*(choice: DragChoice): string =
  ## Name a choice as its wedge says it, in the catalogue's own symbols.
  ##   **The very text the apply picker offers**, through `scene.notationSymbolic`, because
  ##   the wheel and that picker are the same control in two postures and a reader should
  ##   not have to learn `join` on one and `𝐦 ∧ 𝐧` on the other. Whichever they meet first
  ##   teaches the other. The words are still taught, once, in the drawer's own intro line,
  ##   which now names each symbol beside its word.
  ##   The projection's notation (`𝐧 ∨ (𝐦 ∧ 𝐧☆)`) is the wide one, near twice the width of
  ##   the word it replaces -- affordable only because it sits at `Compass.South`, clear of
  ##   the two wedges the width could have collided with. Moving a choice to a different
  ##   compass point is therefore a decision about this label too; see `Compass`.
  ##   `More` takes a bare ellipsis rather than "more…": beside three pieces of notation a
  ##   word is the odd one out, and the ellipsis is the one mark that already means
  ##   "and the rest" without being an operation.
  ##   A `proc` rather than a `func` for the reason `scene.notationSymbolic` is one: the
  ##   table it reads is a `let`, since a picker needs the address of its first entry.
  case choice
  of DragChoice.Join, DragChoice.Meet, DragChoice.Project:
    notationSymbolic(toOperation(toDrag(choice).get))
  of DragChoice.More: "…"


func wordOf*(choice: DragChoice): string =
  ## Name a choice in words, for the one place each is *taught* rather than offered.
  ##   The wedge itself says `𝐦 ∧ 𝐧` -- see `labelOf` -- which is only readable by someone
  ##   who has been told once that it is `join`. That telling is the drawer's own legend
  ##   line and nowhere else, so this exists to keep the legend and the help table naming
  ##   the three the same way.
  case choice
  of DragChoice.Join: "join"
  of DragChoice.Meet: "meet"
  of DragChoice.Project: "project"
  of DragChoice.More: "more"


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


func choosing*(interaction: Interaction): Option[DragChoice] =
  ## Say which wedge of the open menu the cursor stands in, or none where no menu is open
  ## at all and none where the cursor has come back to an open one's centre.
  ##   **The one statement of which wedge**, so the highlight each front-end draws, the
  ##   ghost `updateDrag` shapes and the object `endDrag` commits are never three opinions
  ##   about where the cursor is. Each of those asked `choiceAt` separately before.
  if interaction.menu.isNone: return none(DragChoice)
  choiceAt(interaction.menu.get, interaction.cursor)


type ReleaseEffect* {.pure.} = enum ## Name what letting go right now would do.
  ## Three outcomes and not two, because a release that quietly does nothing and one that
  ## refuses want opposite feedback -- and once a menu is open both are reachable over the
  ## very same pair, depending only on where in the wheel the cursor is resting.
  Nothing, ## End the gesture and build nothing, with nothing to warn about: over empty
    ## space, over the drag's own source, or back at an open menu's own centre.
  Refused, ## Reach a pair that makes nothing drawable, and say so.
  Builds, ## Add an object -- or, for `More`, hand the pair to the apply picker, which
    ## takes the very hue the wheel has been showing.


func effectOf*(interaction: Interaction): ReleaseEffect =
  ## Resolve what letting go right now would do, from the drag's own state.
  ##   Reads `proposal` and `preview`, which `updateDrag` has already resolved in `endDrag`'s
  ##   own order, rather than re-deriving either: this is the one place the three outcomes
  ##   are told apart, and a second derivation is a second answer waiting to disagree.
  if not interaction.is_over_target: return ReleaseEffect.Nothing
  if interaction.proposal.isNone:
    # Two ways to have no answer, and they are not the same event. With a menu open the
    #   cursor is simply back at its centre and the gesture is being called off; with none
    #   open `proposalFor` found nothing this pair makes, which is a refusal to warn about.
    return
      if interaction.menu.isSome: ReleaseEffect.Nothing else: ReleaseEffect.Refused
  if interaction.proposal.get == DragChoice.More: return ReleaseEffect.Builds
  if interaction.preview.isSome: ReleaseEffect.Builds else: ReleaseEffect.Refused


func inkOfDrag*(interaction: Interaction; ink_next: Ink): Ink =
  ## Tint the rubber-band of the drag in progress by what releasing it would do.
  ##   Three states, one per `ReleaseEffect`, and the middle one is the reason this is not
  ##   just `ink_next`: a release that builds nothing and warns about nothing is neutral, one
  ##   that would be refused wears the reserved `Ink.Invalid` magenta, and one that builds
  ##   wears **the hue the new object will actually be**. The warning arrives *before* the
  ##   release rather than as a message after it, which is the whole point of previewing at
  ##   all -- and it is never colour alone, since the ghost simultaneously fails to appear.
  ##   With the wheel open all three are reachable without leaving the target: the centre is
  ##   neutral, a greyed wedge is magenta, an offered one is the new object's hue.
  ##   `ink_next` is `scene.inkNext`, passed in because this has no scene to ask. It used to
  ##   be the *operation's* own colour, which told a reader which of join/meet/project they
  ##   were about to get but nothing about the object they were about to have -- and the
  ##   operation is already named on the wedge and in the label, while the colour is the only
  ##   place the answer could have been shown.
  case interaction.effectOf
  of ReleaseEffect.Nothing: Ink.Guide
  of ReleaseEffect.Refused: Ink.Invalid
  of ReleaseEffect.Builds: ink_next





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


func isMovingCamera*(interaction: Interaction): bool =
  ## Report whether the camera is being moved right now, by pointer or by key.
  ##   The key half is answered here rather than by each front-end, since `keys_held` is
  ##   already this module's; `Key.Shift` alone is not movement, which is why this asks
  ##   `motionFor` rather than counting keys.
  if interaction.is_dragging_camera: return true
  for key in interaction.keys_held:
    if motionFor(key).isSome: return true
  false


proc updateHover*(
  interaction: var Interaction; scene: Scene;
  camera: Camera; view_projection: Matrix4; width, height: int
) =
  ## Recompute item nearest cursor, so overlay and drag-start agree on what stands under it.
  ##   **Nothing is hovered while the camera is moving.** Hover is recomputed from the cursor
  ##   every frame, so a pan drags the highlight across every object it sweeps past and a
  ##   held W lights up whatever slides under a cursor standing still -- a rash of rings for
  ##   a gesture that is not pointing at anything. A camera move is not a hover, and the ring
  ##   comes back the frame it ends.
  interaction.index_hover =
    if interaction.is_enabled and not interaction.isMovingCamera:
      pickNearest(scene, camera, view_projection, width, height, interaction.cursor)
    else:
      none(int)
  # Noted here because this is where the scene is in hand; see `is_hover_backdrop`.
  interaction.is_hover_backdrop =
    interaction.index_hover.isSome and
    scene.geometryOf(interaction.index_hover.get).isHorizonPlane



#[ Keyboard ]#

proc dollyAtCursor*(
  interaction: Interaction; camera: var Camera; factor: float; width, height: int
) =
  ## Zoom the camera by `factor`, toward whatever the cursor is over.
  ##   The one statement of what a wheel notch does, so both front-ends and a pinch all
  ## zoom the same way; each of them only has to say where the cursor is.
  ##   Falls back to a plain `dolly` where the cursor is over nothing to aim at -- the sky,
  ## or a sight line running along the level the target sits on. Zooming toward the middle
  ## of the frame is what a wheel did before this and is still the sensible answer there.
  let anchor = positionUnderCursor(camera, width, height, interaction.cursor)
  if anchor.isNone: camera.dolly(factor)
  else: camera.dollyToward(factor, anchor.get)


proc holdKey*(interaction: var Interaction; key: Key) =
  ## Note a key as held, so `driveHeld` moves the camera by it every frame until it is
  ## released. Harmless on a key already held, which is what an auto-repeat sends.
  interaction.keys_held.incl(key)


proc releaseKey*(interaction: var Interaction; key: Key) =
  ## Note a key as let go of. Harmless on a key not held, which is what a release arriving
  ## after `releaseKeysAll` is.
  interaction.keys_held.excl(key)


proc releaseKeysAll*(interaction: var Interaction) =
  ## Let go of every held key at once, for a view that has stopped being told about
  ## releases: the window losing focus, or the reader tabbing into a panel.
  ##   **Not a nicety.** The release of a key held at that moment is delivered somewhere
  ## else, so without this the camera moves forever and no key press stops it.
  interaction.keys_held = {}


proc driveHeld*(interaction: Interaction; camera: var Camera; seconds: float) =
  ## Move the camera by every key currently held, for one frame of `seconds`.
  ##   Called once a frame by both render paths rather than at each key event, which is
  ## what makes a hold read as continuous movement instead of as the operating system's own
  ## auto-repeat: a delay, then stutters. It also makes two keys held together compose --
  ## W and D slide diagonally -- with nothing here enumerating the pairs.
  ##   Every rate is per second (`TURN_SECOND` and its neighbours) and multiplied by
  ## `seconds` here, so how far a hold travels depends on how long it was held rather than
  ## on how fast the machine draws. The dolly is the one that cannot be a multiplication:
  ## it compounds, so it takes `FACTOR_DOLLY_SECOND` to the power of the elapsed seconds.
  ##   Shift multiplies every rate by `FACTOR_HASTE` rather than changing any direction.
  if interaction.keys_held.len == 0: return
  let
    haste = if Key.Shift in interaction.keys_held: FACTOR_HASTE else: 1.0
    turn = TURN_SECOND*haste*seconds
    rise = RISE_SECOND*haste*seconds
    slide = SLIDE_SECOND*haste*seconds
    dolly = pow(FACTOR_DOLLY_SECOND, haste*seconds)
  for key in interaction.keys_held:
    let motion = motionFor(key)
    if motion.isNone: continue
    case motion.get
    of Motion.Forward: camera.slideGround(slide, 0.0, 0.0)
    of Motion.Back: camera.slideGround(-slide, 0.0, 0.0)
    of Motion.Left: camera.slideGround(0.0, -slide, 0.0)
    of Motion.Right: camera.slideGround(0.0, slide, 0.0)
    of Motion.Down: camera.slideGround(0.0, 0.0, -slide)
    of Motion.Up: camera.slideGround(0.0, 0.0, slide)
    of Motion.OrbitLeft: camera.orbit(-turn, 0.0)
    of Motion.OrbitRight: camera.orbit(turn, 0.0)
    of Motion.OrbitUp: camera.orbit(0.0, rise)
    of Motion.OrbitDown: camera.orbit(0.0, -rise)
    of Motion.DollyIn: camera.dolly(1.0/dolly)
    of Motion.DollyOut: camera.dolly(dolly)


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
  ##   **`FrameSelection` does nothing here**, deliberately: framing reads the selection,
  ##   which this module does not own, and both paths already offer the camera an aim over
  ##   that selection once a frame (`framing.offerAim`). All the key has to do is clear the
  ##   goal that offer is holding, so the next frame aims afresh -- `CameraTween.release`,
  ##   which each path calls on its own tween. Doing it any other way would mean a second
  ##   statement of what "in view" means.
  case action
  of KeyAction.FocusPrevious: interaction.index_focus = scene.slotStepped(
    interaction.index_focus, -1
  )
  of KeyAction.FocusNext: interaction.index_focus = scene.slotStepped(
    interaction.index_focus, 1
  )
  of KeyAction.SelectFocused:
    if interaction.index_focus.isSome and scene.isAlive(interaction.index_focus.get):
      return interaction.index_focus
  of KeyAction.FrameSelection: discard
  of KeyAction.ViewHome:
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
  ##   **Distance alone decides**: a press that has not left `PIXELS_CLICK_SLOP` of where it
  ##   landed is a click however long it was held. Asked at the release, by whichever path is
  ##   resolving the press -- `endDrag` for one that started over an object, the render path
  ##   itself for one that started over empty space, which begins no drag to end.
  ##   **There was a 0.35 s deadline here and it was a bug.** It was meant to separate a
  ##   click from a press held to open the dwell menu, but the dwell belongs to touch alone
  ##   (`MenuArming.OnDwell`, reachable from no button) and a mouse's wheel opens on arriving
  ##   over *another* object, never on time -- so nothing was left for it to separate, and
  ##   what it actually did was drop any click a hand lingered on. Measured on the shipped
  ##   build: shift-clicking three objects with each press held 600 ms picked **none** of
  ##   them, every release answering "Released on its own source; nothing done", while the
  ##   same three at 80 ms picked all three and a fourth click dropped one back out. `now` is
  ##   still taken, since a caller should not have to know that the answer stopped needing it.
  discard now
  interaction.is_press_still


proc beginDrag*(interaction: var Interaction; arming: MenuArming; now: float): bool =
  ## Start a construction drag from the item currently hovered.
  ##   Reports whether one actually started, so a caller knows whether to fall back to
  ##   camera orbit or pan instead.
  ##   `arming` is what the pointer chose: see `MenuArming`, and `armingOf` for what each
  ##   mouse button picks. Every arming reaches the same choices; they differ only in what
  ##   the reader has to do to be asked.
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
  interaction.arming = arming
  interaction.entered = now
  interaction.settled = interaction.cursor
  interaction.menu = none(ScreenPosition)
  interaction.index_disengaged = none(int) # A fresh drag holds nothing at arm's length.
  interaction.is_over_target = false
  interaction.proposal = none(DragChoice)
  interaction.preview = none(Preview)
  true


proc cancelDrag*(interaction: var Interaction) =
  ## Abandon drag in progress without applying anything.
  interaction.is_dragging = false
  interaction.menu = none(ScreenPosition)
  interaction.index_disengaged = none(int) # Or the next drag opens no menu over that object.
  interaction.is_over_target = false
  interaction.proposal = none(DragChoice)
  interaction.preview = none(Preview)


proc updateDrag*(
  interaction: var Interaction; scene: Scene; now: float
) =
  ## Recompute, for the frame just about to draw, what the drag in progress would make and
  ## whether its menu should be open.
  ##   Called after `updateHover`, which is what decides where the drag currently points.
  ##   The preview is whatever a release would commit, applied -- the wedge the cursor
  ##   stands in while a menu is open, and `proposalFor`'s own answer where none is. One
  ##   rule, drawn and then obeyed, rather than a preview computed one way and a commit
  ##   another; ghosting the plain-release answer under an open wheel was exactly that
  ##   split, and a reader aiming at `meet` watched a ghost of `join`.
  if not interaction.is_dragging:
    interaction.is_over_target = false
    interaction.proposal = none(DragChoice)
    interaction.preview = none(Preview)
    interaction.menu = none(ScreenPosition)
    return

  # Let go of a menu the cursor has left, so a wheel opened on the wrong object costs a
  #   movement rather than the whole gesture. Everything after this reads `menu` again, so
  #   clearing it here is the whole of the re-aiming: the latch below starts following hover,
  #   `index_source` is never touched, and the pair becomes the original source with whatever
  #   the drag travels to next. See `PIXELS_MENU_DISENGAGE` on what this costs a throw.
  if interaction.menu.isSome:
    let
      dx_menu = interaction.cursor.x - interaction.menu.get.x
      dy_menu = interaction.cursor.y - interaction.menu.get.y
    if dx_menu*dx_menu + dy_menu*dy_menu >
        PIXELS_MENU_DISENGAGE*PIXELS_MENU_DISENGAGE:
      interaction.menu = none(ScreenPosition)
      interaction.index_disengaged = interaction.index_destination
      interaction.entered = now
      interaction.settled = interaction.cursor

  # Latch what the drag points at while no menu is open, so the one that opens is the one
  #   whose destination the wedges will act on.
  if interaction.menu.isNone: interaction.index_destination = interaction.index_hover

  # ...and stop holding a target at arm's length once the drag has actually left it.
  if interaction.index_disengaged.isSome and
      interaction.index_hover != interaction.index_disengaged:
    interaction.index_disengaged = none(int)

  let over = destinationOf(interaction)
  interaction.is_over_target =
    over.isSome and over.get != interaction.index_source and
    scene.isAlive(over.get) and scene.isAlive(interaction.index_source)
  if not interaction.is_over_target:
    # Left the target: the dwell starts again from wherever it next arrives, so pausing
    #   on the way across never counts toward opening a menu somewhere else.
    interaction.proposal = none(DragChoice)
    interaction.preview = none(Preview)
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

  # Open the menu **before** resolving what a release would do, since with one open that
  #   answer is the wedge the cursor stands in. Resolved after instead, the frame a wheel
  #   opens on would ghost the plain-release answer while the wheel already stood over the
  #   cursor's own centre, which chooses nothing.
  let is_menu_due = case interaction.arming
    of MenuArming.Never: false
    of MenuArming.OnDwell: now - interaction.entered >= SECONDS_DWELL_MENU
    of MenuArming.Always: true
  if interaction.menu.isNone and is_menu_due and interaction.index_disengaged.isNone:
    interaction.menu = some(interaction.cursor)

  let
    m = scene.geometryOf(interaction.index_source)
    n = scene.geometryOf(over.get)
  # `endDrag`'s own order: the wheel answers where one is open, `proposalFor` where none is.
  interaction.proposal =
    if interaction.menu.isSome: interaction.choosing else: proposalFor(m, n)
  # Through `scene.previewApplying`, the same call both apply pickers offer their own answer
  #   from -- so the ghost this gesture draws and the ghost a picker draws are one thing,
  #   anchor included, rather than two constructions that happen to agree.
  #   `More` names no operation and so previews nothing, which is right: it builds nothing
  #   itself and hands the pair on.
  let drag = if interaction.proposal.isSome: toDrag(interaction.proposal.get)
    else: none(DragOperation)
  interaction.preview =
    if drag.isSome:
      scene.previewApplying(
        drag.get.toOperation, interaction.index_source, over.get
      )
    else: none(Preview)


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
  # Silent for the same reason `endDrag` is: a choice committed over nothing built nothing,
  #   and the reader can see that. Reachable here only through a menu whose target went away
  #   under it.
  if over.isNone: return DragOutcome()
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

  # Named through the catalogue's own notation, exactly as the panel's apply button names
  #   the same pair -- so a drag and a panel apply produce byte-identical labels, and the
  #   library's real symbols reach the object list rather than an ASCII stand-in for them.
  let
    operation = toDrag(choice).get.toOperation
    label = notationSubstituted(operation, label_source, label_destination)
    derived = resultOf(choice, m, n)
  if derived.isNone:
    return DragOutcome(
      message: &"{label} makes nothing drawable; nothing added.",
      choice: some(choice), operands: operands,
    )

  let
    anchor = creationAnchor(operation, m, n, derived.get)
    index_created =
      scene.addItem(derived.get, label, scene.takeInk(), now, anchor)
  DragOutcome(
    message: &"{label} gave {shapeText(derived.get)}.",
    index_created: some(index_created), choice: some(choice), operands: operands,
  )


proc endDrag*(
  interaction: var Interaction; scene: var Scene; now: float = 0.0
): DragOutcome =
  ## End the drag in progress, applying whatever the release resolved to.
  ##   **One release rule: a release commits whatever is under the cursor.** With a menu
  ##   open that is the wedge the cursor stands in, and nothing where it went back to the
  ##   centre. With no menu it is `proposalFor`'s own answer. Either way it is exactly what
  ##   `interaction.proposal` holds and what the preview has been ghosting all along -- one
  ##   rule, drawn and then obeyed, rather than a preview computed one way and a commit
  ##   another. `updateDrag` resolves it in this same order, off `choosing`.
  ##   Resolving the wedge here rather than in each render path is deliberate: the cursor
  ##   and the menu's centre are both already known, so neither path gets a chance to
  ##   disagree about which wedge a release landed in.
  ##   Always clears drag state; the message names the outcome even where nothing was done.
  let was_dragging = interaction.is_dragging
  defer:
    # **A construction gesture steps the palette whether or not it built anything.** The
    #   reader watched a colour on the band for the whole drag; offering that same colour
    #   again to the next attempt reads as the gesture having never registered. A release
    #   that *did* build already took its hue through `takeInk`, and a click is excluded --
    #   selecting is not constructing. `More` is excluded too: the construction is still in
    #   flight, and the apply picker it opens will take the hue the wheel just previewed.
    if was_dragging and result.index_clicked.isNone and result.index_created.isNone and
        result.choice != some(DragChoice.More):
      scene.skipInk()
    interaction.cancelDrag()
  if not interaction.is_dragging: return DragOutcome()

  # A press that never moved is a click, not a drag, and a click selects what it came down
  #   on. Answered here rather than in each render path because the drag it abandons was
  #   begun here: the press target chooses the scheme, so the press over an object has to
  #   start a drag eagerly, and *whether it was one* is only knowable at the release.
  #   **The open menu is what excludes a click, not the arming.** A right press once could
  #   never be a click at all, on the reasoning that it had asked for the wheel and being
  #   quietly answered with a selection would make the button unreliable. But the wheel only
  #   opens over a target *other* than the source, so a right press that never left its own
  #   object never opened one and there is no offer to withdraw -- and refusing it left the
  #   right button doing nothing whatsoever on a plain click.
  if interaction.menu.isNone and interaction.isClick(now):
    return
      if scene.isAlive(interaction.index_source):
        DragOutcome(index_clicked: some(interaction.index_source))
      else:
        DragOutcome() # Removed under the press; nothing to select and nothing to say.

  if interaction.menu.isSome:
    let choice = interaction.choosing
    if choice.isNone: return DragOutcome(message: "Released without choosing; nothing done.")
    return commitChoice(interaction, scene, choice.get, now)

  let over = destinationOf(interaction)
  # **Nothing to say about a release over nothing.** The reader dragged a line into empty
  #   space and let go; they can see that no object arrived, and a status line telling them
  #   so is a message that fires on every abandoned gesture -- the commonest thing a reader
  #   does with a drag they thought better of. The refusals below do earn their messages:
  #   each one is a release that landed *on something* and still built nothing, which is
  #   the case a reader cannot read off the screen.
  if over.isNone: return DragOutcome()
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
