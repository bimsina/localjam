# LocalJam Protocol 1.2

Synchronized local-network media playback. One **host** owns the files and the
authoritative session state; N **guests** join over LAN, fetch media, and play
in sync on their own output devices.

This document is **protocol 1** (wire `v: 1`). Later 1.x revisions only add
things a 1.0 peer can safely ignore (§2.1); anything a 1.0 peer would have to
understand is protocol 2. 1.1 adds one optional discovery key, `hname` (§1).
1.2 adds a second spelling of the join URL — `http://host:port/join#…`, the
same keys in its fragment (§1) — and the unauthenticated routes that serve a
browser guest its page (§1.1). Neither changes a frame: a 1.0 host never
serves the page and never prints the http form, and a 1.2 host still speaks
to a 1.0 guest exactly as before. The one place the two meet is a person
with a phone: a 1.0 or 1.1 joiner shown an http QR code cannot read it as an
invitation, because the only form it parses is `localjam://`. That form
stays valid — deep links and the browser page's "Open in app" button use
it, and the reference CLI prints it on a second line — but the QR code,
share text and copied link of a 1.2 host carry the http form only. A joiner
that cannot read it joins from its Nearby list (§1), which carries no URL
and reads the same in every 1.x. (No 1.0 or 1.1 app was released; this is
for other implementations.)

Design goals, in priority order:

