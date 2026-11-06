# 01. 요구사항 정의 및 경쟁 제품 분석

- 작성일: 2026-10-23
- 상태: 초안 (v0.1), 구현 현황은 맨 아래 9장
- 플랫폼: macOS 네이티브 우선 (Swift / SwiftUI / PDFKit)

---

## 1. 제품 한 줄 정의

> **DuckViewer**: PDF 텍스트를 사용자가 지정한 **AI CLI**(예: `claude -p`)에 바로 넘겨 요약하고 질문하는 걸 앱 안에서 해결하는, **AI 친화적 독서용 PDF 뷰어** (macOS).

핵심 철학:
- **AI 공급자에 종속되지 않는다.** 앱은 AI를 직접 부르지 않고, 사용자가 설정한 터미널 명령어를 실행한다.
- **읽기 흐름을 끊지 않는다.** 뷰어, 메모, AI, 터미널이 한 창 안에 있다.
- **데이터는 로컬에 평문으로 둔다.** 메모와 AI 결과를 사람과 AI 둘 다 읽을 수 있는 형식으로 저장한다.

---

## 2. 원하는 기능 (요구사항)

우선순위: **P0** = MVP 필수, **P1** = MVP 직후, **P2** = 나중에

### 2.1 PDF 뷰어 (독서용)
| ID | 기능 | 우선순위 |
|---|---|---|
| V-1 | PDF 열기 (메뉴, 드래그앤드롭, 최근 파일) | P0 |
| V-2 | 페이지 이동, 확대/축소, 단면/양면/연속 스크롤 | P0 |
| V-3 | 목차(Outline)와 썸네일 사이드바 | P0 |
| V-4 | 문서 내 텍스트 검색 | P0 |
| V-5 | 마지막으로 읽은 위치 기억 | P0 |
| V-6 | 다크 모드 / 읽기 모드 (배경색 반전·세피아) | P1 |
| V-7 | 키보드 중심 조작 (vim 스타일 단축키 옵션) | P2 |

### 2.2 메모
| ID | 기능 | 우선순위 |
|---|---|---|
| N-1 | 페이지 단위 메모 작성 | P0 |
| N-2 | 텍스트 하이라이트 + 하이라이트에 메모 달기 | P0 |
| N-3 | 메모 목록 패널 (클릭하면 해당 위치로 이동) | P0 |
| N-4 | 원본 PDF를 바꾸지 않는 **사이드카 저장** (JSON/Markdown) | P0 |
| N-5 | 메모를 Markdown으로 내보내기 (Obsidian 등에서 바로 쓰기) | P1 |
| N-6 | AI 결과를 메모로 저장 (출처 페이지 포함) | P0 |

### 2.3 AI 명령어 설정 (AI 친화성의 핵심)
| ID | 기능 | 우선순위 |
|---|---|---|
| A-1 | AI 실행 명령어 설정 (기본값 `claude -p`, `codex exec`, `gemini -p`, `ollama run ...` 등 자유롭게) | P0 |
| A-2 | 프롬프트는 **stdin**으로 전달 (길이 제한·따옴표 문제 회피). `{prompt}`, `{file}`, `{page}` 같은 치환 변수도 지원 | P0 |
| A-3 | 응답을 **스트리밍**으로 표시, 중간에 취소 가능 | P0 |
| A-4 | 사용자 정의 **프롬프트 템플릿** (요약, 설명, 번역, 퀴즈 등) | P1 |
| A-5 | 로그인 셸 환경(`zsh -lc`)으로 실행해서 PATH 문제 해결 | P0 |
| A-6 | 여러 AI 프로필 저장 후 전환 | P2 |

