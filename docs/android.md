# Android에서 빌드·검증·운영하기

PC는 Linux x86_64, 폰은 Android ARM64를 기준으로 한다. 개발·빌드는 PC에서 하고 폰에는 실행 파일과 CA 번들만 배포한다. 현재 스크립트는 Termux SSH 계정과 `/data/data/com.termux/files/home/asko` 경로를 사용한다.

## 개발 환경

```sh
./scripts/setup-dev.sh
make test
./scripts/setup-android.sh
make android
```

설치는 프로젝트의 `.cache/` 안에서 진행한다. 셸 프로필이나 시스템 패키지를 변경하지 않는다. Debian/Ubuntu에서 개발 헤더가 없으면 `apt-get download`로 GMP·SQLite 헤더를 가져와 로컬에 푼다. 해당 런타임 라이브러리는 호스트에 있어야 한다. `gcc`, `make`, `git`, `curl`, `tar`, `bzip2`, `xz`, `unzip`, `patch`, `python3`, `pkg-config`, `readelf`, `file`이 필요하다.

OCaml 5.4.1, opam 2.5.2, NDK r29, 고정된 Android 패키지 저장소 커밋을 사용한다. 일반 패키지는 `asko.opam.locked`를 따른다. Android용 SQLite 정적 라이브러리와 바인딩, GMP 문서 생성 생략 설정은 `opam/`에 있다. 빌드 도구와 소스까지 수 GB의 공간이 필요하다.

기존 도구를 재사용하려면 `ASKO_TOOLCHAIN_DIR=/path/to/toolchain`을 지정한다. opam 내부 샌드박스를 사용할 수 없는 제한된 러너에서만 `ASKO_DISABLE_OPAM_SANDBOX=1`을 명시한다. 기본 설정은 opam의 샌드박스를 유지한다.

## 실제 폰 검증

```sh
make test-android SSH_TARGET=asko-phone
```

ARM64 테스트 실행 파일을 폰에 보내 SQLite·HTTP·모의 Iris/OpenRouter 파이프라인을 실행한다. 공개 OpenRouter 모델 목록에 대한 HTTPS GET도 확인한다. 실제 카카오톡 송신과 과금 호출은 하지 않는다. 테스트 서버는 종료되며 테스트 바이너리는 `~/asko-runtime-test`에 남는다.

## 배포

```sh
make deploy SSH_TARGET=asko-phone
./scripts/control-phone.sh start asko-phone
./scripts/control-phone.sh status asko-phone
./scripts/control-phone.sh stop asko-phone
```

배포는 바이너리를 다시 빌드하고, 바이너리·CA·실행 스크립트의 SHA256을 확인한 릴리스로 `current` 링크를 바꾼다. 동일 릴리스는 검증 후 재사용한다. 기존 DB·실제 설정·비밀 파일을 덮어쓰지 않으며 실행 중인 프로세스도 자동 재시작하지 않는다. 새 코드로 바꾸려면 `control-phone.sh restart`를 사용한다. 이전 릴리스 경로는 `~/asko/previous-release`에 남는다.

첫 배포는 `dry_run=true`, 허용 방 목록이 빈 상태다. 일반 사용자로 루프백 `127.0.0.1:8080`에만 바인딩한다. `~/asko/run-phone.sh`는 TLS CA 번들과 비밀 파일을 읽고 프로세스를 실행한다.

## OpenRouter와 테스트 방 연결

폰의 `~/asko/config.local.json`에서 `api_key`에 OpenRouter 키를 넣는다. 기본 모델은 `qwen/qwen3.7-flash`, `reasoning_enabled`는 `false`, `response_format`은 `json_object`다. 설정 파일은 600 권한으로 유지하며 `check-config`는 키의 존재 여부만 출력한다. PC에서 만든 `config.local.json`은 일반 배포로 자동 전송하지 않는다.

키를 별도 파일에 두려면 기존 방식도 사용할 수 있다. SSH로 접속한 Bash에서 다음처럼 입력한다.

```sh
cd ~/asko
umask 077
read -rs -p 'OpenRouter API key: ' asko_key
printf '%s\n' "$asko_key" > secrets/openrouter.key
unset asko_key
```

`run-phone.sh`가 이 파일을 `OPENROUTER_API_KEY` 환경변수로 전달한다. 비어 있지 않은 환경변수는 설정 파일의 `api_key`보다 우선한다. 키는 로그나 DB에 저장하지 않으며 채팅이나 커밋에 넣지 않는다.