1. Works fully offline (same Wi-Fi or host's hotspot; no internet, no accounts).
2. Audio is the primary medium. Video and images ride the same model as
   best-effort extras.
3. Sync target: ±40 ms across devices after calibration (per-person headphones,
   not shared-speaker grade).
4. Boring and debuggable over clever: JSON control plane, plain HTTP media plane.
5. Browsers join as guests — never hosts — from a page the host itself
   serves (§1.1), with no install and no internet. A browser guest speaks
   this same protocol; nothing in it is web-specific.

---

## 1. Transport

Two channels, both served by the host on a single TCP port:

| Plane   | Transport                  | Purpose                                  |
|---------|----------------------------|------------------------------------------|
| Control | WebSocket `ws://host:port/ws` | Session state, clock sync, playback commands |
| Media   | HTTP `http://host:port/media/{mediaId}` | File transfer. MUST support `Range` requests. Guest uploads via `POST /media` (§6.4) |
| Page    | HTTP `http://host:port/`, `/join`, `/web/…` | The browser guest's player (§1.1, 1.2). No token |

- Control messages are JSON text frames. The `hello` handshake reserves an
  `encodings` field (§3.1) so clients and host can negotiate a binary
  encoding (CBOR/MessagePack — same data model, no schema tooling) in a later
  version without a breaking change. Note the control plane is low-rate
  (a clock ping every 2 s, state changes only on user action) and the media
  plane is already binary HTTP — JSON is not a bottleneck here; binary framing
  is a polish item, not a performance requirement.
- WebSocket compression (`permessage-deflate`) is not used: hosts MUST NOT
  negotiate it and guests SHOULD NOT offer it (§9.1).
- UDP is deliberately **not** used: LAN TCP jitter is low enough that min-RTT
  filtering (§4) gets clock sync well under our target, and one transport
  keeps every client simple. A browser cannot send UDP at all, so a UDP
  clock-sync fast path could only ever be an optional extra for native
  guests — measure first.

### Discovery / join

Primary: the host renders a QR code / shareable string:

```
localjam://join?v=1&host=192.168.1.7&port=44100&token=<sessionToken>&name=RoadTrip
```

(The host may listen on multiple interfaces and encode several `host` candidates,
comma-separated; guests try them in order.)

**The http form (1.2).** The same parameters, spelled as a URL a phone
camera opens with no app installed — and at which the host serves its
browser player (§1.1):

```
http://192.168.1.7:44100/join#v=1&token=<sessionToken>&name=RoadTrip&host=192.168.1.7,192.168.43.1
```

- The path is `/join`. The **fragment is a query string with the keys of the
  `localjam://join` query** — `v`, `token`, `name`, `host` — in the same
  encoding (percent-escapes, `+` for a space). The URL's own query is not
  part of the link.
- The port is the URL's port, for every candidate. A `port` key in the
  fragment means nothing and is ignored.
- `host` in the fragment is optional. Absent, the URL's own host is the sole
  candidate; present, it lists every candidate (comma-separated, as above),
  and the URL's own host SHOULD be the first of them. An IPv6 literal is
  bracketed in the URL's authority, as in any URL (`[fe80::1%25en0]`), and
  bare in the `host` list.
- The token rides the fragment because a fragment is never part of an HTTP
  request: it is not in the request line and not in a `Referer`, so the
  request for the page, and any log of it, does not carry the token. That
  is all it buys. The browser keeps the whole URL, fragment and all, in its
  history (which it may sync to its user's other devices), and the token
  crosses the LAN in cleartext anyway, in `hello` and as the media plane's
  bearer (§9).
- A joiner accepts both forms and builds the same join parameters from
  either; whatever door a link came in by, the on-LAN rule (§9) applies to
  every candidate. A browser guest reads its own fragment, and its origin is
  its host.
- A 1.2 host's QR code and share text carry the http form. It picks the
  URL's host the way it picks the first `host` candidate. The `localjam://`
  form stays valid — "Open in app" deep links use it — and is the only form
  a pre-1.2 joiner understands, which therefore joins from Nearby rather
  than from the QR (see the caveat at the top).

Secondary: mDNS/Bonjour advertisement for in-app "nearby rooms" listing.
Hosts that opt in ("discoverable") advertise `_localjam._tcp` with TXT
records:

```
v=<major protocol version>  name=<sessionName>  token=<sessionToken>
hname=<host's display name>                       (1.1, optional)
```

`hname` is the host's display name — the name `welcome.host` carries
(§3.1) — so a nearby-room list can say whose jam it is before anyone joins.
It is additive (§2.1): a host with no name to share (hosting anonymously)
leaves the key out, and a joiner that does not know it ignores it like any
other TXT key it does not know, so a 1.0 joiner lists and joins the room
exactly as before. The value is UTF-8, trimmed, and at most 63 bytes; a
longer name is cut on a character boundary (between grapheme clusters where
the implementation can, never inside a code point) and trimmed again. A
joiner treats an empty or blank value as absent, holds what it reads to the
same trim and cap, and never carries it into the join URI. It is display
text and nothing more (§9).

Joiners resolve the service (addresses + port come from mDNS itself) and
build the same join parameters (either form). Including the token makes a
discoverable room one-tap joinable by ANYONE on the network — presence on
the LAN is the invitation (§9), which is why it is host-opt-in per session.
The host MAY change its mind while the room runs: withdrawing the
advertisement sends goodbye records (TTL 0, RFC 6762 §10.1) so browsers
drop the room at once, and advertising again starts it afresh. Nothing else
changes — guests already in the room stay, and the token is the same — and
a withdrawn advertisement stays withdrawn until the host turns it back on,
whatever the network does meanwhile.

A room's identity is its `token`, not its instance name. One room can be on
the wire under two names at once: DNS-SD conflict resolution renames a
registration whose name another responder already answers for ("Van Jam
6537 (2)" — the OS daemon and a host's own fallback responder meeting over
one name), and a re-advertisement can go out under a new name while the old
one is still cached. A joiner SHOULD list records that carry the same token
as one room, showing the advertisement that arrived most recently (it
carries the host's current addresses). A host SHOULD NOT announce one room
from two responders under the same instance name.
QR/link remains the first-class path — mDNS is blocked on hotspots,
guest-isolated Wi-Fi, and unlisted Bonjour types on Apple platforms
(`NSBonjourServices` must contain `_localjam._tcp`).

The `v` in a join URI or TXT record is the host's major protocol version. A
joiner MAY use it to flag rooms it cannot join, but the handshake (§2.1) is
authoritative.

### 1.1 The browser guest's page (1.2)

A host MAY serve a web build of a small listener app from the port it
already serves the protocol on, so that one person with the app installed
can host and everyone else joins from a browser — no install, no internet.
The page is just another guest (§3.1 `clientKind: "web"`); everything it does
after loading goes through `/ws`, `/media` and `/artwork` like any guest's.

| Route | Serves |
|---|---|
| `GET /` and `GET /join` | the page's `index.html` — `Content-Type: text/html; charset=utf-8`, `Cache-Control: no-store` |
| `GET /web/<path>` | the bundle file whose path is `<path>` — percent-decoded, and compared exactly once the HTTP stack has normalised the request path (below) — with its own `Content-Type`, `Cache-Control: no-cache` (`no-store` for `index.html`, which is the page), a strong `ETag` (the quoted first 16 hex characters of the file's sha256), and `304 Not Modified` when `If-None-Match` names that `ETag` (or `*`): status and headers only, with no `Content-Type` and no body framing |
| `HEAD` on either | the same status and headers, no body |
| any other method on either | `405`, `Allow: GET, HEAD` |
| `GET /web/<anything else>` | `404` |
| everything else | unchanged: `/ws`, `/media`, `/media/{id}`, `/artwork/{id}`; unknown paths `404` |

- **No token.** The page is not a secret: it carries no room name, no
  token and nothing about the session, and the same bundle ships in every
  copy of the host app. The token the page needs is in the URL fragment
  (§1), which the request for it never carries; the page then presents it in
  `hello` and as the bearer on the media plane like everyone else.
- **Everything else still applies.** The routes sit behind the same LAN-only
  rule (§9) and the same per-connection limits, header budget and
  `Connection: close` (§9.1) as every other request; a host never parses
  more of a page request than of any other. And because they need no
  token, a response has a send deadline (§9.1): a client that asks for the
  biggest bundle file and reads none of it loses the connection, rather
  than keeping one of the host's connection slots for as long as it likes.
- **Served from memory, from a fixed set.** The host holds the bundle as an
  immutable map of path → bytes and MIME type, loaded once (the reference
  app from its asset bundle, the reference CLI from `--web-dir`), and serves
  exactly its keys: there is no filesystem behind `/web/`, so no path —
  `..`, an encoded `%2e%2e`, a doubled slash — can reach anything else.
  (The reference host's HTTP stack removes dot segments from a request
  path before routing, RFC 3986 §5.2.4, so `/web/a/../b.js` is looked up as
  `b.js` and `/web/../x` is not a page route at all; what is compared with
  the keys is the path after that, percent-decoded.)
- **The page is never stored.** Wherever it is served — `/`, `/join`, or
  `/web/index.html` should anything ask for it there — the page carries
  `no-store`, so a phone that scanned last week's room never runs last
  week's player against this week's host. The rest of the bundle is
  revalidated on every load instead (`no-cache` and the `ETag`).
- **No player, no problem.** A host without a bundle (or without its
  `index.html`) answers `/` and `/join` with a small built-in page instead —
  "This LocalJam room has no browser player. Install the app." — that loads
  nothing else. A browser that opens the http join URL of such a room is
  told what to do rather than shown an error.
- The bundle is built to live under `/web/` (Flutter: `--base-href /web/`),
  so the `index.html` served at `/join` resolves its assets there. Nothing in
  it may need a path outside `/web/`, and none of its paths may collide with
  `/ws`, `/media` or `/artwork`. It makes no off-origin request of any kind
  — fonts and the renderer are bundled — because the room has no internet.

---

## 2. Message envelope

Every control message:

```json
{
  "v": 1,               // MAJOR protocol version (§2.1)
  "type": "play",       // message type
  "seq": 42,            // sender-local monotonically increasing sequence number
  "payload": { ... }
}
```

- `seq` is for logging/dedup; ordering is otherwise guaranteed by TCP.
- Frames are handled in arrival order. In particular a guest applies
  `welcome` before anything that follows it: a host may send its next
  broadcast right behind the welcome, and that broadcast is the newer state.

Message direction key below: **G→H** guest to host, **H→G** host to guest,
**H→\*** host broadcast to all guests.

### 2.1 Versioning

A protocol version is `major.minor`. Only the major travels on the wire
(`v`), because minors need no negotiation:

**Within a major version every change is additive, and every implementation
decodes tolerantly**, so a 1.x peer never breaks a 1.0 peer:

- An unknown message `type` is ignored.
- Unknown payload fields (and unknown envelope fields) are ignored. So are
  unknown keys in a discovery TXT record (§1).
- An entry of a list that does not fit its schema — a roster peer without a
  `peerId`, a playlist item — is dropped; the rest of the message stands.
- An unknown enum value never invalidates the message. Each field says what
  it means:

  | Field | An unknown value means |
  |---|---|
  | playlist item `kind` (§6.1) | the item is dropped; the rest of the playlist stands |
  | `state.status` (§5.1) | `loading`: make no sound, hold `positionUs`, converge on the next snapshot |
  | `media_status.state` (§6.3) | `none`: whatever it is, it is not possession |
  | `reject.reason` (§3.1) | still a reject, still final |
  | `error.code` (§8) | a generic error; `fatal` still decides whether the connection ends |
  | `session_ended.reason` (§3.4) | still terminal |
  | capability in `permissions.overrides` (§5.6) | that override is skipped |
  | `request.action` (§5.2) | the request is ignored |

So a 1.x addition must be safe to ignore. Anything a 1.0 peer would have to
understand to stay correct is a new major version.

**A different major version is a different protocol.** Hosts gate on the `v`
of `hello`: a host that does not speak it answers

```
H→G  reject { reason: "version", versions: [1] }      // the majors this host speaks
```

and closes. That reject is the one frame a host sends in a version it does
not speak: it **echoes the hello's `v`** in its envelope, so the guest's own
decoder reads it. For that to keep working, two things are frozen across
every future major version: the envelope's `v` and `type` fields, and
`reject { reason }`. A guest that receives any handshake reply in a major
version it does not speak — a `welcome`, or anything else — treats it
exactly as `reject { reason: "version" }`. A frame of another major version
outside the handshake is ignored.

---

## 3. Session lifecycle

### 3.1 Join handshake

```
G→H  hello     { token, clientName, clientKind: "flutter"|"web"|...,
                 caps: ["audio","video"], encodings: ["json"],    // encodings reserved for future binary negotiation
                 resumePeerId?,                                    // §3.3 reconnect: resume this peer slot
                 clientId? }                                       // stable per-device id, §3.3
H→G  welcome   { sessionId, sessionName,
                 you: {peerId, uploadKey},                         // uploadKey: §6.4
                 peers: [...], snapshot: <state §5.1>, playlist: [...],
                 permissions: <§5.6>,
                 host: {peerId: "host", clientName, clientKind},
                 hostAway? }                                       // §3.5; omitted when false
     — or —
H→G  reject    { reason: "bad_token" | "full" | "version" | "kicked",
                 versions? }                                       // with "version": §2.1
```

`welcome.snapshot` makes late join trivial: it contains the full current
playback state, and the guest converges on it like any other state update.

**Every reject is final** for the join it answers. A guest MUST NOT retry
the same join against the same host on its own, whatever the reason —
including a reason it does not recognise (§2.1), and including a reject that
answers an automatic reconnect (§3.3). `bad_token` means the room it knew is
gone (the host restarted it); `version` that the two apps cannot talk;
`kicked` that the host removed this device (§5.6); `full` that the room is at
its size (§9.1). Trying again is the human's call.

`you.uploadKey` is this peer's upload credential (§6.4): opaque, unguessable,
issued fresh on every join (a resume included), and valid only while that
connection is joined. It is never displayed and never shared.

`welcome.permissions` is the room's permission document (§5.6). A host that
omits it is treated as listen-only until a `permissions` broadcast arrives.

`welcome.host` is the host as a *person*: the reserved peer id `"host"` plus
the display identity the host device carries ("Silky Puffin"), same shape as
any `peers` entry. It is deliberately NOT a member of `peers` — the host is
not a joined peer (§5.6), and a client that counts the room must not
double-count it. Guests SHOULD use this name wherever they would otherwise
print the role word: the roster, and the `addedBy` byline for
host-contributed tracks (§6.1). Absent (or empty) means the host shares no
identity, and "Host" is the fallback.

`hello.clientId` is a stable, opaque per-device id — persisted by the
client, never displayed, unrelated to `clientName` (which several devices may
share, and which the user may change). See §3.3 and §5.6. It is optional on
the wire, but a client that leaves it out gives up everything keyed on it: it
can never resume (§3.3), its role and tracks live and die with its peerId,
and a kick cannot keep it out (§5.6). Clients SHOULD send one. (The
reference CLI, where one machine often runs several guests, mints a fresh
one per run rather than persisting it, since one id is one device.)

`hello.clientKind` says what sort of client this is — `"flutter"` for the
app, `"dart"`/`"cli"` for tools, `"web"` for the browser guest of §1.1 —
for display and diagnostics only. A host MUST NOT grant, refuse or shape
anything by it: it is a claim like `clientName`, and a browser guest is a
guest like any other, under the same permissions (§5.6). What differs is on
the browser's side and is client-local: its monotonic clock for §4 is
`performance.now()`, it keeps its `clientId` in the page's storage, it
prefetches whole files over `fetch` like any guest (§6.2) and reports
`ready` only once an item has *decoded* — a format the browser cannot play
(Ogg in Safari) is reported `none` and never blocks the room (§6.3 waits
only for `fetching`). Phase 1 of the reference page does not upload.

### 3.2 Presence

```
H→*  peer_joined { peer: {peerId, clientName, clientKind} }
H→*  peer_left   { peerId }
```

### 3.3 Liveness

The `clock_ping` stream (§4) is the heartbeat in both directions: a guest
pings every 2 s, and the host answers every ping with a `clock_pong`.
(Transport-level WebSocket ping/pong is not used.)

**Host side.** A peer from which nothing has arrived for 10 s is dropped. A
host that was itself not running in that time — an app suspended in the
background, a debugger pause — does not hold its own absence against its
guests: on resuming, it restarts its silence clocks and extends grace
windows by the time it was away, instead of dropping everyone whose frames
are still sitting in its socket buffers.

**Guest side.** A host whose battery died, that walked out of range, or whose
Wi-Fi was switched off sends no FIN, and TCP alone leaves the connection
looking open for minutes. So a guest MUST treat a connection on which
nothing at all — no pong, no broadcast — has arrived for three ping intervals
(6 s at the default 2 s) as dead, close it, and reconnect as below. The
media plane is bounded the same way (§6.2). Whether the host said it was
going away first (§3.5) changes how long the guest keeps reconnecting, not
how fast it notices.

**A browser guest MUST schedule its pings from a source the browser does
not throttle.** A page's own timers are no schedule to keep a heartbeat on:
once a tab has been hidden for a while and is not audibly playing, browsers
coalesce its timers — Chrome, after five hidden minutes, to one wake-up a
minute. A guest pinging on them goes quiet for up to a minute, the host
drops it after 10 s, and a listener whose room is paused, or whose phone
tab is in the background, leaves and rejoins every few dozen seconds. The
reference page ticks its ping schedule, its watchdog and its reconnect
backoff from a dedicated Web Worker, whose timers keep time and whose
messages reach the page as tasks, not timers. The cadence and every
timeout above are unchanged; only where the ticks come from differs.

**Reconnecting.** Guests reconnect by sending `hello` with the same `token`,
the same `clientId`, plus `resumePeerId: <their old peerId>`; the host keeps
a 30 s grace slot per dropped peer. A valid resume reclaims the old peerId
(re-announced via `peer_joined`); an expired, unknown or unproven
`resumePeerId` silently falls back to a fresh join. Readiness reports (§6.3)
are forgotten on drop — guests re-send `media_status` after resuming.

**A resume MUST be proved with `clientId`.** The grace slot records the
`clientId` the dropped connection said hello with, and the host MUST honour
`resumePeerId` only when the new `hello` carries a non-empty `clientId` equal
to it. Everything else about a resume is public or shared: peerIds travel the
room in `welcome.peers`, `peer_joined` and `peer_left`, and the token is what
every guest in the room already holds. A slot keyed on those alone is
claimable by anyone who watched someone drop. The `clientId` is the only part
of a resume the claimant has not been told.

A `hello` whose resume is not proved is not an error: it is an ordinary fresh
join with a **new** peerId. Nothing carries over from the slot it named,
which stays where it was until its owner returns or the window expires. (The
device's own role, overrides and tracks do follow it — by `clientId`, §5.6 —
but only the device that holds that id gets them.) A client that sends no
`clientId` can never resume; it reconnects as a new peer.

**One device is one peer.** A silence timeout is the only way to notice a
peer that died without closing its socket — an app force-quit, a process
killed while backgrounded, a phone that left the network — and for those
10 s the corpse is still in the roster. A device that comes back inside that
window would otherwise join beside a ghost of itself: everyone sees a
phantom, and the rejoining guest is handed one in `welcome.peers`.

So a host that receives a `hello` carrying a `clientId` already held by a
connected peer MUST drop that older connection first (a plain `peer_left`,
no grace slot kept) and only then admit the new one, which joins as a fresh
peer and gets its device's role and tracks back (§5.6). The new socket is the live one
by definition — the device is on it. A client that sends no `clientId` is
never superseded, and two devices with different ids both stay however
identical their `clientName`s are.

**Unless it is a resume of that very connection.** The two sides do not
notice a dead link at the same moment: the guest's watchdog (three ping
intervals, 6 s) fires well before the host's 10 s silence timeout, so a
guest whose Wi-Fi blipped is typically back with `resumePeerId` while its
old socket still looks connected on the host. When the `hello`'s
`resumePeerId` is exactly the peerId of the connection its `clientId`
holds, the host MUST treat it as the resume it is: drop the old connection
the way a silence timeout would (`peer_left`, grace slot kept), then resume
it at once — same peerId, role, overrides and `addedBy` ownership. Handing
it a fresh peerId instead would make a guest that only blinked leave and
rejoin in everyone's roster, and re-credit its tracks under a new name
(§5.6) — churn for a connection that never really went away. A `hello`
with the same `clientId` and any other (or no) `resumePeerId` supersedes as
above.

`clientId` is transport bookkeeping, not authentication: like everything
else in §9's honest-guest model it is client-asserted, and a room where
guests forge each other's ids is a room with a worse problem. It is never
broadcast.

### 3.4 Session end

```
H→*  session_ended { reason: "host_ended" }
```

Broadcast by the host immediately before it closes every control socket
(with the WebSocket **normal closure** code, 1000, rather than
`goingAway`). It means the room is over *on purpose* — the host tapped "End
jam" — and it is terminal: a guest that receives one MUST NOT reconnect,
and MUST NOT wait out any host-gone timeout, whatever the `reason` says.
An unrecognized reason is still terminal; treat it as an end you do not have
copy for, never as a message to ignore.

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

### 3.5 Host away

```
H→*  host_status { away: true | false }
```

A phone host that moves to the background may be suspended by its OS — on
iOS a backgrounded host that is not playing audio is suspended by design —
and from the outside that looks exactly like a host that died: it stops
answering. `host_status` lets the host say which one it is.

- The host sends `away: true` **just before** it expects to stop answering
  (when its app leaves the foreground), and `away: false` as soon as it is
  back. The current value also rides `welcome.hostAway`, so a guest that
  (re)joins mid-nap is told too; absent means `false`.
- A guest still notices the silence within seconds (§3.3) and keeps trying
  to reconnect. What `away` changes is how long it keeps trying before it
  gives the room up: a host that said it is asleep gets a much longer
  host-gone timeout than one that simply vanished, and the guest can say
  why it is waiting ("The host's phone is asleep") instead of
  "Reconnecting…". The flag stays in force through the drop and the
  reconnect attempts; it clears when the host says `away: false` or a fresh
  `welcome` says it is not away.
- `away` is not a goodbye. Only `session_ended` (§3.4) ends a room.

---

## 4. Clock synchronization

The host's monotonic clock is the **session clock** (`hostTime`, in
microseconds, from an arbitrary epoch — NOT wall clock; wall clocks jump).

NTP-style exchange, initiated by each guest:

```
G→H  clock_ping { t0 }                 // guest monotonic µs at send (a browser: performance.now())
H→G  clock_pong { t0, t1, t2 }         // t1 = host receive, t2 = host send
                                        // guest records t3 = receive time
offset = ((t1 - t0) + (t2 - t3)) / 2
rtt    = (t3 - t0) - (t2 - t1)
```

With non-negative one-way delays the true offset lies within ±rtt/2 of a
sample's `offset`; queueing in either direction is what moves it there. A
sample with `rtt < 0`, `t3 < t0` or `t2 < t1` cannot come from a real round
trip and MUST be discarded.

Guest algorithm (client-side, not on the wire; reference implementation:
`localjam_core` `ClockSync`):

- Join: burst of 8 pings; keep the sample with **minimum RTT** (least queued,
  most symmetric) as the initial offset; synchronized after 4 samples.
  Guests SHOULD space the burst ~100 ms apart: sent back-to-back over one TCP
  connection, a single delayed pong (Wi-Fi power save) delays all of them
  equally and the whole burst reads the same biased offset — up to 150 ms
  off under aggressive power save. Until the estimate has warmed up (below),
  min-RTT selection carries on: a reading with under half the seed's RTT
  that proves the estimate more than 1 ms off becomes the new seed.
- Steady state: 1 ping every 2 s; accept a sample only if its RTT is within
  1.5× of the **RTT floor**: the 3rd-lowest RTT among the samples (accepted
  or not) of the last 60 s. The floor falls at once but rises only after the
  higher value has held for 120 s, and both windows age on *pinging* time (a
  stretch without pings counts as at most 10 s). An all-time minimum never
  recovers from one lucky sample or a network that got worse; a floor that
  rises as soon as a window happens to hold fewer than three clean pongs
  flaps under power save (one clean pong in ten) and admits readings
  10–20 ms off; and silence is no evidence that the path got worse.
- The estimate is a line, `offset(t) = level + skew·(t − t_level)`: two
  phones' crystals differ by tens of ppm (100 ppm = 6 ms per minute), and a
  Linux host's `CLOCK_MONOTONIC` is additionally frequency-slewed by NTP
  (up to ±500 ppm). `skew` is the weighted least-squares slope over the
  accepted samples of the last 5 min — keeping at least the 30 newest
  however old, so a long ping gap refines the known rate instead of
  replacing it — shrunk toward a reference rate (0 at join; the previous
  rate after a re-seed) under a ±100 ppm prior, with the readings' noise
  estimated from the residuals plus an a-priori RTT/4 worth one reading (so
  three nearly collinear readings cannot claim a precise slope), and
  bounded to ±1000 ppm. The level is an EWMA (α ≈ 0.1) of accepted readings
  taken at each reading's own time along the line, so it does not lag a
  drifting clock; it pivots at the readings' time centroid while the fit
  spans under half its window, and at the newest reading once it is mature.
  A sample's weight falls with its RTT excess over the floor (half of which
  bounds its error). Until the samples since the seed (join burst or
  re-seed) are worth 1/α − 1 floor-quality ones, the level is their
  weighted mean instead. Time conversions extrapolate along the line, so
  they stay exact between pings and through stretches of rejected samples.
- The applied mapping (session time ↔ local time) is continuous and
  monotonic: each sample re-anchors it at its `t3` at the value it already
  had there, sets its slope to the skew and closes the remaining gap to the
  estimate at ≤ 1 ms per second (20 ms/s while the join burst refines and
  during the warm-up, when a queued burst can be tens of ms off), after
  which it follows the estimate. `localToHost(now)` therefore never runs
  backwards. Large error (> 50 ms) ⇒ hard resync: the mapping steps and the
  player pauses locally, re-anchors and rejoins playback at the correct
  position. Players map a past anchor relative to now —
  `localNow − (sessionNow − anchor.hostTime)` — so it is exactly as accurate
  as the mapping at now; extrapolating the skew back to an anchor 10 min old
  would put it skew × age (60 ms at 100 ppm) off. Future anchors go through
  the mapping.
- Clock jumps (device deep sleep pauses the monotonic clock): a sample that
  provably disagrees with the estimate by > 50 ms is a candidate — by its
  disagreement minus rtt/2 if it passed the gate, minus its whole rtt
  otherwise, so the gate can never hide a jump; 2 consecutive mutually
  consistent candidates confirm it. A reading that contradicts the pending
  candidate ends the run; one whose RTT is too large to tell either way
  leaves it open (up to 60 s). Up to 0.5 s: re-seed the estimate from the
  lowest-RTT candidate and hard-resync (keep the skew). Beyond 0.5 s:
  discard all sync state except the skew (offset, RTT floor, fit, mapping)
  and re-run the join burst — the reference guest sends a fresh 8-ping
  burst, 100 ms apart, the moment its estimator resets, and on demand after
  a device sleep it detected itself — hard-resyncing playback.

Expected accuracy — simulated, not yet measured on devices; clocks up to
±200 ppm apart, 60-minute sessions, worst run of several seeds, |error| of
the applied mapping. The estimator assumes the path is **symmetric on
average**: a fixed difference between the one-way delays is invisible to
any NTP-style exchange and biases the offset by half of it (1 ms up / 3 ms
down reads 1 ms off for the whole session). On top of that bias: p99
≈ 0.25 ms on good Wi-Fi (also with bursty or packet-to-packet-correlated
queueing, < 1 ms), ≈ 0.6 ms with a 20-minute stretch of a congested
10 ms-floor network, ≈ 1.1 ms when joining on one, ≈ 1.5 ms when the
crystals' rate swings ±20 ppm every 10 minutes on it. Under heavy power save
(90 % of pongs delayed 0–300 ms) the error stays under 1.5 ms once the
first clean pongs have repaired a queued join burst (seconds to a minute,
at most one hard resync). Through a 30-minute ping gap the extrapolated
mapping stays within 0.8 ms; a rate change during the gap is invisible
until pings resume (40 ppm over 30 min ≈ 70 ms ⇒ one hard resync). The
dominant residual error is per-device **output latency** (§7), not the
network.

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

`rate` is a finite number in `[1/32, 32]` (absent means 1.0) — the range
every audio engine behind the protocol accepts. A snapshot with any other
rate is malformed, not a later version's value: the frame carrying it is
dropped (§2.1), and the guest keeps the snapshot it had.

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
- `set_media` selects an item and keeps the room doing what it was doing.
  A room that is playing — or starting: a start held by the §6.3 readiness
  gate — plays the selected item from its start (selected, then started
  with a fresh scheduled anchor, §5.3, through the readiness gate like any
  new track). A room that is paused, cued (`loading`) or idle cues it:
  `loading` at position 0 until someone plays. Selecting the item that is
  already current changes nothing — a double tap, or a request repeated
  after a reconnect, must not restart the song for the whole room;
  starting it over is a `seek` to 0. The host's own UI selects with the
  same semantics.
- `next`/`previous` skip within the queue, wrapping, with the same
  keep-playing rule (a skip in a one-item queue starts it over). They exist
  so a guest never has to compute "next" itself and race concurrent queue
  edits.
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
  delays the group. (The one exception the host makes is bounded and on its
  own side: the §6.3 readiness gate.)

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

The host learns the end two ways:

- **From the duration**: the anchor-derived position reaches `durationUs`.
  The host acts at that instant (the reference host arms a timer for it on
  every state change), not on its next periodic check: the next track's
  scheduled start already costs the room the §5.3 lead, and a late check
  would add up to a second of silence to every transition.
- **From its own player**: the host plays every item too, and its player
  knows when the file actually ran out. This is the only way to end an item
  whose `durationUs` is unknown — without it such an item would hold the
  queue forever. The host accepts its player's report only for the current
  item, while the room is playing it, after the scheduled start, and for the
  snapshot the player was following (a report from before a later seek is
  stale). When the duration IS known the report is a cross-check, honoured
  within 5 s of that duration: it can bring a slightly overlong declared
  duration forward, never cut a track short.

A `durationUs` that is zero, negative, or absurd (over a week) is no
duration: hosts treat it as unknown (§6.4), and decoders read a non-positive
one as absent.

**A paused room never starts playing because of an end.** A room can sit at
the end while paused — the `pause` policy leaves it there, and a seek to the
end while paused puts it there. Under `advance` such a room moves to the next
item but stays stopped at its start (`loading`); only a room that was
playing plays on. Under `pause` nothing changes; under `stop` the room goes
idle.

The policy runs once per end, and an end is per run towards it: `play` on
an item that is already at its end (paused there) starts a new run that ends
as soon as it starts. The room plays nothing for the scheduled-start lead
(§5.3), reaches the end again, and the policy runs again — a second end of
the same item, and under `pause` the room pauses again. A host that wants
"play" on a finished track to start it over seeks to 0 first; the reference
host does not do that for it.

Clients MUST clamp positions computed from the anchor to `[0, durationUs]`
when the duration is known, and treat a position clamped at the end as
track-finished locally (stop pulling samples) while remaining converged on
the broadcast snapshot.

### 5.6 Roles, permissions, queue operations, moderation

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
`welcome.host`, §3.1) → `cohost` (promoted peers) → `guest` (everyone else).
The id `"host"` is never a remote peer's: no joined peer is ever assigned
it, and nothing a remote device sends can claim it (§6.4).