### 2.4 AI 작업 범위
| ID | 기능 | 우선순위 |
|---|---|---|
| S-1 | **현재 페이지** 요약 | P0 |
| S-2 | **드래그한 텍스트** 요약 / 설명 / 번역 | P0 |
| S-3 | **페이지 범위** 요약 (예: 12–30쪽) | P0 |
| S-4 | 문서 전체 / 장(Chapter) 단위 요약 (목차 기반) | P1 |
| S-5 | AI 응답의 페이지 근거 표시 (`p.12` 클릭하면 해당 페이지로 이동) | P1 |
| S-6 | 스캔본 PDF 대응 (Vision 프레임워크 OCR, 또는 페이지 이미지를 CLI에 전달) | P2 |

### 2.5 내장 터미널
| ID | 기능 | 우선순위 |
|---|---|---|
| T-1 | 앱 안에 실제 셸 터미널 패널 (SwiftTerm 사용) | P0 |
| T-2 | 터미널 작업 디렉터리를 PDF가 있는 폴더로 시작 | P0 |
| T-3 | **현재 읽기 상태를 컨텍스트 파일로 노출** (현재 파일, 페이지, 선택 텍스트) → 터미널의 AI가 "지금 보는 거"를 바로 참조 | P0 |
| T-4 | 선택 텍스트나 현재 페이지를 터미널로 보내기 버튼 | P1 |
| T-5 | 터미널 패널 위치 (아래 / 오른쪽) 전환, 숨기기 | P1 |

### 2.6 비기능 요구사항
- 원본 PDF는 기본적으로 수정하지 않는다.
- 네트워크 호출은 앱이 직접 하지 않는다 (사용자가 설정한 CLI만 실행).
- 큰 PDF(수백 쪽)에서도 페이지 범위 텍스트 추출이 빠를 것.
- 저장소는 Xcode 프로젝트 파일 없이 **SwiftPM 기반**으로 구성해서, 명령줄과 AI 에이전트로도 빌드하기 쉽게 한다.

---

## 3. 경쟁 제품 분석

### 3.1 한눈에 보기
| 제품 | 플랫폼 | 성격 | AI 방식 | 가격 |
|---|---|---|---|---|
| **SumatraPDF 3.7 (pre-release)** | Windows | 경량 오픈소스 뷰어 | **로컬 Claude Code CLI**로 채팅 사이드바 | 무료 |
| **PDF Expert** (Readdle) | Mac, iOS | 고급 PDF 편집기 | 자체 클라우드 AI (Chat with PDF) | 구독 (크레딧 제한) |
| **Adobe Acrobat AI Assistant** | 전 플랫폼 | 업계 표준 편집기 | 자체 클라우드 AI | 애드온 구독 |
| **UPDF** | 전 플랫폼 | 편집기 + AI | 클라우드 (GPT, DeepSeek 계열) | 구독 |
| **PDF Pals** | Mac | 네이티브 AI PDF 채팅 앱 | 사용자 API 키 (OpenAI, OpenRouter 등) | 일회성 결제 |
| **Readwise Reader** (Ghostreader) | 웹, Mac, 모바일 | 읽기 + 하이라이트 서비스 | 클라우드 AI, 선택 영역 프롬프트 | 구독 |
| **MarginNote 4** | Mac, iOS | 학습용 리더 + 마인드맵 | 클라우드 LLM 또는 Apple Intelligence | 부분 유료 |
| **Zotero 7 + llm-for-zotero** | 전 플랫폼 | 논문 관리 + 리더 | 플러그인 (API, 로컬 모델, Claude Code 백엔드) | 무료 |
| **Skim** | Mac | 오픈소스 노트 중심 리더 | 없음 | 무료 |
| **Highlights** | Mac, iOS | 하이라이트 추출 특화 | 확인된 AI 기능 없음 | 유료 |
| **Sioyek** | 전 플랫폼 | 논문용 키보드 중심 뷰어 | 없음 (외부 스크립트 확장 가능) | 무료 |

### 3.2 제품별 핵심 기능

