## eSpeak / eSpeak-NG speech synthesizer backend.
##
## [eSpeak-NG](https://github.com/espeak-ng/espeak-ng) is a modern fork of
## eSpeak with more languages, better pronunciation, and active
## maintenance. It's the **default backend** for `nimanim/voiceover` --
## when you call `newEspeakSynthesizer()`, this module automatically uses
## `espeak-ng` if it's on your PATH, falling back to the older `espeak`
## binary if not. Either way, the user-facing API is identical.
##
## Install one of:
##
##   sudo apt-get install espeak-ng       # Debian/Ubuntu (preferred)
##   sudo apt-get install espeak          # Debian/Ubuntu (legacy fallback)
##   brew install espeak                  # macOS
##
## Quality is robotic compared to neural TTS (Kokoro, Coqui), but it's
## perfect for development / scratch renders, and it has zero setup cost
## beyond the system package. The CLI doesn't expose word-level
## timestamps, so we approximate them by distributing the clip's duration
## evenly across the whitespace-split words of the input. This is the
## same fallback `manim-voiceover`'s pyttsx3 service uses; the resulting
## captions are good enough for development.
##
## Example:
##
##   import nimanim/voiceover/espeak
##   let synth = newEspeakSynthesizer(voice = "en", speed = 160)

import std/[os, osproc, strutils, streams]
import ./synth

# ---------------------------------------------------------------------------
# Binary detection -- prefer `espeak-ng`, fall back to `espeak`. The choice
# is made lazily on first synthesis (not at construction time) so the
# synth object is still usable if the binary is installed after the scene
# is built (e.g. in a Docker build that adds the package late).
# ---------------------------------------------------------------------------

proc findEspeakBinary(): string =
  ## Returns "espeak-ng" if available, otherwise "espeak". Raises
  ## `OSError` if neither is on PATH -- the caller (the synth closure)
  ## turns this into a clear ValueError pointing at install instructions.
  for candidate in ["espeak-ng", "espeak"]:
    let p = startProcess("which", args = @[candidate],
                         options = {poUsePath, poStdErrToStdOut})
    let outStr = p.outputStream().readAll().strip()
    discard p.waitForExit()
    p.close()
    if outStr.len > 0 and fileExists(outStr):
      return candidate
  raise newException(OSError,
    "Neither `espeak-ng` nor `espeak` found on PATH. " &
    "Install with: apt-get install espeak-ng   (or: brew install espeak)")

# Cache the lookup so we don't fork `which` on every `say()` call.
var cachedBinary: string = ""
proc espeakBinary(): string =
  if cachedBinary.len == 0:
    cachedBinary = findEspeakBinary()
  result = cachedBinary

proc espeakSynthesize(text, voice, outPath: string, speed: int,
                      pitch: int, capGain: int): string =
  ## Runs `<espeak-ng|espeak> -w <out> "<text>"` and returns `outPath`
  ## on success, "" on failure.
  let bin = espeakBinary()
  var args = @["-w", outPath]
  if voice.len > 0:
    args.add(@["-v", voice])
  if speed > 0:
    args.add(@["-s", $speed])
  if pitch != 0:
    args.add(@["-p", $pitch])
  if capGain != 0:
    args.add(@["-k", $capGain])
  args.add(text)

  let p = startProcess(bin, args = args,
                       options = {poUsePath, poStdErrToStdOut})
  discard p.outputStream().readAll()
  let rc = p.waitForExit()
  p.close()
  if rc != 0 or not fileExists(outPath):
    return ""
  result = outPath

proc splitWordsEvenly(text: string, duration: float): seq[WordBoundary] =
  ## Splits `text` on whitespace and spreads `duration` seconds evenly
  ## across the resulting words. Used as a fallback when the TTS backend
  ## doesn't expose word-level timing.
  let words = text.splitWhitespace()
  if words.len == 0 or duration <= 0.0:
    return @[]
  result = newSeq[WordBoundary](words.len)
  let per = duration / words.len.float
  for i, w in words:
    result[i] = WordBoundary(
      text: w,
      start: per * i.float,
      `end`: per * (i.float + 1.0),
    )

proc newEspeakSynthesizer*(voice = "en", speed = 160, pitch = 0,
                            capGain = 0,
                            cacheDir = "media/voiceover_cache"): SpeechSynthesizer =
  ## Builds a `SpeechSynthesizer` backed by `espeak-ng` (preferred) or
  ## `espeak` (legacy fallback). The binary actually used is autodetected
  ## at first synthesis call; both binaries share the same CLI flags so
  ## the choice is invisible to user code.
  ##
  ## `voice` is an espeak voice code (`en`, `en-gb`, `fr`, `de`, ...);
  ## run `espeak-ng --voices` to see them all. `speed` is
  ## words-per-minute (default 160, espeak's own default). `pitch` and
  ## `capGain` adjust tone and capital-letter emphasis respectively.
  let captureVoice = voice
  let captureSpeed = speed
  let capturePitch = pitch
  let captureCapGain = capGain

  proc fn(text: string, v: string): SynthesisResult {.closure.} =
    let useVoice = if v.len > 0: v else: captureVoice
    let tmpPath = getTempDir() / "nimanim_espeak_" & $os.getCurrentProcessId() & ".wav"
    try:
      discard espeakSynthesize(text, useVoice, tmpPath,
                                captureSpeed, capturePitch, captureCapGain)
    except OSError as e:
      raise newException(ValueError, e.msg)
    if not fileExists(tmpPath):
      raise newException(ValueError, "espeak-ng/espeak failed to produce audio for: " & text)
    let dur = probeAudioDuration(tmpPath)
    result = SynthesisResult(
      audioPath: tmpPath,
      duration: dur,
      sampleRate: 22050,
      words: splitWordsEvenly(text, dur),
    )

  # Pick the display name now (not lazily) so log messages and errors are
  # accurate even before the first synthesis call -- but tolerate the case
  # where neither binary is installed yet (caller will get a clear error
  # on first `say()` instead of at construction time).
  var displayName = "espeak"
  try:
    displayName = espeakBinary()
  except OSError:
    displayName = "espeak-ng (not yet installed)"

  result = newSpeechSynthesizer(
    name = displayName,
    synthesizeFn = fn,
    defaultVoice = voice,
    cacheDir = cacheDir,
  )

# ---------------------------------------------------------------------------
# Register as the package default. `newVoiceoverScene(scene)` (no explicit
# synth) and `newDefaultSynthesizer()` both call this factory.
# ---------------------------------------------------------------------------
registerDefaultSynthesizer(proc(): SpeechSynthesizer =
  newEspeakSynthesizer())
