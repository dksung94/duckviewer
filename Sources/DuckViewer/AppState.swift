import AppKit
import Combine
import CoreImage
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarTab: String, CaseIterable, Identifiable {
    case thumbnails, outline, notes, search
    var id: Self { self }

    var label: String {
        switch self {
        case .thumbnails: "썸네일"
        case .outline: "목차"
        case .notes: "메모"
        case .search: "검색"
        }
    }

    var icon: String {
        switch self {
        case .thumbnails: "square.grid.2x2"
        case .outline: "list.bullet.indent"
        case .notes: "highlighter"
        case .search: "magnifyingglass"
        }
    }
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case normal, sepia, dark
    var id: Self { self }

    var label: String {
        switch self {
        case .normal: "기본"
        case .sepia: "세피아"
        case .dark: "다크"
        }
    }
}

enum PageLayout: String, CaseIterable, Identifiable {
    case continuous, single, twoUpContinuous, twoUp
    var id: Self { self }

    var label: String {
        switch self {
        case .continuous: "연속 스크롤"
        case .single: "한 페이지씩"
        case .twoUpContinuous: "두 페이지 연속"
        case .twoUp: "두 페이지씩"
        }
    }

    var mode: PDFDisplayMode {
        switch self {
        case .continuous: .singlePageContinuous
        case .single: .singlePage
        case .twoUpContinuous: .twoUpContinuous
        case .twoUp: .twoUp
        }
    }
}

/// AI 패널의 범위 선택
enum AIScopeKind: String, CaseIterable, Identifiable {
    case page, selection, range
    var id: Self { self }

    var label: String {
        switch self {
        case .page: "현재 페이지"
        case .selection: "선택 영역"
        case .range: "페이지 범위"
        }
    }
}

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    /// 0부터 시작하는 페이지 인덱스
    let page: Int
    let depth: Int
    var children: [OutlineItem]?
}

struct SearchHit: Identifiable {
    let id = UUID()
    let page: Int
    let snippet: AttributedString
    let selection: PDFSelection
}

/// 메모 작성 시트에 넘기는 초안
struct NoteDraft: Identifiable {
    let id = UUID()
    var page: Int
    var quote: String?
    var highlights: [HighlightRegion]?
    var text = ""
    var color: NoteColor = .yellow
}

