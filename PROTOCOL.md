# LocalJam Protocol — v0.2 (draft)

> v0.1 → v0.2 is purely additive: optional tag metadata and attribution on
> playlist items (§6.1), the artwork endpoint (§6.5), roles/permissions,
> queue operations, and moderation (§5.6), the `session_ended` goodbye
> (§3.4), the stable `hello.clientId` (§3.1/§3.3), and `welcome.host`
> (§3.1). v0.1 clients interoperate unchanged (unknown JSON fields and
> message types are ignored per §2): they simply never send the new hello
> field, and fall back to the §3.3 silence timeout instead of the goodbye.

Synchronized local-network media playback. One **host** owns the files and the
authoritative session state; N **guests** join over LAN, fetch media, and play
in sync on their own output devices.

Design goals, in priority order:

1. Works fully offline (same Wi-Fi or host's hotspot; no internet, no accounts).
2. Audio is the primary medium. Video and images ride the same model as
   best-effort extras.
3. Sync target: ±40 ms across devices after calibration (per-person headphones,
   not shared-speaker grade).
4. Boring and debuggable over clever: JSON control plane, plain HTTP media plane.
5. Browser clients are a possible future guest (never a host); the protocol
   avoids gratuitously breaking them but v1 targets native mobile + desktop only.

---

## 1. Transport

Two channels, both served by the host on a single TCP port:

| Plane   | Transport                  | Purpose                                  |
|---------|----------------------------|------------------------------------------|
| Control | WebSocket `ws://host:port/ws` | Session state, clock sync, playback commands |
| Media   | HTTP `http://host:port/media/{mediaId}` | File transfer. MUST support `Range` requests. Guest uploads via `POST /media` (§6.4) |

- Control messages are JSON text frames in v1. The `hello` handshake reserves
  an `encodings` field (§3.1) so clients and host can negotiate a binary
  encoding (CBOR/MessagePack — same data model, no schema tooling) in a later
  version without a breaking change. Note the control plane is low-rate
  (a clock ping every 2 s, state changes only on user action) and the media
  plane is already binary HTTP — JSON is not a bottleneck here; binary framing
  is a polish item, not a performance requirement.
- UDP is deliberately **not** used in v1: LAN TCP jitter is low enough that
  min-RTT filtering (§4) gets clock sync well under our target, and one
  transport keeps every client simple. With web off the v1 roster, a UDP
  clock-sync fast path is a possible later optimization — measure first.

### Discovery / join

Primary: the host renders a QR code / shareable string:

```
localjam://join?v=1&host=192.168.1.7&port=44100&token=<sessionToken>&name=RoadTrip
```

(The host may listen on multiple interfaces and encode several `host` candidates,
comma-separated; guests try them in order.)

Secondary (v0.2): mDNS/Bonjour advertisement for in-app "nearby rooms"
listing. Hosts that opt in ("discoverable") advertise `_localjam._tcp` with
TXT records:

```
v=<protocolVersion>  name=<sessionName>  token=<sessionToken>
```

Joiners resolve the service (addresses + port come from mDNS itself) and
build the same `localjam://join` URI. Including the token makes a
discoverable room one-tap joinable by ANYONE on the network — presence on
the LAN is the invitation (§9), which is why it is host-opt-in per session.
QR/link remains the first-class path — mDNS is blocked on hotspots,
guest-isolated Wi-Fi, and unlisted Bonjour types on Apple platforms
(`NSBonjourServices` must contain `_localjam._tcp`).

---

## 2. Message envelope

Every control message:

```json
{
  "v": 1,               // protocol version
  "type": "play",       // message type
  "seq": 42,            // sender-local monotonically increasing sequence number
  "payload": { ... }
}
```

- Unknown `type` or unknown payload fields MUST be ignored (forward compat).
- `seq` is for logging/dedup; ordering is otherwise guaranteed by TCP.

Message direction key below: **G→H** guest to host, **H→G** host to guest,
**H→\*** host broadcast to all guests.

---

## 3. Session lifecycle

### 3.1 Join handshake

```
G→H  hello     { token, clientName, clientKind: "flutter"|"web"|...,
                 caps: ["audio","video"], encodings: ["json"],    // encodings reserved for future binary negotiation
                 resumePeerId?,                                    // §3.3 reconnect: resume this peer slot
                 clientId? }                                       // v0.2: stable per-device id, §3.3
H→G  welcome   { sessionId, sessionName, you: {peerId}, peers: [...], snapshot: <state §5.1>, playlist: [...],
                 host?: {peerId: "host", clientName, clientKind} }  // v0.2
     — or —
H→G  reject    { reason: "bad_token" | "full" | "version" }
```

`welcome.snapshot` makes late join trivial: it contains the full current
playback state, and the guest converges on it like any other state update.

`welcome.host` (v0.2, optional) is the host as a *person*: the reserved
peer id `"host"` plus the display identity the host device carries
("Silky Puffin"), same shape as any `peers` entry. It is deliberately NOT a
member of `peers` — the host is not a joined peer (§5.6), and a client that
counts the room must not double-count it. Guests SHOULD use this name
wherever they would otherwise print the role word: the roster, and the
`addedBy` byline for host-contributed tracks (§6.1). Absent (or empty) means
the host shares no identity, and "Host" is the fallback.

`hello.clientId` (v0.2, optional) is a stable, opaque per-device id —
persisted by the client, never displayed, unrelated to `clientName` (which
several devices may share, and which the user may change). See §3.3.

### 3.2 Presence

```
H→*  peer_joined { peer: {peerId, clientName, clientKind} }
H→*  peer_left   { peerId }
```

### 3.3 Liveness

WebSocket ping/pong at transport level; a peer is dropped after 10 s silence.
Guests reconnect by sending `hello` with the same `token`, the same
`clientId`, plus `resumePeerId: <their old peerId>`; the host keeps a 30 s
grace slot per dropped peer. A valid resume reclaims the old peerId
(re-announced via `peer_joined`); an expired, unknown or unproven
`resumePeerId` silently falls back to a fresh join. Readiness reports (§6.3)
are forgotten on drop — guests re-send `media_status` after resuming.

**A resume MUST be proved with `clientId`.** The grace slot records the
`clientId` the dropped connection said hello with, and the host MUST honour
`resumePeerId` only when the new `hello` carries a non-empty `clientId` equal
to it. Everything else about a resume is public or shared: peerIds travel the
room in `welcome.peers`, `peer_joined` and `peer_left`, and the token is what
every guest in the room already holds. A slot keyed on those alone is
claimable by anyone who watched a co-host drop — and since roles and
overrides (§5.6) survive the grace window by design, claiming the slot means
inheriting the role. The `clientId` is the only part of a resume the claimant
has not been told.

A `hello` whose resume is not proved is not an error: it is an ordinary fresh
join. The host issues a **new** peerId, and the joiner gets the room's
default role with no overrides — nothing carries over from the slot it
named, which stays where it was until its owner returns or the window
expires. A client that sends no `clientId` (a v0.1 client) therefore can
never resume; it reconnects as a new peer, which is what v0.1 always did.
This is a tightening of v0.2's rule and is compatible in the direction that
matters: no client loses a capability it could exercise honestly, because an
honest resume was always a device coming back to its own slot.

**One device is one peer** (v0.2). A silence timeout is the only way to
notice a peer that died without closing its socket — an app force-quit, a
process killed while backgrounded, a phone that left the network — and for
those 10 s the corpse is still in the roster. A device that comes back
inside that window would otherwise join beside a ghost of itself: everyone
sees a phantom, and the rejoining guest is handed one in `welcome.peers`.

So a host that receives a `hello` carrying a `clientId` already held by a
connected peer MUST drop that older connection first (a plain `peer_left`,
no grace slot kept, its roles and overrides forgotten per §5.6) and only
then admit the new one, which joins as an ordinary fresh peer. The new
socket is the live one by definition — the device is on it. A client that
sends no `clientId` (v0.1) is never superseded, and two devices with
different ids both stay however identical their `clientName`s are.

`clientId` is transport bookkeeping, not authentication: like everything
else in §9's honest-guest model it is client-asserted, and a room where
guests forge each other's ids is a room with a worse problem.

### 3.4 Session end (v0.2)

```
H→*  session_ended { reason: "host_ended" }
```

Broadcast by the host immediately before it closes every control socket
(with the WebSocket **normal closure** code, 1000, rather than
`goingAway`). It means the room is over *on purpose* — the host tapped "End
jam" — and it is terminal: a guest that receives one MUST NOT reconnect,
and MUST NOT wait out any host-gone timeout, whatever the `reason` says.
An unrecognized reason (from a later version) is still terminal; treat it
as an end you do not have copy for, never as a message to ignore.

Silence keeps its old meaning, which is the point of announcing anything at
all: a host that crashes, runs out of battery, or walks out of range sends
nothing, and guests fall back to reconnecting until their own host-gone
timeout expires (§10: host death ends the room). Without a goodbye, every
deliberate exit is indistinguishable from that — which is why a host that
ended the jam on purpose used to leave the room staring at "Reconnecting…"
for a minute and a half.

Guests treat an announced end exactly as they treat host-gone once
detected: the transport stops, and whatever is already playing from the
local cache is left alone — the protocol has no opinion on whether the
music fades out, and the app decides.

---

## 4. Clock synchronization

The host's monotonic clock is the **session clock** (`hostTime`, in
microseconds, from an arbitrary epoch — NOT wall clock; wall clocks jump).

