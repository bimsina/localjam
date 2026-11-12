# localjam_client

The embeddable LocalJam engine: `JamHostEngine` and `JamGuestEngine` wrap `localjam_net` transport and `localjam_audio` scheduled playback behind one API. An app builds its player UI on these two classes.

Part of [LocalJam](../../README.md). The package is not published to pub.dev;
depend on it by path from this repository.

- Wire format and behaviour: [PROTOCOL.md](../../PROTOCOL.md)
- How the packages fit together and how to contribute:
  [README.md](../../README.md), [CONTRIBUTING.md](../../CONTRIBUTING.md)

```sh
flutter pub get
flutter test
```

MIT — see [LICENSE](LICENSE).
