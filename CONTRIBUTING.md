# Contributing

Bug reports and pull requests are welcome.

## Building and testing

You need an Apple Silicon Mac, macOS 15 or later, and Xcode 26 with the Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

```bash
swift test                    # unit tests; no model or network needed
./scripts/build.sh --install  # build, install to ~/Applications and launch
```

The tests cover `Sources/ReaderCore`, which has no MLX dependency: text chunking, language
detection, the audio cache, and downloading and installing the model (against a stub server).
Keep logic that can be tested without the model there.

Anything that touches speech, the menu or the windows needs trying by hand in the built app. To
go through first-run setup again, choose **Model › Delete Model…** from the menu, or delete
`~/Library/Application Support/Qwen Reader/Models`.

## Pull requests

- Keep changes focused, and say how you tested them.
- Match the surrounding style: comments explain why, not what.
- Update the README when behaviour that users see changes.

## Making a release

1. Set the version in `App/Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`).
2. Build and zip with a Developer ID certificate, so other Macs will open the app:

   ```bash
   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build.sh --zip
   ```

3. Notarize the zip, staple the ticket to the app, and zip it again:

   ```bash
   xcrun notarytool submit build/Qwen-Reader-<version>.zip --keychain-profile <profile> --wait
   xcrun stapler staple "build/Qwen Reader.app"
   ditto -c -k --keepParent "build/Qwen Reader.app" build/Qwen-Reader-<version>.zip
   ```

4. Attach the zip to a GitHub release.

A build signed without a Developer ID still runs on other Macs, but they have to allow it under
System Settings › Privacy & Security › Open Anyway the first time.

## Changing the model

The model is pinned in `Sources/ReaderCore/VoiceModel.swift`: repository, commit and download
size. After changing it, download it in the app from scratch and check a read with the default
voice and with a cloned one.