**SumatraPDF: 가장 직접적인 경쟁자 (단, Windows 전용)**
- 문서 옆 채팅 사이드바에서 질문하면 로컬에 설치된 `claude` CLI가 답한다. 파일을 SumatraPDF 서버로 보내지 않는다.
- 탭(문서)마다 별도 채팅 세션, 이전 세션 선택, 모델과 effort 선택, 응답 중단.
- `--dangerously-skip-permissions` 옵션 토글 제공 (보안 경고 포함).
- 한계: Claude Code에 고정 (다른 CLI 선택 불가), 페이지 범위나 선택 영역 같은 **구조화된 작업 단위가 없음**, 메모 기능 약함, Windows 전용.

**PDF Expert**
- AI 버튼으로 문서 요약, 핵심 포인트, 반복 주제 분석, 키워드·해시태그 생성, 자유 질문.
- 한계: 구독자 전용, 크레딧 제한 (체험 50 / 구독 200), 클라우드 의존, AI 모델 선택 불가.

**Adobe Acrobat AI Assistant**
- 문서 개요 + 섹션별 요약, **답변에 출처 인용 (클릭하면 해당 페이지로 이동하고 강조 표시)**, 질문 추천, 이메일·보고서용 문장 생성.
- 한계: 유료 애드온, 클라우드 전송, 무거운 앱.

**UPDF**
- **특정 페이지 / 선택한 페이지 / 붙여넣은 텍스트** 단위 요약, 페이지·문단 단위 번역, 이미지와 대화, PDF를 마인드맵으로 변환.
- 한계: 클라우드 구독, 편집기 중심이라 독서 경험은 부차적.

**PDF Pals**
- Mac 네이티브, 파일을 로컬에서 처리, 사용자가 자기 API 키를 사용 (BYOK), 일회성 결제.
- 한계: API 방식만 지원 (CLI 에이전트 생태계 활용 불가), 터미널 없음.

**Readwise Reader (Ghostreader)**
- 선택 영역에서 정의, 번역, 설명, 요약, 플래시카드 생성 + **사용자 정의 프롬프트 템플릿**.
- 2026년 8월 업데이트: 전체 라이브러리 색인 후 인용 포함 답변, 모바일 문서 채팅.
- 한계: 클라우드 서비스 구독, PDF는 주력이 아님.

**MarginNote 4**
- AI 책 분해, AI 번역, AI Q&A, AI 플래시카드, 마인드맵, 수식·차트 추출.
- 클라우드 LLM과 기기 내 Apple Intelligence 중 선택 가능.
- 한계: 학습 도구로서 복잡함, 가볍게 읽기에는 과함.

**Zotero 7 + llm-for-zotero**
- 리더 사이드바에서 논문 요약, 그림 분석, 자료 비교, 노트 저장. API, 로컬 모델, **Claude Code 백엔드**까지 지원.
- 한계: 논문 관리가 주목적이라 일반 독서용으로는 무겁고, 플러그인 설치가 필요.

**Skim / Highlights / Sioyek: AI는 없지만 독서 UX 참고 대상**
- Skim: 원본 PDF를 바꾸지 않는 노트, 노트 목록 패널, 페이지 번호가 붙은 노트 텍스트 내보내기.
- Highlights: Markdown, TextBundle 내보내기, **PDF 옆에 사이드카 Markdown 파일 자동 저장**, Obsidian 연동, BibTeX 인용.
- Sioyek: 링크 없는 PDF에서도 그림·참고문헌으로 이동 (Smart Jump), 미리보기 (Overview), 마크와 북마크, 읽기 줄자 (Ruler mode), 외부 스크립트 확장.

### 3.3 기능 비교 매트릭스

● 지원 / ◐ 부분 지원 / ○ 미지원

