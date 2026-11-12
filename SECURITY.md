# Security policy

## Supported versions

Only the latest release on Google Play (and the `main` branch) gets security
fixes.

## What counts as a vulnerability

LocalJam's threat model is written down in [`PROTOCOL.md` §9](PROTOCOL.md):
an honest-guest, trusted-local-network design. Traffic on the LAN is plain
HTTP/WebSocket **by decision**, so "someone on the same network can read the
audio stream" is a known property, not a report.

The session token is the only key to a room, and it is not a secret from the
network the room is on. A **discoverable** room advertises its token in its
mDNS record, so anyone on the same network can join it; that is the feature,
not a leak. With discovery off, the QR code or join link is the only way in
that LocalJam offers, though someone who can watch the plaintext traffic on
that network can still read the token from it. Neither of those is a report.

These are in scope, and we want to hear about them:

- Getting into a room without its session token, or guessing it.
- The token reaching anyone through a channel the design above does not
  explain: a non-discoverable room's token in an mDNS record, a log, a web
  request, or anywhere off the local network.
- A host accepting control or media requests from a non-LAN address.
- A guest doing something its room permissions forbid (adding, controlling,
  editing the queue, promoting itself, kicking others).
- Reading or writing files on the host or a guest outside what the protocol
  serves (path traversal, the media and catalog endpoints, the web page the
  host serves).
- Crashing or hanging a host or guest remotely, or exhausting its memory or
  storage past the documented caps.
- Anything that sends data off the device or off the local network.
- Issues in the Android/iOS packaging: exported components, backup, signing.

## Reporting

Please **do not open a public issue** for a vulnerability.

- Use GitHub's private vulnerability reporting:
  **Security → Report a vulnerability** on
  <https://github.com/bimsina/localjam>.

Include the version (Settings → Version), the devices involved, and steps or a
proof of concept. You should get an acknowledgement within a week. Once a fix
ships, you are credited in `CHANGELOG.md` unless you would rather not be.
