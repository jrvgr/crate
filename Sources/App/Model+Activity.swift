import SwiftUI
import AppKit

extension Model {
    // MARK: activity

    func notify(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { message = "" } }
    }

    @discardableResult
    func startJob(_ title: String, icon: String, detail: String = "", queued: Bool = false) -> UUID {
        let j = Job(title: title, detail: detail, icon: icon, state: queued ? .queued : .running)
        jobs.insert(j, at: 0)
        return j.id
    }

    func updateJob(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        if !jobs[i].active, jobs[i].finished == nil { jobs[i].finished = Date() }
    }

    func finishJob(_ id: UUID, _ detail: String, failed: Bool = false) {
        updateJob(id) { $0.detail = detail; $0.progress = nil; $0.state = failed ? .failed(detail) : .done }
        jobs = Array(jobs.prefix(40))
    }

    var activeJobs: [Job] { jobs.filter(\.active) }
}
