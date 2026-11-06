import AppKit
import SwiftUI

/// 오른쪽 인스펙터: 문서마다 하나씩 이어지는 Claude 대화
struct AIPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
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
            Text("Claude").font(.headline)
            if !ClaudeSettings.model.isEmpty {
                Text(ClaudeSettings.model)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            Menu {
                Button("새 대화", systemImage: "square.and.pencil") { state.newConversation() }
                    .disabled(state.messages.isEmpty && !state.hasSession)
                Button("터미널에서 이어하기 명령 복사", systemImage: "terminal") { state.copyResumeCommand() }
                    .disabled(state.resumeCommand == nil)
                Divider()
                Button("설정…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(state.resumeCommand ?? "아직 대화가 없습니다")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var conversation: some View {
        if state.messages.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle).foregroundStyle(.tertiary)
                Text(state.document == nil ? "PDF를 열면 이 문서와의 대화가 시작됩니다." : "이 문서에 대해 무엇이든 물어보세요.")
                    .multilineTextAlignment(.center)
                Text("문서마다 대화가 따로 저장되고, 다시 열면 이어집니다.\n텍스트를 드래그하면 그 부분이 질문의 범위가 됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(state.messages) { message in
                            Group {
                                switch message.role {
                                case .user: UserBubble(message: message)
                                case .assistant: AssistantMessage(message: message)
                                }
                            }
                            .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: state.messages.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: state.messages.last?.text) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct ScopeChip: View {
    @EnvironmentObject private var state: AppState
    let label: String
    let page: Int?

    var body: some View {
        Button { if let page { state.goToPage(page) } } label: {
            Text(label)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("이 위치로 이동")
    }
}

private struct UserBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let scope = message.scopeLabel {
                ScopeChip(label: scope, page: message.anchorPage)
            }
            HStack(spacing: 6) {
                if let title = message.title {
                    Image(systemName: message.icon ?? "sparkles")
                    Text(title).fontWeight(.medium)
                } else {
                    Text(message.text).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }
}

private struct AssistantMessage: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.text.isEmpty {
                Text(PageLinkedMarkdown.render(message.text))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if message.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(message.activity ?? (message.text.isEmpty ? "생각하는 중…" : "쓰는 중…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch message.status {
            case .cancelled:
                Text("중단됨").font(.caption).foregroundStyle(.secondary)
            case .failed:
                Text(message.error ?? "실패했습니다")
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(10)
            default:
                EmptyView()
            }

            if message.status == .done, !message.text.isEmpty {
                HStack(spacing: 12) {
                    Button(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        copied = true
                    }
                    if state.isSavedAsNote(message) {
                        Button("메모에 저장됨", systemImage: "checkmark.circle.fill") { state.saveAsNote(message) }
                            .foregroundStyle(.green)
                            .help("메모 목록에서 보기")
                    } else {
                        Button("메모로 저장", systemImage: "note.text.badge.plus") { state.saveAsNote(message) }
                    }
                    Spacer()
                    if let meta = metadata {
                        Text(meta).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 8)
    }

    private var metadata: String? {
        var parts: [String] = []
        if let ms = message.durationMs { parts.append(String(format: "%.1f초", Double(ms) / 1000)) }
        if let cost = message.costUSD { parts.append(String(format: "$%.3f", cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            .disabled(!state.canRunPanelScope || state.claude.isRunning)

            HStack(alignment: .bottom, spacing: 6) {
                TextField(state.messages.isEmpty ? "이 범위에 대해 질문하기" : "이어서 질문하기", text: $question, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(ask)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                if state.claude.isRunning {
                    Button { state.claude.cancel() } label: {
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
        guard canAsk, !state.claude.isRunning else { return }
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
