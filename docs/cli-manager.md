# Comando gestor `mensorcad`

`mensorcad` es un comando persistente de Windows que separa dos pasos: registrar
el gestor una vez y, después, instalar o administrar el complemento de AutoCAD
cuando el usuario lo pida. El gestor se instala **por usuario** en
`%LOCALAPPDATA%\MensorCAD\cli`; el complemento se instala **por equipo** en
`%ProgramFiles%\Autodesk\ApplicationPlugins\MensorCAD.bundle`.

Este documento describe el comportamiento implementado. No afirma que los assets
de release ya estén publicados ni promete un ZIP nuevo: mientras el release no
publique `MensorCAD-CLI.zip` y su `.sha256`, el flujo de instalación del gestor no
está disponible para usuarios finales.

## Requisitos

- Windows de 64 bits y Windows PowerShell 5.1 (`powershell.exe`).
- AutoCAD de 64 bits para usar el complemento.
- El ZIP de instalación (`MensorCAD-Windows.zip` y su `.sha256`) se conserva como
  alternativa manual.

## Comandos

| Comando | Qué hace |
| --- | --- |
| `mensorcad` | Muestra un resumen del estado. No instala nada de forma automática. |
| `mensorcad install` / `mensorcad -i` | Instala el complemento con la última release publicada. |
| `mensorcad update` | Actualiza el complemento sin bajar de versión. |
| `mensorcad uninstall` | Quita el complemento y conserva el comando gestor. |
| `mensorcad status` | Muestra la versión del gestor y la versión instalada del complemento. |
| `mensorcad --help` | Muestra la ayuda. |
| `mensorcad --version` | Muestra la versión del gestor (`--version` es del gestor, no del complemento). |

### Instalar y actualizar

`install` y `update` resuelven la release una sola vez, fijan ese tag y delegan en
`Install-MensorCAD.ps1`, el motor ya validado. El motor descarga el ZIP y su
`.sha256`, verifica el hash, inspecciona el contenido y recién entonces ejecuta el
instalador extraído con elevación UAC. La salida jade y los pasos reales son los
del motor: el gestor no agrega porcentajes ni animaciones ficticias.

- Si `update` no encuentra el complemento, termina con un error que sugiere
  `mensorcad install`; no consulta la red.
- Si la versión instalada y la disponible coinciden, `update` informa
  `Ya estás actualizado` y no reinstala nada.
- `install` tampoco reinstala si ya coincide y no baja de versión un complemento
  existente. Si la comparación no es posible (por ejemplo, una versión con
  sufijo), tanto `install` como `update` rechazan la operación sin modificar
  nada.
- Si la descarga o la verificación del ZIP fallan, el motor no toca la
  instalación anterior.

El SHA-256 verifica integridad y mismo origen; **no autentica al publicador**. La
confianza sigue dependiendo del repositorio y del release.

### Desinstalar sin conexión

`uninstall` no descarga nada. Valida primero la propiedad y las rutas sin puntos
de reanálisis, y después invoca el motor protegido que vive dentro del propio
complemento:
`%ProgramFiles%\Autodesk\ApplicationPlugins\MensorCAD.bundle\Install-MensorCAD.ps1`.
El gestor nunca se eleva a sí mismo ni ejecuta el motor cacheado y escribible que
tiene al lado.

- El comando gestor, el `PATH` y la carpeta `%LOCALAPPDATA%\MensorCAD\cli` se
  conservan para poder reinstalar.
- Si el complemento no está instalado, informa que no hay nada que desinstalar y
  termina bien, sin tocar el gestor ni el `PATH`.
- Si AutoCAD está abierto, el motor avisa y sale sin cerrarlo.
- Una instalación anterior que no incluya `Install-MensorCAD.ps1` no se puede
  quitar con el gestor: se muestra un mensaje accionable para descargar el ZIP y
  ejecutar `Desinstalar.bat` desde esa carpeta. No se descarga nada desde el
  gestor.

### Consultar el estado

`mensorcad`, `mensorcad status`, `mensorcad --help` y `mensorcad --version` son de
solo lectura: no usan la red, no piden UAC y no escriben archivos. `status`
muestra la versión del gestor y la versión instalada leída de
`PackageContents.xml` (`AppVersion` o, si falta, `Version`). `--help` y
`--version` funcionan incluso sin una instalación válida y sin el motor junto al
comando.

## Códigos de salida

Todo comando, opción o argumento adicional no admitido se rechaza antes de la
red, la elevación o cualquier escritura. Los errores de tipeo conocidos (por
ejemplo `unistall`) se explican con una sugerencia; `mensorcad help` también se
rechaza y sugiere `--help`.

| Código | Significado |
| --- | --- |
| `0` | La operación terminó bien. |
| `1` | Error local o fallo del motor; no se modificó nada cuando el error ocurrió antes de la mutación. |
| `2` | Entrada inválida: comando, opción o argumentos adicionales no admitidos. Se rechaza antes de la red, la elevación o cualquier escritura, y no toca archivos ni la instalación. |
| otro | `install`, `update` y `uninstall` propagan el código exacto del motor. |

## Lanzador CMD

`mensorcad.cmd` usa `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`
con `-NoProfile -ExecutionPolicy Bypass -File`, reenvía `%*` sin reinterpretar y
termina con `exit /b %ERRORLEVEL%`, por lo que el código del gestor llega intacto
a CMD y a PowerShell.

## Limitaciones conocidas

- El gestor no se actualiza a sí mismo: la actualización del propio gestor queda
  para una segunda etapa.
- El SHA-256 es integridad de mismo origen, no autenticación del publicador.
- Las pruebas automatizadas no piden UAC ni abren AutoCAD. La instalación real, la
  elevación y el comportamiento del complemento en AutoCAD requieren verificación
  manual.
- La frontera de privilegios es la del motor existente: el gestor no eleva su
  propio proceso. La desinstalación eleva únicamente el motor protegido del
  complemento.
- El entorno del instalador (PowerShell 5.1 de 64 bits, `Program Files`, UAC y
  AutoCAD cerrado) sigue siendo un requisito manual, no una garantía de las
  pruebas.
- No hay assets de release nuevos prometidos por este documento.
