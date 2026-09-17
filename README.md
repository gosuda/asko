# asko

OCaml로 만드는 카카오톡 오픈채팅 대화 요약 봇. 카카오톡 연결은 Iris가 담당하며, 사용자가 멘션·메시지 답장·`/요약`으로 호출했을 때만 응답한다.

배포 대상은 루팅된 Android ARM64 기기다. PC에서 네이티브 바이너리를 크로스 컴파일하고 폰에 배포한다. Iris와 백엔드는 같은 폰의 루프백 HTTP로 통신한다. 폰에 OCaml 컴파일러나 별도 Linux 배포판을 설치하지 않는다.

## 구현 방향

- HTTP: Cohttp/Lwt
- 저장: SQLite. 방과 데이터 소스별로 분리해 조회한다.
- LLM: OpenRouter. 기본 모델은 `qwen/qwen3.7-flash`이며 설정으로 교체한다.
- UI: 카카오톡. 운영용 CLI와 설정 파일만 제공한다.

기본값은 [Qwen3.7 Flash](https://openrouter.ai/qwen/qwen3.7-flash), 추론 활성화(`reasoning_enabled=true`)다. 이 모델은 JSON 모드를 지원하지만 JSON 스키마 강제는 지원하지 않으므로 `response_format=json_object`로 요청하고 OCaml에서 응답 형식과 근거를 검사한다. 스키마를 지원하는 다른 모델을 쓸 때는 `json_schema`로 바꿀 수 있다. 추론 설정은 OpenRouter의 [reasoning 옵션](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)에 전달한다.

임베딩은 폰 내부 `http://127.0.0.1:8081/v1`의 Jina v5 Nano retrieval Q8 서버를 사용한다. OpenRouter 키는 요약·의도 분류에만 사용한다. 검색 질의에는 `Query: `, 대화에는 `Document: ` 접두사를 붙인다. 추론 예산은 기본 2,048토큰이며 응답 토큰 한도에 별도로 더한다.

## 현재 구현

호출 판정과 범위 계산, Iris JSON 정규화, SQLite 메시지·작업·전송 대기열, 루프백 HTTP 수신을 구현했다. OpenRouter 의도 분류·요약·임베딩 검색과 순차 전송 worker도 연결했다. 메시지 수신과 작업 생성은 한 트랜잭션으로 처리한다. 재시작 중 전송이 끊긴 작업은 확인 없이 재전송하지 않는다.

기간 요약은 범위 안의 대화를 구간별로 모두 처리하며, 처리 예산을 넘으면 범위를 줄이도록 안내한다. 주제 요약은 의미 검색과 키워드 검색을 결합하고 앞뒤 발언·답장 관계를 확장한다. 모델이 반환한 근거 ID가 실제 선택된 메시지에 속하는지 검증한다. 임베딩 실패로 키워드 검색만 사용한 경우 답변에 표시한다.

`daily_budget_tokens`는 UTF-8 요청 바이트 수와 최대 출력 토큰을 호출 전에 예약하는 보수적인 일일 예산이다. 실제 청구 토큰이나 금액과 같지 않다. 실패한 요청도 예산을 사용하며, `dry_run`은 카카오톡 송신만 차단한다. 키가 설정되어 있으면 dry-run에서도 모델 호출 요금이 발생할 수 있다.

## 호출 예시

```text
@요약봇 잠깐 못봤는데 뭐 있었음
@요약봇 오늘 중요한거
@요약봇 아까 postgres 얘기 결론 뭐임
[메시지 답장] 여기부터 요약
/요약 오늘
/요약 2시간
```

“못 본 동안”은 이 방에서 사용자의 이전 일반 발언 이후를 뜻한다. 읽음 시각은 추정하지 않는다. 이전 발언이 없으면 최근 1시간으로 제한하고 답변에 표시한다. 답장 요약은 원본 메시지를 포함하며, 모든 범위는 호출 시점에서 끝난다.

## 개발과 배포

```sh
make setup
make test
make setup-android
make test-android SSH_TARGET=asko-phone
make deploy SSH_TARGET=asko-phone
```

Linux x86_64에서 프로젝트 전용 도구와 의존성을 `.cache/`에 설치한다. 일반 opam 환경에서는 OCaml 5.4.1, GMP·SQLite 개발 라이브러리를 준비한 뒤 `opam install . --deps-only --locked`와 `dune build`를 사용한다.

```sh
cp config.example.json config.local.json
./scripts/dev dune exec asko -- check-config --config config.local.json
./scripts/dev dune exec asko -- serve --config config.local.json
```

OpenRouter 키는 `config.local.json`의 `api_key`에 넣는다. 비어 있지 않은 `OPENROUTER_API_KEY` 환경변수가 있으면 그 값이 우선한다. `config.local.json`은 Git에서 제외하며 `chmod 600 config.local.json`으로 접근 권한을 제한한다. `check-config`는 키 자체 대신 설정 여부만 표시한다. 폰에서 실행할 때는 폰의 `~/asko/config.local.json`에 설정한다. 일반 배포는 기존 설정을 보존하므로 PC의 로컬 설정을 자동 복사하지 않는다.

`status`는 큐 상태를, `outbox`는 최근 결과와 근거 메타데이터를 운영자에게 보여준다. 두 명령도 `--config`를 받는다. 원문 수정·삭제·만료가 반영되면 관련 임베딩과 생성 결과를 무효화한다. 이미 카카오톡에 전송한 메시지를 자동 삭제하는 기능은 없다.

수집 커서와 별도로 주기적인 원본 재조회를 수행한다. 모든 페이지를 확인한 경우에만 사라진 메시지를 삭제 표시하며, 늦게 도착한 중복 이벤트로 삭제된 내용을 복원하지 않는다. 네이티브 메시지 ID가 바뀐 채 로컬 순번이 재사용되면 소스 세대를 확인해야 한다.

`backup --output 새파일.sqlite`는 실행 중 DB의 일관된 스냅샷을 만들며 기존 파일을 덮어쓰지 않는다. DB 상대 경로는 설정 파일 위치를 기준으로 해석한다.

기본값은 허용 방이 없는 dry-run이다. `rooms`에 방 ID를 넣어야 저장하며, 실제 송신에는 정확한 `bot_id`도 필요하다. `ASKO_INGEST_TOKEN`을 설정하면 Iris 전달 URL의 `token` 쿼리 매개변수 또는 `X-Asko-Token` 헤더가 일치해야 수신한다. 설정되지 않은 경우 루프백 연결을 신뢰하므로 이 기기에서 실행하는 앱도 신뢰하는 구성을 전제로 한다.

폰에서 전체 테스트와 공개 API에 대한 HTTPS 연결을 확인했다. 실제 Iris/카카오톡 송수신과 유료 모델의 요약 품질은 아직 검증하지 않았다. 연결 설정·시작/정지·부팅·백업은 [Android 운영 문서](docs/android.md), 개발 순서와 검증 범위는 [구현 기록](docs/implementation.md)을 참고한다. API 키와 실제 대화는 저장소에 커밋하지 않는다.
