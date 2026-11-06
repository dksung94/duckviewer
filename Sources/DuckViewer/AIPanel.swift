import AppKit
import SwiftUI

/// 오른쪽 인스펙터: 빠른 실행 템플릿, 결과 카드, 질문 입력 (Acrobat AI Assistant, Readwise Ghostreader와 같은 위치)
struct AIPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
            Divider()
            Composer()
        }
        .environment(\.openURL, OpenURLAction { url in
            // 응답 속 (p.N) 링크를 누르면 해당 페이지로 이동
            guard url.scheme == "duckviewer", url.host == "page", let page = Int(url.lastPathComponent) else {
                return .systemAction
            }
            state.goToPage(page - 1)
            return .handled
        })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("AI").font(.headline)
            Text(AISettings.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("설정(⌘,)에서 바꿀 수 있습니다")
            Spacer()
            if !state.turns.isEmpty {
                Button { state.clearTurns() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("결과 모두 지우기")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var results: some View {
        if state.turns.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                Text("아래에서 범위를 고르고 템플릿을 누르거나 질문하세요.")
                    .multilineTextAlignment(.center)
                Text("텍스트를 드래그하면 선택 영역이 자동으로 범위가 됩니다.\n이어지는 대화는 아래 터미널에서 `claude`를 실행해 나누세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(state.turns) { turn in
                            TurnCard(turn: turn).id(turn.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: state.turns.count) {
                    if let last = state.turns.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .top) }
                    }
                }
            }
        }
    }
}

private struct TurnCard: View {
    @EnvironmentObject private var state: AppState
    let turn: AITurn
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: turn.icon).foregroundStyle(.tint)
                Text(turn.title).font(.callout.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Button { state.goToPage(turn.anchorPage) } label: {
                    Text(turn.scopeLabel)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("이 범위로 이동")
            }

            if !turn.output.isEmpty {
                Text(PageLinkedMarkdown.render(turn.output))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if turn.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(turn.output.isEmpty ? "응답을 기다리는 중…" : "받는 중…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("중단") { state.ai.cancel() }
                        .controlSize(.small)
                }
            }

            if turn.status == .cancelled {
                Text("중단됨").font(.caption).foregroundStyle(.secondary)
            }

            if turn.failed || (!turn.isRunning && turn.output.isEmpty && !turn.error.isEmpty) {
                VStack(alignment: .leading, spacing: 4) {
                    if !turn.error.isEmpty {
                        Text(turn.error)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(12)
                    }
                    if case let .finished(code) = turn.status, code != 0 {
                        Text("종료 코드 \(code). 설정(⌘,)에서 AI 명령어를 확인하세요.").font(.caption)
                    }
                }
                .foregroundStyle(.red)
            }

            if !turn.isRunning, !turn.output.isEmpty {
                HStack(spacing: 12) {
                    Button(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(turn.output, forType: .string)
                        copied = true
                    }
                    Button("메모로 저장", systemImage: "note.text.badge.plus") { state.saveAsNote(turn) }
                    Spacer()
                    Button { state.removeTurn(turn) } label: { Image(systemName: "xmark") }
                        .help("이 결과 지우기")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// 아래쪽 입력부: 범위, 템플릿 칩, 질문 입력
private struct Composer: View {
    @EnvironmentObject private var state: AppState
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            scopeRow

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.templates) { template in
                        Button { state.runAI(.template(template), scope: state.panelScope) } label: {
                            Label(template.name, systemImage: template.icon)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(!state.canRunPanelScope || state.ai.isRunning)

            HStack(alignment: .bottom, spacing: 6) {
                TextField("이 범위에 대해 질문하기", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(ask)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                if state.ai.isRunning {
                    Button { state.ai.cancel() } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .help("중단 (⌘.)")
                } else {
                    Button(action: ask) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canAsk ? Color.accentColor : Color.secondary)
                    .disabled(!canAsk)
                }
            }
        }
        .padding(10)
        .onChange(of: state.composerFocusRequest) { focused = true }
    }

    private var scopeRow: some View {
        HStack(spacing: 6) {
            Picker("범위", selection: $state.aiScopeKind) {
                ForEach(AIScopeKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()

            switch state.aiScopeKind {
            case .page:
                Text("p.\(state.currentPageIndex + 1)").foregroundStyle(.secondary)
            case .selection:
                Text(state.hasSelection ? "“\(state.selectionText.prefix(40))”" : "PDF에서 텍스트를 드래그하세요")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .range:
                TextField("시작", value: $state.rangeFrom, format: .number)
                    .frame(width: 48)
                Text("–")
                TextField("끝", value: $state.rangeTo, format: .number)
                    .frame(width: 48)
                Text("/ \(state.pageCount)").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private var canAsk: Bool {
        state.canRunPanelScope && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !state.ai.isRunning else { return }
        state.runAI(.ask(q), scope: state.panelScope)
        question = ""
    }
}

/// AI 응답을 인라인 Markdown으로 그리고, (p.N) 표기를 페이지 이동 링크로 바꾼다.
enum PageLinkedMarkdown {
    private static let pageRef = try! NSRegularExpression(pattern: #"p\.\s?(\d+)(?:\s?[–-]\s?(\d+))?"#)

    static func render(_ source: String) -> AttributedString {
        // 제목 줄(#)은 인라인 Markdown에서 그대로 보이므로 굵게 바꾼다.
        let prepared = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " }
                guard trimmed.hasPrefix("#") else { return String(line) }
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "" : "**\(title)**"
            }
            .joined(separator: "\n")

        var attributed = (try? AttributedString(
            markdown: prepared,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(source)

        let plain = String(attributed.characters)
        let matches = pageRef.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        for match in matches {
            guard let range = Range(match.range, in: plain),
                  let pageRange = Range(match.range(at: 1), in: plain),
                  let page = Int(plain[pageRange])
            else { continue }
            let lower = attributed.characters.index(attributed.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let upper = attributed.characters.index(attributed.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.upperBound))
            attributed[lower..<upper].link = URL(string: "duckviewer://page/\(page)")
        }
        return attributed
    }
}
