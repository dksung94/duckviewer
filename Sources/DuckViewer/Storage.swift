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

/// 시작 화면의 최근 문서. 문서 기반 앱이 아니라서 NSDocumentController 목록 대신 직접 관리한다.
enum RecentFiles {
    private static let key = "recentFiles"

    static func load() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: key)
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

/// 하이라이트 한 덩어리. 선택이 여러 페이지에 걸칠 수 있어서 페이지마다 따로 둔다.
struct HighlightRegion: Codable, Equatable {
    /// 0부터 시작하는 페이지 인덱스
    var page: Int
    /// PDF 페이지 좌표의 사각형들 [x, y, width, height] (줄 단위)
    var rects: [[Double]]
}

enum NoteColor: String, Codable, CaseIterable {
    case yellow, green, blue, pink

    var label: String {
        switch self {
        case .yellow: "노랑"
        case .green: "초록"
        case .blue: "파랑"
        case .pink: "분홍"
        }
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
    // 아래부터는 v0.2에서 추가. 이전 파일과 호환되도록 모두 Optional로 둔다.
    var highlights: [HighlightRegion]?
    var color: NoteColor?

    var isHighlight: Bool { !(highlights?.isEmpty ?? true) }
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
        guard let path = storagePath, let data = try? Data(contentsOf: path) else { return }
        do {
            notes = try decoder.decode(File.self, from: data).notes
        } catch {
            // 형식이 맞지 않아도 다음 저장에서 덮어쓰지 않도록 백업해 둔다.
            let backup = path.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: path, to: backup)
            NSLog("DuckViewer: 메모 파일을 읽지 못해 \(backup.path) 로 옮겼습니다: \(error)")
        }
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

    /// Obsidian 등에서 바로 쓸 수 있는 Markdown
    func markdown(title: String) -> String {
        var lines = ["# \(title)", ""]
        if let fileURL { lines += ["- 파일: `\(fileURL.path)`", "- 내보낸 날짜: \(Date().formatted(date: .abbreviated, time: .shortened))", ""] }
        var lastPage = -1
        for note in sorted {
            if note.page != lastPage {
                lines += ["## p.\(note.page + 1)", ""]
                lastPage = note.page
            }
            if let quote = note.quote, !quote.isEmpty {
                lines += quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
                lines.append("")
            }
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if let source = note.source { lines.append("*AI · \(source)*") }
                lines += [text, ""]
            }
        }
        return lines.joined(separator: "\n")
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
