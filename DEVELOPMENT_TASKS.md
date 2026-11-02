# Planned development tasks

This file records requested future Pixelorama changes. Items below are **not implemented** until explicitly marked complete.

## In review — PR #49

### Timeline: Delete key clears all selected cel content (requested 2026-11-02)

**Status:** Implemented on feature branch in [PR #49](https://github.com/mukuhata1039/Pixelorama/pull/49). Awaiting merge and runtime validation.

**Expected behavior**
- When the timeline has focus and multiple cels are selected, one press of the **Delete** key clears the image/content of all selected editable cels.
- Supports selections across different layers, nested groups, and multiple frames, including a vertical range crossing group boundaries.
- Does **not** delete layers, group structure, frames, or remove the cel slots.
- One Undo (Ctrl+Z) restores all affected cel content; Redo reapplies the change.
- Delete does not intercept unrelated contexts such as text editing or the canvas selection tools.
- Safely handle group/audio/3D and other unsupported or procedural cel types.
- Define and preserve safe behavior for linked cels, avoiding duplicate mutation/undo entries.

**Relevant existing code:** `src/UI/Timeline/CelButton.gd` has `_delete_cel_content()`, currently used by the cel context-menu Delete action. Add a keyboard timeline command that operates on the complete selected range rather than assuming a single target.

**Verification:** Make a selection crossing multiple expanded groups and frames, clear it with Delete, confirm structure is unchanged and one Ctrl+Z restores all cleared drawings.

### Timeline: consecutive PNG drop into existing empty cels (requested 2026-11-02)

**Status:** Implemented on feature branch in [PR #49](https://github.com/mukuhata1039/Pixelorama/pull/49). Awaiting merge and runtime validation.

**Expected behavior**
- Drop multiple PNG files from Explorer onto the first target cel in the timeline.
- Fill sequential existing frames on the same PixelLayer in natural filename order (e.g. `1.png`, `2.png`, `10.png`).
- Do not overwrite any occupied/linked destination, and reject batches if there are insufficient frames.
- Validate the entire batch before any mutation and support one-step Undo.
- Keep the existing image import dialogs for drops outside the timeline grid.

**Verification:** Drop five consecutively numbered PNGs on five empty timeline cels, check their order and undo/redo. Verify busy frame, non-pixel/locked layer, linked cel, too few frames, and dropping outside the grid.
