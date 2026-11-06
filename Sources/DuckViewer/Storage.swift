import CoreGraphics
import CryptoKit
import Foundation

enum AppPaths {
    static var support: URL {
        #if DEBUG
        // 테스트가 실제 메모와 대화 기록을 건드리지 않도록 다른 폴더를 쓸 수 있다: -DVDataDir <경로>
        if let dir = UserDefaults.standard.string(forKey: "DVDataDir") {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DuckViewer", isDirectory: true)
    }

    static var notes: URL { support.appendingPathComponent("notes", isDirectory: true) }
    static var chats: URL { support.appendingPathComponent("chats", isDirectory: true) }

    /// 터미널 속 AI 에이전트가 읽는 현재 읽기 상태
    static var context: URL {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "DVDataDir") != nil {
            return support.appendingPathComponent("context.json")
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
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
        /// 바깥 터미널에서 `claude --resume <id>`로 같은 대화를 이어갈 수 있다.
        let claudeSession: String?
        let updatedAt: Date
    }

    static func write(file: URL?, page: Int, pageCount: Int, selection: String, pageText: String, claudeSession: String?) {
        let payload = Payload(
            file: file?.path,
            page: page + 1,
            pageCount: pageCount,
            selection: selection,
            pageText: pageText,
            claudeSession: claudeSession,
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
    // v0.4: 밑줄 각주와 영역 메모. nil이면 하이라이트
    var style: NoteStyle?

    var isHighlight: Bool { !(highlights?.isEmpty ?? true) }

    var kind: NoteKind {
        guard isHighlight else { return .page }
        switch style ?? .highlight {
        case .highlight: return .highlight
        case .underline: return .underline
        case .area: return .area
        }
    }

    /// 페이지 위에 [n] 각주로 표시하는 메모. 설명이 없는 형광펜은 번호를 달지 않는다.
    var isFootnote: Bool {
        kind != .highlight || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 각주 번호가 붙는 페이지. 여러 페이지에 걸친 선택은 마지막 페이지 끝에 붙는다.
    var markerPage: Int { highlights?.last?.page ?? page }

    /// 각주를 붙일 PDF 좌표 (마지막 줄 오른쪽 위). 페이지 메모는 nil (페이지 하단 가운데)
    var markerAnchor: CGPoint? {
        guard let rect = highlights?.last?.rects.last, rect.count == 4 else { return nil }
        return CGPoint(x: rect[0] + rect[2], y: rect[1] + rect[3])
    }
}

enum NoteStyle: String, Codable {
    case highlight, underline, area
}

enum NoteKind {
    /// 위치 없이 페이지 전체에 단 메모 (페이지 하단 가운데)
    case page
    case highlight, underline, area
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

    /// 페이지마다 1부터 매기는 각주 번호. 위에서 아래, 왼쪽에서 오른쪽 순서이고 페이지 메모는 맨 뒤에 온다.
    var footnoteNumbers: [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        let byPage = Dictionary(grouping: notes.filter(\.isFootnote), by: \.markerPage)
        for (_, pageNotes) in byPage {
            let ordered = pageNotes.sorted { a, b in
                switch (a.markerAnchor, b.markerAnchor) {
                case let (pa?, pb?):
                    // PDF 좌표는 아래가 0이라 y가 클수록 위쪽이다. 같은 줄은 왼쪽부터
                    if abs(pa.y - pb.y) > 4 { return pa.y > pb.y }
                    return pa.x < pb.x
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a.createdAt < b.createdAt
                }
            }
            for (index, note) in ordered.enumerated() { numbers[note.id] = index + 1 }
        }
        return numbers
    }

    /// Obsidian 등에서 바로 쓸 수 있는 Markdown
    func markdown(title: String) -> String {
        var lines = ["# \(title)", ""]
        if let fileURL { lines += ["- 파일: `\(fileURL.path)`", "- 내보낸 날짜: \(Date().formatted(date: .abbreviated, time: .shortened))", ""] }
        var lastPage = -1
        let numbers = footnoteNumbers
        let ordered = notes.sorted {
            ($0.markerPage, numbers[$0.id] ?? 0, $0.createdAt) < ($1.markerPage, numbers[$1.id] ?? 0, $1.createdAt)
        }
        for note in ordered {
            if note.markerPage != lastPage {
                lines += ["## p.\(note.markerPage + 1)", ""]
                lastPage = note.markerPage
            }
            if let number = numbers[note.id] { lines.append("**[\(number)]**") }
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

// MARK: - Claude 대화

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    enum Status: String, Codable { case running, done, failed, cancelled }

    var id = UUID()
    var role: Role
    var text: String
    /// 사용자 메시지: 템플릿 이름 (자유 질문이면 nil)
    var title: String?
    var icon: String?
    var scopeLabel: String?
    /// 0부터 시작하는 페이지 인덱스. 범위 칩을 누르면 이동하고, 메모로 저장할 때 쓴다.
    var anchorPage: Int?
    var createdAt = Date()
    // 아래는 Claude 응답에만 쓴다.
    var status: Status?
    var activity: String?
    var error: String?
    var costUSD: Double?
    var durationMs: Int?
    /// "메모로 저장"으로 만든 메모. 같은 답을 여러 번 저장하지 않도록 기억한다.
    var savedNoteID: UUID?

    var isRunning: Bool { status == .running }
}

/// 문서 하나에 Claude 세션 하나. 세션은 시작한 폴더(cwd)에 묶이므로 함께 저장한다.
struct ChatLog: Codable {
    var sessionID: String?
    var workingDirectory: String?
    var messages: [ChatMessage] = []
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var log = ChatLog()
    private var key: String?

    func load(key: String?) {
        self.key = key
        log = ChatLog()
        guard let path = storagePath, let data = try? Data(contentsOf: path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            log = try decoder.decode(ChatLog.self, from: data)
            // 앱이 응답 중에 꺼졌던 메시지
            for index in log.messages.indices where log.messages[index].status == .running {
                log.messages[index].status = .cancelled
                log.messages[index].activity = nil
            }
        } catch {
            let backup = path.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: path, to: backup)
            NSLog("DuckViewer: 대화 파일을 읽지 못해 \(backup.path) 로 옮겼습니다: \(error)")
        }
    }

    func startSession(_ id: String, in directory: URL) {
        log.sessionID = id
        log.workingDirectory = directory.path
        save()
    }

    func append(_ message: ChatMessage) {
        log.messages.append(message)
        save()
    }

    /// 스트리밍 중에는 자주 바뀌므로 `persist`가 true일 때만 디스크에 쓴다.
    func update(_ id: UUID, persist: Bool = false, _ change: (inout ChatMessage) -> Void) {
        guard let index = log.messages.firstIndex(where: { $0.id == id }) else { return }
        change(&log.messages[index])
        if persist { save() }
    }

    func remove(_ id: UUID) {
        log.messages.removeAll { $0.id == id }
        save()
    }

    /// `keepingMessages`면 화면의 기록은 두고 세션만 새로 시작한다.
    func reset(keepingMessages: Bool = false) {
        if keepingMessages {
            log.sessionID = nil
            log.workingDirectory = nil
        } else {
            log = ChatLog()
        }
        save()
    }

    private var storagePath: URL? {
        key.map { AppPaths.chats.appendingPathComponent("\($0).json") }
    }

    private func save() {
        guard let path = storagePath else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(log) else { return }
        AppPaths.ensureDirectory(AppPaths.chats)
        try? data.write(to: path, options: .atomic)
    }
}
