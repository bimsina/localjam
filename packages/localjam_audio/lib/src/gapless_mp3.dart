import 'dart:typed_data';

/// The LAME/Xing facts of an MP3 that decide where its media frame 0 is.
///
/// Media position P is the GAPLESS frame P on every platform (README "Media
/// position"): encoder delay and padding are not part of the timeline.
/// Browsers disagree on MP3: Chrome and Firefox decode with FFmpeg, which
/// applies a LAME tag exactly but, WITHOUT one, keeps the decoder's own
/// 529-frame delay at the start (measured: Chrome 157); WebKit decodes with
/// Core Audio, which drops the decoder delay but applies a LAME tag only for
/// some files (as on native Apple). Android and Apple drop the decoder delay
/// and apply the tag. [mediaWindow] maps any of those onto the shared
/// timeline.
class Mp3Info {
  const Mp3Info({
    required this.sampleRate,
    required this.samplesPerFrame,
    required this.frames,
    required this.delay,
    required this.padding,
    required this.hasLameTag,
  });

  /// Rate of the stream (the decoded buffer may be resampled).
  final int sampleRate;

  /// 1152 (MPEG-1) or 576 (MPEG-2/2.5).
  final int samplesPerFrame;

  /// The Xing/Info frame count (audio frames), when present.
  final int? frames;

  /// LAME encoder delay/padding (0 without a tag).
  final int delay;
  final int padding;

  /// Whether a LAME/Lavf/Lavc tag was found (FFmpeg's rule).
  final bool hasLameTag;

  /// The decoder delay FFmpeg keeps in a tagless MP3 and everyone else drops.
  static const int decoderDelay = 529;

  /// Parses [bytes] (a whole file) if they are an MPEG Layer III stream;
  /// null otherwise. Looks at the head only.
  static Mp3Info? parse(Uint8List bytes) {
    var p = 0;
    // ID3v2 tags (possibly several; cover art can make them large).
    for (var i = 0; i < 8; i++) {
      if (p + 10 > bytes.length) return null;
      if (bytes[p] != 0x49 || bytes[p + 1] != 0x44 || bytes[p + 2] != 0x33) {
        break;
      }
      final size =
          (bytes[p + 6] & 0x7F) << 21 |
          (bytes[p + 7] & 0x7F) << 14 |
          (bytes[p + 8] & 0x7F) << 7 |
          (bytes[p + 9] & 0x7F);
      p += 10 + size + ((bytes[p + 5] & 0x10) != 0 ? 10 : 0);
    }
    final limit = p + 64 * 1024 < bytes.length ? p + 64 * 1024 : bytes.length;
    for (; p + 4 <= limit; p++) {
      final h = _header(bytes, p);
      if (h == null) continue;
      final next = _header(bytes, p + h.size);
      if (next == null || next.fixed != h.fixed) continue;
      return _info(bytes, p, h);
    }
    return null;
  }

  static int _be32(Uint8List b, int o) =>
      b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

  static const _v1 = [
    0,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    160,
    192,
    224,
    256,
    320,
  ];
  static const _v2 = [
    0,
    8,
    16,
    24,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    144,
    160,
  ];

  static _Header? _header(Uint8List b, int p) {
    if (p + 4 > b.length) return null;
    final h = _be32(b, p);
    if ((h >> 21) & 0x7FF != 0x7FF) return null;
    final version = (h >> 19) & 3, layer = (h >> 17) & 3;
    final br = (h >> 12) & 0xF, sr = (h >> 10) & 3;
    if (version == 1 || layer != 1 || br == 0 || br == 15 || sr == 3) {
      return null;
    }
    final mpeg1 = version == 3;
    final rate =
        const [44100, 48000, 32000][sr] >> (mpeg1 ? 0 : (version == 2 ? 1 : 2));
    final kbps = (mpeg1 ? _v1 : _v2)[br];
    final size = (mpeg1 ? 144000 : 72000) * kbps ~/ rate + ((h >> 9) & 1);
    final mono = (h >> 6) & 3 == 3;
    return _Header(
      mpeg1,
      mono,
      rate,
      size,
      (h & 0xFFFE0C00) | (mono ? 0xC0 : 0),
    );
  }

  static Mp3Info _info(Uint8List b, int p, _Header h) {
    final spf = h.mpeg1 ? 1152 : 576;
    Mp3Info plain() => Mp3Info(
      sampleRate: h.rate,
      samplesPerFrame: spf,
      frames: null,
      delay: 0,
      padding: 0,
      hasLameTag: false,
    );
    final x = p + 4 + (h.mpeg1 ? (h.mono ? 17 : 32) : (h.mono ? 9 : 17));
    if (x + 8 > b.length) return plain();
    final tag = _be32(b, x);
    if (tag != 0x58696E67 && tag != 0x496E666F) return plain(); // Xing/Info
    final flags = _be32(b, x + 4);
    var o = x + 8;
    int? frames;
    if (flags & 1 != 0) {
      if (o + 4 > b.length) return plain();
      frames = _be32(b, o);
      o += 4;
    }
    if (flags & 2 != 0) o += 4;
    if (flags & 4 != 0) o += 100;
    if (flags & 8 != 0) o += 4;
    if (o + 24 > b.length) return plain();
    final enc = String.fromCharCodes(b.sublist(o, o + 4));
    final lame = enc == 'LAME' || enc == 'Lavf' || enc == 'Lavc';
    final v = b[o + 21] << 16 | b[o + 22] << 8 | b[o + 23];
    return Mp3Info(
      sampleRate: h.rate,
      samplesPerFrame: spf,
      frames: frames,
      delay: lame ? v >> 12 : 0,
      padding: lame ? v & 0xFFF : 0,
      hasLameTag: lame,
    );
  }

  /// Which decoded frames are media frames: `(offset, length)` in frames of
  /// a buffer of [decodedLength] frames at [decodedRate], or null for "the
  /// whole buffer". [decoderKeepsDelay]: the browser decodes with FFmpeg
  /// (Chrome, Firefox), which keeps the 529-frame decoder delay of a
  /// tagless file; false for WebKit (Core Audio).
  (int, int)? mediaWindow({
    required int decodedLength,
    required num decodedRate,
    required bool decoderKeepsDelay,
  }) {
    final ratio = decodedRate / sampleRate;
    int scaled(int frames) => (frames * ratio).round();
    // ±2 frames: decodeAudioData resamples to the context rate.
    bool near(int a, int b) => (a - b).abs() <= 2;
    if (hasLameTag && (delay > 0 || padding > 0)) {
      final f = frames;
      if (f == null) return null;
      final full = f * samplesPerFrame;
      final gapless = full - delay - padding;
      if (gapless <= 0) return null;
      if (near(decodedLength, scaled(gapless))) return null; // applied
      if (near(decodedLength, scaled(full))) {
        return (
          scaled(delay),
          scaled(gapless).clamp(0, decodedLength - scaled(delay)),
        );
      }
      return null; // unrecognized: leave the browser's timeline alone
    }
    if (!hasLameTag && decoderKeepsDelay) {
      final off = scaled(decoderDelay);
      if (decodedLength <= off) return null;
      return (off, decodedLength - off);
    }
    return null;
  }
}

class _Header {
  const _Header(this.mpeg1, this.mono, this.rate, this.size, this.fixed);
  final bool mpeg1;
  final bool mono;
  final int rate;
  final int size;
  final int fixed;
}
