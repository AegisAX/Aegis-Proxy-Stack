# open-appsec 기본 모델 WAF 검증 빌드

이 레시피는 Linux/amd64 환경에서 open-appsec HTTP transaction handler에 Boost.Regex 수정 사항을 반영하고, 테스트한 바이너리와 동일한 설치기와 Docker 이미지를 만드는 데 사용합니다. Advanced 모델, 사용자 등록 정보, 사설 이미지와 실행 파일은 입력 패키지에 포함하지 않습니다.

| 고정 입력·산출물 | SHA 또는 버전 |
|---|---|
| open-appsec 소스 / Git tree | `f562a28d37f25a0a60221517f4f44f50ff940e50` / `e8bcdd6b286c6318e1553e3a2a8b44faaed5c803` |
| Boost.Regex 원본 → 서명된 PR 204 merge | `237e69caf65906d0313c9b852541b07fa84a99c1` → `b8e58068ffbad37a9da9a2c5e4decbeeb3361fed` |
| 헤더 patch SHA-256 | `ba098c1ddca4af893b26a5ecf2b692730c1f753ff9d5ec05223ce445a9930568` |
| Alpine 3.21 빌드 베이스 | `alpine@sha256:2d8a11041a92082ba21e364dec73559ce44f1de69b60fa68315f6d3774e59117` |
| Linux/amd64 베이스 Docker config | `sha256:e50d940e9d2c4d81e5b3506b2ed87bfc7e91267b36ff016eb4b4cb21c39a3331` |
| Ubuntu Noble amd64 ninja-build 1.11.1-2 DEB | `6a17f76a0f75586f1292f6c61a9b07fd0dec963baf6a102b17673f601c6b323a` |
| 기존 사설 에이전트 Docker config | `sha256:f0aabe74c1d1d6a2a676fe39fa10d233bcdefe657ae9047e06ef474fc4567329` |
| CMake install 완료 WAF ELF | `a4d07f54fe3c3f5c553aad98550e9980ebe57b7f1213bf3f2b9e40f111e323c2` |
| 기본 모델 설치 파일 waap.data | `fa59e952a0559376ba3b5a90211881a4b0bfd15f47dbb30101587c8365064e87` |
| 변경한 makeself 설치기 | `73de7db602db5a61c26a529d3c0c0523481ba0462e0e7c2e7feee4a13091fb2b` |
| 새 레이어 diff ID | `sha256:9a2977743728fa1406a20d375d79dad1945f250deb9928837408a120d9776696` |
| 동결한 최종 Docker config | `sha256:688af57069acc05bc6389a50e47b8c7a7401a4b457681ca587c16669bcbc7e52` |

## 입력 확보