**Capabilities.** `add_tracks` (upload, §6.4), `control_playback`
(play/pause/seek/select/skip), `edit_queue` (reorder; remove *others'*
tracks), `manage_members` and `change_settings` (host-only in protocol 1,
reserved on the wire for later delegation).

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
instant — a guest re-uploading the same bytes puts it back, §6.4).

**Moderation follows the device.** The document is keyed by peerId, because
that is what guests know themselves by. But a peerId is one connection's
name, and a phone that naps past its grace window, or force-quits and comes
back, returns with a new one. So the host also remembers what it made each
*device* — keyed by `hello.clientId` (§3.3), for the lifetime of the
session — and re-applies it whenever that device joins: a co-host comes back
a co-host, a guest whose `add_tracks` was revoked comes back revoked. When a
peerId goes for good (grace expired, superseded, kicked) it is dropped from
`cohosts` and `overrides` with a broadcast; the device's record stays with
the host. A device that sends no `clientId` cannot be recognised, so its
role lives and dies with its peerId.

**Attribution follows the device too.** A phone killed and relaunched, one
that napped past its grace window, or one kicked and let back in rejoins
with a new peerId — and its tracks are still its own. So when a device
joins under a peerId other than the one its contributions carry, the host
re-credits every item that device added this session (`addedBy` → the new
peerId) and broadcasts the ordinary §6.1 `playlist`: the joiner's
`welcome.playlist` already says so, and everyone else gets the broadcast
after the joiner's `peer_joined`, so the new id is a name they can print.
Only `addedBy` changes — the order, the items and the playback state are
untouched, and no `state` is broadcast. An upload whose body is still
arriving when its device rejoins is credited to the peerId the device holds
when it lands. A device that never comes back keeps the attribution it left
with (its old peerId, which bylines may render as someone who left), and a
device that sends no `clientId` cannot be recognised, so its attribution,
like its role, stays with the peerId. Wire-wise nothing is new: guests
compare `addedBy` with their own peerId exactly as before.

