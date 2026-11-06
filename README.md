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

## 기능 (v0.1)

- **뷰어**: PDF 열기(⌘O, 드래그앤드롭, Finder에서 열기), 페이지 이동, 썸네일, 마지막 읽은 위치 기억
- **AI 패널**: 범위(현재 페이지 / 선택 영역 / 페이지 범위)를 고르고 요약, 설명, 번역, 자유 질문
  - 단축키: ⇧⌘1 현재 페이지 요약, ⇧⌘2 선택 영역 요약, ⌘. 중단
  - 결과를 복사하거나 메모로 저장
- **메모**: 페이지별 메모. 선택한 텍스트가 있으면 인용으로 함께 저장한다. 원본 PDF는 수정하지 않는다.
- **내장 터미널**: 실제 셸(⌃\`로 토글). 선택 텍스트를 터미널로 보낼 수 있다.

## AI 명령어 설정

설정(⌘,)에서 지정한다. 프롬프트는 **stdin**으로 전달된다.

| 예시 | |
|---|---|
| `claude -p` | 기본값 |
| `claude -p --model sonnet` | 모델 지정 |
| `codex exec -` | |
| `ollama run llama3` | 로컬 모델 |

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
  AppState.swift        문서, 페이지, 선택 상태와 AI 실행 조정
  AI.swift              프롬프트 생성, 셸 환경 해석, CLI 실행(AIRunner)
  Storage.swift         메모, 읽은 위치, 컨텍스트 파일
  ContentView.swift     메인 레이아웃, PDFView, 썸네일, 페이지 이동
  SidePanel.swift       AI 패널, 메모 패널
  Terminal.swift        SwiftTerm 내장 터미널
  SettingsView.swift    설정
scripts/bundle.sh       .app 번들 생성 + ad-hoc 서명
```
