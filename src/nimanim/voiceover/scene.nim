## Voiceover scene -- the user-facing entry point for narrated animations.
##
## `VoiceoverScene` wraps a regular `Scene` and adds narration tracking:
## each `say("text")` or `voiceover(scene, "text"):` call synthesizes a
## TTS clip, schedules it at the current elapsed-time of the video, and
## (for `say`) advances the scene clock by the clip's duration so the
## next animation starts after the narration finishes.
##
## At the end of `renderScene`, the wrapped scene's `audioTrackBuilder`
## hook mixes all scheduled clips into a single WAV and muxes it into the
## final MP4. No video re-encoding happens -- only audio is added.
##
## Example:
##
##   import nimanim
##   import nimanim/voiceover
##   import nimanim/voiceover/espeak
##
##   proc construct(s: VoiceoverScene) =
##     s.say("Hello, world!")
##     voiceover(s, "Watch this circle appear"):
##       s.play(create(circle))
##     s.say("Goodbye.")
##
##   let scene = newVoiceoverScene(
##     newScene(fps = 30),
##     newEspeakSynthesizer(voice = "en"),
##   )
##   renderScene(scene, construct, "output/narrated.mp4")

import std/os
import ../scene
import ../core
import ../mobject
import ../animation
import ./synth
import ./mix

export scene except renderScene  # we add our own renderScene overload below
export synth
export mix

type
  VoiceoverScene* = ref object
    ## A `Scene`-like object that layers narration on top of animations.
    ## Field `base` is the underlying `Scene` -- you can pass it anywhere
    ## a `Scene` is expected.
    base*: Scene
    synth*: SpeechSynthesizer
    voice*: string
    cacheDir*: string
    elapsed*: float           ## current offset into the final video, seconds
    segments*: seq[VoiceoverSegment]

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newVoiceoverScene*(base: Scene, synth: SpeechSynthesizer,
                         voice = ""): VoiceoverScene =
  ## Wraps `base` so it can be narrated. `voice` overrides the synth's
  ## default voice for this scene; pass "" to use the synth default.
  result = VoiceoverScene(
    base: base,
    synth: synth,
    voice: voice,
    cacheDir: synth.cacheDir,
    elapsed: 0.0,
    segments: @[],
  )
  let vs = result  # capture for the closure below
  base.audioTrackBuilder = proc(s: Scene): string =
    if vs.segments.len == 0: return ""
    let mixedPath = vs.cacheDir / "mixed.wav"
    # Clean up any stale mix from a previous render so we don't accidentally
    # mux yesterday's audio into today's video.
    if fileExists(mixedPath): removeFile(mixedPath)
    if not mixVoiceoverSegments(vs.segments, mixedPath):
      return ""
    return mixedPath

proc newVoiceoverScene*(base: Scene, voice = ""): VoiceoverScene =
  ## Convenience overload: builds a `VoiceoverScene` using the package's
  ## default synthesizer (espeak-ng, with espeak as a legacy fallback).
  ## Equivalent to:
  ##
  ##   newVoiceoverScene(base, newDefaultSynthesizer(), voice = voice)
  ##
  ## This is the simplest entry point -- if you just want narration
  ## without picking a specific TTS engine, use this and you'll get
  ## espeak-ng. Swap to `newVoiceoverScene(base, newKokoroSynthesizer())`
  ## (or Coqui, or a custom backend) later without changing your scene
  ## code.
  result = newVoiceoverScene(base, newDefaultSynthesizer(), voice)

# ---------------------------------------------------------------------------
# Forwarded Scene API (so user code can treat VoiceoverScene like a Scene)
# ---------------------------------------------------------------------------

proc add*(vs: VoiceoverScene, mobjects: varargs[Mobject]) =
  vs.base.add(mobjects)

proc remove*(vs: VoiceoverScene, m: Mobject) =
  vs.base.remove(m)

proc play*(vs: VoiceoverScene, anims: varargs[Animation]) =
  ## Same as `Scene.play` -- plays all `anims` simultaneously for as long
  ## as the longest one's `duration` -- and also advances the scene's
  ## elapsed-time clock so subsequent `say()` calls schedule correctly.
  ##
  ## Time is tracked in frames (rounded the same way `Scene.renderFrames`
  ## rounds) and converted back to seconds, so audio start times stay
  ## perfectly aligned with the actual video timeline even when durations
  ## don't fall on exact frame boundaries.
  var duration = 0.0
  for a in anims:
    if a.duration > duration: duration = a.duration
  if duration <= 0: duration = 1.0
  let frameCount = max(1, int(duration * vs.base.fps.float + 0.5))
  vs.base.play(anims)
  vs.elapsed += frameCount.float / vs.base.fps.float

