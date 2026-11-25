import SwiftUI
import AppKit
import UserNotifications

// MARK: - Model

/// Something to come back to, optionally tied to a session
struct FollowUp: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var doneAt: Date?
    var remindAt: Date?
    var link: SessionLink?

    var isDone: Bool { doneAt != nil }

    func isDue(at now: Date) -> Bool {
        guard !isDone, let remindAt = remindAt else { return false }
        return remindAt <= now
    }
}

/// Identifies a session: the exact window while it's open (its Ghostty process), then what survives
/// a relaunch (workstream, then directory)
struct SessionLink: Codable, Equatable {
    var workstreamName: String?
    var cwd: String?
    var label: String  // last-known name, shown while the window is closed
    var pid: pid_t?    // Ghostty process of the linked window (each window usually has its own)
    var axIndex: Int?  // tells windows of one process apart

    init(workstreamName: String?, cwd: String?, label: String) {
        self.workstreamName = workstreamName
        self.cwd = cwd
        self.label = label
    }

    init(window: GhosttyWindow) {
        workstreamName = window.workstreamName
        cwd = window.shellCwd
        label = window.displayName
        pid = window.pid
        axIndex = window.axIndex
    }

    /// The open window this link points at. The linked window itself while it's open; after it closes,
    /// a window of the same workstream, or the only window in the directory (several sessions often
    /// share one, so a directory alone picks one only when the title still matches)
    func window(in windows: [GhosttyWindow]) -> GhosttyWindow? {
        if let pid = pid {
            let same = windows.filter { $0.pid == pid }
            if let match = same.first(where: { $0.axIndex == axIndex }) ?? same.first {
                return match
            }
        }
        if let ws = workstreamName, let match = windows.first(where: { $0.workstreamName == ws }) {
            return match
        }
        if let cwd = cwd {
            let same = windows.filter { $0.shellCwd == cwd }
            if same.count == 1 { return same[0] }
            let title = Self.plainTitle(label)
            return same.first { Self.plainTitle($0.displayName) == title }
        }
        return nil
    }

    /// The label without Claude's status glyph ("✳ Fix tests" -> "Fix tests"), which changes as it works
    var plainLabel: String { Self.plainTitle(label) }

    static func plainTitle(_ title: String) -> String {
        guard let scalar = title.unicodeScalars.first,
              scalar == "\u{2733}" || (0x2800...0x28FF).contains(scalar.value) || (0x25A0...0x25FF).contains(scalar.value) else {
            return title
        }
        return String(title.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}

enum ReminderPreset: String, CaseIterable, Identifiable {
    case none, oneHour, fourHours, tomorrow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "No reminder"
        case .oneHour: return "In 1 hour"
        case .fourHours: return "In 4 hours"
        case .tomorrow: return "Tomorrow 9 AM"
        }
    }

    func date(from now: Date = Date()) -> Date? {
        switch self {
        case .none: return nil
        case .oneHour: return now.addingTimeInterval(3600)
        case .fourHours: return now.addingTimeInterval(4 * 3600)
        case .tomorrow:
            let cal = Calendar.current
            guard let tomorrow = cal.date(byAdding: .day, value: 1, to: now) else { return nil }
            return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
    }
}

// MARK: - Store

final class FollowUpStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = FollowUpStore()

    @Published private(set) var items: [FollowUp] = []

    /// The add field is open; `composeLink` pre-links the new item (set from a session row's menu)
    @Published var isComposing = false
    @Published var composeLink: SessionLink?

