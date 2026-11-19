// Todo widget backed by the default Apple Reminders list (EventKit), so items
// sync to the phone. The strip shows the next item that is due (overdue, today,
// tomorrow if high priority, or undated); clicking it opens
// its drawer (Drawers.swift) with the whole list and an add field.
import AppKit
import EventKit
import SwiftUI

struct TodoItem: Identifiable, Equatable {
    let id: String
    let title: String
}

@MainActor
final class Todos: ObservableObject {
    @Published private(set) var items: [TodoItem] = []
    /// The subset the Dock strip shows (see `upcoming(_:)`); the drawer lists `items`.
    @Published private(set) var upcoming: [TodoItem] = []
    @Published private(set) var denied = false

    private let store = EKEventStore()
    private var reminders: [String: EKReminder] = [:]

    init() {
        if let demo = Config.demo {
            let titles = demo == "a" ? ["Fix bell UI", "Reply to Sam", "Buy coffee"] : ["Export the trailer at 60 fps for the store page"]
            items = titles.enumerated().map { TodoItem(id: "\($0.offset)", title: $0.element) }
            upcoming = items
            return
        }
        store.requestFullAccessToReminders { granted, _ in
            Task { @MainActor in
                self.denied = !granted
                self.reload()
            }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        guard let list = store.defaultCalendarForNewReminders() else { return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        store.fetchReminders(matching: predicate) { found in
            let sorted = (found ?? []).sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            let upcoming = Self.upcoming(sorted)
            Task { @MainActor in
                self.reminders = Dictionary(sorted.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
                let items = sorted.map { TodoItem(id: $0.calendarItemIdentifier, title: $0.title ?? "") }
                if items != self.items { self.items = items }
                if upcoming != self.upcoming { self.upcoming = upcoming }
            }
        }
    }

    /// What the strip may show: overdue, due today, due tomorrow when high
    /// priority, or undated. Dated ones first by due time, then oldest created.
    nonisolated private static func upcoming(_ sorted: [EKReminder]) -> [TodoItem] {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let dayAfter = cal.date(byAdding: .day, value: 1, to: tomorrow)!
        let dated = sorted.map { r in (r, r.dueDateComponents.flatMap { cal.date(from: $0) }) }
        let shown = dated.filter { r, due in
            guard let due else { return true }
            return due < tomorrow || (due < dayAfter && (1...4).contains(r.priority))
        }
        let ordered = shown.enumerated().sorted { a, b in
            switch (a.element.1, b.element.1) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }
        return ordered.map { TodoItem(id: $0.element.0.calendarItemIdentifier, title: $0.element.0.title ?? "") }
    }

    func complete(_ item: TodoItem) {
        items.removeAll { $0 == item }
        upcoming.removeAll { $0 == item }
        guard let reminder = reminders.removeValue(forKey: item.id) else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
    }

    func add(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard Config.demo == nil, let list = store.defaultCalendarForNewReminders() else {
            items.append(TodoItem(id: UUID().uuidString, title: title))
            upcoming.append(items[items.count - 1])
            return
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        try? store.save(reminder, commit: true)
        reminders[reminder.calendarItemIdentifier] = reminder
        items.append(TodoItem(id: reminder.calendarItemIdentifier, title: title))
        upcoming.append(items[items.count - 1])
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
    }
}

/// The strip beside the Dock: the next item and how many follow. Clicking the
/// text opens the full list in a popover.
struct TodoView: View {
    @ObservedObject var todos: Todos
    let height: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            if todos.denied {
                Button("Allow Reminders access", action: todos.openSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
            } else if let first = todos.upcoming.first {
                Button { withAnimation(.smooth) { todos.complete(first) } } label: {
                    Image(systemName: "circle").font(.system(size: 18, weight: .regular))
                        .frame(width: 28, height: 28).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Mark done")

                Button { Drawers.shared.toggle("todo") } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(first.title).font(.system(size: 14, weight: .semibold))
                        Text(todos.items.count > 1 ? "\(todos.items.count - 1) more" : "Reminders")
                            .font(.system(size: 12)).foregroundStyle(ink(0.6))
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .hug(max: 200)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WidgetPress())
                .id(first.id)
                .transition(.blurReplace)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(height: height)
        .animation(.smooth(duration: 0.3), value: todos.upcoming)
    }
}

/// Drawer content: every open item and an add field.
struct TodoList: View {
    @ObservedObject var todos: Todos
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(todos.items) { item in
                        HStack(spacing: 10) {
                            IconButton(symbol: "circle", size: 15) { withAnimation(.smooth) { todos.complete(item) } }
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 30)
                TextField("New reminder", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($typing)
                    .onSubmit { withAnimation(.smooth) { todos.add(draft) }; draft = "" }
            }
            .padding(10)
        }
        .frame(width: 300)
        .card()
        .onAppear { typing = true }
    }
}
