# Instalador local de MensorCAD

El instalador local copia el bundle `MensorCAD.bundle` a la carpeta de AutoCAD
en Program Files, valida los hashes antes de pedir permisos y permite
actualizar o desinstalar sin tocar archivos ajenos. Se ejecuta desde el paquete
extraído y no descarga nada.

> Estado de esta unidad: instalación local y desinstalación. La entrada remota
> `-FromRelease` / `-Version` ya está implementada en el mismo script, pero no
> estará operativa hasta que un humano publique los assets del release. Ver
> `docs/remote-installer.md`.

## Ruta rápida

1. Extraiga el ZIP completo en una carpeta normal (por ejemplo, Descargas).
2. Cierre AutoCAD.
3. Haga doble clic en `Instalar.bat` o ejecute:

   ```bat
   Instalar.bat
   Instalar.bat -Uninstall
   ```

4. Acepte el aviso de UAC.
5. Abra AutoCAD y compruebe que el bundle y los comandos `MC*` están
   disponibles.

No ejecute `Install-MensorCAD.ps1` desde dentro del ZIP: primero extraiga todos
los archivos, porque el instalador necesita `bundle.sha256` y la carpeta
`MensorCAD.bundle` juntos.

## Requisitos

| Requisito | Detalle |
|-----------|---------|
| Sistema | Windows de 64 bits con AutoCAD y ActiveX/VLA. |
| Shell | Windows PowerShell 5.1 de 64 bits (`powershell.exe`). |
| Permisos | Administrador para instalar o desinstalar en Program Files. |
| Paquete | `Install-MensorCAD.ps1`, `Instalar.bat`, `bundle.sha256` y `MensorCAD.bundle/` en la raíz extraída. |
| AutoCAD | Debe estar cerrado. El instalador nunca cierra AutoCAD por su cuenta. |

El host debe ser de 64 bits: se rechaza Windows de 32 bits y también PowerShell
de 32 bits sobre Windows de 64 bits (WOW64). El mensaje exacto es:

```text
MensorCAD requiere Windows de 64 bits y PowerShell de 64 bits. Ejecute Instalar.bat o el powershell.exe nativo de 64 bits. No se escribio ningun archivo.
```

La comprobación de arquitectura ocurre antes de resolver Program Files, antes de UAC y antes de cualquier escritura.

`Instalar.bat` prefiere el `powershell.exe` nativo de 64 bits. Si se inicia desde
WOW64, usa `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe`;
en un host de 64 bits usa `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`.

## Interfaz

| Opción | Efecto |
|--------|--------|
| *(sin opciones)* | Instala o actualiza el bundle. |
| `-Uninstall` | Desinstala únicamente la copia propia de MensorCAD. |
| `-NoAnimation` | Desactiva colores y animaciones. |
| `-Help` | Muestra la ayuda y sale con código `0`. |
| `-FromRelease` | Instala desde el último release de GitHub (ver `docs/remote-installer.md`). |
| `-Version` | Fija un tag concreto del release; requiere `-FromRelease`. |
| `-ElevatedProcess` | Reservado para la relanzada interna de UAC. No evita comprobaciones. |
| `MENSORCAD_BAT_LAUNCHER=1` | Marca reservada que define `Instalar.bat`: identifica el lanzamiento del doble clic y habilita (si todo se cumple) la entrega de ventana única. No evita permisos ni validaciones. No es una opción pública del script. |
| `-HoldResult` | Interruptor reservado para la relanzada de entrega: le indica que debe mantener su resultado visible hasta Enter. No es una opción pública, no se aplica a flujos redirigidos ni cambia el código de salida. |

También se desactiva la animación automáticamente cuando la salida está
redirigida, para que los registros de consola sigan siendo legibles.

`Instalar.bat` reenvía todas las opciones (`%*`) al mismo
`Install-MensorCAD.ps1`, conserva su código de salida y muestra un resumen. El
`pause` final se puede omitir con la variable `MENSORCAD_NO_PAUSE=1` en
automatizaciones.

