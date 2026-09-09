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
