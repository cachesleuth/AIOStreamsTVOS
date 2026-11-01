# AIOStreams for Apple TV

The [AIOStreams](https://github.com/Viren070/AIOStreams) web app's standalone build (the one that
signs in to any Jellyfin server) on tvOS, playing through mpv. The page draws every screen and the
player's controls, unchanged; this app shows it in a web view over libmpv, as the desktop and
Android apps do, and turns the Siri Remote into the keys the page already handles.

It is unofficial and experimental. It uses private tvOS APIs, so it can't go on the App Store and is
installed from Xcode.

## How it fits together

```
┌──────────────────────────── screen ────────────────────────────┐
│  UIWebView, transparent: the web app and its player controls   │
│        ▲  window.aiostreamsApp: JSON messages both ways        │
│  CAMetalLayer: mpv's frames (gpu-next, Vulkan on MoltenVK)     │
└────────────────────────────────────────────────────────────────┘
```

- **The page** is `packages/web`'s standalone build, bundled in the app. `AppURLProtocol` serves it
  at `http://aiostreams.localhost/`, so it has an origin of its own for sign-ins and settings, and can
  reach plain-http servers on the local network.
- **The web view** is tvOS's UIWebView. Apple leaves it out of the tvOS SDK but the system still ships
  it; `LegacyWebView` makes one through the Objective-C runtime.
- **The bridge** is the page's `window.aiostreamsApp`, which `BridgeScript` puts into `index.html`
  ahead of the page's own scripts. Page to app goes through a function the app puts into the page's
  JavaScript context (`JSContextHook`); app to page through `stringByEvaluatingJavaScriptFromString:`.
- **mpv** comes from [MPVKit](https://github.com/mpvkit/MPVKit) (the LGPL build). `MPVEngine` and
  `PlayerChannel` follow AIOStreams' Android `MpvEngine` and `PlayerChannel`: the same options,
  observed properties and messages.

### Posing as the Android TV app

The web app picks its behaviour from the bridge's `platform`, and only knows `android`, `windows`,
`macos` and `linux`. To leave the AIOStreams repo untouched, this app reports itself as the Android
app on a TV (`platform: 'android'`, `tv: true`). That gets the TV layout, remote navigation, the
Back behaviour and the bundled-player path. It also means:

- Jellyfin lists the device as **AIOStreams Android TV**.
- Settings shows an **Android app** section. Its mpv.conf editor works; updates show as off.
- Android-only playback settings (frame rate matching, tunnelling) show and do nothing.
- The statistics overlay shows nothing: it needs mpv's Lua scripts, which tvOS's libmpv lacks.

A `tvos` host in the web app itself would remove all of these; it's a small change there if the
AIOStreams maintainers want one.

## The remote

| Siri Remote                   | Page sees                                     |
| ----------------------------- | --------------------------------------------- |
| Swipe or click the clickpad's edges | Arrow keys (held edges repeat)          |
| Select                        | Select; held, the item's menu                 |
| Select on a text field        | tvOS's keyboard, with dictation on the mic button |
| Back / Menu                   | Back; twice on Home leaves the app            |
| Play/Pause                    | Play/Pause                                    |
| Channel up/down (some remotes)| Next/previous chapter                         |

The player's own keys apply as on any TV: left and right skip, Select shows the controls.

Voice: the page's own voice search needs a speech recogniser, which tvOS doesn't give apps, so it's
off. Dictation works in any field through the system keyboard.

## External players

Settings → Playback → Player lists Infuse, VLC and Outplayer (the app reports an iPad user agent so
the page offers the iOS presets), or a custom link. Play opens the link with `UIApplication.open`.
Infuse's `x-success` callback, `aiostreams://return/item/…`, comes back to this app, which hands it
to the page; the page saves where you stopped.

## Building

Needs a Mac with Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Node 22+
with Corepack, and an Apple TV (or the tvOS simulator).

```sh
bash scripts/fetch-web.sh       # clones AIOStreams into .build/ and builds the web app into WebBuild
xcodegen generate               # writes AIOStreamsTV.xcodeproj from project.yml
open AIOStreamsTV.xcodeproj
```

`AIOSTREAMS_DIR=/path/to/AIOStreams bash scripts/fetch-web.sh` builds from a checkout you already have
instead, and `AIOSTREAMS_REF=<branch or tag>` picks what to clone. The script only reads that repo.

In Xcode, pick your team under Signing & Capabilities (or set `DEVELOPMENT_TEAM` in `project.yml`),
change the bundle ID if it's taken, and run on the Apple TV. A free Apple account's builds stop
opening after 7 days; a paid account's last a year.

Turn off Metal API Validation (Product → Scheme → Edit Scheme → Run → Diagnostics): MoltenVK trips it
on HDR video. See [KhronosGroup/MoltenVK#2226](https://github.com/KhronosGroup/MoltenVK/issues/2226).

The GitHub Actions workflow builds for the simulator on each push, unsigned, to check it compiles.

## What isn't known yet

This was written without a Mac, so none of it has run. In rough order of risk:

1. **UIWebView on current tvOS.** The private class worked in the [tvOS-Browser](https://github.com/Moballo-LLC/tvOS-Browser)
   projects; whether it's still in tvOS 17 and 18 is the first thing to check. Without it there's
   no way to show the web app on tvOS.
2. **Speed.** UIWebView probably runs JavaScript without the JIT Safari gets. A React app this size
   may feel slow.
3. **The context callback.** If WebKit never calls `webView:didCreateJavaScriptContext:forFrame:`,
   the app installs the bridge after the page loads instead; messages wait in a queue until then.
4. **Storage.** tvOS can clear an app's caches, web storage included. The app copies localStorage
   into the user defaults (up to about 400 KB, values over 64 KB left out) and restores missing keys
   at start, so sign-ins and settings survive. IndexedDB caches don't, and may not exist in UIWebView.
5. **The keyboard.** It opens by giving an off-screen text field first responder; if tvOS won't
   show the keyboard for it, this needs another route.
6. **Swipe sensitivity** (`RemoteInput.swipeStep`) is a guess.
7. **MPVKit** describes itself as not production quality. HDR passthrough isn't set up.

## Layout

| Folder         | What it holds                                                          |
| -------------- | ---------------------------------------------------------------------- |
| `App/Web`      | The UIWebView wrapper, the page's origin, the bridge script and hook    |
| `App/Bridge`   | The app's end of the bridge and its JSON helpers                       |
| `App/Player`   | libmpv, the player messages, Now Playing and remote commands           |
| `App/Input`    | The Siri Remote and the system keyboard                                |
| `App/Support`  | Identity, folders, storage mirroring, mpv.conf, the app's own answers  |
| `scripts`      | Building the web app into `WebBuild` (git-ignored)                     |

## Licences

MPVKit's LGPL build bundles mpv and FFmpeg under the LGPL. The web app is AIOStreams', under its
licence.