| 기능 | DuckViewer (목표) | SumatraPDF | PDF Expert | Acrobat | UPDF | PDF Pals | Readwise | Zotero+플러그인 | Skim |
|---|---|---|---|---|---|---|---|---|---|
| macOS 네이티브 | ● | ○ | ● | ◐ | ◐ | ● | ◐ | ◐ | ● |
| AI CLI 자유 선택 | ● | ◐ (claude만) | ○ | ○ | ○ | ○ | ○ | ◐ | ○ |
| 클라우드 구독 불필요 | ● | ● | ○ | ○ | ○ | ● | ○ | ● | ● |
| 현재 페이지 요약 | ● | ◐ (채팅으로) | ◐ | ● | ● | ◐ | ○ | ◐ | ○ |
| 선택 영역 요약/설명 | ● | ○ | ◐ | ● | ● | ◐ | ● | ◐ | ○ |
| 페이지 범위 요약 | ● | ○ | ○ | ◐ | ● | ○ | ○ | ○ | ○ |
| 답변에 페이지 출처 | ◐ (P1) | ? | ○ | ● | ? | ? | ● | ? | ○ |
| 프롬프트 템플릿 | ● (P1) | ○ | ○ | ◐ | ○ | ? | ● | ◐ | ○ |
| 내장 터미널 | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| 읽기 상태를 외부 AI에 노출 | ● | ○ | ○ | ○ | ○ | ○ | ○ | ◐ (MCP) | ○ |
| 메모 (원본 보존) | ● | ○ | ◐ | ◐ | ◐ | ○ | ● | ● | ● |
| Markdown 내보내기 | ● (P1) | ○ | ◐ | ○ | ○ | ? | ● | ◐ | ◐ |

`?`는 이번 조사에서 확인하지 못한 항목이다.

---

## 4. 우리가 받아들일 기능

| 출처 | 받아들일 기능 | 반영 위치 |
|---|---|---|
| SumatraPDF | 로컬 CLI 실행, 문서별 세션, **응답 중단**, 위험 옵션은 명시적 토글 + 경고 | A-1, A-3, T-1 |
| UPDF | **페이지 / 페이지 범위 / 선택 텍스트** 3단 작업 범위 | S-1, S-2, S-3 (원래 요구와 일치) |
| Acrobat | **답변의 페이지 인용 → 클릭하면 이동** | S-5 |
| Readwise Ghostreader | 선택 영역 컨텍스트 메뉴 (요약, 설명, 번역, 정의) + **사용자 프롬프트 템플릿** | S-2, A-4 |
| PDF Pals | AI 백엔드를 사용자가 고르는 구조, 구독 없음 | A-1 |
| Skim | 원본 PDF를 건드리지 않는 메모 + 메모 목록 패널 | N-3, N-4 |
| Highlights | 사이드카 Markdown 저장, Obsidian 친화적 내보내기 | N-4, N-5 |
| Sioyek | 키보드 중심 조작, 마크와 북마크 (나중 단계) | V-7 |
| Zotero MCP / Annota | 외부 AI가 앱 상태와 메모를 읽을 수 있는 인터페이스 → 우리는 우선 **컨텍스트 파일**로, 나중에 MCP 서버로 확장 | T-3, (P2: MCP) |

## 5. 받아들이지 않을 기능 (적어도 당분간)

| 기능 | 제외 이유 |
|---|---|
| 자체 클라우드 AI, 계정, 크레딧 | 핵심 철학(CLI 위임, 공급자 비종속)과 충돌 |
| PDF 편집 (텍스트 수정, 변환, 서명, 양식) | 독서용 앱이라는 범위를 벗어남. PDF Expert나 Acrobat 영역 |
| 마인드맵, 플래시카드 학습 시스템 | MarginNote 영역. 복잡도 대비 핵심 가치가 낮음 |
| 라이브러리 전체 색인, RAG | MVP 범위 초과. 필요하면 터미널의 AI 에이전트가 직접 처리 |
| 모바일 앱 | 맥 네이티브 우선. 모바일은 CLI 실행이 불가하므로 별도 설계 필요 |

---

## 6. 차별화 포인트

