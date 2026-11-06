import AppKit
import PDFKit
import SwiftUI

/// 드래그가 끝난 뒤에 선택 액션 바를 띄우고, 우클릭 메뉴에 메모와 AI 항목을 넣기 위한 PDFView
final class DuckPDFView: PDFView {
    weak var state: AppState?
    private var boundsObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 스크롤하면 선택 액션 바 위치를 다시 계산한다. PDFView 안쪽 클립 뷰의 변경만 받는다.
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let clip = note.object as? NSClipView else { return }
            MainActor.assumeIsolated {
                if clip.isDescendant(of: self) { self.state?.viewportDidChange() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        // ⌥ 드래그: 글자를 선택할 수 없는 스캔본에서도 영역을 지정해 메모를 단다.
        if event.modifierFlags.contains(.option), document != nil {
            trackArea(from: event)
            return
        }
        state?.mouseDown()
        super.mouseDown(with: event)
        // PDFView는 드래그를 mouseDown 안에서 처리하므로, 돌아왔을 때 버튼이 떼어져 있으면 끝난 것이다.
        if NSEvent.pressedMouseButtons & 1 == 0 { state?.mouseUp() }
    }

    private func trackArea(from event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard let page = page(for: start, nearest: true), let document else { return }
        let origin = convert(start, to: page)
        let preview = PDFAnnotation(bounds: .zero, forType: .square, withProperties: nil)
        preview.color = .systemBlue
        let border = PDFBorder()
        border.lineWidth = 1.5
        border.style = .dashed
        border.dashPattern = [4, 3]
        preview.border = border
        page.addAnnotation(preview)
        NSCursor.crosshair.push()
        defer { NSCursor.pop() }

        let pageBounds = page.bounds(for: displayBox)
        var rect = CGRect.zero
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(convert(next.locationInWindow, from: nil), to: page)
            rect = CGRect(
                x: min(origin.x, point.x), y: min(origin.y, point.y),
                width: abs(point.x - origin.x), height: abs(point.y - origin.y)
            ).intersection(pageBounds)
            preview.bounds = rect
            if next.type == .leftMouseUp { break }
        }
        page.removeAnnotation(preview)
        if rect.width > 8, rect.height > 8 {
            state?.beginAreaNote(page: document.index(for: page), rect: rect)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        state?.mouseUp()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let state, state.document != nil else { return menu }
        var items: [NSMenuItem] = []
        if state.hasSelection {
            let highlight = NSMenuItem(title: "하이라이트", action: nil, keyEquivalent: "")
            highlight.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
            highlight.submenu = NSMenu()
            for color in NoteColor.allCases {
                highlight.submenu?.addItem(ClosureMenuItem(color.label) { state.highlightSelection(color: color) })
            }
            items.append(highlight)
            items.append(ClosureMenuItem("밑줄 긋고 설명 달기…", symbol: "underline") { state.beginNote(style: .underline) })
            items.append(ClosureMenuItem("형광펜 + 메모…", symbol: "note.text") { state.beginNote() })
            items.append(aiMenu(state, scope: .selection, title: "선택 영역 Claude"))
            items.append(ClosureMenuItem("Claude에게 질문…", symbol: "bubble.left") {
                state.aiScopeKind = .selection
                state.showInspector = true
                state.composerFocusRequest += 1
            })
        } else {
            items.append(ClosureMenuItem("이 페이지에 메모…", symbol: "note.text") { state.beginNote() })
            let hint = NSMenuItem(title: "⌥ 드래그로 영역에 메모", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            items.append(hint)
            items.append(aiMenu(state, scope: .currentPage, title: "현재 페이지 Claude"))
        }
        items.append(.separator())
        for (index, item) in items.enumerated() {
            menu.insertItem(item, at: index)
        }
        return menu
    }

    private func aiMenu(_ state: AppState, scope: AIScope, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        item.submenu = NSMenu()
        for template in state.templates {
            item.submenu?.addItem(ClosureMenuItem(template.name, symbol: template.icon) {
                state.runAI(.template(template), scope: scope)
            })
        }
        return item
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

/// 가운데 읽기 영역: 문서가 없으면 시작 화면, 있으면 PDF + 선택 액션 바
struct ReaderArea: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.document == nil {
            WelcomeView()
        } else {
            GeometryReader { geometry in
                PDFKitView(pdfView: state.pdfView)
                    .overlay(alignment: .topLeading) {
                        FootnoteLayer()
                    }
                    .overlay(alignment: .topLeading) {
                        if let rect = state.selectionRect {
                            SelectionBar()
                                .fixedSize()
                                .position(Self.barPosition(for: rect, in: geometry.size))
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: state.selectionRect == nil)
            }
        }
    }

    /// 선택 영역 위쪽 가운데. 공간이 없으면 아래쪽에 둔다.
    private static func barPosition(for rect: CGRect, in size: CGSize) -> CGPoint {
        let halfWidth: CGFloat = 190, halfHeight: CGFloat = 18, gap: CGFloat = 10
        var y = rect.minY - gap - halfHeight
        if y < halfHeight + 4 { y = rect.maxY + gap + halfHeight }
        y = min(max(y, halfHeight + 4), size.height - halfHeight - 4)
        let x = min(max(rect.midX, halfWidth + 8), max(halfWidth + 8, size.width - halfWidth - 8))
        return CGPoint(x: x, y: y)
    }
}

/// 텍스트를 선택하면 뜨는 작은 도구 막대 (Readwise Reader의 선택 메뉴와 같은 역할)
private struct SelectionBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            Button { state.highlightSelection() } label: {
                Label("하이라이트", systemImage: "highlighter")
            }
            .help("하이라이트 (⇧⌘H)")
            Button { state.beginNote(style: .underline) } label: {
                Label("밑줄+설명", systemImage: "underline")
            }
            .help("밑줄 긋고 설명 달기 [n] (⇧⌘U)")
            Button { state.beginNote() } label: {
                Label("메모", systemImage: "note.text")
            }
            .help("형광펜 + 메모 (⇧⌘M)")

            Divider().frame(height: 18).padding(.horizontal, 4)

            ForEach(state.templates.prefix(3)) { template in
                Button { state.runAI(.template(template), scope: .selection) } label: {
                    Label(template.name, systemImage: template.icon)
                }
            }
            Menu {
                ForEach(state.templates.dropFirst(3)) { template in
                    Button(template.name, systemImage: template.icon) {
                        state.runAI(.template(template), scope: .selection)
                    }
                }
                Divider()
                Button("Claude에게 질문…", systemImage: "bubble.left") {
                    state.aiScopeKind = .selection
                    state.showInspector = true
                    state.composerFocusRequest += 1
                }
                Button("복사", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.selectionText, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(SelectionBarButtonStyle())
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

private struct SelectionBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Color.primary.opacity(0.12) : .clear, in: Capsule())
            .contentShape(Capsule())
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "book.pages")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("DuckViewer").font(.title.weight(.semibold))
                Text("PDF를 끌어다 놓거나 ⌘O로 여세요").foregroundStyle(.secondary)
            }
            Button("PDF 열기…") { state.presentOpenPanel() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            let recents = RecentFiles.load().prefix(6)
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("최근 문서").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                    ForEach(Array(recents), id: \.self) { url in
                        Button { state.open(url) } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                                Spacer()
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// 페이지 위의 [n] 각주들. 마우스를 올리면 내용을 보여주고, 누르면 편집 창을 연다.
private struct FootnoteLayer: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(state.footnoteMarkers) { marker in
                FootnoteMarkerView(marker: marker)
                    .position(marker.point)
            }
        }
    }
}

private struct FootnoteMarkerView: View {
    @EnvironmentObject private var state: AppState
    let marker: FootnoteMarker
    @State private var hoverTask: Task<Void, Never>?

