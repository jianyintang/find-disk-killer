<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="136" height="136" alt="Icono de la app FindDiskKiller">
  <h1>FindDiskKiller</h1>
  <p><strong>Descubre qué app mantiene ocupado tu disco.</strong></p>
  <p>E/S de disco, CPU, red, actividad de archivos y estado de las unidades en un único espacio de trabajo nativo para macOS.</p>
  <p>
    <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> · <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14+ · Apple Silicon e Intel · Procesamiento local · Interfaz en 10 idiomas</strong></p>
  <p><a href="https://finddiskkiller.com/es/download/">Descargar</a> · <a href="https://finddiskkiller.com/es/">Sitio oficial</a> · <a href="docs/find-disk-killer-product-and-technical-plan.md">Modelo del producto</a> · <a href="SUPPORT.md">Soporte</a> · <a href="PRIVACY.md">Privacidad</a></p>
</div>

---

<p align="center"><img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="Espacio Ahora de FindDiskKiller con actividad de disco sostenida, tendencias de recursos y las apps principales."></p>
<p align="center"><sub>Detecta actividad de disco sostenida e identifica las apps que la provocan.</sub></p>

Cuando el Mac se calienta y el disco no deja de trabajar, una lista de procesos
no siempre explica la causa. FindDiskKiller organiza la investigación alrededor
de las apps: detecta una carga sostenida, identifica la app principal y reúne su
CPU, E/S de disco, red, archivos y contexto de almacenamiento.

## También mide el espacio de los agentes de IA

AI Storage solo mide los datos de Codex y Claude después de una acción explícita, y atribuye el espacio identificable a cada thread/session, conversación principal y subagente recursivo. Los archivos medidos y las estimaciones de base de datos se mantienen separados; la evidencia incompleta nunca se presenta como exacta.

<p align="center"><img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="Resumen de AI Storage con espacio de chats, global y no atribuido para Codex y Claude."></p>

<p align="center"><img src="docs/assets/screenshots/ai-storage-threads.webp" width="100%" alt="AI Storage de Codex con actividad, subagentes y atribución de espacio por thread."></p>

Selecciona una antigüedad, proyecto o conversaciones y revisa el espacio de liberación inmediata estimado antes del borrado permanente. Codex usa el thread/delete oficial y las sesiones independientes de Claude Code usan el Agent SDK oficial. Se omiten elementos activos, modificados o no compatibles, sin escribir SQLite directamente ni borrar transcripts a mano. Claude Desktop/Cowork se elimina actualmente desde Claude Desktop.

<p align="center"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="82%" alt="Limpieza por lotes de chats de agentes de IA con revisión del espacio estimado antes del borrado permanente."></p>

## Todo lo importante de un vistazo

| Espacio | Qué muestra |
| --- | --- |
| **Actividad de las apps** | CPU, lecturas, escrituras, descargas y subidas de los últimos 5 segundos; columnas ordenables y ajustables, con iconos nativos |
| **Cronología** | Gráficas de segmentos rectos para 1 minuto, 15 minutos y 1 hora, con hora y valores exactos al pasar el puntero |
| **Detalles del proceso** | Ventanas independientes para comparar CPU, disco, red y evidencias de archivos |
| **Actividad de archivos** | Ubicaciones abiertas y carpetas en las que se han observado cambios durante los últimos 5 minutos |
| **Seguimiento de acceso** | Bajo demanda: lecturas y escrituras solicitadas, velocidades de 5 segundos, picos de sesión, archivos activos y procesos verificados |
| **Discos** | Rendimiento de dispositivos físicos mediante nombres de volúmenes comprensibles, también para almacenamiento externo |
| **Estado de la unidad** | Temperatura, escrituras del host, desgaste, reserva, historial de encendido y errores cuando macOS los ofrece |
| **Barra de menús** | Estado actual de forma discreta, sin notificaciones repetitivas |

## Una vista completa, de la app al disco

### Empieza por la app responsable

<p align="center"><img src="docs/assets/screenshots/app-codex-overview.webp" width="100%" alt="Detalle de la app Codex con cronologías separadas de CPU, E/S de disco y red."></p>

### Continúa con ubicaciones y accesos acotados

<p align="center"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="100%" alt="Actividad de archivos de Codex con ubicaciones relacionadas, carpetas escribibles y cambios recientes."></p>

<p align="center"><img src="docs/assets/screenshots/folder-access-trace.webp" width="100%" alt="Seguimiento temporal de una carpeta con velocidades solicitadas de lectura y escritura, archivos activos y procesos que acceden."></p>

### Termina con el almacenamiento y su estado

<p align="center"><img src="docs/assets/screenshots/disk-live-activity.webp" width="100%" alt="Espacio Discos con rendimiento de dispositivos físicos, volúmenes montados y diagnósticos de hardware."></p>