    private let fileURL: URL
    /// Done items older than this are dropped at load
    private let doneRetention: TimeInterval = 7 * 24 * 3600

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhosttyThemePicker", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("followups.json")
        super.init()
        load()
        UNUserNotificationCenter.current().delegate = self
    }

    var openItems: [FollowUp] { items.filter { !$0.isDone } }

    // MARK: Editing

    @discardableResult
    func add(title: String, link: SessionLink?, remindAt: Date?) -> FollowUp? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = FollowUp(id: UUID(), title: trimmed, createdAt: Date(), doneAt: nil, remindAt: remindAt, link: link)
        items.append(item)
        save()
        scheduleReminder(for: item)
        return item
    }

    /// Check an item off (unlike toggleDone, doing it twice leaves it done)
    func markDone(_ id: UUID) {
        guard item(id)?.isDone == false else { return }
        toggleDone(id)
    }

    /// The item whose id is or starts with `idOrPrefix` (case-insensitive), if exactly one matches,
    /// so the API and `followup.sh done` can take the short ids that `list` prints
    func item(matching idOrPrefix: String) -> FollowUp? {
        let key = idOrPrefix.lowercased()
        guard !key.isEmpty else { return nil }
        let matches = items.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        return matches.count == 1 ? matches[0] : nil
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id) { $0.title = trimmed }
        if let item = item(id) { scheduleReminder(for: item) }  // keep the notification text current
    }

    func toggleDone(_ id: UUID) {
        mutate(id) { $0.doneAt = $0.isDone ? nil : Date() }
        if let item = item(id) { scheduleReminder(for: item) }
    }

    func setReminder(_ id: UUID, _ date: Date?) {
        mutate(id) { $0.remindAt = date }
        if let item = item(id) { scheduleReminder(for: item) }
    }

    func relink(_ id: UUID, to link: SessionLink?) {
        mutate(id) { $0.link = link }
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
        cancelReminder(id)
    }

    func startComposing(link: SessionLink?) {
        composeLink = link
        isComposing = true
    }

    /// Open items per session key (pid-axIndex), for the badge on session rows
    func openCounts(in windows: [GhosttyWindow]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in openItems {
            guard let window = item.link?.window(in: windows) else { continue }
            counts["\(window.pid)-\(window.axIndex)", default: 0] += 1
        }
        return counts
    }

    private func item(_ id: UUID) -> FollowUp? {
        items.first { $0.id == id }
    }

    private func mutate(_ id: UUID, _ change: (inout FollowUp) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let loaded = try decoder.decode([FollowUp].self, from: data)
            let cutoff = Date().addingTimeInterval(-doneRetention)
            items = loaded.filter { ($0.doneAt ?? .distantFuture) > cutoff }
        } catch {
            // Keep the unreadable file for inspection instead of overwriting it on the next save
            let aside = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            print("FollowUps: could not read \(fileURL.path) (\(error)); moved to \(aside.lastPathComponent)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(items).write(to: fileURL, options: .atomic)
        } catch {
            print("FollowUps: failed to save: \(error)")
        }
    }

    // MARK: Reminders

    /// (Re)schedule the item's notification, or cancel it when it's done or has no future reminder
    private func scheduleReminder(for item: FollowUp) {
        cancelReminder(item.id)
        guard !item.isDone, let date = item.remindAt, date > Date() else { return }

        let center = UNUserNotificationCenter.current()
        // Ask on first use rather than at launch; a no-op once the user has answered
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Follow-up"
            content.body = item.title
            if let label = item.link?.plainLabel { content.subtitle = label }
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger))
        }
    }

    private func cancelReminder(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    // Show banners even when the app (or its sidebar panel) is active
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking the notification focuses the linked session, if it's open
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = UUID(uuidString: response.notification.request.identifier)
        DispatchQueue.main.async {
            if let id = id, let item = self.item(id),
               let window = item.link?.window(in: WindowTracker.shared.ghosttyWindows) {
                SessionSidebarPanel.shared.focusAndDock(window)
            }
            completionHandler()
        }
    }
}

// MARK: - Sidebar Section

struct FollowUpsSection: View {
    @ObservedObject var store: FollowUpStore
    let windows: [GhosttyWindow]
    let filter: String

    @AppStorage("followUpsCollapsed") private var collapsed = false
    /// Items checked off in the last few seconds stay visible (struck through) so the click registers
    @State private var recentlyDone: Set<UUID> = []
    @State private var editingID: UUID?
    @State private var now = Date()

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var visibleItems: [FollowUp] {
        store.items
            .filter { !$0.isDone || recentlyDone.contains($0.id) }
            .filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
            .sorted { a, b in
                let dueA = a.isDue(at: now), dueB = b.isDue(at: now)
                if dueA != dueB { return dueA }
                return a.createdAt < b.createdAt
            }
    }

