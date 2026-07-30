<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="Значок приложения FindDiskKiller">
  <h1>FindDiskKiller</h1>
  <p><strong>Узнайте, что продолжает использовать диск.</strong></p>
  <p>Начните с дискового ввода-вывода приложений и проследите данные через файловую активность, хранилище AI Agents и физические диски.</p>
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
  <p><strong>macOS 14+ · Apple silicon и Intel · 100% локальная обработка</strong></p>
  <p>
    <a href="https://finddiskkiller.com/ru/download/"><strong>Скачать для macOS</strong></a> ·
    <a href="https://finddiskkiller.com/ru/">Официальный сайт</a> ·
    <a href="https://finddiskkiller.com/ru/how-it-works/">Как это работает</a> ·
    <a href="PRIVACY.md">Конфиденциальность</a> · <a href="SUPPORT.md">Поддержка</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="Полный раздел Сейчас FindDiskKiller с длительной дисковой активностью, тенденциями и ведущими приложениями.">
</a>

<p align="center"><sub>Найдите длительную дисковую активность и приложения, которые её вызывают. Нажмите, чтобы открыть оригинал.</sub></p>

FindDiskKiller — нативный инструмент macOS для одной задачи: проследить длительную дисковую активность до приложений, файлов и физических устройств за ней. Данные ЦП, диска и сети организованы вокруг приложений, поэтому контекст не приходится собирать из нескольких системных утилит.

<p align="center"><strong>100%</strong> локально　·　<strong>0</strong> данных отправлено　·　<strong>10</strong> языков　·　<strong>macOS 14+</strong></p>

## Вся информация в одном рабочем пространстве

### Хранилище AI Agents

Codex и Claude накапливают разговоры, сессии субагентов, снимки, визуализации и общие базы. AI Storage запускает локальный анализ только после явного действия, связывает место с thread или session и позволяет проверить всё перед окончательным удалением.

<a href="docs/assets/screenshots/ai-storage-overview.webp"><img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="Обзор AI Storage с раздельным пространством чатов, общими и неатрибутированными данными Codex и Claude."></a>

<p align="center"><sub>Сначала измерьте всё пространство провайдера, затем разделите чаты, общие и неатрибутированные данные.</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="Codex AI Storage с активностью, субагентами и полным составом выбранного thread."></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="Пакетная очистка с выбранной областью и оценкой немедленного освобождения перед удалением."></a>
</p>

<p align="center"><sub>Слева: связать место с разговором　·　Справа: проверить возраст, проект и разговоры перед удалением</sub></p>

Анализ никогда не начинается автоматически. Активные сессии и сессии с изменившейся идентичностью пропускаются; неподдерживаемый провайдер не приводит к прямой записи в базу или ручному удалению transcript. Сессии Claude Desktop и Cowork сейчас удаляются внутри Claude Desktop.

### Активность приложений и файловые данные

Сравните тенденции ЦП, диска и сети приложения, затем перейдите к открытым расположениям и недавно изменённым каталогам. Если нужны более точные данные, явно запустите ограниченную по времени трассировку файла или папки.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="Сведения Codex с раздельными графиками ЦП, дискового ввода-вывода и сети."></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="Файловая активность Codex со связанными расположениями, доступными для записи папками и недавними изменениями."></a>
</p>

<p align="center"><sub>Слева: определить устойчивость активности　·　Справа: перейти к затронутым расположениям</sub></p>

<p align="center"><a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="Ограниченная трассировка папки с запрошенными скоростями чтения и записи, активными файлами и процессами."></a></p>

<p align="center"><sub>Трассировка работает только после явного запуска и показывает запрошенный ввод-вывод, активные файлы и проверенные сессии процессов.</sub></p>

### Физические диски и состояние

Свяжите знакомые имена томов вроде Macintosh HD или внешних дисков с пропускной способностью физического устройства и просмотрите поля SMART/NVMe, которые реально предоставляет macOS и оборудование.

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="Раздел Диски с пропускной способностью физических устройств, подключёнными томами и диагностикой."></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="Состояние диска со SMART, износом, температурой, записью хоста, историей питания и ошибками носителя."></a>
</p>

<p align="center"><sub>Слева: определить активное устройство　·　Справа: проверить сообщаемые данные состояния</sub></p>

## Без ложной точности

FindDiskKiller показывает связанные данные вместе, не сводя измерения с разным смыслом в одно число:

- **Ввод-вывод приложения** — запросы процессов ко всему хранилищу, а не физический трафик NAND.
- **Пропускную способность устройства** нельзя точно приписать одному процессу; итоги приложений и устройств не обязаны совпадать.
- **Недавно изменённое расположение** означает наблюдавшееся macOS изменение, но само по себе не называет автора.
- **Атрибуция базы AI** — явно отмеченная логическая оценка, а не немедленно освобождаемое физическое место.

Отсутствующие, частичные и неподдерживаемые данные показываются как недоступные, а не заменяются нулём.

## Конфиденциальность и разрешения

Мониторинг, анализ и отображение выполняются на Mac. Текущая версия не передаёт имена процессов, пути, серийные номера или историю и не содержит рекламы, телеметрии, аналитики или сторонних SDK отслеживания.

Базовый мониторинг ЦП, диска, сети, томов и процессов не требует прав администратора. Только при явном запуске трассировки macOS может попросить одобрить подписанный фоновый компонент фиксированного назначения; защищённым расположениям может потребоваться полный доступ к диску. Начало и окончание всегда контролируете вы.

Прочитайте полную [Политику конфиденциальности](PRIVACY.md) · [Политику безопасности](SECURITY.md).

## Установка

1. Скачайте последний подписанный и нотариально заверенный DMG с [официального сайта](https://finddiskkiller.com/ru/download/).
2. Откройте его и перетащите FindDiskKiller в «Программы».
3. Запустите FindDiskKiller из «Программ».

Официальные версии поддерживают Mac с Apple silicon и Intel и содержат SHA-256. Не обходите Gatekeeper, если проверка подписи или нотариализации не прошла.

## Разработка и документация

<details>
<summary><strong>Сборка из исходников и запуск тестов</strong></summary>

Для разработки нужны Xcode 16+ и XcodeGen 2.42.0+.

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

Неподписанная сборка покрывает базовый мониторинг, но не привилегированную трассировку, которой нужны официальные идентификаторы App и helper.

</details>

- [План продукта и технологий](docs/find-disk-killer-product-and-technical-plan.md)
- [План глубокой трассировки и состояния SSD](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Контрольный список веб-релиза](docs/website-release-checklist.md)
- [Участие в разработке](CONTRIBUTING.md)
- [Уведомления третьих сторон](THIRD_PARTY_NOTICES.md)

## Поддержка и лицензия

Для вопросов, ошибок и предложений используйте [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues). Об уязвимостях сообщайте приватно через [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) и удаляйте чувствительные пути, имена пользователей и серийные номера из диагностики и снимков.

FindDiskKiller распространяется с открытым исходным кодом по [лицензии MIT](LICENSE).
