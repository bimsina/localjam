# Play Store listing (draft)

Draft copy for the Google Play listing of LocalJam 1.0.0. Limits are Play's:
title 30 characters, short description 80, full description 4000.

Keep it honest: every claim here should be true of the build being uploaded.
In particular, do not claim "works on any phone" or quote sync numbers from
physical devices until `DEVICE_TESTING.md` has real-hardware results.

## App name (30)

```
LocalJam: Listen Together
```

(25 characters. Plain `LocalJam` also works.)

## Short description (80)

```
Play music in sync on nearby phones over Wi-Fi. No internet, no accounts.
```

(73 characters.)

## Full description (4000)

```
LocalJam turns the phones in a room into one sound system. One person hosts a jam and picks the songs; everyone nearby joins over the same Wi-Fi or the host's hotspot and hears the same thing at the same moment, in their own headphones or speaker.

No internet. No accounts. No servers. Everything happens between the phones in the room.

HOW IT WORKS
• Host a jam and add songs from your phone.
• Friends join by scanning the QR code, tapping the room in "Nearby", or opening a link you share.
• Playback stays in sync across every device, with tiny, inaudible corrections instead of jumps.
• Friends without the app can listen too: the join link opens a listener page served by the host's phone, right in their browser.

A SHARED QUEUE
• Anyone you allow can add songs, reorder and skip.
• Every song shows who added it.
• Pick a vibe for the room: Open (everyone can do everything), Jam (everyone adds, you control playback) or Listen-only. Promote a co-host, or remove someone, at any time.

MADE FOR REAL ROOMS
• Keeps playing with the screen off, with play and pause on the lock screen and in notifications.
• Ending the jam tells everyone straight away.
• Jam history remembers each session: what played, who added it and who was there.

PRIVATE BY DESIGN
LocalJam collects no data. There are no accounts, no ads, no analytics and no tracking. Your music goes only to the phones in your jam, over your local network. Use it on networks you trust, such as your home Wi-Fi or your own hotspot.

FREE AND OPEN SOURCE
LocalJam is MIT-licensed. Read the code, report issues or contribute at github.com/bimsina/localjam.

GOOD TO KNOW
• All devices need to be on the same Wi-Fi network or the host's hotspot. Some public and office networks block devices from seeing each other.
• Browser listeners on iPhone (Safari) cannot play Ogg Vorbis or Opus files.
• Only share music you have the right to share.
```

## Category and tags

- **Category:** Music & Audio
- **Tags (pick up to 5):** Music player, Party, Social, Offline, Audio sharing
- **Contact email:** the developer account's public support address, entered in
  Play Console (it is not kept in this repository)
- **Website:** https://github.com/bimsina/localjam

## Graphics checklist

| Asset | Spec | Source |
| --- | --- | --- |
| App icon | 512 × 512 PNG, 32-bit, no transparency needed but allowed alpha is flattened | Scale `apps/localjam_app/assets/brand/icon_1024.png` |
| Feature graphic | 1024 × 500 PNG/JPG | **To make**: the mark on the raspberry gradient with "Listen together" |
| Phone screenshots | 2 to 8, 16:9 or 9:16, 1080 px wide recommended | **To capture on a real phone**: home with a nearby jam, the room (light), the room (dark), the shared queue with "added by", people and the invite QR, a browser listener |
| 7- and 10-inch tablet screenshots | optional | Skip for 1.0.0 |

`docs/screenshots/` has emulator/design captures that can stand in for the
internal testing track, but production listing screenshots should come from
a physical device with real song metadata the owner has the rights to show
(no copyrighted album art you cannot license).

## Release notes (What's new, 500)

```
First release. Host a jam, invite nearby phones by QR, link or Nearby, and listen together in sync over Wi-Fi with no internet and no accounts. Friends without the app can listen in their browser.
```
