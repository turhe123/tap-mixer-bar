# TapMixerBar — specification

**Tagline:** A menu bar mixer with one volume slider per app playing sound, no virtual audio driver needed.

**Category:** Audio

**Inspired by (paid):** Fabar ($9.99 one-time)

**Frameworks:** SwiftUI, AppKit, CoreAudio, AudioToolbox, AVFoundation, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: Fabar is a direct-download menu bar app sold for 9.99 dollars one-time on Product Hunt, with a 30-day refund. It gives every app that is making sound its own volume slider, and it works without installing a kernel extension or a virtual audio device. Demand is shown by a stack of similar launches, such as VolumeHub and Volume Mixer, plus long-running requests for per-app volume that macOS still does not offer, and by the long history of SoundSource and Sound Control being the go-to answer on forums. Our clean-room version is a free alternative built only on Apple frameworks.

Feature set: List every running app that currently produces audio. Show an icon, name, a volume slider from zero to 150 percent, and a mute button for each. Remember each app's level by bundle identifier and re-apply it when the app next plays sound. Include a master reset button and a toggle to hide apps that are silent. Optional hotkey to mute everything except the frontmost app. Keep the scope to roughly 500 lines.

UI spec: A MenuBarExtra with window style showing a vertical list of rows. Each row has the app icon, name, a slider, a percent label, and a mute toggle. At the bottom sit a Reset All button, a Settings button and Quit. The empty state reads Nothing is playing right now, with a small speaker glyph. The settings window has three fields: Launch at login, Show silent apps, and Maximum boost with choices 100, 125 and 150 percent. The menu bar icon changes to a slashed speaker if any app is muted.

Technical approach: Use the Core Audio process tap API introduced in macOS 14.2. Enumerate audio process objects through the process object list property on the system object, read each one's bundle identifier and running-output flag, and create a tap description for the chosen process with the mute behavior set so the original stream is silenced. Wrap the tap in a private aggregate device that contains the current default output device, attach an IO proc, and in that callback multiply the sample buffers by the stored gain with soft clipping above full scale before writing to the output buffers. Rebuild the aggregate device when the default output device changes, which is detected through a property listener on the default output device selector. Permission: the first tap triggers the system audio capture prompt, so add the audio capture usage description string to the Info file and show a friendly explanation view before the first tap is created. Persist gains in UserDefaults as a dictionary keyed by bundle identifier. Launch at login uses SMAppService main app registration. Because macOS 14.2 is the minimum for taps, declare that in the README and degrade gracefully by showing an unsupported notice on 14.0 and 14.1.

Edge cases and error handling: If a tapped app quits, tear down its tap and aggregate device immediately to avoid leaks. If tap creation fails, for example because permission was denied, show an inline banner with a button that opens the Privacy settings pane. Protect against feedback by never tapping this app's own process. When a gain of exactly 100 percent is stored, skip creating a tap at all to avoid needless latency. Handle sample rate changes mid-stream by recreating the IO proc. Clamp stored values to the valid range, and ignore apps whose audio is protected, showing them with a lock icon and a disabled slider.