**Kick.** A kick is: fatal `error { code: "kicked" }` (§8) → socket close
`goingAway` → `peer_left`. No grace slot is kept, the device loses any
co-host role, and **the device stays out for the rest of the session**: a
later `hello` with its `clientId` is answered `reject { reason: "kicked" }`
(final, §3.1) until the host lets it back in. A device that sent no
`clientId` cannot be held: its later `hello` is an ordinary join. The host
has nothing stable to refuse it by — not its `clientName`, which anyone may
share, and not its address, which phones behind one NAT or on one hotspot
share, so refusing by address would lock the room's other guests out with
it. A host UI SHOULD NOT promise such a guest stays out. A kicked client
MUST treat the fatal error as terminal and not auto-rejoin. An upload of the device's
whose body is still arriving goes with it: it is refused when it lands
(`403`, §6.4), and nothing of it is added or kept.

**Attribution and upload gating** use the per-peer upload key (§6.4): an
upload is credited to — and permission-checked as — the joined peer whose
key it presents. Nothing a sender merely claims decides either.

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
`"host"`, or absent. It follows the contributing device: when that device
rejoins under a new peerId the host re-credits its items and re-broadcasts
the playlist (§5.6). Ordering is queue order (§5.6). Rendering `"host"` as
the literal word "Host" names nobody — every room has exactly one — so
clients SHOULD resolve it through `welcome.host` (§3.1) and print the host's
display name, falling back to the role word only when the host shared none.

