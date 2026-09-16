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

호출 판정과 범위 계산, Iris JSON 정규화, SQLite 메시지·작업·전송 대기열, 루프백 HTTP 수신을 구현했다. 메시지 수신과 작업 생성은 한 트랜잭션으로 처리한다. 재시작 중 전송이 끊긴 작업은 확인 없이 재전송하지 않는다. 요약과 전송 worker는 뒤따르는 작업에서 연결한다.

```sh
ASKO_OCAMLOPT=/path/to/ocamlopt bash scripts/test-core.sh
```

일반 개발 환경에서는 OCaml 5.4.1, GMP·SQLite 개발 라이브러리를 준비한 뒤 `opam install . --deps-only`와 `dune build`를 사용한다. 프로젝트 전용 opam 환경을 사용하는 경우 `scripts/dev dune runtest`로 검증한다.

```sh
cp config.example.json config.local.json
dune exec asko -- check-config --config config.local.json
dune exec asko -- serve --config config.local.json
```

기본값은 허용 방이 없는 dry-run이다. `rooms`에 방 ID를 넣어야 저장하며, 실제 송신에는 정확한 `bot_id`도 필요하다. `ASKO_INGEST_TOKEN`을 설정하면 Iris 전달 URL의 `token` 쿼리 매개변수 또는 `X-Asko-Token` 헤더가 일치해야 수신한다. 설정되지 않은 경우 루프백 연결을 신뢰하므로 이 기기에서 실행하는 앱도 신뢰하는 구성을 전제로 한다.

개발 순서와 실제 기기 검증 범위는 [구현 계획](docs/implementation.md)에 기록한다. API 키와 실제 대화는 저장소에 커밋하지 않는다.
