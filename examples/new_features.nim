## Demonstrates the new features added in this commit:
##   * True stroke-by-stroke glyph tracing via `write()` (Fix #1)
##   * `transform()` on text -- morphs text into another text (Fix #2)
##   * Camera pan/zoom animations (Fix #3 -- partial)
##   * Custom font file loading via `fontFile = "..."` (Fix #4)
##
## Run with:
##   nim c -r -d:release --path:src --passL:-lfreetype --passC:-I/usr/include/freetype2 \
##     examples/new_features.nim
## Produces: output/new_features.mp4

import nimanim

proc construct(s: Scene) =
  # 1. Stroke-by-stroke glyph tracing. The text outline is extracted via
  #    cairo_text_path + cairo_copy_path_flat and revealed progressively.
  let title = newText("nimanim", fontSize = 1.0, center = (0.0, 3.0),
                      color = WHITE)
  s.add(title)
  s.play(1.5, write(title))
  s.wait(0.3)

  # 2. Morph text into different text. Before this commit, `transform()`
  #    on text was a cross-fade; now it samples the actual glyph outlines
  #    and interpolates point-by-point, so the morph looks like the
  #    letters physically rearranging themselves.
  let title2 = newText("manim", fontSize = 1.0, center = (0.0, 3.0),
                       color = YELLOW)
  s.play(transform(title, title2, duration = 1.2))
  s.wait(0.3)

  # 3. Camera zoom-in on the title text. (Camera pan is also available
  #    via `panTo((x, y))` -- we use zoomTo here for brevity.)
  s.play(zoomTo(2.0, duration = 1.2))
  s.wait(0.2)
  s.play(zoomTo(1.0, duration = 1.0))

  # 4. A bit of text morph + a circle for visual variety. The camera
  #    animation runs in parallel with the circle's `create` animation --
  #    both finish at the same time, exactly as multi-animation `play`
  #    calls already did before.
  let circle = newCircle(radius = 1.2, center = (0.0, -1.5),
                          fillColor = BLUE, strokeColor = BLUE,
                          fillOpacity = 0.6)
  s.add(circle)
  s.play(
    panTo((0.0, -1.5), duration = 1.2),
    create(circle),
  )
  s.wait(0.3)

  s.play(0.8, fadeOut(circle), fadeOut(title))

let scene = newScene(pixelWidth = 1280, pixelHeight = 720, fps = 30)
renderScene(scene, construct, "output/new_features.mp4")
