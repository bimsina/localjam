import AVFoundation
import Foundation

/// The frames of an AVAudioFile that are media frames 0..<length: media frame
/// P is file frame `offset + P`. Shared verbatim between iOS and macOS.
struct GaplessWindow: Equatable {
  let offset: AVAudioFramePosition
  let length: AVAudioFramePosition

  static func whole(_ length: AVAudioFramePosition) -> GaplessWindow {
    GaplessWindow(offset: 0, length: length)
  }
}

/// Media position P is the GAPLESS frame P on every platform: encoder delay
/// and padding are not part of the timeline (Android and the browser do the
/// same; README "Media position"). AVAudioFile already does this for AAC (its
/// packet table comes from the `elst` or iTunSMPB), but for MP3 Core Audio
/// honors the LAME tag only some of the time — measured on macOS 26: MPEG-1
/// stereo files yes, mono and every MPEG-2/2.5 file no (frame 0 is then the
/// first frame after the decoder's own delay, i.e. LAME's encoder delay plays
/// as frames 0..<delay). A fixed rule would break when Apple fixes that, so
/// the window is chosen by comparing AVAudioFile's length with the tag:
/// `frames × samplesPerFrame` → not honored, shift by the delay;
/// `… − delay − padding` → already gapless.
enum GaplessMp3 {
  struct LameInfo: Equatable {
    let samplesPerFrame: Int64
    /// The Xing/Info frame count (audio frames), when present.
    let frames: Int64?
    let delay: Int64
    let padding: Int64
  }

  /// The media window of `file`: MP3 with a LAME tag that Core Audio did
  /// not apply → shifted; anything else → the whole file.
  static func window(for file: AVAudioFile, path: String) -> GaplessWindow {
    let length = file.length
    guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3,
          let info = lameInfo(path: path)
    else { return .whole(length) }
    return window(fileLength: length, info: info)
  }

  static func window(fileLength length: AVAudioFramePosition, info: LameInfo) -> GaplessWindow {
    let trim = info.delay + info.padding
    guard info.delay > 0 || info.padding > 0 else { return .whole(length) }
    if let frames = info.frames {
      let full = frames * info.samplesPerFrame
      if length == full - trim { return .whole(length) } // Core Audio applied it
      if length == full, full > trim { return GaplessWindow(offset: info.delay, length: full - trim) }
      return .whole(length) // unrecognized: leave Core Audio's timeline alone
    }
    if length % info.samplesPerFrame == 0, length > trim {
      return GaplessWindow(offset: info.delay, length: length - trim)
    }
    return .whole(length)
  }

  /// LAME gapless info of the MP3 at `path` (nil without a LAME/Lavf/Lavc
  /// tag — FFmpeg's rule, hence Chrome's and Android's).
  static func lameInfo(path: String) -> LameInfo? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    var pos: UInt64 = 0
    // Skip ID3v2 tags (cover art can make them megabytes).
    for _ in 0..<8 {
      fh.seek(toFileOffset: pos)
      let h = [UInt8](fh.readData(ofLength: 10))
      guard h.count == 10 else { return nil }
      guard h[0] == 0x49, h[1] == 0x44, h[2] == 0x33 else { break }
      let size = (UInt64(h[6] & 0x7F) << 21) | (UInt64(h[7] & 0x7F) << 14)
        | (UInt64(h[8] & 0x7F) << 7) | UInt64(h[9] & 0x7F)
      pos += 10 + size + ((h[5] & 0x10) != 0 ? 10 : 0)
    }
    fh.seek(toFileOffset: pos)
    return lameInfo([UInt8](fh.readData(ofLength: 64 * 1024)))
  }

  /// Parses the first Layer III frame in `bytes` (which start after any ID3v2
  /// tag) for a Xing/Info header and its LAME tag.
  static func lameInfo(_ b: [UInt8]) -> LameInfo? {
    var p = 0
    while p + 4 <= b.count {
      if let hdr = header(b, p) {
        let next = p + hdr.size
        if next + 4 <= b.count, let h2 = header(b, next), h2.fixed == hdr.fixed {
          return infoTag(b, p, hdr)
        }
      }
      p += 1
    }
    return nil
  }

  private struct Header {
    let mpeg1: Bool
    let mono: Bool
    let size: Int
    let fixed: UInt32
  }

  private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
    (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
  }

  private static func header(_ b: [UInt8], _ p: Int) -> Header? {
    guard p + 4 <= b.count else { return nil }
    let h = be32(b, p)
    guard (h >> 21) & 0x7FF == 0x7FF else { return nil }
    let version = (h >> 19) & 3, layer = (h >> 17) & 3
    let br = Int((h >> 12) & 0xF), sr = Int((h >> 10) & 3)
    guard version != 1, layer == 1, br != 0, br != 15, sr != 3 else { return nil }
    let mpeg1 = version == 3
    let v1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    let v2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    let rate = [44100, 48000, 32000][sr] >> (mpeg1 ? 0 : (version == 2 ? 1 : 2))
    let kbps = (mpeg1 ? v1 : v2)[br]
    let size = (mpeg1 ? 144_000 : 72_000) * kbps / rate + Int((h >> 9) & 1)
    let mono = (h >> 6) & 3 == 3
    return Header(mpeg1: mpeg1, mono: mono, size: size, fixed: (h & 0xFFFE_0C00) | (mono ? 0xC0 : 0))
  }

  private static func infoTag(_ b: [UInt8], _ p: Int, _ hdr: Header) -> LameInfo? {
    let side = hdr.mpeg1 ? (hdr.mono ? 17 : 32) : (hdr.mono ? 9 : 17)
    let x = p + 4 + side
    guard x + 8 <= b.count else { return nil }
    let tag = be32(b, x)
    guard tag == 0x5869_6E67 || tag == 0x496E_666F else { return nil } // "Xing" / "Info"
    let flags = be32(b, x + 4)
    var o = x + 8
    var frames: Int64?
    if flags & 1 != 0 {
      guard o + 4 <= b.count else { return nil }
      frames = Int64(be32(b, o))
      o += 4
    }
    if flags & 2 != 0 { o += 4 }
    if flags & 4 != 0 { o += 100 }
    if flags & 8 != 0 { o += 4 }
    guard o + 24 <= b.count else { return nil }
    let enc = String(bytes: b[o..<(o + 4)], encoding: .isoLatin1)
    guard enc == "LAME" || enc == "Lavf" || enc == "Lavc" else { return nil }
    let v = (Int64(b[o + 21]) << 16) | (Int64(b[o + 22]) << 8) | Int64(b[o + 23])
    return LameInfo(
      samplesPerFrame: hdr.mpeg1 ? 1152 : 576, frames: frames, delay: v >> 12, padding: v & 0xFFF)
  }
}
