import SwiftUI
import EventKit

// Calendars and To Do on the iPod: the Mac's calendars and reminders (EventKit) become .ics files
// in the iPod's Calendars folder ("Crate <name>.ics", replaced on every sync). Repeating events
// are written out one by one, in local time, which is what the old iPod firmware reads best.

enum CalendarSync {
    static let store = EKEventStore()

    static var eventsAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var remindersAllowed: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    static func requestEvents() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }
    static func requestReminders() async -> Bool { (try? await store.requestFullAccessToReminders()) ?? false }

    static func calendars(_ type: EKEntityType) -> [EKCalendar] {
        store.calendars(for: type).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: iCalendar text

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines longer than 75 octets are folded, as the format wants.
    static func fold(_ line: String) -> String {
        var out = "", cur = ""
        for ch in line {
            if (cur + String(ch)).utf8.count > 74 { out += cur + "\r\n "; cur = "" }
            cur.append(ch)
        }
        return out + cur
    }

    static let local: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    static func file(_ components: [[String]]) -> String {
        let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Crate//iPod//EN"] + components.flatMap { $0 } + ["END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func event(_ e: EKEvent) -> [String] {
        var l = ["BEGIN:VEVENT", "UID:\(esc(e.calendarItemIdentifier))-\(day.string(from: e.startDate))", "SUMMARY:\(esc(e.title ?? ""))"]
        if e.isAllDay {
            l += ["DTSTART;VALUE=DATE:\(day.string(from: e.startDate))",
                  "DTEND;VALUE=DATE:\(day.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: e.endDate))!))"]
        } else {
            l += ["DTSTART:\(local.string(from: e.startDate))", "DTEND:\(local.string(from: e.endDate))"]
        }
        if let loc = e.location, !loc.isEmpty { l.append("LOCATION:\(esc(loc))") }
        if let n = e.notes, !n.isEmpty { l.append("DESCRIPTION:\(esc(String(n.prefix(400))))") }
        if let a = e.alarms?.first, a.absoluteDate == nil {
            l += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:\(esc(e.title ?? ""))", "TRIGGER:-PT\(max(0, Int(-a.relativeOffset / 60)))M", "END:VALARM"]
        }
        return l + ["END:VEVENT"]
    }

    static func todo(_ r: EKReminder) -> [String] {
        var l = ["BEGIN:VTODO", "UID:\(esc(r.calendarItemIdentifier))", "SUMMARY:\(esc(r.title ?? ""))", "STATUS:NEEDS-ACTION"]
        if let d = r.dueDateComponents?.date ?? r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) {
            l.append("DUE;VALUE=DATE:\(day.string(from: d))")
        }
        if r.priority > 0 { l.append("PRIORITY:\(r.priority)") }
        if let n = r.notes, !n.isEmpty { l.append("DESCRIPTION:\(esc(String(n.prefix(400))))") }
        return l + ["END:VTODO"]
    }

    static func reminders(_ cals: [EKCalendar]) async -> [EKReminder] {
        await withCheckedContinuation { c in
            store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)) { c.resume(returning: $0 ?? []) }
        }
    }

    /// Writes the files; returns a one-line summary.
    static func write(to ipod: IPodInfo, settings s: PodSettings) async -> String {
        let dir = ipod.mount.appendingPathComponent("Calendars")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasPrefix("Crate ") && n.hasSuffix(".ics") {
            try? fm.removeItem(at: dir.appendingPathComponent(n))
        }
        var parts: [String] = []
        if s.calendars, eventsAllowed {
            let cals = calendars(.event).filter { s.calendarIDs.isEmpty || s.calendarIDs.contains($0.calendarIdentifier) }
            let start = Calendar.current.date(byAdding: .day, value: -s.calendarPastDays, to: Calendar.current.startOfDay(for: Date()))!
            let end = Calendar.current.date(byAdding: .day, value: s.calendarFutureDays, to: Date())!
            var n = 0
            for c in cals {
                let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [c]))
                guard !events.isEmpty else { continue }
                let name = "Crate " + Organizer.clean(c.title) + ".ics"
                try? file(events.map(event)).write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
                n += events.count
            }
            parts.append("\(n) events")
        }
        if s.reminders, remindersAllowed {
            let lists = calendars(.reminder).filter { s.reminderIDs.isEmpty || s.reminderIDs.contains($0.calendarIdentifier) }
            let rs = await reminders(lists)
            if !rs.isEmpty { try? file(rs.map(todo)).write(to: dir.appendingPathComponent("Crate To Do.ics"), atomically: true, encoding: .utf8) }
            parts.append("\(rs.count) to-dos")
        }
        return parts.isEmpty ? "" : parts.joined(separator: ", ") + " on the iPod"
    }
}

