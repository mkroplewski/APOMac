# APOMac

APOMac is a native macOS system audio equalizer with Equalizer APO-compatible configuration files.

The project targets macOS 15 or newer on Apple Silicon and uses SwiftUI, Core Audio taps, and Accelerate/vDSP. The processing engine is a platform port of Equalizer APO behavior; it is distributed under GPL-2.0-only with the required attribution and source obligations.

## Current compatibility boundary

The engine supports the documented post-mix configuration commands: `Preamp`, `Filter`, `IIR`, `Delay`, `Copy`, `GraphicEQ`, `Convolution`, `Include`, `Channel`, `Device`, `If`/`ElseIf`/`Else`/`EndIf`, `Eval`, and inline expressions. Windows-only registry expressions, pre-mix/capture stages, VST plug-ins, and Equalizer APO extensions are preserved and reported as diagnostics.

## Build

```sh
swift build
swift test
swift run APOMacApp
```

The Core Audio tap requires the application bundle to declare `NSAudioCaptureUsageDescription` and the user to grant system-audio recording permission. For a local app bundle:

```sh
./scripts/package-app.sh
MAKE_DMG=1 ./scripts/package-app.sh
```

Set `CODESIGN_IDENTITY` for a Developer ID signature. Notarization requires the normal Apple notarytool credentials and is intentionally kept outside the source build.

The app starts with an empty profile library. Use `New Profile` or import a complete profile directory from the sidebar. Simple profiles containing gain/preamp stages, supported biquads, and delays can be added, edited, and removed from the visual filter chain; profiles with includes, conditionals, channel routing, convolution, or other source-level behavior remain source-editable with a read-only effective graph. Raw edits receive a debounced response preview, while Apply & Reload activates them in the audio session.

`APOCompiler` returns `ConfigurationDiagnostics` because Swift's `Result` requires its failure type to conform to `Error`; its `diagnostics` property is the complete `[ConfigurationDiagnostic]` list.
