<a id="inicio"></a>

<div align="center">
  <img src="docs/images/mensor-cad-title.png" width="900" alt="MensorCAD — herramientas para topografía y catastro en AutoCAD">
</div>

<p align="center">
  Calcula superficies, prepara tablas de coordenadas y completa tus planos.<br>
  <strong>Herramientas para topografía y catastro, directamente en AutoCAD.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/AutoCAD-Windows_64_bits-0CB587?style=for-the-badge&amp;labelColor=073F35" alt="Para AutoCAD de Windows de 64 bits">
  <img src="https://img.shields.io/badge/Herramientas-13-00785E?style=for-the-badge&amp;labelColor=073F35" alt="13 herramientas">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Licencia-MIT-0CB587?style=for-the-badge&amp;labelColor=073F35" alt="Licencia MIT"></a>
</p>

<p align="center">
  <strong>
    <a href="#instalacion">Instalación</a> &nbsp;·&nbsp;
    <a href="#herramientas">Herramientas</a> &nbsp;·&nbsp;
    <a href="#vista-previa">Vista previa</a> &nbsp;·&nbsp;
    <a href="#ayuda">Ayuda</a>
  </strong>
</p>

---

| 📐 Calcula y organiza | 📍 Trabaja con coordenadas | 🌿 Completa la presentación |
|---|---|---|
| Superficies, subdivisiones y tablas de rumbos y distancias. | Importación de puntos, exportación de coordenadas y etiquetas de vértices. | Linderos, edificaciones, vegetación y cuerpos de agua. |

<a id="requisitos"></a>

## Antes de instalar

- **AutoCAD para Windows de 64 bits**, con soporte para AutoLISP y ActiveX. No se garantiza compatibilidad con Mac, AutoCAD Web ni AutoCAD LT.
- Para instalar el paquete completo: **Windows PowerShell 5.1 de 64 bits** y permisos de administrador. Windows incluye PowerShell; no necesitas saber programar.
- **El comando gestor `mensorcad` no pide permisos de administrador**: se instala por usuario. Solo el complemento de AutoCAD se instala por equipo y requiere elevación.
- **Guarda tus dibujos y cierra AutoCAD** antes de instalar, actualizar o desinstalar el paquete.

> **Antes de trabajar:** usa una copia de tu dibujo y revisa sus unidades y sistema de coordenadas. MensorCAD no los convierte automáticamente. Para trabajar con metros y m², prepara el dibujo en metros.

<a id="instalacion"></a>

## Instalación

Instalar MensorCAD son **dos pasos a propósito**: primero el comando gestor
`mensorcad`, que se instala **por usuario** y no pide permisos de administrador;
después el complemento de AutoCAD, que se instala **por equipo** y sí los pide.
Así el complemento se instala, se actualiza y se quita cuando vos lo decidís,
desde la terminal.

<p align="center">
  <a href="https://github.com/RonGrasz/Mensor-CAD/releases/latest">Ver la última versión y sus novedades</a>
</p>

> **Estado de publicación:** el flujo de dos pasos llega con la release
> `v0.2.0`. Mientras la última release siga siendo anterior, el comando del paso
> 1 ejecuta el instalador de un solo paso de esa release y no registra el gestor.

<a id="instalacion-cli"></a>

### Paso 1 · Instalar el comando gestor

Abrí **Windows PowerShell** y pegá este comando:

```powershell
irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/install.ps1' -ea Stop | iex
```

Antes de ejecutarlo, verificá que la URL apunte al repositorio oficial:
`https://github.com/RonGrasz/Mensor-CAD`.

Ese comando descarga el bootstrap desde la última release publicada, verifica el
SHA-256 y el contenido del ZIP del gestor, lo instala en
`%LOCALAPPDATA%\MensorCAD\cli` y agrega esa carpeta al `PATH` de tu usuario **una
sola vez**. No pide permisos de administrador, no descarga el complemento y no
abre AutoCAD.

Cuando termina, el mensaje te pide abrir una terminal nueva: las que ya estaban
abiertas conservan el `PATH` anterior.

<a id="instalacion-complemento"></a>

### Paso 2 · Instalar el complemento

1. **Guardá tus dibujos y cerrá AutoCAD.** El instalador no lo cierra por vos: si
   está abierto, se detiene y te lo pide.
2. Abrí una **terminal nueva** y ejecutá:

```powershell
mensorcad install
```

3. Windows va a pedir permisos de administrador (UAC): aceptá el aviso. El
   complemento se instala en
   `%ProgramFiles%\Autodesk\ApplicationPlugins\MensorCAD.bundle`.
