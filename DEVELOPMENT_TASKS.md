# Planned development tasks

This file records requested future Pixelorama changes. Items below are **not implemented** until explicitly marked complete.

## Pending

### Timeline: Delete key clears all selected cel content (requested 2026-11-02)

**Status:** Not implemented. Record this as a future implementation task.

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
