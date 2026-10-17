# Contributing to LocalJam

Thanks for looking. Bug reports, device-test results and patches are all
welcome — especially test results from real hardware, and from Windows and
Linux machines, which nobody has verified at runtime yet.

## Repo layout

```
PROTOCOL.md            the wire protocol — read this before touching the engine
packages/
  localjam_core        pure Dart, no I/O: messages, codec, clock, anchors
  localjam_net         transport: host server, guest client, reconnect
  localjam_audio       Flutter plugin: native scheduled playback + media session
  localjam_client      the engine UI apps depend on (host + guest)
  third_party/         vendored forks, each with its own LICENSE and PATCHES.md
apps/
  localjam_cli         headless demo client
  localjam_app         the Flutter app
```

Dependencies point one way: `core → net → client`, with `audio` beside them and
`localjam_app` depending on `localjam_client` only. If the app needs to reach
past `localjam_client` to do something, that is a sign the engine is missing an
API.

## Running the tests

```sh
cd packages/localjam_core   && dart test
cd packages/localjam_net    && dart test
cd packages/localjam_client && flutter test
cd packages/localjam_audio  && flutter test
cd apps/localjam_cli        && dart test
cd apps/localjam_app        && flutter test
```

All of it runs offline and in seconds. Flutter 3.47.5 / Dart 3.13.4 is what CI
pins; anything newer on the same major should be fine.

Things simulators cannot prove live in [`DEVICE_TESTING.md`](DEVICE_TESTING.md).
If you run any of that checklist, a PR adding your results (device, OS version,
numbers) is a genuinely useful contribution.

## Code style

- `dart format .` before you commit. CI checks it.
- The analyzer must be clean: `dart analyze` in the pure-Dart packages,
  `flutter analyze` in the Flutter ones. No new ignores without a comment
  saying why.
- Engine changes need tests. Anything touching sync, transport, permissions or
  lifecycle should come with a test that fails without the change — the suite
  is the reason it is safe to refactor this thing at all.
- Comments explain *why*, not *what*. The existing code is written that way;
  match it.
- Vendored third-party code stays byte-for-byte upstream except for what is
  documented in its `PATCHES.md`.

## Protocol changes

`PROTOCOL.md` is the contract, not a description of the code. So:

1. **Additive only.** New optional fields and new message types. Unknown fields
   and unknown message types are ignored (§2), which is what lets an older
   client keep working — do not repurpose or remove anything.
2. **Spec first.** Update `PROTOCOL.md` in the same PR, with the section number
   the change belongs to, and note the compatibility story at the top of the
   file the way v0.2 does.
3. **Both sides.** Host and guest, plus a test in `localjam_core` for the wire
   shape and one in `localjam_net` for the behaviour.
4. Anything that cannot be additive is a version bump and a conversation —
   open an issue first.

## Pull requests

- One topic per PR. A formatting sweep and a bug fix in the same diff is two
  PRs.
- Say what changed and why, and how you verified it. "Ran the suite" is fine
  for pure logic; for anything with a UI or a device in the loop, say which
  device and what you saw.
- Green analyzer, green tests, formatted.
- New behaviour that a user would notice gets a line in `CHANGELOG.md` under
  `## Unreleased`.
- Keep the docs honest. If a platform is build-verified rather than
  run-verified, `README.md` and `DEVICE_TESTING.md` should say so.

## License

By contributing you agree your work ships under the [MIT license](LICENSE).
