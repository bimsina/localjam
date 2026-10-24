# Library catalog — design brief (2026-10-24)

The host's device music library, offered to the room as a browsable
**catalog**. Guests (and the host) browse and search it and add songs from it
to the queue; the queue stays short, the library stays on the host's phone.
Nothing is hashed, probed or copied until a song is actually added.

Android host only for now (the only platform with a library bridge,
`JamMediaLibrary` in `localjam_audio`). Guests on every platform may browse
and add; a client that does not know the feature ignores it (§2.1 tolerant
decoding). Browser guest: out of scope for this wave.

## Protocol 1.3 (additive; `v` stays 1)

### §6.6 Catalog

A host MAY offer a catalog: a list of songs it can add to the room on
request. A catalog entry is **not** a playlist item: it has no `mediaId`,
no `sha256`, and its bytes are not servable. It becomes a §6.1 item only when
someone adds it.

**Control plane**

```
H→*  catalog { rev, count }        // the catalog changed, or appeared/vanished
```

- `rev` increments on every change (contents, or on/off). `count: 0` means
  the host offers no catalog; guests drop whatever they cached.
- `welcome.catalog?: { rev, count }` carries the same for a joiner. Absent
  means none.
- Guests fetch the contents over the media plane (below) when `rev` changes;
  the broadcast is a notification, never the list itself.

```
G→H  request { action: "catalog_add", catalogIds: [ ... ] }
```

- Needs `add_tracks` (§5.6), like an upload. Refused: `error { code:
  "not_allowed", fatal: false }`, nothing added.
- `catalogIds` beyond the host's per-request cap (reference host: 50) are
  dropped; ids the host does not know, or that are no longer in the catalog,
  are skipped silently (the ordinary §6.1 `playlist` broadcast is the
  answer; a client compares). A request with no usable id changes nothing.
- The host adds each id in order, one at a time, in the background: resolve
  the file, probe, read tags (host-extracted, §6.1), sha256, append,
  broadcast `playlist`. One broadcast per landed item is fine (an item is
  playable the moment it is in). The item is credited `addedBy` =
  **the requesting peer** (it is their contribution to the queue, so their
  byline and their own-removal right, §5.6), even though the file is the
  host's.
- Idempotent like uploads: an id whose content is already in the playlist
  is a no-op; one whose content was removed goes back in, credited to the
  requester.
- Bounds (host policy, §9.1): catalog adds pending across all peers 64
  (beyond: `error { code: "busy", fatal: false }`, non-fatal, a 1.2 client
  reads it as a generic error); the §9.1 "playlist items from guests" cap
  counts these items (they are remote input), the upload byte budget does
  not (nothing is stored).

**Media plane**

```
GET /catalog                     Authorization: Bearer <sessionToken>
200 application/json
{ rev, items: [ { catalogId, title, artist?, album?, durationUs?,
                  sizeBytes?, hasArtwork? } ] }
```

- `catalogId`: opaque, host-local, stable for the session (reference host on
  Android: `c_<MediaStore id>`). Not content-derived. Never reused for a
  different song within a session.
- `404` when the host offers no catalog. `401` bad token. Full body, no
  `Range`. Guests bound the body like any media response (§6.2); the
  reference guest caps it at 16 MB.
- Guests cache the list by `rev` and re-fetch when a `catalog` broadcast
  announces a newer one. Search/filter is client-local.

```
GET /catalog/{catalogId}/artwork  Authorization: Bearer <sessionToken>
```

- The song's embedded cover, read from the file **on demand** (never at
  listing time; a 3,000-song catalog must cost the host nothing until
  someone scrolls). Full-body `200` with its `Content-Type`; `404` when the
  entry is unknown or has no cover (or `hasArtwork` was false). Same cap as
  §6.5 (8 MB). The host keeps a small bounded cache (reference: 64 covers).
  Guests hold few connections (§6.2) and SHOULD request covers for visible
  rows only.

**Privacy.** The catalog reveals the titles of a person's music to everyone
holding the room token — on a discoverable room, everyone on the Wi-Fi. So
it is **host opt-in per room**, default off, switchable live (a `catalog`
broadcast each way). Listing is not serving: bytes of a catalog entry are
fetchable only once it has been added as a playlist item (`/media/{mediaId}`),
so a guest cannot bulk-download a library by enumerating ids.

