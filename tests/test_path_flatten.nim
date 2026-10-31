## Regression test for `copyPathFlatToSeqs` (font.nim), which `write()` and
## text `transform()` rely on. It used to walk Cairo's 16-byte
## `cairo_path_data_t` with a 24-byte stride, returning garbage, so
## `write()` drew nothing until the text popped in at the end.
##
## Run with:
##   nim c -r --path:src --passL:-lfreetype --passC:-I/usr/include/freetype2 \
##     tests/test_path_flatten.nim

import cairo
import nimanim

let surface = imageSurfaceCreate(FORMAT_ARGB32, 200, 100)
let cr = create(surface)

# A known rectangle: one closed subpath with 4 sides of total length 120.
# (Cairo appends a moveTo after closePath, which shows up as a trailing
# single-point subpath; it has no length, so only the first one matters.)
cr.newPath()
cr.rectangle(10.0, 20.0, 40.0, 20.0)
let rect = cr.copyPathFlatToSeqs()
doAssert rect.subpaths[0] == @[(10.0, 20.0), (50.0, 20.0), (50.0, 40.0),
                               (10.0, 40.0), (10.0, 20.0)], $rect.subpaths
doAssert abs(rect.totalLength - 120.0) < 1e-9, $rect.totalLength

# Glyph outlines: several subpaths, all inside the surface.
cr.selectFontFace("sans-serif", FontSlantNormal, FontWeightNormal)
cr.setFontSize(40.0)
cr.newPath()
cr.moveTo(10.0, 70.0)
cr.textPath("nim")
let glyphs = cr.copyPathFlatToSeqs()
doAssert glyphs.subpaths.len >= 3, $glyphs.subpaths.len
doAssert glyphs.totalLength > 0.0
for sub in glyphs.subpaths:
  for p in sub:
    doAssert p.x >= 0.0 and p.x <= 200.0 and p.y >= 0.0 and p.y <= 100.0, $p

# Half of the trace is half of the length.
let half = glyphs.traceFraction(0.5)
doAssert abs(half.totalLength - glyphs.totalLength / 2.0) < 1e-6

cr.destroy()
surface.destroy()
echo "ok"