/// 앱 전체 상태. 창이 하나뿐이라 싱글턴으로 둔다.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let pdfView: DuckPDFView = {
        let view = DuckPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }()

    let claude = ClaudeRunner()
    let notes = NotesStore()
    let chats = ChatStore()

    // 문서
    @Published private(set) var document: PDFDocument?
    @Published private(set) var fileURL: URL?
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var outline: [OutlineItem] = []

    // 선택
    @Published private(set) var selectionText = ""
    /// PDFView 좌표(위쪽이 0)의 선택 영역. 드래그 중이거나 화면 밖이면 nil
    @Published private(set) var selectionRect: CGRect?

    // 레이아웃
    @Published var sidebarTab: SidebarTab = .thumbnails
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var showInspector = true
    @Published var theme: ReadingTheme = .normal { didSet { applyTheme() } }
    @Published var pageLayout: PageLayout = .continuous { didSet { pdfView.displayMode = pageLayout.mode } }

    // 검색
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [SearchHit] = []
    @Published private(set) var searchedQuery = ""

    // AI
    @Published private(set) var templates = PromptTemplates.load()
    @Published var aiScopeKind: AIScopeKind = .page
    @Published var rangeFrom = 1
    @Published var rangeTo = 1
    /// 값이 바뀌면 AI 질문 입력창에 포커스를 준다.
    @Published var composerFocusRequest = 0

    // 메모
    @Published var noteDraft: NoteDraft?

    private var documentKey: String?
    private var isLoadingDocument = false
    private var isMouseDown = false
    private var highlightAnnotations: [UUID: [PDFAnnotation]] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        pdfView.state = self
        let center = NotificationCenter.default
        center.publisher(for: .PDFViewPageChanged, object: pdfView)
            .sink { [weak self] _ in self?.pageDidChange() }
            .store(in: &cancellables)
        center.publisher(for: .PDFViewSelectionChanged, object: pdfView)
            .sink { [weak self] _ in self?.selectionDidChange() }
            .store(in: &cancellables)
        center.publisher(for: .PDFViewScaleChanged, object: pdfView)
            .sink { [weak self] _ in self?.updateSelectionRect() }
            .store(in: &cancellables)
        center.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let latest = PromptTemplates.load()
                if latest != self.templates { self.templates = latest }
            }
            .store(in: &cancellables)
        // 하위 객체 변경을 뷰에 전달
        claude.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        chats.objectWillChange
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
        // 문서를 바꾸는 동안 PDFView가 보내는 페이지 변경 알림이 읽은 위치를 덮어쓰지 않게 막는다.
        let key = DocumentKey.make(for: url)
        let saved = ReadingPosition.load(key: key)
        isLoadingDocument = true
        documentKey = key
        document = doc
        fileURL = url
        selectionText = ""
        selectionRect = nil
        clearSearch()
        highlightAnnotations = [:]
        pdfView.document = doc
        outline = Self.buildOutline(doc.outlineRoot)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentFiles.add(url)
        notes.load(key: key, fileURL: url)
        notes.notes.forEach(addHighlightAnnotations)
        claude.cancel()
        chats.load(key: key)

        // 레이아웃이 끝난 다음에 이동해야 적용된다.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.document === doc else { return }
            // 이전 문서의 스크롤 위치가 남지 않도록 항상 목표 페이지로 이동한다.
            let target = (0..<doc.pageCount).contains(saved) ? saved : 0
            if let page = doc.page(at: target) { self.pdfView.go(to: page) }
            self.isLoadingDocument = false
            self.pageDidChange()
            self.rangeFrom = self.currentPageIndex + 1
            self.rangeTo = self.rangeFrom
            #if DEBUG
            self.runDebugHooks()
            #endif
        }
    }

    func goToPage(_ index: Int) {
        guard let page = document?.page(at: max(0, min(index, pageCount - 1))) else { return }
        pdfView.go(to: page)
    }

    private func pageDidChange() {
        guard !isLoadingDocument, let doc = document, let page = pdfView.currentPage else { return }
        currentPageIndex = doc.index(for: page)
        ReadingPosition.save(currentPageIndex, key: documentKey)
        writeContext()
    }

    // MARK: - 선택

    private func selectionDidChange() {
        selectionText = pdfView.currentSelection?.string ?? ""
        if hasSelection, aiScopeKind == .page { aiScopeKind = .selection }
        if !hasSelection, aiScopeKind == .selection { aiScopeKind = .page }
        updateSelectionRect()
        writeContext()
    }

    func mouseDown() {
        isMouseDown = true
        selectionRect = nil
    }

    func mouseUp() {
        isMouseDown = false
        updateSelectionRect()
    }

    func updateSelectionRect() {
        guard !isMouseDown, hasSelection, let selection = pdfView.currentSelection,
              let page = selection.pages.first
        else {
            selectionRect = nil
            return
        }
        var rect = pdfView.convert(selection.bounds(for: page), from: page)
        if !pdfView.isFlipped {
            rect.origin.y = pdfView.bounds.height - rect.maxY
        }
        selectionRect = rect.intersects(pdfView.bounds) ? rect : nil
    }

    func clearSelection() {
        pdfView.clearSelection()
    }

    // MARK: - 화면

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func zoomToFit() { pdfView.autoScales = true }

    private func applyTheme() {
        pdfView.wantsLayer = true
        pdfView.layerUsesCoreImageFilters = true
        switch theme {
        case .normal:
            pdfView.contentFilters = []
            pdfView.backgroundColor = .underPageBackgroundColor
        case .sepia:
            let sepia = CIFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.35])
            pdfView.contentFilters = [sepia].compactMap { $0 }
            pdfView.backgroundColor = NSColor(calibratedRed: 0.42, green: 0.38, blue: 0.32, alpha: 1)
        case .dark:
            // 반전한 뒤 색상을 180도 돌려서 하이라이트 색이 원래 계열로 보이게 한다.
            let invert = CIFilter(name: "CIColorInvert")
            let hue = CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
            pdfView.contentFilters = [invert, hue].compactMap { $0 }
            pdfView.backgroundColor = NSColor(white: 0.85, alpha: 1) // 반전되면 어두운 회색
        }
    }

    // MARK: - 목차

    private static func buildOutline(_ root: PDFOutline?, depth: Int = 0) -> [OutlineItem] {
        guard let root, let document = root.document else { return [] }
        return (0..<root.numberOfChildren).compactMap { index in
            guard let child = root.child(at: index) else { return nil }
            let page = child.destination?.page.map { document.index(for: $0) } ?? 0
            let children = buildOutline(child, depth: depth + 1)
            return OutlineItem(
                title: child.label ?? "(제목 없음)",
                page: page,
                depth: depth,
                children: children.isEmpty ? nil : children
            )
        }
    }

    /// 목차 항목이 차지하는 페이지 범위 (1부터). 다음 같은 단계 이상 항목의 앞 페이지까지다.
    func pageRange(of item: OutlineItem) -> ClosedRange<Int> {
        var flat: [OutlineItem] = []
        func walk(_ items: [OutlineItem]) {
            for item in items {
                flat.append(item)
                walk(item.children ?? [])
            }
        }
        walk(outline)
        let start = item.page + 1
        guard let index = flat.firstIndex(where: { $0.id == item.id }) else { return start...start }
        let next = flat[(index + 1)...].first { $0.depth <= item.depth }
        let end = next.map { max(start, $0.page) } ?? pageCount
        return start...max(start, end)
    }

    // MARK: - 검색

    func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = document, !query.isEmpty else {
            clearSearch()
            return
        }
        let selections = doc.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        searchResults = selections.prefix(500).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            return SearchHit(page: doc.index(for: page), snippet: Self.snippet(for: selection, query: query), selection: selection)
        }
        searchedQuery = query
        pdfView.highlightedSelections = selections
        sidebarTab = .search
        sidebarVisibility = .all
    }

    func clearSearch() {
        searchResults = []
        searchedQuery = ""
        pdfView.highlightedSelections = nil
    }

    func show(_ hit: SearchHit) {
        pdfView.setCurrentSelection(hit.selection, animate: true)
        pdfView.go(to: hit.selection)
    }

    private static func snippet(for selection: PDFSelection, query: String) -> AttributedString {
        guard let line = selection.copy() as? PDFSelection else { return AttributedString(query) }
        line.extendForLineBoundaries()
        let text = (line.string ?? query)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var snippet = AttributedString(text)
        if let range = snippet.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            snippet[range].font = .body.bold()
            snippet[range].foregroundColor = .accentColor
        }
        return snippet
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

    /// AI 패널에서 고른 범위
    var panelScope: AIScope {
        switch aiScopeKind {
        case .page: .currentPage
        case .selection: .selection
        case .range: .pages(min(rangeFrom, rangeTo), max(rangeFrom, rangeTo))
        }
    }

    var canRunPanelScope: Bool {
        guard document != nil else { return false }
        switch aiScopeKind {
        case .page: return true
        case .selection: return hasSelection
        case .range:
            let pages = 1...max(1, pageCount)
            return pages.contains(rangeFrom) && pages.contains(rangeTo)
        }
    }

    var messages: [ChatMessage] { chats.log.messages }
    var hasSession: Bool { chats.log.sessionID != nil }

    /// 범위에 맞는 컨텍스트를 붙여 Claude 세션에 메시지를 보낸다.
    func runAI(_ request: AIRequest, scope: AIScope) {
        guard document != nil, let fileURL, !claude.isRunning else { return }
        let anchor: Int
        let scopeLabel: String
        var context: String?
        var pages: ClosedRange<Int>?
        switch scope {
        case .currentPage:
            anchor = currentPageIndex
            scopeLabel = "p.\(currentPageIndex + 1)"
            pages = currentPageIndex...currentPageIndex
        case .selection:
            guard hasSelection else { return }
            anchor = currentPageIndex
            scopeLabel = "p.\(currentPageIndex + 1) 선택 영역"
            context = selectionText
        case let .pages(from, to), let .chapter(_, from, to):
            anchor = from - 1
            scopeLabel = scope.label
            pages = (from - 1)...(to - 1)
        }

        // 텍스트가 너무 길거나 없으면(스캔본) Claude가 PDF를 직접 읽게 한다.
        var readHint: String?
        if let pages {
            let extracted = text(pages: pages)
            let label = pages.count == 1 ? "p.\(pages.lowerBound + 1)" : "p.\(pages.lowerBound + 1)–\(pages.upperBound + 1)"
            if extracted.filter({ !$0.isWhitespace }).count < 20 * pages.count {
                readHint = "\(label)는 텍스트가 거의 추출되지 않았다 (스캔본일 수 있음). Read 도구로 PDF의 해당 페이지를 직접 읽어라."
            } else if extracted.count > 150_000 {
                readHint = "\(label)는 너무 길어 텍스트를 붙이지 않았다. 필요한 부분을 Read 도구로 나눠 읽어라."
            } else {
                context = extracted
            }
        }

        let user = ChatMessage(
            role: .user,
            text: {
                if case let .ask(question) = request { return question }
                return ""
            }(),
            title: {
                if case let .template(template) = request { return template.name }
                return nil
            }(),
            icon: request.icon,
            scopeLabel: scopeLabel,
            anchorPage: anchor
        )
        chats.append(user)
        showInspector = true

        let prompt = PromptBuilder.message(
            request: request,
            scopeLabel: scopeLabel,
            currentPage: currentPageIndex + 1,
            pageCount: pageCount,
            context: context,
            readHint: readHint
        )
        send(prompt, anchor: anchor, scopeLabel: scopeLabel, fileURL: fileURL, retryWithNewSession: true)
    }

    private func send(_ prompt: String, anchor: Int, scopeLabel: String, fileURL: URL, retryWithNewSession: Bool) {
        let reply = ChatMessage(role: .assistant, text: "", scopeLabel: scopeLabel, anchorPage: anchor, status: .running)
        chats.append(reply)

        // 세션은 처음 시작한 폴더에서만 이어갈 수 있다. 폴더가 사라졌으면 새로 시작한다.
        let pdfDirectory = fileURL.deletingLastPathComponent()
        var resume = false
        var sessionID = UUID().uuidString.lowercased()
        var directory = pdfDirectory
        if let existing = chats.log.sessionID, let path = chats.log.workingDirectory,
           FileManager.default.fileExists(atPath: path) {
            resume = true
            sessionID = existing
            directory = URL(fileURLWithPath: path)
        } else {
            chats.startSession(sessionID, in: pdfDirectory)
            writeContext()
        }

        let request = ClaudeRunner.Request(
            prompt: prompt,
            sessionID: sessionID,
            resume: resume,
            systemPrompt: PromptBuilder.system(
                title: title, path: fileURL.path, pageCount: pageCount, permission: ClaudeSettings.permission
            ),
            model: ClaudeSettings.model,
            permission: ClaudeSettings.permission,
            workingDirectory: directory
        )
        let id = reply.id
        claude.run(request) { [weak self] event in
            guard let self else { return }
            switch event {
            case let .text(text):
                self.chats.update(id) { $0.text = text }
            case let .activity(activity):
                self.chats.update(id) { $0.activity = activity }
            case let .finished(outcome):
                // Claude 쪽 세션 파일이 사라졌으면 새 세션으로 한 번 다시 보낸다.
                if resume, retryWithNewSession, !outcome.success, !outcome.cancelled,
                   (outcome.error ?? "").localizedCaseInsensitiveContains("no conversation found") {
                    self.chats.remove(id)
                    self.chats.reset(keepingMessages: true)
                    self.send(prompt, anchor: anchor, scopeLabel: scopeLabel, fileURL: fileURL, retryWithNewSession: false)
                    return
                }
                self.chats.update(id, persist: true) {
                    $0.activity = nil
                    $0.costUSD = outcome.costUSD
                    $0.durationMs = outcome.durationMs
                    if outcome.cancelled {
                        $0.status = .cancelled
                    } else if outcome.success {
                        $0.status = .done
                    } else {
                        $0.status = .failed
                        $0.error = outcome.error
                    }
                }
            }
        }
    }

    /// 메뉴 단축키용: 템플릿 순서로 실행
    func runTemplate(at index: Int, scope: AIScope) {
        guard templates.indices.contains(index) else { return }
        runAI(.template(templates[index]), scope: scope)
    }

    /// 대화 기록과 세션을 버리고 새로 시작한다.
    func newConversation() {
        guard !messages.isEmpty || hasSession else { return }
        let alert = NSAlert()
        alert.messageText = "새 대화를 시작할까요?"
        alert.informativeText = "이 문서의 대화 기록이 지워집니다. Claude 쪽 세션은 남아 있어서 터미널에서 이어하기 명령으로 열 수 있습니다."
        alert.addButton(withTitle: "새 대화")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        claude.cancel()
        chats.reset()
        writeContext()
    }

    /// 바깥 터미널에서 같은 대화를 이어가는 명령
    var resumeCommand: String? {
        guard let id = chats.log.sessionID, let directory = chats.log.workingDirectory else { return nil }
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && claude --resume \(id)"
    }

    func copyResumeCommand() {
        guard let command = resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func saveAsNote(_ message: ChatMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let request = messages.last { $0.role == .user && $0.createdAt <= message.createdAt }
        let source = [request?.title ?? request?.text.prefix(30).description, message.scopeLabel]
            .compactMap { $0 }.joined(separator: " · ")
        notes.add(Note(page: message.anchorPage ?? currentPageIndex, text: text, quote: nil, source: "Claude · \(source)"))
    }

    // MARK: - 메모와 하이라이트

    private func selectionRegions() -> [HighlightRegion] {
        guard let selection = pdfView.currentSelection, let doc = document else { return [] }
        var byPage: [Int: [[Double]]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                byPage[doc.index(for: page), default: []].append([bounds.minX, bounds.minY, bounds.width, bounds.height])
            }
        }
        return byPage.keys.sorted().map { HighlightRegion(page: $0, rects: byPage[$0]!) }
    }

    func highlightSelection(color: NoteColor = .yellow) {
        guard hasSelection else { return }
        let regions = selectionRegions()
        let note = Note(
            page: regions.first?.page ?? currentPageIndex,
            text: "",
            quote: selectionText,
            source: nil,
            highlights: regions,
            color: color
        )
        notes.add(note)
        addHighlightAnnotations(note)
        clearSelection()
    }

    /// 선택 영역이 있으면 하이라이트 + 인용, 없으면 현재 페이지 메모
    func beginNote() {
        guard document != nil else { return }
        if hasSelection {
            let regions = selectionRegions()
            noteDraft = NoteDraft(page: regions.first?.page ?? currentPageIndex, quote: selectionText, highlights: regions)
        } else {
            noteDraft = NoteDraft(page: currentPageIndex)
        }
    }

    func commit(_ draft: NoteDraft) {
        let note = Note(
            page: draft.page,
            text: draft.text,
            quote: draft.quote,
            source: nil,
            highlights: draft.highlights,
            color: draft.highlights == nil ? nil : draft.color
        )
        notes.add(note)
        addHighlightAnnotations(note)
        noteDraft = nil
        clearSelection()
    }

    func updateNote(_ note: Note) {
        notes.update(note)
        removeHighlightAnnotations(note.id)
        addHighlightAnnotations(note)
    }

    func removeNote(_ note: Note) {
        notes.remove(note)
        removeHighlightAnnotations(note.id)
    }

    func show(_ note: Note) {
        guard let doc = document, let region = note.highlights?.first, let rect = region.rects.first,
              let page = doc.page(at: region.page)
        else {
            goToPage(note.page)
            return
        }
        let bounds = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        pdfView.go(to: bounds.insetBy(dx: 0, dy: -80), on: page)
    }

    private func addHighlightAnnotations(_ note: Note) {
        guard let doc = document, let regions = note.highlights else { return }
        let color = (note.color ?? .yellow).nsColor.withAlphaComponent(0.45)
        var created: [PDFAnnotation] = []
        for region in regions {
            guard let page = doc.page(at: region.page) else { continue }
            for rect in region.rects where rect.count == 4 {
                let bounds = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = color
                page.addAnnotation(annotation)
                created.append(annotation)
            }
        }
        highlightAnnotations[note.id] = created
    }

    private func removeHighlightAnnotations(_ id: UUID) {
        for annotation in highlightAnnotations[id] ?? [] {
            annotation.page?.removeAnnotation(annotation)
        }
        highlightAnnotations[id] = nil
    }

    func exportNotesMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(title) 메모.md"
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try notes.markdown(title: title).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert.show("내보내기 실패", error.localizedDescription)
        }
    }

    // MARK: - 컨텍스트 파일

    private func writeContext() {
        ReadingContext.write(
            file: fileURL,
            page: currentPageIndex,
            pageCount: pageCount,
            selection: selectionText,
            pageText: document?.page(at: currentPageIndex)?.string ?? "",
            claudeSession: chats.log.sessionID
        )
    }
}

