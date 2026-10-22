import EventKit
import Foundation

/// Experimental: meeting notes that know your calendar. A meeting is named after the event happening now, the
/// people on the invite help the notes get names right, and an event with a call link starting is a reminder to
/// take notes. Reads only; Yap never changes your calendar.
@MainActor
final class MeetingCalendar {
    static let shared = MeetingCalendar()
    private let store = EKEventStore()
    private var timer: Timer?
    private var asked: Set<String> = []

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.Key.labsCalendar) }
    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks for calendar access the first time; returns whether Yap can read events.
    func requestAccess() async -> Bool {
        if hasAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingCalendar.shared.tick() }
        }
    }

    struct Event { var id: String; var title: String; var start: Date; var end: Date; var people: [String]; var hasCallLink: Bool }

    /// The event going on now (or about to start), preferring ones with a call link.
    func current(at now: Date = Date()) -> Event? {
        guard Self.isEnabled, hasAccess else { return nil }
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(15 * 60), calendars: nil)
        let events = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate.addingTimeInterval(-10 * 60) <= now && $0.endDate > now.addingTimeInterval(-5 * 60) }
            .map(Self.event)
        return events.sorted { ($0.hasCallLink ? 0 : 1, abs($0.start.timeIntervalSince(now))) < ($1.hasCallLink ? 0 : 1, abs($1.start.timeIntervalSince(now))) }.first
    }

    private func tick() {
        guard Self.isEnabled, hasAccess, AppModel.shared.meeting.phase == .idle else { return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-2 * 60), end: now.addingTimeInterval(60), calendars: nil)
        guard let e = store.events(matching: pred).map(Self.event)
            .first(where: { $0.hasCallLink && $0.start <= now.addingTimeInterval(30) && $0.start >= now.addingTimeInterval(-120) && !asked.contains($0.id) }) else { return }
        asked.insert(e.id)
        CallPrompt.shared.offerNotes(app: "calendar", name: e.title, message: "“\(e.title)” is starting. Take meeting notes?")
    }

    private static let callHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com", "whereby.com", "around.co"]

    private static func event(_ e: EKEvent) -> Event {
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ").lowercased()
        let people = (e.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty && !$0.contains("@") }
        return Event(id: e.calendarItemIdentifier + "\(e.startDate.timeIntervalSince1970)", title: e.title ?? "Meeting",
                     start: e.startDate, end: e.endDate, people: people, hasCallLink: callHosts.contains { text.contains($0) })
    }
}
