![Docker](https://img.shields.io/badge/docker-ready-blue)
![Security](https://img.shields.io/badge/security-hardened-green)
![License](https://img.shields.io/badge/license-MIT-blue)
![Version](https://img.shields.io/badge/version-v0.4.1-orange)

# 🛡️ Aegis-Proxy-Stack (v0.4.1)

**Aegis-Proxy-Stack** is an all-in-one integrated security package that combines the exceptional usability of [NGINX Proxy Manager (NPM)](https://nginxproxymanager.com/) with enterprise-grade security solutions (WAF, IPS, Visualizer). It is designed to enable anyone to easily build an efficient web defense system without complex configuration.

'**Aegis(이지스)**'는 그리스 신화에서 제우스와 아테나가 사용한 방패를 의미하며, 강력한 보호와 방어를 상징합니다. 여러 보안 계층(WAF, IPS, Visualizer)이 겹겹이 쌓여(Stack) 완벽한 방어를 제공한다는 의미를 담았습니다.

리눅스 환경의 Docker 기반으로 설계되어 즉시 배포가 가능하며, 기계 학습 기반의 제로데이 공격 차단, 집단지성 기반의 IP 평판 분석, 그리고 실시간 지리적 시각화 모니터링을 하나의 통합된 환경에서 제공하며, 나아가 **Aegis 통합 관리 UI**까지 개발하는 것이 목표입니다.

Defense-in-depth architecture for hardened containerized web services.

![Architecture Diagram](images/architecture.png)


## 🌟 Key Features

* **Core Proxy:** [NGINX Proxy Manager](https://nginxproxymanager.com) 기반의 직관적인 도메인 및 TLS Certificates 관리
* **ML-Based WAF:** [open-appsec](https://www.openappsec.io) 탑재로 OWASP Top 10 및 제로데이 공격에 대한 선제적 방어 (서명 업데이트 불필요)
* **Advanced Machine Learning Model:** [고급 머신러닝 모델](https://docs.openappsec.io/getting-started/using-the-advanced-machine-learning-model)을 적용한 방어체계 구축 **(Phase 2 Completed)**
* **Crowd-Sourced IPS:** [CrowdSec](https://www.crowdsec.net) 통합으로 전 세계 위협 IP 데이터 실시간 공유 및 차단 **(Phase 3 Scheduled)**
* **Real-time Visualization:** [GoAccess](https://goaccess.io)와 [GeoIP2](https://www.maxmind.com) 연동으로 트래픽 및 공격지점 지도 기반 시각화 **(Phase 4 Scheduled)**
* **Aegis Integrated Management UI:** 상기 보안 솔루션 통합 관리를 위한 웹 기반 관리 솔루션 개발 **(Phase 5 Scheduled)**


## 📜 Architecture (Roadmap)

* ✅ **Phase 1:** NGINX Proxy Manager + open-appsec ML-Based WAF Integration
* ✅ **Phase 2:** Using the Advanced Machine Learning Model
* ⬜ **Phase 3:** CrowdSec IPS Integration
* ⬜ **Phase 4:** GoAccess + GeoIP Visualization Setup
* ⬜ **Phase 5:** Aegis Integrated Management UI
* ⬜ **Phase 6:** Integration with other Security Solutions
* ⬜ **Phase 7:** Enhanced Performance and Functionality


## 🛠️ Technical Specifications (기술적 특징)

Aegis-Proxy-Stack은 단순한 통합을 넘어, 운영 안정성과 보안 규제 준수(Compliance)를 고려하여 정교하게 설계되었습니다.

### 1. 보안 강화 아키텍처 (Hardened Security)
* **IPv4 Only & IPv6 Leak Prevention:** IPv6를 통한 우회 공격이나 정보 유출을 방지하기 위해 3중 잠금 장치(Docker Ports, App Environment, Kernel Sysctl)를 적용하여 IPv6 트래픽을 원천 차단했습니다.
* **Isolated Network (네트워크 격리):** `aegis-network`라는 독립된 내부 브리지 네트워크를 사용하여 컨테이너 간 통신을 제어합니다. 특히 데이터베이스(DB)는 호스트 포트를 노출하지 않고 오직 내부망에서만 접근 가능하도록 격리했습니다.

### 2. 규제 준수형 로그 관리 (Compliance-Ready Logging)
* **Log-Rotator Sidecar:** 호스트 OS의 설정에 의존하지 않고, Docker 내부의 독립적인 `log-rotator` 사이드카 컨테이너가 로그를 관리합니다.
* **1-Year Retention:** 보안 규제(ISMS-P 등)를 고려하여 모든 보안 로그는 **365일간 보관**되며, 일 단위(Daily)로 압축(Compress)되어 저장됩니다.
* **Copytruncate Strategy:** 서비스 중단 없는 로그 순환을 위해 `copytruncate` 방식을 채택하여 무중단 운영을 보장합니다.

### 3. 최적화된 데이터베이스 (Optimized Database)
* **MariaDB Aria Engine:** NGINX Proxy Manager에 최적화된 경량화 이미지(`jc21/mariadb-aria`)를 사용하여 리소스 사용량을 최소화했습니다.
* **DB 초기화:** MariaDB 엔트리포인트가 첫 기동 시 설치기의 자격 증명으로 NPM 전용 DB와 사용자를 생성합니다.


## 📂 Project Structure (디렉토리 구조)

**Aegis-Proxy-Stack**은 관리 효율성을 위해 모든 디렉토리를 **성격(Config, Data, Logs)에 따라 3개의 대분류로 통합**하여 관리합니다.

| 대분류 | 하위 경로 (Sub-path) | 성격 (Role) | 설명 및 주요 내용 |
| :--- | :--- | :--- | :--- |
| 📂 **`aegis-config`**<br>(설정) | `/advanced-model` | **Model** | 고급 머신러닝 모델 구동을 위한 바이너리 파일 보관 |
| | `/agent` | **Brain** | WAF 에이전트 구동을 위한 내부 설정 및 환경 파일 |
| | `/crowdsec` | **Guard** | IPS 위협 분석 엔진 설정 및 차단 시나리오 정의 |
| | `/logrotate` | **Cron** | 보안 규정 준수를 위한 로그 파일 자동 압축 및 순환 설정 |
| | `/policy` | **Hub** | **[핵심]** NPM-WAF 간 정책 공유 디렉토리 (`local_policy.yaml`) |
| | `/scripts` | **Controller** | 정책 자동 생성 로직(`policy_generator.js`) 및 관련 모듈 |
| 📂 **`aegis-data`**<br>(데이터) | `/certs` | **Vault** | 발급된 SSL 인증서 원본 및 비공개 키 파일 보호 |
| | `/crowdsec` | **Alert** | 위협 IP 데이터베이스 및 탐지된 침입 알람 데이터 |
| | `/db` | **DB** | 서비스 메타데이터가 저장되는 MariaDB 물리 데이터 파일 |
| | `/learning` | **Memory** | AI 기반 보안 엔진의 공격 학습 데이터가 저장되는 영속 공간 |
| | `/npm` | **Core** | Nginx Proxy Manager의 도메인 설정 및 관리자 계정 데이터 |
| 📂 **`aegis-logs`**<br>(로그) | `/crowdsec` | **IPS Log** | 침입 탐지 시스템의 진단 및 IP 차단 이력 기록 |
| | `/npm` | **Web Log** | Nginx 웹 서비스 접속 로그(`access.log`) 및 에러 로그 |
| | `/waf` | **WAF Log** | WAF 엔진의 실시간 차단 내역(`cp-nano-*.log`) 및 시스템 로그 |
| 📂 **`images`** | (Root) | **Asset** | README 및 프로젝트 문서용 이미지 파일 (아키텍처 구성도 등) |


## 🚀 Installation & Getting Started

### 📋 Prerequisites (사전 요구 사항 및 환경 점검)

설치를 진행하기 전에 반드시 아래 사항들을 확인해주세요.

> **보안 권장 사항:** 본 프로젝트는 보안상의 이유로 `root` 계정이 아닌 **`일반 사용자` 계정**으로 설치 및 실행하는 것을 권장합니다.

1. **Docker 설치 및 버전 확인 (필수)**

   터미널에서 아래 명령어를 입력하여 설치된 버전이 아래의 최소 요구사항을 만족하는지 확인합니다.
   * Docker version 20.10.x 이상
   * Docker Compose version v2.0.x 이상
   ```bash
   docker --version
   docker compose version
   ```
   **🚨 Docker가 없거나 버전이 낮은 경우 (해결 방법)**

   아래와 같은 공식 설치 스크립트를 사용하면 최신 버전의 Docker와 Compose가 자동으로 설치(또는 업데이트)됩니다.
   ```bash
   curl -fsSL https://get.docker.com | sudo sh
   ```

2. **사용자 권한 확인 (Docker 그룹 설정)**

   일반 계정에서 `sudo` 없이 Docker 명령어를 실행하려면, 해당 계정이 `docker` 그룹에 포함되어 있어야 합니다.

   **Step 1. 현재 권한 확인**

   터미널에서 아래 명령어를 입력했을 때, 에러 없이 컨테이너 목록(또는 빈 목록)이 나와야 합니다.
   ```bash
   docker ps
   ```
   **🚨 `permission denied` 에러가 발생한다면 아래 Step 2를 진행하세요.**

   **Step 2. Docker 그룹에 사용자 추가 (필요시)**

   현재 사용자를 docker 그룹에 추가 및 그룹 변경 사항 적용을 위해 아래 명령어 실행
   ```bash
   sudo usermod -aG docker $USER 
   newgrp docker
   ```

3. **필수 포트 확인**

   Aegis-Proxy-Stack은 다음 포트를 사용합니다. 해당 포트가 이미 사용 중인지 확인하세요.
   * **80 (HTTP):** 웹 서비스 (Let’s Encrypt Challenge 및 HTTP 트래픽)
   * **81 (Admin):** NGINX Proxy Manager 관리자 웹 콘솔
   * **443 (HTTPS):** 웹 서비스 (TLS 암호화 트래픽)

### 🛠️ Step-by-Step Install Guide

1. **작업 환경 구성 (Prepare)**

   프로젝트의 체계적인 관리와 향후 확장성을 위해 `aegis` 전용 디렉토리를 생성하여 설치하는 것을 권장합니다. 아래 모든 과정은 반드시 `root`가 아닌 일반 사용자 계정으로 진행해 주세요.

   사용자 홈디렉토리에 'aegis' 프로젝트 최상위 폴더 생성 후 해당 폴더로 이동합니다. **(옵션 사항)**
   ```bash
   mkdir -p ~/aegis
   cd ~/aegis
   ```

2. **저장소 복제 (Clone Repository)**
   ```bash
   git clone https://github.com/AegisAX/Aegis-Proxy-Stack.git
   cd Aegis-Proxy-Stack
   ```

3. **설치 스크립트 실행 (Run Interactive Installer)**

   `install.sh`를 실행하고 NPM 관리자 이메일과 비밀번호를 입력합니다.

   ```bash
   chmod +x install.sh verify_all.sh
   ./install.sh
   ```

   신규 설치에서는 이메일을 open-appsec 에이전트 식별에도 사용합니다. DB 루트와 DB 앱 계정에는 서로 다른 임의 비밀번호를 생성해 소유자만 읽을 수 있는 `.env`에 보관합니다. 기존 설치의 DB 데이터와 `.env`는 함께 백업해야 합니다. 재설치 시 기존 DB 비밀번호를 유지합니다.

   DB가 포함된 신규 설치는 `aegis-config/db-security/Dockerfile`의 MariaDB 10.11.20을 사용합니다. 검증한 이미지 ID가 로컬에 있으면 재사용하고, 다른 호스트에서는 고정된 빌드 입력으로 이미지를 만든 뒤 버전·초기 데이터 디렉터리 및 사용자 전환을 확인합니다. 결과 태그를 `.env`에 기록해 Compose와 업데이트 관리자가 같은 이미지를 선택합니다. 새로 빌드한 이미지의 취약점 결과는 해당 이미지 ID로 검사한 뒤 표시합니다. 기존 DB는 별도 데이터 디렉터리에서 논리 백업 복원과 롤백을 확인한 뒤 전환해야 합니다.
   
   > **Note:** 설치가 완료되면 검증 스크립트(`verify_all.sh`)를 즉시 실행할지 묻는 메시지가 나타납니다.

4. **서비스 실행 (Start Services)**

   설치 스크립트에서 자동 실행을 하지 않았다면 아래 명령어로 실행합니다.
   ```bash
   ./install.sh
   ```

   > **💡 Dashboard Access Tip:** 
   >
   > 신규 설치의 관리 포트는 `127.0.0.1:81`에서 열립니다. 원격 PC에서 `ssh -L 8081:127.0.0.1:81 계정@서버`를 실행한 뒤 브라우저에서 `http://127.0.0.1:8081`에 접속하고 설치 시 입력한 NPM 자격 증명으로 로그인합니다. 기존 설치는 `NPM_ADMIN_BIND`를 명시할 때까지 기존 바인딩을 사용합니다.


## ⚠️ Known Issues & Workarounds (알려진 이슈 및 해결 방법)

### 1. SSL 인증서 발급 시 "Test Reachability" 실패 현상
NPM UI에서 SSL 인증서 발급 시 `JSONObject["responsetime"] not found` 또는 `Unexpected status code` 오류와 함께 도메인 연결 테스트가 실패하는 경우가 있습니다.

> **원인:** 이는 Aegis-Proxy-Stack의 결함이 아닌, **Nginx Proxy Manager(NPM) 자체의 고질적인 사전 점검 로직 이슈**입니다. NPM 백엔드가 자기 자신의 공인 IP로 접속하여 응답을 확인하는 과정에서 루프백(Loopback) 경로 문제나 보안 모듈의 응답 헤더 간섭으로 인해 발생합니다.
>
> **증상:** "Test Reachability" 버튼 클릭 시 에러가 발생하거나, 인증서 발급 창에서 저장 시 경고 팝업이 뜸.
>
> **해결 방법 (Workaround):**
> 1. **무시하고 진행:** 사전 테스트 결과와 상관없이 실제 `Certbot`을 통한 인증서 발급은 정상적으로 수행됩니다. 에러 팝업이 뜨더라도 다시 한번 **Save**를 누르면 발급이 완료됩니다.
> 2. **Temporary Disable:** 만약 지속적으로 실패한다면, 해당 Proxy Host를 잠시 **'Disabled'** 상태로 변경한 뒤 인증서를 발급받으세요. 발급 성공 후 다시 'Enabled' 및 'open-appsec ON'으로 설정하면 모든 기능이 정상 작동합니다.


## 🧪 Verification & Testing (검증 및 테스트)

설치가 완료된 후, 시스템이 정상적으로 작동하는지 확인하기 위해 **검증 전용 스크립트**를 제공합니다. 복잡한 수동 설정 없이 명령 한 줄로 모든 상태를 점검할 수 있습니다.

### ✅ 자동 검증 실행 (Automated Verification)

프로젝트 디렉터리에서 `./verify_all.sh`를 실행하면 NPM 인증, NGINX 설정 검사, 정책 동기화 및 에이전트의 정책 재적용을 확인합니다. 기존 검증에서 만든 `test.aegis.local`이 관리 콘솔로 연결되면 해당 항목을 보고하고 중단합니다. 정상 요청과 차단 요청까지 확인하려면 인증서가 유효한 기존 시험 호스트에 허용·차단 경로를 준비하고 아래처럼 실행합니다.

```bash
AEGIS_VERIFY_HOST=qa.example.org AEGIS_VERIFY_ALLOW_PATH=/health AEGIS_VERIFY_DENY_PATH=/waf-test ./verify_all.sh
```

두 요청은 서버의 루프백 HTTPS 리스너로 전송합니다. 정상 경로 HTTP 200과 차단 경로 HTTP 403을 모두 확인해야 종단 간 시험이 통과합니다.

## 🔄 Update Guide

실행 이미지 ID별 등급과 검사 기준 시각은 [이미지 감사 기록](aegis-config/security/image-audits.json)에 포함됩니다.

`v0.4.1` 설치의 기존 `./update.sh`가 GitHub 태그에서 관리자를 갱신하면
`v0.4.3` 브리지가 이어집니다. 브리지는 고정된 체크섬으로 필요한 도구를 확인하고
기존 서비스와 일치하는 Compose 기준본을 선택합니다. 브리지 태그 다운로드에서는
컨테이너와 설치 버전이 교체되지 않습니다. 서명된 이미지 릴리스를 적용하면
성공한 배포 버전은 `.aegis-update/release.json`에 저장됩니다.

프로젝트 디렉토리에서 `./update.sh`를 실행하면 설치 버전, Git 커밋,
컨테이너 이름, 실행 중인 앱과 버전, 헬스 상태, 이미지 보안 결과를
표시합니다. 전체 이미지 참조와 해시는 **[i] 이미지 상세**에서 확인합니다.
GitHub Releases의 기능·보안 릴리스는 서명과 실행 이미지가 일치할 때 메뉴에 표시합니다.
**실행 이미지 취약점**에는 실행 중인 이미지의 전체 ID와 일치하는 검사 결과와
Trivy DB 시각을 표시합니다. Critical·High는 패키지 유형·이름·취약점별 발견 수,
KEV는 CISA 목록과 일치하는 고유 CVE 수입니다. **[i]**에서 나머지 심각도와
KEV 식별자를 확인할 수 있습니다. 검사 결과가 없거나 DB 갱신 후 48시간이
지나면 각각 미검사 또는 재검사 필요로 표시합니다. Trivy와 Python 3가 설치된
호스트는 메뉴를 열면 미검사·재검사 대상만 백그라운드에서 검사하며, **[s]**로 즉시 다시 검사할 수 있습니다.
자동 검사 실패 시 같은 조합의 재시도 간격은 한 시간입니다. 전체 패키지 및 발견 목록은
`.aegis-update/audits/<이미지 ID>.trivy.json`에, 원본 SHA-256은 같은 이름의 요약 JSON에 저장됩니다. 검사 범위는 이미지의
OS·언어 패키지입니다. 실행 후 설치된 패키지와 별도 공급자 바이너리는 별도 검증이 필요합니다.
게시된 릴리스를 메뉴에서 선택하면 매니페스트를 검증하고 변경 계획을
표시합니다. 자동 적용 조건을 충족하는 배포에는 확인 메뉴가 표시됩니다.

첫 화면에서 컨테이너 이미지의 보안 업데이트 상태를 자동 확인합니다.
적용할 항목이 있는 조치만 메뉴에 표시합니다. 관리 중인 Alpine 3.22
로그 이미지는 임시 컨테이너에서 Alpine 저장소를 조회해 패키지 갱신
여부를 확인합니다. NPM, open-appsec 에이전트, MariaDB는 실행 이미지의
레지스트리 다이제스트와 공급자 태그를 비교합니다. 공급자 이미지가
바뀌었을 때에는 별도 표시합니다. NPM에 포함된 NGINX 엔진 버전도
실행 중인 컨테이너에서 별도로 조회합니다. 보안 수정의 포함 여부와 운영 적용은
검증된 릴리스를 통해 확인합니다.

격리 시험을 수행하는 설치에서는 에이전트의 실행 이미지, NPM 이미지와 공급자
다이제스트가 시험 기록과 일치하면 관찰 단계, 라이브러리 버전, 요청 성공·실패
건수와 종료 예정 시각도 표시합니다. 기록이 끊기면 재검토 상태로 표시합니다.
격리 검증 완료 표시는 해당 이미지 조합의 시험 결과입니다.

`aegis-npm`의 엔진 보안 후보는 [Aegis NPM 포크의 보안 브랜치](https://github.com/AegisAX/open-appsec-npm/tree/aegis/security-engine/security)에서 빌드합니다.
운영 NPM 앱을 담은 이미지를 다이제스트로 고정한 뒤 OpenResty와 open-appsec 모듈을 함께 빌드합니다.
예를 들어 `openresty/1.31.8.1 (aegis-nginx-core-1.31.9)`는 NGINX 1.31.9의 코어 수정을 적용한 Aegis 빌드입니다.
후보의 로컬 시험과 운영 배포는 별도 단계입니다. `./update.sh`는 서명된
`stack-v1` 릴리스의 호환성과 변경 계획을 확인하고, 점검 시간에 네 서비스를
함께 교체할 수 있습니다.
운영 후보를 승인할 때에는 WAF 에이전트가 시험 정책을 적용한 환경에서
정상 경로의 응답과 명시적으로 차단한 시험 경로의 응답을 각각 확인합니다.

포크에서 `./security/check-candidate.sh`를 통과한 로컬 이미지에는 이 저장소의 NPM 로그 보완을 이어서 적용할 수 있습니다.
아래 명령은 후보 이미지를 만들고 임시 NPM에서 초기 관리자 생성과 인증서 업로드를 시험합니다.
두 작업을 완료한 뒤 테스트 암호와 개인 키가 컨테이너 로그에 기록되었는지도 확인합니다.

```bash
docker build -t aegis-npm:security-candidate-hardened aegis-config/npm-security
bash tests/npm-log-privacy.sh aegis-npm:security-candidate-hardened
```

대화형 `./update.sh`를 시작하면 설치 디렉터리의 `.env`와
`backups/<백업>/.env`에서 그룹·기타 사용자에게 열려 있는 권한을
자동으로 제거합니다. 조치가 완료됐거나 수동 확인이 필요한 경우에만
결과를 표시합니다. 파일 내용과 소유자 권한은 유지합니다.
옵션으로 실행하는 조회 명령은 파일을 변경하지 않습니다.

**[b] 백업 파일 생성**은 네 서비스가 정상이고 적용 가능한 스택 릴리스가 없을 때 표시됩니다.
스택 릴리스에 적용 전 백업이 포함됩니다. 확인 후 log, NPM,
WAF, MariaDB 순으로 정지해 쓰기가 멈춘 상태에서 DB 파일·NPM 데이터·인증서·
WAF 설정과 학습 데이터·Compose 설정을 같은 백업에 저장합니다. 그 뒤 DB,
WAF, NPM, log 순으로 기존 컨테이너를 다시 시작합니다. 백업 전 호스트에서
정책 파일이나 마운트된 데이터를 쓰는 작업을 함께 멈춥니다. 백업에는 인증서
개인 키와 `.env`가 포함되며, 출력 경로와 파일은 현재 계정 전용입니다.
순환 로그는 백업 대상에서 제외합니다.
기본 설치의 프로젝트 디렉터리 아래 바인드 마운트를 지원합니다. 별도
Docker 볼륨이나 외부 디스크에 둔 파일은 해당 저장소의 백업을 준비합니다.

`backups/stack-…/snapshot.json`에는 백업 파일의 SHA-256, 실행 이미지 ID와
서비스 정지부터 정상 상태까지의 시간이 기록됩니다. 물리 DB 백업은 해당
버전의 이전 DB 이미지와 함께 복구에 사용합니다. 백업이 중단된 경우
**[b] 중단된 백업 후 서비스 재시작**으로 원래 컨테이너를 다시 시작합니다.
복구 기록이 남아 있는 동안 릴리스와 log 이미지 교체는 대기합니다.

운영 배포 전에는 백업을 검증하고 분리된 새 경로로 복원합니다. 아래 명령에
백업 완료 메시지에 표시된 실제 경로를 입력합니다.

```bash
python3 aegis-config/scripts/stack-backup.py verify "$SNAPSHOT"
python3 aegis-config/scripts/stack-backup.py extract "$SNAPSHOT" "$NEW_RECOVERY_DIR"
```

복원 시험에서는 원래 이미지 ID와 별도 Compose 프로젝트·네트워크를
지정하고 외부 포트와 공급자 접속 설정을 확인한 뒤 기동합니다. 업데이트
이후 쓰기가 발생한 환경을 이전 시점으로 복원하면 그 사이의 데이터가
누락될 수 있습니다. 운영 전환 시점과 쓰기 재개 조건을 미리 정합니다.

**[4] aegis-log 보안 업데이트**는 적용 가능한 스택 릴리스에 Log 업데이트가 없을 때 표시됩니다.
이 작업은 Alpine 저장소의
패키지를 갱신한 로그 순환 이미지를 빌드합니다. 설정 검증과 musl 최소
수정 버전 확인 후, 승인하면 로그 순환 컨테이너만 교체합니다.
교체에 실패하면 이전 실행 이미지와 구성을 복구합니다. 적용에 성공한
이미지는 로컬에서 이미지 ID로 식별되는 태그와
`docker-compose.override.yml`에 기록됩니다. 기존 사용자 오버라이드가
있으면 교체를 중단합니다. 이미지 빌드에는 Docker Hub와 Alpine 패키지
저장소 접근이 필요합니다.

자동화에서는 옵션으로 같은 조회를 실행할 수 있습니다.

```bash
./update.sh --dry-run
./update.sh --security --dry-run
./update.sh --security --dry-run --manifest /path/to/release.json
```

게시할 매니페스트는 정식 GitHub 릴리스에
`aegis-<채널>-<시작버전>-<40자리 시작 커밋>.json` 이름의 에셋으로
첨부합니다. 같은 시작 상태의 호환 릴리스가 여러 개면 기능 또는 보안 채널에서
원하는 버전을 번호로 선택합니다.

발행자는 검토를 마친 JSON을 `releases/<릴리스 태그>/<매니페스트 파일명>`으로
`main`에 반영합니다. 스택 릴리스에는 48시간 관찰의 완료 기록인
`qualification.json`과 검증된 OCI 아카이브의 SHA-256을 담은
`archives.json`이 필요합니다.

1. 최종 이미지의 최신 취약점 검사와 관찰 결과를 확인합니다. OCI 아카이브 네 개를 GitHub 초안에 첨부하고 사전 릴리스로 공개합니다. 이 단계의 사전 릴리스에는 배포 매니페스트를 첨부하지 않습니다.
2. **Publish qualified stack images**를 실행합니다. 워크플로는 읽기 전용 토큰으로 사전 릴리스의 파일을 읽고, 관찰 결과와 체크섬을 확인한 뒤 정확한 OCI 다이제스트로 GHCR에 게시합니다. 최초 게시 시 GHCR 패키지의 접근 설정에서 공개 범위를 확인하고 인증 없이 각 이미지가 내려받아지는지 검사합니다.
3. **Attest a release manifest**를 실행합니다. 관찰 결과, 커밋된 매니페스트와 레지스트리 다이제스트를 대조한 뒤 해당 바이트에 GitHub 증명을 발행합니다.
4. 서명을 실제로 검증하고 같은 매니페스트를 사전 릴리스에 첨부합니다. 이때 운영의 기본 메뉴에 해당 태그가 표시되지 않는지 확인합니다.
5. 운영과 같은 시작 버전·Git 커밋·이미지 ID로 구성한 격리 스테이징에서 기존 `./update.sh`가 배포 관리자 브리지를 불러오는지 확인합니다. GitHub에서 내려받은 서명된 매니페스트로 `./update.sh --security --manifest <파일> --dry-run`을 실행한 뒤, `--dry-run` 대신 `--maintenance`를 주어 실제로 교체합니다. 이 시험에는 합성 DB 데이터, 인증서와 프록시 설정을 사용합니다.
6. 목표 이미지 네 개, 서비스 헬스, DB 데이터·인증서 보존, 프록시·WAF와 로그 순환을 확인합니다. 격리 환경에서 헬스 실패를 유도해 이전 이미지와 데이터가 복구되는지도 확인한 뒤, 같은 태그를 정식 릴리스로 전환합니다.

`--security`는 보안 업데이트 채널을 선택합니다. `--manifest`를 사용하려면
`gh`의 GitHub 인증과 `jq`가 필요합니다. 매니페스트는 저장소의
`main`에서 실행된 `.github/workflows/release.yml`의 GitHub 아티팩트
증명이 있어야 합니다. 검증 후 시작 버전, Git 커밋, 대상 서비스의 실제
이미지 ID를 대조하고 목표 이미지 다이제스트와 해결 대상 CVE를 표시합니다.

매니페스트 스키마 1은 `schema_version`, `channel` (`feature` 또는
`security`), `from_version`, `from_commit`, `release`,
`resolved_cves`, `images`를 사용합니다. `images`는 변경할 Compose 서비스
이름을 키로 사용하며, 각 값은 현재 이미지 ID인 `from_id`와
`저장소@sha256:다이제스트` 형식의 `target`을 포함합니다.

기존 형식의 릴리스는 헬스체크가 있는 격리된 단일 서비스에 적용합니다.
네 서비스 릴리스는 스키마 1에 `strategy: "stack-v1"`을 추가합니다. `images`에
`db`, `agent`, `npm`, `log-rotator`와 각각의 `target_id`(검증된
Linux/amd64 이미지 config ID)를 모두 명시합니다. 발행 워크플로는 공개
레지스트리의 이미지 매니페스트와 config 다이제스트를 대조합니다.

스택 적용은 현재 Compose와 실행 중인 서비스의 구성 해시, 기존 이미지 ID,
데이터 경로를 사전 확인합니다. 점검 시간에 외부 트래픽과 관리 작업을 멈춘 뒤
메뉴에서 확인합니다. 자동화에서는 같은 확인 의미로 `--maintenance`를
사용합니다. 이미지가 준비되면 콜드 백업을 검증하고, 별도 복사본으로 DB,
에이전트, NPM, log를 순차 기동합니다. 백업과 복사본을 둘 공간과 동일한
파일시스템의 기본 바인드 마운트가 필요합니다. 기존 로그 설정을 바인드한
설치는 후보 이미지에 내장된 로그 규칙과 같은 설정을 사용해야 합니다.

각 서비스의 이미지 ID와 헬스체크가 통과하면 `.aegis-update/images.json`에
적용 결과를 기록합니다. 실패하면 전환 전 데이터와 기존 이미지로 복구합니다.
후보에서 발생한 쓰기는 전용 작업 디렉터리의 `failed/`에 보존합니다.
프로세스가 강제 종료되면 메뉴의 **[r] 스택 전환 복구** 또는
`./update.sh --recover-stack`을 사용합니다. 이미 승인된 전환 단계에서는
후보의 상태를 확인하고 오버라이드를 저장해 전환을 마칩니다. 점검 상태에서
작업·복구가 끝난 뒤 트래픽을 다시 엽니다.

중단 기록은 단일 서비스의 `.aegis-update/pending.json`과 스택의
`.aegis-update/stack-pending.json`에 남습니다. 해당 기록이 있는 동안 새
적용은 차단됩니다. Compose를 직접 관리할 때는 프로젝트 기본 설정에
`.aegis-update/images.json`을 마지막 `-f` 옵션으로 포함합니다.

격리 통합 시험에는 로컬 Alpine 이미지와 다른 Alpine 이미지 다이제스트를
지정합니다. GitHub 증명 검증 호출만 모의 처리하고, 다운로드·컨테이너
교체·헬스체크·롤백은 실제 Docker에서 수행합니다.

```bash
bash tests/update-integration.sh alpine:3.19 alpine@sha256:<다른-Alpine-이미지-다이제스트>
```

운영 적용 전에는 실제 GitHub 증명 발행, 정확한 이미지 조합의 검증,
운영 Compose 사전 점검과 데이터 복구 시간을 확인합니다.


## ⚖️ License

본 프로젝트는 여러 오픈 소스 프로젝트를 통합한 패키지입니다. 각 구성 요소의 라이선스를 준수합니다.

* **Aegis-Proxy-Stack Configuration:** MIT License
* **open-appsec:** Apache 2.0 (Engine) / Machine Learning Model License (Advanced Model)
* **NGINX Proxy Manager:** MIT License
* **CrowdSec:** MIT License
* **GoAccess:** MIT License
