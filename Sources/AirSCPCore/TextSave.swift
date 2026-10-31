import Foundation

/// What an editor's Save did (`Session.saveText`).
public enum TextSave: Equatable {
    case saved
    /// Nothing was written: the file changed on the server since the editor read or wrote it. Its text now, when the
    /// editor can show it (nil: no longer UTF-8 text, or too large).
    case changed(String?)
}

extension Session {
    /// The editors' Save (the Mac's and the iPhone's): `text` over the file (`writeText`), unless the server's file is no
    /// longer `known`, the text the editor last read or wrote there (or showed since): then nothing is written, so that
    /// the editor asks before overwriting someone else's change. nil `known` overwrites without checking. The whole file
    /// is compared, byte for byte: its size and a time to the minute (all sftp tells) would miss a quick change of a few
    /// characters. A file that is gone hasn't changed: saving makes it again.
    public func saveText(_ text: String, to path: String, isLink: Bool = false, ifUnchangedFrom known: String?) async throws
        -> TextSave {
        if let known {
            // The editor's limits for opening a file, widened to what `known` needs: what fails them isn't that text.
            let mine = known.utf8
            let longest = mine.split(separator: 0x0A, omittingEmptySubsequences: false).lazy.map(\.count).max() ?? 0
            do {
                let theirs = try await readText(path, limit: max(4 << 20, mine.count), lineLimit: max(256 << 10, longest))
                if !theirs.utf8.elementsEqual(mine) { return .changed(theirs) }
            } catch let error as AirSCPError where error.kind == .noSuchFile {
                // Gone: saving makes it again.
            } catch let error as AirSCPError where error.kind == .notText {
                return .changed(nil)  // not UTF-8 text now, or too large to show
            }
        }
        try await writeText(text, to: path, isLink: isLink)
        return .saved
    }
}
