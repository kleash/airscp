import Foundation

/// SSH without macOS's ssh: a connection that a `Session` runs its scripts, commands and sftp batches over instead of a
/// master ssh. libssh2's (AirSCPSSH2) is the iPhone and iPad app's, and the tests check it does what ssh does.
/// Each call blocks only its caller; a `Session` makes them one at a time per lane (`Session.Slot`).
public protocol RemoteTransport: AnyObject {
    /// Connects and logs in. Questions go to `ask` in ssh's own words (`Askpass.classify` reads them: the host key, a
    /// password, a verification code); nil cancels. Throws what `ErrorMapping` makes of ssh's words for the failure.
    func open(ask: @escaping (String) async -> String?) async throws
    /// `command` on the server, as `ssh host command` runs it, with `input` on its standard input. Throws only when it
    /// couldn't run: `.disconnected` once the connection is gone, `.cancelled`.
    func exec(_ command: String, input: String?, cancellation: Cancellation, standardOutput: ((Data) -> Void)?,
              errorOutput: ((Data) -> Void)?) async throws -> CommandResult
    /// sftp batch lines, as `sftp -b -` runs them (`OpenSSH.sftpBatch`): each echoed after "sftp> ", output as sftp
    /// prints it, sftp's error lines; the first failing line ends the batch with exit status 1, unless it starts with "-".
    func sftp(_ lines: [String], cancellation: Cancellation) async throws -> CommandResult
    /// The transfer queue's copy (`TransferQueue`; iOS has no scp, sftp or tar to run): `local` to `remote` (`upload`) or
    /// back over SFTP, a folder with everything in it (symbolic links stay links), a step at a time so that other calls
    /// go on in between. `resume`: a single file continues its partial copy (the server's for an upload, the local one
    /// for a download) from that copy's size, as sftp's reput and reget do; else, or when there is none to continue, it
    /// starts afresh. `preserveTimes`: as sftp's -p. `limit`: bytes a second at most. `progress` gets the bytes copied so
    /// far, the file at it and the files done (a single file's size as `total`), on a background thread. Returns where
    /// a resumed copy continued from (0: afresh), and what a folder's copy left out (in sftp's words, a line each).
    /// Throws as `sftp` does (mapped), `.disconnected` once the connection is gone, `.cancelled`.
    func copy(upload: Bool, local: String, remote: String, resume: Bool, preserveTimes: Bool, limit: Int?,
              cancellation: Cancellation, progress: @escaping (TransferProgress) -> Void) async throws
        -> (resumedFrom: Int64, leftOut: [String])
    /// Ends the connection.
    func close()
}
