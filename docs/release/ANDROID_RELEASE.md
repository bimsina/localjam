# Android release

How to build, sign and upload LocalJam to Google Play. Everything here runs
from `apps/localjam_app/` unless it says otherwise.

| | |
| --- | --- |
| Application id | `dev.bimsina.localjam` (cannot change after the first upload) |
| minSdk | 24 (Android 7.0), Flutter's floor |
| targetSdk | 36, pinned in `android/app/build.gradle.kts` (Play requires 36 from 2026-08-31) |
| compileSdk | 37 (`permission_handler` 13 needs it for `ACCESS_LOCAL_NETWORK`) |
| Version | `pubspec.yaml` `version: <versionName>+<versionCode>` |
| Toolchain | Flutter 3.50.0 (CI pins 3.50.0 / Dart 3.14.0), Gradle 9.5.1, AGP 9.3.3, Kotlin 2.4.20 (AGP built-in Kotlin), JDK 17, NDK 28.2 |

## 1. One-time setup

### Play Console

1. Create the app in Play Console: name **LocalJam**, app (not game), free.
2. Turn on **Play App Signing** (the default for new apps). Google keeps the
   key that signs what users install; you keep an **upload key** that only
   proves an upload came from you. If the upload key is ever lost or leaked,
   Play support can reset it. The app-signing key never leaves Google.
3. Fill in the listing, Data safety and content declarations from
   [`PLAY_LISTING.md`](PLAY_LISTING.md) and [`DATA_SAFETY.md`](DATA_SAFETY.md),
   and the privacy policy URL (see "Privacy policy URL" below).

### The upload key

Generate it once, outside the repository, and back it up somewhere that is not
this machine (a password manager that stores files, an encrypted drive):

```sh
keytool -genkeypair -v \
  -keystore ~/keys/localjam-upload.jks \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -alias upload
```

Then point the build at it:

```sh
cp android/key.properties.example android/key.properties
$EDITOR android/key.properties
```

```properties
storeFile=/Users/you/keys/localjam-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

`android/key.properties`, `*.jks` and `*.keystore` are git-ignored at the repo
root and in `android/.gitignore`. Check before every commit that touches
`android/` that `git status` does not list them.

**Without `key.properties` a release build fails** with "localjam: no release
signing key". That is deliberate: it used to fall back to the debug key, and a
debug-signed bundle is one Play rejects and one you cannot update from. For a
local release build you never intend to upload (R8 checks, profiling on your
own phone), opt in to the debug key explicitly:

```sh
LOCALJAM_ALLOW_DEBUG_SIGNING=1 flutter build apk --release
# or
flutter build apk --release --android-project-arg=localjam.allowDebugSigning=true
```

Debug and profile builds are not affected.

## 2. Every release

1. **Bump the version** in `apps/localjam_app/pubspec.yaml`. The number after
   `+` is the `versionCode` and must be higher than every build ever uploaded,
   to any track. The part before it is what users see.
2. **Update `CHANGELOG.md`**: move `## Unreleased` under the new version
   heading.
