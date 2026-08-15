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
Nim-level dependency (the Cairo *bindings*), not the C libraries or ffmpeg:

```bash
# Debian/Ubuntu
sudo apt-get install libcairo2-dev libfreetype6-dev pkg-config ffmpeg

# macOS
brew install cairo freetype pkg-config ffmpeg
```

`ffmpeg` must be on your `PATH` — it's invoked as a subprocess to encode
frames into the output MP4.

`libfreetype` is required by `nimanim/font.nim` to load arbitrary
`.ttf` / `.otf` font files via `newText(..., fontFile = "...")`. If you
only ever use the `fontFamily` (default) mode of `newText`, FreeType
isn't loaded, but the link flag is always applied at build time.

Optional: to use `newLatex(r"E = mc^2")` you also need `pdflatex` and
`pdftoppm` on your `PATH`:

```bash
sudo apt-get install texlive-latex-base texlive-latex-extra poppler-utils
```

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
cubic beziers), `newImage` (PNG, drawn at native aspect ratio or
arbitrary size), `newLatex` (LaTeX source → PNG via `pdflatex` +
`pdftoppm`, cached on disk). Instant (non-animated) mutators: `shift`,
`moveTo`, `rotateBy`, `scaleBy`, `setColor`, `setOpacity`, `copyMobject`.

**Animations** (`src/nimanim/animation.nim`): `create`, `uncreate`,
`fadeIn`, `fadeOut`, `shiftBy`, `moveTo`, `rotateBy`, `scaleTo`, `write`
(real stroke-by-stroke glyph tracing via `cairo_text_path` +
`cairo_copy_path_flat`), and `transform` (morphs one mobject into
another — both are approximated as point outlines and interpolated,
so it works between any two shape kinds, e.g. circle → triangle, and
**now also works on text and groups** by sampling glyph outlines /
children's boundaries respectively). Camera animations: `panTo`,
`zoomTo`. Every animation constructor takes
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

- `write()` **now performs true stroke-by-stroke glyph tracing**: the
  text's glyph outlines are extracted via `cairo_text_path` +
  `cairo_copy_path_flat`, then revealed progressively along the
  cumulative arc length. Works for any font (including those loaded via
  `fontFile = "..."`). This replaces the previous fade/scale-in
  approximation.
- `transform()` on text or groups **now morphs the actual shape**:
  text's glyph outlines are sampled as a point cloud (using the same
  path-flattening technique as `write()`), and groups recursively sample
  each child's boundary and concatenate. The previous behaviour (treating
  text/groups as a single point, effectively a cross-fade) is no longer
  the fallback.
- Camera moves and zooming are now supported via the `Camera` type on
  `Scene`. Animate the camera with `panTo((x, y), duration = ...)`
  and `zoomTo(2.0, duration = ...)`. LaTeX rendering is supported via
  `newLatex(r"E = mc^2")` (requires `pdflatex` + `pdftoppm` on PATH).
  **3D is still out of scope** — adding it would require Z coordinates
  on mobjects, depth sorting, and perspective projection, all of which
  are a much larger architectural change.
- Text **can now load arbitrary `.ttf` / `.otf` font files** via the
  `fontFile` parameter on `newText()`. Loading uses FreeType + Cairo's
  FreeType bridge, and the loaded `FontFace` is cached per process so
  repeated `newText(..., fontFile=...)` calls with the same path are
  cheap. The previous "toy text API only" limitation is lifted;
  `cairo_toy_font_face_create` (the proper Cairo API for family-name
  fonts) is now used for the `fontFamily`-only path, replacing the
  deprecated `cairo_select_font_face` Context mutator.

**Audio / voiceover is supported** via the optional `nimanim/voiceover`
module — see "Voiceover" below.

## Voiceover

`nimanim/voiceover` is an optional module that adds narration to scenes,
modelled on the relationship between Python's `manim-voiceover` (and
`kokoro-manim-voiceover`) and `manim` itself. The design is:

* **A pluggable `SpeechSynthesizer` interface** so any TTS engine can be
  wired in. Four backends ship in the box:
  * `espeak` — robotic but free and zero-setup; **the default backend**.
    Automatically uses `espeak-ng` if available, falling back to the
    older `espeak` binary if not. Works offline everywhere.
  * `kokoro` — high-quality neural TTS via the Python `kokoro` package;
    exposes real per-word timestamps for accurate captioning.
  * `coqui` — neural TTS via the Python `TTS` (Coqui) package; supports
    many model families (XTTS, VITS, Glow-TTS, Tacotron2, YourTTS) and
    multi-speaker / multilingual voices.
  * `command` — generic shell-template driver for any other TTS CLI
    (`festival`, `pico2wave`, `say`, …).
* **A `VoiceoverScene` wrapper** around `Scene` that adds `say()` and a
  `voiceover(s, "text"):` template for interleaving narration with
  animations. A convenience overload `newVoiceoverScene(scene)` uses the
  default backend (espeak-ng) so you don't have to pick one explicitly
  during development.
* **On-disk caching** keyed by `(text, voice)` so re-rendering a scene
  is essentially free after the first run.
