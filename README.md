# Qwen Reader

A macOS menu bar app that reads selected text aloud, in a natural default voice or a clone of
your own. Speech is generated on your Mac by
[Qwen3-TTS](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit) running on
[MLX](https://github.com/ml-explore/mlx-swift), so the text you read never leaves it.

- Select text in any app and press **⌃⌥S** to hear it. Speech starts in under a second.
- Clone a voice from 5–15 seconds of speech: record yourself, or import a clip.
- Reads English, Chinese, Japanese, Korean, German, French, Russian, Portuguese, Spanish and
  Italian, detecting the language by itself.
- No account and no cloud service. The only network use is the one-time model download.

## Requirements

- A Mac with Apple silicon, running macOS 15 or later
- About 4 GB of free disk space for the model
- 16 GB of memory recommended: the app uses about 3 GB idle and up to 6 GB while speaking

## Installing

Download the latest `Qwen-Reader-<version>.zip` from the Releases page, unzip it and move
**Qwen Reader** to your Applications folder. Or build it yourself; see [Building](#building).

## Setting up the voice model

The first time it opens, Qwen Reader asks for its voice model, a 3.1 GB download. There are two
ways to get it, in the setup window or from the menu bar icon's menu:

- **Download Model** fetches it from Hugging Face. The setup window, the menu and the menu bar
  icon show progress, with speed and time remaining. You can pause the download, or quit, and it
  carries on later from where it stopped. Each large file is checked against its published
  checksum.
- **Use a Model on Disk…** takes a copy you already have. Choose the model's folder, or any folder
  that contains it, such as Downloads or a Hugging Face cache folder; you can also drop the folder
  on the setup window. Qwen Reader makes its own copy, which on the same disk is instant and takes
  no extra space, so the original can be moved or deleted afterwards.

If the model is already in the Hugging Face cache (`~/.cache/huggingface/hub`), because another
tool or an earlier version of this app downloaded it, Qwen Reader finds it and uses it without
asking.

To fetch the model yourself, for a Mac that is offline for example:

```bash
hf download mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit --local-dir ~/Downloads/Qwen3-TTS-12Hz-1.7B-Base-8bit
```

The app is built for and tested with that model. Other MLX conversions of the Qwen3-TTS *Base*
model are accepted from disk but untested. The CustomVoice and VoiceDesign models are not
supported.

The model is kept in `~/Library/Application Support/Qwen Reader/Models`. **Model** in the menu
shows its size, reveals it in Finder, and deletes it.

## Using it

- Select text in any app and press **⌃⌥S** (Control+Option+S), or click the menu bar icon.
  Press or click again to stop.
- Or right-click the selection and choose **Services › Read Aloud with Qwen Reader**.
- Right-click (or Control-click) the menu bar icon for the menu: Pause/Resume, Stop, Voice, Speed,
  Language, Model and Launch at Login.
- Reading the same text again with the same voice plays instantly from a cache of about the last
  10 minutes of audio, at the current speed. **Replay Last Reading** does this without
  reselecting the text.
- Until the first words play, the menu bar speaker animates and a small "Preparing speech…" badge
  appears next to the pointer (turn it off with **Show Progress Near Pointer**).

### Voices

**Voice › Add or Manage Voices…** opens the Voices window. Record yourself reading the passage
shown, or import a clip and type exactly what is said in it. Use 5–15 seconds of clear speech
from one person, with no music or background noise. Voices are kept in
`~/Library/Application Support/Qwen Reader/Voices`.

Only clone a voice that is yours, or that you have permission to use.

### Permissions

- **Accessibility** lets the app read the selection, and fall back to copying it with ⌘C (your
  clipboard is restored afterwards). Allow it in System Settings › Privacy & Security ›
  Accessibility; the setup window and the menu both link there.
- **Microphone** is only needed to record a voice.
- The Services menu works without either permission.

### Memory

The model loads when the app starts and stays in memory so reads start quickly. **Model › Unload
After 30 Minutes Idle** frees it when you aren't using it; the next read reloads it, which takes
several seconds.

## Performance (M1 Max)

| | Default voice | Cloned voice |
|---|---|---|
| Time to first audio | ~0.3–0.4 s | ~0.4–0.9 s |
| Generation speed | ~0.44× real time | ~0.96× real time |
| Peak memory while speaking | ~5.7 GB | ~5.7 GB |

Anything below 1× keeps up with playback at normal speed. A cloned voice is only just fast
enough: it may stutter when the Mac is busy or at faster playback speeds.

## Building

Requires Xcode 26 with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
The build uses `xcodebuild` rather than `swift build`, because only Xcode compiles MLX's Metal
shaders.

```bash
./scripts/build.sh            # builds build/Qwen Reader.app
./scripts/build.sh --install  # also installs to ~/Applications and launches it
./scripts/build.sh --zip      # also makes a zip for sharing
```

The app is signed with your "Apple Development" certificate when you have one, so macOS keeps the
Accessibility permission across rebuilds; otherwise it is ad-hoc signed, and you may need to allow
Accessibility again after each rebuild. Set `CODESIGN_IDENTITY` to choose another certificate.

Unit tests need neither the model nor a network connection:

```bash
swift test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for more, including how to make a release.

## Layout

| Path | Role |
|---|---|
| `Sources/ReaderCore/` | No MLX dependency, so it is unit tested: sentence chunking, language detection, the audio cache, and downloading, checking and installing the model |
| `Sources/QwenReader/ModelLibrary.swift` | Whether the model is installed; runs downloads and imports |
| `Sources/QwenReader/Engine/TTSEngine.swift` | Loads, warms up and runs the model; caches cloned voices |
| `Sources/QwenReader/Engine/AudioPlayer.swift` | Streams audio through AVAudioEngine with pitch-preserving speed |
| `Sources/QwenReader/ReadingController.swift` | One read at a time: chunk, stream, play, cancel |
| `Sources/QwenReader/Input/` | ⌃⌥S hotkey (Carbon), selection reading (Accessibility, ⌘C fallback), Services menu |
| `Sources/QwenReader/AppModel.swift`, `UI/` | Settings, model lifecycle, menu bar, setup and Voices windows |

## Troubleshooting

- **Nothing happens on ⌃⌥S.** Check that Qwen Reader is allowed under System Settings › Privacy &
  Security › Accessibility. If the menu says the shortcut is unavailable, another app has taken it.
- **The download fails or stalls.** Choose **Resume Download**; it continues from where it
  stopped. Behind a proxy that blocks Hugging Face, download the model elsewhere and use
  **Use a Model on Disk…**.
- **"…is a Git LFS placeholder".** The folder was cloned with git without its large files. Run
  `git lfs pull` in it, or download the model from the app.
- **Logs.** `log stream --predicate 'subsystem == "io.github.hazit90.QwenReader"' --info`

## Acknowledgements and licences

Qwen Reader is released under the [MIT License](LICENSE).

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) by Alibaba's Qwen team, converted for MLX by
  [mlx-community](https://huggingface.co/mlx-community). The model weights are licensed
  Apache-2.0 and are downloaded separately, not distributed with this app.
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) (MIT), which implements the model.
- [MLX Swift](https://github.com/ml-explore/mlx-swift) (MIT).
