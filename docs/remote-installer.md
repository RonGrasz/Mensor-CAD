# Instalación remota de MensorCAD

La entrada remota instala MensorCAD desde un release de GitHub con **un solo
comando de PowerShell**: descarga el ZIP, verifica su SHA-256, inspecciona su
contenido y ejecuta el mismo instalador local que ya existe dentro del paquete
extraído. La instalación en `Program Files` sigue siendo la misma, con la misma
marca, el mismo respaldo y el mismo aviso de UAC.

> **No disponible todavía.** El comando no funciona hasta que un humano
> publique un release con los cuatro assets `MensorCAD-Windows.zip`,
> `MensorCAD-Windows.zip.sha256`, `Install-MensorCAD.ps1` e `install.ps1` en
> `RonGrasz/Mensor-CAD`. Esta unidad no publica releases, no crea tags y no
> cambia los disparadores ni los permisos del CI; solo agrega la suite
> `tests/Test-Bootstrap.ps1` al workflow existente.
## Ruta rápida

1. Verifique que el release publicado por un humano existe en
   <https://github.com/RonGrasz/Mensor-CAD/releases>.
2. Abra Windows PowerShell 5.1 y ejecute uno de los comandos de abajo.
3. Acepte el aviso de UAC.
4. Abra AutoCAD y compruebe que los comandos `MC*` cargan.

## Comando corto recomendado (`install.ps1`)

El comando más corto descarga el bootstrap `install.ps1` del release y lo
ejecuta. Ese archivo **no instala nada por sí mismo**: descarga el
`Install-MensorCAD.ps1` real a una carpeta temporal propia, lo lanza en un
proceso Windows PowerShell aparte con `-FromRelease` y reenvía su salida. La
verificación SHA-256, la inspección del ZIP, el destino fijo, el respaldo y el
aviso de UAC siguen siendo los del instalador real: el bootstrap no duplica el
motor ni lleva una versión de producto propia.

### Última versión publicada

```powershell
irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/install.ps1' -ea Stop | iex
```

### Versión fijada

Reemplace `v0.1.0` en **las dos apariciones** (URL y `-Version`) por el tag que
quiera instalar. **El ejemplo `v0.1.0` es ilustrativo y no está publicado**: hoy
no existe ningún release con ese tag en este repositorio. Descargar el bootstrap
de `releases/latest/download` y pasarle `-Version <tag>` **no** fija la versión
instalada: el script que se ejecuta tiene que ser el del tag.

```powershell
&([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v0.1.0/install.ps1' -ea Stop))) -Version v0.1.0
```

### Contrato de salida del comando corto

| Situación | Comportamiento |
|-----------|----------------|
| `iex` | El bootstrap se ejecuta en el ámbito del llamador y **nunca llama a `exit`**: la sesión no se cierra. |
| Éxito del instalador real | `$LASTEXITCODE` queda en `0`. El bootstrap no imprime un resumen de éxito ni afirma que se instaló o actualizó. |
| Fallo, UAC cancelado o hijo con otro código | `$LASTEXITCODE` conserva ese código real, distinto de cero. |
| Estado del hijo no disponible | El bootstrap escribe `ERROR:` en `stderr` y fija `$LASTEXITCODE` en `1`; nunca informa éxito por un estado ausente. |
| Primera descarga de `install.ps1` (antes del wrapper) con `404` o fallo de red | `-ea Stop` corta la invocación y el error queda visible, pero el canal depende del host y el wrapper nunca se ejecuta. Por eso **no fija** `$LASTEXITCODE`: puede conservar un valor anterior, incluso `0`. No se garantiza un código `1`. |
| Descarga del instalador real (dentro del wrapper) con `404` o fallo de red | `ERROR:` en `stderr` y `$LASTEXITCODE` en `1`; el instalador hijo no llega a ejecutarse. |
| `-Version` vacío o con formato inválido | `ERROR:` antes de cualquier descarga o escritura, y `$LASTEXITCODE` en `1`. |

