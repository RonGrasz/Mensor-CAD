# Construir los artefactos de MensorCAD

`tools/build_bundle.py` construye, en una sola pasada y sin red, los seis
archivos que publica una release: el ZIP del complemento con su sidecar, el ZIP
del comando gestor `mensorcad` con su sidecar, el instalador standalone y el
bootstrap corto. Todo se valida antes de escribir y la salida es reproducible
byte a byte.

## Ruta rápida

```bash
python tools/build_bundle.py --output-dir dist --version 0.1.0
```

`--version` debe coincidir con `AppVersion` o `Version` de
`PackageContents.xml`. La salida esperada son estos seis archivos:

| Archivo | Qué es |
|---|---|
| `MensorCAD-Windows.zip` | Complemento de AutoCAD: `MensorCAD.bundle/`, `bundle.sha256`, `Install-MensorCAD.ps1`, `Instalar.bat`, `Desinstalar.bat` y `LICENSE`. |
| `MensorCAD-Windows.zip.sha256` | Sidecar del ZIP del complemento: `64 hex`, dos espacios y `MensorCAD-Windows.zip`. |
| `MensorCAD-CLI.zip` | Gestor: exactamente tres entradas planas, `Install-MensorCAD.ps1`, `mensorcad.cmd` y `mensorcad.ps1`. |
| `MensorCAD-CLI.zip.sha256` | Sidecar del ZIP del gestor: `64 hex`, dos espacios y `MensorCAD-CLI.zip`. |
| `Install-MensorCAD.ps1` | Motor estampado con la versión, para instalar desde una carpeta extraída. |
| `install.ps1` | Bootstrap corto de la entrada remota, copiado **byte a byte** y fuera del ZIP. |

## Detalles

| Tema | Decisión |
|---|---|
| Versión del producto | La plantilla `Install-MensorCAD.ps1` debe contener exactamente un marcador `__MENSORCAD_RELEASE_VERSION__`; se reemplaza solo ese marcador y se conservan BOM y fines de línea. |
| Versión del gestor | `mensorcad.ps1` debe contener exactamente un marcador `__MENSORCAD_MANAGER_VERSION__`. El gestor no lleva la versión del producto y el motor no lleva la del gestor. |
| Lanzador CMD | `mensorcad.cmd` se copia byte a byte dentro del ZIP del gestor; debe ser ASCII sin BOM para que CMD lo ejecute igual en cualquier configuración regional. |
| Bootstrap | `install.ps1` no se estampa, no puede contener marcadores y no viaja dentro de ningún ZIP: es la cuarta salida y se copia sin cambios. |
| Motor protegido | El motor estampado también se guarda como `MensorCAD.bundle/Install-MensorCAD.ps1` y figura en `bundle.sha256` con su propio hash. Así el gestor puede desinstalar sin conexión y el inventario instalado contiene el motor que lo valida. |
| Inventario | `bundle.sha256` cubre todos los archivos de `MensorCAD.bundle/`, incluido el motor protegido, con rutas relativas POSIX y hashes en minúsculas. |
| Reproducibilidad | Entradas ordenadas, marca de tiempo fija `1980-01-01` y compresión deflate: dos construcciones con las mismas fuentes producen los mismos bytes. |
| Colisiones | Ninguna de las seis salidas puede ser el mismo archivo que una fuente: plantilla, bootstrap, gestor o lanzador. Se rechaza antes de escribir. |
| Enlaces y directorios | Se rechazan enlaces simbólicos, directorios en las rutas de salida y temporales preexistentes; el temporal se crea con `mkstemp` y solo se publica con reemplazo atómico por archivo. |
| Fuentes protegidas | `lisp/`, `cuix/`, la plantilla, el bootstrap, el gestor y el lanzador nunca se modifican. La salida no puede estar dentro de `lisp/` ni de `cuix/`. |

### Entradas de la CLI

