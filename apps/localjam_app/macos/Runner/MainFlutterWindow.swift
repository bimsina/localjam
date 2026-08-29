import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // After super, or the storyboard's ~800pt frame wins — which lands in
    // the medium breakpoint and shows phone chrome on a desktop. Opening at
    // 1280 puts the app in its sidebar layout, matching the Linux runner.
    self.minSize = NSSize(width: 420, height: 560)

    // macOS restores a saved frame AFTER awakeFromNib, which pinned the
    // window to the storyboard's ~800pt forever after the first launch —
    // below the sidebar threshold, so a desktop app kept opening in phone
    // chrome. One window, one intended size.
    self.isRestorable = false
    let visible =
      (self.screen ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    self.setContentSize(
      NSSize(
        width: min(1280, visible.width),
        height: min(800, visible.height)
      )
    )
    self.center()
  }
}
