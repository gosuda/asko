# asko

OCaml로 만드는 카카오톡 오픈채팅 대화 요약 봇. 카카오톡 연결은 Iris가 담당하며, 사용자가 멘션·메시지 답장·`/요약`으로 호출했을 때만 응답한다.

배포 대상은 루팅된 Android ARM64 기기다. PC에서 네이티브 바이너리를 크로스 컴파일하고 폰에 배포한다. Iris와 백엔드는 같은 폰의 루프백 HTTP로 통신한다. 폰에 OCaml 컴파일러나 별도 Linux 배포판을 설치하지 않는다.

## 구현 방향

- HTTP: Cohttp/Lwt
- 저장: SQLite. 방과 데이터 소스별로 분리해 조회한다.
- LLM: OpenRouter. 기본 모델은 `google/gemini-3.1-flash-lite`이며 설정으로 교체한다.
- UI: 카카오톡. 운영용 CLI와 설정 파일만 제공한다.

모델 기본값은 2026-09-16 기준 1M 컨텍스트와 입력/출력 100만 토큰당 $0.25/$1.50인 [Gemini 3.1 Flash Lite](https://openrouter.ai/google/gemini-3.1-flash-lite)를 선택했다. 가격은 코드의 과금 보장값으로 사용하지 않는다.

## 현재 구현

호출 판정, 고정 명령 해석, KST 날짜·이전 발언·답장 원본 기준의 요약 범위를 순수 OCaml 함수로 구현했다. 네트워크와 저장 계층은 뒤따르는 작업에서 연결한다.

```sh
ASKO_OCAMLOPT=/path/to/ocamlopt bash scripts/test-core.sh
```

개발 순서와 실제 기기 검증 범위는 [구현 계획](docs/implementation.md)에 기록한다. API 키와 실제 대화는 저장소에 커밋하지 않는다.
