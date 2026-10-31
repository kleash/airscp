import SwiftUI
import UIKit

/// The editor's text: a text view in a monospaced font without autocorrection or smart quotes, in syntax colours for
/// common file types (`Syntax`), that goes to a line when asked (`jump`).
struct CodeView: UIViewRepresentable {
    @Binding var text: String
    /// The file's name: its type's colours.
    let name: String
    /// A line to go to (from 1): selected and shown, then nil.
    @Binding var jump: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        view.keyboardDismissMode = .interactive
        view.text = text
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "editor.text"
        context.coordinator.syntax = Syntax(name: name, text: text)
        context.coordinator.color(view, now: true)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard let line = jump else { return }
        DispatchQueue.main.async {  // once the view has its size, and not while SwiftUI updates
            Self.go(to: line, in: view)
            jump = nil
        }
    }

    /// Line `number` (from 1; the last one past the end) selected, without its line end, and shown.
    static func go(to number: Int, in view: UITextView) {
        let text = view.text as NSString
        var start = 0, end = 0, contentsEnd = 0, line = 1
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: 0, length: 0))
        while line < number && end > contentsEnd {  // a line end: another line follows (empty at the end of the text)
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: end, length: 0))
            line += 1
        }
        let range = NSRange(location: start, length: contentsEnd - start)
        view.becomeFirstResponder()  // a selection shows only there
        view.selectedRange = range
        view.scrollRangeToVisible(range)
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeView
        var syntax: Syntax?
        private var coloring: Task<Void, Never>?

        init(_ parent: CodeView) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            color(view, now: false)
        }

        /// The syntax colours, found off the main thread (`now`: at once, else after a pause in typing); none for a file
        /// above 256 KB, where each pass would hold up typing.
        func color(_ view: UITextView, now: Bool) {
            coloring?.cancel()
            guard let syntax, view.textStorage.length <= 256 << 10 else { return }
            let text: String = view.text
            coloring = Task {
                if !now, (try? await Task.sleep(for: .milliseconds(250))) == nil { return }
                let runs = await Task.detached { syntax.runs(in: text) }.value
                // Not over text typed meanwhile, nor over letters being composed (marked text).
                guard !Task.isCancelled, view.markedTextRange == nil, view.text == text else { return }
                let storage = view.textStorage
                storage.beginEditing()
                storage.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: storage.length))
                for (range, kind) in runs { storage.addAttribute(.foregroundColor, value: Syntax.colors[kind], range: range) }
                storage.endEditing()
            }
        }
    }
}

/// Syntax colours for the editor: comments, strings, numbers and keywords of shell scripts, Python, JSON, YAML, Swift,
/// C-like languages and config files, by the file's name (or a script's #! line). One regular expression for each type,
/// read from left to right, so a "#" in a string isn't a comment and a quote in a comment isn't a string. (The Mac's
/// editor has no colours.)
struct Syntax {
    /// Comments, strings, numbers, keywords (and keys, in YAML and config files).
    static let colors: [UIColor] = [.secondaryLabel, .systemRed, .systemBlue, .systemPink]
    private let pattern: NSRegularExpression

    /// nil: a type without colours.
    init?(name: String, text: String) {
        let hash = #"(?<!\S)#.*"#, slashes = #"//.*|/\*[\s\S]*?\*/"#
        // ".bashrc" is a bashrc; a script without a type says it in its first line ("#!/bin/bash").
        var type = name.hasPrefix(".") && !name.dropFirst().contains(".") ? String(name.dropFirst()) : (name as NSString).pathExtension
        if type.isEmpty && text.hasPrefix("#!") {
            let first = text.prefix { $0 != "\n" }
            type = first.contains("python") ? "py" : first.contains("sh") ? "sh" : ""
        }
        let comment: String, words: String
        switch type.lowercased() {
        case "sh", "bash", "zsh", "ksh", "bashrc", "zshrc", "profile", "bash_profile", "bash_aliases", "zprofile", "zshenv":
            comment = hash
            words = Self.words("if then else elif fi for while until do done case esac in function return local export readonly "
                               + "declare unset shift break continue exit source alias set trap eval exec")
        case "py":
            comment = hash
            words = Self.words("False None True and as assert async await break class continue def del elif else except finally "
                               + "for from global if import in is lambda nonlocal not or pass raise return try while with yield self")
        case "json":
            comment = "(?!)"
            words = Self.words("true false null")
        case "yml", "yaml":
            comment = hash
            words = #"^[ \t-]*[\w./-]+(?=:(?:\s|$))|"# + Self.words("true false null yes no")
        case "swift":
            comment = slashes
            words = Self.words("actor any as async await break case catch class continue default defer deinit do else enum "
                               + "extension false fileprivate for func guard if import in init inout internal is let nil open "
                               + "private protocol public repeat rethrows return self Self some static struct super switch throw "
                               + "throws true try typealias var weak where while")
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "java", "js", "mjs", "ts", "jsx", "tsx", "go", "rs", "kt", "cs", "php":
            comment = slashes
            words = Self.words("auto break case catch char class const continue default delete do double else enum export "
                               + "extends extern false final finally float fn for func function goto if impl implements import "
                               + "include define int interface let long match mod mut new nil null package private protected pub "
                               + "public return short signed sizeof static struct super switch this throw throws trait true try "
                               + "typedef typeof union unsigned use var void volatile while yield")
        case let type where ["conf", "cfg", "ini", "toml", "env", "properties", "service", "cnf"].contains(type)
            || name.hasSuffix("config") || name.hasSuffix("rc"):  // also sshd_config, .gitconfig, .npmrc
            // A setting (or a [section]) at the start of each line.
            (comment, words) = (#"^[ \t]*;.*|"# + hash, #"^[ \t]*(?:\[[^\]\n]*\]|[A-Za-z_][\w.-]*)"#)
        default:
            return nil
        }
        let strings = #""{3}[\s\S]*?"{3}|'{3}[\s\S]*?'{3}|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#
        let numbers = #"\b(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?)\b"#
        pattern = try! NSRegularExpression(pattern: "(\(comment))|(\(strings))|(\(numbers))|(\(words))", options: .anchorsMatchLines)
    }

    private static func words(_ list: String) -> String {
        #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    /// Each match in `text` (UTF-16 ranges, as a text view counts) with its kind: an index into `colors`.
    func runs(in text: String) -> [(NSRange, Int)] {
        pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).compactMap { match in
            (1...4).first { match.range(at: $0).location != NSNotFound }.map { (match.range, $0 - 1) }
        }
    }
}
