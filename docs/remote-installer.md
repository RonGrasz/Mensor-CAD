# Instalación remota de MensorCAD

La entrada remota instala MensorCAD desde un release de GitHub con **un solo
comando de PowerShell**: descarga el ZIP, verifica su SHA-256, inspecciona su
contenido y ejecuta el mismo instalador local que ya existe dentro del paquete
extraído. La instalación en `Program Files` sigue siendo la misma, con la misma
marca, el mismo respaldo y el mismo aviso de UAC.

> **No disponible todavía.** El comando no funciona hasta que un humano
> publique un release con los assets `MensorCAD-Windows.zip`,
> `MensorCAD-Windows.zip.sha256` e `Install-MensorCAD.ps1` en
> `RonGrasz/Mensor-CAD`. Esta unidad no publica releases ni cambia CI.
## Ruta rápida

1. Verifique que el release publicado por un humano existe en
   <https://github.com/RonGrasz/Mensor-CAD/releases>.
2. Abra Windows PowerShell 5.1 y ejecute el comando de una línea de abajo.
3. Acepte el aviso de UAC.
4. Abra AutoCAD y compruebe que los comandos `MC*` cargan.

## Comando de una línea

Cuando el release exista, el comando previsto es exactamente este:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/Install-MensorCAD.ps1'))) -FromRelease"
```

El script se ejecuta **en memoria**, por lo que `$PSScriptRoot` y
`$PSCommandPath` están vacíos. Por eso la rama remota no usa esas variables:
descarga el ZIP, lo extrae en una carpeta temporal propia y trabaja con el
`Install-MensorCAD.ps1` que viene **dentro del paquete verificado**. La
elevación y la instalación se ejecutan sobre ese script extraído, nunca sobre
una ruta inexistente. `exit` termina solo el proceso de PowerShell creado por el
comando, con el código real de la instalación.

Si prefiere no usar un comando en memoria, el ZIP del release se puede
descargar, extraer y ejecutar con `Instalar.bat` como siempre.

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
| Consola normal | La terminal que invocó pinta frames de actividad mientras el proceso hijo real sigue en ejecución, incluida la espera de UAC. |
| `-NoAnimation` o salida redirigida | El paso de espera se informa una sola vez, sin frames repetidos ni demoras artificiales. |
| Fin del hijo | La animación se detiene en cuanto el proceso termina; no hay esperas decorativas posteriores. |
| Salida del hijo inmediato | Su `stdout` y `stderr` se capturan y se reenvían a la terminal después de terminar. |
| Proceso elevado por UAC | Abre su propia ventana de diagnóstico; esa salida no se captura ni se reenvía. |
| Estado final | El estado de salida final vuelve siempre a la terminal que invocó, también con UAC cancelado. |

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
| Estructura remota | `python3 -m unittest discover -s tests -p 'test_*installer_structure.py' -v` | Se ejecuta en Linux. No demuestra comportamiento. |
| Estructura local | `python3 -m unittest discover -s tests -p 'test_installer_structure.py' -v` | Se ejecuta en Linux. No demuestra comportamiento. |
| Pruebas remotas | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-RemoteInstaller.ps1` | Requiere Windows PowerShell 5.1. Red y destino simulados; el camino de instalación usa un hijo simulado y la espera activa se mide contra procesos reales aislados. |
| Pruebas locales | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Installer.ps1` | Requiere Windows PowerShell 5.1. |

Las pruebas de Windows simulan la API de GitHub, las descargas y el camino de
instalación con costuras locales: no descargan nada real, no escriben en
`Program Files` y no piden UAC real. Las regresiones de la espera activa lanzan
procesos PowerShell aislados para observar la animación y su detención real. En el entorno de desarrollo de esta unidad no hay PowerShell
ni AutoCAD, así que **la ejecución funcional sigue pendiente** y no debe
presentarse como superada.