    private var note: Note? { state.notes.notes.first { $0.id == marker.id } }
    private var isHovered: Bool { state.hoveredFootnote == marker.id }

    var body: some View {
        // 앱 모양이 아니라 페이지 색(읽기 테마)에 맞춘다.
        let pageColor: Color = state.theme == .dark ? Color(white: 0.12) : .white
        Text("[\(marker.number)]")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(state.theme == .dark ? Color(red: 0.55, green: 0.75, blue: 1) : Color(red: 0.0, green: 0.4, blue: 0.85))
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isHovered ? Color.accentColor.opacity(0.18) : pageColor.opacity(0.9))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                // 스쳐 지나갈 때 깜빡이지 않도록 잠깐 머문 뒤에 띄운다.
                hoverTask?.cancel()
                if inside {
                    NSCursor.pointingHand.push()
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        if !Task.isCancelled { state.hoveredFootnote = marker.id }
                    }
                } else {
                    NSCursor.pop()
                    if state.hoveredFootnote == marker.id { state.hoveredFootnote = nil }
                }
            }
            .onTapGesture {
                state.hoveredFootnote = nil
                if let note { state.editingNote = note }
            }
            .popover(isPresented: Binding(
                get: { isHovered && note != nil },
                set: { if !$0, isHovered { state.hoveredFootnote = nil } }
            ), arrowEdge: .bottom) {
                if let note { FootnoteCard(note: note, number: marker.number) }
            }
            .help("")
    }
}

/// 각주 내용 미리보기 (나무위키 각주 팝업과 같은 역할)
struct FootnoteCard: View {
    let note: Note
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("[\(number)]").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                Text(kindLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("p.\(note.markerPage + 1)").font(.caption2).foregroundStyle(.tertiary)
            }
            if let quote = note.quote, !quote.isEmpty {
                Text(quote)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !note.text.isEmpty {
                Text(note.source == nil ? AttributedString(note.text) : PageLinkedMarkdown.render(note.text))
                    .font(.callout)
                    .lineLimit(14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("클릭하면 편집").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    private var kindLabel: String {
        if let source = note.source { return source }
        switch note.kind {
        case .page: return "페이지 메모"
        case .underline: return "밑줄 설명"
        case .area: return "영역 메모"
        case .highlight: return "형광펜 메모"
        }
    }
}
