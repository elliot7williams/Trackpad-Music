# Trackpad Music

Trackpad Music is a standalone macOS player for local audio files. Open an MP3, M4A, WAV, AIFF, or another audio file that macOS can decode. Normal audio playback is available while the app analyzes the track.

**Live audio** plots the recorded waveform and shows separate bass, midrange, and treble levels. **Reactive bass synth** adds a speaker layer that follows the song’s detected bass pitch and level. Use **Synth mix** to blend it into the song.

- **Bass Boost** follows the song’s low frequencies through a Force Touch trackpad.
- **Third Speaker** mixes the strongest bass, midrange, and treble tones from each short slice of the song. The trackpad plays a simplified rendition of the mix.
- **Off** disables trackpad output. Clear **Speakers** to listen to the trackpad by itself, and use **Intensity** to adjust the haptic level.

Use the built-in Force Touch trackpad or choose **Magic Trackpad** to connect an external Magic Trackpad 2 or newer. The motor uses a private macOS framework, so compatibility depends on macOS and trackpad hardware. Speaker playback works independently of the motor.

Open `TrackpadMusic.xcodeproj` in Xcode and run the **TrackpadMusic** scheme. To build a local release from this directory, run:

```sh
xcodebuild -project TrackpadMusic.xcodeproj -scheme TrackpadMusic \
    -configuration Release -destination 'generic/platform=macOS' \
    CONFIGURATION_BUILD_DIR="$PWD/build" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
open "build/Trackpad Music.app"
```

## Mac App Store

The **TrackpadMusic-AppStore** scheme builds a sandboxed player with the live visualizer and reactive synth. The direct build includes the Force Touch modes. See [App Store preparation](AppStore/Submission.md) for the listing, screenshots, review demo, and upload requirements.