NTP-style exchange, initiated by each guest:

```
G→H  clock_ping { t0 }                 // guest monotonic µs at send
H→G  clock_pong { t0, t1, t2 }         // t1 = host receive, t2 = host send
                                        // guest records t3 = receive time
offset = ((t1 - t0) + (t2 - t3)) / 2
rtt    = (t3 - t0) - (t2 - t1)
```

Guest algorithm (client-side, not on the wire):

- Burst of 8 pings at join; keep the sample with **minimum RTT** (least queued,
  most symmetric) as the initial offset.
- Steady state: 1 ping every 2 s; accept a sample only if its RTT is within
  1.5× of the best RTT seen; blend accepted samples with an EWMA (α ≈ 0.1).
- Never step the offset while playing; slew it (≤ 1 ms per second) to avoid
  audible jumps. Large error (> 50 ms) ⇒ hard resync: pause locally, step,
  rejoin playback at the correct position.
- Clock discontinuity (device deep sleep pauses the monotonic clock): 2
  consecutive accepted samples disagreeing with the estimate by > 0.5 s are a
  jump, not drift — discard all sync state (offset, best RTT, slew) and
  re-run the join burst from the steady ping stream, hard-resyncing playback.

Expected accuracy on LAN: 1–5 ms. The dominant residual error is per-device
**output latency** (§7), not the network.

