import AppKit

extension NSPasteboard.PasteboardType {
    /// Put on every pasteboard write MyHub makes itself, so the clipboard
    /// history does not record our own copies back (and a screenshot copied
    /// off the stash is not saved a second time).
    static let myHubOwnWrite = NSPasteboard.PasteboardType("com.orazz.myhub.own-write")
}
