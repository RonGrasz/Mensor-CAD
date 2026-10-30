# Probar la instalación de MensorCAD

Guía para mantenedores: qué se puede comprobar en Linux, qué exige Windows y qué
sigue pendiente de una persona con AutoCAD. Las pruebas estructurales en Python
no demuestran comportamiento; las suites de Windows tampoco abren AutoCAD.

## Estado de esta unidad

- Al momento de escribir esta guía, el workflow `.github/workflows/build-bundle.yml` está escrito, pero **no se ejecutó** en GitHub Actions desde este entorno.
- Las suites `tests/Test-Installer.ps1` y `tests/Test-RemoteInstaller.ps1` requieren **Windows PowerShell 5.1** y no se ejecutaron aquí.
- La instalación manual del ZIP local fue verificada por el usuario en Windows, incluida la carga del CUIX y los comandos. Esa evidencia no certifica la ruta remota ni las suites automatizadas.
- La comparación diferencial de CLI aislado entre baseline y rama actual sigue pendiente de una ejecución externa en Windows.

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
[`docs/build-bundle.md`](build-bundle.md). El workflow no se ha ejecutado: que el
texto sea correcto no es un resultado de CI.

## CI: qué hace y qué no hace

El workflow se activa con `push`, `pull_request` y `workflow_dispatch`. Tiene un
solo job en `windows-latest`, permisos de solo lectura (`contents: read`), checkout
sin credenciales persistentes y acciones fijadas por SHA. Ejecuta, en este orden:

1. La suite completa de Python con Python 3.13 y sin bytecode.
2. `tests/Test-Installer.ps1` con Windows PowerShell 5.1.
3. `tests/Test-RemoteInstaller.ps1` con Windows PowerShell 5.1.
4. `tools/build_bundle.py` con la versión del manifiesto.
5. La subida de tres archivos como artifact.

Si una comprobación falla, su código de salida detiene el job y la subida no se
ejecuta. El workflow no crea releases, tags ni pushes, y no modifica la
autenticación del repositorio.

### Artifact de Actions frente a assets del release

| Entrega | Contenido | Uso |
|---|---|---|
| Artifact `mensorcad-windows` | `MensorCAD-Windows.zip`, `MensorCAD-Windows.zip.sha256` e `Install-MensorCAD.ps1` | Descarga temporal para mantenedores dentro de Actions; **no es un release**. |
| Assets del release | Los mismos tres nombres | Descarga pública y comando remoto; requieren **publicación humana** separada. |

El artifact no reemplaza a los assets y no hace que el comando remoto funcione.
La publicación de un release es una decisión humana, no una tarea del workflow.

## Suites funcionales en Windows

Ejecuta cada suite en una consola **Windows PowerShell 5.1 de 64 bits** desde la
raíz del repositorio. No uses `pwsh` para estas pruebas.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Installer.ps1
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-RemoteInstaller.ps1
```

Ambas suites usan destinos temporales aislados: no escriben en el `Program Files`
real, no piden UAC real y no abren AutoCAD. La suite remota simula red, API y
procesos hijos. Los casos que necesitan symlinks o junctions se omiten si el
entorno no permite crearlos; una omisión no cuenta como prueba superada.

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
| Desinstalar | Cierra AutoCAD y ejecuta `Instalar.bat -Uninstall`. | La carpeta propia del bundle desaparece; otros plugins de `ApplicationPlugins` quedan intactos. |

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
- [ ] La suite remota de Windows pasa con red simulada.
- [ ] El paquete se construye con la versión del manifiesto y contiene los tres archivos esperados.
- [ ] El dibujo nuevo, el reinicio, la actualización y la desinstalación se probaron con evidencia.
- [ ] El artifact de Actions no se presenta como release ni como descarga pública.
- [ ] El diferencial de CLI aislado se marca como pendiente mientras no se ejecute.
