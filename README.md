# Mensor CAD

Plugins LISP para AutoCAD orientados a trabajos topográficos y catastrales. Comandos independientes, la mayoría con interfaz gráfica (DCL).

## Requisitos

- AutoCAD 64-bit (2010 o superior)
- Soporte ActiveX/VLA habilitado (carga automática con `vl-load-com`)

## Instalación

Cargar cada script manualmente con `APPLOAD`, o añadir la carpeta `lisp/` a las rutas de búsqueda de AutoCAD y colocar lo siguiente en tu `acaddoc.lsp`:

```lisp
(vl-load-com)
(load "MC-AREA.lsp"   "\nError al cargar MC-AREA")
(load "MC-TABLE.lsp"  "\nError al cargar MC-TABLE")
(load "MC-VECTOR.lsp" "\nError al cargar MC-VECTOR")
(load "MC-COORD.lsp"  "\nError al cargar MC-COORD")
(load "MC-VERTEX.lsp" "\nError al cargar MC-VERTEX")
```

## Comandos

### MCAREA — Cálculo de Áreas Catastrales

```
MCAREA
```

Calcula el área de una polilínea cerrada e inserta el valor en el centroide del polígono. Soporta dos métodos de cálculo:

| Método | Descripción |
|--------|-------------|
| Estándar | Coordenadas originales sin modificar |
| MIMP / Mensuras RD | Redondeo de coordenadas a 2 decimales antes del cálculo (según normativa dominicana) |

Permite seleccionar la polilínea directamente o detectar el contorno con `-BOUNDARY` haciendo clic en un punto interior.

**Opciones de formato:** precisión decimal (0–4), altura de texto configurable, sufijo `m²` opcional.

### MCTABLE — Tablas de Coordenadas UTM, Rumbos y Distancias

```
MCTABLE
```

Genera dos tablas a partir de una polilínea cerrada:

1. **Tabla de coordenadas georreferenciadas** — ESTE (X) y NORTE (Y) por vértice, con posibilidad de invertir el orden de columnas.
2. **Cuadro de rumbos y distancias** — rumbo en formato `N DD° MM' SS" E` y distancia en metros por tramo.

Numera automáticamente los vértices en el dibujo y permite elegir el vértice de origen, la dirección de recorrido (horaria/antihoraria) y la precisión decimal.

### MCVECTOR — Anotador de Rumbos y Distancias

```
MCVECTOR
```

Anota el rumbo y la distancia de cada segmento de una polilínea directamente sobre el dibujo. El texto se coloca a ambos lados de cada segmento, rotado para mantener legibilidad.

Soporta dos modos:

| Modo | Funcionamiento |
|------|----------------|
| Polígono | Selecciona una polilínea y un vértice de inicio; anota todos los segmentos automáticamente |
| Manual | Indica pares de puntos uno a uno hasta cancelar con ESC |

Permite elegir sentido de recorrido (directo/inverso) y precisión decimal de la distancia (0–8).

### MCCOORD — Tabla de Coordenadas Vinculada a un Punto

```
MCCOORD
```

Solicita un punto, nodo o vértice y un punto de inserción; crea una **TABLE nativa de 3×3** con el título `COORDENADAS UTM 19 NORTE`, los encabezados `ESTE`/`NORTE`/`ALTURA` y los valores X/Y/Z con tres decimales. Además traza una **LINE** desde el punto original hasta la tabla y la mantiene anclada: al mover la tabla con `MOVE` o pinzamientos, la línea se reajusta al terminar el comando.

- Las coordenadas se toman en WCS; el punto original se guarda como instantánea en XDATA (`1010`), por lo que no se recalcula si la geometría de origen cambia después.
- **No hay conversión geodésica**: el dibujo ya debe estar en el CRS previsto (por defecto se rotula UTM zona 19 Norte).
- La línea se actualiza al finalizar/cancelar el comando, no durante el arrastre en vivo.
- Copias, rotaciones y escalados de la tabla no se reasocian de forma garantizada; el caso soportado es el desplazamiento (`MOVE`).
- Requiere **AutoCAD de 64 bits con ActiveX/VLA** y cargar el script en cada dibujo (p. ej. desde `acaddoc.lsp`) para reconectar los reactores; al recargar el script o abrir el dibujo, los extremos de la LINE se reconstruyen desde los metadatos XDATA.

### MCVERTEX — Círculos y etiquetas de vértices

```
MCVERTEX
```

Dibuja un **CIRCLE** centrado en la coordenada exacta de cada vértice de una fuente planar horizontal y, opcionalmente, una etiqueta `PREFIJO-n` junto a cada círculo. El diálogo DCL ofrece cuatro tipos de fuente:

| Tipo de fuente | Descripción |
|----------------|-------------|
| Polilínea ligera cerrada | Selecciona una LWPOLYLINE cerrada |
| Línea (LINE) | Selecciona una LINE horizontal |
| Polilínea ligera abierta | Selecciona una LWPOLYLINE abierta, incluida una cerrada por coincidencia de extremos sin usar `C` |
| Contorno desde punto interior | Genera el contorno con `-BOUNDARY` a partir de un clic interior |