| Bandera | Valor por defecto | Regla |
|---|---|---|
| `--package-contents` | `PackageContents.xml` | Manifiesto del complemento; `Name` debe ser `MensorCAD` y la versión debe coincidir con `--version`. |
| `--lisp-dir` | `lisp/` | Solo `MC-*.lsp`; cualquier otro archivo se rechaza. |
| `--cuix-dir` | `cuix/` | Árbol OPC completo; se preserva cada byte y cada ruta relativa. |
| `--install-script` | `Install-MensorCAD.ps1` | Plantilla del motor; un único `__MENSORCAD_RELEASE_VERSION__`. |
| `--bootstrap-script` | `install.ps1` | Se copia sin estampar y no puede contener marcadores. |
| `--manager-script` | `mensorcad.ps1` | Gestor; un único `__MENSORCAD_MANAGER_VERSION__`. |
| `--launcher-script` | `mensorcad.cmd` | Lanzador CMD; ASCII sin BOM, copia byte a byte. |
| `--bat-script` | `Instalar.bat` | Entrada de doble clic del ZIP del complemento. |
| `--uninstall-bat-script` | `Desinstalar.bat` | Desinstalador de doble clic del ZIP del complemento. |
| `--license` | `LICENSE` | Licencia del paquete. |

Un rechazo imprime `ERROR: ...` por `stderr`, no escribe nada en `stdout`, deja
la salida anterior intacta y termina con código `1`.

## Verificación

El CI ejecuta solo lo crítico para empaquetar y publicar: no corre el
descubrimiento completo de Python ni las suites de estilo, ventana, instalador
local o remoto. Esas suites siguen en `tests/` para ejecutarlas a mano.

| Etapa del CI | Qué protege |
|---|---|
| `test_build_bundle.py` | Inventario, estampado, sidecars, reproducibilidad y rechazos del constructor. |
| `test_bootstrap_encoding.py` | Arranque real del bootstrap en PowerShell 5.1 con decodificación Latin-1 y BOM. |
| `Test-CliBootstrap.ps1` | Descarga, SHA-256, entradas del ZIP, `PATH` de usuario y rollback del gestor. |
| `Test-Manager.ps1` | Despacho de solo lectura, versiones y desinstalación sin conexión con el motor protegido. |
| `Test-CliDistribution.ps1` | Artefactos reales: motor, inventario, instalación aislada, gestor y desinstalación. |

El orden es: construir `dist` **una sola vez** con la versión del manifiesto,
validar ese mismo `dist` con `Test-CliDistribution.ps1 -BuildDir dist -Version
<versión>` y recién entonces subir los seis artefactos. La suite reutiliza los
archivos existentes y no vuelve a ejecutar el constructor; un `-BuildDir`
incompleto se rechaza en lugar de validar otros bytes. Si todas las etapas
pasan, el artifact publicado es exactamente el que se validó.

```bash
# Crítico (lo que ejecuta el CI)
python3 -m unittest discover -s tests -p 'test_build_bundle.py' -v
python3 -m unittest discover -s tests -p 'test_bootstrap_encoding.py' -v
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests\Test-CliBootstrap.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests\Test-Manager.ps1

# Construir una vez y validar ese mismo dist
python3 tools/build_bundle.py --output-dir dist --version <versión>
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests\Test-CliDistribution.ps1 -BuildDir dist -Version <versión>

# Opcional en local: contrato estructural y suites no críticas
python3 -m unittest discover -s tests -p 'test_cli_distribution.py' -v
```

`Test-CliDistribution.ps1` sin `-BuildDir` construye sus propios artefactos en
el scratch ignorado, así que también sirve como verificación aislada sin tocar
`dist` ni una release publicada. Nunca escribe `Program Files`, el `PATH` ni
pide UAC.

## Checklist

- [ ] `--version` coincide con el manifiesto.
- [ ] El ZIP del gestor tiene exactamente tres entradas planas.
- [ ] `MensorCAD.bundle/Install-MensorCAD.ps1` está en `bundle.sha256`.
- [ ] Los dos sidecars tienen el formato `sha256sum`.
- [ ] Las fuentes (`lisp/`, `cuix/`, plantillas) no cambiaron.
- [ ] El CI construyó `dist` una sola vez y validó ese mismo `dist`.
- [ ] Los artefactos todavía no se publican: esta guía no crea tags ni releases.

## Siguiente paso

La publicación de la release que incluye `MensorCAD-CLI.zip` sigue pendiente.
Mientras no exista, la entrada remota documentada en el README corresponde al
instalador anterior de la release publicada.