1. **"아무 AI CLI나" 붙는 macOS 뷰어.** SumatraPDF는 Windows 전용에 Claude Code 고정, Mac 앱들은 자체 클라우드나 API 키 방식이다.
2. **구조화된 AI 작업 + 자유 대화 동시 지원.** 버튼 한 번으로 페이지·선택·범위 요약을 하고, 옆 터미널에서는 에이전트와 자유롭게 대화한다.
3. **읽기 상태를 AI에 노출.** 컨텍스트 파일(현재 PDF, 페이지, 선택 텍스트)을 통해 터미널의 `claude` 같은 에이전트가 "지금 내가 보는 부분"을 바로 안다. 어떤 경쟁 제품도 이걸 하지 않는다.
4. **로컬 평문 데이터.** 메모와 AI 결과가 사이드카 파일로 남아서 Obsidian, git, AI 에이전트가 그대로 읽을 수 있다.

---

## 7. 기술 방향 (요약)

| 영역 | 선택 |
|---|---|
| 언어 / UI | Swift, SwiftUI (+ 필요한 곳은 AppKit) |
| PDF 렌더링, 텍스트 추출 | PDFKit (`PDFView`, `PDFPage.string`, `PDFSelection`) |
| 내장 터미널 | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) `LocalProcessTerminalView` |
| AI 실행 | `Process`로 `zsh -lc "<사용자 명령어>"` 실행, 프롬프트는 stdin, 출력은 스트리밍 |
| 메모 저장 | `~/Library/Application Support/DuckViewer/` 아래 문서 해시별 JSON (+ Markdown 내보내기) |
| 컨텍스트 노출 | `~/.duckviewer/context.json` (현재 파일, 페이지, 선택 텍스트) |
| 빌드 | SwiftPM + `.app` 번들 생성 스크립트 (Xcode 프로젝트 파일 없음) |
| 최소 OS | macOS 14 이상 |

---

## 8. 출처

- SumatraPDF, AI Chat with document: https://www.sumatrapdfreader.org/docs/AI-Chat-with-document
- SumatraPDF 뉴스 (3.7 pre-release): https://www.sumatrapdfreader.org/news.html
- PDF Expert, AI Chat with PDF: https://support.readdle.com/pdfexpert/de_DE/reading-pdfs/ai-chat-with-pdf
- PDF Expert 리뷰 (2026): https://thesweetbits.com/pdf-expert-review/
- Adobe Acrobat AI Assistant (CNBC, 2024): https://www.cnbc.com/2024/02/20/adobe-launches-ai-assistant-that-can-search-and-summarize-pdfs.html
- Adobe Acrobat AI Assistant 정식 출시 (2024): https://www.businesswire.com/news/home/20240415994050/en
- UPDF AI 출시: https://updf.com/news/updf-ai-is-released/
- PDF Pals (G2): https://www.g2.com/sellers/pdf-pals
- Readwise Reader 2026년 8월 업데이트: https://readwise.io/reader/update-aug2026
- MarginNote 4 (App Store): https://apps.apple.com/us/app/marginnote-4-ai-notes-mindmap/id1531657269
- llm-for-zotero: https://github.com/yilewang/llm-for-zotero
- Skim 위키: https://skim-app.sourceforge.net/wiki
- Highlights (App Store): https://apps.apple.com/us/app/highlights-extract-pdf-notes/id1498912833
- Sioyek: https://github.com/Jusb3/sioyek

> 참고: Acrobat 관련 자료는 2024년 기준이고, 일부 제품의 가격·모델 정보는 바뀌었을 수 있다. 매트릭스의 `?` 항목은 추가 확인이 필요하다.

---

## 9. 구현 현황 (2026-11-06, v0.2)

| 상태 | 항목 |
|---|---|
| 완료 | V-1 ~ V-6, N-1 ~ N-6, A-1 ~ A-5, S-1 ~ S-5, T-1 ~ T-5 |
| 일부 | A-6 (프로필 저장 대신 명령어 프리셋) |
| 남음 | V-7 키보드 중심 조작, S-6 스캔본 OCR |

UI 설계는 [02_ui_design.md](02_ui_design.md) 참고.
