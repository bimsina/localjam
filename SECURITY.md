# Security policy

## Supported versions

Only the latest release on Google Play (and the `main` branch) gets security
fixes.

## What counts as a vulnerability

LocalJam's threat model is written down in [`PROTOCOL.md` §9](PROTOCOL.md):
an honest-guest, trusted-local-network design. Traffic on the LAN is plain
HTTP/WebSocket **by decision**, so "someone on the same network can read the
audio stream" is a known property, not a report.

These are in scope, and we want to hear about them:

- Getting into a room without its session token, or guessing or leaking the
  token through a side channel.
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
- Or email **[SECURITY CONTACT EMAIL]**.

Include the version (Settings → Version), the devices involved, and steps or a
proof of concept. You should get an acknowledgement within a week. Once a fix
ships, you are credited in `CHANGELOG.md` unless you would rather not be.
