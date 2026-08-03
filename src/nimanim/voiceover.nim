## nimanim/voiceover -- optional narration layer for nimanim.
##
## Importing this module gives you:
##   * `SpeechSynthesizer` and `WordBoundary` (the synthesizer interface),
##   * `VoiceoverScene` and the `voiceover` template (the user-facing API),
##   * The four bundled backends: `espeak` (default, espeak-ng or espeak),
##     `kokoro`, `coqui`, and `command`.
##   * `newDefaultSynthesizer()` -- the package default (espeak-ng).
##   * `mixVoiceoverSegments` (used internally, exposed for advanced users),
##   * `writeCaptions` / `buildCaptions` for SRT/VTT subtitle export.
##
## Backends are split into separate submodules so you only pay the import
## cost for the one you actually use. A typical scene only needs:
##
##   import nimanim
##   import nimanim/voiceover          # gives you `newVoiceoverScene(scene)`
##                                     # with espeak-ng as the default
##
## To swap to a different backend, import its module and pass it explicitly:
##
##   import nimanim/voiceover/kokoro
##   let scene = newVoiceoverScene(newScene(), newKokoroSynthesizer())
##
## See `examples/voiceover_scene.nim` for a runnable demo.

import ./voiceover/synth
import ./voiceover/mix
import ./voiceover/scene
import ./voiceover/espeak
import ./voiceover/kokoro
import ./voiceover/coqui
import ./voiceover/command
import ./voiceover/caption

export synth
export mix
export scene
export espeak
export kokoro
export coqui
export command
export caption
