# DuckViewer

AI랑 같이 읽는 macOS PDF 뷰어. 사용자가 지정한 AI CLI(기본값 `claude -p`)로 현재 페이지, 선택 영역, 페이지 범위를 요약하고 질문하며, 앱 안의 터미널에서 AI 에이전트와 바로 대화할 수 있다.

요구사항과 경쟁 제품 분석은 [doc/01_requirements_and_competitors.md](doc/01_requirements_and_competitors.md)에 있다.

## 빌드와 실행

macOS 14 이상, Swift 6.0 이상(Command Line Tools만 있어도 된다. SwiftTerm 1.20.0이 Swift 6.0을 요구한다).

```sh
scripts/bundle.sh            # build/DuckViewer.app 생성 (release)
open build/DuckViewer.app
open -a "$PWD/build/DuckViewer.app" some.pdf   # 파일과 함께 열기
```

개발 중에는 `scripts/bundle.sh debug`가 더 빠르다. SwiftUI 앱이라 `swift run`으로 바로 실행하지 말고 `.app` 번들로 실행해야 키보드 입력과 메뉴가 정상 동작한다.

## 기능 (v0.2)

화면 구성과 경쟁 제품 대비 설계 근거는 [doc/02_ui_design.md](doc/02_ui_design.md)에 있다.

- **왼쪽 사이드바**: 썸네일, 목차, 메모, 검색 탭
- **가운데**: PDF와 내장 터미널(높이 조절 가능)
  - 텍스트를 드래그하면 **선택 액션 바**: 하이라이트, 메모, AI 템플릿, 터미널로 보내기
  - 우클릭 메뉴에도 같은 항목이 있다
- **오른쪽 AI 패널**: 범위(현재 페이지 / 선택 영역 / 페이지 범위)를 고르고 템플릿(요약, 쉽게 설명, 번역, 핵심 용어, 퀴즈)이나 자유 질문 실행
  - 결과는 카드로 쌓이고, 응답 속 `(p.N)`을 누르면 그 페이지로 이동한다
  - 목차 항목을 우클릭하면 그 장 전체를 요약할 수 있다
- **메모와 하이라이트**: 4가지 색, 원본 PDF는 수정하지 않음, Markdown 내보내기(⇧⌘E)
- **보기**: 확대/축소, 페이지 배치(연속, 한 페이지, 두 페이지), 읽기 테마(기본, 세피아, 다크)
- 마지막 읽은 위치 기억, 시작 화면의 최근 문서

단축키는 doc/02의 표를 참고.

## AI 명령어 설정

설정(⌘,)에서 지정한다. 프롬프트는 **stdin**으로 전달된다.

| 예시 | |
|---|---|
| `claude -p` | 기본값 |
| `claude -p --model sonnet` | 모델 지정 |
| `codex exec -` | |
| `gemini -p` | |
| `ollama run qwen3:8b` | 로컬 모델 (오프라인). `ollama pull qwen3:8b` 먼저 |

설정의 **프리셋** 메뉴에서 고를 수 있고, **프롬프트 템플릿** 탭에서 템플릿을 추가하거나 순서를 바꿀 수 있다.

치환 변수: `{file}`(현재 PDF 경로), `{page}`(현재 페이지 번호). 값은 셸 인용 처리된다.

명령어는 사용자의 대화형 로그인 셸(`$SHELL -ilc`)에서 읽어 온 환경변수로 실행된다. 그래서 Finder에서 실행해도 터미널과 같은 PATH를 쓴다.

## 터미널 속 AI와 연동

앱은 현재 읽기 상태를 `~/.duckviewer/context.json`에 계속 써 둔다. 내장 터미널에는 `DUCKVIEWER_CONTEXT` 환경변수로 이 경로가 들어 있다.

```json
{
  "file": "/path/to/book.pdf",
  "page": 12,
  "pageCount": 340,
  "selection": "드래그한 텍스트",
  "pageText": "현재 페이지 전체 텍스트",
  "updatedAt": "2026-11-06T09:29:44Z"
}
```

터미널에서 `claude`를 띄운 뒤 "$DUCKVIEWER_CONTEXT 읽고 지금 보는 페이지 설명해줘"처럼 물으면 된다.

## 데이터 위치

| 경로 | 내용 |
|---|---|
| `~/Library/Application Support/DuckViewer/notes/<sha256>.json` | 문서별 메모 (파일 내용 해시 기준이라 파일을 옮겨도 유지) |
| `~/.duckviewer/context.json` | 현재 읽기 상태 |
| `UserDefaults` (`com.dksung94.duckviewer`) | AI 명령어, 응답 언어, 읽은 위치 |

## 구조

```
Sources/DuckViewer/
  DuckViewerApp.swift   앱 진입점, 메뉴, 파일 열기 처리
  AppState.swift        문서, 선택, 검색, 하이라이트, AI 실행 상태 (+ DEBUG 훅)
  AI.swift              프롬프트 템플릿, 프롬프트 생성, 셸 환경 해석, CLI 실행(AIRunner)
  Storage.swift         메모(사이드카 JSON), 읽은 위치, 최근 문서, 컨텍스트 파일
  MainView.swift        3단 레이아웃, 툴바, 터미널 분할 바
  Reader.swift          PDFView 서브클래스(우클릭 메뉴), 선택 액션 바, 시작 화면
  Sidebar.swift         썸네일, 목차, 메모, 검색 탭과 메모 시트
  AIPanel.swift         AI 결과 카드, 입력부, 페이지 링크 Markdown 렌더링
  Terminal.swift        SwiftTerm 내장 터미널
  SettingsView.swift    AI 명령어와 프리셋, 프롬프트 템플릿 편집
scripts/bundle.sh       .app 번들 생성 + ad-hoc 서명
```
