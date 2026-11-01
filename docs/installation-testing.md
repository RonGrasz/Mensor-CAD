# Probar la instalación de MensorCAD

Guía para mantenedores: qué se puede comprobar en Linux, qué exige Windows y qué
sigue pendiente de una persona con AutoCAD. Las pruebas estructurales en Python
no demuestran comportamiento; las suites de Windows tampoco abren AutoCAD.

## Estado de esta unidad

- Se informó una ejecución anterior de GitHub Actions aprobada. Para los cambios actuales de `.github/workflows/build-bundle.yml`, falta asociar un run aprobado a su commit: el pase anterior no se presenta como fallido ni se extrapola a un candidato distinto.
- Las cinco suites funcionales (`tests/Test-Installer.ps1`, `tests/Test-InstallerWindow.ps1`, `tests/Test-InstallerStyle.ps1`, `tests/Test-RemoteInstaller.ps1` y `tests/Test-Bootstrap.ps1`) requieren **Windows PowerShell 5.1** y no se ejecutaron desde aquí.
- La instalación manual del ZIP local fue verificada por el usuario en Windows, incluida la carga del CUIX y los comandos. Esa evidencia no certifica la ruta remota ni las suites automatizadas.
- La comparación diferencial de CLI aislado entre baseline y rama actual sigue pendiente de una ejecución externa en Windows.
- Evidencia humana de una ronda anterior: `tests/Test-RemoteInstaller.ps1` (25 casos) y `tests/Test-Bootstrap.ps1` (17 casos) fueron ejecutadas por una persona en Windows sin fallos ni omisiones. Esa evidencia no cubre las suites local, de ventana ni de estilo, y no se reutiliza aquí como resultado nuevo.
- Conteos de casos escritos, no resultados: local 31, ventana 23, estilo 17. Las tres siguen **pendientes** de ejecución humana en Windows PowerShell 5.1.
- `tests/Test-InstallerStyle.ps1` contiene comprobaciones de la versión estampada, el padding del banner y la regla del resultado, pero **no se ejecutó** en este entorno.
- La versión del instalador ya no se lee en runtime: `tools/build_bundle.py` estampa el marcador de la plantilla. La ejecución de esa estampa se comprueba en Linux con `tests/test_build_bundle.py`; el aspecto visual sigue pendiente de Windows.

No presentes una ejecución no observada como superada.

## Comprobaciones locales en Linux

Usa un directorio temporal de trabajo para no sobrescribir artefactos de origen.
La suite completa de Python debe correr sin escribir bytecode:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s tests -p 'test_*.py' -v
```

Para revisar solo la forma del workflow y la documentación:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s tests -p 'test_workflow_structure.py' -v
```

La construcción real del paquete se puede ensayar en un directorio de salida
temporal. La versión se lee del manifiesto: `AppVersion` y, si falta, `Version`.
El workflow usa exactamente este criterio, sin reescribir la versión desde un tag:

```powershell
[xml]$manifest = Get-Content -LiteralPath PackageContents.xml -Raw
$package = $manifest.ApplicationPackage
$version = $package.AppVersion
if (-not $version) { $version = $package.Version }
if (-not $version) { throw "PackageContents.xml no declara AppVersion ni Version" }
python tools/build_bundle.py --output-dir dist --version $version
```

El detalle del inventario y de las validaciones está en
[`docs/build-bundle.md`](build-bundle.md). Estas comprobaciones estructurales no
certifican el resultado de GitHub Actions para un commit concreto.

## CI: qué hace y qué no hace

El workflow se activa con `push`, `pull_request` y `workflow_dispatch`. Tiene un
solo job en `windows-latest`, permisos de solo lectura (`contents: read`), checkout
sin credenciales persistentes y acciones fijadas por SHA. Ejecuta, en este orden:

1. La suite completa de Python con Python 3.13 y sin bytecode.
2. `tests/Test-Installer.ps1` con Windows PowerShell 5.1.
3. `tests/Test-InstallerWindow.ps1` con Windows PowerShell 5.1.
4. `tests/Test-InstallerStyle.ps1` con Windows PowerShell 5.1.
5. `tests/Test-RemoteInstaller.ps1` con Windows PowerShell 5.1.
6. `tests/Test-Bootstrap.ps1` con Windows PowerShell 5.1.
7. `tools/build_bundle.py` con la versión del manifiesto.
8. La subida de cuatro archivos como artifact.

