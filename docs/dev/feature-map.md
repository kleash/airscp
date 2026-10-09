# Feature map: where each feature lives and what tests it

Files are under `Sources/` (`Core/` = `AirSCPCore`, `App/` = `AirSCP`); tests under `Tests/AirSCPTests/`.
"lab" = needs `AIRSCP_DOCKER=1`, "VM" = needs `AIRSCP_WINDOWS=1`. The plan section is in brackets (PLAN.md).

| Feature | Code | Tests |
|---|---|---|
| One window, sidebar, Connected section, ⌘1…⌘9, workspaces kept while connected [A, Q] | App/MainWindow, HostsSidebar, HostWorkspace, AppDelegate, AppModel | ShellTests (connected order, workspaces, menu shortcuts once, a connected workspace fills the window) |
| Window sizes: own size centred, saved frames only when they fit, nothing saved by throwaway instances | App/MainWindow (`NSWindow.open`, `WindowFrame`, `layoutName`), AppDelegate (Settings) | ShellTests `savedFramesAreUsedOnlyWhenTheyFitTheScreen`, `aWindowOpensAtItsSavedFrameOnlyWhenItFits`; lab `AgentLabTests.windowsOpenAtTheirOwnSizes` |
| Hosts, groups, editor, duplicate/delete, import ~/.ssh/config, export/import hosts [1] | App/HostEditor, Import, AppModel; Core/Models, SSHConfig | AppTests (editor checks, imports, `ssh -G`); UnitTests `storeRoundTripAndTolerance`, `filesFromTheFirstVersionLoadWithTheNewDefaults` |
| Key menu, missing key warning [K] | App/HostEditor; Core/Keys | ShellTests `keyMenuListsTheKeysAndMarksAMissingOne`; KeysTests |
| Connecting: askpass prompts, saved password + Remember, host key trust/changed, plain errors [2] | Core/Session, Askpass, ErrorMapping, Commands; App/HostConnection, Prompts | SessionTests; AppTests (prompt sheets, changed host key); UnitTests `errorMapping`, `promptClassification`; lab PAM/password tests |
| Two-factor (verification codes) [S.2] | Core/Askpass; App/Prompts | lab `aVerificationCodeIsAskedAndAWrongOneAgain`, S2AppTests `aVerificationCodeIsAskedInTheWindow` |
| Jump host (one hop) and HTTP proxies, chains [F] | Core/Commands, ProxyConnect, Askpass; App/Proxies | SessionTests `jumpHostConnection`; ProxyTests (in-process proxy); lab `proxyThenBastionThenTarget`; `AgentLabTests.anAgentDrivesTheLabChain` |
| Route in the sidebar [U.1] | App/HostsSidebar | HelpTests `theSidebarShowsEachHostsRoute` |
| Server key / certificate trust modes, orange shield [U.4] | Core/Models (`HostKeyCheck`, `CertificateCheck`), Commands, RDP; App/Trust, HostEditor, RDPEditor, SettingsWindow | TrustTests (incl. lab `acceptNewAgainstTheLab`; VM changed certificate) |
| Other ssh options with examples, `ssh -G` validation [U.3] | App/HostEditor | HelpTests `otherSSHOptionsAreCheckedAsTyped` |
| Automatic reconnect, keep-alive, wake and network triggers [L, R, S.2] | Core/Session; App/HostWorkspace (banner) | ReconnectTests (9); StreamTransferTests `jobsLostWithTheConnectionAreRetriedAfterReconnecting` |
| Terminal hand-off, Run Command, snippets, command log [3, 6] | App/Terminal, RunCommand, CommandLog | AppTests; ShellTests `terminalScriptsExportTheAskpassEnvironment`; S2Tests `theCommandLogLeavesOutRunCommandsMarker` |
| Tunnels: the editor as a sentence, routes in the list [6] | App/Tunnels; Core/Session | SessionTests `tunnelsForwardCancelAndBusyPort`; AppTests `tunnelTitlesAndChecks`; AgentTests `agentTestsAConnectionAndSwitchesATunnel`; lab `localAndRemoteTunnelsCarryTraffic` |
| Keys window, New Key Pair (all types/formats) [7, K.1] | App/KeysWindow, KeySheet; Core/Keys | KeysTests; KeyFormatTests (every type/size/format round trip, passphrase never on a command line); KeyFlowAppTests |
| PuTTY .ppk import v2/v3, export v3 [K.2] | Core/PuTTYKey; CRDP/airscp_crypto.c (Argon2id) | PuTTYKeyTests (PuTTY's own test vectors byte for byte; `AIRSCP_PUTTY=1`: interop with puttygen) |
| Files tab: two panes, listing, sort, filter, hidden, path bar, columns [4, H] | App/BrowserContent, FilePane, FileList, FileActions; Core/RemoteFS | WorkspaceTests; ListingTests; RemoteOpsTests `listingAFolderOf50000Entries`; lab listing, sftp-only chroot, login noise |
| Owner and Group by name, their numbers in the tooltip, sorting by them [Release 2 backlog] | Core/RemoteFS (`lsFunction`, `numbered`); App/FileList, FilePane, AgentSnapshot | ListingTests `ownersAndGroupsAreNamedAndKeepTheirNumbers`; RemoteFSTests `ownersAndGroupsAreListedByName`; WorkspaceTests `rowsSortByOwnerAndGroupNames`, `ownerAndGroupCellsShowNamesWithTheirNumbers`; AgentTests (rows); lab `FilesLabTests.ownersAndGroupsByNameOnLinux` (GNU, BusyBox, sftp) |
| Remote file operations: new, rename, delete, permissions, zip/tar, extract, edit [4, B] | Core/RemoteFS, RemoteOps; App/FileActions, FileSheets, RemoteEditor | RemoteFSTests; RemoteOpsTests; WorkspaceTests; FeatureRoundTests (safe replace, deep folders, recursive permissions) |
| Editor's Save asks when the file changed on the server: Overwrite, Show Server Version, Cancel [Release 2 backlog] | App/RemoteEditor | WorkspaceTests `editorAsksBeforeOverwritingAChangeOnTheServer`; lab `FilesLabTests.theEditorAsksWhenTheFileChangedOnTheServer` (GNU, BusyBox, sftp-only); `scripts/agent-session.sh` (steps 08, 09) |
| Get Info, folder sizes [H] | Core/RemoteOps; App/FileSheets | RemoteOpsTests; WorkspaceTests; lab `folderSizesAndGetInfo` |
| Transfers: scp, tar streams, part files, conflicts with details, cancel, retry [5, C, S, S.2] | Core/Transfer, Runner (pump) | TransferTests; StreamTransferTests; PumpTests; RegressionTests; S2AppTests `conflictSheetsCompareTheTwoItems`; lab `largeFilesMoveAtPlainScpSpeed` |
| Leave out patterns, speed limit, favourites [S.2] | Core/Transfer, Runner; App/TransfersPanel, FilePane | S2Tests; S2AppTests; lab `foldersLeaveOutWhatMatchesWithGNUAndBusyBoxTar` |
| Download as archive, upload compressed [D, E] | Core/Transfer; App/BrowserContent | StreamTransferTests; lab `compressedUploadAndArchiveDownload` |
| Server-to-server copy, drag to Finder [L] | Core/Transfer (relay); App/FilePane (file promises) | StreamTransferTests `serverToServerCopies`; WorkspaceTests (promise path) |
| Pause and resume, Pause All / Resume All [1.1.0] | Core/Transfer (`pause`, `resume`, `pausing`, `keepsPartial`); App/TransfersPanel | PauseAndVerifyTests (single files continue, folders start again, paused through a lost connection, agent control); lab `pausedTransfersContinueOnLinuxBusyBoxAndOverSFTPOnly` |
| SHA-256 checks: Verify with Checksum, Verify transfers with SHA-256 [1.1.0] | Core/Transfer (`verify`, `checksum`, `sha256`); App/TransfersPanel, SettingsWindow | PauseAndVerifyTests (verified, a damaged copy found and copied again, sftp-only says why); lab `copiesAreCheckedWithGNUAndBusyBoxSha256sum` |
| Resume after a lost connection [S.1] | Core/Transfer (`resumable`, `resume`), Runner, Session | ResumeTests; lab `cutOffTransfersContinueOnAnSFTPOnlyAccount`; AgentTests `aCutOffTransferShowsItContinuesWhereItStopped` |
| Find Files [S.1] | Core/RemoteOps (`Session.find`); App/FileSheets, FileActions | SyncFindTests; lab `findFilesOnLinuxBusyBoxAndSFTPOnly` |
| Synchronize [S.1]; its Leave out and unticking items (1.1.0) | App/Synchronize, BrowserContent; agent set/select/snapshot in App/AgentServer, AgentSnapshot | SyncFindTests (incl. `synchronizeLeavesOutWhatMatchesAndDoesOnlyTheTickedItems`); FeatureRoundTests (a level per command, 20+ files as one stream); AgentTests `agentLeavesOutAndUnticksWhatToSynchronize`; lab (GNU, BusyBox, sftp; `aCompareOf5000FilesStaysFast`, `untickedItemsAreNeitherCopiedNorDeleted`) |
| Transfers panel, Dock badge, App Nap held off [C] | App/TransfersPanel, AppModel, AppDelegate | WorkspaceTests; ShellTests; FeatureRoundTests `transfersKeepAppNapAway` |
| Monitor tab, Kill, sudo in Terminal [I] | Core/Monitor; App/MonitorTab | MonitorTests (real Debian/BusyBox captures); lab `monitorOnDebianAndBusyBoxWithKill` |
| Monitor ▸ Ports: listening sockets, their processes and users, the picked port's connections; read only while shown (2026-10-06) | Core/Monitor (`portsScript`: /proc/net tables, `ls -l` of /proc/<pid>/fd); App/MonitorTab, AgentSnapshot (`ports`), AgentServer (`select pane=ports`) | MonitorTests `portsOf…` (Debian/BusyBox captures, as a user and as root); FeatureRoundAppTests `portsAreReadOnlyWhileTheyAreShown` (every command sent); HelpTests; lab `portsOnDebianAndBusyBox`, `AgentLabTests` |
| Remote Desktop: entries, desktop, keyboard/mouse, certificates, login, through SSH [M, R] | CRDP/*; Core/RDP; App/RDPWorkspace, RDPDesktopView, RDPEditor | RDPTests (unit + VM); RDPEditorTests |
| Remote Desktop file transfer: shared folder, clipboard files both ways [S] | CRDP/rdp_clipboard.c, rdp_shim.c; Core/RDP; App/RDPWorkspace | VM `rdpKeyboardClipboardAndFilesBothWays`, `rdpClipboardSwitchedOffSharesNothing`; AgentTests (VM) |
| Light and dark, appearance setting [O] | App/SettingsWindow, AppDelegate | ShellTests `appearanceSettingSetsTheAppsAppearance` |
| Night Harbor and Paper looks, workspace header, server pulse strip [O.1] | App/Themes, HostsSidebar, HostWorkspace (`WorkspaceHeader`), FilePane (`FileRowView`), TransfersPanel, MonitorTab (`PulseStrip`); Core/Monitor `refresh(processes:)` | AgentTests `screenshotsArePNGsOfTheWindowWithItsSheets` (drawn as the key window); `scripts/docs-screenshots.sh` (light and dark pictures) |
| Self-explanatory UI: tooltips, captions, empty states, welcome, tips [U] | App/Help and each view's `.help` | HelpTests `everyControlSaysWhatItDoes`, `everyMenuItemSaysWhatItDoes`, `theWelcomeSheetComesOnceOnAFirstRun` |
| Agent control: MCP, `--agent`, snapshot/actions/waits, screenshots, indicator [T, T.1, U.2] | Core/AgentBridge; App/AgentServer, AgentSnapshot, HostsSidebar | AgentTests; AgentBridgeTests; lab `AgentLabTests`; HelpTests `theAgentIndicatorSaysWhoActsAndWhat`; CI `scripts/agent-session.sh` |
| Agents on the Windows desktop: `click target=rdp` in the picture's own pixels, a picture of each click, the Windows key, keys first in the guide [1.0.1] | App/AgentServer (`clickDesktop`, `desktopPixel`, `clickPicture`, `KeyCombo.windowsKey`); Resources/AgentGuide.md (overview, rdp) | AgentTests `desktopClicksTakeThePicturesOwnPixels`, `aDesktopClicksPictureShowsWhereItLanded`, `theWindowsKeyIsTakenOutOfADesktopCombo`; VM `clickTheMagentaTarget` (in both agent VM tests), Win+R / Win+E / Alt+D / Ctrl+Shift+N in `agentClicksTypesAndResizesTheWindowsDesktop` |
| Help menu, docs site, **?** buttons [Y] | App/Help (`HelpPage`); docs/ | DocsTests |
| Debug log: the switch, ssh -vv, the proxy helper's answers, questions, states, transfers, FreeRDP's log, redaction, rotation, Show Debug Log / Copy Diagnostics, the failure's way to it [AE] | Core/DebugLog, Runner (`DebugLog.ErrorOutput`), Commands (`verbose`), Session (`failedHop`), ProxyConnect, Transfer, RDP; CRDP/rdp_shim.c (`rdp_log_to`); App/SettingsWindow, Help (`DebugLogButton`), AppDelegate, HostsSidebar, HostWorkspace, RDPWorkspace, AgentSnapshot | DebugLogTests (off writes nothing, rotation, -vv kept out of what AirSCP shows, no secret through any path, the failed hop in words; lab: proxy 407, wrong key behind openproxy → bastion, unreachable jump host, refused port, a working chain) |
| Import from WinSCP: WinSCP.ini sites → hosts, groups, jump hosts, HTTP proxies; .ppk keys beside it → OpenSSH keys; no passwords [task 70] | Core/WinSCP (`sites`, `data`, `importKeys`); App/AppDelegate (`importWinSCP`), Help | WinSCPTests |
| Terminal tab: a shell riding the master (xterm emulator, scrollback, selection), file-aware right-click (Show in Files, Download, Edit, Get Info, Copy Path), Finder drops upload to the shell's folder, agents type/key/snapshot [W] | Core/TerminalScreen (emulator), TerminalSession (pty), Commands (`terminalShell`, `processDirectory`), CPTY (`cpty_resize`); App/TerminalTab, HostWorkspace, AgentServer/AgentSnapshot (target terminal) | TerminalScreenTests (emulator, paths, `terminalTabRunsAShellThatKnowsFiles` on a real sshd) |
| Tools menu + Certificate Manager: PEM/DER/PKCS#7/PKCS#12/JKS/keys/CSRs read, details + expiry, chain order, key match, PEM/DER/chain/key/public key/PKCS#12 export with the openssl command, View Server Certificate [AA] | CRDP/airscp_pki.c (OpenSSL in process); Core/Certificates (`PKI`, `JKS`); App/CertificateManager, AppDelegate (Tools menu), KeysWindow (`request`) | CertificatesTests (interop with openssl and keytool, test-only; a local s_server) |
| Name AirSCP, migration from Porter [X] | Core/Models, Keychain; App/AppDelegate | UnitTests `theFirstStartTakesOverPortersSettings`, `environmentVariablesStillTakeTheirPorterNames` |
| Docker lab [J] | testenv/ | LabTests, LabFeatureTests, RegressionLabTests, S1LabTests, FeatureRoundLabTests |

## Measured speed (Docker lab on an M1 Pro; Docker Desktop's port forwarding is the ceiling)

Each pair timed in both orders (October 2026): the first of a pair pays for the server's cold cache, which made the
plain tool look slower when it always went first.

| What | AirSCP | Plain tool |
|---|---|---|
| List a folder of 50 000 files | 0.78–0.89 s | sftp 0.79–1.01 s (1.6 s cold) |
| Download a 2 GiB file | 116–129 MB/s | scp 111–122 MB/s |
| Upload a 1 GiB file | 115–142 MB/s | scp 120–143 MB/s |
| Upload / download 10 000 small files (one stream) | 0.75–1.6 s / 1.2–1.3 s | scp -r 23–26 s / 26 s |
| Synchronize: compare 301 folders | 0.39 s | (20.1 s before the fix) |
| Synchronize: compare 5,000 files in 51 folders (Leave out keeps a node_modules of 2,000 unread) / show their 5,000 rows | 0.55 s / 0.5–0.8 s | |
| Remote Desktop file copy, Mac → Windows / Windows → Mac | ~9 MB/s / 1–1.5 MB/s | (the RDP channel is the limit) |