---

## 5. Playback model

### 5.1 State snapshot

The entire playback state is one small struct. The host is the only writer;
every mutation broadcasts a full new snapshot (no deltas — it's tiny):

```json
{
  "type": "state",
  "payload": {
    "rev": 17,                    // increments on every change
    "mediaId": "m_9f2c",          // current item, or null
    "status": "playing",          // "idle" | "loading" | "playing" | "paused"
    "anchor": {                   // meaningful when status == "playing"
      "hostTime": 8123456789,     // session-clock µs...
      "positionUs": 45000000      // ...at which media position was/will be here
    },
    "positionUs": 45000000,       // when paused: the frozen position
    "rate": 1.0
  }
}
```

The **anchor** is the whole trick: `position(t) = anchor.positionUs +
(t - anchor.hostTime) * rate`. Any client at any time can compute where
playback should be and correct itself. Play, seek, and resume are all just
"here is a new anchor."

### 5.2 Commands (host-side UI → state changes)

Guests never mutate state directly; a guest UI sends *requests* the host
validates against the sender's capabilities (§5.6) and then applies or
refuses:

```
G→H  request { action: "play"|"pause"|"seek"|"set_media"|"next"|"previous"
                       |"queue_move"|"queue_remove", ... }
```

- `seek` carries `positionUs`; `set_media`, `queue_move`, `queue_remove`
  carry `mediaId`; `queue_move` also carries `toIndex` (clamped host-side).
- `next`/`previous` skip within the queue, wrapping. They exist so a guest
  never has to compute "next" itself and race concurrent queue edits.
- A refused request gets `error { code: "not_allowed", fatal: false }` (§8)
  and changes nothing. Guests know their own capabilities from §5.6
  broadcasts, so a well-behaved UI disables the controls up front; the error
  is the backstop for races.

There is still exactly one state writer: the host.

### 5.3 Scheduled start (the sync-critical path)

Starting playback "now" is unsynchronizable. The host always schedules starts
in the near future:

```
H→*  state { status: "playing", anchor: { hostTime: <now + leadTime>, positionUs: P } }
```

- `leadTime` default 750 ms; the host may raise it if guests are slow (§6).
- Each client converts `anchor.hostTime` to its local clock via its offset and
  schedules audio to begin at exactly that instant using its platform's
  sample-accurate scheduler (AVAudioEngine / ExoPlayer / Web Audio
  `AudioBufferSourceNode.start(when)`).
- A client that misses the deadline (e.g. still buffering) joins late: it
  computes the current position from the anchor and starts there — it never
  delays the group.

### 5.4 Drift correction

Clients self-check ~1×/s: compare actual playback position against the anchor
formula. Error < 15 ms: ignore. 15–50 ms: correct by micro rate adjustment
(±0.5 % for a bounded interval) — inaudible. > 50 ms: hard resync (local
pause/seek/rejoin). No protocol messages involved; the anchor is the truth.

### 5.5 End of media

Durations travel in the playlist (§6.1 `durationUs`), which SHOULD be set for
audio items. Reaching the end of the current item does **not** change the
broadcast state on its own — the anchor formula is oblivious to file length,
so the snapshot would extrapolate `playing` forever. Instead the host applies
an end-of-media *policy* (advance to another track, pause at the end, or
stop) and broadcasts the resulting ordinary `state`; guests never see a
special message.

Clients MUST clamp positions computed from the anchor to `[0, durationUs]`
when the duration is known, and treat a position clamped at the end as
track-finished locally (stop pulling samples) while remaining converged on
the broadcast snapshot.

### 5.6 Roles, permissions, queue operations, moderation (v0.2)

The playlist doubles as the shared queue; who may do what to it (and to
playback) is governed by one host-owned **permission document**, revisioned
like the playlist, included in `welcome`, and broadcast on every change:

```
H→*  permissions {
       rev,
       policy:   { addTracks, controlPlayback, editQueue },   // guest role
       cohosts:  [ peerId, ... ],
       overrides:{ peerId: { "add_tracks": false, ... }, ... }
     }
```

**Roles.** `host` (the serving device; the reserved peer id `"host"` is used
for attribution — the host is not a joined peer, and is named by
`welcome.host`, §3.1) → `cohost` (promoted peers)
→ `guest` (everyone else).

**Capabilities.** `add_tracks` (upload, §6.4), `control_playback`
(play/pause/seek/select/skip), `edit_queue` (reorder; remove *others'*
tracks), `manage_members` and `change_settings` (host-only in v1, reserved
on the wire for later delegation).

**Effective capabilities** for a peer: host ⇒ everything; cohost ⇒
`{add_tracks, control_playback, edit_queue}`; guest ⇒ whatever `policy`
grants; then the peer's `overrides` entry is applied on top (a per-peer
grant or revoke). Removing your **own** contribution (`addedBy` = you) is
always allowed, `edit_queue` or not. The app-level presets map onto
`policy`: *Open* = all three true, *Jam* (default) = add + edit without
control, *Listen-only* = none.