3. **Build the browser listener page into the app** (the page a host serves to
   guests who don't have the app). Skipping this still builds, but rooms then
   serve an "install the app" page instead:

   ```sh
   # from the repository root
   tool/build_web_guest.sh
   tool/build_web_guest.sh --check
   ```

4. **Run the suites** (see the root `README.md`) and the Android rows of
   [`DEVICE_TESTING.md`](../../DEVICE_TESTING.md) on at least one physical
   phone.
5. **Build the bundle:**

   ```sh
   cd apps/localjam_app
   flutter build appbundle --release
   # build/app/outputs/bundle/release/app-release.aab
   ```

6. **Sanity-check it** (optional but cheap): `bundletool build-apks
   --bundle app-release.aab --output out.apks --connected-device` then
   `bundletool install-apks --apks out.apks`, and play a jam.
7. **Upload** to the internal testing track first, then promote. Keep the
   R8 mapping file (`build/app/outputs/mapping/release/mapping.txt`) Play
   asks for; it is what turns obfuscated Java stack traces back into names.

## 3. What the build enforces and why

### Shrinking

Release builds run R8 (`isMinifyEnabled`, `isShrinkResources`) with
`android/app/proguard-rules.pro`, which keeps the Flutter embedding, the
`localjam_audio` plugin (its foreground service is named from the merged
manifest) and the ML Kit barcode classes behind `mobile_scanner`. Dart code is
AOT-compiled and is not touched by R8.

### 16 KB page size

Play requires 16 KB-compatible native libraries for apps targeting Android 15+.
Checked on the 1.0.0 build: every `.so` for `arm64-v8a` and `x86_64`
(`libflutter`, `libapp`, ML Kit's `libbarhopper_v3`, CameraX's JNI helpers,
`libdartjni`, `libdatastore_shared_counter`) has LOAD segments aligned to
16 KB or more, and `zipalign -c -P 16 -v 4` passes. To re-check after a
dependency bump:

```sh
unzip -o app-release.apk 'lib/*' -d /tmp/lj
for f in /tmp/lj/lib/arm64-v8a/*.so; do
  echo "$f $(llvm-readelf -lW "$f" | awk '$1=="LOAD"{print $NF}' | sort -u)"
done                        # every value must be 0x4000 or larger
zipalign -c -P 16 -v 4 app-release.apk | tail -1
```

(`llvm-readelf` ships in the NDK under `toolchains/llvm/prebuilt/*/bin/`.)

### Permissions

The merged release manifest asks for exactly these. The left column is what
Play Console and the system show.

| Permission | Kind | Why |
| --- | --- | --- |
| `INTERNET` | normal | Android grants no socket without it, LAN included. The host's server and every guest connection are local-network sockets; nothing connects to the internet. |
| `CHANGE_WIFI_MULTICAST_STATE`, `ACCESS_WIFI_STATE`, `ACCESS_NETWORK_STATE` | normal | Nearby-room discovery (mDNS, `bonsoir`), the Wi-Fi lock that keeps a host reachable, and reading the device's LAN address for the join link. |
| `READ_MEDIA_AUDIO` (`READ_EXTERNAL_STORAGE` up to API 32) | runtime | "Add from library": lists the phone's music through MediaStore. Only asked for when the user opens the library. Songs picked with the system file picker need no permission. |
| `CAMERA` | runtime | Scanning a room's join QR code. Frames are decoded on the device and never stored. `android.hardware.camera` is `required="false"`, so phones without a camera can still install and join by link or nearby rooms. |
| `POST_NOTIFICATIONS` | runtime (Android 13+) | The media card (now playing, play/pause) while a jam runs. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | normal | `JamSessionService` (`foregroundServiceType="mediaPlayback"`) keeps a backgrounded host serving its room and a guest playing. |
| `WAKE_LOCK` | normal | Held with the Wi-Fi lock only while a jam is active, so a screen-off phone keeps playing in sync. |
| `<package>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | signature | Added by AndroidX; protects the app's own unexported receivers. |

Not requested, on purpose: `NEARBY_WIFI_DEVICES` (no Wi-Fi Direct or Wi-Fi
scanning; discovery is mDNS on the network the phone is already on), location,
microphone, contacts, accounts, `MANAGE_EXTERNAL_STORAGE`.
`ACCESS_LOCAL_NETWORK` is also absent for now: Android 17 gates LAN traffic
behind it only for apps targeting API 37, and Google's guidance is that apps
targeting 36 or lower must neither declare nor request it. It is declared and
asked for (behind an in-app explanation) in the same change that moves
`targetSdk` to 37; see the comment there in `build.gradle.kts`.

### Foreground service declaration (Play Console)

Play asks every app that targets Android 14+ and declares a foreground service
type to justify it under **App content → Foreground service permissions**.
Answer:

- **Type:** Media playback (`FOREGROUND_SERVICE_MEDIA_PLAYBACK`).
- **Description:** "LocalJam plays music in sync with nearby phones on the same
  Wi-Fi. While a jam is running, a media-playback foreground service keeps the
  audio playing and the host's local server answering when the app is in the
  background or the screen is off. It shows the standard media notification
  with play/pause and stops when the user ends or leaves the jam."
- **User-initiated, user-visible, stoppable:** yes. It starts when the user
  hosts or joins a jam and stops when they end or leave it.
- **Video:** Play may ask for a short screen recording: start a jam, play a
  song, background the app, show the notification, pause from it, end the jam.

### Cleartext traffic

Jam traffic is plain HTTP and WebSocket on the LAN, by decision
(`PROTOCOL.md` §9), and goes through Dart's `dart:io`, which Android's
network-security config does not govern. The app ships
`res/xml/network_security_config.xml` with cleartext **off** for the platform
stack, so no Java/Kotlin library in the APK can make a cleartext request.
Android cannot express "cleartext only to private addresses", so this is the
tightest scoping available. If a future plugin needs platform-side LAN HTTP
(for example `ExoPlayer` streaming from the host), that is the moment to
revisit it, and the config is where it would show.

### No telemetry from ML Kit

`mobile_scanner` uses Google's ML Kit barcode scanner, bundled into the APK
(no Play-services model download, works on phones without Google services).
ML Kit on its own batches usage and diagnostics events (device model, OS, app
version, a per-install id, API timings) and uploads them to Google through
the `datatransport` library. The app manifest removes that library's
`TransportBackendDiscovery` service, so the uploader finds no backend and
discards the batches on the device. That is what lets the privacy policy and
the Data safety form say no data is collected.

Verify after any `mobile_scanner` or ML Kit upgrade:

1. The merged release manifest
   (`build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`)
   does not contain `TransportBackendDiscovery`.
2. Scanning a join QR still works on a device, and `adb logcat | grep -i
   -E "TRuntime|datatransport"` shows "Unknown backend ... deleting event
   batch" rather than an upload.

If that ever stops working, either fix it or update `PRIVACY.md` and
`DATA_SAFETY.md` to disclose ML Kit's collection (Google's table:
<https://developers.google.com/ml-kit/android-data-disclosure>).

### Backup

`allowBackup="false"` plus `data_extraction_rules.xml` (Android 12+) and
`backup_rules.xml` (older): nothing is backed up to the cloud or copied in a
device-to-device transfer. Jam history, cached songs and the device's
identity stay on the install.

### Exported components and links

Only `MainActivity` is exported (launcher, and `localjam://` links), apart
from androidx's `ProfileInstallReceiver`, which the profileinstaller library
merges in exported but guarded by `android.permission.DUMP` (only the shell or
system can send to it). The
`http://<lan-ip>:<port>/join#…` join link is intentionally not claimed: its
host is a LAN IP that changes per room, so it cannot be a verified App Link,
and an unverified `http` filter would offer LocalJam as a browser for every
web link. It opens in the browser (the web-guest path), whose page offers
"Open in app" via `localjam://`. No `assetlinks.json` is needed.

### Icons

Adaptive icon with background colour, foreground and a **monochrome** layer
(themed icons on Android 13+), generated by `flutter_launcher_icons` from
`assets/brand/`. Play's 512×512 listing icon is
`assets/brand/icon_1024.png` scaled down; it must have no transparency.

## Privacy policy URL

Play needs a public URL: <https://localjam.bimsina.dev/privacy>, the website's
copy of [`PRIVACY.md`](../../PRIVACY.md) (source in the `localjam_website`
repository). Change both together.