## Ventana única después de UAC

Al hacer doble clic en `Instalar.bat` el lanzador **no** manipula ni oculta
ventanas: entrega el resultado a la ventana elevada. Con una consola interactiva
dedicada a este BAT, el lanzador deja de esperar, la ventana elevada hace el
trabajo y mantiene su resultado final visible hasta pulsar Enter, y el lanzador
imprime el mensaje neutral «La instalacion continua en la ventana elevada.» y
termina en ese instante. Así el host de la terminal
(Windows Terminal, conhost u otro) no necesita cambios: la ventana que queda con
el resultado es la elevada.

| Situación | Resultado |
|-----------|-----------|
| Doble clic en `Instalar.bat` con consola dedicada `cmd.exe /c` de este BAT | El lanzador entrega el resultado: mensaje neutral, sin resumen de éxito ni pausa. La ventana elevada muestra el resultado final hasta Enter. |
| PowerShell directo, terminal ya abierta, `-FromRelease` o consola compartida | Sin entrega: se conserva el comportamiento síncrono y los códigos de salida originales. |
| Flujos redirigidos o automatización con `MENSORCAD_NO_PAUSE=1` | Sin entrega y sin espera final: camino síncrono original. |
| Ya elevado (sin UAC) o `-Help` | No se lanza ninguna entrega ni se abre ninguna ventana extra. |
| Se cancela UAC o el lanzamiento falla | Errores originales, código `1`, resumen de error y pausa del BAT como antes. |

La entrega exige cuatro condiciones a la vez, y cualquier duda la desactiva
(fail-open, camino síncrono):

1. El lanzador del BAT, marcado con `MENSORCAD_BAT_LAUNCHER=1`.
2. Consola interactiva: entrada, salida y error sin redirigir.
3. Sin `MENSORCAD_NO_PAUSE` (automatización).
4. Prueba de consola dedicada: la lista de clientes de la consola tiene
   exactamente dos procesos (este y su `cmd.exe` padre directo) y la línea de
   comandos de ese `cmd.exe` ejecuta exactamente este `Instalar.bat` con `/c`.
   Se rechaza `/k`, un `/c` dentro de una ruta o argumento, otro programa, otro
   `Instalar.bat` y cualquier línea ilegible. El antecesor de `cmd.exe` y la
   variable `WT_SESSION` no se consultan: el host de la terminal es irrelevante
   porque no se toca ninguna ventana.

La ventana elevada recibe el interruptor reservado `-HoldResult` y mantiene su
resultado visible hasta Enter, tanto si la instalación termina bien como si
falla; nunca se aplica a flujos redirigidos y un fallo de lectura de teclado no
altera el código de salida real. El lanzador devuelve un sentinel privado (`75`)
que solo el BAT interpreta: no es éxito de instalación y nunca llega a
PowerShell directo, a la entrada remota ni a automatizaciones. El código de
salida documentado del instalador sigue siendo `0` o `1`; `75` es interno del
lanzador y el BAT lo convierte en `0` tras informar el traspaso.

Comprobación de seguridad: la validación local antes de UAC, la revalidación
después de UAC y el motor de instalación no cambian; el único sitio de elevación
sigue siendo uno y la marca reservada no evita ninguna comprobación de permisos
ni de integridad.

### Límite conocido en Windows Terminal

Microsoft Learn documenta en
<https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-advanced#profile-termination-behavior>
que con `closeOnExit` en `automatic` (el valor por defecto) el comportamiento es
como `always` para una aplicación cuyo terminal predeterminado está delegado:
la pestaña se cierra al terminar el lanzador y **no** se conserva. Si el usuario
configurara `closeOnExit: never` la pestaña podría permanecer, pero es una
preferencia global del usuario: este instalador no escribe ninguna
configuración de Windows Terminal y no promete el cierre de la pestaña en todos
los casos. Lo que se conserva es la ventana elevada con el resultado final.

Variantes desconocidas (por ejemplo un envoltorio `.cmd` propio o un acceso
directo con otra línea de comandos) no entregan el resultado: el precio de no
tocar nunca una terminal ajena es que el lanzador original permanezca.

