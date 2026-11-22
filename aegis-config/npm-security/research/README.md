# NPM 보안 후보 재빌드

이 레시피는 Linux amd64용 로컬 연구 이미지를 만든다. `bookworm`은 기존 NPM 2.12.6·open-appsec 인터페이스를 유지한다. `modern`은 공식 2.17.1 소스에 호스트별 WAF 관리 기능을 이식한다. 각 빌드는 자체 로컬 태그와 `final-image.id`를 생성한다. 운영 적용은 기존 MariaDB·파일 백업의 복원과 설치 사이트별 DNS·SSH 훅 검증을 전제로 한다.

## 오프라인 입력

Docker 로컬 엔진에는 다음 두 이미지가 있어야 한다.

| 입력 | 고정 식별자 |
|---|---|
| Aegis의 기존 WAF·NGINX·로그 수정 이미지 | `sha256:58da2f5a21c96723e2bcf7379604bdae063e1bc112da8a89697424a29340991a` |
| 공식 `jc21/nginx-proxy-manager` 2.17.1 amd64 manifest | `sha256:ddccef5311d962ce733bc3439f9efdc11f167888804e60c5912f8a37ecdc5d52` |
| 공식 이미지의 OCI config | `sha256:6b906b29aee05da90feb85cd2bb1e4473df2d6b4498fd8a237f2716138e2c9f5` |

`INPUT_DIRECTORY` 안에 다음 파일을 준비한다. `build-offline.sh`는 빈 작업 경로를 새로 만들고, 고정 라이브러리 SHA와 npm registry 무결성 값을 검증한다. npm 캐시는 각 `locks/*-node.json` 또는 `locks/trixie-tools.json`을 `package-lock.json`으로 두고 해당 루트 `packages[""].dependencies`로 `package.json`을 만든 뒤, 연결된 준비 환경에서 `npm ci --ignore-scripts --no-audit --no-fund --cache /cache`로 채운다. 캐시를 만드는 동안에도 NPM 공급자 원본의 Node/npm 버전을 사용한다.

| 경로 | 사용하는 경로와 내용 |
|---|---|
| `certifi-2026.11.20-py3-none-any.whl` | 공통, 공식 PyPI SHA `7422df25243767b9877031a2248cb14d09ddac9beee846f4cef3d5c9191d488f` |
| `debs/` | Bookworm. `locks/bookworm-debs.sha256`에 있는 75개 패키지. 입력 생성 단계에서 고정 부모의 Debian 및 NodeSource 서명 저장소로 `apt-get update`·`dist-upgrade --download-only` 실행 |
| `cert-prune` | Bookworm. Go 1.27.4, `CGO_ENABLED=0`, `GOFLAGS=-p=1`, `go install -trimpath -ldflags='-s -w' github.com/axllent/cert-prune@v0.0.0-20221103034325-19e68de52ae1`. Linux amd64 Go 배포 압축파일 SHA `7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840`. SumDB 근거는 `locks/cert-prune.sumdb`, 완성 ELF SHA는 스크립트에서 대조 |
| `bookworm-node/npm-cache/` | Bookworm, `locks/bookworm-node.json`용 npm 캐시 |
| `npm-source/` | Modern. 공식 Git 커밋 `89c43f564422a78bd0732046b636cbcd5e566b03`을 포함한 저장소. 빌드는 `git archive`로 해당 커밋만 추출 |
| `frontend-yarn-cache/` | Modern. 해당 소스의 `frontend/yarn.lock` SHA `650bbb1248aafcc4abc52b14bd7e3ee227dd2006b6f64c58ef8dd897a839f0bf`, Yarn 1.22.22. 연결된 준비 환경에서 `YARN_CACHE_FOLDER=/cache yarn install --frozen-lockfile --production=false --ignore-scripts`로 초기화 |
| `trixie-node/npm-cache/`, `trixie-tools/npm-cache/` | Modern, `locks/trixie-node.json`과 `locks/trixie-tools.json`용 npm 캐시 |
| `attachment-notices/{LICENSE,NOTICE}` | Modern, 고정 attachment 원천의 재배포 문서. 모듈·지원 라이브러리·예제 WAF 정책은 스크립트가 58da 이미지에서 추출한 뒤 `locks/attachment.sha256`로 함께 검증 |
| `pip-26.3-py3-none-any.whl`, `setuptools-80.10.2-py3-none-any.whl` | Modern, `repack-pip.py`에 고정한 공식 PyPI SHA. pip의 실제 `pkg_resources` 파일과 공급망 명세·RECORD를 함께 교체 |

```bash
./build-offline.sh bookworm /path/to/inputs /path/to/new-bookworm-build
./build-offline.sh modern /path/to/inputs /path/to/new-modern-build
```

