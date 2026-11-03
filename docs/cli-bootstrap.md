# Bootstrap del gestor `mensorcad`

Este documento describe como se instala MensorCAD en dos pasos: un bootstrap
corto que instala **solo el gestor de linea de comandos** en la carpeta del
usuario y lo registra en el `PATH` del usuario actual. El complemento de AutoCAD
**no** se instala aqui y no se pide UAC.

El bootstrap acepta dos origenes del ZIP del gestor: el **release publicado** de
GitHub (por defecto) o un **ZIP construido localmente** con `-LocalZip`, que no
usa la red y sirve para probar el circuito completo antes de publicar.

La instalacion tiene dos pasos a proposito:

1. el bootstrap publica el comando `mensorcad`;
2. el usuario decide cuando instalar o actualizar el complemento con
   `mensorcad install`.

Los assets de release de esta etapa todavia no estan publicados; estos comandos
funcionaran cuando el release oficial incluya `install.ps1`, `MensorCAD-CLI.zip`
y `MensorCAD-CLI.zip.sha256`. La ruta local no depende de esa publicacion.

---

## Paso 1: instalar el gestor

Release mas reciente, con el comando corto que se publica en el README:

```powershell
irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/install.ps1' -ea Stop | iex
```

Release fijado, para reproducir una version concreta:

```powershell
&([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v1.2.3/install.ps1' -ea Stop))) -Version v1.2.3
```

Variante sin animacion (compatibilidad con el bootstrap anterior; este flujo
solo escribe texto, asi que no cambia ningun paso):

```powershell
&([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v1.2.3/install.ps1' -ea Stop))) -Version v1.2.3 -NoAnimation
```

Requiere Windows con Windows PowerShell 5.1. El comando `irm ... | iex` ejecuta
el texto publicado en la sesion actual; no cierra la terminal.

## Paso 2: instalar o actualizar el complemento

```powershell
mensorcad install
```

`mensorcad install` y `mensorcad update` son comandos del gestor, no de este
bootstrap: el bootstrap nunca ejecuta el instalador del complemento.

---

## Instalacion local desde el ZIP construido (sin publicar)

Para probar el mismo circuito sin publicar ninguna release, construya los
artefactos y pase el ZIP del gestor con `-LocalZip`:

```bash
python tools/build_bundle.py --output-dir dist --version 0.1.0
```

```powershell
& .\dist\install.ps1 -LocalZip .\dist\MensorCAD-CLI.zip
```

Esta ruta exige el sidecar **adjunto** al ZIP elegido: mismo nombre mas
`.sha256` (`dist\MensorCAD-CLI.zip.sha256`). Si falta, si el hash no coincide o
si el ZIP no tiene exactamente las tres entradas del gestor, el bootstrap se
detiene sin tocar el destino ni el `PATH`.

| Tema | Decision |
|------|----------|
| Red | No consulta la API de GitHub y no descarga nada. |
| Validacion | Reutiliza el mismo SHA-256, el recuento exacto de entradas, el staging transaccional y el `PATH` de usuario de la ruta remota. |
| Version | Sale del `mensorcad.ps1` incluido en el ZIP, leido como texto inerte: una sola linea `$script:MensorCadManagerVersion = 'X.Y.Z'`. El gestor no se ejecuta para averiguarla y no se inventa ningun tag de release. |
| Excluyente | `-LocalZip` y `-Version` son mutuamente excluyentes; el rechazo ocurre antes de cualquier red o escritura. |
| Ruta relativa | Se resuelve contra la carpeta actual de su sesion de PowerShell, la misma que usa `Get-ChildItem`, aunque el comando se haya ejecutado despues de `Set-Location`. Las rutas absolutas, UNC y con espacios se aceptan tal cual; una ruta que no pertenece al sistema de archivos se rechaza sin red y sin escrituras. |
| Complemento | No instala el complemento y no pide UAC: eso sigue siendo `mensorcad install`. |

**Confianza en la ruta local:** el SHA-256 es integridad, no confianza. El hash
solo comprueba que el ZIP coincide con el sidecar que esta a su lado; no
autentica al autor. Usted eligio ese archivo, asi que debe confiar en la
compilacion local que selecciono.

---

## Que hace el bootstrap

En este orden, sin saltarse ninguno:

