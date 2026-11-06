import AppKit
import Foundation
import PDFKit

/// `duckviewer` 명령과 실행 중인 앱을 잇는 유닉스 소켓.
/// 요청 하나에 연결 하나: 클라이언트가 JSON을 보내고 쓰기를 닫으면, 앱이 JSON으로 답하고 닫는다.
enum ControlPaths {
    static var socket: String {
        if let path = ProcessInfo.processInfo.environment["DUCKVIEWER_SOCKET"] { return path }
        #if DEBUG
        // 테스트 앱은 사용자가 쓰는 앱과 다른 소켓을 쓴다. (소켓 경로는 104바이트 제한이 있어 짧은 임시 폴더에 둔다)
        if UserDefaults.standard.string(forKey: "DVDataDir") != nil {
            return (NSTemporaryDirectory() as NSString).appendingPathComponent("duckviewer-test.sock")
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".duckviewer/control.sock").path
    }

    /// Claude가 `duckviewer`라는 이름으로 부를 수 있도록 실행 파일 링크를 두는 폴더
    static var binDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".duckviewer/bin", isDirectory: true)
    }

    /// 앱 실행 파일을 가리키는 `~/.duckviewer/bin/duckviewer` 링크를 만든다.
    static func installCommandLink() {
        guard let executable = Bundle.main.executablePath else { return }
        let link = binDirectory.appendingPathComponent("duckviewer")
        try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == executable { return }
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: executable)
    }
}

final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()
    private var listener: Int32 = -1

    func start(handler: @escaping @MainActor ([String: Any]) -> [String: Any]) {
        let path = ControlPaths.socket
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = Self.address(path) else { return }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            NSLog("DuckViewer: 제어 소켓을 열지 못했습니다: \(path)")
            close(fd)
            return
        }
        chmod(path, 0o600)
        listener = fd
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                let request = Self.readAll(client)
                var response: [String: Any] = ["ok": false, "error": "잘못된 요청입니다"]
                if let json = try? JSONSerialization.jsonObject(with: request) as? [String: Any] {
                    response = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(json) } }
                }
                let data = (try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
                data.withUnsafeBytes { _ = write(client, $0.baseAddress, data.count) }
                close(client)
            }
        }
        thread.name = "DuckViewer control socket"
        thread.start()
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return address
    }

    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// `duckviewer <명령> [--옵션 값 ...]` 명령줄 모드
enum ControlCLI {
    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first, command != "help", command != "--help" else {
            print("""
            사용법: duckviewer <명령> [--옵션 값 ...]
              state | notes [--page N | --pages A-B | --all] | text --page N
              highlight --page N --text 글자 [--color 색] [--note 설명]
              underline --page N --text 글자 --note 설명
              page-note --page N --note 내용
              edit --id ID [--note 설명] [--color 색] | delete --id ID [--id ID ...] | goto --page N
            """)
            return 0
        }
        var options: [String: [String]] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                fputs("알 수 없는 인자: \(key)\n", stderr)
                return 2
            }
            let name = String(key.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                options[name, default: []].append(arguments[index + 1])
                index += 2
            } else {
                options[name, default: []].append("true")
                index += 1
            }
        }

        var request: [String: Any] = ["command": command, "options": options]
        if let doc = ProcessInfo.processInfo.environment["DUCKVIEWER_DOC"] { request["doc"] = doc }
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return 2 }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = ControlServer.address(ControlPaths.socket) else { return 1 }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            fputs("DuckViewer가 실행 중이 아닙니다 (\(ControlPaths.socket))\n", stderr)
            return 1
        }
        body.withUnsafeBytes { _ = write(fd, $0.baseAddress, body.count) }
        shutdown(fd, SHUT_WR)
        let response = ControlServer.readAll(fd)
        close(fd)
        FileHandle.standardOutput.write(response)
        print()
        let ok = ((try? JSONSerialization.jsonObject(with: response)) as? [String: Any])?["ok"] as? Bool ?? false
        return ok ? 0 : 1
    }
}

// MARK: - 명령 처리