## Engine API

### localjam_core
- `CatalogMessage { rev, count }` (`wireType: 'catalog'`), decoded in the
  codec; `WelcomeMessage.catalog` optional `CatalogSummary?`.
- `RequestAction.catalogAdd('catalog_add')`; `RequestMessage.catalogIds`
  (`List<String>?`).
- `CatalogSummary { rev, count }`, `CatalogEntry { catalogId, title, artist,
  album, durationUs, sizeBytes, hasArtwork }` with tolerant `tryFromJson`.
- `ErrorCode.busy`.

### localjam_net
- `JamHostServer`: `setCatalog(JamCatalogProvider? provider)` — provider
  gives `List<CatalogEntry> entries` and `Future<File?> open(catalogId)`;
  the server owns rev/count, the `/catalog` and `/catalog/{id}/artwork`
  routes, lazy artwork extraction + bounded cache, `catalog_add` handling
  (permission, caps, sequential background ingestion through the same
  describe/probe/tag path uploads use, attribution to the requester), the
  pending-adds bound, and a `JamHostEvent` for a landed catalog add
  (peerId + mediaId, like the upload event).
- `JamGuestSession`: `catalog` (`CatalogSummary?`) + stream of changes;
  `Future<List<CatalogEntry>> fetchCatalog()` (cached by rev, bounded
  body); `requestCatalogAdd(List<String> ids)`;
  `Future<Uint8List?> fetchCatalogArtwork(String catalogId)`.

### localjam_client
- `abstract class JamCatalogSource { Future<List<CatalogEntry>> list();
  Future<File?> open(String catalogId); }` and
  `JamMediaLibraryCatalogSource` (Android: `JamMediaLibrary.queryAudio` →
  `c_<id>`, `resolve` on open; copies a scoped-storage fallback into the
  cache exactly as the picker does today).
- `JamHostEngine`: `Future<void> shareCatalog(JamCatalogSource? source)`
  (null = stop sharing), `ValueListenable<CatalogSummary?> catalog`,
  `List<CatalogEntry> get catalogEntries`,
  `Future<JamAddResult?> addFromCatalog(String catalogId)` for the host's
  own UI (credited `"host"`), and `catalogAdds` events for "X added Y from
  your library" notices.
- `JamGuestEngine`: `ValueListenable<CatalogSummary?> catalog`,
  `Future<List<CatalogEntry>> fetchCatalog()`,
  `Future<bool> requestCatalogAdd(List<String> ids)`,
  `Future<Uint8List?> catalogArtworkFor(CatalogEntry)` (bounded, memoised,
  through the same connection limiter as §6.5 covers).

