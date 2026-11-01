# AIOStreams for Apple TV

The [AIOStreams](https://github.com/Viren070/AIOStreams) web app's standalone build (the one that
signs in to any Jellyfin server) on tvOS, playing through mpv. The page draws every screen and the
player's controls, unchanged; this app shows it in a web view over libmpv, as the desktop and
Android apps do, and turns the Siri Remote into the keys the page already handles.

It is unofficial and experimental. It uses private tvOS APIs, so it can't go on the App Store; the
IPA is sideloaded.

## How it fits together

```
┌──────────────────────────── screen ────────────────────────────┐
│  WKWebView, transparent: the web app and its player controls   │
│        ▲  window.aiostreamsApp: JSON messages both ways        │
│  AVSampleBufferDisplayLayer: mpv's frames, HDR metadata kept   │
└────────────────────────────────────────────────────────────────┘
```

The web layer follows the working aiostreams-tvos project, which loads an AIOStreams server's own
page the same way:

- **The web view** is WKWebView. tvOS ships WebKit but leaves it out of the SDK, so `AIOWebView.m`
  loads it with `dlopen` and calls it through the Objective-C runtime.
- **The page** is `packages/web`'s standalone build, bundled in the app as `WebBuild` and served by
  a URL scheme handler at `aiostv://localhost/`, so it has an origin of its own for sign-ins and
  settings.
- **Filling the screen:** WebKit fits the page to the screen less tvOS's safe area but draws it
  from the left edge, leaving a strip on the right. The app cancels the safe area and hands the web
  view the whole screen to lay out in (`fillScreen`).
- **The focus ring:** WebKit only counts the page focused while its content view is first responder,
  and `:focus` and `:focus-visible` need that. The app makes it first responder after each load and
  whenever its own screens close (`focusPage`).
- **The remote:** `AppWindow` takes the remote's presses and swipes before WebKit's content view
  can, and hands them to the page as keys through `__aioTV`.
- **The bridge** is the page's `window.aiostreamsApp`, added by a user script at document start.
  Page to app goes through `webkit.messageHandlers.aiostreamsNative`; app to page through
  `evaluateJavaScript`, which never blocks the app.
- **mpv** comes from Streamyfin's [MPVKit](https://github.com/streamyfin/MPVKit) build (GPL), the
  one the working aiostreams-tvos project uses, fetched by `scripts/fetch-mpvkit.sh`. Its
  `vo_avfoundation` output hands VideoToolbox's frames to an `AVSampleBufferDisplayLayer` with their
  HDR metadata. `MPVEngine` and `PlayerChannel` otherwise follow AIOStreams' Android `MpvEngine` and
  `PlayerChannel`: the same observed properties and messages.

### HDR and Dolby Vision

- **HDR10 and HLG** reach the TV as HDR. When a video starts, `DisplayMode` asks tvOS for the
  matching TV mode (HDR10, HLG or SDR) at the video's frame rate, and goes back to the TV's own mode
  when playback ends. tvOS only switches with **Settings → Video and Audio → Match Content**
  (Dynamic Range, and Frame Rate if you want that too) turned on.
- **Dolby Vision** plays through its HDR10 base layer, so the TV shows HDR10, not Dolby Vision.
  That covers profile 8 (most streaming releases) and profile 7 (UHD Blu-ray remuxes). Real Dolby
  Vision output on Apple TV only comes from Apple's own player, which can't play what mpv plays.
- **Profile 5** has no HDR10 base layer, so its colours come out wrong (purple and green).
- Subtitles are drawn by libass with the bundled Noto Sans (SIL Open Font License), as libass can't
  open tvOS's own fonts.

### Posing as the Android TV app

The web app picks its behaviour from the bridge's `platform`, and only knows `android`, `windows`,
`macos` and `linux`. To leave the AIOStreams repo untouched, this app reports itself as the Android
app on a TV (`platform: 'android'`, `tv: true`). That gets the TV layout, remote navigation, the
Back behaviour and the bundled-player path. It also means:

- Jellyfin lists the device as **AIOStreams Android TV**.
- Settings shows an **Android app** section. Its mpv.conf editor works; updates show as off.
- Android-only playback settings (frame rate matching, tunnelling) show and do nothing.
- The statistics overlay shows nothing: it needs mpv's Lua scripts, which tvOS's libmpv lacks.

## The remote

| Siri Remote                         | Does                                              |
| ----------------------------------- | ------------------------------------------------- |
| Clickpad edges / swipe              | Arrow keys (held edges repeat)                    |
| Click                               | Enter (held, the page's hold actions)             |
| Click on a text field               | tvOS's search keyboard over the page, typing straight into the field (dictation on the mic button); Menu or moving down closes it. Passwords and PINs get the keyboard in an alert |
| Back / Menu                         | The page's Back; twice on Home leaves the app     |
| Play/Pause                          | Play/Pause                                        |
| **Hold Play/Pause (1 s)**           | App menu: reload, or reset the app's data         |

## Saved data

tvOS can drop a web view's stored data between launches, and with it the page's sign-in. The app
keeps a copy of the page's localStorage in its own settings (about 350,000 characters at most,
values over 100,000 left out), puts back what is missing as the page starts, and hears of every
change. **Reset the app's data** in the app menu clears both, then loads the page again.

## External players

Settings → Playback → Player lists Infuse, VLC and Outplayer (the app reports an iPad user agent so
the page offers the iOS presets), or a custom link. Play opens the link with `UIApplication.open`.
Infuse's `x-success` callback, `aiostreams://return/item/…`, comes back to this app, which hands it
to the page; the page saves where you stopped.

## Building

The GitHub Actions workflow builds an unsigned `AIOStreams.ipa` for Apple TV hardware. Every run
attaches it as an artifact, each push to `main` replaces the **Nightly** release, and a `v*` tag
publishes a release of its own. Sign it with your own Apple ID using a sideloading tool that
handles Apple TV; with a free Apple ID the signature lasts 7 days, with a paid account a year.

On a Mac with Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Node 22+:

```sh
bash scripts/fetch-web.sh       # clones AIOStreams into .build/ and builds the web app into WebBuild
bash scripts/fetch-mpvkit.sh    # downloads Streamyfin's MPVKit (250 MB) into Vendor/, checked by SHA-256
xcodegen generate               # writes AIOStreamsTV.xcodeproj from project.yml
open AIOStreamsTV.xcodeproj
```

`AIOSTREAMS_DIR=/path/to/AIOStreams bash scripts/fetch-web.sh` builds from a checkout you already have
instead, and `AIOSTREAMS_REF=<branch or tag>` picks what to clone. The script only reads that repo.
Safari's Develop menu on a Mac can inspect the page.

## Layout

| Folder         | What it holds                                                          |
| -------------- | ---------------------------------------------------------------------- |
| `App/Web`      | The WKWebView wrapper and scheme handler, the bridge script, storage   |
| `App/Bridge`   | JSON helpers                                                           |
| `App/Player`   | libmpv, the player messages, Now Playing and remote commands           |
| `App/Input`    | The window that takes the remote, and the keys it becomes              |
| `App/Support`  | Identity, folders, mpv.conf, the app's own answers                     |
| `scripts`      | Building the web app into `WebBuild` (git-ignored)                     |

## Licences

Streamyfin's MPVKit build is GPL-3.0, so builds of this app are for personal use. Noto Sans is under
the SIL Open Font License. The web app is AIOStreams', under its licence.
