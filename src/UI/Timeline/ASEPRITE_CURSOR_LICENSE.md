# Aseprite timeline cursors — third-party assets

The following cursor designs are extracted **without modification** from the
official Aseprite Default Theme sprite sheet and rendered at 2× size
(**16×16 source pixels → 32×32 cursor pixels**) with nearest-neighbor scaling
to preserve hard pixel edges.

| Original `theme.xml` part | Used for | Sprite region (x, y, w, h) |
| --- | --- | --- |
| `cursor_normal` | Ordinary pointer / cel selection | (80, 0, 16, 16) |
| `cursor_normal_add` | Ctrl/Alt cel copy drag | (80, 16, 16, 16) |
| `cursor_forbidden` | Disallowed cursor state | (80, 32, 16, 16) |
| `cursor_hand` | Timeline clickable controls | (80, 48, 16, 16) |
| `cursor_scroll` | Scrolling cursor asset | (80, 64, 16, 16) |
| `cursor_move` | Selected cel outline / move drag | (80, 80, 16, 16) |
| `cursor_size_ns` | Vertical resize | (80, 112, 16, 16) |
| `cursor_size_we` | Horizontal resize | (80, 144, 16, 16) |

The unmodified source PNG is embedded losslessly as Base64 in
`AsepriteCopyCursor.gd`; its regions are extracted and **scaled for display
only**, without altering the original image data or individual pixels. The
original `theme.xml` cursor hotspot coordinates are scaled by the same factor.

**Aseprite Default Theme**  
Copyright (C) 2009–2017 David Capello and Ilija Melentijevic.

- Original sprite sheet: https://github.com/aseprite/aseprite/blob/main/data/extensions/aseprite-theme/sheet.png
- Sprite positions and hotspots: https://github.com/aseprite/aseprite/blob/main/data/extensions/aseprite-theme/theme.xml
- Original license notice: https://github.com/aseprite/aseprite/blob/main/data/extensions/aseprite-theme/LICENSE.txt
- License: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)

These cursors are installed temporarily for the timeline or while dragging
its cels; they are restored to the standard application cursor outside that
context. This does not change other Pixelorama artwork or its licenses.