1. valida `-Version` (si se indico) y la entrada local de `-LocalZip` (si se
   indico) antes de cualquier red o escritura;
2. elige el origen: resuelve el release oficial de `RonGrasz/Mensor-CAD` **una
   sola vez** (API de GitHub o el tag validado de `-Version`), o toma el ZIP
   local y su sidecar adjunto;
3. obtiene `MensorCAD-CLI.zip` y su sidecar `MensorCAD-CLI.zip.sha256`: los
   descarga del tag fijado o los copia a una carpeta temporal propia;
4. comprueba el SHA-256 del ZIP contra el sidecar;
5. valida el indice del ZIP antes de escribir el destino: exactamente tres
   entradas planas (`mensorcad.ps1`, `mensorcad.cmd` e
   `Install-MensorCAD.ps1`), sin duplicados, sin rutas con traversal, sin
   enlaces ni puntos de reanalisis y con tamanios acotados;
6. extrae el ZIP en una carpeta de staging propia (GUID completo), escribe el
   marcador y reemplaza el gestor de forma transaccional; si algo falla se
   restaura la instalacion anterior;
7. agrega la carpeta del gestor al `PATH` del usuario una sola vez.

En la ruta remota el marcador guarda el tag del release. En la ruta local guarda
la version estable leida del `mensorcad.ps1` ya extraido.

Ningun script descargado se ejecuta durante la instalacion: no se ejecuta el
instalador del complemento, no se ejecuta el gestor y no se ejecuta nada del
ZIP. El bootstrap solo copia archivos ya validados.

## Donde instala

Carpeta fija, siempre dentro del perfil del usuario actual:

```text
%LOCALAPPDATA%\MensorCAD\cli
```

Contiene exactamente los tres archivos del ZIP mas un marcador propio,
`.mensorcad-cli.json`, que identifica la carpeta como instalacion del gestor y
guarda la version instalada: el tag del release publicado o la version estable
del build local. El ZIP tiene exactamente tres entradas y el marcador lo agrega
el bootstrap fuera del ZIP.

Las carpetas de staging y de respaldo usan un GUID completo y solo existen
mientras dura la operacion. Un destino con contenido ajeno no se toca, no se
sobrescribe y no se borra: el bootstrap se detiene con un error.

## PATH del usuario

El bootstrap escribe **solo** el `PATH` del usuario actual
(`HKCU\Environment`):

- conserva el contenido original **sin expandir** las variables;
- conserva el tipo del valor: `REG_EXPAND_SZ` sigue siendo `REG_EXPAND_SZ` y
  `REG_SZ` sigue siendo `REG_SZ`;
- agrega la carpeta del gestor **una sola vez**, al final, y reconoce una
  entrada equivalente aunque cambie la caja o use `%LOCALAPPDATA%`;
- no reordena, no expande y no reescribe las entradas anteriores del usuario;
- no toca el PATH de maquina, no usa `setx` y no cambia la politica de
  ejecucion global.

Repetir el bootstrap actualiza el gestor y no duplica el `PATH`.

### Acceso de escritura sin permisos nuevos

El proveedor de registro de PowerShell entrega `HKCU\Environment` con acceso de
**solo lectura**: escribir sobre ese acceso falla con "No se puede escribir en la
clave del Registro" aunque la clave sea del propio usuario. Por eso el bootstrap
abre un acceso propio **con escritura** sobre la misma clave antes de registrar
el `PATH`.

| Tema | Decision |
|------|----------|
| Permisos | Pedir acceso de escritura no cambia los permisos de la clave: no se tocan ACLs, no se desactiva seguridad y no se eleva el proceso. `HKCU\Environment` ya pertenece al usuario actual. |
| Alcance | Solo la clave del usuario actual; nunca `HKLM` ni el `PATH` de maquina. |
| Cierre | El bootstrap cierra siempre los accesos que abre: en exito, cuando el `PATH` ya estaba registrado y cuando falla. |

Si Windows rechaza abrir ese acceso, el bootstrap se detiene, revierte la
instalacion y lo informa por stderr: no pide elevacion ni cambia permisos.

## Terminales

Tras la instalacion hace falta una **terminal nueva** para usar `mensorcad`,
porque las terminales ya abiertas conservan el `PATH` con el que arrancaron. La
sesion de PowerShell que ejecuto `irm ... | iex` se actualiza sola y puede usar
el comando de inmediato. Las demas ventanas necesitan reiniciarse.

