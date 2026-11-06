import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// 앱 전체 상태. 창이 하나뿐이라 싱글턴으로 둔다.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let pdfView: PDFView = {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }()

    let ai = AIRunner()
    let notes = NotesStore()

    @Published private(set) var document: PDFDocument?
    @Published private(set) var fileURL: URL?
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var selectionText = ""
    @Published var showTerminal = true
    @Published var showSidePanel = true

    private var documentKey: String?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: pdfView)
            .sink { [weak self] _ in self?.pageDidChange() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .PDFViewSelectionChanged, object: pdfView)
            .sink { [weak self] _ in self?.selectionDidChange() }
            .store(in: &cancellables)
        // AIRunner 변경을 상위 뷰에도 전달
        ai.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        notes.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var pageCount: Int { document?.pageCount ?? 0 }
    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? "DuckViewer" }
    var hasSelection: Bool { !selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - 문서

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        guard let doc = PDFDocument(url: url) else {
            NSAlert.show("PDF를 열 수 없습니다", url.path)
            return
        }
        document = doc
        fileURL = url
        selectionText = ""
        pdfView.document = doc
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        documentKey = DocumentKey.make(for: url)
        notes.load(key: documentKey, fileURL: url)

        let saved = ReadingPosition.load(key: documentKey)
        if saved > 0, saved < doc.pageCount, let page = doc.page(at: saved) {
            pdfView.go(to: page)
        }
        pageDidChange()
    }

    func goToPage(_ index: Int) {
        guard let page = document?.page(at: max(0, min(index, pageCount - 1))) else { return }
        pdfView.go(to: page)
    }

    private func pageDidChange() {
        guard let doc = document, let page = pdfView.currentPage else { return }
        currentPageIndex = doc.index(for: page)
        ReadingPosition.save(currentPageIndex, key: documentKey)
        writeContext()
    }

    private func selectionDidChange() {
        selectionText = pdfView.currentSelection?.string ?? ""
        writeContext()
    }

    // MARK: - 텍스트 추출

    /// 0부터 시작하는 페이지 인덱스 범위의 텍스트. 페이지마다 `[p.N]` 표시를 붙여서 AI가 출처를 밝힐 수 있게 한다.
    func text(pages range: ClosedRange<Int>) -> String {
        guard let doc = document else { return "" }
        let lower = max(0, range.lowerBound)
        let upper = min(doc.pageCount - 1, range.upperBound)
        guard lower <= upper else { return "" }
        return (lower...upper).compactMap { index -> String? in
            guard let string = doc.page(at: index)?.string else { return nil }
            return "[p.\(index + 1)]\n\(string)"
        }.joined(separator: "\n\n")
    }

    // MARK: - AI

    func runAI(_ action: AIAction, scope: AIScope) {
        guard document != nil else { return }
        let body: String
        switch scope {
        case .currentPage:
            body = text(pages: currentPageIndex...currentPageIndex)
        case .selection:
            guard hasSelection else { return }
            body = "[p.\(currentPageIndex + 1) 선택 영역]\n\(selectionText)"
        case let .pages(from, to):
            body = text(pages: (from - 1)...(to - 1))
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSAlert.show("추출된 텍스트가 없습니다", "스캔본 PDF일 수 있습니다. (OCR은 아직 지원하지 않습니다)")
            return
        }
        let prompt = PromptBuilder.build(action: action, scope: scope, title: title, body: body)
        ai.run(
            command: AISettings.command,
            prompt: prompt,
            label: "\(action.label) · \(scope.label)",
            variables: ["file": fileURL?.path ?? "", "page": "\(currentPageIndex + 1)"],
            workingDirectory: fileURL?.deletingLastPathComponent()
        )
    }

    func saveAIOutputAsNote() {
        let text = ai.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.add(Note(page: currentPageIndex, text: text, quote: nil, source: ai.lastLabel))
    }

    // MARK: - 컨텍스트 파일

    private func writeContext() {
        ReadingContext.write(
            file: fileURL,
            page: currentPageIndex,
            pageCount: pageCount,
            selection: selectionText,
            pageText: document?.page(at: currentPageIndex)?.string ?? ""
        )
    }
}

extension NSAlert {
    static func show(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
