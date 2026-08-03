## Kokoro speech synthesizer backend.
##
## [Kokoro](https://github.com/hexgrad/kokoro) is a high-quality open-source
## neural TTS (StyleTTS2-based, ~85M params) with permissive Apache-2.0
## weights. It exposes word-level timestamps via the Python
## [`kokoro`](https://pypi.org/project/kokoro/) package, which makes it
## ideal for accurate captioning.
##
## Because Kokoro is a Python library, this backend shells out to a small
## Python script that:
##   1. Loads the Kokoro pipeline (cached by the Python side),
##   2. Synthesizes the text to a WAV,
##   3. Emits a JSON manifest with `duration`, `sample_rate`, and `words`.
##
## Setup (one-time, in any virtualenv that the `python3` on your PATH can
## see):
##
##   pip install kokoro>=0.9 misaki[en]>=0.9.1 soundfile
##
## If the import fails at runtime, the backend raises a clear error with
## the install hint -- it does NOT silently fall back.
##
## Example:
##
##   import nimanim/voiceover/kokoro
##   let synth = newKokoroSynthesizer(voice = "af_heart")

import std/[os, osproc, strutils, streams, json]
import ./synth

# The Python helper script. It runs as `python3 -c <script>` with the text
# and voice passed as argv to avoid shell-escaping pitfalls. Output is one
# JSON object on stdout: {"audio": "<path>", "duration": f, "sample_rate": i,
# "words": [{"text": s, "start": f, "end": f}, ...]}.
const kokoroHelper = """
import json, os, sys, tempfile, warnings
warnings.filterwarnings("ignore")

def main():
    text = sys.argv[1]
    voice = sys.argv[2] or "af_heart"
    out_dir = sys.argv[3]
    try:
        from kokoro import KPipeline
    except Exception as e:
        print(json.dumps({"error": "import_failed", "detail": str(e)}))
        sys.exit(2)
    try:
        import soundfile as sf
    except Exception as e:
        print(json.dumps({"error": "import_failed", "detail": "soundfile: " + str(e)}))
        sys.exit(2)

    pipe = KPipeline(lang_code="a")  # 'a' = American English; override as needed
    out_path = os.path.join(out_dir, "kokoro_out.wav")
    gs, ps, audio = pipe(text, voice=voice)
    sf.write(out_path, audio, 24000)

    # Build word boundaries from the per-grapheme chunk list. `gs` is a
    # list of (graphemes, phonemes) pairs; their lengths in audio sum to
    # `len(audio)/24000` seconds. We approximate per-word timing by
    # splitting on whitespace inside each chunk.
    words = []
    t = 0.0
    total = len(audio) / 24000.0
    chunk_dur = total / max(1, len(gs))
    for i, (graphemes, _phonemes) in enumerate(gs):
        chunk_start = t
        chunk_end = t + chunk_dur
        toks = graphemes.split()
        if len(toks) == 0:
            t = chunk_end
            continue
        per = (chunk_end - chunk_start) / len(toks)
        for j, w in enumerate(toks):
            words.append({
                "text": w,
                "start": chunk_start + j * per,
                "end": chunk_start + (j + 1) * per,
            })
        t = chunk_end
    print(json.dumps({
        "audio": out_path,
        "duration": total,
        "sample_rate": 24000,
        "words": words,
    }))

main()
"""

proc runKokoro(text, voice, workDir: string): SynthesisResult =
  let p = startProcess("python3",
                       args = @["-c", kokoroHelper, text, voice, workDir],
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
            "Kokoro backend error: " & j["detail"].getStr() &
            "\nInstall with: pip install kokoro misaki[en] soundfile")
      except JsonParsingError:
        discard
    raise newException(ValueError,
      "python3 failed (rc=" & $rc & ") running Kokoro. " &
      "Install with: pip install kokoro misaki[en] soundfile. " &
      "Output: " & outStr)

  if outStr.len == 0:
    raise newException(ValueError, "Kokoro backend produced no output")

  let j = parseJson(outStr)
  if j.hasKey("error"):
    raise newException(ValueError,
      "Kokoro backend error: " & j["detail"].getStr() &
      "\nInstall with: pip install kokoro misaki[en] soundfile")

  result.audioPath = j["audio"].getStr()
  result.duration = j["duration"].getFloat()
  result.sampleRate = j["sample_rate"].getInt()
  if j.hasKey("words"):
    for w in j["words"]:
      result.words.add(WordBoundary(
        text: w["text"].getStr(),
        start: w["start"].getFloat(),
        `end`: w["end"].getFloat(),
      ))

proc newKokoroSynthesizer*(voice = "af_heart",
                            cacheDir = "media/voiceover_cache",
                            workDir = ""): SpeechSynthesizer =
  ## Builds a `SpeechSynthesizer` backed by the Python `kokoro` package.
  ##
  ## `voice` is a Kokoro voice code (e.g. `af_heart`, `am_michael`,
  ## `bf_alice`, `bm_george`). See the Kokoro repo for the full list.
  ##
  ## `workDir` is where the Python helper writes its temp WAV; defaults
  ## to a `kokoro_tmp` subdirectory of `cacheDir`.
  let captureVoice = voice
  let captureWorkDir = if workDir.len > 0: workDir else: cacheDir / "kokoro_tmp"
  if not dirExists(captureWorkDir):
    createDir(captureWorkDir)

  proc fn(text: string, v: string): SynthesisResult {.closure.} =
    let useVoice = if v.len > 0: v else: captureVoice
    runKokoro(text, useVoice, captureWorkDir)

  result = newSpeechSynthesizer(
    name = "kokoro",
    synthesizeFn = fn,
    defaultVoice = voice,
    cacheDir = cacheDir,
  )