* **Per-word `WordBoundary` timestamps** surfaced from backends that
  provide them, with an even-distribution fallback for those that don't.
* **SRT / WebVTT caption export** via `scene.writeCaptions(path)`.
* **No video re-encode** — audio is muxed in with `ffmpeg -c:v copy`,
  so the voiceover step adds negligible time on top of the video render.

### Setup

In addition to nimanim's own prerequisites (Cairo + ffmpeg), the
voiceover module needs a TTS engine on your `PATH`:

```bash
# eSpeak-NG (default backend, free, offline, zero-setup)
sudo apt-get install espeak-ng       # Debian/Ubuntu (preferred)
sudo apt-get install espeak          # legacy fallback if ng isn't available
brew install espeak                  # macOS

# Kokoro (high-quality neural TTS) -- optional, requires Python 3.10+
pip install kokoro>=0.9 misaki[en]>=0.9.1 soundfile

# Coqui TTS (neural TTS, many model families) -- optional, requires Python 3.9+
pip install TTS soundfile
```

If no backend is explicitly configured, `nimanim/voiceover` uses
`espeak-ng` (or `espeak` as a fallback). To use Kokoro or Coqui, import
the corresponding module and pass it to `newVoiceoverScene` explicitly.

### Quick example

```nim
import nimanim
import nimanim/voiceover
# Default backend (espeak-ng) is wired in automatically -- no backend
# import needed. To swap, e.g.:
#   import nimanim/voiceover/kokoro
#   let synth = newKokoroSynthesizer()

proc construct(s: VoiceoverScene) =
  let circle = newCircle(radius = 1.5, fillColor = BLUE, fillOpacity = 0.5)
  s.add(circle)

  # `say` speaks and waits for the clip to finish -- no parallel animation.
  s.say("Behold: a circle.")

  # `voiceover` speaks while running the block. If the block is shorter
  # than the narration, the scene waits for the remainder. If it's
  # longer, the narration simply ends mid-way.
  voiceover(s, "Watch it slide to the right."):
    s.play(shiftBy(circle, (3.0, 0.0), duration = 1.4))

  s.say("And that's the demo.")

# No synth argument -> uses the default (espeak-ng).
let scene = newVoiceoverScene(
  newScene(pixelWidth = 1280, pixelHeight = 720, fps = 30),
)
renderScene(scene, construct, "output/narrated.mp4")
scene.writeCaptions("output/narrated.srt")
```

To swap backends, just pass a different synthesizer:

```nim
import nimanim/voiceover/kokoro
let scene = newVoiceoverScene(
  newScene(pixelWidth = 1280, pixelHeight = 720, fps = 30),
  newKokoroSynthesizer(voice = "af_heart"),
)

# Or Coqui:
import nimanim/voiceover/coqui
let scene = newVoiceoverScene(
  newScene(pixelWidth = 1280, pixelHeight = 720, fps = 30),
  newCoquiSynthesizer(modelName = "tts_models/en/ljspeech/glow-tts"),
)
```

### Run the bundled examples

```bash
# Default backend (espeak-ng) -- simplest, no explicit synth
nim c -r -d:release --path:src examples/voiceover_default.nim
# -> output/voiceover_default.mp4 + output/voiceover_default.srt

# Explicit espeak backend (still uses espeak-ng if available)
nim c -r -d:release --path:src examples/voiceover_scene.nim
# -> output/voiceover_scene.mp4 + output/voiceover_scene.srt

# Kokoro backend (needs `pip install kokoro misaki[en] soundfile`)
nim c -r -d:release --path:src examples/voiceover_kokoro.nim
# -> output/voiceover_kokoro.mp4 + output/voiceover_kokoro.srt

# Coqui backend (needs `pip install TTS soundfile`)
nim c -r -d:release --path:src examples/voiceover_coqui.nim
# -> output/voiceover_coqui.mp4 + output/voiceover_coqui.srt

# Generic command backend (drives any TTS CLI via a template)
nim c -r -d:release --path:src examples/voiceover_command.nim
```

### Backends at a glance

| Backend       | Default? | Quality  | Word timestamps | Setup                     |
|---------------|----------|----------|-----------------|---------------------------|
| `espeak`      | **yes**  | robotic  | approximated    | `apt install espeak-ng`   |
| `kokoro`      |          | natural  | real (model)    | `pip install kokoro ...`  |
| `coqui`       |          | natural  | approximated    | `pip install TTS ...`     |
| `command`     |          | depends  | approximated    | any TTS CLI on PATH       |

The `espeak` backend automatically prefers `espeak-ng` (the modern fork
with more languages and active maintenance) when both are installed, and
silently falls back to the legacy `espeak` binary otherwise. Either way
the user-facing API is identical.

`newCommandSynthesizer(cmd = "pico2wave -w {output} {text}")` is the
escape hatch for engines without a dedicated module: `{text}` and
`{output}` are substituted before invocation, and the resulting WAV's
duration is probed with `ffprobe`.

### Coqui TTS specifics

Coqui TTS supports many model families. The constructor's `modelName`
parameter picks one:

