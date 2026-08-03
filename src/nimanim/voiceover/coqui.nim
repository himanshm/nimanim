## Coqui TTS speech synthesizer backend.
##
## [Coqui TTS](https://github.com/coqui-ai/TTS) is a Python library
## providing access to a wide range of neural TTS models -- XTTS, VITS,
## Glow-TTS, Tacotron2, YourTTS, and more. It's a strong choice when you
## want high-quality, locally-run, permissively-licensed narration and
## don't mind the (significant) Python install footprint.
##
## Setup (one-time, in any virtualenv that the `python3` on your PATH can
## see):
##
##   pip install TTS soundfile
##
## Models are downloaded automatically on first use to
## `~/.local/share/tts/`. The first synthesis of a new model can take a
## while (download + torch warm-up); subsequent calls are fast and
## cached on disk by nimanim, so re-rendering a scene after the first
## run is essentially free.
##
## Word-level timing: Coqui's high-level `TTS.api.tts_to_file` doesn't
## expose timestamps, so we approximate them by distributing the clip's
## duration evenly across the whitespace-split words of the input -- the
## same fallback the espeak/command backends use. (The lower-level
## `Synthesizer` class can return attention alignments, but those aren't
## reliable across all model families, so we don't use them.)
##
## Example:
##
##   import nimanim/voiceover/coqui
##   # XTTS v2 (multilingual, multi-speaker, ~1.5GB download first run)
##   let synth = newCoquiSynthesizer(
##     modelName = "tts_models/multilingual/multi-dataset/xtts_v2",
##     speaker = "Ana Florence",
##     language = "en",
##   )
##   # Or a small single-speaker model (~100MB download):
##   # let synth = newCoquiSynthesizer(
##   #   modelName = "tts_models/en/ljspeech/glow-tts")

import std/[os, osproc, strutils, streams, json]
import ./synth

# The Python helper script. It runs as `python3 -c <script>` with the
# text and config passed as argv to avoid shell-escaping pitfalls.
# Output is one JSON object on stdout:
#   {"audio": "<wav path>", "duration": f, "sample_rate": i, "words": [...]}
# or {"error": "...", "detail": "..."} on failure.
const coquiHelper = """
import json, os, sys, tempfile, warnings
warnings.filterwarnings("ignore")

def main():
    text = sys.argv[1]
    model_name = sys.argv[2]
    speaker = sys.argv[3] or None
    language = sys.argv[4] or None
    out_dir = sys.argv[5]
    use_cuda = sys.argv[6] == "1"
    out_path = os.path.join(out_dir, "coqui_out.wav")

    try:
        from TTS.api import TTS
    except Exception as e:
        print(json.dumps({"error": "import_failed", "detail":
            "TTS package not installed: " + str(e) +
            " -- install with: pip install TTS soundfile"}))
        sys.exit(2)

    try:
        # `progress=False` keeps stdout clean so we can parse JSON.
        tts = TTS(model_name=model_name, progress=False, gpu=use_cuda)
    except Exception as e:
        print(json.dumps({"error": "model_load_failed", "detail": str(e)}))
        sys.exit(2)

    # Build kwargs only for the args this model actually accepts. Coqui's
    # `tts_to_file` will reject unknown kwargs (e.g. `speaker` on a
    # single-speaker model), so we probe the model's capabilities first.
    kwargs = {"text": text, "file_path": out_path}
    if speaker is not None and getattr(tts, "speakers", None):
        kwargs["speaker"] = speaker
    if language is not None and getattr(tts, "languages", None):
        kwargs["language"] = language

    try:
        tts.tts_to_file(**kwargs)
    except Exception as e:
        print(json.dumps({"error": "synthesis_failed", "detail": str(e)}))
        sys.exit(2)

    if not os.path.exists(out_path):
        print(json.dumps({"error": "synthesis_failed",
                          "detail": "TTS did not produce output file"}))
        sys.exit(2)

    # Read sample rate from the WAV header so the caller's cache manifest
    # is accurate. Coqui writes 16-bit PCM mono at the model's native rate
    # (typically 22050 or 24000 Hz).
    sample_rate = 0
    try:
        import wave
        with wave.open(out_path, "rb") as wf:
            sample_rate = wf.getframerate()
    except Exception:
        pass

    print(json.dumps({
        "audio": out_path,
        "duration": 0.0,  # let nimanim probe via ffprobe
        "sample_rate": sample_rate,
        "words": [],  # even-distribution fallback in Nim
    }))

main()
"""