## App (Android host; every guest)
- **Start a Jam**: a "Share my music library" row (switch) under the song
  list. On: permission → `JamMediaLibrary.queryAudio` → shared on start.
  Copy explains who sees it ("Everyone in the jam can browse and add from
  it"). Default off. Still possible to pick songs for the opening queue.
- **In room**: when the room has a catalog, Add Songs offers "Host's
  library" (named with the host's display name, §3.1) beside Files/Library.
  The browse sheet reuses the library picker chrome (search, rows with lazy
  covers, multi-select, **Add**): rows already in the queue show as such.
  Host's Settings sheet gets the share switch to turn it on/off mid-room.
- Guests with no `add_tracks` can browse but the Add is disabled, with the
  existing permission copy.

## Deviations

Where the protocol + network layer (2026-10-24) differs from, or settles
what is open in, the brief above. PROTOCOL.md §6.6 is written to match.

- **Provider hooks.** `JamCatalogProvider` has three optional members
  besides `entries` and `open`: `probeDurationUs(catalogId, file)` (default
  null), `mimeFor(catalogId, file)` (default: the app's extension mapping,
  as `jamAudioMimeForPath`) and `openForArtwork(catalogId)` (default:
  `open`). The server cannot probe (the probe is the native engine's,
  `LocaljamAudio.probeDurationUs`) or see the app's MIME table, and "the
  same path the host uses for its own files" needs both. The duration order
  is probe → the entry's library `durationUs` → the tag's. Cover reads call
  only `openForArtwork`, so a provider whose `open` copies a file (Android
  scoped storage) can answer a direct path or null there and a cover read
  never copies.
- **Untagged files.** When the file carries no title/artist/album tag, the
  added item falls back to the catalog entry's value, so the item reads as
  the row the guest picked (MediaStore titles a tagless file by its name).
- **Bounds answer what fit.** A `catalog_add` past the pending bound (128
  across the room, and 50 per requesting device — counted across its
  rejoins, and equal to the per-request id cap so one full selection fits
  whole; the brief's 64 across the room is raised to match) or the guest playlist cap (500) is not refused whole: the ids
  that fit are queued, the rest dropped, and the requester gets one
  `error { code: "busy" }`. The brief named no code for the playlist-cap
  case; it is `busy` too (an upload's `507` has no control-plane
  equivalent). An add that finds the queue full when it lands (the host's
  own additions are not held to the cap and may have filled it) is dropped
  with a `busy` too — one per request at most. Repeats within one request
  are skipped like unknown ids.
- **No repeated hashing.** An id already waiting to land (anyone's) is
  skipped, and the host remembers which mediaId each id hashed to under the
  current provider: an id whose content is in the queue is a no-op without
  opening or hashing the file again, and takes no pending slot.
- **Adds are judged again when they land**, like uploads (§6.4): only while
  the requester is still in the room (joined, in its grace window, or
  rejoined under a new peerId, credited there) and still holds
  `add_tracks`. A kicked device's queued adds never land. The test is
  repeated after every step of the add — the open, every chunk of the
  hash, the probe, the tag read, the cover write — so an add nobody wants
  any more stops where it is; its cover is written under a name of its own
  and registered (§6.5) only at the landing, and deleted otherwise.
- **`rev` moves only on a change.** `setCatalog` reads `entries` first (a
  provider that throws leaves the old catalog in place and the error is
  rethrown) and bumps `rev` and broadcasts only when the resulting listing
  differs from the current one — whether or not the provider is the same
  object. A different provider still drops the waiting adds and the cover
  cache, even with an equal listing (its ids are its own). A refresh by the
  same provider drops only the adds for ids it no longer offers.
- **Cover cache** is bounded by bytes as well as count: 64 covers and at
  most 32 MB (64 × the 8 MB cap would be 512 MB). A song without a cover is
  cached as "none". Cover reads use the upload tag budget (≈ 8 MB per read);
  the add path reads tags in full, as for the host's own files. At most 3
  covers are read at once and 16 more requests wait; past that the answer
  is `503` with `Retry-After: 1`, not cached (`JamGuestClient` surfaces it
  as a `JamHttpStatusException`, which a client must not memoise as "no
  cover"). A cover read across a provider swap is `404`.
- **Guest listing freshness.** `JamGuestSession.fetchCatalog` never returns
  a listing older than the `catalog` rev it knew when called: a fetch
  overtaken by a newer broadcast fetches again (up to 4 rounds), and a
  caller arriving while a fetch for an older rev is under way waits for it
  and asks again.
- **An empty provider** still counts as offered: `welcome.catalog` is
  `{rev, count: 0}` and `/catalog` answers `200` with no items; `count: 0`
  reads as "nothing to browse" either way, and `JamGuestSession.catalog` is
  null for it. `/catalog` is `404` only when `setCatalog(null)`.
- **Playlist items name their row.** A §6.1 item gains an optional
  `catalogId` (core `MediaItem.catalogId`; written only when set, and a
  value that is not a non-empty string reads as absent), set by the host
  when a catalog add lands — a guest's or `addFromCatalog` — so a client
  can mark the catalog row as queued without comparing content. Absent for
  uploads and the host's own files. Content already in the queue keeps
  whatever `catalogId` it has (a catalog add of an uploaded song's bytes is
  a no-op and does not set it); removed content put back by a catalog add
  carries the id, and put back by an upload carries none.
- **`hasArtwork` is tri-state** (`bool?`): `false` = no cover (never asked
  for), absent = unknown until asked.
- **Extra engine surface** the client layer can use: core `CatalogListing`
  (the `/catalog` body); `JamHostServer.catalog`, `catalogEntries`,
  `addFromCatalog(catalogId)` (the host's own add, credited `"host"`,
  through the same queue; no bounds), `mediaFile(mediaId)` (the file the
  host plays for a catalog-added item); `JamHostEvent.catalogId`;
  `JamGuestClient.fetchCatalogListing()`. `catalogAdded` events fire for
  the host's own adds too (`peerId: "host"`).