준비 환경에는 로컬 Docker BuildKit, Bash, Git, Python 3.11 이상과 GNU coreutils가 필요하다. 오프라인 베이스 이미지·BuildKit 프런트엔드를 미리 준비한다. `modern`은 프런트엔드용 Yarn 캐시 복사본과 개발 의존성을 별도로 풀 공간이 필요하다. 새 빌드의 OCI ID를 기록하고 전체 스캔·스택 시험을 다시 실행한다. 빌드 생성 시각과 빌드 시스템의 메타데이터에 따라 OCI ID가 달라질 수 있다.

## 호환 범위

`modern`은 기존 YAML에만 있던 호스트의 모드와 임곗값을 목록·상세 API에서 읽는다. 관리자는 React의 호스트 편집 화면에서 설정을 변경할 수 있고 이전 API 요청 형식과 `meta.openappsec`도 처리한다. 파일에는 현재 호스트의 규칙만 갱신하며 에이전트 적용 요청에 오류가 있으면 관리자에게 알린다. 기존 경로별 WAF 규칙이 있는 호스트의 정책·도메인·location 변경 및 삭제는 전체 경로별 편집 기능 이식이 완료될 때까지 거부한다. 기존 old fork의 모든 관리 화면은 별도 기능 비교 대상이다.

신규 NPM은 기본 관리자 계정 생성을 최초 사용자 API로 처리한다. 구→신 전환 시에는 기존 인증 정보를 사용한다. Certbot이 5.1.0에서 5.10.0으로 바뀐다. 순정 이미지에 기본 설치된 인증기는 `standalone`, `webroot`다. DNS 플러그인 카탈로그는 75종에서 90종으로 늘며 EdgeDNS, Beget, Infomaniak 패키지 버전 또는 이름도 바뀐다. 실제 DNS 제공자의 인증·운영 도메인 갱신, 사용자 정의 SSH 기반 배포 훅은 설치 현장별 확인 사항이다. `modern`은 OpenSSH 클라이언트를 제거한다. 롤백할 때는 마이그레이션 전 MariaDB 덤프와 인증서·NPM 데이터·WAF 정책 스냅샷을 같은 시점에서 함께 복원한다.