Iris 설치와 실행은 [Iris 공식 절차](https://github.com/dolidolih/Iris#시작하기)를 따른다. Iris의 `/query`·`/reply`·설정 API는 이 폰의 asko가 접근하는 용도다. 현재 Iris 서버의 외부 인터페이스 바인딩을 확인하고 운영 전에 접근을 제한해야 한다. 이번 구현 검증에서는 실제 Iris 설치나 네트워크 설정을 변경하지 않았다.

```sh
cd ~/asko
./run-phone.sh iris-info
./run-phone.sh check-config
```

`config.local.json`에 확인된 `bot_id`와 테스트 방 ID를 문자열로 넣는다. `rooms`에 없는 방은 저장·검색·응답 대상이 아니다. 실제 payload에서 `_id`와 네이티브 `id`, 멘션·답장 필드를 확인한다.

```sh
./run-phone.sh configure-iris
```

이 명령은 배포 시 생성한 토큰을 포함하는 루프백 수신 URL을 Iris에 설정한다. 토큰 값은 출력하지 않는다. 이후 PC에서 `control-phone.sh restart`로 설정을 반영한다.

먼저 dry-run에서 호출 세 방식을 시험하고 `./run-phone.sh outbox`로 결과·근거를 확인한다. 키가 있는 dry-run은 실제 모델을 호출하므로 과금될 수 있다. 송신을 시험할 준비가 되면 `dry_run=false`로 바꾸고 재시작한다. 실제 호출 예시는 README에 있다.

## 재시작과 부팅

사용자 권한의 supervisor는 중복 실행을 막고 백엔드가 종료되면 5초 후 재시작한다. `control-phone.sh stop`은 `var/disabled`를 남기므로 다음 부팅에도 정지 상태를 유지한다. `start`는 이 표시를 지운다.

실제 운영 설정이 끝난 뒤 부팅 자동 실행을 설치할 수 있다.

```sh
./scripts/install-boot-service.sh asko-phone
```

이 명령은 Magisk 루트 권한이 필요하다. 최초 실행 시 폰에서 Termux의 루트 요청을 허용해야 할 수 있다. `/data/adb/service.d/asko-backend.sh`는 첫 잠금 해제 후 Termux UID로 supervisor를 실행한다. 이미 등록된 SSH 부팅 서비스는 수정하지 않는다. 동일 이름의 다른 스크립트도 덮어쓰지 않는다. 이 설치 명령과 폰 전체 재부팅은 실제 운영 전에 별도로 확인한다.

## 백업과 보관

```sh
./scripts/backup-phone.sh asko-phone
```

실행 중 DB를 `VACUUM INTO`로 일관된 단일 파일에 백업하고 PC의 `.cache/backups`로 가져온다. 양쪽 SHA256이 같을 때만 폰의 임시 백업을 지운다. `ASKO_BACKUP_DIR`로 PC 저장 위치를 바꿀 수 있다. 기존 백업 파일은 덮어쓰지 않는다. 백업의 보관·삭제 주기는 운영자가 별도로 관리한다.

원문은 기본 7일 보관한다. 알려진 수정·삭제나 보관 만료가 반영되면 임베딩·생성 결과를 무효화한다. 30분마다 완전한 원본 조회가 성공했을 때만 사라진 메시지를 표시하며, 실패한 페이지 조회만으로 삭제하지 않는다. 이미 전송된 카카오톡 메시지는 자동으로 삭제하지 않는다.

카카오톡 DB가 재생성되어 `_id`가 다시 사용되거나 수집 커서가 뒤로 가면 `source_id`의 세대 값을 바꿔야 한다. 이전 세대의 ID를 새 대화와 섞지 않는다.

## 현재 검증의 한계

- 실제 기기의 네이티브 실행, SQLite, HTTP, TLS와 모의 파이프라인은 검증했다.
- 실제 Iris payload와 카카오톡 수신·송신은 지정된 테스트 방에서 확인해야 한다.
- 실제 OpenRouter 분류·요약 품질과 비용은 API 키를 설정한 후 평가한다.
- 모델의 근거 ID가 유효한지는 검사하지만, 문장 의미가 근거와 완전히 일치한다는 보장은 아니다.
- Android 장시간 절전·재부팅·네트워크 전환 시험은 별도다.