서명 검증용 GnuPG 키는 신뢰할 수 있는 배포 경로에서 독립 확인합니다. 두 Git 커밋의 GitHub web-flow 서명 키 지문은 `968479A1AFF927E37D1A566BB5690EEEBB952194`입니다. Alpine v3.21 main/community에서 `APK.SHA256`에 명시된 139개 파일을 확보합니다. 베이스 이미지에 포함된 Alpine 공개 키로 모든 APK 서명을 별도 확인합니다. Ubuntu Noble universe의 amd64 Packages에 기록된 Ninja 파일 SHA를 확인하고 Packages와 Ubuntu Archive 2018 서명 InRelease 사이의 지문 연결도 확인합니다. 이 Ubuntu 서명 키 지문은 `F6ECB3762474EDA9D21B7022871920D1991BC93C`입니다. 당시 사용한 패키지 바이트가 현재 미러에 없어도 파일 이름이나 버전을 바꿔 대체하면 빌드가 중단됩니다. [open-appsec 소스와 기본 모델](https://github.com/openappsec/openappsec/tree/f562a28d37f25a0a60221517f4f44f50ff940e50) · [Boost.Regex PR 204](https://github.com/boostorg/regex/pull/204) · [Alpine v3.21](https://dl-cdn.alpinelinux.org/alpine/v3.21/) · [Ubuntu Ninja](https://packages.ubuntu.com/noble/ninja-build)

기존 사설 에이전트 `f0aabe74…`는 이전 단계에서 동결한 사본을 별도로 확보해 같은 Docker 엔진에 로드해야 합니다. Docker config ID만으로 레지스트리에서 이미지를 받을 수 없습니다. 현재 레시피는 공식 에이전트에서 이 사설 부모까지의 이미지 이력을 재생성하지 않습니다. 공급자 등록이 필요한 기능 시험에는 별도 테스트용 등록과 해당 공급자 목적지로 제한한 연결이 필요합니다.

## 오프라인 컴파일과 이미지 만들기

Docker, Git, GnuPG, GNU binutils, dpkg-deb, POSIX cksum이 설치된 전용 Linux/amd64 호스트에서 실행합니다. 관찰과 별도 디스크를 사용하는 빌드 호스트를 권장합니다. 빌드 계정은 일반 사용자여야 하며 UID와 GID가 베이스 컨테이너에 이미 할당돼 있으면 중단됩니다. 스크립트는 네트워크를 차단하고 CPU 1개와 메모리 3 GiB로 제한한 컨테이너에서 검증한 소스를 컴파일합니다. 이미지 동결 검증에 사용한 호스트는 Ubuntu 24.04, Python 3.12.3입니다. gzip 헤더나 zlib 구현이 달라 출력 바이트가 바뀌면 동결 단계에서 이를 검출합니다.

```sh
sha256sum -c SHA256SUMS
./build.sh /input/openappsec-git /input/boost-regex-git /input/official-apks \
  /input/ninja-build_1.11.1-2_amd64.deb /scratch/new-build
python3 freeze.py \
  /scratch/new-build/work/installed/http_transaction_handler_service/bin/cp-nano-http-transaction-handler \
  /scratch/basic-waf.tar
```

`build-inner.sh`는 오리지널 빌드의 공개 버전 헤더에 들어간 생성 시각을 고정하고 헤더 전체 SHA를 검증합니다. Release C/C++ 플래그는 `-O2 -DNDEBUG`입니다. GraphQL 라이브러리가 생성한 두 헤더의 SHA를 확인하고, 생성 디렉터리와 공식 소스 디렉터리를 C++ 헤더 탐색 경로에 포함합니다. `ParserGql.cc.o`를 먼저 컴파일해 해당 설정을 확인한 다음 HTTP transaction handler 전체를 빌드하고 CMake 설치 규칙을 실행합니다. `verify-deps.py`는 실제 `.ninja_deps`에서 보완 헤더를 사용한 WAAP 오브젝트 31개를 찾아, 같은 바이트가 들어 있는 정적 라이브러리와 최종 링크 명령을 확인합니다. 원본에 포함된 Samurai는 Ninja의 deps 하위 명령을 지원하지 않아 검증 단계에서 Ubuntu Ninja를 사용합니다. `freeze.py`는 원래 설치기의 64개 항목 중 ELF 하나를 교체하고 설치기, 단일 레이어, 최종 config SHA가 모두 일치할 때 새 무태그 아카이브를 저장합니다. 레지스트리 업로드는 별도의 배포 절차입니다.

## 기능 확인과 정상 트래픽 관찰

비어 있는 별도 Docker Compose 프로젝트 이름에 `wafsoak-` 접두사를 사용합니다. DB와 모든 볼륨, 네트워크, IPC, 등록 정보를 이 시험 전용으로 만듭니다. NPM과 에이전트는 호스트 포트를 공개하지 않는 Compose internal network로 연결하고, NPM의 IPC는 해당 에이전트 컨테이너만 참조합니다. NPM 이미지 ID는 `sha256:58da2f5a21c96723e2bcf7379604bdae063e1bc112da8a89697424a29340991a`입니다. NPM의 localhost에만 `smoke.example.test` 테스트 호스트를 구성하고, 정상 경로에 `aegis-smoke /health-probe` 및 `aegis-smoke /tls-probe` 본문을 응답하는 합성 origin을 둡니다. TLS 테스트 인증서의 신뢰 경로는 NPM 내부 `/data/smoke.crt`입니다.

1. 같은 등록과 DB로 부모 → 후보 → 부모 복구 → 후보 재적용을 시험합니다. 단계별 실제 컨테이너 ID와 이미지 ID를 기록합니다. 정상 HTTPS/HTTP2 및 두 개의 평범한 URL을 먼저 확인합니다.
2. 테스트용 URL 하나에만 공급자의 명시적인 drop 예외를 적용합니다. 별도의 정상 URL은 200이고 해당 테스트 URL은 403이어야 합니다. 요청 식별자로 origin 로그를 대조해 차단 시 origin에 도달하지 않았음을 확인합니다. 예외를 제거하고 같은 URL의 200 응답과 origin 도달을 다시 확인합니다. [공식 로컬 정책과 예외](https://docs.openappsec.io/getting-started/start-with-linux/local-policy-file-advanced)
3. 후보가 두 번 모두 검증된 후 아래 관찰기를 실행합니다. 세션 종료 또는 재부팅을 처리하는 운영 스케줄러에는 해당 프로젝트만을 대상으로 하는 정리 및 중단 상태 기록을 따로 구성합니다. 강제 중단된 구간은 새 연속 48시간에 합산하지 않습니다.

```sh
python3 observe.py /scratch/waf-lab wafsoak-example inspect unused
python3 observe.py /scratch/waf-lab wafsoak-example initial /scratch/new-15m &&
  python3 observe.py /scratch/waf-lab wafsoak-example long /scratch/new-48h
```

`inspect`는 컨테이너 소유권과 내부망, 볼륨 공유, 두 이미지의 health 및 기본 모델 파일과 상주하는 16개 ELF의 실제 해시를 검사합니다. 관찰 모드는 매 2초(15분) 또는 30초(48시간)마다 localhost에 평범한 GET을 보내고 30분마다 실제 ELF와 인증서를 검증하는 HTTP/2 GET을 확인합니다. 호스트 디스크 2 GiB·가용 RAM 1 GiB, working set 증가 512 MiB, 지속적인 CPU 과부하, OOM·재시작·worker 교체·샘플 공백·응답 실패를 검사합니다. 출력은 샘플 JSONL과 구간별 결과 JSON입니다. 완료 판정 시 담당자가 두 구간의 경과 시간과 종료 상태, 자동 정리 결과를 함께 확인합니다. 이 정상 트래픽 관찰만으로 모든 입력에 대한 메모리 누수 부재나 공개 배포 승인을 판정할 수 없습니다.