<p align="center"><img src="docs/assets/screenshots/disk-health.webp" width="100%" alt="Estado de la unidad con SMART, desgaste, temperatura, escrituras del host, historial de encendido y errores de medios."></p>

## Una investigación con un solo contexto

```text
Actividad sostenida
        |
        v
App principal  -->  CPU / disco / descarga / subida
        |
        v
Archivos abiertos y cambios recientes
        |
        v
Seguimiento opcional y limitado de un archivo o carpeta
        |
        v
Rendimiento físico y datos de estado disponibles
```

La CPU aparece siempre primero. Lectura y escritura, descarga y subida se
mantienen separadas. Los valores actuales usan los últimos cinco segundos. Al
examinar una fila solo se pausa su reordenación visual: sigue siendo posible
hacer clic. Los detalles se abren en ventanas independientes.

## Sin una precisión engañosa

- La **E/S de disco de la app** procede de contadores de proceso e incluye todo el almacenamiento que utiliza.
- El **rendimiento del dispositivo** procede de contadores físicos y se presenta con nombres como `Macintosh HD` o `ExternalSSD`.
- Los **cambios recientes** indican que macOS observó un cambio; por sí solos no identifican el proceso responsable.
- El **seguimiento de acceso** mide los bytes solicitados por llamadas al sistema correctas. Caché, escritura diferida de APFS, compresión, copia en escritura, mapeo de memoria y lagunas de cobertura hacen que difiera de las escrituras físicas o NAND.
- El **estado de la unidad** contiene solo los campos que macOS comunica. Un dato ausente sigue sin estar disponible y no se convierte en cero.

FindDiskKiller no afirma que pueda atribuir exactamente cada byte de un proceso a un disco físico concreto.

## Privacidad y permisos

La supervisión y el análisis se realizan localmente. La versión actual no
incluye publicidad, telemetría, análisis de uso ni SDK de seguimiento de
terceros. Tampoco sube actividad de procesos, rutas de archivos, historial de
supervisión ni números de serie de discos.

La supervisión básica no requiere aprobación de administrador. Solo al iniciar
explícitamente el seguimiento de un archivo o carpeta, macOS puede solicitar la
aprobación del componente en segundo plano firmado. Este solo puede supervisar
una sesión limitada de `/usr/bin/fs_usage` con parámetros fijos; no puede
ejecutar un shell ni comandos arbitrarios.

Consulta la [Política de privacidad](PRIVACY.md) y la [Política de seguridad](SECURITY.md).

## Requisitos e instalación

- macOS 14 o posterior
- Mac con Apple Silicon o Intel
- Cuenta de administrador solo para activar el seguimiento de acceso bajo demanda

Cuando están disponibles, las versiones oficiales se distribuyen como DMG universal2 firmado con Developer ID y notarizado por Apple.

1. Descarga la versión más reciente desde el [sitio oficial](https://finddiskkiller.com/es/download/).
2. Abre el DMG y arrastra FindDiskKiller a Aplicaciones.
3. Inicia FindDiskKiller desde Aplicaciones.

Cada versión oficial publica su SHA-256. No evites Gatekeeper si un paquete no supera la validación.

## Compilación y pruebas

El desarrollo requiere Xcode 16 o posterior y XcodeGen 2.42.0 o posterior.

```bash
git clone https://github.com/jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
swift test
```

La compilación de desarrollo sin firma permite validar la supervisión básica,
pero no ejecutar el seguimiento privilegiado de archivos o carpetas. La app y
el helper se autentican entre sí mediante el Team ID del mantenedor, por lo que
ese flujo debe comprobarse con una compilación oficial firmada. La aprobación
del componente en segundo plano y el acceso total al disco para ubicaciones
protegidas son permisos independientes de macOS.

Para crear una versión firmada y notarizada desde un commit limpio:

```bash
make lint test
make release VERSION=1.0.0 BUILD_NUMBER=100
```

Los artefactos creados con `SKIP_NOTARIZATION=1` son solo ensayos locales y nunca deben publicarse.

## Documentación y soporte

- [Plan de producto y técnico](docs/find-disk-killer-product-and-technical-plan.md)
- [Plan de seguimiento profundo de archivos y estado del SSD](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Lista de publicación web](docs/website-release-checklist.md)
- [Cómo contribuir](CONTRIBUTING.md)
- [Soporte](SUPPORT.md) · [Privacidad](PRIVACY.md) · [Seguridad](SECURITY.md) · [Avisos de terceros](THIRD_PARTY_NOTICES.md)

Usa [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) para consultas habituales.
Informa de vulnerabilidades en privado mediante [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new).

FindDiskKiller es software de código abierto bajo la [licencia MIT](LICENSE).
Las marcas de apps de terceros solo identifican software observado y no implican afiliación ni respaldo.