`title`/`artist`/`album` are tag metadata, `artworkId` references embedded
cover art servable via §6.5. All four are optional and **host-extracted**:
the host parses tags itself for both its own files and guest uploads (§6.4),
so guests never need a tag parser and every client sees identical metadata.
`name` (the display filename) remains the fallback when tags are absent.

An item whose `kind` a client does not know is one it cannot play: it drops
that item and keeps the rest of the playlist (§2.1).

### 6.2 Transfer

- Guest fetches `GET /media/{mediaId}` (with `Range` as needed) over the media
  plane. Auth: `Authorization: Bearer <sessionToken>`.
- Policy: **fully prefetch before playing** (LAN is fast; an entire class of
  rebuffer-desync bugs disappears). Streaming with a large lead buffer is a
  later option for video.
- `sha256` lets guests cache across sessions and verify transfer.
- Media requests are bounded like the control plane (§3.3): a guest SHOULD
  give up on a connect, a response, or a gap between body bytes that takes
  longer than a few seconds (the reference guest uses 10 s), report
  `media_status: none`, and retry later. A transfer from a host that died
  mid-body otherwise never ends.
- A guest SHOULD bound a body by the size it was given — the item's
  `sizeBytes`, or the `Content-Length` when `sizeBytes` is 0 or past the
  guest's own ceiling — plus a little slack, never past that ceiling (the
  reference guest: 64 KB of slack, 512 MB, the reference host's cap on one
  upload), and abandon the transfer past it. The host's word alone is no
  bound: a browser tab holds the body in memory.