**Selección de geometría y origen.** Los botones *Seleccionar geometría...* y *Seleccionar origen...* suspenden el diálogo para elegir sobre el dibujo; el origen solo se puede fijar después de elegir la geometría. En fuentes cerradas el origen es el **vértice real más cercano** al clic y el recorrido se normaliza **en sentido horario conservando ese origen**. Lo mismo se aplica a una **LWPOLYLINE cerrada por imán**, sin bandera de cierre, si tiene al menos cuatro vértices fuente y sus extremos coinciden dentro de la tolerancia: se selecciona como *Polilínea ligera abierta*, pero se reconoce como circuito **antes de ordenar**. El extremo final duplicado se retira solo de la lista de anotación, antes de rotarla; la entidad original no se modifica. En abiertas reales y LINE el clic sigue eligiendo el **extremo más cercano** y se preserva la continuidad de todos los vértices.

**Apariencia y etiquetas.** El radio (positivo, por defecto `1.0`) y el prefijo (por defecto `E`) se editan en el diálogo. Cada etiqueta `PREFIJO-n` (numeración contigua en orden de recorrido) se **mide con `textbox`** usando el estilo, la altura (`radio × 0.9`), el ancho, el oblicuo y las banderas de generación reales, y se ubica **cerca del vértice, después del círculo y sobre el lado exterior** del contorno: paralela a la dirección de salida (legible, sin quedar boca abajo) y con un **espacio proporcional al radio** (`radio × 0.35`) respecto del círculo y del borde. Ya no se usa un desfase fijo `radio × 1.7`. El interruptor *Mostrar etiquetas* permite dibujar solo los círculos.

**Colocación exterior y búsqueda acotada.** La caja real de cada etiqueta (rectángulo orientado según su rotación) debe quedar **completamente fuera** del polígono fuente: se comprueban esquinas dentro del polígono, vértices del polígono dentro de la caja y cruces/contactos entre lados, además de una separación mínima de `radio × 0.35` respecto de **todos** los tramos de la frontera (el mismo margen que se exige al círculo). También se exige distancia mínima `radio + margen` a **todos** los centros de círculo conservados (no solo a la inserción). La posición se busca con desplazamientos acotados hacia el exterior y a lo largo de la salida, priorizando el **margen exterior pequeño** y, dentro de él, la **cercanía al vértice**. Si en el límite de la búsqueda no hay una posición segura, esa etiqueta se **omite con un aviso que la identifica**, conservando su círculo y el resto de etiquetas válidas; si `textbox` no está disponible tampoco se inventan posiciones. En los **cierres geométricos** se conserva la frontera original completa para comprobar colisiones, ordenada en sentido horario en una copia para que la normal exterior coincida con el recorrido de anotación; la entidad no se cierra ni se reordena físicamente. Una fuente **abierta real no tiene interior**, así que se usa de forma consistente la normal izquierda del recorrido y se evita el cruce con los tramos. Todo el cálculo es en WCS y no se mezcla la caja neutra de `textbox` con `boundingbox` alineada a ejes.

**Tolerancia de fusión y unidades.** El dibujo se interpreta en **metros**, sin conversión de unidades. El diálogo incluye el campo *Tolerancia (m)* con valor inicial `0.001` (1 mm). Se anotan **una sola vez** los vértices consecutivos y el par **primero/último** cuya distancia al **representante conservado** sea **menor o igual** a la tolerancia:

- El representante es la **coordenada fuente exacta** del primer vértice del grupo; nunca se calcula un centroide.
- La comparación se hace contra el representante del grupo y no contra el vecino inmediato, para no encadenar por transitividad vértices que sí son distintos.
- Nunca se fusionan vértices **no adyacentes**: en un contorno cóncavo, en L/U o en una franja estrecha, las puntas cercanas entre sí pero no consecutivas conservan cada una su círculo y su etiqueta.
- En **LWPOLYLINE abiertas con al menos cuatro vértices fuente** cuyos extremos **originales** quedan dentro de la tolerancia (distancia medida antes de fusionar, no contra los representantes), se omite la anotación duplicada del extremo final y se usa un recorrido **horario desde el origen elegido**, igual que en las cerradas nativas. La fuente **no se cierra físicamente**: conserva su bandera abierta y sus coordenadas. Se muestra un aviso de cierre geométrico. Las cadenas con menos de cuatro vértices mantienen su tratamiento anterior; en las cerradas nativas se conserva el origen elegido.
- Si tras la fusión queda un **único vértice**, se dibuja un solo `CIRCLE` y se omite la etiqueta (no hay dirección de salida definida) con un aviso explícito. Los vértices conservados se **renumeran de forma consecutiva**.
- El radio y la tolerancia se validan como **números positivos estrictos** (se rechazan textos como `1abc`); no se aplica conversión de unidades.