Las cinco suites funcionales quedan agendadas antes de construir y subir, así que
una suite escrita sin paso en el workflow ya no es cobertura invisible. Esto
describe el texto del workflow; no demuestra que el CI haya pasado.

Si una comprobación falla, su código de salida detiene el job y la subida no se
ejecuta. El workflow no crea releases, tags ni pushes, y no modifica la
autenticación del repositorio.

### Artifact de Actions frente a assets del release

| Entrega | Contenido | Uso |
|---|---|---|
| Artifact `mensorcad-windows` | `MensorCAD-Windows.zip`, `MensorCAD-Windows.zip.sha256`, `Install-MensorCAD.ps1` e `install.ps1` | Descarga temporal para mantenedores dentro de Actions; **no es un release**. |
| Assets del release | Los mismos cuatro nombres | Descarga pública y comando remoto; requieren **publicación humana** separada. |

El artifact no reemplaza a los assets y no hace que el comando remoto funcione.
La publicación de un release es una decisión humana, no una tarea del workflow.

## Suites funcionales en Windows

Ejecuta cada suite en una consola **Windows PowerShell 5.1 de 64 bits** desde la
raíz del repositorio. No uses `pwsh` para estas pruebas.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Installer.ps1
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-InstallerWindow.ps1
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-InstallerStyle.ps1
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-RemoteInstaller.ps1
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Bootstrap.ps1
```

Las cinco suites usan destinos temporales aislados: no escriben en el `Program Files`
real, no piden UAC real y no abren AutoCAD. La suite de ventana sustituye los
diálogos por costuras locales, la de estilo sustituye las sondas de consola y la
remota simula red, API y procesos hijos. Los casos que necesitan symlinks o
junctions se omiten si el entorno no permite crearlos; una omisión no cuenta como
prueba superada. Windows PowerShell 5.1 acepta finales de línea LF y CRLF, y las
pruebas estructurales aceptan ambos; solo rechazan un CR suelto y exigen el BOM
UTF-8.

### Bootstrap corto `install.ps1` (simulado)

`tests/Test-Bootstrap.ps1` extrae el **cuerpo exacto** de los dos comandos cortos
publicados en [`README.md`](../README.md) y
[`docs/remote-installer.md`](remote-installer.md), y los ejecuta en un proceso
PowerShell aparte con dos costuras locales:

| Costura | Qué reemplaza | Qué demuestra |
|---------|---------------|---------------|
| `global:Invoke-RestMethod` | La primera descarga, la de `install.ps1` | Que el comando publicado se ejecuta tal cual, que `-ea Stop` corta un error no terminante y que el llamador sobrevive porque el bootstrap no llama a `exit`. |
| `global:Invoke-WebRequest` | La descarga del `Install-MensorCAD.ps1` real | Que el wrapper crea su carpeta temporal propia, escribe ahí el instalador fixture y lanza un proceso hijo real con `-FromRelease` y el `-Version` exacto. |

El proceso hijo **no** es un motor de instalación: la costura entrega un
instalador fixture que solo escribe en `stdout`/`stderr` y termina con el código
indicado. Así la prueba mide el contrato observable del bootstrap —código real
en `$LASTEXITCODE`, salida reenviada, limpieza de su carpeta y ausencia de
escrituras en `Program Files`— sin descargar nada ni pedir UAC. El fixture deja
un marcador con sus argumentos para comprobar `-Version` y `-NoAnimation`.

Evidencia que debes registrar: el `$LASTEXITCODE` de cada variante (éxito, hijo
con código distinto de cero, fallo de descarga, tag inválido), las líneas
`ERROR:`/`AVISO:` de `stderr`, el `stdout` del hijo fixture en orden y la
ausencia de carpetas `mensorcad-bootstrap-*` residuales.

### Comando remoto de una línea (simulado)

El caso `El comando de una linea publicado se ejecuta en memoria y distingue el
primer fallo` no ejecuta una URL real: extrae el cuerpo exacto de `-Command "..."`
desde [`docs/remote-installer.md`](remote-installer.md) y lo ejecuta en un proceso
PowerShell aparte con dos costuras locales.

| Costura | Qué reemplaza | Qué demuestra |
|---------|---------------|---------------|
| `global:Invoke-RestMethod` | La **primera descarga** del comando | Que el cuerpo se ejecuta en memoria sin `PSScriptRoot`, y que un fallo en esa primera descarga escribe `ERROR:` en español y un código distinto de cero sin llegar a ejecutar el instalador. |
| `global:Invoke-WebRequest` | La red del instalador ya descargado | Que el `ERROR:` del instalador se distingue del `ERROR:` del bootstrap. |

Evidencia que debes registrar de esa ejecución: el código de salida de cada
variante (última versión, primera descarga fallida y versión fijada), la línea
`ERROR:` de `stderr` y la fase que aparece en `stdout` (`[1/5]` o `[2/5]`). Si
la variante de la última versión no muestra `[1/5]`, el script no se ejecutó en
memoria. Si la variante del primer fallo muestra `[1/5]`, el error ocurrió
después de la primera descarga.

Estas variantes **no** demuestran que el comando funcione contra GitHub: no hay
release publicado, así que la prueba pública real del comando de una línea sigue
pendiente de una persona con Windows y acceso al repositorio.

`-ExecutionPolicy Bypass` se aplica solo a ese proceso de PowerShell. No cambia la
política global y no debe acompañarse de cambios en `SECURELOAD`,
`TRUSTEDPATHS` ni `APPAUTOLOAD`.

## Verificación manual con AutoCAD

Trabaja en un equipo de prueba y sobre una **copia** de los dibujos. Cierra AutoCAD
antes de instalar, actualizar o desinstalar; el instalador nunca lo cierra por su
cuenta. No desactives `SECURELOAD`, `TRUSTEDPATHS` ni `APPAUTOLOAD`, y no borres
manualmente carpetas del `Program Files` real.

| Escenario | Pasos mínimos | Evidencia esperada |
|---|---|---|
| Instalación | Extrae el ZIP, ejecuta `Instalar.bat`, acepta UAC y abre AutoCAD. | Instalación con código `0`; CUIX visible; comandos `MC*` disponibles. |
| Dibujo nuevo | Crea un dibujo nuevo sin ejecutar `APPLOAD` y prueba comandos representativos. | Los comandos cargan automáticamente en el dibujo nuevo. |
| Reiniciar | Cierra y vuelve a abrir AutoCAD. | El bundle sigue cargado y los comandos funcionan. |
| Actualizar | Con AutoCAD cerrado, ejecuta `Instalar.bat` con el ZIP nuevo. | Actualización sin errores; versión y comandos esperados; sin archivos ajenos tocados. |
| Desinstalar | Cierra AutoCAD y haz doble clic en `Desinstalar.bat` desde el ZIP extraído (equivale a `Instalar.bat -Uninstall`). | La carpeta propia del bundle desaparece; otros plugins de `ApplicationPlugins` quedan intactos. |

Comprueba también que las entidades ya creadas en los dibujos no se modifican al
desinstalar. Si algo falla, conserva el mensaje completo y no repitas la operación
con permisos elevados adicionales ni deshabilitando controles de seguridad.

## Evidencia que debes registrar

Adjunta la evidencia a la tarea o al PR, no dentro del paquete:

- Fecha, versión de Windows y versión de AutoCAD.
- SHA-256 del ZIP usado, copiado del archivo `.sha256`.
- Comandos exactos ejecutados y su **código de salida**.
- Resultado de cada escenario manual y una captura de la ventana o del error.
- Para el diferencial de CLI aislado, las dos salidas comparadas y el resultado; esta comparación permanece **pendiente** hasta que exista un Windows aislado disponible.

## Lista de comprobación

- [ ] La suite completa de Python pasa sin escribir bytecode.
- [ ] La suite local de Windows pasa en un destino aislado.
- [ ] La suite de la ventana del instalador pasa y conserva los 23 casos escritos.
- [ ] La suite del estilo del instalador pasa y conserva los 17 casos escritos.
- [ ] La suite remota de Windows pasa con red simulada, incluido el comando de una línea con la primera descarga simulada.
- [ ] La suite del bootstrap pasa y demuestra que `iex` no cierra el llamador y que `$LASTEXITCODE` conserva el código real.
- [ ] El paquete se construye con la versión del manifiesto y contiene los cuatro archivos esperados.
- [ ] El dibujo nuevo, el reinicio, la actualización y la desinstalación se probaron con evidencia.
- [ ] El artifact de Actions no se presenta como release ni como descarga pública.
- [ ] El diferencial de CLI aislado se marca como pendiente mientras no se ejecute.