Esta unidad **no** demuestra el resultado visual: eso exige prueba visual humana
en Windows (doble clic en `Instalar.bat`, aceptar y cancelar UAC y comprobar que
queda una sola ventana legible con el resultado). Las pruebas automatizadas usan
costuras locales y no sustituyen esa comprobación.

## Destino fijo

```text
<Program Files>\Autodesk\ApplicationPlugins\MensorCAD.bundle
```

La ruta se obtiene con la carpeta especial `ProgramFiles` de Windows. No existe
un parámetro público para elegir otro destino, y la entrada remota tampoco lo
añadirá.

Dentro del bundle se conserva la estructura del paquete:

```text
MensorCAD.bundle/
  PackageContents.xml
  Contents/
    Lisp/MC-*.lsp
    UI/MensorCAD.cuix
  .mensorcad-install.json      # marca generada al instalar
```

## Flujo de instalación

1. **Validación local, sin administrador.** Comprueba `bundle.sha256` y:
   - hashes SHA-256 de todos los archivos declarados;
   - rutas relativas sin `..`, sin unidad, sin barras invertidas y sin
     segmentos vacíos;
   - inventario sin rutas duplicadas;
   - ausencia de archivos no declarados dentro de `MensorCAD.bundle`;
   - ausencia de puntos de reanálisis (symlinks o junctions) en el origen.
2. **Elevación UAC.** Solo después de validar el origen se relanza el mismo
   script con permisos de administrador.
3. **Revalidación.** Tras UAC y otra vez después de preparar la etapa temporal,
   se repiten las validaciones del origen.

   La validación previa a UAC y la posterior son comprobaciones independientes.
   No se usa una huella entre procesos; el proceso elevado fija el inventario y
   la etapa temporal, y esa identidad es la que describe la marca.

   Si el origen cambia después de preparar la etapa, la revalidación se compara
   contra el inventario fijado y se rechaza, incluso si el nuevo contenido es
   autoconsistente con un manifiesto regenerado. El destino existente no se toca.
4. **Comprobación de AutoCAD.** Se comprueba antes de instalar o actualizar,
   incluso cuando el contenido ya coincide, y de nuevo antes de reemplazar
   archivos. Si AutoCAD está abierto, la operación falla con un mensaje claro.
5. **Etapa, respaldo y reemplazo.** El contenido se copia a una carpeta temporal
   hermana, se verifica, se respalda la versión anterior y se mueve la nueva.
6. **Rollback.** Si algo falla después del respaldo, se restaura la versión
   anterior y se elimina solo la carpeta temporal propia. Si la restauración
   automática no fuera posible, el mensaje indica dónde quedó el respaldo.
7. **Marca.** Se escribe `.mensorcad-install.json` dentro del bundle y se
   verifica el inventario instalado.

La instalación es idempotente: si el contenido ya coincide con el paquete, no
se reescriben archivos y se informa `ya estaba actualizado`.

## Marca de instalación

La marca es la prueba de propiedad que usan la actualización y la
desinstalación. Su nombre y representación son parte del contrato:

| Campo | Valor |
|-------|-------|
| Archivo | `.mensorcad-install.json` en la raíz del bundle. |
| `format` | `mensorcad-bundle-marker` |
| `formatVersion` | `1` |
| `product` | `MensorCAD` |
| `installedAtUtc` | Fecha UTC en formato ISO 8601 redondo (`o`). |
| `sourceManifestSha256` | SHA-256 del archivo `bundle.sha256` usado al instalar. |
| `files` | Lista de `{ "path": "<ruta relativa>", "sha256": "<hash>" }` de todos los archivos instalados, sin incluir la propia marca. |

Ejemplo exacto de la forma esperada (los hashes son ficticios):

