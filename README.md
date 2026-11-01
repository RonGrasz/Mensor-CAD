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
- **Guarda tus dibujos y cierra AutoCAD** antes de instalar, actualizar o desinstalar el paquete.

> **Antes de trabajar:** usa una copia de tu dibujo y revisa sus unidades y sistema de coordenadas. MensorCAD no los convierte automáticamente. Para trabajar con metros y m², prepara el dibujo en metros.

<a id="instalacion"></a>

## Instalación

Elige la forma que te resulte más cómoda. **Si quieres todas las herramientas y su menú, usa el ZIP.**

<p align="center">
  <a href="https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/MensorCAD-Windows.zip"><img src="https://img.shields.io/badge/Descargar-MensorCAD_para_Windows-0CB587?style=for-the-badge&amp;labelColor=073F35" alt="Descargar MensorCAD para Windows en ZIP"></a>
  <br>
  <a href="https://github.com/RonGrasz/Mensor-CAD/releases/latest">Ver la última versión y sus novedades</a>
</p>

<a id="instalacion-manual"></a>

### 1. Manual · Descargando el ZIP

**La opción recomendada: descargar, extraer e instalar con doble clic.**

1. **[Descarga MensorCAD para Windows](https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/MensorCAD-Windows.zip)**. El archivo se llama **`MensorCAD-Windows.zip`**; no es el archivo «Source code (zip)» de GitHub.
2. Descárgalo, haz clic derecho sobre él y elige **Extraer todo**. Conserva juntos todos los archivos extraídos; no ejecutes el instalador desde dentro del ZIP.
3. Con AutoCAD cerrado, abre la carpeta extraída y haz doble clic en **`Instalar.bat`**.
4. Acepta el aviso de permisos de Windows y espera el mensaje final del instalador.
5. Abre AutoCAD. Tendrás disponibles el menú de MensorCAD y sus comandos.

**Pruébalo:** escribe `MCHELP` en la línea de comandos de AutoCAD. Si aparece la ventana de MensorCAD, ya puedes empezar.

<a id="instalacion-cli"></a>

### 2. CLI · Desde PowerShell

**La alternativa para instalar la última versión desde la terminal, sin descargar el ZIP a mano.** Necesitas conexión a Internet.

1. Guarda tus dibujos y cierra AutoCAD.
2. En el menú Inicio de Windows, busca y abre **Windows PowerShell** de 64 bits.
3. Copia esta línea completa, pégala en PowerShell y presiona **Enter**:

```powershell
irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/install.ps1' -ea Stop | iex
```

4. Acepta el aviso de permisos de Windows y espera a que el instalador termine.
5. Abre AutoCAD y escribe `MCHELP` para comprobar la instalación.

Este comando descarga y ejecuta el instalador oficial de **RonGrasz/Mensor-CAD**. Úsalo únicamente si confías en el proyecto.

<a id="instalacion-personalizada"></a>

### 3. Personalizada · Solo las herramientas que necesitas

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
| La descarga del ZIP o la instalación por CLI falla. | Revisa tu conexión y vuelve a intentarlo desde la [página de descargas](https://github.com/RonGrasz/Mensor-CAD/releases/latest). |
| Una herramienta no acepta el contorno. | Revisa los mensajes de AutoCAD. Algunas herramientas necesitan una polilínea cerrada, plana y sin cruces. |

**¿Necesitas reportar un problema?** Cuéntanos qué comando usaste, tu versión de AutoCAD y qué ocurrió en **[Problemas y consultas](https://github.com/RonGrasz/Mensor-CAD/issues)**. Una captura del mensaje ayuda.

<a id="actualizacion"></a>

## Actualizar

Cierra AutoCAD e instala la versión nueva por ZIP o CLI. **No necesitas desinstalar primero.** Si usas APPLOAD, reemplaza tus archivos por los nuevos y vuelve a cargarlos después de reiniciar AutoCAD.

<a id="desinstalacion"></a>

## Desinstalar

- **Paquete completo:** cierra AutoCAD y haz doble clic en **`Desinstalar.bat`**, en la carpeta donde extrajiste el ZIP. Conserva ese archivo junto a `Instalar.bat` e `Install-MensorCAD.ps1` y acepta el aviso de permisos. Si instalaste por CLI y no tienes esa carpeta, descarga y extrae el ZIP para acceder al desinstalador.
- **Carga con APPLOAD:** cierra AutoCAD y no vuelvas a cargar los scripts. Si ya no los necesitas, puedes borrar los archivos descargados.

Las tablas, textos y símbolos que ya creaste **permanecen en tus dibujos**. Las funciones automáticas que dependan de una herramienta dejarán de ejecutarse si no está cargada.

---

<p align="center">
  <strong>MensorCAD™ · Topografía y catastro en AutoCAD</strong><br>
  Distribuido bajo la <a href="LICENSE">licencia MIT</a>.<br><br>
  <a href="#inicio">↑ Volver al inicio</a>
</p>