    private var openCount: Int { store.openItems.count }

    var body: some View {
        // No section at all when there's nothing to show; the sidebar header's ＋ opens the add field
        if openCount > 0 || store.isComposing || !recentlyDone.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                header
                if !collapsed {
                    if store.isComposing {
                        FollowUpComposer(store: store, windows: windows)
                    }
                    ForEach(visibleItems) { item in
                        FollowUpRow(
                            item: item,
                            window: item.link?.window(in: windows),
                            windows: windows,
                            now: now,
                            isEditing: Binding(
                                get: { editingID == item.id },
                                set: { editingID = $0 ? item.id : nil }
                            ),
                            onToggle: { toggle(item) }
                        )
                    }
                }
            }
            .padding(.bottom, 4)
            .onReceive(clock) { now = $0 }
            .onChange(of: store.isComposing) { composing in
                if composing { collapsed = false }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("FOLLOW-UPS")
                .foregroundColor(.secondary)
            if collapsed, let next = visibleItems.first(where: { !$0.isDone }) {
                Text(next.title)
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text("\(openCount)")
                .monospacedDigit()
                .foregroundColor(store.openItems.contains { $0.isDue(at: now) } ? .orange : .secondary)
            Button {
                store.startComposing(link: nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add follow-up")
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .frame(width: 10)
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Show follow-ups" : "Hide follow-ups")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func toggle(_ item: FollowUp) {
        let id = item.id
        store.toggleDone(id)
        if item.isDone {
            recentlyDone.remove(id)  // un-checked during the fade window
            return
        }
        recentlyDone.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeOut(duration: 0.3)) { _ = recentlyDone.remove(id) }
        }
    }
}

// MARK: - Session Picker

/// Menu of open sessions to link a follow-up to. Selection is `none`, `existing` (a link whose window
/// is closed, kept as is), or an open window's pid-axIndex.
private struct SessionPicker: View {
    @Binding var selection: String
    let windows: [GhosttyWindow]
    let existing: SessionLink?

    static let none = ""
    static let existingTag = "existing"

    var body: some View {
        Picker("", selection: $selection) {
            Text("No session").tag(Self.none)
            if let link = existing, link.window(in: windows) == nil {
                Text("\(link.plainLabel) (closed)").tag(Self.existingTag)
            }
            ForEach(windows.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
                    id: \.id) { window in
                Text(window.displayName).tag(Self.key(window))
            }
        }
        .labelsHidden()
        .help("Link to a session")
    }

    static func key(_ window: GhosttyWindow) -> String {
        "\(window.pid)-\(window.axIndex)"
    }

    /// What to preselect for a link
    static func selection(for link: SessionLink?, in windows: [GhosttyWindow]) -> String {
        guard let link = link else { return none }
        return link.window(in: windows).map(key) ?? existingTag
    }

    /// The link a selection stands for
    static func link(for selection: String, in windows: [GhosttyWindow], existing: SessionLink?) -> SessionLink? {
        if selection == existingTag { return existing }
        return windows.first { key($0) == selection }.map(SessionLink.init(window:))
    }
}

// MARK: - Composer

private struct FollowUpComposer: View {
    @ObservedObject var store: FollowUpStore
    let windows: [GhosttyWindow]

    @State private var title = ""
    @State private var linkKey = SessionPicker.none
    @State private var reminder: ReminderPreset = .none
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What do you need to follow up on?", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
                .onExitCommand(perform: cancel)

