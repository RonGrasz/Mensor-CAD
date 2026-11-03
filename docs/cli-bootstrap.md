# Bootstrap del gestor `mensorcad`

Este documento describe la entrada remota de MensorCAD: un bootstrap corto que
instala **solo el gestor de linea de comandos** en la carpeta del usuario y lo
registra en el `PATH` del usuario actual. El complemento de AutoCAD **no** se
instala aqui y no se pide UAC.

La instalacion tiene dos pasos a proposito:

1. el bootstrap publica el comando `mensorcad`;
2. el usuario decide cuando instalar o actualizar el complemento con
   `mensorcad install`.

Los assets de release de esta etapa todavia no estan publicados; estos comandos
funcionaran cuando el release oficial incluya `install.ps1`, `MensorCAD-CLI.zip`
y `MensorCAD-CLI.zip.sha256`.

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

## Que hace el bootstrap

En este orden, sin saltarse ninguno:

1. valida `-Version` (si se indico) antes de cualquier red o escritura;
2. resuelve el release oficial de `RonGrasz/Mensor-CAD` **una sola vez**
   (API de GitHub para el release mas reciente, o el tag validado de
   `-Version`);
3. descarga `MensorCAD-CLI.zip` y su sidecar `MensorCAD-CLI.zip.sha256` de ese
   tag fijado;
4. comprueba el SHA-256 del ZIP contra el sidecar;
5. valida el indice del ZIP antes de escribir el destino: exactamente tres
   entradas planas (`mensorcad.ps1`, `mensorcad.cmd` e
   `Install-MensorCAD.ps1`), sin duplicados, sin rutas con traversal, sin
   enlaces ni puntos de reanalisis y con tamanios acotados;
6. extrae el ZIP en una carpeta de staging propia (GUID completo), escribe el
   marcador y reemplaza el gestor de forma transaccional; si algo falla se
   restaura la instalacion anterior;
7. agrega la carpeta del gestor al `PATH` del usuario una sola vez.

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
guarda el tag instalado. El ZIP publicado tiene exactamente tres entradas y el
marcador lo agrega el bootstrap fuera del ZIP.

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

## Terminales

Tras la instalacion hace falta una **terminal nueva** para usar `mensorcad`,
porque las terminales ya abiertas conservan el `PATH` con el que arrancaron. La
sesion de PowerShell que ejecuto `irm ... | iex` se actualiza sola y puede usar
el comando de inmediato. Las demas ventanas necesitan reiniciarse.

## Parametros publicos

| Parametro | Efecto |
|-----------|--------|
| `-Version <tag>` | Fija el release; no consulta la API. Acepta tags como `v1.2.3`, `v1.2` o `v1.2.3-rc.1`. |
| `-NoAnimation` | Se conserva por compatibilidad con el bootstrap anterior. No cambia ningun paso: este flujo solo escribe texto plano. |

No hay parametros de URL, repositorio, destino, PATH ni elevacion: la fuente y
el destino son fijos.

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

El sidecar publicado usa el formato `sha256sum`: 64 caracteres hexadecimales,
dos espacios, `MensorCAD-CLI.zip` y salto de linea final. El bootstrap rechaza
cualquier otro contenido.

La revision SHA-256 comprueba que el ZIP coincide con el sidecar del release
fijo `RonGrasz/Mensor-CAD`, pero no autentica al publicador: la confianza viene
del repositorio oficial fijo, no del hash. Si el release o el sidecar se
comprometen, el hash no lo detecta.

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
pide UAC y no llama a GitHub: usa fixtures de ZIP y un registro falso.
