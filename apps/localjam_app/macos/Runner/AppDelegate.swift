import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override init() {
    // Before MainMenu.xib's window starts the engine (and any socket).
    raiseOpenFileLimit()
    super.init()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Raises this process's open-file soft limit before Flutter (and any socket)
/// starts. Apple's default soft limit is 256 descriptors, which a host room
/// spends on guest connections, their uploads and the media it serves — the
/// engine's connection cap had to sit at 128 because of it. Soft = min(hard,
/// [wanted]); best-effort, never fatal: a refusal is logged and the app runs
/// on the default. The resulting limit is logged once at launch.
private func raiseOpenFileLimit(to wanted: rlim_t = 4096) {
  var limit = rlimit()
  guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
    NSLog("localjam: getrlimit(RLIMIT_NOFILE) failed (errno %d)", errno)
    return
  }
  let target = min(limit.rlim_max, wanted)
  if target > limit.rlim_cur {
    var raised = limit
    raised.rlim_cur = target
    if setrlimit(RLIMIT_NOFILE, &raised) != 0 {
      NSLog("localjam: setrlimit(RLIMIT_NOFILE, %llu) failed (errno %d)", target, errno)
    }
  }
  // One line per launch: what the room actually has to work with.
  var now = rlimit()
  if getrlimit(RLIMIT_NOFILE, &now) == 0 {
    NSLog("localjam: open-file limit %llu (was %llu, hard %llu)", now.rlim_cur, limit.rlim_cur, now.rlim_max)
  }
}
