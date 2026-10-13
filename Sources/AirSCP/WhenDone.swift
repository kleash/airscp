import AirSCPCore
import AppKit
import IOKit.pwr_mgt
import SwiftUI
import UserNotifications

/// The Transfers panel's When Done: what happens once every transfer has
/// finished. It fires once, then goes back to Do Nothing; it isn't saved.
enum WhenDone: String, CaseIterable {
    case nothing = "Do Nothing", disconnect = "Disconnect", sleep = "Sleep This Mac", notify = "Notify"

    var help: String {
        switch self {
        case .nothing: return "Nothing happens when the transfers finish"
        case .disconnect: return "Disconnect every host once the transfers have finished"
        case .sleep: return "Put this Mac to sleep once the transfers have finished"
        case .notify: return "Show a notification once transfers that took longer than 30 seconds have finished"
        }
    }
}

@MainActor
final class WhenDoneModel: ObservableObject {
    static let shared = WhenDoneModel()
    @Published var choice = WhenDone.nothing
    /// Does the choice, given how long the batch took (the app's; tests set a stand-in).
    var perform: (WhenDone, TimeInterval) -> Void = { _, _ in }
    private var started: Date?

    /// Told how many transfers are running or queued. A batch ends when none is, and none is paused either.
    func activeChanged(_ count: Int, unfinished: Bool) {
        if count > 0 {
            if started == nil { started = Date() }
            return
        }
        guard let started, !unfinished else { return }
        self.started = nil
        let choice = self.choice
        guard choice != .nothing else { return }
        self.choice = .nothing
        perform(choice, Date().timeIntervalSince(started))
    }

    /// Puts this Mac to sleep; why not, when macOS refuses.
    static func sleepMac() -> String? {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { return "AirSCP can't reach macOS's power management." }
        defer { IOServiceClose(port) }
        let result = IOPMSleepSystem(port)
        return result == kIOReturnSuccess ? nil : String(format: "macOS didn't let AirSCP put this Mac to sleep (error 0x%x).", result)
    }

    /// A notification that the transfers have finished (asking once for permission), for batches over 30 s.
    static func notify(after seconds: TimeInterval, summary: String) {
        guard seconds >= 30 else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Transfers finished"
            content.body = summary
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                         trigger: nil))
        }
    }
}

/// The header's When Done menu.
struct WhenDoneMenu: View {
    @ObservedObject var model = WhenDoneModel.shared

    var body: some View {
        Menu {
            Picker("When the transfers finish", selection: $model.choice) {
                ForEach(WhenDone.allCases, id: \.self) { Text($0.rawValue).tag($0).help($0.help) }
            }
            .pickerStyle(.inline)
        } label: {
            // What will happen, once chosen; until then the short title leaves the header's buttons their room.
            Text(model.choice == .nothing ? "When Done" : "When Done: " + model.choice.rawValue)
                .fontWeight(model.choice == .nothing ? .regular : .semibold)
        }
        .fixedSize()
        .accessibilityIdentifier("transfers.whenDone")
        .help("What happens once every transfer has finished: nothing, disconnect, sleep this Mac or a notification. "
              + "It happens once, then goes back to Do Nothing.")
    }
}