```json
{
  "format": "mensorcad-bundle-marker",
  "formatVersion": 1,
  "product": "MensorCAD",
  "installedAtUtc": "2025-01-31T12:00:00.0000000Z",
  "sourceManifestSha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "files": [
    {
      "path": "Contents/Lisp/MC-AREA.lsp",
      "sha256": "1111111111111111111111111111111111111111111111111111111111111111"
    },
    {
      "path": "PackageContents.xml",
      "sha256": "2222222222222222222222222222222222222222222222222222222222222222"
    }
  ]
}
```

Reglas de interpretación:

- La marca **no** forma parte de `bundle.sha256`; se genera durante la
  instalación.
- El inventario de `files` cubre todos los archivos del bundle menos la marca.
- Al actualizar o desinstalar, cada archivo del inventario debe existir y
  conservar su hash. Cualquier archivo adicional dentro del bundle se considera
  no reconocido y bloquea la operación; no se borra.
- Una verificación remota puede comprobar la existencia y el formato de la
  marca, y validar los hashes de `files` contra los archivos instalados.

La marca demuestra **consistencia interna** de una instalación: permite detectar
archivos modificados o agregados, pero no autentica al publicador ni demuestra
que el paquete original fuera legítimo; SHA-256 solo detecta corrupción, no firma
el origen.

## Actualización

La actualización exige que el destino existente sea propio:

| Situación del destino | Resultado |
|-----------------------|-----------|
| No existe | Instalación nueva. |
| Existe con marca válida e inventario intacto | Actualización con respaldo y rollback. |
| Existe sin marca válida | Se rechaza; no se elimina ni se reemplaza. |
| Existe con archivos modificados | Se rechaza con el archivo afectado. |
| Existe con archivos adicionales no registrados | Se rechaza; el archivo adicional se conserva. |

## Desinstalación

`-Uninstall` valida la marca y el inventario, comprueba que AutoCAD esté
cerrado y elimina únicamente los archivos registrados y la marca. Después
elimina los directorios vacíos del bundle. No elimina carpetas padre como
`Autodesk` o `ApplicationPlugins`, y no toca archivos ajenos.

Si el destino no es propio, la desinstalación falla sin borrar nada.

## Seguridad y permisos

| Tema | Decisión |
|------|----------|
| Ejecución | `Instalar.bat` y la relanzada UAC usan `-NoProfile -ExecutionPolicy Bypass` solo para ese proceso. No se cambia la política global. |
| Configuración de AutoCAD | No se modifican `SECURELOAD`, `TRUSTEDPATHS` ni `APPAUTOLOAD`. |
| Origen | Los hashes se validan antes de UAC, después de UAC y después de la etapa. |
| Integridad | SHA-256 detecta corrupción; no sustituye la autenticación del publicador. La marca de propiedad es consistencia, no autenticación. |
| Destino | Solo se escribe dentro de `MensorCAD.bundle`; las carpetas temporales son hermanas y llevan el prefijo `.mensorcad-tx-`. |
| Reparse points | Se rechazan en el origen, en el destino y en sus antecesores para evitar redirecciones inesperadas. |
| AutoCAD | Si está abierto se detiene la operación; no se fuerza su cierre. |
| Windows | En otros sistemas la entrada pública falla sin escribir archivos. |

## Motor reutilizable

La entrada local usa funciones internas que la futura entrada remota puede
reutilizar sin duplicar reglas:

| Función | Responsabilidad |
|---------|-----------------|
| `Test-MensorCadSource -SourceRoot <ruta>` | Valida manifiesto, hashes, inventario, rutas y reparse points. |
| `Install-MensorCadBundle -SourceRoot <ruta> -DestinationRoot <ruta>` | Instala o actualiza con etapa, respaldo y rollback. |
| `Uninstall-MensorCadBundle -DestinationRoot <ruta>` | Desinstala solo un bundle propio. |
| `Read-MensorCadMarker` / `Write-MensorCadMarker` | Interpretan y generan la marca. |

El archivo se puede cargar con dot-source para pruebas o extensiones: en ese
caso define las funciones y retorna sin ejecutar la interfaz ni escribir nada.
`Install-MensorCadBundle` no eleva permisos ni comprueba la arquitectura por sí
mismo; la entrada pública valida el host de 64 bits antes de llamarlo. La
elevación y el destino fijo siguen siendo responsabilidad de la entrada pública.