## Parametros publicos

| Parametro | Efecto |
|-----------|--------|
| `-Version <tag>` | Fija el release; no consulta la API. Acepta tags como `v1.2.3`, `v1.2` o `v1.2.3-rc.1`. |
| `-LocalZip <ruta>` | Instala el gestor desde un ZIP construido localmente. Exige el sidecar `.sha256` adjunto, no usa la red y no se puede combinar con `-Version`. |
| `-NoAnimation` | Se conserva por compatibilidad con el bootstrap anterior. No cambia ningun paso: este flujo solo escribe texto plano. |

No hay parametros de URL, repositorio, destino, PATH ni elevacion: la fuente y
el destino son fijos. `-LocalZip` no cambia el destino ni el `PATH`: solo cambia
de donde sale el ZIP ya validado.

## Codigo de salida

El bootstrap no ejecuta `exit` para no cerrar la sesion cuando el texto llega
por `iex`. El resultado real queda en `$global:LASTEXITCODE`:

- `0`: el gestor quedo instalado o actualizado y el `PATH` quedo registrado;
- `1`: no se completo la instalacion (o se revirtio) y el mensaje explica el
  motivo por stderr.

Para obtener un codigo de salida del sistema operativo desde PowerShell:

```powershell
& .\install.ps1; exit $LASTEXITCODE
```

## Integridad y limites

El sidecar usa el formato `sha256sum`: 64 caracteres hexadecimales, dos espacios,
`MensorCAD-CLI.zip` y salto de linea final. El bootstrap rechaza cualquier otro
contenido, tanto en el release publicado como junto al ZIP local.

La revision SHA-256 comprueba que el ZIP coincide con su sidecar, pero no
autentica al publicador. En la ruta remota la confianza viene del repositorio
oficial fijo `RonGrasz/Mensor-CAD`; en la ruta local, de la compilacion que el
usuario construyo y eligio. Si el release o el sidecar se comprometen, el hash
no lo detecta.

Fuera del alcance de este bootstrap: quitar o autoactualizar el gestor, tocar
el PATH de maquina, instalar el complemento, abrir AutoCAD y pedir elevacion.
Esos pasos pertenecen al gestor (`mensorcad install`, `mensorcad update`,
`mensorcad uninstall`) o al instalador protegido del complemento.

## Como se prueba

Contrato estructural (sin red, sin PowerShell, multiplataforma):

```text
python3 -m unittest discover -s tests -p 'test_cli_bootstrap.py' -v
```

Pruebas funcionales en Windows PowerShell 5.1 con red, registro y carpetas del
usuario simuladas:

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests\Test-CliBootstrap.ps1
```

La suite funcional no toca el `PATH` real, no escribe en `Program Files`, no
pide UAC y no llama a GitHub: usa fixtures de ZIP y un registro falso. Ese
registro falso modela el backend real: el acceso que entrega `Get-Item` es de
solo lectura, el bootstrap abre su propio acceso de escritura y la suite exige
que todos los accesos queden cerrados. La ruta local se prueba con un ZIP
fixture cuyo `mensorcad.ps1` lleva la version sellada escrita como texto; la
suite verifica cero consultas al release, cero descargas y que el gestor nunca
se ejecuta.

### Sonda manual del registro real (opt-in)

La suite anterior no escribe en el registro real. Para comprobar el backend real
de Windows hay una sonda **aparte, manual y opt-in**:

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests\Test-CliBootstrapRegistry.ps1
```

| Tema | Decision |
|------|----------|
| Clave | Solo `HKCU:\Software\MensorCAD-Bootstrap-Probe`, con valores ficticios. |
| Si ya existe | La sonda se detiene **sin tocarla**: solo crea y elimina su propia clave. |
| PATH real | No escribe `HKCU\Environment` ni el `PATH`: los compara antes y despues y exige que no cambien. |
| Fuera de alcance | Nada de `HKLM`, ACLs, UAC, red ni AutoCAD; `TEMP`, `LOCALAPPDATA` y el ZIP local viven en `odd/artifacts/bootstrap-registry-writable`. |
| Limpieza | Cierra sus accesos y elimina la clave que creo; comprueba que quedo ausente. |

No forma parte de la suite por defecto ni de CI: hay que ejecutarla a mano.