```nim
# Small (~100MB), single-speaker American female. Good for development.
let s1 = newCoquiSynthesizer(modelName = "tts_models/en/ljspeech/glow-tts")

# Slower, slightly more natural than glow-tts.
let s2 = newCoquiSynthesizer(modelName = "tts_models/en/ljspeech/tacotron2-DDC")

# XTTS v2 (~1.5GB): multilingual + multi-speaker.
let s3 = newCoquiSynthesizer(
  modelName = "tts_models/multilingual/multi-dataset/xtts_v2",
  speaker = "Ana Florence",
  language = "en",
)

# Use a CUDA GPU if available (much faster for large models).
let s4 = newCoquiSynthesizer(
  modelName = "tts_models/multilingual/multi-dataset/xtts_v2",
  speaker = "Ana Florence",
  language = "en",
  useCuda = true,
)
```

List all available models with:

```bash
python3 -c "from TTS.api import TTS; print(TTS().list_models())"
```

`speaker` and `language` are silently ignored for single-speaker models
so the same scene code works whether you're using glow-tts or XTTS.

### Writing your own backend

A `SpeechSynthesizer` is just a `ref object` with three fields:
`name`, `defaultVoice`, `cacheDir`, and a `synthesizeFn` closure that
takes `(text, voice)` and returns a `SynthesisResult` (audio path +
duration + optional word boundaries). Caching, manifest serialisation,
and ffprobe-based duration fallback are handled by the framework, so a
new backend only needs the actual TTS call:

```nim
import nimanim/voiceover/synth

proc newMySynthesizer(): SpeechSynthesizer =
  proc fn(text, voice: string): SynthesisResult {.closure.} =
    let tmpPath = "/tmp/my_tts.wav"
    # ... call your TTS engine, write to tmpPath ...
    result = SynthesisResult(
      audioPath: tmpPath,
      duration: 0.0,            # 0 -> framework will ffprobe it
      sampleRate: 0,
      words: @[],               # empty -> caption.nim will approximate
    )
  result = newSpeechSynthesizer("my-tts", fn, defaultVoice = "default")
```

### How audio gets into the MP4

`Scene` has an optional `audioTrackBuilder` hook (a `proc(s: Scene):
string`). When set, `renderScene`:

1. Writes the video to `<output>.tmpvid.mp4` instead of straight to the
   final path.
2. Runs `construct` as usual — frames are piped to ffmpeg just like the
   no-audio case.
3. After construct returns, calls `audioTrackBuilder(scene)` to obtain
   the path to a mixed WAV (the voiceover module uses ffmpeg's `adelay`
   + `amix` filters to combine all queued segments at their scheduled
   start times).
4. Muxes the temp video and mixed audio with `ffmpeg -c:v copy -c:a aac
   -shortest` into the final output.

This means voiceover adds **no extra video encode** — only an audio
encode (AAC) and a stream copy, both very fast.

## File layout

```
nimanim.nimble              package manifest
src/nimanim.nim             single import point, re-exports the base library
src/nimanim/core.nim        Point2, Color, Camera, easing functions
src/nimanim/font.nim        FreeType + Cairo font-face loading (fontFile support),
                            + glyph-path flattening helpers used by write() /
                            transform() to trace / morph text outlines
src/nimanim/mobject.nim     shapes, text (with fontFile), groups, bezier paths,
                            images, LaTeX (newLatex), drawing
src/nimanim/animation.nim   animation kinds + interpolation,
                            + camera animations (panTo, zoomTo)
src/nimanim/scene.nim       coordinate mapping (with camera pan/zoom),
                            add/play/wait, ffmpeg piping,
                            + optional `audioTrackBuilder` hook
src/nimanim/voiceover.nim   optional module: re-exports the voiceover API
src/nimanim/voiceover/
  synth.nim                 SpeechSynthesizer interface + on-disk cache
                            + newDefaultSynthesizer() (espeak-ng)
  mix.nim                   ffmpeg adelay+amix segment mixer
  scene.nim                 VoiceoverScene, say(), voiceover() template,
                            + newVoiceoverScene(scene) overload (default synth)
  caption.nim               SRT / WebVTT subtitle export
  espeak.nim                eSpeak-NG/eSpeak backend (DEFAULT -- auto-detects)
  kokoro.nim                Kokoro backend (high-quality neural TTS)
  coqui.nim                 Coqui TTS backend (XTTS, VITS, Glow-TTS, ...)
  command.nim               generic CLI-template backend
examples/basic_scene.nim        a runnable demo scene (no audio)
examples/new_features.nim        demo of stroke-tracing write(), text morph,
                                camera pan/zoom (added with the limitation fixes)
examples/voiceover_default.nim  default-backend demo (espeak-ng, no config)
examples/voiceover_scene.nim    explicit espeak backend demo + SRT
examples/voiceover_kokoro.nim   Kokoro-narrated demo (needs pip install)
examples/voiceover_coqui.nim    Coqui-narrated demo (needs pip install)
examples/voiceover_command.nim  generic command-backend demo
tests/voiceover_compile.nim     compile + API-surface smoke test (31 assertions)
```
