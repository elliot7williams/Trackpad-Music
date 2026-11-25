# Mac App Store submission

Use the **TrackpadMusic-AppStore** scheme to archive in Xcode. This scheme enables App Sandbox with read-only access to files selected in the macOS picker. It compiles out the private Force Touch motor integration and omits its controls. The regular **TrackpadMusic** scheme retains Bass Boost and Third Speaker for direct distribution.

## App Review notes

No account or special hardware is required. Open the supplied Bass Pulse WAV (or any local unprotected audio file) and press Play. The waveform and frequency meters update during playback. Enable Reactive Bass Synth, adjust Synth Mix, and seek or pause to verify that the synth follows the song.

## Before upload

- Select your Apple Developer team in Xcode, register or confirm the bundle ID, enable its MusicKit App Service, and create the macOS app record in App Store Connect.
- Publish the privacy policy and support content at public HTTPS URLs. Add a public support contact to the support page and enter both URLs in App Store Connect.
- Enter the listing fields and upload the two screenshots. Provide private App Review contact information and attach the demo WAV if desired.
- Complete the age-rating, privacy, accessibility, export-compliance, rights, pricing, and availability questionnaires for the actual submission. The app has no analytics, ads, or first-party accounts. Apple Music handles cloud-library requests and streams through MusicKit. Review the final archive and any added integrations before declaring data collection.
- Archive and validate with an App Store Connect–accepted Xcode version, then upload the signed archive. Set the release timing in App Store Connect.

References: [App Review guidelines](https://developer.apple.com/app-store/review/guidelines/), [platform metadata](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/), [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/), [app privacy](https://developer.apple.com/app-store/app-privacy-details/), and [uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).
