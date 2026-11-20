# Desk Controls

A native macOS menu-bar app for external display brightness, speaker volume, and microphone controls. Each connected external monitor has its own brightness slider. Choose a sound output or microphone from the same panel.

## Use

Unzip `DeskControls.zip`, drag **Desk Controls.app** into Applications, and open it. Click the monitor with three sound-level bars in the menu bar. The app requires macOS 14 or later.

- **Brightness** adjusts the selected display’s hardware brightness. Apple brightness keys adjust the display beneath the pointer.
- **Volume and mute** follow the current system sound output. Compatible monitor speakers use DDC/CI. AirPods and other system-adjustable outputs use macOS audio controls. When headphones disconnect, Desk Controls leaves the monitor at its existing volume.
- **Microphone** lets you choose the macOS input, adjust gain and toggle mute when supported. An input chosen in another app that changes the system default is remembered until it disconnects or you choose another one.
- **Settings → Devices** manages device priority and visibility. Existing Audio Priority Bar users can import saved device choices once. The source preferences remain available to the old app.
- **Settings → General** includes Open at Login, keyboard access, and manual monitor speaker pairing when a display output is active. Use manual pairing when displays have the same name or the output and display names differ.

The sliders work without Accessibility access. To use the Apple media keys, grant Desk Controls access in **System Settings → Privacy & Security → Accessibility**. When trying these keys, quit MonitorControl or turn off its Apple key handling so that one app handles each keypress. Right-click the menu-bar icon to quit Desk Controls.

Hardware controls depend on the monitor and connection. A dock that does not carry DDC/CI can leave brightness or speaker volume unavailable. Check the monitor’s own DDC/CI setting. Unsupported controls are shown in the panel.

## Build and test

Use Xcode with Swift 6.2 or later. Open `Package.swift` in Xcode, or run these commands from the repository root.

```sh
swift test
./scripts/build.sh
```

The build script produces a universal Apple silicon and Intel app in `dist/DeskControls.zip`. Development builds have no Developer ID signature or notarization.

Normal tests use fixtures. On a Mac with exactly one LG ULTRAWIDE, an explicit hardware check reads the starting brightness, volume and mute, tests small changes, restores the originals, and verifies them. It briefly mutes the monitor if it was initially unmuted.

```sh
DESK_CONTROLS_TEST_LG=1 swift test --filter LGHardwareTests
```

## Source

The Swift app uses AppKit for the menu bar and SwiftUI for the panel. `AudioRouting` observes Core Audio devices, `DisplayHardware` serializes display communication, and `DeskPolicy` resolves speaker pairing and media-key ownership. `DisplayBridge` is a small C interface to the macOS display transports.

Desk Controls incorporates work from Audio Priority Bar and MonitorControl. See [LICENSE](LICENSE) and [origin and license notices](Licenses/Origins.txt).
