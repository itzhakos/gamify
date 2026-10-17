import AppKit
import SwiftUI

/// Tails a job's log file (the child writes stdout+stderr to it) into a read-only
/// NSTextView. Polls every 0.5 s; follows the end unless the user scrolled up.
struct LogView: NSViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Tailer { Tailer() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.backgroundColor = .textBackgroundColor
        scroll.borderType = .bezelBorder
        context.coordinator.textView = text
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.follow(url)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Tailer) {
        coordinator.follow(nil)
    }

    @MainActor
    final class Tailer {
        weak var textView: NSTextView?
        private var url: URL?
        private var offset: UInt64 = 0
        private var timer: Timer?
        /// Only the tail is kept on screen; the full log stays in the file.
        private let maxCharacters = 400_000

        func follow(_ newURL: URL?) {
            guard newURL != url else { return }
            url = newURL
            offset = 0
            textView?.string = newURL == nil ? "" : ""
            timer?.invalidate()
            timer = nil
            guard newURL != nil else { return }
            poll()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }

        private func poll() {
            guard let url, let textView, let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)
            let chunk = String(decoding: data, as: UTF8.self)

            let scroll = textView.enclosingScrollView
            let atBottom: Bool = {
                guard let scroll else { return true }
                let visible = scroll.contentView.documentVisibleRect
                return visible.maxY >= textView.bounds.height - 20
            }()
            let storage = textView.textStorage!
            storage.append(NSAttributedString(string: chunk, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]))
            if storage.length > maxCharacters {
                storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxCharacters))
            }
            if atBottom { textView.scrollToEndOfDocument(nil) }
        }
    }
}
