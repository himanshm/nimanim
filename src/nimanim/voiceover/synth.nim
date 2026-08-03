## Pluggable speech-synthesizer interface for `nimanim/voiceover`.
##
## The design mirrors `manim-voiceover`'s "services" abstraction: a single
## `SpeechSynthesizer` type holds a function pointer that turns a string of
## text into a `SynthesisResult` (an audio file + duration + word-level
## timestamps). Concrete backends -- `espeak`, `kokoro`, `command` -- are
## just constructors that wire up the function pointer with the right
## shell-out / Python call / etc.
##
## All backends share a single on-disk cache (keyed by `hash(text|voice)`)
## so re-rendering a scene is essentially free after the first run.

import std/[os, hashes, json, osproc, strutils, streams]

type
  WordBoundary* = object
    ## A single word within a synthesized clip, with its start/end time
    ## relative to the start of the clip (seconds). Used for captioning.
    text*: string
    start*: float
    `end`*: float

  SynthesisResult* = object
    ## Output of one TTS call.
    audioPath*: string       ## path to a WAV file (any sample rate, mono or stereo)
    duration*: float         ## length in seconds
    sampleRate*: int         ## Hz (0 if unknown)
    words*: seq[WordBoundary]## may be empty if the backend doesn't provide timing

  SynthesizeFn* = proc(text: string, voice: string): SynthesisResult {.closure.}

  SpeechSynthesizer* = ref object
    ## A TTS backend. Construct one with `newSpeechSynthesizer` (or one of
    ## the backend-specific constructors in `espeak`/`kokoro`/`command`)
    ## and pass it to `newVoiceoverScene`.
    name*: string
    defaultVoice*: string
    cacheDir*: string
    synthesizeFn*: SynthesizeFn

# ---------------------------------------------------------------------------
# ffprobe helper -- used to measure the duration of a WAV file when the
# backend itself doesn't report one (e.g. espeak).
# ---------------------------------------------------------------------------

proc probeAudioDuration*(path: string): float =
  ## Returns the duration of `path` in seconds via ffprobe, or 0.0 on error.
  let p = startProcess("ffprobe", args = @[
    "-v", "error",
    "-show_entries", "format=duration",
    "-of", "default=noprint_wrappers=1:nokey=1",
    path,
  ], options = {poUsePath, poStdErrToStdOut})
  let outStr = p.outputStream().readAll().strip()
  discard p.waitForExit()
  p.close()
  if outStr.len == 0: return 0.0
  try:
    result = parseFloat(outStr)
  except ValueError:
    result = 0.0

# ---------------------------------------------------------------------------
# Manifest (cache metadata) -- stored as `<wav>.json` next to the WAV.
# ---------------------------------------------------------------------------

proc saveManifest*(wavPath: string, r: SynthesisResult) =
  let m = newJObject()
  m["duration"] = %r.duration
  m["sample_rate"] = %r.sampleRate
  let wordsArr = newJArray()
  for w in r.words:
    let wObj = newJObject()
    wObj["text"] = %w.text
    wObj["start"] = %w.start
    wObj["end"] = %w.`end`
    wordsArr.add(wObj)
  m["words"] = wordsArr
  writeFile(wavPath & ".json", $m)

proc loadManifest*(wavPath: string): SynthesisResult =
  result.audioPath = wavPath
  let raw = readFile(wavPath & ".json")
  let m = parseJson(raw)
  result.duration = m["duration"].getFloat()
  result.sampleRate = m["sample_rate"].getInt()
  if m.hasKey("words"):
    for w in m["words"]:
      result.words.add(WordBoundary(
        text: w["text"].getStr(),
        start: w["start"].getFloat(),
        `end`: w["end"].getFloat(),
      ))

# ---------------------------------------------------------------------------
# Cache key -- a stable hash of (text, voice). MD5 would be nicer but the
# stdlib's `hashes.hash` is plenty collision-resistant for cache filenames
# (we verify by reading the manifest back, so a collision would only cause
# a single wasted resynthesis).
# ---------------------------------------------------------------------------

