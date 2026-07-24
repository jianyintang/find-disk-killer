<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="136" height="136" alt="FindDiskKiller 앱 아이콘">
  <h1>FindDiskKiller</h1>
  <p><strong>디스크를 계속 사용하는 앱을 한눈에 확인하세요.</strong></p>
  <p>앱별 디스크 I/O, CPU, 네트워크, 파일 활동, 드라이브 상태 정보를 하나의 네이티브 macOS 작업 공간에 모았습니다.</p>
  <p>
    <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> · <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14 이상 · Apple Silicon 및 Intel · 로컬 처리 · 10개 인터페이스 언어</strong></p>
  <p><a href="https://github.com/jianyintang/find-disk-killer/releases/latest">다운로드</a> · <a href="docs/find-disk-killer-product-and-technical-plan.md">제품 모델</a> · <a href="SUPPORT.md">지원</a> · <a href="PRIVACY.md">개인정보 보호</a></p>
</div>

---

Mac이 뜨거워지고 디스크가 계속 바쁜데 프로세스 목록만으로는 이유를 알 수 없을 때,
FindDiskKiller는 조사를 앱 중심의 흐름으로 정리합니다. 지속되는 부하를 찾고 해당 앱의 CPU,
디스크, 네트워크, 파일, 저장 장치 정보를 한곳에서 확인할 수 있습니다.

## 한 화면에서 확인하는 정보

| 작업 공간 | 제공하는 정보 |
| --- | --- |
| **앱 활동** | 최근 5초 CPU, 읽기, 쓰기, 다운로드, 업로드. 정렬과 열 너비 조절, 네이티브 앱 아이콘 지원 |
| **타임라인** | 1분, 15분, 1시간 꺾은선 기록과 포인터 위치의 정확한 시간 및 값 |
| **프로세스 세부 정보** | 독립 창에서 앱의 CPU, 디스크, 네트워크, 파일 근거를 비교 |
| **파일 활동** | 현재 열려 있는 위치와 최근 5분 동안 변경이 관찰된 디렉터리 |
| **파일 접근 추적** | 필요할 때 요청 읽기/쓰기 총량, 최근 5초 속도, 세션 최고값, 활성 파일과 검증된 프로세스 표시 |
| **디스크** | 사용자가 알아보기 쉬운 마운트 볼륨 이름으로 물리 장치 처리량 표시 |
| **드라이브 상태** | macOS가 제공하는 온도, 호스트 쓰기, 마모, 예비 공간, 전원 기록, 오류 정보 |
| **메뉴 막대** | 반복 알림 없이 현재 상태를 조용히 확인 |

## 끊김 없는 조사 흐름

```text
지속 부하 발견
      |
      v
주요 앱 확인  -->  CPU / 디스크 / 다운로드 / 업로드
      |
      v
열린 파일과 최근 변경 확인
      |
      v
필요할 때만 제한된 파일 또는 폴더 추적 시작
      |
      v
물리 장치 처리량과 사용 가능한 상태 정보 확인
```

CPU는 항상 첫 번째에 표시되고 읽기와 쓰기, 다운로드와 업로드는 분리됩니다. 현재 값은 최근 5초로 계산합니다.
행을 살펴보는 동안 목록의 시각적 재정렬만 멈추며 클릭은 그대로 동작합니다. 프로세스 세부 정보는 독립 창으로 열립니다.

## 그럴듯한 정밀도를 만들지 않습니다

- **앱 디스크 I/O**는 프로세스 카운터에서 가져오며 해당 프로세스가 사용한 모든 저장 장치의 합계입니다.
- **장치 처리량**은 물리 장치 카운터이며 `Macintosh HD`, `JianDisk`처럼 익숙한 볼륨 이름으로 표시합니다.
- **최근 변경**은 macOS가 위치 변경을 관찰했다는 뜻이며, 이것만으로 변경한 프로세스를 특정하지 않습니다.
- **파일 접근 추적**은 성공한 시스템 호출이 요청한 바이트를 측정합니다. 캐시, APFS 지연 쓰기,
  압축, Copy-on-Write, 메모리 매핑, 관측 누락 때문에 물리 디스크나 NAND 쓰기와 다를 수 있습니다.
- **드라이브 상태**는 macOS가 실제로 제공한 필드만 표시하며, 없는 값을 0으로 바꾸지 않습니다.

임의의 프로세스가 특정 물리 디스크에 쓴 모든 바이트를 정확히 귀속할 수 있다고 주장하지 않습니다.

## 개인정보 보호 및 권한

모니터링과 분석은 Mac 안에서 처리됩니다. 현재 버전에는 광고, 텔레메트리, 행동 분석,
타사 추적 SDK가 없으며 프로세스 활동, 파일 경로, 모니터링 기록, 디스크 일련번호를 업로드하지 않습니다.

기본 모니터링에는 관리자 승인이 필요하지 않습니다. 사용자가 파일이나 폴더 추적을 명시적으로 시작할 때만
macOS가 서명된 백그라운드 구성 요소의 승인을 요청할 수 있습니다. 이 구성 요소는 고정된 인수와 시간 제한을 가진
`/usr/bin/fs_usage` 세션만 관리하며 셸이나 임의 명령을 실행할 수 없습니다.

자세한 내용은 [개인정보 처리방침](PRIVACY.md)과 [보안 정책](SECURITY.md)을 확인하세요.

## 시스템 요구 사항 및 설치

- macOS 14 이상
- Apple Silicon 또는 Intel Mac
- 관리자 계정은 필요할 때 파일 접근 추적을 활성화하는 경우에만 필요합니다

정식 버전은 Developer ID 서명과 Apple 공증을 거친 universal2 DMG로 제공됩니다.

1. [Releases](https://github.com/jianyintang/find-disk-killer/releases/latest)에서 최신 버전을 다운로드합니다.
2. DMG를 열고 FindDiskKiller를 응용 프로그램 폴더로 드래그합니다.
3. 응용 프로그램 폴더에서 FindDiskKiller를 실행합니다.

각 정식 버전에는 SHA-256이 함께 게시됩니다. Gatekeeper 검증에 실패한 패키지는 시스템 보안을 우회하지 마세요.

## 빌드 및 테스트

```bash
git clone git@github.com:jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp -configuration Release \
  -destination 'generic/platform=macOS' build
swift test
```

깨끗한 커밋에서 서명 및 공증된 웹 배포 파일을 만듭니다.

```bash
make lint test
make release VERSION=1.0.0 BUILD_NUMBER=100
```

`SKIP_NOTARIZATION=1`로 만든 결과물은 로컬 리허설 전용이며 공개해서는 안 됩니다.

## 문서 및 지원

- [제품 및 기술 계획](docs/find-disk-killer-product-and-technical-plan.md)
- [심층 파일 추적 및 SSD 상태 계획](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [웹 배포 점검표](docs/website-release-checklist.md)
- [지원](SUPPORT.md) · [개인정보 보호](PRIVACY.md) · [보안](SECURITY.md) · [타사 고지](THIRD_PARTY_NOTICES.md)

일반 문의는 [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues),
취약점은 [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new)를 통해 비공개로 알려 주세요.

FindDiskKiller는 저장소의 [All Rights Reserved 라이선스](LICENSE)에 따라 배포됩니다.
타사 앱 표시는 관찰된 소프트웨어를 식별하기 위한 것이며 제휴나 보증을 의미하지 않습니다.