4. Abrí AutoCAD: vas a tener el menú de MensorCAD y sus comandos.

**Pruébalo:** escribí `MCHELP` en la línea de comandos de AutoCAD. Si aparece la
ventana de MensorCAD, ya podés empezar.

#### Comandos del gestor

| Comando | Qué hace |
|---|---|
| `mensorcad` | Muestra un resumen del estado. **No instala nada automáticamente.** |
| `mensorcad install` / `mensorcad -i` | Instala el complemento con la última release publicada. |
| `mensorcad update` | Actualiza sin bajar de versión. Si ya coincide, informa «Ya estás actualizado» y no reinstala. |
| `mensorcad uninstall` | Quita el complemento **sin conexión** y conserva el comando gestor. |
| `mensorcad status` | Muestra la versión del gestor y la versión instalada del complemento, sin usar la red. |
| `mensorcad --help` | Muestra la ayuda. |
| `mensorcad --version` | Muestra la versión del gestor (no la del complemento). |

`status`, `--help` y `--version` son de solo lectura: no descargan, no piden
permisos de administrador y no escriben archivos. El gestor **no se autoactualiza**
en esta etapa: para actualizar el propio comando se vuelve a ejecutar el comando
del paso 1.

#### Si el comando no aparece

- **`mensorcad` no se reconoce.** Abrí una terminal **nueva** —la que ya estaba
  abierta conserva el `PATH` viejo— y probá `mensorcad --version`.
- **`mensorcad install` no puede descargar el paquete.** Revisá la conexión y
  volvé a intentarlo. Si la descarga o la verificación fallan, no se modifica
  nada de lo que ya tenías instalado.
- **¿Construiste los artefactos vos y querés probarlos sin publicar?** La guía
  del [bootstrap del gestor](docs/cli-bootstrap.md) y la del
  [gestor `mensorcad`](docs/cli-manager.md) explican la ruta `-LocalZip`, que no
  usa la red.

<a id="instalacion-manual"></a>

### Histórico · la instalación de un solo paso

Hasta la release `v0.1.0` el único método era descargar `MensorCAD-Windows.zip`
y ejecutar `Instalar.bat`. Ese ZIP se sigue publicando con cada release —y su
`Desinstalar.bat` es la salida para quitar instalaciones anteriores—, pero ya no
es la vía recomendada: el flujo de dos pasos mantiene el complemento al día
desde la terminal.

<a id="instalacion-personalizada"></a>

### Alternativa · Solo las herramientas que necesitas

**Descarga los scripts y cárgalos con APPLOAD, sin instalar el paquete completo.** Esta opción no añade el menú de MensorCAD.

