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
    /// Ends the connection.
    func close()
}