@MainActor
final class CalendarUI: ObservableObject {
    @Published var status = ""
    @Published var working = false
}

/// The Calendars & To Do card on the iPod page.
struct CalendarSettings: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = CalendarUI()

    var body: some View {
        SettingsCard {
            SettingRow(icon: "calendar", title: "Calendars", detail: model.podSettings.calendars
                       ? "\(model.podSettings.calendarIDs.isEmpty ? "All calendars" : "\(model.podSettings.calendarIDs.count) calendars"), \(model.podSettings.calendarPastDays) days back to \(model.podSettings.calendarFutureDays) ahead"
                       : "Your Mac's calendars on the iPod (Extras › Calendars)") {
                if model.podSettings.calendars {
                    Menu("Choose") {
                        Button("All Calendars") { model.podSettings.calendarIDs = [] }
                        Divider()
                        ForEach(CalendarSync.calendars(.event), id: \.calendarIdentifier) { c in
                            Toggle(c.title, isOn: Binding(get: { model.podSettings.calendarIDs.contains(c.calendarIdentifier) },
                                                          set: { on in
                                                              if on { model.podSettings.calendarIDs.append(c.calendarIdentifier) }
                                                              else { model.podSettings.calendarIDs.removeAll { $0 == c.calendarIdentifier } }
                                                          }))
                        }
                        Divider()
                        Picker("Ahead", selection: $model.podSettings.calendarFutureDays) {
                            ForEach([30, 90, 180, 365], id: \.self) { Text("\($0) days ahead").tag($0) }
                        }
                    }
                    .fixedSize()
                }
                Toggle("", isOn: Binding(get: { model.podSettings.calendars }, set: { on in
                    Task { if on && !CalendarSync.eventsAllowed { _ = await CalendarSync.requestEvents() }
                           model.podSettings.calendars = on && CalendarSync.eventsAllowed
                           if on && !CalendarSync.eventsAllowed { ui.status = "Crate isn't allowed to read your calendars (System Settings › Privacy & Security › Calendars)" } }
                })).toggleStyle(.switch).labelsHidden()
            }
            Divider().padding(.leading, 50)
            SettingRow(icon: "checklist", title: "To Do", detail: model.podSettings.reminders
                       ? (model.podSettings.reminderIDs.isEmpty ? "All reminder lists" : "\(model.podSettings.reminderIDs.count) lists") + ", open items"
                       : "Open reminders as the iPod's To Do list") {
                if model.podSettings.reminders {
                    Menu("Choose") {
                        Button("All Lists") { model.podSettings.reminderIDs = [] }
                        Divider()
                        ForEach(CalendarSync.calendars(.reminder), id: \.calendarIdentifier) { c in
                            Toggle(c.title, isOn: Binding(get: { model.podSettings.reminderIDs.contains(c.calendarIdentifier) },
                                                          set: { on in
                                                              if on { model.podSettings.reminderIDs.append(c.calendarIdentifier) }
                                                              else { model.podSettings.reminderIDs.removeAll { $0 == c.calendarIdentifier } }
                                                          }))
                        }
                    }
                    .fixedSize()
                }
                Toggle("", isOn: Binding(get: { model.podSettings.reminders }, set: { on in
                    Task { if on && !CalendarSync.remindersAllowed { _ = await CalendarSync.requestReminders() }
                           model.podSettings.reminders = on && CalendarSync.remindersAllowed
                           if on && !CalendarSync.remindersAllowed { ui.status = "Crate isn't allowed to read your reminders (System Settings › Privacy & Security › Reminders)" } }
                })).toggleStyle(.switch).labelsHidden()
            }
            if model.podSettings.calendars || model.podSettings.reminders || !ui.status.isEmpty {
                Divider().padding(.leading, 50)
                HStack {
                    Text(ui.status.isEmpty ? "Updated on every sync." : ui.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if ui.working { ProgressView().controlSize(.small) }
                    Button("Update Now") {
                        ui.working = true
                        Task { ui.status = await model.writeCalendars(); ui.working = false }
                    }
                    .buttonStyle(.glass).disabled(!model.connected || ui.working || !(model.podSettings.calendars || model.podSettings.reminders))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}