**Queue semantics.** `queue_move`/`queue_remove` (§5.2) mutate the playlist
order and are answered with an ordinary §6.1 `playlist` broadcast — there is
no separate queue object. Removing the current item makes the host select
the item that slid into its slot (resuming playback if it was playing), or
stop when the queue empties. Removal drops the item from the playlist only;
the host MAY keep serving its bytes (guests can be mid-fetch; re-adding is
instant).

**Roles survive reconnects** (§3.3 resume keeps the peerId); a peer whose
grace expires — or who is kicked — is forgotten (dropped from `cohosts` and
`overrides`, with a broadcast when that changes the document).

**Moderation.** A kick is: fatal `error { code: "kicked" }` (§8) → socket
close `goingAway` → `peer_left`. No grace slot is kept, so a resume attempt
falls back to a fresh join — but a kicked client MUST treat the fatal error
as terminal and not auto-rejoin (rejoining deliberately via a new invite is
the human's call). Attribution and upload gating ride the honest-guest model
(§9): `X-LocalJam-Peer-Id` is client-asserted.

---

## 6. Media distribution

### 6.1 Playlist

```
H→*  playlist { rev, items: [ {mediaId, kind: "audio"|"video"|"image",
                               name, mime, sizeBytes, durationUs, sha256,
                               title?, artist?, album?, artworkId?,
                               addedBy?} ] }
```

`addedBy` attributes the contribution (§5.6): a peerId, the reserved
`"host"`, or absent for legacy items. Ordering is queue order (§5.6).
Rendering `"host"` as the literal word "Host" names nobody — every room has
exactly one — so clients SHOULD resolve it through `welcome.host` (§3.1)
and print the host's display name, falling back to the role word only when
the host shared none.

`title`/`artist`/`album` are tag metadata, `artworkId` references embedded
cover art servable via §6.5. All four are optional and **host-extracted**:
the host parses tags itself for both its own files and guest uploads (§6.4),
so guests never need a tag parser and every client sees identical metadata.
`name` (the display filename) remains the fallback when tags are absent.

### 6.2 Transfer

- Guest fetches `GET /media/{mediaId}` (with `Range` as needed) over the media
  plane. Auth: `Authorization: Bearer <sessionToken>`.
- v1 policy: **fully prefetch before playing** (LAN is fast; an entire class of
  rebuffer-desync bugs disappears). Streaming with a large lead buffer is a v2
  option for video.
- `sha256` lets guests cache across sessions and verify transfer.

### 6.3 Readiness

```
G→H  media_status { mediaId, state: "none"|"fetching"|"ready", progress: 0.87 }
```

The host tracks readiness per (peer, mediaId) and retains it across track
switches — readiness is per-file possession (guests prefetch the whole
playlist, §6.2), so a report on one item never supersedes a peer's readiness
for another. A peer's readiness for all media is forgotten when the peer is
dropped (matching §3.3: guests re-send `media_status` after resuming).

Host UX rule (not protocol): when selecting a new track, wait for all guests
`ready` or a 10 s timeout — whichever first — then broadcast the scheduled
`state`. Stragglers late-join per §5.3.

A client MAY send `media_status: ready` without ever fetching — e.g. a
rejoining guest that finds the file already in a local cache — so the host's
readiness gate does not wait on a redundant transfer.

### 6.4 Guest uploads

"Anyone adds songs to the jam": guests contribute files by uploading them to
the host over the media plane.

```
POST /media
Authorization: Bearer <sessionToken>
<body: the raw file bytes>
```

Metadata rides in request headers (the body stays raw bytes so nothing ever
re-encodes the file):

| Header                   | Required | Meaning                                          |
|--------------------------|----------|--------------------------------------------------|
| `X-LocalJam-Name`        | no       | Display filename, percent-encoded UTF-8          |
| `X-LocalJam-Mime`        | no       | MIME type (default `application/octet-stream`)   |
| `X-LocalJam-Kind`        | yes      | `audio` \| `video` \| `image`                    |
| `X-LocalJam-Duration-Us` | no       | Duration in µs (SHOULD be set for audio, §5.5). When absent the host MAY fall back to the tag-declared duration it extracts (§6.1); a sender-probed value wins because a decoder probe beats a tag claim |
| `X-LocalJam-Peer-Id`     | no       | Uploader's peerId — informational/diagnostics only |

The host streams the body to disk while hashing incrementally, computes the
`sha256` **itself** (it never trusts a sender-supplied digest), and derives
the `mediaId` from the digest exactly as it does for its own files
(`m_` + first 12 hex chars of the sha256). It then stores the bytes, appends
the item to the playlist, and broadcasts the ordinary §6.1 `playlist` —
uploads need no new control-plane message.

Responses:

- `201 Created` — item added; the body is the new item's §6.1 MediaItem JSON.
- `200 OK` — an item with this `mediaId` already exists. Because the mediaId
  is content-derived, that means the same bytes: uploads are **idempotent**.
  The body is the *existing* item's JSON (the first upload's metadata wins);
  no playlist change and no broadcast happens. (`409` is reserved for the
  cryptographically-negligible case of a mediaId collision with different
  content; hosts are not required to detect it.)
