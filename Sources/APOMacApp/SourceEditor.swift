import AppKit
import SwiftUI

/// Plain-text editor for Equalizer APO configuration files.
struct SourceEditor: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    /// 1-based line numbers to tint as errors.
    var errorLines: Set<Int> = []
    var warningLines: Set<Int> = []
    /// Set to a 1-based line to select and reveal it.
    @Binding var revealLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Coordinator.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.highlight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            // Replaced from outside (visual edit, profile switch): the text
            // view's undo history no longer matches its contents.
            let selection = textView.selectedRanges
            textView.string = text
            context.coordinator.undo.removeAllActions()
            let length = (text as NSString).length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
        }
        context.coordinator.highlight(textView)
        if let line = revealLine {
            context.coordinator.reveal(line: line, in: textView)
            DispatchQueue.main.async { revealLine = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        private static let commandPattern = try! NSRegularExpression(pattern: "^[ \\t]*([A-Za-z][A-Za-z0-9 ]*?)[ \\t]*:", options: [.anchorsMatchLines])
        private static let commentPattern = try! NSRegularExpression(pattern: "(^[ \\t]*//.*$)|(#.*$)", options: [.anchorsMatchLines])
        private static let numberPattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])[-+]?[0-9]+(?:[.,][0-9]+)?", options: [])

        var parent: SourceEditor
        let undo = UndoManager()
        private var highlightedText = ""
        private var highlightedErrors: Set<Int> = []
        private var highlightedWarnings: Set<Int> = []

        init(_ parent: SourceEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            highlight(textView)
            parent.onChange(textView.string)
        }

        func highlight(_ textView: NSTextView) {
            let text = textView.string
            guard text != highlightedText || parent.errorLines != highlightedErrors || parent.warningLines != highlightedWarnings,
                  let storage = textView.textStorage else { return }
            highlightedText = text
            highlightedErrors = parent.errorLines
            highlightedWarnings = parent.warningLines

            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.textColor], range: full)
            Self.numberPattern.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let range = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
            }
            Self.commandPattern.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let range = match?.range(at: 1) else { return }
                storage.addAttributes([
                    .foregroundColor: NSColor.systemPurple,
                    .font: NSFont.monospacedSystemFont(ofSize: Self.font.pointSize, weight: .semibold)
                ], range: range)
            }
            Self.commentPattern.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let range = match?.range else { return }
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: Self.font], range: range)
            }
            let nsText = text as NSString
            var lineNumber = 1
            nsText.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, _, enclosingRange, _ in
                if self.highlightedErrors.contains(lineNumber) {
                    storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.15), range: enclosingRange)
                } else if self.highlightedWarnings.contains(lineNumber) {
                    storage.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.12), range: enclosingRange)
                }
                lineNumber += 1
            }
            storage.endEditing()
            textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.textColor]
        }

        func reveal(line: Int, in textView: NSTextView) {
            let nsText = textView.string as NSString
            var current = 1
            var target: NSRange?
            nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: [.byLines, .substringNotRequired]) { _, range, _, stop in
                if current == line {
                    target = range
                    stop.pointee = true
                }
                current += 1
            }
            guard let target else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(target)
            textView.scrollRangeToVisible(target)
            textView.showFindIndicator(for: target)
        }
    }
}
