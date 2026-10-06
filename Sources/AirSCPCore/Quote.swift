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

    /// An argument in an sftp batch line: "text", with \ and " backslash-escaped. Inside quotes sftp treats
    /// * ? [ ] literally by itself, so they are left alone.
    public static func sftp(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