La entrada remota reutiliza este mismo motor: descarga y verifica el ZIP sin
administrador, extrae el paquete en una carpeta temporal propia y ejecuta el
`Install-MensorCAD.ps1` incluido en el paquete extraído. Ese hijo aplica las
mismas validaciones, el destino fijo y la elevación UAC descritas aquí. El
detalle de descarga, integridad y límites del ZIP vive en
`docs/remote-installer.md`.

El comando remoto no está disponible todavía: requiere que un humano publique
los assets del release.

## Pruebas y verificación

| Prueba | Dónde | Estado |
|--------|-------|--------|
| Estructura del instalador, BAT y documentación | `python3 -m unittest discover -s tests -p 'test_installer_structure.py' -v` | Se ejecuta en Linux. No demuestra comportamiento funcional. |
| Instalación, actualización, desinstalación, rollback, rechazos y flags | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Installer.ps1` | Requiere Windows PowerShell 5.1. Usa destinos temporales aislados. |
| Ventana única (entrega con sentinel, espera no bloqueante, `-HoldResult`, camino síncrono, `/c` de este BAT y BAT real con stub) | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-InstallerWindow.ps1` | Requiere Windows PowerShell 5.1. Consola, UAC y proceso simulado; no demuestra el resultado visual. |
| Entrada remota | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-RemoteInstaller.ps1` | Requiere Windows PowerShell 5.1. Red y proceso hijo simulados. |

Las pruebas de Windows nunca escriben en Program Files ni abren AutoCAD. Los
casos que necesitan symlinks/junctions se omiten si el entorno no permite
crearlos; una omisión no cuenta como prueba superada.

En el entorno de desarrollo de esta unidad no hay PowerShell ni AutoCAD, por lo
que la prueba funcional de Windows queda pendiente de ejecución humana o de CI
Windows. No se debe presentar como superada.

## Códigos de salida

| Código | Significado |
|--------|-------------|
| `0` | Instalación, actualización, desinstalación o ayuda completadas. |
| `1` | Fallo controlado: validación, permisos, UAC, AutoCAD abierto, destino no propio, rollback fallido u otro error. |
| `75` | Interno del lanzador del BAT: entrega de ventana única. No es un resultado de instalación; `Instalar.bat` lo convierte en `0` después de informar el traspaso. Nunca se devuelve a PowerShell directo, a `-FromRelease` ni a automatizaciones. |

Los errores se escriben en `stderr` con el prefijo `ERROR:` y un mensaje en
español. `Instalar.bat` conserva el mismo código y no oculta el fallo.

## Problemas frecuentes

| Síntoma | Causa probable | Acción |
|---------|----------------|--------|
| `No se encontro el manifiesto bundle.sha256` | Se ejecutó desde dentro del ZIP o faltan archivos. | Extraer el ZIP completo. |
| `El hash ... no coincide` | Paquete incompleto o modificado. | Volver a extraer el paquete oficial. |
| `ya existe y no pertenece a MensorCAD` | Hay una carpeta ajena en el destino. | Revisarla y retirarla manualmente si corresponde; el instalador no la toca. |
| `contiene archivos no reconocidos` | Se agregaron archivos dentro del bundle instalado. | Retirarlos o desinstalar con una copia oficial; el instalador no los borra. |
| `AutoCAD esta en ejecucion` | AutoCAD abierto. | Cerrar AutoCAD y repetir. |
| `No se obtuvo elevacion mediante UAC` | Se canceló el aviso de UAC. | Repetir y aceptar el aviso. |

## Fuera de alcance de esta unidad

- Publicación de releases o cambios de CI.
- Firma de ejecutables o certificados de editor.
- Cambios en LISP, CUIX o en el contenido del bundle.
- Cierre automático de AutoCAD.

La descarga remota se documenta en `docs/remote-installer.md`; este documento
cubre solo el motor y la entrada local.