proc runCoqui(text, modelName, speaker, language, workDir: string,
              useCuda: bool): SynthesisResult =
  let cudaFlag = if useCuda: "1" else: "0"
  let p = startProcess("python3",
                       args = @["-c", coquiHelper, text, modelName, speaker,
                                language, workDir, cudaFlag],
                       options = {poUsePath, poStdErrToStdOut})
  let outStr = p.outputStream().readAll().strip()
  let rc = p.waitForExit()
  p.close()

  if rc != 0:
    if outStr.len > 0:
      try:
        let j = parseJson(outStr)
        if j.hasKey("detail"):
          raise newException(ValueError,
            "Coqui TTS backend error: " & j["detail"].getStr() &
            "\nInstall with: pip install TTS soundfile")
      except JsonParsingError:
        discard
    raise newException(ValueError,
      "python3 failed (rc=" & $rc & ") running Coqui TTS. " &
      "Install with: pip install TTS soundfile. " &
      "Output: " & outStr)

  if outStr.len == 0:
    raise newException(ValueError, "Coqui TTS backend produced no output")

  let j = parseJson(outStr)
  if j.hasKey("error"):
    raise newException(ValueError,
      "Coqui TTS backend error: " & j["detail"].getStr() &
      "\nInstall with: pip install TTS soundfile")

  result.audioPath = j["audio"].getStr()
  result.duration = j["duration"].getFloat()
  result.sampleRate = j["sample_rate"].getInt()
  # Word boundaries: Coqui's high-level API doesn't expose them reliably,
  # so we leave them empty here and let `splitWordsEvenly` (called by
  # the caption module / synth cache layer) approximate from text length.

proc splitWordsEvenly(text: string, duration: float): seq[WordBoundary] =
  ## Splits `text` on whitespace and spreads `duration` seconds evenly
  ## across the resulting words. (Same implementation as the espeak
  ## backend -- duplicated here so this module is self-contained.)
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

proc newCoquiSynthesizer*(modelName = "tts_models/en/ljspeech/glow-tts",
                           speaker = "",
                           language = "",
                           useCuda = false,
                           cacheDir = "media/voiceover_cache",
                           workDir = ""): SpeechSynthesizer =
  ## Builds a `SpeechSynthesizer` backed by the Python `TTS` (Coqui)
  ## package.
  ##
  ## `modelName` is a Coqui model identifier. Some good defaults:
  ##   * `"tts_models/en/ljspeech/glow-tts"` -- small, fast, ~100MB,
  ##     single-speaker (American female), great for development.
  ##   * `"tts_models/en/ljspeech/tacotron2-DDC"` -- slower, slightly
  ##     more natural than glow-tts.
  ##   * `"tts_models/multilingual/multi-dataset/xtts_v2"` -- ~1.5GB,
  ##     multilingual + multi-speaker; pass `speaker` and `language`.
  ## Browse all available models with `python3 -c "from TTS.api import TTS;
  ## print(TTS().list_models())"`.
  ##
  ## `speaker` and `language` are only used by multi-speaker /
  ## multilingual models (XTTS, YourTTS, etc.); they're silently ignored
  ## for single-speaker models so the same scene code works either way.
  ##
  ## `useCuda = true` lets Coqui use a CUDA GPU if available (much faster
  ## for large models). Default is `false` for portability -- flip to
  ## `true` once you've confirmed your environment has torch+CUDA.
  ##
  ## `workDir` is where the Python helper writes its temp WAV; defaults
  ## to a `coqui_tmp` subdirectory of `cacheDir`.
  let captureModel = modelName
  let captureSpeaker = speaker
  let captureLanguage = language
  let captureCuda = useCuda
  let captureWorkDir = if workDir.len > 0: workDir else: cacheDir / "coqui_tmp"
  if not dirExists(captureWorkDir):
    createDir(captureWorkDir)

  proc fn(text: string, v: string): SynthesisResult {.closure.} =
    # Coqui models don't have a per-call "voice" concept the way espeak
    # does -- the model + speaker + language chosen at construction time
    # fully determine the voice. We accept `v` for API symmetry with the
    # other backends but ignore it. (If you want multiple voices in one
    # scene, construct multiple Coqui synthesizers.)
    result = runCoqui(text, captureModel, captureSpeaker, captureLanguage,
                      captureWorkDir, captureCuda)
    if result.duration <= 0.0:
      result.duration = probeAudioDuration(result.audioPath)
    result.words = splitWordsEvenly(text, result.duration)

  result = newSpeechSynthesizer(
    name = "coqui:" & modelName,
    synthesizeFn = fn,
    defaultVoice = speaker,  # for Coqui, "voice" is really the speaker name
    cacheDir = cacheDir,
  )
