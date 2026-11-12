# localjam_core

The pure-Dart heart of LocalJam: the wire protocol (messages, codec, versioning), clock synchronisation, the shared playback timeline and the queue/permission logic. No I/O, no Flutter — everything here runs and is tested on the Dart VM.

Part of [LocalJam](../../README.md). The package is not published to pub.dev;
depend on it by path from this repository.

- Wire format and behaviour: [PROTOCOL.md](../../PROTOCOL.md)
- How the packages fit together and how to contribute:
  [README.md](../../README.md), [CONTRIBUTING.md](../../CONTRIBUTING.md)

```sh
dart pub get
dart test
```

MIT — see [LICENSE](LICENSE).
