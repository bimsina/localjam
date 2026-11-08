# LocalJam privacy policy

_Effective 2026-11-08. Applies to the LocalJam app for Android (and, when
released, iOS and desktop) and to the listener page a LocalJam host serves to
browsers on its local network._

**In short: LocalJam does not collect, store on a server, share or sell any
data about you. It has no accounts, no analytics, no ads and no server of its
own. Everything it does happens on your device and on the local network you
choose to use it on.**

## What LocalJam is

LocalJam plays music in sync on several nearby phones. One person hosts a
"jam" and picks songs from their phone; the others join over the same Wi-Fi
network or the host's hotspot. The host's phone sends the songs and the
playback timing directly to the guests' phones. No internet connection is
used or needed.

## Data we collect

None. The developer receives no data from the app: no usage statistics, no
crash reports, no identifiers, no location, no contacts, nothing.

## What stays on your device

The app keeps the following only on your device, in its private storage, and
it is deleted when you uninstall the app or clear its data:

- **A device name and id**: a randomly generated name (for example "Silky
  Puffin") and a random device id, so the people in a room can tell devices
  apart and a host can recognise a returning guest. You can change the name
  in Settings.
- **Jam history**: the rooms you hosted or joined, their song lists, who added
  what and who was in the room.
- **Cached songs and artwork**: copies of songs played in a jam, so they can
  be played again from history. The oldest are removed automatically once the
  cache passes about 1 GB.
- **Your settings**, such as the appearance theme.

The app opts out of Android cloud backup and device-to-device transfer, so
none of this is copied off the device by the system either.

## What is shared on the local network, and with whom

When you host or join a jam, LocalJam talks directly to the other devices in
that jam over your local network. It shares only what a jam needs:

- with everyone in the room: your device name and role (host, co-host,
  guest), and the songs in the queue with their title, artist,
  album, artwork and who added them;
- with the host: your random device id, so it can recognise you if you
  reconnect;
- from the host to guests: the audio of the queued songs and the playback
  timing;
- with devices on the same network, if the host leaves "nearby discovery" on:
  the room's name and the information needed to join it, announced over
  mDNS. Anyone on that network can then join. Turn discovery off to share the
  room only by QR code or link.

This traffic stays on your local network and is not encrypted (see
`PROTOCOL.md` §9 in the source code for the reasoning). Use LocalJam on
networks you trust, such as your home Wi-Fi or your own hotspot. Songs you
share are sent to the guests' devices; guests can keep cached copies, the
same as when you hand someone a file.

When a guest without the app opens the join link, their browser loads the
listener page from the host's phone, over the same local network. That page
loads nothing from the internet. In the browser it keeps only a random device
id, the name you join under and, while the tab is open, the room's
invitation, in that page's own site storage.

## Permissions and why they are asked for

| Permission | Used for |
| --- | --- |
| Network access (Android "Internet") | Android requires this permission for any network connection, including on the local network. LocalJam uses it only to talk to the other devices in a jam. It does not connect to the internet. |
| Local network access (Android 17+) | Finding and connecting to jams on your Wi-Fi. |
| Music and audio (Android "Read media audio") | Showing the songs on your phone when you choose "Add from library". Not needed to pick a song with the file picker. |
| Camera | Scanning a jam's QR code to join. Camera images are processed on the device to read the code and are never stored or sent anywhere. |
| Notifications | Showing what is playing, with play and pause, while a jam runs. |
| Foreground service, wake lock, Wi-Fi state and multicast | Keeping the jam playing and reachable with the screen off, and discovering nearby jams. |

Every permission is optional. Declining one only turns off the feature that
needs it.

## Third-party code

LocalJam uses open-source libraries, listed in the app under Settings → Licenses. It does not include any analytics, advertising or crash-reporting
SDK. QR codes are read with Google's ML Kit barcode scanner, which is bundled
in the app and runs entirely on the device; the app disables ML Kit's
usage-statistics upload, so it does not send data to Google.

Links the app shows (for example to the source code) open in your browser,
which applies its own privacy policy.

## Children

LocalJam does not collect data from anyone, including children under 13.

## Changes

If this policy changes, the new version will be published at the same place
with a new effective date, and the change will be listed in the app's
changelog. The history of this file is public in the source repository.

## Contact

Questions about this policy: open an issue at
<https://github.com/bimsina/localjam/issues>, or email
**[PRIVACY CONTACT EMAIL]**.