**Implementación y capas.** Círculos y textos usan la capa actual (`CLAYER`) y el estilo de texto actual (`TEXTSTYLE`); el comando no crea capas ni estilos. El `TEXT` final usa justificación izquierda/base (`72/73 = 0`) con inserción calculada, las mismas propiedades medidas y la bandera de generación no reflejada. El contorno usa `-BOUNDARY` forzando `PLINETYPE=2` de forma temporal y restaura el valor previo al terminar. Los arcos (bulge) se anotan por la **cuerda** entre vértices: no se añaden vértices sobre los arcos y la comprobación de exterior/colisión usa esas cuerdas, no la curva real (un arco cóncavo puede invadir una etiqueta situada respecto de la cuerda).

**Restricciones.** Solo se admiten fuentes **planas horizontales** (normal `+Z` y cota constante); se rechazan entidades inclinadas o con normal `-Z`. Solo se soportan **LWPOLYLINE ligeras** y LINE; la POLYLINE antigua y la geometría 3D no están soportadas. Al cancelar con ESC se restauran `OSMODE`, `CMDECHO` y `DIMZIN`, se elimina el DCL temporal y se revierten las anotaciones o contornos parciales de esa ejecución, sin borrar geometría preexistente.

> **Verificación parcial en AutoCAD.** El usuario confirmó carga y ejecución, y el origen correcto en una polilínea cerrada con `C`, antes de estos ajustes. La nueva separación y el cierre geométrico todavía requieren prueba manual; no hay tests ni runner automatizado en el repositorio.

**Verificación manual pendiente:**

- [ ] Recargar esta versión con `APPLOAD` y comprobar el mensaje de carga.
- [ ] Cuadrado en ambos sentidos de dibujo y con distintos orígenes: recorrido horario y origen conservado.
- [ ] LINE y polilínea abierta eligiendo ambos extremos como origen.
- [ ] Tolerancia **por debajo**, **igual** y **por encima** del umbral: con tolerancia `0.001`, dos vértices separados `0.0008 m` y `0.001 m` se fusionan, y a `0.002 m` no.
- [ ] Vértices cercanos **no adyacentes** (contorno cóncavo, en L/U o franja estrecha): no se fusionan entre sí.
- [ ] Polígono **cerrado por imán sin `C`**, seleccionado como abierto: elegir un vértice distinto del extremo de creación (por ejemplo, arriba a la izquierda); debe ser `E-1`, con recorrido horario y un solo círculo por vértice. La entidad conserva sus coordenadas y su bandera abierta.
- [ ] Cierre geométrico con tolerancia `0.001`: extremos a `0`, `0.0008 m` y `0.001 m` se reconocen; a `0.002 m` siguen siendo abiertos reales. Comprobar ambos sentidos de creación, también cambiando la tolerancia después de seleccionar y antes de aceptar.
- [ ] Radio o tolerancia **inválidos** (texto como `1abc`, cero o negativo) muestran el aviso y conservan el texto crudo al reabrir el diálogo por geometría u origen.
- [ ] Contorno con islas y con una cola previa de atributos/vértices, confirmando que no se borra geometría existente.
- [ ] Comprobar `PLINETYPE` previo y su restauración tras el contorno, con `REGION`/`BOUNDARY` preexistentes intactos.
- [ ] UCS rotado y distinta elevación: los clics y las coordenadas se interpretan en WCS correctamente.
- [ ] Etiquetas: prefijo, radio, altura y paralelismo correctos, sin quedar invertidas; probar *Mostrar etiquetas* desactivado.
- [ ] Contorno **cóncavo** (L/U/estrecho) y tramos en diagonal: ninguna etiqueta cae dentro del polígono ni cruza lados; si no cabe, aparece el aviso de omisión y se conserva su círculo.
- [ ] **Prefijo largo** y estilos con **ancho/oblicuo** distintos: la caja medida coincide con el texto dibujado y respeta el margen `radio × 0.35` tanto respecto de los círculos como de todos los tramos.
- [ ] Vértices/círculos **muy juntos** (crowded): ninguna etiqueta toca un círculo; las que no caben se omiten de forma identificada sin abortar el resto.
- [ ] Polígono **cerrado por imán dibujado en CCW**: las anotaciones recorren en horario desde el origen elegido, las etiquetas quedan fuera y la fuente sigue marcada como abierta en AutoCAD.
- [ ] Fuente **abierta real** (LINE/abierta): etiquetas a la izquierda del recorrido, sin cruzar los tramos.
- [ ] **Arcos (bulge)**: comprobar que la comprobación por cuerdas no deja una etiqueta dentro de un arco cóncavo.
- [ ] ESC en cada etapa (diálogo, selección, origen, contorno, anotación) sin dejar temporales ni variables alteradas.
- [ ] Revisar que `OSMODE`, `CMDECHO` y `DIMZIN` vuelven a su valor previo.

## Estructura del repositorio

```
lisp/           # Scripts .lsp (el producto)
cuix/icons/     # Iconos para botones CUIX (pendiente)
```

## Licencia

MIT
