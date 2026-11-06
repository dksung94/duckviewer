# DuckViewer

Claude와 같이 읽는 macOS PDF 뷰어. PDF마다 Claude Code 세션이 하나씩 붙어서, 현재 페이지·선택 영역·페이지 범위·장 단위로 요약하고 이어서 질문할 수 있다. 문서를 다시 열면 대화가 이어진다.

- 요구사항과 경쟁 제품 분석: [doc/01_requirements_and_competitors.md](doc/01_requirements_and_competitors.md)
- 화면 설계: [doc/02_ui_design.md](doc/02_ui_design.md)

## 빌드와 실행

macOS 14 이상, Swift 5.10 이상(Command Line Tools만 있어도 된다), [Claude Code](https://claude.com/claude-code) (`claude` 명령).

```sh
scripts/bundle.sh            # build/DuckViewer.app 생성 (release)
open build/DuckViewer.app
open -a "$PWD/build/DuckViewer.app" some.pdf   # 파일과 함께 열기
```

개발 중에는 `scripts/bundle.sh debug`가 더 빠르다. SwiftUI 앱이라 `swift run`으로 바로 실행하지 말고 `.app` 번들로 실행해야 키보드 입력과 메뉴가 정상 동작한다.

## 기능

- **왼쪽 사이드바**: 썸네일, 목차, 메모, 검색 탭
- **가운데**: PDF. 텍스트를 드래그하면 **선택 액션 바**(하이라이트, 메모, 요약·설명·번역, Claude에게 질문)가 뜨고, 우클릭 메뉴에도 같은 항목이 있다.
- **오른쪽 Claude 패널**: 문서별로 이어지는 대화
  - 범위(현재 페이지 / 선택 영역 / 페이지 범위)를 고르고 템플릿(요약, 쉽게 설명, 번역, 핵심 용어, 퀴즈)이나 자유 질문
  - 목차 항목을 우클릭하면 그 장 전체를 대상으로 실행
  - 답이 글자 단위로 흘러나오고, "PDF p.3 읽는 중…"처럼 Claude가 하는 일을 보여준다
  - 응답 속 `(p.N)`을 누르면 그 페이지로 이동, 답을 메모로 저장
  - ⋯ 메뉴: 새 대화, 터미널에서 이어하기 명령 복사
- **메모와 하이라이트**: 4가지 색, 원본 PDF는 수정하지 않음, Markdown 내보내기(⇧⌘E)
- **보기**: 확대/축소, 페이지 배치, 읽기 테마(기본, 세피아, 다크), 마지막 읽은 위치 기억, 최근 문서

단축키는 doc/02의 표를 참고.

## Claude 연동 방식

- 메시지를 보낼 때마다 `claude -p --resume <세션> --output-format stream-json`을 실행하고, 프롬프트는 stdin으로 넘긴다. 첫 메시지는 `--session-id`로 새 세션을 만든다.
- 세션은 PDF가 있는 폴더에서 시작한다. Claude Code의 세션이라 터미널에서 `cd <폴더> && claude --resume <세션>`으로 같은 대화를 이어갈 수 있다 (패널 ⋯ 메뉴에서 명령 복사).
- 메시지마다 `[DuckViewer]` 블록으로 **지금 보고 있는 페이지**, 범위, 범위의 텍스트를 함께 보낸다. 시스템 프롬프트에는 PDF 경로와 총 쪽수가 들어간다.
- 범위의 텍스트가 거의 없거나(스캔본) 너무 길면 텍스트 대신 Claude가 `Read` 도구로 PDF 페이지를 직접 읽게 한다. 그림·표가 필요할 때도 직접 읽는다.
- 허용하는 도구는 `Read`뿐이다. 설정에서 켜면 `Write`도 허용해서 "요약을 파일로 저장해줘" 같은 요청을 처리한다.
- `claude`는 사용자의 대화형 로그인 셸(`$SHELL -ilc`)에서 읽어 온 PATH로 찾는다. 그래서 Finder에서 실행해도 터미널과 같은 `claude`를 쓴다.

설정(⌘,): 모델(기본값 / Opus / Sonnet / Haiku), 응답 언어, 파일 쓰기 허용, 프롬프트 템플릿 편집.

## 데이터 위치

| 경로 | 내용 |
|---|---|
| `~/Library/Application Support/DuckViewer/notes/<sha256>.json` | 문서별 메모와 하이라이트 (파일 내용 해시 기준이라 파일을 옮겨도 유지) |
| `~/Library/Application Support/DuckViewer/chats/<sha256>.json` | 문서별 Claude 세션 ID, 세션 폴더, 대화 기록 |
| `~/.duckviewer/context.json` | 현재 읽기 상태 (파일, 페이지, 선택 텍스트, 페이지 본문, Claude 세션 ID) |
| `UserDefaults` (`com.dksung94.duckviewer`) | 설정, 읽은 위치, 최근 문서 |

## 구조

```
Sources/DuckViewer/
  DuckViewerApp.swift   앱 진입점, 메뉴, 파일 열기 처리
  AppState.swift        문서, 선택, 검색, 하이라이트, Claude 대화 상태 (+ DEBUG 훅)
  Claude.swift          프롬프트 템플릿, 프롬프트 생성, 셸 환경 해석, claude 스트리밍 실행(ClaudeRunner)
  Storage.swift         메모, 대화 기록, 읽은 위치, 최근 문서, 컨텍스트 파일
  MainView.swift        3단 레이아웃, 툴바
  Reader.swift          PDFView 서브클래스(우클릭 메뉴), 선택 액션 바, 시작 화면
  Sidebar.swift         썸네일, 목차, 메모, 검색 탭과 메모 시트
  AIPanel.swift         Claude 대화 화면, 입력부, 페이지 링크 Markdown 렌더링
  SettingsView.swift    Claude 설정, 프롬프트 템플릿 편집
scripts/bundle.sh       .app 번들 생성 + ad-hoc 서명
```