- A fetch the guest reported `fetching` for that ends without the file —
  a stall, a break, an over-size or mismatched body, or the guest's own
  storage failing to open or flush — is reported `none` (§6.3), so the
  host's readiness gate never waits on it.
- One request per connection: hosts MAY answer every media-plane request
  with `Connection: close` (the reference host does, §9.1), so guests MUST
  NOT depend on keep-alive. On a LAN a fresh connection per transfer costs
  nothing.
- Guests SHOULD bound how many media-plane connections they hold open to
  their host at once — media, artwork and uploads together — well under the
  host's per-address cap (§9.1; the reference guest: 6), and queue the rest.
  A burst of 40 cover fetches over 40 connections draws `503`s.

### 6.3 Readiness

```
G→H  media_status { mediaId, state: "none"|"fetching"|"ready", progress: 0.87 }
```

The host tracks readiness per (peer, mediaId) and retains it across track
switches — readiness is per-file possession (guests prefetch the whole
playlist, §6.2), so a report on one item never supersedes a peer's readiness
for another. A peer's readiness for all media is forgotten when the peer is
dropped (matching §3.3: guests re-send `media_status` after resuming).
Reports on media ids the host does not serve are ignored.

A client MAY send `media_status: ready` without ever fetching — e.g. a
rejoining guest that finds the file already in a local cache.

**Readiness gate** (host behaviour, not a message). When the host starts a
newly selected item — the room is `loading` it — while some joined guest's
latest report on it is `fetching`, the host holds the scheduled start for a
short while (the reference host: at most 2.5 s), and sends it the moment no
guest is fetching the item any more: each finished, gave up (`none`), or
left. Only guests actively transferring the item are waited for — never one
that never reported, reported `none`, or already holds the file — so a
stalled or broken guest costs the room that short wait once per track, and
stragglers late-join per §5.3. Resuming from `paused` never waits.

### 6.4 Guest uploads

"Anyone adds songs to the jam": guests contribute files by uploading them to
the host over the media plane.

```
POST /media
Authorization: Bearer <sessionToken>
X-LocalJam-Upload-Key: <welcome.you.uploadKey>
<body: the raw file bytes>
```

Metadata rides in request headers (the body stays raw bytes so nothing ever
re-encodes the file):

| Header                   | Required | Meaning                                          |
|--------------------------|----------|--------------------------------------------------|
| `X-LocalJam-Upload-Key`  | yes      | The uploader's key from its `welcome` (§3.1)     |
| `X-LocalJam-Name`        | no       | Display filename, percent-encoded UTF-8          |
| `X-LocalJam-Mime`        | no       | MIME type (default `application/octet-stream`)   |
| `X-LocalJam-Kind`        | yes      | `audio` \| `video` \| `image`                    |
| `X-LocalJam-Duration-Us` | no       | Duration in µs (SHOULD be set for audio, §5.5). When absent the host MAY fall back to the tag-declared duration it extracts (§6.1); a sender-probed value wins because a decoder probe beats a tag claim. A value that is not positive, or is over a week, is treated as absent |

**Who is uploading.** The session token proves only that a request comes
from someone holding the invite — for a discoverable room, everyone on the
Wi-Fi (§9). The upload key proves *which joined peer* it is: the host
credits the item to that peer (`addedBy`; to its device, really — if the
device rejoined under a new peerId while the body was arriving, the new one,
§5.6) and checks `add_tracks` against that peer's effective capabilities
(§5.6). A key belongs to one connection
and dies with it — no new request is accepted on it once that connection
drops (one already under way is judged below); there is no key for
`"host"`, and any self-declared peer id a request carries is ignored.

The key is judged twice: when the request arrives, and again when its body
has arrived, just before anything is added — a body takes a while, and the
room moves on meanwhile. At that second look the upload lands only if its
uploader is still in the room: the connection that holds the key is still
joined; or it dropped, but its peer is still inside its §3.3 grace window
(its peerId, role and tracks are being held for it, and it is credited to
that peerId); or the device has rejoined under a new peerId (§5.6, and it
is credited there). The body travels on a connection of its own, so a blip
on the control socket MUST NOT throw away an upload that arrived whole. A
device kicked meanwhile never lands one, and neither does a peer gone for
good without its device coming back — kicked without a `clientId` to
recognise it by, superseded, or past its grace window: the answer is `403`,
the received bytes are deleted and the reservation released, as for any
refusal.

The host streams the body to disk while hashing incrementally, computes the
`sha256` **itself** (it never trusts a sender-supplied digest), and derives
the `mediaId` from the digest exactly as it does for its own files
(`m_` + first 12 hex chars of the sha256). It then stores the bytes, appends
the item to the playlist, and broadcasts the ordinary §6.1 `playlist` —
uploads need no new control-plane message. The host plays the stored file
itself when the room selects the item (it never fetches its own media
plane), and keeps it for the rest of the session, whether or not the item
stays in the playlist (§5.6 removal keeps bytes servable).

Responses:

- `201 Created` — item added; the body is the new item's §6.1 MediaItem JSON.
  That includes content the host already has but that is no longer in the
  playlist (removed, §5.6): it goes back in, credited to this uploader
  (`addedBy`, and its device), with the first upload's other metadata, and
  the ordinary §6.1 `playlist` is broadcast. Nothing new is stored, and it
  is judged like any upload: `add_tracks`, the playlist cap. Answering such
  an upload `200` would tell the guest a track is queued that is not.
- `200 OK` — an item with this `mediaId` is already in the playlist. Because
  the mediaId is content-derived, that means the same bytes: uploads are
  **idempotent**. The body is the *existing* item's JSON (the first upload's
  metadata, and its `addedBy`, win); no playlist change and no broadcast
  happens. (`409` is reserved for the
  cryptographically-negligible case of a mediaId collision with different
  content; hosts are not required to detect it.)
- `400 Bad Request` — missing/unknown `X-LocalJam-Kind`, or an
  `X-LocalJam-Name` that is not valid percent-encoding of UTF-8 (`%zz`, or
  `%FF`).
- `401 Unauthorized` — bad or missing bearer token (§9).
- `403 Forbidden` — no upload key, a key that belongs to no joined peer, or
  a peer that lacks `add_tracks` (§5.6); or, once the body has arrived, an
  uploader no longer in the room (see *Who is uploading* above).
- `411 Length Required` — no `Content-Length`. A body of undeclared length
  (chunked) cannot be budgeted before it is read, so hosts MAY refuse it
  outright; every LocalJam client declares a length.
- `408 Request Timeout` — the body stalled: over some window (the
  reference host: 30 s) it delivered less than the host's minimum rate (32
  KB/s), or nothing at all. The upload is abandoned (see below).
- `413 Content Too Large` — the body exceeds the host's upload size limit
  (host policy; default 512 MB). The host MAY reject from `Content-Length`
  alone without reading the body.
- `429 Too Many Requests` — this peer already has as many uploads in flight
  as the host allows at once (default 2). Retry when one finishes.
- `507 Insufficient Storage` — the upload does not fit the host's
  whole-session budget (default 2 GB of guest uploads) or its playlist cap
  (default 500 items). Both are host policy; a guest SHOULD treat a 507 as
  "this room is full of music", not as an error to retry.

**Refusals arrive after the body.** Most HTTP clients send a request's whole
body before they read any response, and a host that answers mid-body and
closes resets the connection under them: the client sees a broken pipe, not
the reason. So a host that refuses an upload before reading it SHOULD first
read and discard what is left of the body — bounded, so a refusal is never a
way to hold the host (§9.1): the reference host reads at most 64 MB, for at
most its 10 s hello deadline, and otherwise answers and closes at once.
A refusal of a larger body (a `413` always is one) or of a body that does not
arrive in time (a `408` usually is one) can therefore reach the client only
as a connection error, and clients SHOULD present it as a failed upload, not
as a dead host.