extension AppState {
    func handleControl(_ request: [String: Any]) -> [String: Any] {
        let command = request["command"] as? String ?? ""
        let options = request["options"] as? [String: [String]] ?? [:]
        func value(_ key: String) -> String? { options[key]?.last }
        func failure(_ message: String) -> [String: Any] { ["ok": false, "error": message] }

        guard let doc = document else { return failure("열린 문서가 없습니다") }
        // Claude가 일하는 사이에 사용자가 다른 문서를 열었으면 엉뚱한 문서를 바꾸지 않는다.
        if let expected = request["doc"] as? String, expected != documentKeyValue {
            return failure("Claude가 작업하던 문서가 아닌 다른 문서가 열려 있습니다. 바꾸지 않았습니다.")
        }
        func page() -> Int? {
            guard let page = value("page").flatMap(Int.init), (1...doc.pageCount).contains(page) else { return nil }
            return page - 1
        }

        switch command {
        case "state":
            return [
                "ok": true,
                "file": fileURL?.path ?? "",
                "page": currentPageIndex + 1,
                "pageCount": doc.pageCount,
                "selection": selectionText,
                "notes": notes.notes.count,
            ]

        case "notes":
            var range: ClosedRange<Int>?
            if let pages = value("pages") {
                let parts = pages.split(separator: "-").compactMap { Int($0) }
                if parts.count == 2 { range = (parts[0] - 1)...(parts[1] - 1) }
            } else if let page = page() {
                range = page...page
            } else if value("all") == nil {
                range = currentPageIndex...currentPageIndex
            }
            let numbers = notes.notes.isEmpty ? [:] : notes.footnoteNumbers
            let list = notes.notes
                .filter { range?.contains($0.markerPage) ?? true }
                .sorted { ($0.markerPage, numbers[$0.id] ?? 99, $0.createdAt) < ($1.markerPage, numbers[$1.id] ?? 99, $1.createdAt) }
                .map { note -> [String: Any] in
                    var item: [String: Any] = [
                        "id": Self.shortID(note.id),
                        "page": note.markerPage + 1,
                        "kind": "\(note.kind)",
                        "text": note.text,
                    ]
                    if let number = numbers[note.id] { item["footnote"] = number }
                    if let quote = note.quote { item["quote"] = quote }
                    if let color = note.color { item["color"] = color.rawValue }
                    if let source = note.source { item["source"] = source }
                    return item
                }
            return ["ok": true, "count": list.count, "notes": list]

        case "text":
            guard let page = page() else { return failure("--page에 1부터 \(doc.pageCount) 사이의 쪽 번호를 주세요") }
            return ["ok": true, "page": page + 1, "text": doc.page(at: page)?.string ?? ""]

        case "highlight", "underline":
            guard let page = page() else { return failure("--page에 1부터 \(doc.pageCount) 사이의 쪽 번호를 주세요") }
            guard let text = value("text"), !text.isEmpty else { return failure("--text가 필요합니다") }
            let style: NoteStyle = command == "underline" ? .underline : .highlight
            let note = value("note") ?? ""
            if style == .underline, note.isEmpty { return failure("밑줄에는 --note 설명이 필요합니다") }
            guard let selection = findText(text, onPage: page) else {
                return failure("\(page + 1)쪽에서 글자를 찾지 못했습니다. `duckviewer text --page \(page + 1)`로 정확한 글자를 확인하고 더 짧게 다시 시도하세요.")
            }
            let regions = regions(of: selection)
            let color = value("color").flatMap(NoteColor.init(rawValue:)) ?? (style == .underline ? .blue : .yellow)
            let created = Note(
                page: regions.first?.page ?? page, text: note, quote: selection.string ?? text, source: nil,
                highlights: regions, color: color, style: style
            )
            addFromControl(created, summary: "\(page + 1)쪽 \(style == .underline ? "밑줄" : "형광펜"): “\(text.prefix(30))”")
            return ["ok": true, "id": Self.shortID(created.id), "footnote": notes.footnoteNumbers[created.id] as Any]

        case "page-note":
            guard let page = page() else { return failure("--page에 1부터 \(doc.pageCount) 사이의 쪽 번호를 주세요") }
            guard let text = value("note"), !text.isEmpty else { return failure("--note가 필요합니다") }
            let created = Note(page: page, text: text, quote: nil, source: "Claude")
            addFromControl(created, summary: "\(page + 1)쪽 페이지 메모")
            return ["ok": true, "id": Self.shortID(created.id), "footnote": notes.footnoteNumbers[created.id] as Any]

        case "edit":
            guard let id = value("id"), let original = note(withShortID: id) else { return failure("id에 맞는 메모가 없습니다") }
            var changed = original
            if let text = value("note") { changed.text = text }
            if let color = value("color") {
                guard let parsed = NoteColor(rawValue: color) else { return failure("색은 yellow, green, blue, pink 중 하나입니다") }
                changed.color = parsed
            }
            updateNote(changed)
            recordControlChange("\(changed.markerPage + 1)쪽 메모 수정") { $0.edited.append(original) }
            return ["ok": true]

        case "delete":
            let ids = options["id"] ?? []
            guard !ids.isEmpty else { return failure("--id가 필요합니다") }
            var deleted: [String] = []
            var missing: [String] = []
            for id in ids {
                guard let note = note(withShortID: id) else {
                    missing.append(id)
                    continue
                }
                removeNote(note)
                recordControlChange(nil) { $0.deleted.append(note) }
                deleted.append(id)
            }
            if !deleted.isEmpty { recordControlChange("메모 \(deleted.count)개 삭제", { _ in }) }
            return ["ok": missing.isEmpty, "deleted": deleted, "missing": missing]

        case "goto":
            guard let page = page() else { return failure("--page에 1부터 \(doc.pageCount) 사이의 쪽 번호를 주세요") }
            goToPage(page)
            return ["ok": true]

        default:
            return failure("알 수 없는 명령: \(command). `duckviewer help`를 보세요.")
        }
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    private func note(withShortID id: String) -> Note? {
        let key = id.lowercased()
        return notes.notes.first { Self.shortID($0.id) == key || $0.id.uuidString.lowercased() == key }
    }

    /// 그 쪽에서 글자를 찾는다. OCR 문서는 줄바꿈과 띄어쓰기가 달라서 몇 가지 형태로 시도한다.
    private func findText(_ text: String, onPage page: Int) -> PDFSelection? {
        guard let doc = document else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for candidate in [text, collapsed, text.replacingOccurrences(of: "\n", with: "")] where !candidate.isEmpty {
            let match = doc.findString(candidate, withOptions: [.caseInsensitive])
                .first { $0.pages.first.map(doc.index(for:)) == page }
            if let match { return match }
        }
        return nil
    }
}
