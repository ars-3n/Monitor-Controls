# Monitor Controls

A native macOS menu-bar app for external display brightness, speaker volume, and microphone controls. Each connected external monitor has its own brightness slider. Choose a sound output or microphone from the same panel.

## Use

Download [MonitorControls.zip from the latest release](https://github.com/ars-3n/MacOS-External-Monitor-Controls/releases/latest/download/MonitorControls.zip), unzip it, drag **Monitor Controls.app** into Applications, and open it. Click the monitor with three sound-level bars in the menu bar. The app requires a Mac with Apple silicon and macOS 14 or later.

Upgrading from Desk Controls? Quit the old app, move its copy out of Applications, then open **Monitor Controls.app** from Applications. Your device preferences carry over. If you use Open at Login, check its status in **Settings → General** after the move.

- **Brightness** adjusts the selected display as you drag. Monitor Controls checks the final brightness after you pause. Apple brightness keys adjust the display beneath the pointer.
- **Volume and mute** follow the current system sound output. Compatible monitor speakers use DDC/CI. AirPods and other system-adjustable outputs use macOS audio controls. When headphones disconnect, Monitor Controls leaves the monitor at its existing volume.
- **Microphone** lets you choose the macOS input, adjust gain and toggle mute when supported. An input chosen in another app that changes the system default is remembered until it disconnects or you choose another one.
- **Settings → Outputs** and **Settings → Microphones** show each device’s priority and visibility. A disconnected device has a trash button that removes it from the list. Existing Audio Priority Bar users can import saved device choices once. The source preferences remain available to the old app.
- **Settings → General** includes Open at Login, keyboard access, and manual monitor speaker pairing when a display output is active. Use manual pairing when displays have the same name or the output and display names differ.

The sliders work without Accessibility access. To use the Apple media keys, grant Monitor Controls access in **System Settings → Privacy & Security → Accessibility**. When trying these keys, quit MonitorControl or turn off its Apple key handling so that one app handles each keypress. Right-click the menu-bar icon to quit Monitor Controls.

Hardware controls depend on the monitor and connection. A dock that does not carry DDC/CI can leave brightness or speaker volume unavailable. Check the monitor’s own DDC/CI setting. Unsupported controls are shown in the panel.

## Build and test

Use Xcode with Swift 6.2 or later. Open `Package.swift` in Xcode, or run these commands from the repository root.

```sh
swift test
./scripts/build.sh
```

The build script produces an Apple silicon app in `dist/MonitorControls.zip`. It does not run on Intel Macs. GitHub Actions tests and packages each commit added to `main`, then publishes the ZIP in a release tagged with the app version and commit hash. These builds have no Developer ID signature or notarization.

The script signs the app ad hoc. macOS ties Accessibility access to the signature, so an ad-hoc build loses that access each time it replaces an older one. Remove Monitor Controls from the Accessibility list and add it again after updating. To keep access across your own builds, set `CODESIGN_IDENTITY` to the name of a signing certificate in your keychain.

```sh
CODESIGN_IDENTITY="My Signing Certificate" ./scripts/build.sh
```

GitHub Actions signs a release with a certificate when the repository has two secrets. `SIGNING_CERTIFICATE_P12` is a base64-encoded `.p12` export of a code signing certificate with its private key, and `SIGNING_CERTIFICATE_PASSWORD` is the export password. Without them the release is signed ad hoc. A self-signed certificate keeps Accessibility access across updates as long as every release uses the same one.

Normal tests use fixtures. On a Mac with exactly one LG ULTRAWIDE, an explicit hardware check reads the starting brightness, volume and mute, tests small changes, restores the originals, and verifies them. It briefly mutes the monitor if it was initially unmuted.

```sh
DESK_CONTROLS_TEST_LG=1 swift test --filter LGHardwareTests
```

## Source

The Swift app uses AppKit for the menu bar and SwiftUI for the panel. `AudioRouting` observes Core Audio devices, `DisplayHardware` serializes display communication, and `DeskPolicy` resolves speaker pairing and media-key ownership. `DisplayBridge` is a small C interface to the macOS display transports.

Monitor Controls incorporates work from Audio Priority Bar and MonitorControl. See [LICENSE](LICENSE) and [origin and license notices](Licenses/Origins.txt).
