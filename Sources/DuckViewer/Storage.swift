import CryptoKit
import Foundation

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DuckViewer", isDirectory: true)
    }

    static var notes: URL { support.appendingPathComponent("notes", isDirectory: true) }

    /// 터미널 속 AI 에이전트가 읽는 현재 읽기 상태
    static var context: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".duckviewer", isDirectory: true)
            .appendingPathComponent("context.json")
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// 파일 내용 해시. 파일을 옮기거나 이름을 바꿔도 메모가 따라간다.
enum DocumentKey {
    static func make(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ReadingPosition {
    private static let key = "readingPositions"

    static func load(key documentKey: String?) -> Int {
        guard let documentKey else { return 0 }
        let positions = UserDefaults.standard.dictionary(forKey: key) as? [String: Int]
        return positions?[documentKey] ?? 0
    }

    static func save(_ page: Int, key documentKey: String?) {
        guard let documentKey else { return }
        var positions = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        positions[documentKey] = page
        UserDefaults.standard.set(positions, forKey: key)
    }
}

enum ReadingContext {
    private struct Payload: Encodable {
        let file: String?
        let page: Int
        let pageCount: Int
        let selection: String
        let pageText: String
        let updatedAt: Date
    }

    static func write(file: URL?, page: Int, pageCount: Int, selection: String, pageText: String) {
        let payload = Payload(
            file: file?.path,
            page: page + 1,
            pageCount: pageCount,
            selection: selection,
            pageText: pageText,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        AppPaths.ensureDirectory(AppPaths.context.deletingLastPathComponent())
        try? data.write(to: AppPaths.context, options: .atomic)
    }
}

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    /// 0부터 시작하는 페이지 인덱스
    var page: Int
    var text: String
    var quote: String?
    var source: String?
    var createdAt = Date()
}

@MainActor
final class NotesStore: ObservableObject {
    private struct File: Codable {
        var file: String
        var notes: [Note]
    }

    @Published private(set) var notes: [Note] = []
    private var key: String?
    private var fileURL: URL?

    func load(key: String?, fileURL: URL) {
        self.key = key
        self.fileURL = fileURL
        notes = []
        guard let path = storagePath,
              let data = try? Data(contentsOf: path),
              let file = try? decoder.decode(File.self, from: data)
        else { return }
        notes = file.notes
    }

    func add(_ note: Note) {
        notes.append(note)
        save()
    }

    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        save()
    }

    func remove(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    var sorted: [Note] {
        notes.sorted { ($0.page, $0.createdAt) < ($1.page, $1.createdAt) }
    }

    private var storagePath: URL? {
        key.map { AppPaths.notes.appendingPathComponent("\($0).json") }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func save() {
        guard let path = storagePath, let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(File(file: fileURL.path, notes: notes)) else { return }
        AppPaths.ensureDirectory(AppPaths.notes)
        try? data.write(to: path, options: .atomic)
    }
}
