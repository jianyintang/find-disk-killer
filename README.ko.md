<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="FindDiskKiller 앱 아이콘">
  <h1>FindDiskKiller</h1>
  <p><strong>무엇이 디스크를 계속 사용하는지 확인하세요.</strong></p>
  <p>앱 디스크 I/O에서 시작해 파일 활동, AI Agent 저장 공간, 물리 디스크 근거까지 한 흐름으로 추적합니다.</p>
  <p>
    <a href="README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> ·
    <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14+ · Apple silicon 및 Intel · 100% 로컬 처리</strong></p>
  <p>
    <a href="https://finddiskkiller.com/ko/download/"><strong>macOS용 다운로드</strong></a> ·
    <a href="https://finddiskkiller.com/ko/">공식 웹사이트</a> ·
    <a href="https://finddiskkiller.com/ko/how-it-works/">작동 방식</a> ·
    <a href="PRIVACY.md">개인정보 보호</a> ·
    <a href="SUPPORT.md">지원</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="지속적인 디스크 활동, 리소스 추세, 주요 앱을 완전히 보여 주는 FindDiskKiller 현재 작업 공간.">
</a>

<p align="center"><sub>지속적인 디스크 활동을 찾고 원인이 되는 앱을 확인합니다. 이미지를 클릭하면 원본을 볼 수 있습니다.</sub></p>

FindDiskKiller는 한 가지 작업에 집중하는 네이티브 macOS 도구입니다. 지속적인 디스크 활동 신호에서 원인이 되는 앱, 파일, 물리 장치까지 추적합니다. CPU, 디스크, 네트워크 근거를 앱 중심으로 모아 여러 시스템 도구 사이에서 정보를 조합할 필요가 없습니다.

<p align="center">
  <strong>100%</strong> 로컬 처리　·　<strong>0</strong> 데이터 업로드　·　<strong>10</strong>개 언어　·　<strong>macOS 14+</strong>
</p>

## 모든 정보를 하나의 작업 공간에

### AI Agent 저장 공간

Codex와 Claude는 대화, 하위 에이전트 세션, 스냅샷, 시각화, 공유 데이터베이스를 축적합니다. AI Storage는 명시적으로 클릭한 후에만 로컬 분석을 시작하고 저장 공간을 thread 또는 session별로 귀속하며 영구 삭제 전에 전체 검토를 제공합니다.

<a href="docs/assets/screenshots/ai-storage-overview.webp">
  <img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="Codex와 Claude의 대화, 전역, 미귀속 공간을 구분한 AI Storage 개요.">
</a>

<p align="center"><sub>제공자 전체 사용량을 먼저 측정한 뒤 대화, 전역 데이터, 미귀속 공간을 구분합니다.</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="활동 시간, 하위 에이전트 수, 선택한 thread의 전체 저장 공간 구성을 보여 주는 Codex AI Storage."></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="영구 삭제 전에 선택 범위와 예상 즉시 확보 공간을 보여 주는 AI Agent 일괄 정리."></a>
</p>

<p align="center"><sub>왼쪽: 개별 대화에 저장 공간 귀속　·　오른쪽: 영구 삭제 전 기간, 프로젝트, 대화 범위 검토</sub></p>

분석은 자동으로 시작되지 않습니다. 활동 중이거나 ID가 변경된 세션은 건너뛰며 지원되지 않는 제공자에서 데이터베이스 직접 쓰기나 transcript 수동 삭제로 전환하지 않습니다. Claude Desktop과 Cowork 세션은 현재 Claude Desktop 안에서 삭제해야 합니다.

### 앱 활동 및 파일 근거

앱의 CPU, 디스크 I/O, 네트워크 추세를 비교한 다음 열린 위치와 최근 변경된 디렉터리로 이동합니다. 더 명확한 근거가 필요할 때만 시간 제한 파일 또는 폴더 추적을 명시적으로 시작합니다.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="CPU, 디스크 I/O, 네트워크 타임라인을 분리해 보여 주는 Codex 앱 세부 정보."></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="관련 위치, 쓰기 가능한 폴더, 최근 변경을 보여 주는 Codex 파일 활동."></a>
</p>

<p align="center"><sub>왼쪽: 리소스 활동의 지속 여부 판단　·　오른쪽: 앱이 관련된 위치로 이동</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="요청 읽기 및 쓰기 속도, 활성 파일, 접근 프로세스를 보여 주는 시간 제한 폴더 추적."></a>
</p>

