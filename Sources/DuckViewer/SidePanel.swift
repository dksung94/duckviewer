import AppKit
import SwiftUI

struct SidePanel: View {
    private enum Tab: String, CaseIterable { case ai = "AI", notes = "메모" }
    @State private var tab: Tab = .ai

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .ai: AIPanel()
            case .notes: NotesPanel()
            }
        }
    }
}

// MARK: - AI

private struct AIPanel: View {
    private enum ScopeKind: String, CaseIterable { case page = "현재 페이지", selection = "선택 영역", range = "페이지 범위" }

    @EnvironmentObject private var state: AppState
    @State private var scopeKind: ScopeKind = .page
    @State private var fromPage = 1
    @State private var toPage = 1
    @State private var question = ""

    private var scope: AIScope {
        switch scopeKind {
        case .page: .currentPage
        case .selection: .selection
        case .range: .pages(min(fromPage, toPage), max(fromPage, toPage))
        }
    }

    private var canRun: Bool {
        guard state.document != nil else { return false }
        switch scopeKind {
        case .page: return true
        case .selection: return state.hasSelection
        case .range: return (1...state.pageCount).contains(fromPage) && (1...state.pageCount).contains(toPage)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("범위", selection: $scopeKind) {
                ForEach(ScopeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            scopeDetail

            HStack {
                Button("요약") { state.runAI(.summarize, scope: scope) }
                Button("설명") { state.runAI(.explain, scope: scope) }
                Button("번역") { state.runAI(.translate, scope: scope) }
            }
            .disabled(!canRun || state.ai.isRunning)

            HStack {
                TextField("이 범위에 대해 질문하기", text: $question)
                    .onSubmit(ask)
                Button("묻기", action: ask)
                    .disabled(!canRun || state.ai.isRunning || question.isEmpty)
            }

            Divider()
            AIOutputView()
        }
        .padding(10)
        .onAppear { fromPage = state.currentPageIndex + 1; toPage = fromPage }
    }

    @ViewBuilder
    private var scopeDetail: some View {
        switch scopeKind {
        case .page:
            Text("p.\(state.currentPageIndex + 1)").font(.caption).foregroundStyle(.secondary)
        case .selection:
            Text(state.hasSelection ? state.selectionText : "PDF에서 텍스트를 드래그하세요")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        case .range:
            HStack {
                TextField("시작", value: $fromPage, format: .number).frame(width: 60)
                Text("–")
                TextField("끝", value: $toPage, format: .number).frame(width: 60)
                Text("/ \(state.pageCount)쪽").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("현재 페이지부터") { fromPage = state.currentPageIndex + 1 }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRun, !q.isEmpty, !state.ai.isRunning else { return }
        state.runAI(.ask(q), scope: scope)
    }
}

private struct AIOutputView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let ai = state.ai
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if ai.isRunning {
                    ProgressView().controlSize(.small)
                    Text("\(ai.lastLabel) 실행 중… (\(AISettings.command))")
                        .lineLimit(1)
                } else if !ai.lastLabel.isEmpty {
                    Text(ai.lastLabel)
                }
                Spacer()
                if ai.isRunning {
                    Button("중단") { ai.cancel() }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ai.output)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !ai.errorOutput.isEmpty, ai.exitStatus != 0 || ai.output.isEmpty {
                        Text(ai.errorOutput)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let status = ai.exitStatus, status != 0 {
                        Text("종료 코드 \(status). 설정(⌘,)에서 AI 명령어를 확인하세요.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack {
                Button("복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ai.output, forType: .string)
                }
                Button("메모로 저장") { state.saveAIOutputAsNote() }
                Spacer()
            }
            .disabled(ai.output.isEmpty || ai.isRunning)
        }
    }
}

// MARK: - 메모

private struct NotesPanel: View {
    @EnvironmentObject private var state: AppState
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("p.\(state.currentPageIndex + 1)에 메모" + (state.hasSelection ? " (선택 영역 인용)" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            HStack {
                Spacer()
                Button("추가") {
                    let quote = state.hasSelection ? state.selectionText : nil
                    state.notes.add(Note(page: state.currentPageIndex, text: draft, quote: quote, source: nil))
                    draft = ""
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.document == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            if state.notes.notes.isEmpty {
                Text("메모가 없습니다").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(state.notes.sorted) { note in
                    NoteRow(note: note)
                }
                .listStyle(.plain)
            }
        }
        .padding(10)
    }
}

private struct NoteRow: View {
    @EnvironmentObject private var state: AppState
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("p.\(note.page + 1)") { state.goToPage(note.page) }
                    .buttonStyle(.link)
                if let source = note.source {
                    Text("AI · \(source)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(note.createdAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
            }
            if let quote = note.quote {
                Text(quote)
                    .italic()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Text(note.text).textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("이 페이지로 이동") { state.goToPage(note.page) }
            Button("삭제", role: .destructive) { state.notes.remove(note) }
        }
    }
}
