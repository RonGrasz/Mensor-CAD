# Arquitectura

## La estructura ideal para tu repositorio

Para que el repositorio sea atractivo, ordenado y fácil de migrar a futuro (a C# o C++), te recomiendo organizar los archivos separando la **interfaz** de la **lógica**. Aquí tienes una propuesta de estructura limpia:

```text
📦 mi-repositorio-cad
 ┣ 📂 lisp                 # Todos tus scripts .lsp sueltos
 ┃ ┣ 📜 limpieza-planos.lsp
 ┃ ┣ 📜 exportar-puntos.lsp
 ┃ ┗ 📜 utils-geometria.lsp
 ┣ 📂 cuix                 # Archivos de personalización
 ┃ ┣ 📜 mis-herramientas.cuix
 ┃ ┗ 📂 iconos             # Imágenes (.png) de 16x16 y 32x32 para los botones
 ┣ 📜 acaddoc.lsp          # El cargador automático (crucial)
 ┣ 📜 LICENSE              # Licencia (ej. MIT para que sea libre)
 ┗ 📜 README.md            # Las instrucciones de instalación

```

---

## 🔧 El truco del archivo `acaddoc.lsp` (La clave de la automatización)

Para que la comunidad no tenga que cargar los LISP uno por uno usando el comando `APPLOAD`, incluye un archivo llamado `acaddoc.lsp` en la raíz de la carpeta.

AutoCAD busca este archivo automáticamente en sus rutas de soporte cada vez que se abre un dibujo. Dentro de él, puedes programar la carga automática de tus scripts y del menú CUIX usando las funciones VLA que ya conoces:

```lisp
;; acaddoc.lsp
(vl-load-com)

;; 1. Cargar los scripts LISP de forma automática
(load "limpieza-planos.lsp" "\nError al cargar limpieza-planos")
(load "exportar-puntos.lsp" "\nError al cargar exportar-puntos")

;; 2. Cargar el menú CUIX automáticamente si no está cargado
(defun c:CargarMiMenu ()
  (if (not (menugroup "MI_MENU_COMUNIDAD"))
    (vl-cmdf "_.menuload" "mis-herramientas.cuix")
  )
  (princ "\n[Menu de la Comunidad Cargado Correctamente]")
  (princ)
)
(c:CargarMiMenu)

```

---

## 🗺️ La ruta de migración: De LISP a .NET (C#)

Si la comunidad se inspira y el repositorio crece, la transición de LISP a C# usando tu estructura de CUIX es sumamente sencilla gracias a cómo maneja AutoCAD las macros de los botones.

Cuando creas un botón en el editor `CUI](comando `CUI`), la macro asociada simplemente escribe un comando en la barra de texto de AutoCAD:

```text
Macro del botón actual (LISP):   ^C^C_MI_COMANDO_LISP

```

Si el día de mañana alguien reescribe esa función en **C#**, la macro del botón **no tiene que cambiar**. El botón seguirá llamando a `^C^C_MI_COMANDO_LISP`. Lo único que cambiará es el trasfondo: en lugar de cargar un archivo `.lsp`, el usuario cargará un archivo `.dll` usando `NETLOAD`.

Esto significa que **toda la interfaz CUIX que diseñes hoy seguirá siendo 100% útil en el futuro**, sin importar si el motor del comando es LISP, C# o C++.

---

## 🚀 Consejos para lanzar el repositorio

1. **Usa una licencia clara:** Te recomiendo la **Licencia MIT**. Es súper permisiva, le dice a la gente "puedes usar esto para lo que quieras, incluso comercialmente, solo mantén mi nombre en los créditos", lo cual fomenta que la gente pierda el miedo a colaborar.
2. **Haz un buen README:** Pon capturas de pantalla o GIFs animados mostrando qué hace cada script. Los ingenieros y diseñadores compran mucho por los ojos; si ven un GIF de una polilínea automatizándose, querrán descargar el repositorio de inmediato.
3. **Crea "Issues" (Tareas pendientes):** En GitHub, deja una lista de ideas de scripts que te gustaría tener pero no has tenido tiempo de programar. Eso le da a los programadores novatos un punto de partida para ayudarte.

¿Tienes pensado ya cuál va a ser ese primer script "estrella" con el que vas a inaugurar el repositorio?