            HStack(spacing: 6) {
                SessionPicker(selection: $linkKey, windows: windows, existing: store.composeLink)

                Picker("", selection: $reminder) {
                    ForEach(ReminderPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .help("Remind me")
            }
            .controlSize(.small)

            HStack {
                Spacer()
                // Return/Esc are handled by the text field (onSubmit/onExitCommand)
                Button("Cancel", action: cancel)
                Button("Add", action: add)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onAppear(perform: prefill)
        .onChange(of: store.composeLink) { _ in prefill() }
    }

    private func prefill() {
        linkKey = SessionPicker.selection(for: store.composeLink, in: windows)
        SessionSidebarPanel.shared.makeKey()
        DispatchQueue.main.async { focused = true }
    }

    private func add() {
        let link = SessionPicker.link(for: linkKey, in: windows, existing: store.composeLink)
        store.add(title: title, link: link, remindAt: reminder.date())
        title = ""
        reminder = .none
        cancel()
    }

    private func cancel() {
        store.isComposing = false
        store.composeLink = nil
    }
}

// MARK: - Row

private struct FollowUpRow: View {
    let item: FollowUp
    let window: GhosttyWindow?  // the linked session, when open
    let windows: [GhosttyWindow]
    let now: Date
    @Binding var isEditing: Bool
    let onToggle: () -> Void

    @ObservedObject private var store = FollowUpStore.shared
    @State private var hovering = false
    @State private var draft = ""
    @State private var draftLink = SessionPicker.none
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(item.isDone ? .green : item.isDue(at: now) ? .orange : .secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help(item.isDone ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($editFocused)
                        .onSubmit(saveEdit)
                        .onExitCommand { isEditing = false }
                        .onAppear {
                            draft = item.title
                            draftLink = SessionPicker.selection(for: item.link, in: windows)
                            SessionSidebarPanel.shared.makeKey()
                            DispatchQueue.main.async { editFocused = true }
                        }
                    HStack(spacing: 6) {
                        SessionPicker(selection: $draftLink, windows: windows, existing: item.link)
                        Button("Cancel") { isEditing = false }
                        Button("Save", action: saveEdit)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.small)
                } else {
                    HStack(spacing: 4) {
                        if item.isDue(at: now) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                        }
                        Text(item.title)
                            .font(.callout)
                            .strikethrough(item.isDone)
                            .foregroundColor(item.isDone ? .secondary : .primary)
                            .lineLimit(2)
                    }
                }
                if !isEditing && (item.link != nil || item.remindAt != nil) {
                    detailLine
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering && window != nil ? Color.primary.opacity(0.08) : Color.clear)
        )
        .padding(.horizontal, 4)
        .opacity(item.isDone ? 0.6 : 1)
        .onHover { hovering = $0 }
        .onTapGesture {
            if let window = window, !isEditing {
                SessionSidebarPanel.shared.focusAndDock(window)
            }
        }
        .help(window != nil ? "Click to focus \(window!.displayName)" : "")
        .contextMenu { menu }
    }

    private var detailLine: some View {
        HStack(spacing: 4) {
            if let link = item.link {
                Text("↳ \(window?.displayName ?? link.plainLabel)\(window == nil ? " (closed)" : "")")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("· \(Self.age(of: item.createdAt, now: now))")
            }
            Spacer(minLength: 4)
            if let remindAt = item.remindAt, !item.isDone {
                Label(Self.reminderText(remindAt, now: now), systemImage: "alarm")
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(remindAt <= now ? .orange : .secondary)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private func saveEdit() {
        store.rename(item.id, to: draft)
        let link = SessionPicker.link(for: draftLink, in: windows, existing: item.link)
        if link != item.link { store.relink(item.id, to: link) }
        isEditing = false
    }

    @ViewBuilder
    private var menu: some View {
        Button("Edit") { isEditing = true }
        Menu("Remind Me") {
            ForEach(ReminderPreset.allCases.filter { $0 != .none }) { preset in
                Button(preset.label) { store.setReminder(item.id, preset.date()) }
            }
            if item.remindAt != nil {
                Divider()
                Button("Clear Reminder") { store.setReminder(item.id, nil) }
            }
        }
        if item.link != nil {
            Button("Unlink Session") { store.relink(item.id, to: nil) }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item.id) }
    }

    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }

    static func reminderText(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return "Tmrw \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
