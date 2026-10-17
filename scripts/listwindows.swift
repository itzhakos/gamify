import CoreGraphics
import Foundation
// Lists on-screen windows: id, owner, title, bounds
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in list {
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name = w[kCGWindowName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Int ?? 0, y = b["Y"] as? Int ?? 0, wd = b["Width"] as? Int ?? 0, ht = b["Height"] as? Int ?? 0
    if layer == 0 && wd > 50 && ht > 50 { print("\(id)\t\(owner)\t\(name)\t\(x),\(y) \(wd)x\(ht)") }
}
