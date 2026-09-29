import AppKit
import SwiftUI

enum IntentAppIcon {
  static var image: NSImage? {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
      return nil
    }
    return NSImage(contentsOf: url)
  }
}

final class IntentAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Refresh the running Dock icon as well as supplying Finder's bundle icon.
    if let image = IntentAppIcon.image {
      NSApplication.shared.applicationIconImage = image
    }
  }
}

struct IntentBrandIcon: View {
  var body: some View {
    if let image = IntentAppIcon.image {
      Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
    } else {
      Image(systemName: "calendar.badge.checkmark").foregroundStyle(.teal)
        .accessibilityHidden(true)
    }
  }
}
