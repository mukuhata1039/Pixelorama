# Aseprite application cursors — third-party assets

Pixelorama uses the **original Aseprite Default Theme cursor sprites** throughout
its UI where Godot provides matching cursor shapes. The source images themselves
are unchanged and are displayed at **2× size (16×16 → 32×32 pixels)**
using **nearest-neighbor scaling**. The source PNG is embedded losslessly as
Base64 in `src/UI/Timeline/AsepriteCopyCursor.gd` and cropped at runtime.
The cursor hotspots from Aseprite's `theme.xml` are scaled by the same factor.

| Original `theme.xml` part | Application usage | Source region (x, y, w, h) |
| --- | --- | --- |
| `cursor_normal` | Ordinary pointer | (80, 0, 16, 16) |
| `cursor_normal_add` | Copy drag / valid drop | (80, 16, 16, 16) |
| `cursor_crosshair` | Canvas crosshair, if native preference is off | (96, 32, 16, 16) |
| `cursor_forbidden` | Disallowed cursor state | (80, 32, 16, 16) |
| `cursor_hand` | Clickable controls | (80, 48, 16, 16) |
| `cursor_scroll` | Included for future cursor uses | (80, 64, 16, 16) |
| `cursor_move` | Move drag and controls | (80, 80, 16, 16) |
| `cursor_size_ns` | Vertical resize/split | (80, 112, 16, 16) |
| `cursor_size_we` | Horizontal resize/split | (80, 144, 16, 16) |
| `cursor_size_nw` | One diagonal resize direction | (80, 96, 16, 16) |
| `cursor_size_ne` | Other diagonal resize direction | (80, 128, 16, 16) |

Unmapped cursor shapes (such as text insertion/I-beam, wait and busy) retain the
system cursors. Pixelorama's pre-existing *canvas rotation* cursor and per-tool
brush preview overlays retain their behavior. The "native cursors" preference
also continues to control the canvas crosshair. The sprite sheet is not
recolored, edited or resampled other than the stated 2× nearest-neighbor
display enlargement.

**Aseprite Default Theme**  
Copyright (C) 2009–2017 David Capello and Ilija Melentijevic.

- Source sprite sheet: https://github.com/aseprite/aseprite/blob/main/data/extensions/aseprite-theme/sheet.png
- Sprite coordinates and hotspots: https://github.com/aseprite/aseprite/blob/main/data/extensions/aseprite-theme/theme.xml
- Upstream license notice: https://github.com/aseprite/aseprite/blob/main/data/extensions/aseprite-theme/LICENSE.txt
- License: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)

Attribution is provided in accordance with CC BY 4.0. This asset license
does not change the terms of Pixelorama's other code and artwork.
