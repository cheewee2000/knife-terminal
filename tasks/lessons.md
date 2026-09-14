# Lessons

## SwiftUI drag-and-drop (2026-08-27, sidebar project reorder)

**Never mutate `@State` synchronously inside `.onDrag`.** The re-render lands while AppKit is
opening the drag session and cancels or garbles it. Always
`DispatchQueue.main.async { dragging = item }`.

**Never change list geometry in response to "a drag started."** Revealing extra rows/headers
mid-drag shifts everything under the cursor, so the user is suddenly dragging over a different
row than the one they aimed at. Keep the layout constant for the whole drag.

**Every drop target in a container must commit the drag, including the ones that "aren't for it."**
Sibling targets that accept the same UTI will swallow the drop. Funnel all `performDrop`
implementations (plus the container's catch-all) through one `endDrag()` that persists the live
order — otherwise the row visibly moves and then snaps back.

**One drag-state value, not one optional per kind.** Parallel `draggingTabId` / `draggingProject`
optionals over the same `public.plain-text` payload let each target misread the other's drag. A
single `enum SidebarDrag { case tab(Int), project(String) }` makes the guards exhaustive.

**Pass identity as an argument, don't round-trip it through `@State`.** `dragging = p.path` followed
by a function that reads `dragging` back in the same call is a same-tick state read waiting to break.

## Process

**"BUILD SUCCEEDED" is not QA for anything with a pointer in it.** The first round of this feature
was reviewed against the plan and compiled clean, and every one of the five defects above was
only findable by dragging a row. When a change is interaction-shaped, either drive the real app or
say plainly that it is unverified — don't mark it done.

## Live-regrouping lists (2026-09-14, sidebar status groups — "its super buggy")

Grouping tabs by live status shipped after a clean build and no hands-on pass. Every defect
was structural and findable by reading the code for these four questions first:

**Does anything move rows while the pointer is on the list?** Activating a ready tab cleared its
status, so the row left from under the cursor. The first fix pinned the *selected* row's group,
which only relocated the jump: selecting the next row unpinned the previous one, it slid into the
group being clicked, and the highlight landed a row away from the pointer ("clicking an item in
active doesn't highlight"). Freeze group membership while the pointer is over the list instead —
order stays live so drags still work — and unfreeze on hover exit and on window resign-key.
A fix for "row moves under the cursor" that keys off *selection* will always move something at
the moment of the next click.

**Does drag reorder the model the list is actually drawn from?** Drag moved tabs in the flat
array while rows were drawn grouped, so drops didn't land and the list reshuffled mid-drag.
Constrain the drop to the dragged row's visual group.

**Is membership decided by something slower than the UI?** active/dormant hung off a 3 s
process scan, so new rows flashed into the wrong group. Prefer a value the app already owns
(a timestamp) over polling the outside world.

**Does frequent input flip the grouping key?** Every keystroke reset status, so a busy tab
flapped between groups while typing ahead.

## Technical gotchas from the same round

- **Claude Code renames its process to its version.** The kernel reports "2.1.270", not
  "claude"; match on the executable path (…/claude/versions/…). A name-based scan silently
  found zero agents.
- **A bare Esc never reached onUserInput** (it filters ESC-prefixed bytes to skip terminal
  reports), and interrupts send no Stop hook. Detect a lone 0x1b / 0x03 separately.
- **NSCursor push/pop in SwiftUI hover handlers leaks** when views reorder mid-hover. Use
  onContinuousHover with set().
- **Test extracted code, not a copy.** Pull the real enum/struct out of the source file into a
  swift script so the harness can't drift from what ships.
