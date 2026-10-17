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

Palette: raspberry `#E63B6F`, raspberry deep `#C71F5E`, plum `#2B1332`,
cream `#FFF7F2`, apricot `#FFB25C`.

Type is **Plus Jakarta Sans** (Tokotype, OFL 1.1 — `assets/fonts/OFL.txt`),
roman weights only; the UI has no italics. Every weight ships real tabular
figures (`tnum`), which is what keeps the room timer from jittering as it
counts.

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
  `@color/app_background` (cream in `values/`, plum in `values-night/`) so there
  is no white frame between the splash and the first Flutter frame.
- The `LaunchScreen.storyboard` root view background is raspberry, not white.

## Release signing

Debug and profile builds sign themselves. A release build looks for
`android/key.properties`; without it Gradle prints a warning and falls back to
the debug key, so `flutter run --release` and local `flutter build apk --release`
still work — but the artifact is not distributable.

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