<p align="center"><sub>추적은 명시적으로 시작한 뒤에만 실행되며 요청 I/O, 활성 파일, 검증된 프로세스 세션을 표시합니다.</sub></p>

### 물리 디스크 및 상태

Macintosh HD와 외장 드라이브처럼 익숙한 볼륨 이름을 물리 장치 처리량에 연결하고 macOS와 하드웨어가 실제 제공하는 SMART/NVMe 상태 필드를 확인합니다.

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="물리 장치 처리량, 마운트 볼륨, 하드웨어 진단을 보여 주는 디스크 작업 공간."></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="SMART 상태, 마모, 온도, 호스트 쓰기, 전원 기록, 미디어 오류를 보여 주는 디스크 상태 화면."></a>
</p>

<p align="center"><sub>왼쪽: 사용 중인 물리 장치 확인　·　오른쪽: 장치가 보고하는 상태 근거 확인</sub></p>

## 거짓 정밀도를 만들지 않습니다

FindDiskKiller는 관련 근거를 함께 보여 주지만 의미가 다른 측정을 하나의 숫자로 강제하지 않습니다:

- **앱 I/O**는 모든 저장 장치에 대한 프로세스 요청이며 물리 NAND 읽기/쓰기가 아닙니다.
- **물리 장치 처리량**을 단일 프로세스에 정확히 귀속할 수 없으며 앱 합계와 장치 합계가 같을 필요도 없습니다.
- **최근 변경된 위치**는 macOS가 변경을 관찰했다는 뜻이며 그 자체로 작성자를 확인하지 않습니다.
- **AI 데이터베이스 귀속**은 명확히 표시된 논리 추정치이며 즉시 확보 가능한 물리 공간이 아닙니다.

누락되거나 부분적이거나 지원되지 않는 근거는 0이 아니라 사용할 수 없음으로 표시합니다.

## 개인정보 보호 및 권한

모든 모니터링, 분석, 표시는 Mac에서 이루어집니다. 현재 버전은 프로세스 이름, 파일 경로, 디스크 일련 번호, 모니터링 기록을 업로드하지 않으며 광고, 텔레메트리, 분석, 타사 추적 SDK도 포함하지 않습니다.

기본 CPU, 디스크, 네트워크, 볼륨, 프로세스 모니터링에는 관리자 승인이 필요 없습니다. 파일 또는 디렉터리 추적을 명시적으로 시작할 때만 macOS가 서명된 고정 목적 백그라운드 구성 요소 승인을 요청할 수 있으며 보호된 위치에는 전체 디스크 접근 권한이 필요할 수 있습니다. 추적 시작과 중지는 항상 사용자가 제어합니다.

전체 내용은 [개인정보 보호정책](PRIVACY.md) · [보안 정책](SECURITY.md).

## 설치

1. [공식 웹사이트](https://finddiskkiller.com/ko/download/)에서 최신 서명 및 공증 DMG를 다운로드합니다.
2. DMG를 열고 FindDiskKiller를 응용 프로그램 폴더로 드래그합니다.
3. 응용 프로그램에서 FindDiskKiller를 실행합니다.

공식 버전은 Apple silicon과 Intel Mac을 지원하며 SHA-256 체크섬을 제공합니다. 서명 또는 공증 검증에 실패하면 Gatekeeper를 우회하지 마세요.

## 개발 및 문서

<details>
<summary><strong>소스에서 빌드하고 테스트 실행</strong></summary>

개발에는 Xcode 16+ 및 XcodeGen 2.42.0+가 필요합니다.

```bash
git clone https://github.com/jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild \
  -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build
make test
```

서명되지 않은 빌드는 기본 모니터링을 검증할 수 있지만 공식 서명 App 및 helper ID가 필요한 권한 파일 추적은 수행할 수 없습니다.

</details>

- [제품 및 기술 계획](docs/find-disk-killer-product-and-technical-plan.md)
- [심층 파일 추적 및 SSD 상태 계획](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [웹 배포 점검표](docs/website-release-checklist.md)
- [기여](CONTRIBUTING.md)
- [타사 고지](THIRD_PARTY_NOTICES.md)

## 지원 및 라이선스

질문, 버그, 기능 요청은 [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues)를 이용하세요. 취약점은 [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new)를 통해 비공개로 신고하고 진단 또는 스크린샷에서 민감한 경로, 사용자 이름, 디스크 일련 번호를 제거하세요.

FindDiskKiller는 [MIT License](LICENSE)로 오픈 소스로 제공됩니다.