proc play*(vs: VoiceoverScene, runTime: float, anims: varargs[Animation]) =
  ## Like `Scene.play(runTime, anims)` -- forces the whole call to take
  ## exactly `runTime` seconds -- and advances the elapsed-time clock.
  let frameCount = max(1, int(runTime * vs.base.fps.float + 0.5))
  vs.base.play(runTime, anims)
  vs.elapsed += frameCount.float / vs.base.fps.float

proc wait*(vs: VoiceoverScene, seconds: float = 1.0) =
  ## Same as `Scene.wait` -- renders `seconds` seconds of the current
  ## frame -- and advances the elapsed-time clock.
  let frameCount = max(1, int(seconds * vs.base.fps.float + 0.5))
  vs.base.wait(seconds)
  vs.elapsed += frameCount.float / vs.base.fps.float

# ---------------------------------------------------------------------------
# Narration
# ---------------------------------------------------------------------------

proc startSegment*(vs: VoiceoverScene, text: string, voice = ""): SynthesisResult =
  ## Synthesizes `text` and records a voiceover segment starting at the
  ## current elapsed time. Returns the `SynthesisResult` so callers (like
  ## the `voiceover` template) can inspect `duration` and `words`.
  ##
  ## The clip itself is *not* played yet -- it's queued for mixing at the
  ## end of `renderScene`. Use `say` for fire-and-forget narration, or
  ## the `voiceover` template to interleave narration with animations.
  let useVoice = if voice.len > 0: voice else: vs.voice
  let r = vs.synth.synthesize(text, useVoice)
  vs.segments.add(VoiceoverSegment(
    audioPath: r.audioPath,
    startTime: vs.elapsed,
    duration: r.duration,
    text: text,
    voice: useVoice,
    words: r.words,
  ))
  result = r

proc say*(vs: VoiceoverScene, text: string, voice = "") =
  ## Speaks `text` and waits for the clip to finish before returning.
  ## The scene's elapsed-time clock advances by the clip's duration.
  ##
  ## This is the simplest narration call -- use it when you don't have
  ## animations to run in parallel with the speech.
  let r = vs.startSegment(text, voice)
  vs.wait(r.duration)

proc say*(vs: VoiceoverScene, text: string, voice: string,
          body: proc()) =
  ## Speaks `text` while running `body`. After `body` finishes, if the
  ## narration isn't done yet, the scene waits for the remainder. If
  ## `body` runs longer than the narration, the narration simply ends
  ## mid-way through -- no padding is added.
  ##
  ## Prefer the `voiceover` template over this overload -- it's more
  ## readable and doesn't require wrapping your scene code in a `proc`.
  let r = vs.startSegment(text, voice)
  let startElapsed = vs.elapsed
  body()
  let bodyDuration = vs.elapsed - startElapsed
  if r.duration > bodyDuration:
    vs.wait(r.duration - bodyDuration)

# ---------------------------------------------------------------------------
# Rendering -- we provide our own `renderScene` overload so user code looks
# identical whether the scene is a plain `Scene` or a `VoiceoverScene`.
# ---------------------------------------------------------------------------

proc renderScene*(vs: VoiceoverScene, construct: proc(s: VoiceoverScene),
                   outputPath: string) =
  ## Same shape as `Scene.renderScene`, but the construct proc receives a
  ## `VoiceoverScene`. Under the hood, this delegates to `base.renderScene`
  ## with a wrapper that calls `construct(vs)` -- the audio mixing is
  ## handled by the `audioTrackBuilder` hook installed at construction.
  proc wrapper(s: Scene) =
    construct(vs)
  vs.base.renderScene(wrapper, outputPath)

# ---------------------------------------------------------------------------
# `voiceover` template -- the most ergonomic way to narrate.
# ---------------------------------------------------------------------------

template voiceover*(vs: VoiceoverScene, text: string, body: untyped) =
  ## Speak `text` while running `body`. If the narration outlasts `body`,
  ## the scene waits for the remainder; if `body` outlasts the narration,
  ## the narration simply ends early.
  ##
  ## Example:
  ##   voiceover(s, "Watch the circle move"):
  ##     s.play(moveTo(circle, (3, 0)))
  let segmentResult = vs.startSegment(text)
  let voStart = vs.elapsed
  body
  let voBodyDuration = vs.elapsed - voStart
  if segmentResult.duration > voBodyDuration:
    vs.wait(segmentResult.duration - voBodyDuration)

# ---------------------------------------------------------------------------
# Caption helpers
# ---------------------------------------------------------------------------

import ./caption

proc writeCaptions*(vs: VoiceoverScene, outputPath: string,
                    format: CaptionFormat = cfSrt) =
  ## Writes all queued voiceover segments to `outputPath` as an SRT (or
  ## VTT) subtitle file. Call this AFTER `renderScene` -- segments are
  ## only populated once `construct` has run.
  ##
  ## Uses per-word timestamps from the synth (Kokoro provides real ones;
  ## espeak/command backends approximate by spreading duration evenly).
  let caps = buildCaptions(vs.segments, format)
  writeFile(outputPath, caps)