- `400 Bad Request` — missing/unknown `X-LocalJam-Kind`, or malformed
  percent-encoding in `X-LocalJam-Name`.
- `401 Unauthorized` — bad or missing bearer token (§9).
- `403 Forbidden` — the uploader (per `X-LocalJam-Peer-Id`, judged as a
  plain guest when absent) lacks `add_tracks` (§5.6).
- `411 Length Required` — no `Content-Length`. A body of undeclared length
  (chunked) cannot be budgeted before it is read, so hosts MAY refuse it
  outright; every LocalJam client declares a length.
- `413 Content Too Large` — the body exceeds the host's upload size limit
  (host policy; default 512 MB). The host MAY reject from `Content-Length`
  alone without reading the body.
- `507 Insufficient Storage` — the upload does not fit the host's
  whole-session budget (default 2 GB of guest uploads) or its playlist cap
  (default 500 items). Both are host policy; a guest SHOULD treat a 507 as
  "this room is full of music", not as an error to retry.

**Budget accounting.** A host that enforces a session budget MUST reserve the
declared `Content-Length` (and one playlist slot) when the request arrives,
not when it finishes: uploads overlap, and a check that only counts bytes
already stored is one every simultaneous upload passes before any of them
lands. The reservation is reconciled to the bytes actually received on
success and released on every failure — a 413, a 507, or a client that
disappears mid-body. Idempotent re-uploads (the `200` above) store nothing
and so spend nothing. Host-side additions (the host's own library) are not
remote input and are not budgeted.

### 6.5 Artwork

Embedded cover art rides the media plane as its own small resource:

```
GET /artwork/{artworkId}
Authorization: Bearer <sessionToken>
```

- `artworkId` = `a_` + first 12 hex chars of the sha256 of the artwork bytes —
  content-derived like `mediaId`, so every track of an album referencing the
  same cover bytes shares one artworkId (one transfer per album, and guests
  can cache across sessions without verification).
- Responses are full-body 200s with the artwork's `Content-Type` (no `Range`
  support — covers are small). `401` for a bad/missing token, `404` for an
  unknown id (including artwork of a playlist item that has since been
  replaced — clients fall back to no-artwork rendering).
