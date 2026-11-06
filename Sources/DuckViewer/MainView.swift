import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 왼쪽 사이드바 | 가운데 PDF | 오른쪽 AI + 터미널 (터미널은 가운데 아래로도 옮길 수 있다)
struct MainView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("terminalHeight") private var terminalHeight = 220.0

    var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ReaderArea()
                        .frame(maxHeight: .infinity)
                    if state.showTerminal && state.terminalPosition == .bottom {
                        // VSplitView는 처음에 반반으로 나눠서, 높이를 기억하는 분할 바를 직접 둔다.
                        let limit = 110.0...max(110.0, Double(geometry.size.height) - 200)
                        SplitHandle(height: $terminalHeight, limit: limit)
                        TerminalPanel()
                            .frame(height: min(max(terminalHeight, limit.lowerBound), limit.upperBound))
                    }
                }
            }
            .inspector(isPresented: rightPanelPresented) {
                RightPanel()
                    .inspectorColumnWidth(min: 320, ideal: state.terminalOnRight ? 440 : 380, max: 720)
            }
        }
        .navigationTitle(state.title)
        .navigationSubtitle(state.document == nil ? "" : "\(state.currentPageIndex + 1) / \(state.pageCount)쪽")
        .searchable(text: $state.searchQuery, placement: .toolbar, prompt: "문서에서 검색")
        .onSubmit(of: .search) { state.search() }
        .onChange(of: state.searchQuery) { _, query in
            if query.isEmpty { state.clearSearch() }
        }
        .toolbar { toolbar }
        .sheet(item: $state.noteDraft) { draft in
            NoteDraftSheet(draft: draft)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in AppState.shared.open(url) }
            }
            return true
        }
    }

    /// 오른쪽 패널은 AI나 (오른쪽 배치일 때) 터미널 중 하나라도 켜져 있으면 보인다.
    private var rightPanelPresented: Binding<Bool> {
        Binding(
            get: { state.showInspector || state.terminalOnRight },
            set: { shown in
                if !shown {
                    state.showInspector = false
                    if state.terminalPosition == .right { state.showTerminal = false }
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if state.document != nil { PageNavigator() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { state.zoomOut() } label: { Label("축소", systemImage: "minus.magnifyingglass") }
                Button { state.zoomIn() } label: { Label("확대", systemImage: "plus.magnifyingglass") }
            }
            .disabled(state.document == nil)
            .help("축소 / 확대")

            Menu {
                Button("화면에 맞추기") { state.zoomToFit() }
                Section("페이지 배치") {
                    Picker("페이지 배치", selection: $state.pageLayout) {
                        ForEach(PageLayout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("터미널 위치") {
                    Picker("터미널 위치", selection: $state.terminalPosition) {
                        ForEach(TerminalPosition.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("읽기 테마") {
                    Picker("읽기 테마", selection: $state.theme) {
                        ForEach(ReadingTheme.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            } label: {
                Label("보기", systemImage: "doc.text.magnifyingglass")
            }
            .help("페이지 배치와 읽기 테마")

            Toggle(isOn: $state.showTerminal) {
                Label("터미널", systemImage: "terminal")
            }
            .help("터미널 (⌃`)")

            Toggle(isOn: $state.showInspector) {
                Label("AI", systemImage: "sparkles")
            }
            .help("AI 패널 (⌥⌘0)")
        }
    }
}

private struct PageNavigator: View {
    @EnvironmentObject private var state: AppState
    @State private var input = ""

    var body: some View {
        HStack(spacing: 2) {
            Button { state.goToPage(state.currentPageIndex - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(state.currentPageIndex == 0)
                .help("이전 페이지")
            TextField("", text: $input)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let page = Int(input) { state.goToPage(page - 1) }
                    input = "\(state.currentPageIndex + 1)"
                }
            Text("/ \(state.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            Button { state.goToPage(state.currentPageIndex + 1) } label: { Image(systemName: "chevron.down") }
                .disabled(state.currentPageIndex >= state.pageCount - 1)
                .help("다음 페이지")
        }
        .onAppear { input = "\(state.currentPageIndex + 1)" }
        .onChange(of: state.currentPageIndex) { _, page in input = "\(page + 1)" }
    }
}

/// 위아래로 끌어서 터미널 높이를 바꾸는 막대
private struct SplitHandle: View {
    @Binding var height: Double
    let limit: ClosedRange<Double>
    @State private var startHeight: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startHeight ?? height
                                startHeight = start
                                height = min(max(start - value.translation.height, limit.lowerBound), limit.upperBound)
                            }
                            .onEnded { _ in startHeight = nil }
                    )
            }
            .zIndex(1)
    }
}

/// 오른쪽 패널: 위는 AI, 아래는 터미널 (터미널이 오른쪽 배치일 때)
private struct RightPanel: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("rightTerminalHeight") private var terminalHeight = 320.0

    var body: some View {
        if state.terminalOnRight && state.showInspector {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    AIPanel()
                        .frame(maxHeight: .infinity)
                    let limit = 120.0...max(120.0, Double(geometry.size.height) - 220)
                    SplitHandle(height: $terminalHeight, limit: limit)
                    TerminalPanel()
                        .frame(height: min(max(terminalHeight, limit.lowerBound), limit.upperBound))
                }
            }
        } else if state.terminalOnRight {
            TerminalPanel()
        } else {
            AIPanel()
        }
    }
}
