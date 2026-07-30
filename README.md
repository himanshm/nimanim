# nimanim

A small, manim-inspired 2D animation engine for Nim. Define a `Scene`, add
shapes/text, animate them, and render straight to an MP4 — using
[Cairo](https://www.cairographics.org/) for 2D rendering and `ffmpeg` (as a
subprocess) for video encoding.

This is **not** a transliteration of the Python [manim](https://www.manim.community/)
project — that library is ~73,000 lines of Python with deep dependencies on
Cairo, Pango, LaTeX, and (for its OpenGL renderer) moderngl, and porting it
1:1 wasn't practical. Instead, this package re-implements the core workflow
people actually reach for manim to do: shapes, text, easing, groups, bezier
paths, and shape-morphing (`transform`), rendered and tested end-to-end.

Verified in this environment: compiles cleanly with no warnings, and
`examples/basic_scene.nim` renders a real 1280x720/30fps H.264 MP4.

## Requirements

Install these before using the package — `nimble install` only fetches the
Nim-level dependency (the Cairo *bindings*), not the C library or ffmpeg:

```bash
# Debian/Ubuntu
sudo apt-get install libcairo2-dev pkg-config ffmpeg

# macOS
brew install cairo pkg-config ffmpeg
```

`ffmpeg` must be on your `PATH` — it's invoked as a subprocess to encode
frames into the output MP4.

## Install

From the package directory:

```bash
nimble install
```

This pulls in the one Nim-level dependency, the official `cairo` bindings
(`nim-lang/cairo`).

## Usage

```nim
import nimanim

proc construct(s: Scene) =
  let circle = newCircle(radius = 1.5, strokeColor = BLUE, fillColor = BLUE,
                          fillOpacity = 0.5)
  s.add(circle)
  s.play(create(circle))
  s.play(shiftBy(circle, (3.0, 0.0)))
  s.wait(0.5)

let scene = newScene()             # 1280x720, 30fps by default
renderScene(scene, construct, "output/my_video.mp4")
```

Compile and run like any Nim program:

```bash
nim c -r -d:release my_scene.nim
```

### Run the bundled example

```bash
nim c -r -d:release --path:src examples/basic_scene.nim
```

produces `output/basic_scene.mp4`.

## API overview

**Coordinates**: origin at the center of the frame, +x right, +y up (same
convention as manim), measured in "scene units" — `Scene.frameWidth` /
`frameHeight` (default `14.222` x `8.0`) control how many units are visible;
`pixelWidth` / `pixelHeight` control the output resolution.

**Shapes** (`src/nimanim/mobject.nim`): `newCircle`, `newSquare`,
`newRectangle`, `newLine`, `newPolygon`, `newTriangle`, `newArc`, `newText`,
`newGroup`, `newPath` (freeform, via `lineTo` / `curveTo` / `closePath` —
cubic beziers). Instant (non-animated) mutators: `shift`, `moveTo`,
`rotateBy`, `scaleBy`, `setColor`, `setOpacity`, `copyMobject`.

**Animations** (`src/nimanim/animation.nim`): `create`, `uncreate`,
`fadeIn`, `fadeOut`, `shiftBy`, `moveTo`, `rotateBy`, `scaleTo`, `write`
(text), and `transform` (morphs one mobject into another — both are
approximated as point outlines and interpolated, so it works between any
two shape kinds, e.g. circle → triangle). Every animation constructor takes
`duration` (seconds) and `easing` (an `EasingFunc`, i.e. `proc(t: float):
float`); built-ins are in `core.nim`: `linear`, `smoothstep` (default),
`easeInSine/OutSine/InOutSine`, `easeInCubic/OutCubic/InOutCubic`,
`thereAndBack`.

**Scene** (`src/nimanim/scene.nim`): `newScene(...)`, `scene.add(...)`,
`scene.play(anims...)` (runs for the longest animation's duration) or
`scene.play(runTime, anims...)` (forces a fixed duration — `runTime` comes
first because Nim's `varargs` must be the last parameter), `scene.wait(s)`,
and `renderScene(scene, construct, outputPath)` to drive the whole thing.

**Colors**: `Color(r,g,b,a)` in 0..1, `rgb255(r,g,b)` for 0..255 input, plus
named constants `WHITE BLACK RED GREEN BLUE YELLOW ORANGE PURPLE TEAL GRAY
TRANSPARENT`.

## Known limitations (honest notes, not swept under the rug)

- `write()` is a fade/scale-in approximation, not manim's actual
  stroke-by-stroke glyph tracing (that needs font outline access this
  package doesn't have).
- `transform()` on text or groups falls back to treating them as a single
  point (effectively a cross-fade) rather than morphing their internal
  structure — full support would need per-glyph/per-child point sampling.
- No 3D, no camera moves/zooming, no LaTeX rendering, no audio.
- Text uses Cairo's "toy" text API (`select_font_face` / `show_text`), so
  font selection is by family name only, not arbitrary font files.

These are reasonable follow-ups if you want to extend the package further.

## File layout

```
nimanim.nimble          package manifest
src/nimanim.nim         single import point, re-exports everything below
src/nimanim/core.nim    Point2, Color, easing functions
src/nimanim/mobject.nim shapes, text, groups, bezier paths, drawing
src/nimanim/animation.nim   animation kinds + interpolation
src/nimanim/scene.nim   coordinate mapping, add/play/wait, ffmpeg piping
examples/basic_scene.nim   a runnable demo scene
```