- The host extracts artwork itself while registering media (§6.1); there is
  no upload path for standalone artwork.
- Artwork never gates readiness: `media_status` (§6.3) is about playable
  bytes only. A guest that never fetches artwork is a fully-ready guest.

---

## 7. Output-latency calibration (client-local)

Bluetooth headphones add 100–300 ms of device-specific latency — the largest
error source by far. Handling is client-local (each client shifts its own
scheduling earlier by its known output latency), but the protocol supports it:

- Clients SHOULD use platform-reported latency when available
  (`AVAudioSession.outputLatency`, Web Audio `outputLatency`, Android
  `AudioTrack#getTimestamp`-derived) as the default.
- Clients SHOULD offer a manual nudge (±500 ms, 10 ms steps), persisted per
  output device.
- `G→H media_status` MAY include `reportedLatencyUs` for host-side diagnostics.

---

## 8. Errors

```
H→G  error { code, message, fatal: bool }
```

Codes: `bad_token`, `version_unsupported`, `session_full`, `media_gone`,
`not_allowed` (§5.6, never fatal), `kicked` (§5.6, always fatal),
`internal`. Fatal errors are followed by a close.

---

## 9. Security model (v1 = honest-guest, hostile-network-lite)

- The session token (128-bit random, in the QR) gates both planes. Possession
  of the QR = invitation. A host that opts into mDNS discovery (§1)
  broadcasts the token to its network segment — deliberately widening the
  invitation to "everyone on this Wi-Fi" for that session.
