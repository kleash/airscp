import AirSCPCore
import BackgroundTasks
import Combine
import os
import SwiftUI

/// Keeps transfers going when AirSCP leaves the screen (mockup screen 13), with iOS 26's continued processing: while
/// any is queued or running, a task that the system shows with its progress (on the Lock Screen and in the Dynamic
/// Island, as a Live Activity of its own), ended once the queues are done. Asked for when a transfer starts, which is with
/// AirSCP in front, as iOS requires. When iOS stops it (the user, or the system's limits), the transfers pause, keeping
/// what they have copied, and the Transfers tab says so: Resume continues them.
@MainActor @Observable final class BackgroundTransfers {
    static let shared = BackgroundTransfers()

    /// iOS paused the transfers in the background: the Transfers tab says so until they run again.
    private(set) var stoppedByIOS = false

    /// Info.plist's BGTaskSchedulerPermittedIdentifiers has "<bundle id>.transfers.*".
    private static let identifier = (Bundle.main.bundleIdentifier ?? "com.kleash.airscp") + ".transfers.queue"
    private static let log = Logger(subsystem: "com.kleash.airscp", category: "background")
    /// Registered once, at the first transfer (iOS ends an app that registers an identifier twice).
    private static let registered: Bool = {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { BackgroundTransfers.shared.began(task) }
        }
        log.log("Registered \(identifier, privacy: .public): \(registered)")
        return registered
    }()
    private var task: BGContinuedProcessingTask?
    /// Asked for in this run of transfers (once: iOS says no while AirSCP isn't in front, or when it can't run it now).
    private var asked = false
    /// The jobs of this run: their bytes make up the progress iOS shows.
    private var tracked: Set<UUID> = []
    private var watching: AnyCancellable?

    /// Follows the transfers from now on (at launch).
    func start() {
        watching = TransferCenter.shared.$jobs.sink { [weak self] jobs in
            MainActor.assumeIsolated { self?.update(jobs) }
        }
    }

    private func update(_ jobs: [TransferJob]) {
        let active = jobs.filter(\.status.isActive)
        if !active.isEmpty { stoppedByIOS = false }
        guard !active.isEmpty || jobs.contains(where: { $0.checksum == .checking || $0.checksum == .wanted }) else {
            return finish(success: true)
        }
        tracked.formUnion(active.map(\.id))
        if !asked { ask() }
        guard let task else { return }
        // Bytes so far against the sizes known; a folder's size isn't known until it is done, so it counts twice what
        // it has copied (and a megabyte), which keeps the bar moving without reaching the end before it does.
        var done: Int64 = 0, total: Int64 = 0
        for job in jobs where tracked.contains(job.id) {
            let bytes = job.progress.bytes
            if let size = job.progress.total, !job.progress.indeterminate {
                total += size
                done += job.status.isFinished ? size : min(bytes, size)
            } else {
                total += job.status.isFinished ? bytes : 2 * bytes + (1 << 20)
                done += bytes
            }
        }
        task.progress.totalUnitCount = max(total, 1)
        task.progress.completedUnitCount = min(done, max(total, 1))
        let running = active.first { $0.status == .running } ?? active.first
        let speed = running.map { $0.progress.speed.isEmpty ? "" : " · " + $0.progress.speed } ?? ""
        task.updateTitle(active.count == 1 ? "Copying 1 transfer" : "Copying \(active.count) transfers",
                         subtitle: (running.map(TransferText.name) ?? "") + speed)
    }

    private func ask() {
        asked = true
        guard Self.registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: "Copying transfers",
                                                       subtitle: "AirSCP keeps your transfers going")
        // Now or not at all: queued, it could start after the transfers are done.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.log.info("Asked iOS to keep the transfers going in the background")
        } catch {
            // Without it the transfers go on while AirSCP is in front (the Transfers tab says so).
            Self.log.error("iOS won't keep the transfers going in the background: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func began(_ started: BGTask) {
        guard let started = started as? BGContinuedProcessingTask else { return started.setTaskCompleted(success: false) }
        task = started
        started.expirationHandler = {
            Task { @MainActor in BackgroundTransfers.shared.expired() }
        }
        update(TransferCenter.shared.currentJobs)
    }

    /// iOS stopped the task: the transfers pause, a file keeping what it has copied, and wait for Resume.
    private func expired() {
        Self.log.info("iOS stopped the background transfers; pausing them")
        let center = TransferCenter.shared
        center.pause(Set(center.currentJobs.filter(\.status.isActive).map(\.id)))
        stoppedByIOS = true
        finish(success: false)
    }

    private func finish(success: Bool) {
        task?.setTaskCompleted(success: success)
        task = nil
        asked = false
        tracked = []
    }
}
