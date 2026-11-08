import Foundation
import Observation
import OSLog

struct Dictation: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var text: String
}

/// Recent dictations, newest first, kept in a JSON file on this Mac.
@MainActor
@Observable
final class HistoryStore {
    static let limit = 200

    private(set) var items: [Dictation]
    private let file: URL

    init(file: URL = AppPaths.history) {
        self.file = file
        items = (try? JSONDecoder().decode([Dictation].self, from: Data(contentsOf: file))) ?? []
    }

    func add(_ text: String) {
        items.insert(Dictation(date: .now, text: text), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func remove(_ item: Dictation) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items = []
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(to: file, options: .atomic)
        } catch {
            Logger.app.error("History save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