El bootstrap no propaga un código de salida del **proceso** `powershell.exe`
porque se lo pidió `iex`, no el sistema operativo. Para automatizar con un
código del sistema operativo use el comando completo de más abajo o el
fallback con el operador de llamada:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '& .\install.ps1; exit $LASTEXITCODE'
```

Use comillas simples al pegar desde PowerShell: con comillas dobles, el proceso
exterior expandiría `$LASTEXITCODE` antes de que lo lea el hijo. Desde `cmd.exe`
conviene el comando completo, que ya trae su propio `exit`.

`-ea Stop` protege **solo la primera descarga**, la de `install.ps1`. Ese primer
paso ya ejecuta código del repositorio: la confianza empieza en
`RonGrasz/Mensor-CAD`, no en el ZIP. La descarga inicial usa la configuración
TLS del equipo; el bootstrap fija TLS 1.2 después, ya para el instalador real.
En un equipo que no negocie TLS 1.2 con `Invoke-RestMethod`, use el comando
completo, que fija TLS 1.2 antes de la primera descarga: ningún script
descargado puede configurar la descarga que ya ocurrió. Después, el bootstrap fija TLS 1.2 en su
propio proceso (sin tocar políticas globales) y vuelve a comprobar el estado de
la descarga antes de lanzar el instalador real.

### Qué hace el bootstrap con la carpeta temporal

1. Crea `%TEMP%\mensorcad-bootstrap-<guid>` con un GUID completo: si la ruta
existiera, la creación falla en lugar de reutilizar una carpeta ajena.
2. Descarga ahí el `Install-MensorCAD.ps1` real, sin capturar ni reescribir su
contenido.
3. Ejecuta ese archivo con `-NoProfile -ExecutionPolicy Bypass -File` en un
proceso Windows PowerShell aparte, preferentemente el nativo de System32, y le
pasa `-FromRelease`, el `-Version` exacto y `-NoAnimation` si se indicó.
4. Reenvía el `stdout` y el `stderr` del hijo tal como llegan, sin capturarlos
ni convertirlos en valor de retorno.
5. Intenta borrar solo su propia carpeta temporal en un `finally`. Si el borrado
falla, avisa con la ruta en `stderr` y **conserva el código real** del
instalador.

El bootstrap no elige URL, repositorio, destino ni forma de saltarse UAC: la
fuente está fija en el código y el resto lo decide el instalador real.

## Comando completo (compatibilidad, automatización y TLS)

Hay **dos** comandos completos previstos: uno para la última versión publicada y
otro para
una versión fijada. Los dos descargan el script del release y lo ejecutan **en
memoria**, y los dos envuelven esa **primera descarga** en un `try/catch`
propio: si GitHub responde `404` o la red falla, se escribe un mensaje `ERROR:`
en español en `stderr` y el proceso termina con un código distinto de cero.
Ninguno de los dos comandos contiene variables `$`, para que se pueda pegar tal
cual en una consola de Windows PowerShell 5.1 sin que el shell exterior expanda
nada antes de ejecutarlo.

### Última versión publicada

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing -ErrorAction Stop 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/Install-MensorCAD.ps1'))) -FromRelease } catch { [Console]::Error.WriteLine('ERROR: no se pudo descargar el instalador de MensorCAD desde GitHub. Compruebe su conexion y que la release este publicada y sea accesible sin credenciales; no se instalo nada.'); exit 1 }"
```

### Versión fijada

