import PDFKit
import SwiftUI

/// 왼쪽 사이드바: 썸네일, 목차, 메모, 검색 (PDF Expert, Skim과 같은 구성)
struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.icon).help(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            Group {
                if state.document == nil {
                    placeholder("열린 문서가 없습니다")
                } else {
                    switch state.sidebarTab {
                    case .thumbnails: ThumbnailStrip(pdfView: state.pdfView)
                    case .outline: OutlineList()
                    case .notes: NotesList()
                    case .search: SearchList()
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private func placeholder(_ text: String, systemImage: String? = nil) -> some View {
    VStack(spacing: 8) {
        if let systemImage {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.tertiary)
        }
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 썸네일

private struct ThumbnailStrip: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.thumbnailSize = CGSize(width: 110, height: 150)
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {}
}

// MARK: - 목차

private struct OutlineList: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.outline.isEmpty {
            placeholder("이 PDF에는 목차가 없습니다", systemImage: "list.bullet.indent")
        } else {
            List(state.outline, children: \.children) { item in
                let range = state.pageRange(of: item)
                HStack {
                    Text(item.title).lineLimit(2)
                    Spacer(minLength: 6)
                    Text("\(item.page + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { state.goToPage(item.page) }
                .contextMenu {
                    let scope = AIScope.chapter(item.title, range.lowerBound, range.upperBound)
                    Section("이 장 (p.\(range.lowerBound)–\(range.upperBound))") {
                        ForEach(state.templates) { template in
                            Button(template.name, systemImage: template.icon) {
                                state.runAI(.template(template), scope: scope)
                            }
                        }
                    }
                    Divider()
                    Button("AI 패널 범위로 설정") {
                        state.aiScopeKind = .range
                        state.rangeFrom = range.lowerBound
                        state.rangeTo = range.upperBound
                        state.showInspector = true
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - 메모

private struct NotesList: View {
    @EnvironmentObject private var state: AppState
    @State private var editing: Note?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "메모 \(state.notes.notes.count)개") {
                Button { state.beginNote() } label: { Image(systemName: "plus") }
                    .help("현재 페이지에 메모 추가")
                Menu {
                    Button("Markdown으로 내보내기…") { state.exportNotesMarkdown() }
                        .disabled(state.notes.notes.isEmpty)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            Divider()
            if state.notes.notes.isEmpty {
                placeholder("텍스트를 선택한 뒤 하이라이트하거나\n메모를 추가해 보세요", systemImage: "highlighter")
            } else {
                List(state.notes.sorted) { note in
                    NoteRow(note: note)
                        .contentShape(Rectangle())
                        .onTapGesture { state.show(note) }
                        .contextMenu {
                            Button("메모 편집…") { editing = note }
                            if note.isHighlight {
                                Menu("색상") {
                                    ForEach(NoteColor.allCases, id: \.self) { color in
                                        Button(color.label) {
                                            var changed = note
                                            changed.color = color
                                            state.updateNote(changed)
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("삭제", role: .destructive) { state.removeNote(note) }
                        }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editing) { note in
            NoteEditSheet(note: note) { state.updateNote($0) }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(note.isHighlight ? (note.color ?? .yellow).color : Color.secondary.opacity(0.3))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("p.\(note.page + 1)").font(.caption.weight(.semibold))
                    if let source = note.source {
                        Label(source, systemImage: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(note.createdAt, format: .dateTime.month().day())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let quote = note.quote, !quote.isEmpty {
                    Text(quote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if !note.text.isEmpty {
                    // Claude 답을 저장한 메모는 Markdown이므로 답변 화면과 같이 그린다.
                    Text(note.source == nil ? AttributedString(note.text) : PageLinkedMarkdown.render(note.text))
                        .font(.callout)
                        .lineLimit(8)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 새 메모 작성 (선택 영역이 있으면 하이라이트와 인용 포함)
struct NoteDraftSheet: View {
    @EnvironmentObject private var state: AppState
    @State var draft: NoteDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("p.\(draft.page + 1)에 메모").font(.headline)
            if let quote = draft.quote {
                Text(quote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(draft.color.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                Picker("하이라이트 색", selection: $draft.color) {
                    ForEach(NoteColor.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            TextEditor(text: $draft.text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("취소", role: .cancel) { state.noteDraft = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") { state.commit(draft) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.quote == nil && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct NoteEditSheet: View {
    @State var note: Note
    let save: (Note) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("p.\(note.page + 1) 메모 편집").font(.headline)
            if let quote = note.quote, !quote.isEmpty {
                Text(quote).font(.callout).foregroundStyle(.secondary).lineLimit(6)
            }
            TextEditor(text: $note.text)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") { save(note); dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - 검색

private struct SearchList: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.searchedQuery.isEmpty {
            placeholder("툴바의 검색창에 입력하고\nReturn을 누르세요", systemImage: "magnifyingglass")
        } else if state.searchResults.isEmpty {
            placeholder("‘\(state.searchedQuery)’ 결과가 없습니다")
        } else {
            VStack(spacing: 0) {
                SectionHeader(title: "‘\(state.searchedQuery)’ \(state.searchResults.count)개") {
                    Button("지우기") {
                        state.searchQuery = ""
                        state.clearSearch()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Divider()
                List(state.searchResults) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("p.\(hit.page + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(hit.snippet).font(.callout).lineLimit(3)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { state.show(hit) }
                }
                .listStyle(.inset)
            }
        }
    }
}
