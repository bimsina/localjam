# LocalJam

Listen together, in sync, over local Wi-Fi — no internet, no accounts.

One person hosts a jam and shares the files; everyone nearby joins over the LAN
or a hotspot and hears the same thing at the same instant in their own
headphones. Measured drift between devices is about ±5 ms, corrected silently
with pitch-corrected ±0.5 % rate slews.

This is the Flutter UI. All the interesting machinery — transport, clock sync,
drift correction, the OS media session, room discovery, jam history — lives in
`packages/localjam_client` and is re-exported through one `JamHostEngine` /
`JamGuestEngine` pair. See the repo root `README.md` and `PROTOCOL.md`.

Application id on every platform: **`np.com.bibektimsina.localjam`**.

## Running it

```sh
flutter pub get

flutter run                       # whatever device is attached
flutter run -d macos
flutter run -d windows
flutter run -d linux
```

Two devices on the same network are the point — host on one, join on the other
by nearby-room discovery, QR scan, or a `localjam://join?…` link.

### Per-platform notes

| Platform | Notes |
| --- | --- |
| **iOS** | Needs a real device or simulator on the same LAN. `flutter build ios --simulator --no-codesign` for a simulator-only build. Local network access is prompted on first host/join, behind the app's own rationale sheet. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` put a **LocalJam** folder in the Files app — that is how audio gets onto a phone with no library of its own. |
| **Android** | API 37 (Android 17) gates *all* LAN traffic behind the runtime `ACCESS_LOCAL_NETWORK` permission; the app asks at host/join time. |
| **macOS** | Sandboxed. The network client/server and camera entitlements are already in `macos/Runner/*.entitlements`. |
| **Apple, both** | `pubspec.yaml` carries a `dependency_overrides` entry pointing `bonsoir_darwin` at the patched copy in `packages/third_party/` — without it the app deadlocks on the Simulator the moment it advertises a room. See that package's `PATCHES.md`. |
| **Windows / Linux** | Desktop playback goes through miniaudio in the `localjam_audio` plugin. Linux needs GTK 3 dev packages. |

## Brand assets

The mark is `assets/brand/logo.svg` — white headphones-with-microphone on a
transparent ground. Everything else is derived from it:

| File | Used for |
| --- | --- |
| `icon_1024.png` | full-bleed app icon (raspberry gradient, no alpha — the App Store rejects icons with an alpha channel) |
| `icon_foreground.png` | Android adaptive-icon foreground layer |
| `icon_monochrome.png` | Android 13 themed icons |
| `splash_logo.png` | launch screen mark (≈35 % of screen width) |
| `splash_logo_android12.png` | Android 12+ platform splash icon |

Colour and type follow `docs/design/DESIGN_SPEC.md` (v3): Apple system
neutrals, raspberry (`#D92C64` light / `#FF4F82` dark) only as the tint on
things you can tap, and the platform's own system font — SF Pro on iOS and
macOS, Roboto on Android, Segoe UI on Windows — at iOS text-style sizes. No
font ships with the app. Timers use tabular figures
(`FontFeature.tabularFigures()`), which is what keeps the room timer from
jittering as it counts.

Regenerate the native icon sets and launch screens after changing any of those
PNGs — both generators are configured from `pubspec.yaml`:

```sh
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

`flutter_native_splash:create` rewrites `android/app/src/main/res/values*/styles.xml`
and `ios/Runner/Base.lproj/LaunchScreen.storyboard`. Two hand-made edits live in
those files and must be re-applied if the generator stomps them:

- `NormalTheme` pins `windowBackground` / `colorBackground` to
  `@color/app_background` (white in `values/`, black in `values-night/`, the
  app's own `background`) so there is no seam between the splash and the
  first Flutter frame.
- The `LaunchScreen.storyboard` root view background is white, matching the
  splash.

## Release signing

Debug and profile builds sign themselves. A release build needs
`android/key.properties` and **fails without it**, so a debug-signed artifact
can never be uploaded by accident. For a local release build (`flutter run
--release`, R8 checks), opt in to the debug key with
`LOCALJAM_ALLOW_DEBUG_SIGNING=1`. The full Play process (upload key, Play App
Signing, permissions, Data safety) is in
[`docs/release/ANDROID_RELEASE.md`](../../docs/release/ANDROID_RELEASE.md).

```sh
keytool -genkey -v -keystore ~/localjam-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload

cp android/key.properties.example android/key.properties
$EDITOR android/key.properties          # git-ignored
flutter build appbundle --release
```

Release builds run R8 with `isMinifyEnabled` and `isShrinkResources` on;
`android/app/proguard-rules.pro` keeps the Flutter embedding, the
`localjam_audio` plugin (its foreground service is named from the merged
manifest) and the ML Kit barcode classes behind `mobile_scanner`.

The app also sets `allowBackup="false"` with matching
`res/xml/data_extraction_rules.xml` and `res/xml/backup_rules.xml`: the media
cache, artwork, jam history and device identity stay on the device.

## Tests

```sh
flutter test          # 251 tests: screens, widgets, state, formatting helpers
```

They run offline and need no device. The engine's own suites live beside it in
`packages/` — see the root `README.md`.