[공식 NPM 릴리스](https://github.com/NginxProxyManager/nginx-proxy-manager/releases/tag/v2.17.1) · [pip 26.3](https://pypi.org/project/pip/26.3/) · [setuptools 80.10.2](https://pypi.org/project/setuptools/80.10.2/) · [Debian Brotli 권고](https://security-tracker.debian.org/tracker/CVE-2026-111497)

## 2026년 11월 21일 스테이징 검증

| 이미지 | 식별자 앞 12자 | Critical | High | CISA KEV |
|---|---|---:|---:|---:|
| 원본 NPM 2.12.6 | `f94c1504a3d0` | 35 | 1,185 | 7 |
| 기존 NGINX·로그 보강 | `58da2f5a21c9` | 33 | 1,165 | 7 |
| Bookworm 패키지·Node·Go·Certbot 교체 | `1fba1d01aac1` | 6 | 330 | 1 |
| Bookworm 앱 tar까지 실제 교체 | `bc05abc9f7ce` | 5 | 322 | 1 |
| 공식 NPM 2.17.1 | `6b906b29aee0` | 1 | 209 | 1 |
| 최신 WAF·도구 수정 및 실제 관리자 저장 검증 | `4011d192e11d` | 0 | 196 | 0 |

최종 OCI config는 `sha256:4011d192e11d14783ba86f6d1b0ef935495324731e903523390ea40a7e9972e0`이다. Trivy 0.76.2로 OS 및 언어 패키지를 전체 조회한 이미지 JSON SHA는 `f9a434f13fa087f743d12cce388e6b2693199ebfca3124808fc5c88178efd416`이다. 취약점 DB 갱신 시각은 2026-11-21 10:10:48 KST이고 CISA KEV 카탈로그는 2026-11-20판이다. 등급은 패키지 종류·이름·권고 ID 기준 고유 건수, KEV는 모든 등급의 고유 CVE 수다. 최종 High 196개는 모두 Debian 패키지이며 해당 DB의 `FixedVersion`이 비어 있다. 고정 버전이 제시된 하위 등급은 pip의 내장 `pkg_resources`에 연결된 Medium 1건 `CVE-2026-59890`과 Low 1건 `GHSA-xmj3-9gf7-h52w`다. 실제 설치된 전체 setuptools는 84.2.1이며 pip의 Python 3.13 레거시 메타데이터 백엔드에는 80.10.2의 `pkg_resources`를 고정했다. 이 Linux 이미지에 포함한 해당 번들의 Python 소스는 `pkg_resources/__init__.py` 한 개다. 두 권고의 `setuptools/command/egg_info.py`와 `setuptools/wheel.py`는 수정 버전 이후인 84.2.1에서 로드된다. 해당 이미지의 macOS 및 Windows 전용 권고 두 건은 적용 대상에서 제외되며 원본 스캔에는 포함된다. [Debian 적용성 판정](https://security-tracker.debian.org/tracker/CVE-2026-59890) · [setuptools 공급자 권고](https://github.com/pypa/setuptools/security/advisories/GHSA-xmj3-9gf7-h52w)

별도 생성한 MariaDB·데이터·TLS 인증서와 로컬 정책을 사용했다. 최종 NPM, MariaDB `01ac69580137`, WAF 에이전트 `688af57069ac` 조합에서 기존 관리자·호스트·인증서 이관, HTTP/2, GeoIP2·WAF 모듈 로딩, 등록 후 정상 URL 허용→지정 URL 차단→허용 복원을 확인했다. Chromium에서 로그인하여 실제 호스트 모드를 `detect-learn`에서 `prevent-learn`으로, 임곗값을 `critical`로 변경했다. 기존 API에서 다른 호스트를 활성화하고 새 API에서 비활성화·삭제하는 동안 첫 번째 호스트 설정도 보존됐다. 실제 Aegis 정책 생성기가 작성한 YAML을 확인했고 구버전 덤프·인증서·데이터·정책 복원 후 2.12.6으로 TLS 프록시와 WAF IPC를 재검증했다.

## 개발 헤더 제거 비교

`Dockerfile.runtime-minimal`은 NPM 2.17.1 후보에서 개발 헤더와 해당 헤더에 의존하는 패키지 일곱 개를 제거한 비교 레시피다. APT의 제거 예정 목록과 실제 설치 패키지 전후 차이를 각각 확인한다. 검증된 부모 이미지를 로컬에 준비한 뒤 이 디렉터리에서 실행한다.

```bash
(
    set -eu
    parent=aegis-npm-research:modern-api-f5bh4ipe
    expected=sha256:4011d192e11d14783ba86f6d1b0ef935495324731e903523390ea40a7e9972e0
    test "$(docker image inspect --format '{{.Id}}' "$parent")" = "$expected"
    trial=$(mktemp -d)
    docker build --pull=false --network none --platform linux/amd64 \
        --build-arg "AEGIS_NPM_SOURCE=$parent" --iidfile "$trial/image.id" - < Dockerfile.runtime-minimal
    cat "$trial/image.id"
)
```

2026년 11월 21일 동일한 Trivy OS·Java DB와 CISA KEV 목록으로 두 이미지를 검사했다. 스테이징 비교 이미지 `89c7d5cac699668462b668cdedfb905417341fd5a2f04f30c9643a04d84e7244`의 Critical/High/Medium/Low/Unknown은 **0/163/371/851/39**, KEV는 0건이다. 부모의 High 196건 중 `linux-libc-dev` 33건이 줄었고 고유 High 권고는 75개에서 42개가 됐다. 새로 검출된 항목은 0건이다. 이 결과는 컨테이너에서 보이는 최종 파일시스템 기준이다. 부모의 48개 레이어에는 원래 파일이 남고, 비교 이미지의 49번째 레이어가 해당 경로를 가린다.

비교 이미지의 기본 엔트리포인트, NGINX 설정 검사, SQLite 초기화, 관리자 API의 2.17.1 응답 및 Compose와 같은 HTTP 헬스체크가 통과했다. 외부 네트워크가 차단된 컨테이너에서 SHA-256을 확인한 공식 휠 18개로 NPM 자체 설치 함수를 실행하고 Certbot의 Cloudflare·Route53·webroot·standalone 인증기를 로드했다. 실제 인증서 발급·갱신은 별도 검증 사항이다. 카탈로그 90개 중 82개는 조사 시점의 대상 버전에 호환 휠이 있었고 8개는 소스 배포본만 제공했다. 이 구분은 각 플러그인 자체에 한정되며 하위 의존성, 장래 버전, 전체 제공자의 설치·갱신 호환성은 확인되지 않았다. NPMplus2의 `~/aegis-test/npm-runtime-minimal.8ANV1VYG/`에 첫 비교 이미지 `5a159e248ff8`의 자료와 최종 비교 이미지의 `failfast.trivy.json`, `failfast-result.json`, `failfast-qa/runtime.json`을 보관한다. 첫 번째 헤더만 다시 만든 음성 빌드는 즉시 실패했다. 두 비교 이미지의 dpkg·pip 인벤토리와 전체 취약점 발견 목록은 일치했다. 기존 네 서비스 관찰은 4011 후보를 사용한다.