proc cacheKey*(text, voice: string): string =
  let h = hash(text & "\1" & voice)
  "vo_" & $h

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc newSpeechSynthesizer*(name: string, synthesizeFn: SynthesizeFn,
                           defaultVoice = "",
                           cacheDir = "media/voiceover_cache"): SpeechSynthesizer =
  ## Builds a generic `SpeechSynthesizer` from a closure. Backend modules
  ## use this under the hood; end users usually call `newEspeakSynthesizer`
  ## / `newKokoroSynthesizer` / `newCommandSynthesizer` instead.
  result = SpeechSynthesizer(
    name: name,
    defaultVoice: defaultVoice,
    cacheDir: cacheDir,
    synthesizeFn: synthesizeFn,
  )
  if not dirExists(cacheDir):
    createDir(cacheDir)

proc synthesize*(s: SpeechSynthesizer, text: string,
                 voice = ""): SynthesisResult =
  ## Synthesizes `text`, returning a cached clip if one already exists for
  ## the same (text, voice) pair. The returned `audioPath` always points
  ## inside `s.cacheDir`, so it's safe to reuse across runs.
  let v = if voice.len > 0: voice else: s.defaultVoice
  let key = cacheKey(text, v)
  let cachePath = s.cacheDir / (key & ".wav")

  if fileExists(cachePath) and fileExists(cachePath & ".json"):
    return loadManifest(cachePath)

  # Call the backend and copy its output into the cache.
  result = s.synthesizeFn(text, v)
  if result.audioPath.len == 0 or not fileExists(result.audioPath):
    raise newException(ValueError, "Synthesizer '" & s.name &
                                "' produced no audio for text: " & text)
  if result.duration <= 0.0:
    result.duration = probeAudioDuration(result.audioPath)

  # Normalise into the cache location.
  if result.audioPath != cachePath:
    copyFile(result.audioPath, cachePath)
    # If the backend wrote its own temp file outside the cache, leave it;
    # caller can clean up /tmp separately.
  result.audioPath = cachePath
  saveManifest(cachePath, result)

# ---------------------------------------------------------------------------
# Default backend -- espeak-ng (or espeak as a legacy fallback). This is
# what `newVoiceoverScene(scene)` (no explicit synth) uses, and what
# `nimanim/voiceover` re-exports as `newDefaultSynthesizer`.
# ---------------------------------------------------------------------------

# Forward-declared here to avoid a circular import (`espeak.nim` imports
# `synth.nim`). The actual implementation is wired up at the bottom of
# `espeak.nim` via `registerDefaultSynthesizer`. Until that happens
# (which it always does when `nimanim/voiceover` is imported), calling
# this raises a clear error.
var defaultSynthFactory: proc(): SpeechSynthesizer {.closure.} = nil

proc registerDefaultSynthesizer*(factory: proc(): SpeechSynthesizer) =
  ## Called by backend modules (currently `espeak.nim`) to register the
  ## "default" backend -- i.e. the one returned by
  ## `newVoiceoverScene(scene)` when the caller doesn't pass an explicit
  ## synth. End users don't normally call this.
  defaultSynthFactory = factory

proc newDefaultSynthesizer*(): SpeechSynthesizer =
  ## Returns the package's default `SpeechSynthesizer` -- an espeak-ng
  ## instance (with espeak as legacy fallback). This is what
  ## `newVoiceoverScene(scene)` (no explicit synth) uses under the hood.
  ##
  ## End users normally don't need to call this directly; just import
  ## `nimanim/voiceover` and the default is wired in for you. Calling it
  ## before any backend module has been imported will raise a clear
  ## `ValueError` telling you to import one.
  if defaultSynthFactory == nil:
    raise newException(ValueError,
      "No default synthesizer is registered. Import a backend module " &
      "(e.g. `import nimanim/voiceover/espeak`) before calling " &
      "`newDefaultSynthesizer()` or `newVoiceoverScene(scene)` without " &
      "an explicit synth argument.")
  result = defaultSynthFactory()
