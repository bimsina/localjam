# localjam_net

LocalJam's transport: the host's HTTP + WebSocket server (media, artwork, the browser player), the guest client, LAN discovery over mDNS, and media metadata reading. Pure Dart apart from the discovery plugin.

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