1. Abre la carpeta **[`lisp/`](lisp/)** y elige el archivo de la herramienta que quieras usar. Más abajo tienes la [lista de comandos y archivos](#herramientas).
2. Abre el archivo en GitHub y usa **Download raw file / Descargar archivo sin formato**. Guárdalo en una carpeta de tu equipo, conservando la extensión **`.lsp`**.
3. En AutoCAD, escribe **`APPLOAD`** y presiona Enter.
4. Busca el archivo descargado, selecciónalo y pulsa **Cargar**. Después, cierra la ventana.
5. Escribe el comando de esa herramienta en AutoCAD. Por ejemplo: carga **`MC-AREA.lsp`** y ejecuta **`MCAREA`**.

Repite la carga para cada herramienta que necesites, en el dibujo donde vas a trabajar. **No hace falta cargar todos los archivos ni seguir un orden.** Al volver a abrir AutoCAD, tendrás que cargarlos nuevamente.

<a id="herramientas"></a>

## Una herramienta para cada parte del trabajo

Con el paquete completo, abre una herramienta desde el menú o escribe su comando en AutoCAD. Si elegiste la instalación personalizada, carga primero el archivo indicado.

| Herramienta | Comando | ¿Qué puedes hacer? | Archivo para APPLOAD |
|---|---|---|---|
| <img src="docs/icons/mcarea32.png" width="24" alt=""> **Áreas** | `MCAREA` | Calcular y rotular la superficie de una parcela. | [MC-AREA.lsp](lisp/MC-AREA.lsp) |
| <img src="docs/icons/mctable32.png" width="24" alt=""> **Tablas** | `MCTABLE` | Generar tablas de coordenadas, rumbos y distancias. | [MC-TABLE.lsp](lisp/MC-TABLE.lsp) |
| <img src="docs/icons/mcvector32.png" width="24" alt=""> **Rumbos y distancias** | `MCVECTOR` | Anotar los tramos de un contorno o pares de puntos. | [MC-VECTOR.lsp](lisp/MC-VECTOR.lsp) |
| <img src="docs/icons/mccoord32.png" width="24" alt=""> **Coordenadas** | `MCCOORD` | Colocar una tabla de coordenadas de un punto con línea de referencia. | [MC-COORD.lsp](lisp/MC-COORD.lsp) |
| <img src="docs/icons/mcvertex32.png" width="24" alt=""> **Vértices** | `MCVERTEX` | Marcar y numerar los vértices de un contorno. | [MC-VERTEX.lsp](lisp/MC-VERTEX.lsp) |
| <img src="docs/icons/mcsubdiv32.png" width="24" alt=""> **Subdivisión** | `MCSUBDIV` | Dividir una parcela por superficie, porcentaje o partes iguales. | [MC-SUBDIV.lsp](lisp/MC-SUBDIV.lsp) |
| <img src="docs/icons/mctransform32.png" width="24" alt=""> **Escala por superficie** | `MCTRANSFORM` | Crear una copia de un contorno con el área que necesitas. | [MC-TRANSFORM.lsp](lisp/MC-TRANSFORM.lsp) |
| <img src="docs/icons/mcimport32.png" width="24" alt=""> **Importar puntos** | `MCIMPORT` | Llevar puntos de un archivo TXT o CSV al dibujo. | [MC-IMPORT.lsp](lisp/MC-IMPORT.lsp) |
| <img src="docs/icons/mcexportex32.png" width="24" alt=""> **Exportar coordenadas** | `MCEXPORTEX` | Guardar coordenadas de vértices o posiciones de textos en TXT o CSV. | [MC-EXPORTEX.lsp](lisp/MC-EXPORTEX.lsp) |
| <img src="docs/icons/mcfix32.png" width="24" alt=""> **Preparar polilíneas** | `MCFIX` | Convertir polilíneas antiguas compatibles para trabajar con ellas. | [MC-FIX.lsp](lisp/MC-FIX.lsp) |
| <img src="docs/icons/mccolind32.png" width="24" alt=""> **Colindancias** | `MCCOLIND` | Representar linderos y colocar nombres de colindantes. | [MC-COLIND.lsp](lisp/MC-COLIND.lsp) |
| <img src="docs/icons/mcelements32.png" width="24" alt=""> **Elementos del terreno** | `MCELEMENTS` | Dibujar edificaciones, vegetación, masas de agua y ríos. | [MC-ELEMENTS.lsp](lisp/MC-ELEMENTS.lsp) |
| **Acerca de MensorCAD** | `MCHELP` | Consultar la versión y abrir la página del proyecto. | [MC-HELP.lsp](lisp/MC-HELP.lsp) |

<a id="vista-previa"></a>

## Mira las herramientas por dentro

Consulta las opciones de cada herramienta. Puedes plegar las secciones si lo prefieres.

<details open>
<summary><strong>📐 Superficies y subdivisión de parcelas</strong></summary>

### Cálculo de áreas

Elige el formato del área, los decimales y el tamaño del texto.

<img src="docs/images/Area.png" width="660" alt="Ventana de MCAREA con opciones de cálculo y rotulación de superficies" loading="lazy">

### Subdivisión

Configura cortes paralelos o en abanico y define cómo repartir la superficie.

<img src="docs/images/Subdividir.png" width="660" alt="Ventana de MCSUBDIV para dividir parcelas" loading="lazy">

</details>

<details open>
<summary><strong>📍 Tablas, rumbos y vértices</strong></summary>

### Tablas de coordenadas

Ajusta las columnas, el recorrido y las etiquetas de los vértices.

<img src="docs/images/Tabla-de-coordenadas.png" width="660" alt="Ventana de MCTABLE para preparar tablas de coordenadas" loading="lazy">

### Rumbos y distancias

Elige entre recorrer un contorno o indicar pares de puntos manualmente.

<img src="docs/images/Rumbo-y-distancia.png" width="660" alt="Ventana de MCVECTOR para anotar rumbos y distancias" loading="lazy">

### Símbolos de vértices

Elige el símbolo, su tamaño y la numeración que vas a usar.

<img src="docs/images/Etiqueta-de-vertice.png" width="660" alt="Ventana de MCVERTEX con símbolos y etiquetas de vértices" loading="lazy">

</details>

<details open>
<summary><strong>📂 Importación y exportación de puntos</strong></summary>

### Importar puntos

Selecciona el archivo, el orden de las coordenadas y la apariencia de los puntos.

<img src="docs/images/Importar-puntos.png" width="660" alt="Ventana de MCIMPORT para importar puntos desde TXT o CSV" loading="lazy">

### Exportar coordenadas

Elige los objetos de origen y guarda sus coordenadas en un archivo.

<img src="docs/images/Exportar-puntos.png" width="660" alt="Ventana de MCEXPORTEX para exportar coordenadas" loading="lazy">

</details>

<details open>
<summary><strong>🌿 Colindancias y elementos del terreno</strong></summary>

### Colindancias

Elige el estilo de lindero y el nombre de la colindancia.

<img src="docs/images/Estilo-de-colindancia.png" width="660" alt="Ventana de MCCOLIND con estilos de colindancias" loading="lazy">

### Elementos del terreno

Agrega edificaciones, áreas verdes y agua con sus opciones de presentación.

<img src="docs/images/Estructuras.png" width="660" alt="Ventana de MCELEMENTS para dibujar elementos del terreno" loading="lazy">

</details>

<a id="ayuda"></a>

## Ayuda rápida

| Si te pasa esto… | Prueba lo siguiente |
|---|---|
| AutoCAD dice «Comando desconocido». | Si usaste APPLOAD, carga el archivo correspondiente en ese dibujo. Si instalaste el paquete, cierra y vuelve a abrir AutoCAD. |
| El instalador pide cerrar AutoCAD. | Guarda tus dibujos, cierra todas las ventanas de AutoCAD y ejecuta nuevamente el instalador. |
| `mensorcad` no se reconoce como comando. | Abre una terminal **nueva**: las que ya estaban abiertas conservan el `PATH` viejo. Después ejecuta `mensorcad --version`. |
| `mensorcad install` no puede descargar el paquete. | Revisa tu conexión y vuelve a intentarlo desde la [página de descargas](https://github.com/RonGrasz/Mensor-CAD/releases/latest). Si la descarga o la verificación fallan, no se modifica nada de lo que ya tenías instalado. |
| Una herramienta no acepta el contorno. | Revisa los mensajes de AutoCAD. Algunas herramientas necesitan una polilínea cerrada, plana y sin cruces. |

**¿Necesitas reportar un problema?** Cuéntanos qué comando usaste, tu versión de AutoCAD y qué ocurrió en **[Problemas y consultas](https://github.com/RonGrasz/Mensor-CAD/issues)**. Una captura del mensaje ayuda.

<a id="actualizacion"></a>

## Actualizar

- **Con el gestor:** `mensorcad update`. Compara la versión instalada con la disponible y, si coinciden, informa «Ya estás actualizado» sin reinstalar. Nunca baja de versión de forma silenciosa; si la comparación no es posible, no modifica nada.
- **Con el ZIP (instalaciones anteriores):** descarga el ZIP nuevo y ejecuta `Instalar.bat` como antes. **No necesitas desinstalar primero.**
- **Con APPLOAD:** reemplaza tus archivos por los nuevos y vuelve a cargarlos después de reiniciar AutoCAD.

<a id="desinstalacion"></a>

## Desinstalar

- **Con el gestor:** cierra AutoCAD y ejecuta `mensorcad uninstall`. Quita el complemento **sin conexión** con el motor protegido que quedó dentro de la instalación y **conserva el comando gestor, su carpeta y el `PATH`** para poder reinstalar. Si AutoCAD está abierto, avisa y sale sin cerrarlo.
- **Instalaciones anteriores o sin gestor:** descarga el ZIP y haz doble clic en **`Desinstalar.bat`**, en la carpeta donde extrajiste el ZIP. Conserva ese archivo junto a `Instalar.bat` e `Install-MensorCAD.ps1` y acepta el aviso de permisos. Es el respaldo para instalaciones viejas que no incluyen el motor de desinstalación.
- **Carga con APPLOAD:** cierra AutoCAD y no vuelvas a cargar los scripts. Si ya no los necesitas, puedes borrar los archivos descargados.

Las tablas, textos y símbolos que ya creaste **permanecen en tus dibujos**. Las funciones automáticas que dependan de una herramienta dejarán de ejecutarse si no está cargada.

---

<p align="center">
  <strong>MensorCAD™ · Topografía y catastro en AutoCAD</strong><br>
  Distribuido bajo la <a href="LICENSE">licencia MIT</a>.<br><br>
  <a href="#inicio">↑ Volver al inicio</a>
</p>