- Traffic is plaintext in v1 (it's your living room / car). TLS with a
  self-signed cert pinned via the QR is the upgrade path — required before any
  future web guest client (browser secure-context rules), optional until then.
- Host MUST bind to LAN interfaces only, never 0.0.0.0 on a public interface.
  Binding one interface is not always possible (a phone on Wi-Fi *and* a
  hotspot needs one port on several), so hosts SHOULD also filter by remote
  address on both planes and answer `403` to anything off-LAN. "On-LAN" is
  loopback, RFC1918 v4, v4 link-local, and their v6 equivalents (`::1`,
  `fe80::/10`, `fc00::/7`, v4-mapped). An IPv6 **global** unicast remote
  (`2000::/3`) counts as on-LAN only when it shares a /64 with one of the
  host's own interface addresses — native-v6 home networks give every device
  a global address, and the shared prefix is the closest an address alone
  gets to "same link".
- **Discovery is not a channel of trust.** mDNS records are unauthenticated:
  anyone on the segment can answer, including with an address that is not on
  it. A joiner MUST apply the same on-LAN rule to every `host` candidate it
  is about to dial, whatever door the join URI came in by — QR, pasted link,
  deep link, or a nearby-room row — and SHOULD refuse candidates that are
  names rather than IP literals, since what a name resolves to is not
  knowable from the link. (`*.local` is the reasonable exception: multicast
  DNS answers only from the local link, and the resolved addresses can then
  be checked like any other.)
- An mDNS responder SHOULD answer only queries that arrive from port 5353,
  rate-limit its responses to at most one per second (coalescing the rest),
  and cap a response's size — an unauthenticated packet that costs a few
  dozen bytes to send must not buy an unbounded multicast to the whole
  segment.

### 9.1 Host-side limits (v0.2)

§9 is an honest-guest model; "honest" is not the same as "unbounded". A host
SHOULD bound what one LAN neighbour can spend of its memory, sockets, disk
and queue, and the defaults below are what the reference host ships. All of
them are host policy — none is negotiated, and a guest observes them only as
a reject, a close, or a 4xx/5xx.

| Limit | Default | On breach |
|---|---|---|
| Joined peers | 32 | `reject { full }`, socket closed |
| Half-open (pre-`hello`) sockets | 8 | `503` on the upgrade |
| One control frame, joined peer | 256 KB | close `1008` |
| One control frame, before `hello` | 16 KB | close `1008` |
| Time to send a valid `hello` | 10 s | socket dropped |
| One upload | 512 MB | `413` |
| Uploads this session | 2 GB | `507` |
| Playlist items from guests | 500 | `507` |

Two notes on the frame caps. They are counted in **UTF-8 bytes**, not
UTF-16 code units — a text frame of three-byte characters is three times its
`length`. And the cap is not a receive-buffer bound: WebSocket messages are
reassembled before a host sees them, so what a cap of this shape actually
bounds is the cost of parsing and acting on a frame, plus how many times a
sender gets to impose it (once — the socket goes with the frame). The
pre-`hello` cap is the one that bounds memory usefully, because a `hello` is
a few hundred bytes and the sockets it applies to have proved nothing yet.
For the same reason a rejected `hello` (`bad_token`, `full`) frees its
half-open slot immediately rather than when the close handshake completes.

---

## 10. Decided (v0.1 review)

- **Targets**: native mobile + desktop. Web is a possible later guest-only
  client; never a host.
- **Media priority**: audio-first. Video ships later as "best effort ±100 ms"
  on the same anchor model; images are trivial (`state.mediaId` + display).
- **Session lifetime**: one host; host death ends the room. No migration.
  "Multiple admins" shipped in v0.2 as co-hosts (§5.6) — still exactly one
  state writer. v0.2 distinguishes *ending* the room from *dying*: a
  deliberate shutdown says so (§3.4 `session_ended`), and only an
  unannounced death costs guests their host-gone timeout.
- **Encoding**: JSON v1; binary (CBOR/MessagePack) negotiable later via
  `hello.encodings`. Not a performance requirement — control plane is low-rate.

## 11. Open questions

1. **Video sync quality bar** — same anchor model, but players
   (AVPlayer/ExoPlayer) have coarser scheduling than audio engines. Define the
   acceptable drift for "cherry on top" video when it lands.
2. **TLS** — plaintext is fine for v1 native clients; a self-signed cert
   pinned via the QR becomes relevant if/when a web guest client appears
   (secure-context requirements) or if hostile-network hardening matters.
