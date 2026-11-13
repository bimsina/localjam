# Play Console: Data safety and app content answers

Answers for LocalJam 1.0.0 (Android). Re-check them whenever a dependency that
touches the network, the camera or storage changes. The reasoning lives in
[`ANDROID_RELEASE.md`](ANDROID_RELEASE.md) ("Permissions", "No telemetry from
ML Kit") and [`PRIVACY.md`](../../PRIVACY.md).

## Data safety

Play's definition of "collected" is data **transmitted off the device** to the
developer or a third party. Data that moves directly between users' devices on
a local network, without passing through a server, and data processed only on
the device, is not "collected" in Play's sense. LocalJam has no server, no
analytics, no crash reporting and no ads, and the ML Kit telemetry upload is
disabled in the manifest.

| Question | Answer |
| --- | --- |
| Does your app collect or share any of the required user data types? | **No** |
| Is all of the user data collected by your app encrypted in transit? | Not asked once the answer above is No. (If Play still asks: not applicable, no data is collected.) |
| Do you provide a way for users to request that their data is deleted? | Not asked once the answer above is No. All data is local: uninstalling or clearing the app's storage deletes it. |

Data types considered and why each is "not collected":

| Data type | Why not |
| --- | --- |
| Audio files (Files and docs / Audio) | Songs a host picks go only to guests' devices in the same room, peer to peer on the LAN, at the user's request. Never to the developer or a third party. |
| Name / user IDs | The device name and random id are shared only with other devices in the jam, on the LAN. |
| Photos and videos (camera) | QR frames are decoded on the device and discarded. |
| App activity, app info and performance, device or other IDs | No analytics or crash SDK. ML Kit's diagnostics upload is disabled (its `datatransport` backend is removed from the manifest), so nothing goes to Google. |
| Location | Not requested. LAN addresses are used only to connect devices in the room. |

**If the ML Kit telemetry removal is ever dropped**, the answer becomes "Yes,
collected" with: *App info and performance → Diagnostics* and *Device or other
IDs*, collected (not shared), purpose *Analytics*, processed ephemerally: no,
encrypted in transit: yes, required: yes (no in-app opt-out). Update
`PRIVACY.md` the same day.

## App content

| Section | Answer |
| --- | --- |
| Privacy policy | URL of `PRIVACY.md` (see `ANDROID_RELEASE.md`, "Privacy policy URL") |
| Ads | No, the app contains no ads |
| App access | All functionality is available without special access. No login. Note for reviewers: "LocalJam needs two devices on the same Wi-Fi network for the core feature. One device can host a jam alone: tap Host, add a song from the device, press play." |
| Content rating (IARC questionnaire) | Category: All Other App Types. No violence, sexual content, profanity, drugs, gambling. **User-generated content / users can interact: yes**, because users share music and see each other's chosen names, but only with people on the same local network; no chat, no public sharing, no online interaction. "Shared user content is the main source of content": yes; block and report: no; can be limited to invited friends: yes ("Show to people nearby" off). Rated ESRB Teen, PEGI Parental Guidance, 12+ elsewhere (saved 2026-11-13). |
| Target audience | 13+ (not designed for children; avoids the Families policy requirements) |
| News app | No |
| COVID-19 contact tracing / status | No |
| Data safety | As above |
| Government app | No |
| Financial features | None |
| Health | None |
| Foreground service permissions | Media playback. Text in `ANDROID_RELEASE.md`, "Foreground service declaration". |
| Photo and video permissions | Not requested (`READ_MEDIA_IMAGES`/`VIDEO` absent) |
| Exact alarms, full-screen intent, accessibility, VPN, `QUERY_ALL_PACKAGES` | Not used |

## Pre-launch report notes

Play's automated pre-launch devices have no second LocalJam device on their
network, so the crawler will see the home screen, onboarding and an empty
"nearby" list. That is expected. Permission prompts appear only behind an
in-app explanation sheet, after a user action.