**Budget accounting.** A host that enforces a session budget MUST reserve the
declared `Content-Length` (and one playlist slot) when the request arrives,
not when it finishes: uploads overlap, and a check that only counts bytes
already stored is one every simultaneous upload passes before any of them
lands. The reservation is reconciled to the bytes actually received on
success and released on every failure — a 413, a 507, or a client that
disappears mid-body. Re-uploads of content the host already has (the `200`
above, and a removed item put back) store nothing and so spend nothing.
Host-side additions (the host's own library) are not remote input and are
not budgeted.

**Abandoned uploads leave nothing behind.** A host holds an upload's
reservation, its playlist slot and its partial file only while the body is
actually arriving. A body that stalls (`408`), breaks a cap, or whose client
vanishes is abandoned: the reservation is released and the partial file is
deleted on every such path — a partial file that outlived its request would
be disk the budget no longer counts. Bodies have no other time limit, so the
stall rule is what bounds how long a client that declares 512 MB and then
goes quiet (or trickles a byte now and then) can hold a share of the
budget, and the per-peer in-flight cap (`429`) bounds how much of it one
peer can hold at a time.

**Tag reading is bounded too.** The host parses an uploaded file's tags
(§6.1) under a read budget tied to its artwork cap (§6.5): no single read
of more than the cap, and not much more than twice the cap in all. A cover
over budget is skipped unread (the track keeps its title); a text frame over
budget costs the upload its tags, never the host's memory. A host's own
library is not remote input and is read in full.

Uploads are bounded in time like every media request (§6.2): a guest gives
up on a host that stops reading the body or never answers it.

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
  no upload path for standalone artwork. Cover art in a guest upload larger
  than the host's cap (default 8 MB, matching what guests will hold in
  memory) is dropped: the track keeps playing, without a cover.
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

**Browser guests** (§1.1) have the least to go on. Web Audio reports
`AudioContext.outputLatency` plus `baseLatency` in Chromium and Firefox, and
a page should schedule by their sum; Safari reports neither (or zero), so on
an iPhone the platform default is no correction at all, and Bluetooth
headphones are a few hundred milliseconds late until the listener nudges.
A browser guest SHOULD therefore make the manual nudge prominent and keep
it per page (a page cannot identify the output device). A page also maps
`anchor.hostTime` into its audio clock through
`AudioContext.getOutputTimestamp()` where it can, which is coarser than a
native engine's scheduler; browser listening is best-effort within the §5.4
correction bands rather than held to the native target.

---

## 8. Errors

```
H→G  error { code, message, fatal: bool }
```

Codes: `not_allowed` (§5.6, never fatal), `kicked` (§5.6, always fatal),
`media_gone`, `internal`, and `bad_token`, `version_unsupported`,
`session_full` (reserved: joins are refused with `reject`, §3.1). Fatal
errors are followed by a close. An unknown code is a generic error; `fatal`
still says whether the connection is ending (§2.1).

---

## 9. Security model (honest-guest, hostile-network-lite)

- The session token (128-bit random, in the QR) gates both planes. Possession
  of the QR = invitation. A host that opts into mDNS discovery (§1)
  broadcasts the token to its network segment — deliberately widening the
  invitation to "everyone on this Wi-Fi" for that session.
- Within the room, guests are trusted to be honest about what only they can
  know (their `clientName`, their `clientId`), but not about *who they are*
  where it gates something: uploads are attributed and permission-checked by
  a host-issued per-peer key (§6.4), never by a claim. Holding the token does
  not make a device a member — joining does.
- **Traffic is plaintext, browser guests included** (it's your living room
  / car). This is a decision, not a gap waiting for TLS. Everything a
  listener needs works on a plain `http://` LAN origin — WebSocket, `fetch`,
  Web Audio, `performance.now()`; only service workers, PWA install and the
  wake lock require a secure context, and listening needs none of them. TLS
  would buy a LAN room little: a self-signed certificate on a LAN IP puts a
  full-page warning in front of every browser guest, a browser offers a page
  no way to pin a certificate it was handed in a QR code, and an `https` page
  could not open `ws://` or fetch `http://` from the host anyway (mixed
  content). What plaintext costs is that anyone on the same network segment
  can read the traffic, the token included — which, for a room that is
  already "everyone on this Wi-Fi" when discoverable, is the threat model of
  this whole section, not a new one. TLS with a self-signed certificate
  pinned via the `localjam://` QR remains possible later as a
  **hostile-network hardening option for native clients**; it is not a
  prerequisite for anything, the web guest included.
- The page routes (§1.1) are unauthenticated by design and reveal nothing
  about the room: the bundle is the same in every host, the token rides only
  the URL fragment, and a request for the page carries neither.