Reemplace `v0.1.0` en **las dos apariciones** (URL y `-Version`) por el tag que
quiera instalar. **El ejemplo `v0.1.0` es ilustrativo y no está publicado**: hoy
no existe ningún release con ese tag en este repositorio.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing -ErrorAction Stop 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v0.1.0/Install-MensorCAD.ps1'))) -FromRelease -Version v0.1.0 } catch { [Console]::Error.WriteLine('ERROR: no se pudo descargar el instalador de MensorCAD desde GitHub. Compruebe su conexion y que la version v0.1.0 este publicada y sea accesible sin credenciales; no se instalo nada.'); exit 1 }"
```

Una versión fijada **no** usa el comando de la última versión: el script que se
ejecuta tiene que ser el del tag que se va a instalar. Si usa el bootstrap de
`releases/latest/download` con `-Version <tag>`, ejecuta el instalador de la
última versión pidiendo otra; por eso la documentación publica los dos comandos
por separado.

### Qué descarga primero el comando

El comando no descarga un instalador “inocuo”: la **primera descarga ya ejecuta
código remoto** del repositorio, igual que si hubiera descargado el `Instalar.bat`
a mano. El primer `Invoke-RestMethod` trae el script y `[scriptblock]::Create`
lo ejecuta en el proceso de PowerShell que se creó para el comando. Por eso la
primera descarga tiene su propio `try/catch` y por eso la confianza empieza en el
repositorio, no en el ZIP. Después de esa primera descarga, el script instalado
repite el flujo de siempre: resuelve un tag exacto, descarga el ZIP y su
`.sha256`, verifica el hash, inspecciona el ZIP y ejecuta el instalador extraído.

El script se ejecuta **en memoria**, por lo que `$PSScriptRoot` y
`$PSCommandPath` están vacíos. Por eso la rama remota no usa esas variables:
descarga el ZIP, lo extrae en una carpeta temporal propia y trabaja con el
`Install-MensorCAD.ps1` que viene **dentro del paquete verificado**. La
elevación y la instalación se ejecutan sobre ese script extraído, nunca sobre
una ruta inexistente. `exit` termina solo el proceso de PowerShell creado por el
comando, con el código real de la instalación.

Si prefiere no usar un comando en memoria, el ZIP del release se puede
descargar, extraer y ejecutar con `Instalar.bat` como siempre.

## Cuándo la primera descarga falla

| Situación | Resultado |
|-----------|-----------|
| Fallo de red o `404` en la primera descarga | `ERROR:` en español en `stderr` y código distinto de cero; el instalador nunca llega a ejecutarse. |
| El tag fijado no existe o no está publicado | El `404` de la primera descarga también produce `ERROR:` y código distinto de cero. |
| Repositorio privado o sin acceso anónimo | Se comporta igual que un `404`: el mensaje admite que puede ser publicación **o** acceso, no afirma que la release no exista. |
| Fallo después de la primera descarga | Lo informa el instalador con su propio `ERROR:` y su propio código de salida. |

## Uso del instalador

| Opción | Efecto |
|--------|--------|
| `-FromRelease` | Descarga e instala la última release publicada. |
| `-FromRelease -Version <tag>` | Fija un tag concreto, por ejemplo `v1.2.3`. No consulta la API. |
| `-FromRelease -NoAnimation` | Igual que arriba, sin colores ni animaciones. |
| `-Help` | Muestra la ayuda y sale con `0`. |

Combinaciones inválidas, que fallan **sin red y sin escrituras** (el comando
sigue no disponible en este repositorio hasta que exista un release publicado):

| Combinación | Motivo |
|-------------|--------|
| `-FromRelease -Uninstall` | La desinstalación es local; use `-Uninstall` sin `-FromRelease`. |
| `-Version` sin `-FromRelease` | `-Version` solo tiene sentido remoto. |
| `-FromRelease -Version ''` | Falta el valor del tag. |
| `-FromRelease -Version <tag inválido>` | Solo se aceptan tags como `v1.2.3`, `1.2.3` o `v1.2.3-rc.1`. |

No existe ningún parámetro público para elegir la URL, el repositorio, la ruta
de instalación ni para saltarse UAC. La fuente está fija en el código.

## Flujo remoto

1. **Resolver la release.** Con `-Version` se usa ese tag. Sin `-Version` se
   consulta **una sola vez** `releases/latest` y se fija el `tag_name`
   concreto; el ZIP y el sidecar usan exactamente ese tag.
2. **Descargar sin administrador.** El ZIP y el `.sha256` se guardan en una
   carpeta temporal propia (`%TEMP%\mensorcad-remote-<guid>`).
3. **Verificar el SHA-256 antes de extraer.** Si el hash no coincide, no se
   extrae nada y el destino no se toca.
4. **Inspeccionar el ZIP antes de extraer.** Se rechazan entradas con ruta
   absoluta, unidad de disco, UNC, `..`, barras invertidas, duplicados sin
   distinguir mayúsculas, enlaces/reparse points, flujos alternativos (ADS),
   nombres reservados de Windows, segmentos que terminan en punto o espacio, y
   cualquier archivo fuera del inventario congelado:

   ```text
   MensorCAD.bundle/PackageContents.xml
   MensorCAD.bundle/Contents/Lisp/*.lsp
   MensorCAD.bundle/Contents/UI/MensorCAD.cuix
   bundle.sha256
   Install-MensorCAD.ps1
   Instalar.bat
   LICENSE
   ```

   También se permite `Desinstalar.bat` en la raíz del ZIP. Los paquetes nuevos
   lo incluyen; es opcional en la validación para aceptar los ZIP anteriores.

5. **Extraer y revalidar.** La extracción ocurre solo dentro de la carpeta
   temporal propia y después se ejecuta `Test-MensorCadSource` sobre el paquete
   extraído, con el mismo manifiesto `bundle.sha256` del motor local.
6. **Instalar con el motor local.** Se invoca el `Install-MensorCAD.ps1`
   extraído, que valida otra vez, pide UAC si hace falta, instala en el destino
   fijo y escribe la marca `.mensorcad-install.json`. Mientras ese proceso hijo
   real (incluida la espera de UAC) sigue vivo, la terminal que invocó muestra
   actividad animada con el renderizador local; la animación se detiene cuando
   el hijo termina. Después se reenvía la salida capturada del hijo inmediato.
   El estado de salida final vuelve a la terminal; un fallo o un UAC cancelado
   no se oculta.
7. **Limpiar.** La carpeta temporal se intenta eliminar en todos los caminos,
   también cuando algo falla. Si el borrado no es posible (por ejemplo, un
   archivo bloqueado), la carpeta se conserva en disco y se muestra un aviso con
   la ruta; no se garantiza que la limpieza siempre tenga éxito.

## Animación y salida del proceso

| Situación | Comportamiento |
|-----------|----------------|
| Consola normal | Las cinco fases muestran un título amigable y una pista corta; la terminal que invocó pinta frames de actividad mientras el proceso hijo real sigue en ejecución, incluida la espera de UAC. |
| `-NoAnimation` o salida redirigida | Las fases conservan su texto técnico original, sin títulos ni frames, y el paso de espera se informa una sola vez. No se agregan líneas nuevas. |
| Fin del hijo | La animación se detiene en cuanto el proceso termina; no hay esperas decorativas posteriores. |
| Salida del hijo inmediato | Su `stdout` y `stderr` se capturan y se reenvían a la terminal después de terminar, **siempre**, con color o sin él. |
| Proceso elevado por UAC | Abre su propia ventana de diagnóstico; esa salida no se captura ni se reenvía. |
| Estado final | El estado de salida final vuelve siempre a la terminal que invocó, también con UAC cancelado. |

### Resumen del resultado en la terminal que invocó

Con color, y **solo cuando el hijo inmediato sale con código `0`**, el padre
agrega al final un bloque de resultado con la release resuelta y la misma
próxima acción que usa el instalador local. Ese bloque no afirma si se instaló o
se actualizó: el código `0` del hijo no distingue esos dos casos.

Si el hijo sale con otro código (UAC cancelado, AutoCAD abierto, fallo del
instalador local), el padre no pinta ningún check de éxito: reenvía intactos el
`stdout` y el `stderr` del hijo y agrega un resumen de fallo con el código, sin
inventar un segundo mensaje `ERROR:` en `stderr`. En modo plano no se agrega
ningún resumen: la única salida nueva sigue siendo la del hijo.

No hay captura de la salida del proceso elevado: Windows lo lanza en una
ventana propia y el instalador remoto solo recibe su código de salida.


## Qué garantiza el SHA-256

SHA-256 detecta **corrupción o modificación de la descarga**; no autentica al
publicador: si el repositorio o la release fueran comprometidos, el hash podría
ser válido. La seguridad real depende de confiar en el repositorio de GitHub
`RonGrasz/Mensor-CAD` y en la cuenta que publica los assets. No hay firma de
código ni certificado de editor en este flujo.

La verificación de la marca instalada también es consistencia interna, no
autenticación.

## Redirecciones de descarga

Las URLs iniciales están fijas en `https://github.com/RonGrasz/Mensor-CAD/...` y
`https://api.github.com/repos/RonGrasz/Mensor-CAD/...`. GitHub responde con
redirecciones HTTPS a su CDN (`objects.githubusercontent.com`,
`github-releases.githubusercontent.com`), que es el comportamiento normal de
las descargas de releases. El cliente HTTP del sistema sigue esas redirecciones:
no se valida un host final y no existe un parámetro público de URL o de host que
permita apuntar a otro origen. No se rechazan descargas legítimas por el host
final del CDN.

## Alternativa offline

Si no quiere depender de la red ni de GitHub:

1. Descargue `MensorCAD-Windows.zip` desde un release publicado por un humano.
2. Extraiga el ZIP completo en una carpeta local.
3. Ejecute `Instalar.bat` o `Install-MensorCAD.ps1` desde la carpeta extraída.

El instalador local no descarga nada y valida el paquete con `bundle.sha256`.
Ver `docs/local-installer.md` para el detalle del motor local.

## Requisitos y límites

| Tema | Decisión |
|------|----------|
| Sistema | Windows de 64 bits con Windows PowerShell 5.1 de 64 bits. |
| Permisos | La descarga y la verificación no requieren administrador; la instalación sí (UAC). |
| Destino | Fijo: `<Program Files>\Autodesk\ApplicationPlugins\MensorCAD.bundle`. |
| Red | Fuente fija en `github.com` y `api.github.com`; GitHub redirige las descargas al CDN con TLS 1.2 del proceso actual. |
| Configuración global | No se cambia la política de ejecución, `SECURELOAD`, `TRUSTEDPATHS`, `APPAUTOLOAD` ni el perfil del usuario. |
| Dependencias | Ninguna fuera de Windows PowerShell 5.1 y .NET Framework incluido. |
| Publicación | Un humano debe publicar los assets; esta unidad no publica nada. |
| AutoCAD | Debe estar cerrado; el instalador nunca lo cierra. |

## Códigos de salida

En el comando corto, el código real queda en `$LASTEXITCODE` porque el bootstrap
no llama a `exit`; consulte la tabla del contrato de salida de más arriba. En el
comando completo el proceso `powershell.exe` termina con ese mismo código.

| Código | Significado |
|--------|-------------|
| `0` | Instalación remota completada; solo cuando el hijo reportó `0` de verdad. |
| `1` | Fallo controlado: argumentos inválidos, red, API, SHA-256, ZIP inseguro, UAC cancelado, error del instalador local o estado de salida del hijo no disponible. |
| Otro | Código propagado desde el instalador extraído. |

Los errores de la entrada remota se escriben en `stderr` con prefijo `ERROR:`.
La salida del hijo inmediato se reenvía a `stdout`/`stderr` sin ocultarla: los
mensajes del proceso que pide UAC se capturan antes de elevar, y el proceso ya
elevado escribe en su propia ventana de diagnóstico, que no se captura. El
estado de salida final siempre vuelve a la terminal que invocó.

### Cuándo un `404` explica qué pasó

El instalador no trata cualquier error de red como un `404`: solo cuando el
error trae un estado HTTP real `404` agrega una guía específica. Ese `404`
puede significar que la release o el asset no estén publicados **o** que el
repositorio no sea accesible sin credenciales; el mensaje dice las dos cosas y
no afirma que la release no exista. Para cualquier otro error se conserva el
mensaje genérico con el detalle subyacente.

### Estado de salida del proceso hijo

El instalador remoto captura el estado de salida del proceso hijo inmediato
mientras mantiene la espera activa: fija el handle del proceso antes de esperar,
lee el estado crudo una sola vez y lo valida **antes** de convertirlo en número.
Si el sistema no expone ese estado (por ejemplo, un `Process` cuyo `ExitCode`
queda vacío en Windows PowerShell 5.1), no se puede determinar el estado real
del hijo: la entrada remota termina con código `1` y un mensaje `ERROR:` que
incluye el identificador del proceso. Ese caso nunca se informa como éxito: un
`0` solo se devuelve cuando el hijo realmente salió con `0`, y cualquier otro
valor real se propaga sin cambios.

## Verificación

| Comprobación | Comando | Estado |
|--------------|---------|--------|
| Estructura del bootstrap | `python3 -m unittest discover -s tests -p 'test_bootstrap_structure.py' -v` | Se ejecuta en Linux. No demuestra comportamiento. |
| Estructura remota | `python3 -m unittest discover -s tests -p 'test_remote_installer_structure.py' -v` | Se ejecuta en Linux. No demuestra comportamiento. |
| Estructura local | `python3 -m unittest discover -s tests -p 'test_installer_structure.py' -v` | Se ejecuta en Linux. No demuestra comportamiento. |
| Pruebas del bootstrap | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Bootstrap.ps1` | Requiere Windows PowerShell 5.1 y ejecución manual. Red, servidor y proceso hijo simulados con fixtures locales. |
| Pruebas remotas | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-RemoteInstaller.ps1` | Requiere Windows PowerShell 5.1. Red y destino simulados; el hijo está simulado, la espera activa se mide contra procesos reales aislados y el comando de una línea se ejecuta en un proceso aparte con la primera descarga simulada. |
| Pruebas locales | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Installer.ps1` | Requiere Windows PowerShell 5.1. |

Las pruebas de Windows simulan la API de GitHub, las descargas y el camino de
instalación con costuras locales: no descargan nada real, no escriben en
`Program Files` y no piden UAC real. Las regresiones de la espera activa lanzan
procesos PowerShell aislados para observar la animación y su detención real. Los
comandos de una línea se extraen del texto publicado en este documento y se
ejecutan en un proceso PowerShell aparte con la primera descarga sustituida por
una costura local: una variante entrega el instalador desde disco (para
demostrar que se ejecuta en memoria, sin `$PSScriptRoot`) y otra falla en esa
primera descarga (para demostrar que el `ERROR:` del bootstrap se distingue del
`ERROR:` del instalador). En el entorno de desarrollo de esta unidad no hay
PowerShell ni AutoCAD, así que **la ejecución funcional sigue pendiente** y no
debe presentarse como superada. Tampoco existe todavía una prueba pública real
del comando de una línea: sin release publicado no hay nada que descargar.
