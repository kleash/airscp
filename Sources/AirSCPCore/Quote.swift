import Foundation

/// Quoting for the three places a path or command ends up.
public enum Quote {
    /// A POSIX shell word: 'text', with ' written as '\''. For remote commands and the Terminal script.
    public static func shell(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A shell word that is left bare when it can't be misread (for showing commands to people).
    public static func shellWord(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return shell(text)
    }

    /// The last word of a command line being typed, as a POSIX shell reads it (quotes and backslashes taken away, a quote
    /// left open running to the end), and how many characters (Unicode scalars, as line editors erase them) it takes in
    /// the line. Words end at blanks and at ; | & < > ( ) and = (as bash's completion has it: --file=/var/log).
    public static func lastWord(in line: String) -> (word: String, typed: Int) {
        var word = String.UnicodeScalarView(), typed = 0, quote: Unicode.Scalar?, escaped = false
        for scalar in line.unicodeScalars {
            typed += 1
            if escaped {
                // In double quotes a backslash escapes only $ ` " and \ (and stays before anything else).
                if quote == "\"" && !"$`\"\\".unicodeScalars.contains(scalar) { word.append("\\") }
                word.append(scalar)
                escaped = false
            } else if let open = quote {
                if scalar == open { quote = nil } else if scalar == "\\" && open == "\"" { escaped = true } else { word.append(scalar) }
            } else if " \t\n;|&<>()=".unicodeScalars.contains(scalar) {
                word = String.UnicodeScalarView()
                typed = 0
            } else if scalar == "'" || scalar == "\"" {
                quote = scalar
            } else if scalar == "\\" {
                escaped = true
            } else {
                word.append(scalar)
            }
        }
        return (String(word), typed)
    }

    /// An argument in an sftp batch line: "text", with \ and " backslash-escaped. Inside quotes sftp treats
    /// * ? [ ] literally by itself, so they are left alone. A line break can't be written in a batch line: it would end
    /// the line, and sftp would read what follows as a command of its own. It is written as ?, which matches no name.
    public static func sftp(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + String(String.UnicodeScalarView(escaped.unicodeScalars.map { $0 == "\n" ? "?" : $0 })) + "\""
    }

    /// The remote path of an scp download (scp in SFTP mode globs it; no shell is involved): \ * ? [ ] escaped
    /// with a backslash. Upload destinations are taken literally by scp and must not be escaped.
    public static func scpSource(_ path: String) -> String {
        var result = ""
        for character in path {
            if "\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A value in an ssh -o Key=Value option: bare when it has no spaces, quotes, backslashes or '#', else
    /// "double-quoted" (ssh splits option values like config-file lines).
    public static func configValue(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || "\"'\\#".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
