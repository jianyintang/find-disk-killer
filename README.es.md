<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="Icono de la app FindDiskKiller">
  <h1>FindDiskKiller</h1>
  <p><strong>Descubre qué sigue usando tu disco.</strong></p>
  <p>Empieza por la E/S de disco de las apps y sigue las evidencias por la actividad de archivos, el espacio de agentes de IA y los discos físicos.</p>
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
  <p><strong>macOS 14+ · Apple silicon e Intel · Procesamiento 100 % local</strong></p>
  <p>
    <a href="https://finddiskkiller.com/es/download/"><strong>Descargar para macOS</strong></a> ·
    <a href="https://finddiskkiller.com/es/">Sitio oficial</a> ·
    <a href="https://finddiskkiller.com/es/how-it-works/">Cómo funciona</a> ·
    <a href="PRIVACY.md">Privacidad</a> · <a href="SUPPORT.md">Soporte</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="Área Ahora completa de FindDiskKiller con actividad de disco sostenida, tendencias y apps principales.">
</a>

<p align="center"><sub>Detecta actividad de disco sostenida e identifica las apps responsables. Haz clic para abrir la imagen original.</sub></p>

FindDiskKiller es una herramienta nativa para macOS centrada en una tarea: seguir una actividad de disco sostenida hasta las apps, archivos y dispositivos físicos que la explican. Las evidencias de CPU, disco y red se organizan por app, sin tener que reconstruir el contexto entre varias herramientas del sistema.

<p align="center"><strong>100 %</strong> local　·　<strong>0</strong> datos subidos　·　<strong>10</strong> idiomas　·　<strong>macOS 14+</strong></p>

## Toda la información en un solo espacio

### Espacio de agentes de IA

Codex y Claude acumulan conversaciones, sesiones de subagentes, instantáneas, visualizaciones y bases compartidas. AI Storage inicia el análisis local solo tras una acción explícita, atribuye el espacio a cada thread o session y permite revisarlo antes de la eliminación permanente.

<a href="docs/assets/screenshots/ai-storage-overview.webp"><img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="Resumen de AI Storage con espacio de chats, global y no atribuido para Codex y Claude."></a>

<p align="center"><sub>Mide primero el espacio total del proveedor y separa chats, datos globales y espacio no atribuido.</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="AI Storage de Codex con actividad, subagentes y desglose completo del thread seleccionado."></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="Limpieza por lotes con el ámbito elegido y la recuperación inmediata estimada antes del borrado permanente."></a>
</p>

<p align="center"><sub>Izquierda: atribuir espacio a una conversación　·　Derecha: revisar antigüedad, proyecto y conversaciones antes de borrar</sub></p>

El análisis nunca comienza automáticamente. Se omiten sesiones activas o con identidad cambiada; los proveedores no compatibles nunca provocan escrituras directas en bases ni borrado manual de transcripts. Las sesiones de Claude Desktop y Cowork se eliminan actualmente dentro de Claude Desktop.

### Actividad de apps y evidencias de archivos

Compara las tendencias de CPU, disco y red de una app y pasa a sus ubicaciones abiertas y directorios modificados recientemente. Cuando necesites más evidencia, inicia explícitamente un seguimiento temporal de archivo o carpeta.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="Detalle de Codex con cronologías separadas de CPU, E/S de disco y red."></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="Actividad de archivos de Codex con ubicaciones relacionadas, carpetas escribibles y cambios recientes."></a>
</p>

<p align="center"><sub>Izquierda: comprobar si la actividad persiste　·　Derecha: entrar en las ubicaciones implicadas</sub></p>

<p align="center"><a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="Seguimiento temporal de carpeta con velocidades solicitadas de lectura y escritura, archivos activos y procesos."></a></p>

<p align="center"><sub>El seguimiento solo funciona tras iniciarlo explícitamente y muestra E/S solicitada, archivos activos y sesiones de proceso verificadas.</sub></p>

### Discos físicos y estado

Relaciona nombres conocidos como Macintosh HD o discos externos con el rendimiento del dispositivo físico y consulta los campos SMART/NVMe que macOS y el hardware realmente ofrecen.

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="Área Discos con rendimiento de dispositivos físicos, volúmenes montados y diagnósticos de hardware."></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="Estado del disco con SMART, desgaste, temperatura, escrituras del host, historial de encendido y errores."></a>
</p>

<p align="center"><sub>Izquierda: detectar el dispositivo activo　·　Derecha: consultar los datos de estado que proporciona</sub></p>

## Sin precisión engañosa

FindDiskKiller reúne evidencias relacionadas sin forzar mediciones de distinto significado en un único número:

- **La E/S de apps** son solicitudes de procesos sobre todo el almacenamiento, no tráfico NAND físico.
- **El rendimiento del dispositivo** no puede atribuirse exactamente a un proceso; los totales de apps y dispositivos no tienen que coincidir.
- **Una ubicación modificada recientemente** indica un cambio observado por macOS, pero no identifica por sí sola al autor.
- **La atribución de base de datos de IA** es una estimación lógica indicada, no espacio físico recuperable al instante.

Las evidencias ausentes, parciales o no compatibles se muestran como no disponibles en lugar de sustituirse por cero.

## Privacidad y permisos

Toda la supervisión, el análisis y la visualización ocurren en el Mac. La versión actual no sube nombres de procesos, rutas, números de serie ni historial, y no contiene anuncios, telemetría, analítica ni SDK de seguimiento de terceros.

La supervisión básica de CPU, disco, red, volúmenes y procesos no requiere aprobación de administrador. Solo al iniciar explícitamente un seguimiento macOS puede pedir que apruebes el componente en segundo plano firmado y de propósito limitado; las ubicaciones protegidas también pueden requerir acceso total al disco. Tú controlas siempre el inicio y el final.

Lee la [Política de privacidad](PRIVACY.md) · [Política de seguridad](SECURITY.md).

## Instalación

1. Descarga el último DMG firmado y notarizado desde el [sitio oficial](https://finddiskkiller.com/es/download/).
2. Ábrelo y arrastra FindDiskKiller a Aplicaciones.
3. Inicia FindDiskKiller desde Aplicaciones.

Las versiones oficiales admiten Mac Apple silicon e Intel e incluyen una suma SHA-256. No eludas Gatekeeper si falla la validación de firma o notarización.

## Desarrollo y documentación

<details>
<summary><strong>Compilar desde el código fuente y ejecutar pruebas</strong></summary>

El desarrollo requiere Xcode 16+ y XcodeGen 2.42.0+.

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

La compilación sin firmar cubre la supervisión básica, pero no el seguimiento privilegiado que requiere identidades oficiales de la app y el helper.

</details>

- [Plan de producto y técnico](docs/find-disk-killer-product-and-technical-plan.md)
- [Plan de seguimiento profundo y estado SSD](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Lista de publicación web](docs/website-release-checklist.md)
- [Contribuir](CONTRIBUTING.md)
- [Avisos de terceros](THIRD_PARTY_NOTICES.md)

## Soporte y licencia

Usa [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) para preguntas, fallos y sugerencias. Informa de vulnerabilidades en privado mediante [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) y elimina rutas sensibles, nombres de usuario y números de serie de diagnósticos o capturas.

FindDiskKiller es código abierto bajo la [licencia MIT](LICENSE).