- Hosts serve the LAN only. A host MUST refuse off-LAN remotes on both
  planes — and on the page routes (§1.1) — before it processes anything they
  send (answering `403`), and that
  filter — not the bind address — is the rule: a host MAY bind the wildcard
  address when one port has to span several networks (a phone on Wi-Fi
  *and* its own hotspot) or a network whose interface does not exist yet
  (an iPhone's own hotspot interface can appear after the room opens).
  A host that can bind its LAN interfaces alone SHOULD. "On-LAN" is
  loopback, RFC1918 v4, v4 link-local, and their v6 equivalents (`::1`,
  `fe80::/10`, `fc00::/7`, v4-mapped). An IPv6 **global** unicast remote
  (`2000::/3`) counts as on-LAN only when it shares a /64 with one of the
  host's own interface addresses — native-v6 home networks give every device
  a global address, and the shared prefix is the closest an address alone
  gets to "same link". A remote address cannot tell a neighbour from a
  carrier's other customer, though (carrier networks use RFC1918 too), so a
  host bound to the wildcard SHOULD also refuse connections that arrive on
  its cellular and tunnel interfaces, by local address, before processing
  them (`403`). *Known gap in the reference host:* `dart:io` reports a
  wildcard listener's address (`0.0.0.0`) as every accepted socket's local
  address, so the reference host's local-address filter only takes effect
  when it is bound to a specific address. Closing this needs one listener
  per LAN interface (tracked as a follow-up); until then the token, the
  pre-auth limits of §9.1 and carriers' own client isolation are what stand
  between a carrier-network neighbour and the host.
- **Discovery is not a channel of trust.** mDNS records are unauthenticated:
  anyone on the segment can answer, including with an address that is not on
  it. A joiner MUST apply the same on-LAN rule to every `host` candidate it
  is about to dial, whatever door the join URI came in by — QR, pasted link,
  deep link, or a nearby-room row — and in whichever form (§1: for the http
  form, its own host when the fragment lists none, every listed one when it
  does), and SHOULD refuse candidates that are
  names rather than IP literals, since what a name resolves to is not
  knowable from the link. (`*.local` is the reasonable exception: multicast
  DNS answers only from the local link, and the resolved addresses can then
  be checked like any other.)
- **A host name off the network is a claim, not an identity.** `hname`
  (§1) is as unauthenticated as the rest of the record: any device can
  advertise a room under any name, including yours or a friend's. A joiner
  shows it as untrusted text, never uses it for trust, identity, permissions
  or deduplication (a room is its token), and never derives anything from it
  that would outlive the listing — inside the room, the host is whoever
  `welcome.host` says (§3.1).
- An mDNS responder SHOULD answer only queries that arrive from port 5353,
  rate-limit its responses to at most one per second (coalescing the rest),
  and cap a response's size — an unauthenticated packet that costs a few
  dozen bytes to send must not buy an unbounded multicast to the whole
  segment.

### 9.1 Host-side limits

§9 is an honest-guest model; "honest" is not the same as "unbounded". A host
SHOULD bound what one LAN neighbour can spend of its memory, sockets, disk
and queue, and the defaults below are what the reference host ships. All of
them are host policy — none is negotiated, and a guest observes them only as
a reject, a close, or a 4xx/5xx.

| Limit | Default | On breach |
|---|---|---|
| Open TCP connections, all kinds | 128 | `503`, closed before anything is parsed |
| Open TCP connections from one address | 32 | `503`, closed before anything is parsed |
| Time a connection the host has closed waits for the peer to close (counted throughout) | 2 s | destroyed |
| Request line + headers | 16 KB | connection destroyed mid-headers |
| Time to finish sending headers | 10 s | connection destroyed |
| Joined peers | 32 | `reject { full }`, socket closed |
| Half-open (pre-`hello`) sockets | 8 | `503` on the upgrade |
| Bytes a socket may send before its `hello` is accepted, counting any sent with the upgrade request | 16 KB (+1 KB framing) | close `1008` (not upgraded, if the upgrade's own read was over) |
| One control frame, before `hello` | 16 KB | close `1008` |
| One control frame, joined peer | 256 KB | close `1008` |
| Time to send a valid `hello` | 10 s | socket dropped |
| One upload | 512 MB | `413` |
| Uploads this session | 2 GB | `507` |
| Playlist items from guests | 500 | `507` |
| Uploads in flight, one peer | 2 | `429` |
| Upload body progress | ≥ 32 KB/s over every 30 s | `408`, upload abandoned |
| Time to send a page response (§1.1), which needs no token | the longer of 10 s and its size at 32 KB/s | connection destroyed |
| Body of a refused upload read (and dropped) before answering | 64 MB, within 10 s | answered and closed at once |
| Cover art in one upload | 8 MB | art dropped, track kept |
| Tag bytes read from one upload | ≈ 8 MB per read, ≈ 17 MB in all | art (or tags) skipped |

**What actually bounds memory.** Connections that have proved nothing are
the ones a host must bound in bytes, and the bound has to be on bytes as
they arrive: a typical HTTP stack (the reference host's included) buffers a
request's header block whole — `dart:io` at eight bytes of memory per byte,
up to 1 MiB per connection — and a WebSocket stack reassembles a whole
message, of any size, before anyone can look at it. So the reference host counts raw bytes per
connection in front of both: a header block past 16 KB, or a pre-`hello`
socket past its budget, is cut off while it is still arriving. Together
with the connection caps that puts a ceiling on unauthenticated memory —
128 connections × 16 KB of headers (× 8 in the parser) is 16 MB in the
worst case, where a hundred 1 MB headers measured ~900 MB of host memory
and eight pre-`hello` sockets streaming 100 MB frames ~540 MB (both now
stay at the idle ~20 MB) — and the header deadline frees the slots of
connections that dribble. For the
counting to hold, the host serves one request per connection
(`Connection: close`, §6.2): after the first request a connection's bytes
are a body or WebSocket frames, and a second header block would go
uncounted. For the same reason the pre-`hello` budget starts at the end of
the upgrade's header block, not at the upgrade: a client can send headers,
a megabyte of frames and a `hello` in one write, and whatever arrived in the
same read as the headers goes to the WebSocket as it is. When those bytes
alone are over budget the host does not upgrade at all.

**What bounds descriptors.** A connection counts against the caps until it
is actually gone — both directions closed, or destroyed — not from the
moment the host closes its own side. A WebSocket close handshake leaves the
connection half-open for as long as the peer takes to answer (`dart:io`
waits up to 5 s), and a host that stopped counting at its own close let a
neighbour cycling wrong-token joins hold ~14,000 descriptors while the cap
counted 13; under a 256-descriptor limit nobody else could join. The
reference host keeps the slot through the handshake and destroys the
connection 2 s after closing its side. The connection cap is in effect the
descriptor cap, too, which is why it is 128: Apple platforms start an app
at a soft limit of 256 descriptors, every connection is one, a transfer
holds a second (the file) while it runs, and the app needs its own. A
process out of descriptors cannot `accept` at all — nobody can join —
which is worse than the newest connections getting a `503`. An embedder
that raises its descriptor limit at launch (`setrlimit(RLIMIT_NOFILE)`)
can raise the cap with it.

The per-frame caps are a different kind of limit. They are counted in
**UTF-8 bytes**, not UTF-16 code units — a text frame of three-byte
characters is three times its `length` — but they are applied to whole,
reassembled messages, so what they bound is the cost of parsing and acting
on a frame, plus how many times a sender gets to impose it (once — the
socket goes with the frame). For a joined peer that is the only bound: it
holds the token, and within the room §9 trusts it not to stream a gigabyte
into one frame. The bounds that hold against anyone are the ones above.

Compression would undo all of it — with `permessage-deflate` a cap would be
measured after inflation, and a few hundred compressed bytes from a socket
that has proved nothing could inflate to megabytes before any cap looked at
them — which is why hosts MUST NOT negotiate it (§1). For the same reason a
rejected `hello` (`bad_token`, `full`, `version`, `kicked`) frees its
half-open slot immediately rather than when the close handshake completes.

Request bodies are not buffered: an upload is streamed to disk (§6.4), and
a body nobody reads is left unread — a host MUST NOT wait unboundedly for
the rest of a body it is refusing, or a request that declares a gigabyte and
sends nothing is never answered and holds its connection for good. The one
courtesy is bounded: a refused upload's body is read and dropped first when
it is small enough to arrive in time, so the client sees the status (§6.4)
— the reference host reads at most 64 MB of it, for no longer than a
connection that has proved nothing may live (10 s), and answers at once
otherwise. Uploads hold a share of the session budget only while they make
progress (§6.4); a window the host itself missed (a stall of its own) is not
held against the client.

---

## 10. Decided

- **Targets**: native mobile + desktop, hosts and guests. Browsers are guests
  only — never hosts — and load their player from the host itself (§1.1),
  so a room needs one installed app.
- **Transport security**: plaintext, browsers included (§9). TLS is a
  possible hardening option for hostile networks, not a prerequisite.
- **Media priority**: audio-first. Video ships later as "best effort ±100 ms"
  on the same anchor model; images are trivial (`state.mediaId` + display).
- **Session lifetime**: one host; host death ends the room. No migration.
  "Multiple admins" are co-hosts (§5.6) — still exactly one state writer.
  Ending the room is distinct from dying: a deliberate shutdown says so
  (§3.4 `session_ended`), a host about to be suspended says so (§3.5
  `host_status`), and only an unannounced death costs guests the short
  host-gone timeout.
- **Encoding**: JSON; binary (CBOR/MessagePack) negotiable later via
  `hello.encodings`. Not a performance requirement — control plane is low-rate.
- **Versioning**: one major version on the wire, tolerant decoding within it,
  a hard gate between majors (§2.1). There were no deployed clients before
  1.0, so 1.0 carries no compatibility shims for the drafts that preceded it.

## 11. Open questions

1. **Video sync quality bar** — same anchor model, but players
   (AVPlayer/ExoPlayer) have coarser scheduling than audio engines. Define the
   acceptable drift for "cherry on top" video when it lands.
2. **TLS as hardening** — decided against as a requirement (§9, §10):
   plaintext is the protocol for every client, the browser guest included,
   which needs no secure context to listen. What stays open is whether
   native clients get an opt-in hardening mode for hostile networks — a
   self-signed certificate pinned via the `localjam://` QR — and whether
   that is worth a second code path nobody on a home or car network needs.