#if DEBUG
/// 클릭 없이 UI를 확인하기 위한 디버그 빌드 전용 훅. 실행 인자로 넘긴다.
/// 예: `DuckViewer a.pdf -DVSelect "2:waterfowl" -DVHighlight YES -DVSidebar notes`
extension AppState {
    func runDebugHooks() {
        let defaults = UserDefaults.standard
        if let tab = defaults.string(forKey: "DVSidebar").flatMap(SidebarTab.init(rawValue:)) { sidebarTab = tab }
        if let theme = defaults.string(forKey: "DVTheme").flatMap(ReadingTheme.init(rawValue:)) { self.theme = theme }
        if let query = defaults.string(forKey: "DVSearch") {
            searchQuery = query
            search()
        }
        if defaults.bool(forKey: "DVFakeAI") {
            chats.append(ChatMessage(role: .user, text: "", title: "요약", icon: "text.alignleft", scopeLabel: "p.1", anchorPage: 0))
            chats.append(ChatMessage(
                role: .assistant,
                text: "**개요**: 오리는 물새다 (p.1).\n\n- 첫째 요점: AI CLI로 요약할 수 있다 (p.1)\n- 둘째 요점: 범위는 p.2–3에 걸쳐 있다\n\n## 결론\n`claude -p` 같은 명령어를 쓴다.",
                scopeLabel: "p.1", anchorPage: 0, status: .done, costUSD: 0.0412, durationMs: 5300
            ))
            chats.append(ChatMessage(role: .user, text: "두 번째 요점을 더 자세히 설명해줘", icon: "bubble.left", scopeLabel: "p.1", anchorPage: 0))
            chats.append(ChatMessage(role: .assistant, text: "AI CLI는 터미널에서", scopeLabel: "p.1", anchorPage: 0, status: .running, activity: "PDF p.2 읽는 중…"))
        }
        if let title = defaults.string(forKey: "DVChapter"), let template = templates.first {
            func find(_ items: [OutlineItem]) -> OutlineItem? {
                for item in items {
                    if item.title == title { return item }
                    if let found = find(item.children ?? []) { return found }
                }
                return nil
            }
            if let item = find(outline) {
                let range = pageRange(of: item)
                runAI(.template(template), scope: .chapter(item.title, range.lowerBound, range.upperBound))
            }
        }
        if let question = defaults.string(forKey: "DVAsk") {
            // 앞의 요청이 끝난 뒤에 이어서 묻는다 (세션 이어가기 확인용)
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, !self.claude.isRunning else { return }
                    timer.invalidate()
                    self.runAI(.ask(question), scope: .currentPage)
                }
            }
        }
        guard let spec = defaults.string(forKey: "DVSelect"), let colon = spec.firstIndex(of: ":"),
              let pageNumber = Int(spec[..<colon]), let doc = document
        else { return }
        let text = String(spec[spec.index(after: colon)...])
        let select = { [weak self] in
            guard let self,
                  let match = doc.findString(text, withOptions: .caseInsensitive)
                      .first(where: { $0.pages.first.map(doc.index(for:)) == pageNumber - 1 })
            else { return }
            self.pdfView.setCurrentSelection(match, animate: false)
            self.pdfView.go(to: match)
            self.mouseUp()
        }
        select()
        if defaults.bool(forKey: "DVHighlight") {
            highlightSelection(color: .yellow)
            select()
        }
        if let name = defaults.string(forKey: "DVRun"), let template = templates.first(where: { $0.name == name }) {
            runAI(.template(template), scope: .selection)
        }
        if defaults.bool(forKey: "DVNote") { beginNote() }
    }
}
#endif

extension NoteColor {
    var nsColor: NSColor {
        switch self {
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .pink: .systemPink
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension NSAlert {
    static func show(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
