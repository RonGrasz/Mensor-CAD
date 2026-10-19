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
(load "MC-SUBDIV.lsp" "\nError al cargar MC-SUBDIV")
(load "MC-TRANSFORM.lsp" "\nError al cargar MC-TRANSFORM")
(load "MC-IMPORT.lsp" "\nError al cargar MC-IMPORT")
(load "MC-FIX.lsp" "\nError al cargar MC-FIX")
(load "MC-COLIND.lsp" "\nError al cargar MC-COLIND")
(load "MC-ELEMENTS.lsp" "\nError al cargar MC-ELEMENTS")
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

### MCVERTEX — Símbolos y etiquetas de vértices

```
MCVERTEX
```

Dibuja un **símbolo local** (20 estilos tipo `DDPTYPE`) centrado en la coordenada exacta de cada vértice anotado de una fuente planar horizontal y, opcionalmente, una etiqueta `PREFIJO-n` junto a cada símbolo. El predeterminado es el **círculo sin marca central** (modo `33`). El diálogo DCL ofrece cuatro tipos de fuente:

| Tipo de fuente | Descripción |
|----------------|-------------|
| Polilínea ligera cerrada | Selecciona una LWPOLYLINE cerrada |
| Línea (LINE) | Selecciona una LINE horizontal |
| Polilínea ligera abierta | Selecciona una LWPOLYLINE abierta, incluida una cerrada por coincidencia de extremos sin usar `C` |
| Contorno desde punto interior | Genera el contorno con `-BOUNDARY` a partir de un clic interior |

**Selección de geometría y origen.** Los botones *Seleccionar geometría...* y *Seleccionar origen...* suspenden el diálogo para elegir sobre el dibujo; el origen solo se puede fijar después de elegir la geometría. En fuentes cerradas el origen es el **vértice real más cercano** al clic y el recorrido se normaliza **en sentido horario conservando ese origen**. Lo mismo se aplica a una **LWPOLYLINE cerrada por imán**, sin bandera de cierre, si tiene al menos cuatro vértices fuente y sus extremos coinciden dentro de la tolerancia: se selecciona como *Polilínea ligera abierta*, pero se reconoce como circuito **antes de ordenar**. El extremo final duplicado se retira solo de la lista de anotación, antes de rotarla; la entidad original no se modifica. En abiertas reales y LINE el clic sigue eligiendo el **extremo más cercano** y se preserva la continuidad de todos los vértices.

**Muestreo de vértices.** Sobre los vértices ya **conservados tras la tolerancia** se aplica un muestreo opcional. El campo *Vértices a omitir entre puntos* es un **entero no negativo** (por defecto `0`): `0` conserva todos; `3` avanza de cuatro en cuatro y produce las posiciones `1, 5, 9, 13…`. El muestreo **solo se activa desde cinco representantes** (`≥ 5`); con menos de cinco se anotan todos. El origen, el recorrido, las direcciones de salida y la frontera completa se calculan siempre con la lista de representantes de referencia; el muestreo solo elige qué centros se dibujan. Los centros de marcador usados en las colisiones son **únicamente los seleccionados**.

**Numeración de los vértices.** El campo *Número inicial* acepta cualquier **entero positivo** (por defecto `1`). Cada representante del recorrido completo tiene su número: **omitir su dibujo no renumera los restantes**. Con inicio `1` y omisión `2`, se rotulan `E-1`, `E-4`, `E-7…`; con inicio `5`, `E-5`, `E-8`, `E-11…`. Con omisión `3` e inicio `1`, se obtiene `E-1`, `E-5`, `E-9…`. Se exige un entero entre `1` y `2147483647`; antes de crear entidades se comprueba que `inicio + índice del último vértice seleccionado` (índice desde cero) no desborde ese límite. Las entradas se conservan al reabrir el diálogo por geometría u origen.

**Apariencia, símbolo y etiquetas.** El radio (positivo, por defecto `1.0`), el prefijo (por defecto `E`), el **tipo de símbolo**, el **número inicial** y los **vértices a omitir** se editan en el diálogo. El selector *Símbolo del vértice* lista las **20 combinaciones de `DDPTYPE`** con **previsualización DCL**; el predeterminado es **círculo sin marca central** (modo `33`). El símbolo y sus etiquetas se crean como **entidades locales** (`LINE`, `CIRCLE` y un `SOLID` diminuto para el punto); no son entidades `POINT` ni objetos COGO y **no se modifica `PDMODE`/`PDSIZE`**. Cada etiqueta `PREFIJO-n` (número del vértice en el recorrido completo, sin compactar por omisión) se **mide con `textbox`** usando el estilo, la altura (`radio × 0.9`), el ancho, el oblicuo y las banderas de generación reales, y se ubica **cerca del vértice, después del símbolo y sobre el lado exterior** del contorno: paralela a la dirección de salida (legible, sin quedar boca abajo) y con un **espacio proporcional al radio** (`radio × 0.35`) respecto del símbolo y del borde. Ya no se usa un desfase fijo `radio × 1.7`. El interruptor *Mostrar etiquetas* permite dibujar solo los símbolos; el **estilo invisible exige etiquetas activas** porque, sin ellas, no generaría ninguna salida.

**Colocación exterior y búsqueda acotada.** La caja real de cada etiqueta (rectángulo orientado según su rotación) debe quedar **completamente fuera** del polígono fuente: se comprueban esquinas dentro del polígono, vértices del polígono dentro de la caja y cruces/contactos entre lados, además de una separación mínima de `radio × 0.35` respecto de **todos** los tramos de la frontera. La colisión con los símbolos usa una **envolvente conservadora** ajustada a la extensión máxima del estilo elegido: `radio` para círculo, cruz `+` y trazo vertical; `√2 · radio` para cuadrado y cruz `X` (sus esquinas); el punto solo, que es un `SOLID` diminuto; y `0` para el estilo invisible, que no deja huella. La caja debe quedar a distancia mínima `envolvente + margen` de **todos** los centros de marcador seleccionados (no solo a la inserción) y el primer desplazamiento candidato ya parte de esa envolvente. La posición se busca con desplazamientos acotados hacia el exterior y a lo largo de la salida, priorizando el **margen exterior pequeño** y, dentro de él, la **cercanía al vértice**. Si en el límite de la búsqueda no hay una posición segura, esa etiqueta se **omite con un aviso que la identifica**, conservando su símbolo y el resto de etiquetas válidas; si `textbox` no está disponible tampoco se inventan posiciones. En los **cierres geométricos** se conserva la frontera original completa para comprobar colisiones, ordenada en sentido horario en una copia para que la normal exterior coincida con el recorrido de anotación; la entidad no se cierra ni se reordena físicamente. Una fuente **abierta real no tiene interior**, así que se usa de forma consistente la normal izquierda del recorrido y se evita el cruce con los tramos. Todo el cálculo es en WCS y no se mezcla la caja neutra de `textbox` con `boundingbox` alineada a ejes.

**Tolerancia de fusión y unidades.** El dibujo se interpreta en **metros**, sin conversión de unidades. El diálogo incluye el campo *Tolerancia (m)* con valor inicial `0.001` (1 mm). Se anotan **una sola vez** los vértices consecutivos y el par **primero/último** cuya distancia al **representante conservado** sea **menor o igual** a la tolerancia:

- El representante es la **coordenada fuente exacta** del primer vértice del grupo; nunca se calcula un centroide.
- La comparación se hace contra el representante del grupo y no contra el vecino inmediato, para no encadenar por transitividad vértices que sí son distintos.
- Nunca se fusionan vértices **no adyacentes**: en un contorno cóncavo, en L/U o en una franja estrecha, las puntas cercanas entre sí pero no consecutivas conservan cada una su símbolo y su etiqueta.
- En **LWPOLYLINE abiertas con al menos cuatro vértices fuente** cuyos extremos **originales** quedan dentro de la tolerancia (distancia medida antes de fusionar, no contra los representantes), se omite la anotación duplicada del extremo final y se usa un recorrido **horario desde el origen elegido**, igual que en las cerradas nativas. La fuente **no se cierra físicamente**: conserva su bandera abierta y sus coordenadas. Se muestra un aviso de cierre geométrico. Las cadenas con menos de cuatro vértices mantienen su tratamiento anterior; en las cerradas nativas se conserva el origen elegido.
- Si tras la fusión queda un **único vértice**, se dibuja un solo **símbolo** y se **omite la etiqueta** (no hay dirección de salida definida) con un aviso explícito; con el estilo invisible ese caso no genera ninguna entidad y se rechaza antes de crear. La numeración se asigna al recorrido completo de representantes desde el número inicial; el muestreo solo controla cuáles se dibujan.
- El radio y la tolerancia se validan como **números positivos estrictos** (se rechazan textos como `1abc`); no se aplica conversión de unidades.

**Implementación y capas.** Los símbolos (`LINE`, `CIRCLE`, `SOLID`) y los textos usan la capa actual (`CLAYER`) y el estilo de texto actual (`TEXTSTYLE`); el comando no crea capas ni estilos. Cada entidad creada (cada segmento de línea, círculo, cuadrado, marca puntual o texto) se registra para revertir **solo lo creado en la ejecución** ante un fallo parcial o ESC. El `TEXT` final usa justificación izquierda/base (`72/73 = 0`) con inserción calculada, las mismas propiedades medidas y la bandera de generación no reflejada. El contorno usa `-BOUNDARY` forzando `PLINETYPE=2` de forma temporal y restaura el valor previo al terminar. Los arcos (bulge) se anotan por la **cuerda** entre vértices: no se añaden vértices sobre los arcos y la comprobación de exterior/colisión usa esas cuerdas, no la curva real (un arco cóncavo puede invadir una etiqueta situada respecto de la cuerda).

**Restricciones.** Solo se admiten fuentes **planas horizontales** (normal `+Z` y cota constante); se rechazan entidades inclinadas o con normal `-Z`. Solo se soportan **LWPOLYLINE ligeras** y LINE; la POLYLINE antigua y la geometría 3D no están soportadas. Al cancelar con ESC se restauran `OSMODE`, `CMDECHO` y `DIMZIN`, se elimina el DCL temporal y se revierten las anotaciones o contornos parciales de esa ejecución, sin borrar geometría preexistente.

> **Refactor cerrado por decisión del usuario, con verificación parcial en AutoCAD.** El usuario confirmó que **el fix de numeración al omitir puntos funciona correctamente** en su prueba manual. Aclaró que **no se probaron todos los escenarios**; esta confirmación no acredita cada variante de muestreo, número inicial, desbordamiento, símbolos, colisiones o cancelación. Antes de estos ajustes también había confirmado carga, ejecución y origen correcto en una polilínea cerrada con `C`. No hay tests ni runner automatizado en el repositorio: las comprobaciones del agente fueron estructurales y la prueba funcional fue realizada por el usuario.

**Verificación manual:**

- [x] Fix de numeración al omitir puntos: resultado positivo confirmado por el usuario, sin atribuir cobertura a escenarios individuales.

**Escenarios no confirmados; lista conservada para futuras regresiones (no bloquea el cierre aceptado por el usuario):**

- [ ] Recargar esta versión con `APPLOAD` y comprobar el mensaje de carga.
- [ ] Cuadrado en ambos sentidos de dibujo y con distintos orígenes: recorrido horario y origen conservado.
- [ ] LINE y polilínea abierta eligiendo ambos extremos como origen.
- [ ] Tolerancia **por debajo**, **igual** y **por encima** del umbral: con tolerancia `0.001`, dos vértices separados `0.0008 m` y `0.001 m` se fusionan, y a `0.002 m` no.
- [ ] Vértices cercanos **no adyacentes** (contorno cóncavo, en L/U o franja estrecha): no se fusionan entre sí.
- [ ] Polígono **cerrado por imán sin `C`**, seleccionado como abierto: elegir un vértice distinto del extremo de creación (por ejemplo, arriba a la izquierda); debe ser `E-1`, con recorrido horario y un solo símbolo por vértice. La entidad conserva sus coordenadas y su bandera abierta.
- [ ] Cierre geométrico con tolerancia `0.001`: extremos a `0`, `0.0008 m` y `0.001 m` se reconocen; a `0.002 m` siguen siendo abiertos reales. Comprobar ambos sentidos de creación, también cambiando la tolerancia después de seleccionar y antes de aceptar.
- [ ] Radio o tolerancia **inválidos** (texto como `1abc`, cero o negativo) muestran el aviso y conservan el texto crudo al reabrir el diálogo por geometría u origen.
- [ ] Contorno con islas y con una cola previa de atributos/vértices, confirmando que no se borra geometría existente.
- [ ] Comprobar `PLINETYPE` previo y su restauración tras el contorno, con `REGION`/`BOUNDARY` preexistentes intactos.
- [ ] UCS rotado y distinta elevación: los clics y las coordenadas se interpretan en WCS correctamente.
- [ ] Etiquetas: prefijo, radio, altura y paralelismo correctos, sin quedar invertidas; probar *Mostrar etiquetas* desactivado.
- [ ] Contorno **cóncavo** (L/U/estrecho) y tramos en diagonal: ninguna etiqueta cae dentro del polígono ni cruza lados; si no cabe, aparece el aviso de omisión y se conserva su símbolo.
- [ ] **Prefijo largo** y estilos con **ancho/oblicuo** distintos: la caja medida coincide con el texto dibujado y respeta el margen `radio × 0.35` tanto respecto de los símbolos como de todos los tramos.
- [ ] Vértices/símbolos **muy juntos** (crowded): ninguna etiqueta toca la envolvente de un símbolo; las que no caben se omiten de forma identificada sin abortar el resto.
- [ ] **Muestreo:** fuente con **4** representantes tras la tolerancia anota los 4; con **5 o más** y omisión `0` anota todos; con omisión `3` produce las posiciones `1, 5, 9, 13…`. Comprobar que la frontera y las direcciones siguen usando la lista completa de representantes.
- [ ] **Número inicial y omisiones:** sobre al menos 7 representantes, inicio `1` y omisión `2` produce `E-1`, `E-4`, `E-7…`; inicio `5` produce `E-5`, `E-8`, `E-11…`. Omisión `3` e inicio `1`: `E-1`, `E-5`, `E-9…`. Con omisión `0` se mantiene la numeración consecutiva; por debajo de cinco representantes se anotan todos. Inicio `2147483644`, omisión `2` y 7 representantes debe rechazar antes de crear: el tercer punto sería `2147483650`. Con ese mismo inicio y solo 5 representantes, los números `2147483644` y `2147483647` son válidos.
- [ ] **Símbolos:** probar las 20 combinaciones con su previsualización y comprobar que se crean `LINE`/`CIRCLE`/`SOLID` locales. Registrar `PDMODE`/`PDSIZE` y los `POINT` preexistentes antes/después: deben permanecer intactos. Estilo invisible sin etiquetas: rechazo; con etiquetas: solo textos.
- [ ] **Envolvente:** con cuadrado o cruz `X`, ninguna etiqueta debe tocar las esquinas del símbolo (`√2 · radio`); con el punto solo, la etiqueta puede acercarse más.
- [ ] Polígono **cerrado por imán dibujado en CCW**: las anotaciones recorren en horario desde el origen elegido, las etiquetas quedan fuera y la fuente sigue marcada como abierta en AutoCAD.
- [ ] Fuente **abierta real** (LINE/abierta): etiquetas a la izquierda del recorrido, sin cruzar los tramos.
- [ ] **Arcos (bulge)**: comprobar que la comprobación por cuerdas no deja una etiqueta dentro de un arco cóncavo.
- [ ] ESC en cada etapa (diálogo, selección, origen, contorno, anotación) sin dejar temporales ni variables alteradas.
- [ ] Revisar que `OSMODE`, `CMDECHO` y `DIMZIN` vuelven a su valor previo.

### MCSUBDIV — Subdivisión por superficie

```
MCSUBDIV
```

**Feature aceptada tras pruebas manuales positivas en AutoCAD, incluidos el anclaje, el contorno de polígonos cerrados manualmente y los polígonos cerrados con `C`.** Divide una **LWPOLYLINE simple, horizontal y de tramos rectos** por superficie, mediante cortes paralelos o cortes anclados en abanico. La polilínea fuente permanece intacta. El comando es independiente: no requiere cargar otros scripts.

#### Uso

1. Cargar `lisp/MC-SUBDIV.lsp` con `APPLOAD` y ejecutar `MCSUBDIV`.
2. Seleccionar una polilínea cerrada o abierta. Si no tiene `C`, se trabaja con una copia cerrada uniendo último y primer vértice. Si sus extremos coinciden dentro de la tolerancia geométrica, el extremo final duplicado se retira **solo de la copia**. El cierre debe producir un contorno simple válido.
3. Elegir el método en el diálogo:

   | Método | Resultado |
   |--------|-----------|
   | Partes iguales | N parcelas de área total / N; N−1 posiciones de corte |
   | Área + resto | Una parcela objetivo y otra con el resto |
   | Porcentaje + resto | Una parcela con el porcentaje del área original y otra con el resto |

4. Pulsar **Definir dirección...**. Elegir dos puntos para dibujar la guía, o hacer clic cerca de dos **vértices reales distintos** de la fuente. La selección por vértices toma el vértice de la fuente más cercano a cada clic.
5. Elegir **Tipo de corte**:
   - **Paralelo (trasladar):** conserva el comportamiento anterior. Opcionalmente activar **Rotar la guía**, indicar un ángulo relativo en grados (positivo antihorario, negativo horario) y seleccionar un pivote. La guía se rota antes del ajuste por superficie; el corte final no está obligado a pasar por ese pivote.
   - **Anclado (girar / abanico):** elegir **Primer punto** o **Segundo punto** de la guía como ancla. Ese punto debe coincidir con un vértice real del contorno; resulta práctico definir la guía mediante dos vértices. El comando determina el ángulo necesario, manteniendo fijo ese vértice. La rotación manual queda deshabilitada en este modo, pero conserva sus valores al volver al paralelo.
6. Para área o porcentaje, elegir el lado objetivo. Ajustar tolerancia, altura y decimales, y pulsar **Subdividir**. En partes iguales ancladas, las N−1 cuerdas comparten el ancla: las áreas son iguales, no necesariamente los ángulos.

El diálogo se suspende durante las selecciones y se reabre conservando los campos, incluidos los textos todavía inválidos y las opciones de anclaje. En el modo paralelo, la guía solo determina la dirección: su longitud y posición inicial no limitan la subdivisión. En el anclado, la guía identifica el vértice fijo y el ángulo final lo determina la superficie. Las cotas Z se proyectan al plano horizontal de la fuente; los clics se convierten de UCS a WCS.

#### Orientación y precisión

- **Norte = +Y y Este = +X de WCS**, sin transformación geodésica ni conversión de unidades; el dibujo se interpreta en metros. Un UCS rotado no cambia los lados cardinales.
- El lado elegido recibe la parcela objetivo (**Lote 1**). En paralelo, las diagonales eligen el semiplano compatible, no un cuadrante; una orientación paralela a la guía se rechaza. En anclado, se busca una cuerda cuyo lado local del lote objetivo sea compatible con esa dirección WCS; la guía inicial no limita el ángulo. En un cóncavo que envuelve el ancla esto es una preferencia de lado del corte, no una garantía de que todos los puntos estén en un cuadrante.
- En partes iguales paralelas, invertir la guía invierte la numeración, no las superficies. En abanico se recorre la frontera desde el ancla en sentido antihorario; si no se encuentra una secuencia válida se intenta el horario.
- Los cortes se resuelven por **áreas acumuladas**, no por separaciones ni ángulos iguales. La tolerancia de área es positiva y empieza en `0.01 m²`. El modo paralelo usa bisección con tolerancia/4 y un máximo de 80 iteraciones por corte. En anclado, el área acumulada es afín a lo largo de cada arista: se calcula el punto de llegada y, con él, la dirección de la cuerda. No se supone que el área sea monótona respecto del ángulo en todo un cóncavo.
- Cada parcela y la suma total deben cumplir la tolerancia de área. El objetivo y el resto, o cada parte igual, deben superar esa tolerancia. Para superficies menores hay que reducirla.
- La tolerancia geométrica interna es independiente: `max(1e-8 m, extensión XY × 1e-10)`. Los cálculos usan un origen local cercano a la fuente para evitar pérdida de precisión en coordenadas UTM.
- Los decimales de la etiqueta (0–4) **no intervienen en los cortes**. Se aceptan números con punto decimal y signo; se rechazan texto sobrante (`1abc`), comas y exponentes. Partes exige un entero ≥2; porcentaje exige `0 < valor < 100`; área exige `0 < valor < área total`.

#### Salida y restricciones

La salida contiene **LWPOLYLINE cerradas, LINE divisorias y MTEXT** con número de lote y área en `m²`, en la capa actual y con el estilo de texto actual. No se crean capas ni estilos. Las LINE paralelas se limitan a los tramos interiores; las ancladas van del vértice fijo al punto calculado sobre la frontera. Los contornos incluyen sus fronteras compartidas.

Si la fuente es abierta, también se publica el **contorno cerrado de trabajo**, conservando la original con su bandera abierta y sus coordenadas. Se publica únicamente después de validar todas las parcelas; pertenece a la misma ejecución y se retira junto con los resultados al deshacer o ante un fallo.

Cada parcela debe ser **una sola pieza conectada**. Si una dirección genera fragmentos separados, se rechaza toda la operación; no se suman fragmentos para presentarlos como un lote. En anclado se admiten solamente cuerdas interiores que no cruzan, tocan ni se superponen a la frontera salvo en sus dos extremos. Se elige la primera solución válida en orden de frontera, avanzando de un acumulado al siguiente para evitar parcelas superpuestas. Si no se encuentra un abanico válido, se solicita otro vértice o el modo paralelo. La búsqueda no es exhaustiva: no reconsidera cortes anteriores si un acumulado posterior falla, por lo que puede rechazar un ancla aun cuando otra combinación fuera viable. Se valida toda la geometría antes de publicar resultados. Las etiquetas se ubican en el **centroide real**: si queda fuera de una parcela cóncava, se informa el número de lote y se mantiene esa posición matemática.

No se admiten arcos/bulges (se rechazan, **no se aproximan por cuerdas**), huecos, autointersecciones, contactos consigo misma, vértices consecutivos coincidentes, geometría inclinada, normal −Z, POLYLINE antigua ni entidades 3D. Una capa actual bloqueada también impide iniciar la operación.

Requiere AutoCAD Windows con ActiveX y operaciones REGION/Boolean. El DCL y las entidades de cálculo son temporales. ESC o un error restablecen `OSMODE`, `CMDECHO` y `DIMZIN` y eliminan únicamente lo creado por esa ejecución. Los resultados se agrupan en una marca de deshacer para retirarlos con un solo `UNDO`. Si AutoCAD impide borrar o restaurar algo, el comando imprime un aviso para revisar el dibujo y las variables.

#### Lista de verificación manual

Las pruebas manuales reportadas fueron positivas y la feature fue aceptada. La siguiente lista se conserva para futuras regresiones; sus casillas no representan resultados individuales confirmados.

Usar un **DWG de prueba**, guardar las variables originales y comprobar áreas mediante las propiedades de AutoCAD, no solamente leyendo las etiquetas. Después de cada rechazo o cancelación, comprobar fuente intacta, ausencia de resultados/REGION/temporales y restauración de variables.

- [ ] **Carga:** `APPLOAD` muestra `MCSUBDIV cargado. Escriba MCSUBDIV para iniciar.` y el comando abre el diálogo.
- [ ] **Ejemplo base:** rectángulo WCS `(0,0)-(25,0)-(25,20)-(0,20)`, cerrado con `C`: área `500 m²`. Guía vertical, área `200`, lado Este: corte `X=15`, lote 1 a la derecha `200 m²`, resto `300 m²`, dos contornos y dos etiquetas. Repetir con porcentaje `40`: mismo resultado dentro de `0.01 m²`.
- [ ] **Partes:** dos partes de `250 m²` con un corte; tres partes de `166.666666… m²` con dos posiciones de corte. Comprobar superficies reales y suma `500 m²`, sin huecos ni solapes.
- [ ] **Guía corta/larga:** repetir el ejemplo con puntos `(10,8)-(10,12)` y `(10,-10)-(10,30)`; mismo corte y ningún tramo LINE fuera del contorno. Repetir usando los vértices `(0,0)` y `(0,20)`.
- [ ] **Lados:** repetir área `200` al Oeste (corte `X=10`), Norte (guía horizontal, `Y=12`) y Sur (`Y=8`); probar las cuatro diagonales con guía diagonal. Lado paralelo a la guía muestra el aviso y mantiene el diálogo abierto.
- [ ] **Rotación:** guía horizontal, pivote `(0,0)`, ángulo `90`, área `200` al Este: corte vertical `X=15`. Repetir con ángulo negativo y otro pivote. Sin pivote o ángulo inválido no acepta.
- [ ] **Irregular:** contorno convexo `(0,0)-(30,0)-(20,20)-(0,20)` de `500 m²`, tres partes iguales: áreas equivalentes aunque los cortes paralelos no sean equidistantes.
- [ ] **Conectividad:** polígono U `(0,0)-(10,0)-(10,10)-(7,10)-(7,3)-(3,3)-(3,10)-(0,10)` de `72 m²`; guía horizontal, área `20` al Norte: debe rechazar fragmentos separados sin dejar geometría. Probar también una división conectada de un cóncavo.
- [ ] **Entorno:** trasladar el ejemplo a coordenadas UTM y elevación `100`; usar UCS rotado. Contornos, líneas y textos conservan el plano de la fuente y los lados WCS.
- [ ] **Entrada:** `1abc`, vacío, cero y negativo; partes `1`/`2.5`; porcentaje `0`/`100`; área `500`/mayor que total; dos puntos iguales; tolerancia/altura no positivas. Los avisos conservan los campos al reabrir por selección; no crean resultados.
- [ ] **Fuente abierta:** repetir el rectángulo de 500 m² sin `C`, tanto con cuatro vértices y nuevo tramo de cierre como con un quinto punto coincidente con el primero. Área 200 al Este en modo paralelo produce 200+300 y una copia cerrada adicional; la fuente conserva bandera abierta y coordenadas. Probar también en modo anclado y verificar que `UNDO` retira copia y resultados, no la fuente.
- [ ] **Cierre inválido:** abierta `(0,0)-(10,0)-(0,10)-(10,10)` produce un cierre que se cruza: rechazo sin copia ni resultados; fuente intacta. Bulge, normal −Z, inclinadas, cruces, contactos y duplicados consecutivos siguen rechazándose. Capa actual bloqueada: aviso sin temporales.
- [ ] **Ancla / área:** rectángulo 25×20, guía `(0,0)-(0,20)`, tipo anclado, primer punto fijo, área `200` al Este: cuerda `(0,0)-(25,16)`, áreas 200+300. Repetir porcentaje `40`. Con segundo punto fijo: cuerda `(0,20)-(25,4)`, mismas áreas. Comprobar extremos exactos y ausencia de huecos/solapes.
- [ ] **Abanico:** mismo rectángulo, primer punto fijo, tres partes: cuerdas hacia `(25,13.333333…)` y `(16.666666…,20)`, tres áreas `166.666666…`, misma ancla y ángulos distintos. Dos partes: una cuerda hacia `(25,20)` y dos áreas 250.
- [ ] **Ancla inválida / regresión:** guía `(10,8)-(10,12)` sigue válida en paralelo (corte X=15 para 200 al Este) pero no en anclado, porque ningún extremo es un vértice. Alternar tipos, cambiar extremo fijo y reabrir por selección conservando valores. La rotación manual anterior mantiene su comportamiento al volver al paralelo.
- [ ] **Cóncavo anclado:** probar distintas anclas en L/U, incluidos cortes que salen/reentran, solapan un borde o tocan un vértice intermedio. Cada cuerda publicada permanece dentro; en rechazo no queda geometría parcial y el área total se conserva en las operaciones aceptadas.
- [ ] **Cancelación:** ESC en selección, diálogo, primer/segundo punto, vértices, pivote y procesamiento. Comprobar `OSMODE`, `CMDECHO`, `DIMZIN`, fuente y temporales. Tras una ejecución correcta, un `UNDO` retira todos sus resultados y conserva la fuente.
- [ ] **Centroide:** comprobar la ubicación con propiedades de región en copia de prueba; en un cóncavo cuyo centroide quede fuera, aparece el aviso y no se desplaza silenciosamente la etiqueta.

### MCTRANSFORM — Escala de contorno por superficie

```
MCTRANSFORM
```

Crea un **contorno cerrado verde (ACI 3)** y lo reduce o amplía hasta el área indicada, conservando la forma y la posición del **centroide real del área**. La entidad original permanece intacta. El script es independiente: no requiere cargar otros comandos.

#### Uso

1. Cargar `lisp/MC-TRANSFORM.lsp` con `APPLOAD` y ejecutar `MCTRANSFORM`.
2. Seleccionar una **LWPOLYLINE simple, horizontal y de tramos rectos**, cerrada o abierta. En abiertas se une último y primer vértice **solo en la copia**. Si el extremo final coincide con el primero dentro de la tolerancia geométrica, se retira ese extremo duplicado únicamente de la copia. El cierre debe formar un contorno válido.
3. El comando crea la copia verde y muestra su área inicial. Introducir un **área objetivo positiva** por línea de comandos; Enter o ESC cancela y elimina la copia de esa ejecución.
4. Se aplica el factor `sqrt(área objetivo / área original)` alrededor del centroide. El resultado queda en la **capa actual**, sin crear capas ni estilos. Un solo `UNDO` retira el resultado y conserva la fuente.

El área se expresa en **unidades de dibujo al cuadrado (`u2`)**: si el dibujo está en metros, corresponde a m². No se convierte el CRS ni se convierten unidades. La elevación se conserva; los vértices se convierten de OCS a WCS y los cálculos usan un origen local cercano a la fuente para reducir pérdida de precisión en coordenadas UTM. El UCS no determina el centro de escala.

#### Precisión y restricciones

- La escala es uniforme y positiva: no rota, refleja ni deforma. Un área objetivo igual a la inicial produce un contorno coincidente; el original sigue intacto.
- El centroide es el de la superficie, **no** el promedio de vértices ni el centro de la caja. Puede quedar fuera de un polígono cóncavo; se mantiene su posición matemática.
- Solo se acepta normal `+Z`. No se admiten arcos/bulges, POLYLINE antigua, entidades 3D, autointersecciones, contactos consigo misma, aristas superpuestas, vértices consecutivos coincidentes ni área nula. No se aproximan arcos por cuerdas. Una capa actual bloqueada impide crear el contorno.
- La copia es un contorno sin ancho ni grosor: no replica las propiedades, etiquetas ni asociaciones de la fuente; usa la capa actual y color verde explícito, no `ByLayer`.
- La tolerancia geométrica interna es `max(1e-8, extensión XY × 1e-10)` en unidades de dibujo. Después de escribir la geometría se verifican nuevamente su validez, el área (error relativo máximo `1e-8`) y el centroide (tolerancia geométrica máxima entre fuente y resultado). Una escala extrema que produzca geometría degenerada o pérdida de precisión se rechaza y se retira la copia.
- Requiere AutoCAD Windows con ActiveX. ESC o error elimina únicamente la copia creada por esa ejecución y restaura `OSMODE`, `CMDECHO` y `DIMZIN`. Si AutoCAD impide la limpieza o restauración, se imprime un aviso para revisar el dibujo y las variables.

#### Verificación manual

**Feature aceptada tras pruebas manuales positivas en AutoCAD.** El usuario confirmó polígonos cerrados con `C` y cerrados manualmente, reducción y ampliación de áreas, y cancelación con ESC que restaura las variables y elimina el contorno, dejando el dibujo limpio. Posteriormente confirmó «Todo OK» y dio por terminada la feature.

La siguiente lista se conserva para futuras regresiones; sus casillas no representan resultados individuales confirmados. Usar un DWG de prueba y comprobar las superficies mediante las propiedades de AutoCAD. Para verificar el centroide, crear una REGION de una copia de prueba y consultar sus propiedades de masa; no usar el centro de la caja envolvente.

- [ ] **Carga:** `APPLOAD` muestra `MCTRANSFORM cargado. Escriba MCTRANSFORM para iniciar.`; el comando solicita la fuente sin cargar otros scripts.
- [ ] **Reducción:** cuadrado `(0,0)-(10,0)-(10,10)-(0,10)`, cerrado con `C`, área 100; objetivo 25 → factor 0.5 y límites `(2.5,2.5)-(7.5,7.5)`. Centroide `(5,5)` y fuente intacta.
- [ ] **Ampliación e igualdad:** mismo cuadrado, objetivo 400 → factor 2 y límites `(-5,-5)-(15,15)`; objetivo 100 → copia coincidente. En ambos casos, una copia cerrada verde en la capa actual y ningún cambio en la fuente.
- [ ] **Centroide irregular:** trapecio `(0,0)-(10,0)-(6,4)-(0,4)`, área 32 y centroide `(4.083333…,1.833333…)`; objetivo 128 → factor 2, mismo centroide y todas las longitudes al doble. Repetir invirtiendo el recorrido y con un cóncavo simple.
- [ ] **Abiertas:** repetir el cuadrado sin `C`, con cuatro vértices y con un quinto coincidente con el primero. Resultado cerrado de área 25, sin extremo duplicado; fuente conserva coordenadas y bandera abierta. No aparece una copia adicional sin transformar.
- [ ] **Rechazos:** abierta cuyo cierre cruza el contorno, bulge, entidad distinta de LWPOLYLINE, normal −Z/inclinada, cruces, contactos, superposiciones, duplicados consecutivos, área nula y capa actual bloqueada. Aviso sin copia residual ni cambios en fuente/variables.
- [ ] **Entrada:** cero, negativo y texto como `1abc` no se aceptan como área; el prompt sigue activo. Introducir luego un área válida y comprobar que no hay copias adicionales. Enter o ESC retira la copia y conserva la fuente.
- [ ] **Entorno y precisión:** fuente en UTM, elevación 100 y UCS rotado; misma área objetivo y centroide WCS, con elevación preservada. Probar escala extrema y comprobar retirada del resultado si no supera las verificaciones.
- [ ] **Cancelación y deshacer:** ESC en selección y entrada de área; revisar ausencia de copias parciales y restauración de `OSMODE`, `CMDECHO`, `DIMZIN`. Tras una ejecución correcta, un `UNDO` retira solo su resultado. Repetir ejecuciones para descartar estado residual.

### MCIMPORT — Importación de puntos TXT / CSV

Cargar `lisp/MC-IMPORT.lsp` con `APPLOAD` y ejecutar `MCIMPORT`. El diálogo permite buscar el archivo, elegir el orden de sus columnas, un símbolo con previsualización y las etiquetas opcionales. Al aceptar se importan los puntos y se ajusta la vista a la salida, incluidas las etiquetas.

**Símbolos independientes.** Se reproducen las 20 combinaciones de `DDPTYPE`: punto, sin marca central, cruz `+`, cruz `X` o trazo vertical, solos o rodeados por círculo, cuadrado o ambos. Se crean entidades `LINE`, `CIRCLE` y un pequeño `SOLID` para la marca puntual; **no son entidades POINT ni objetos COGO de Civil 3D**. El comando no abre `DDPTYPE` ni modifica `PDMODE`/`PDSIZE`, y no afecta la apariencia de puntos existentes. El tipo sin ninguna marca requiere etiquetas que produzcan salida.

Un **único valor positivo** fija la altura de los textos y el radio del círculo o semilado del cuadrado, en unidades del dibujo. Los textos son entidades **TEXT separadas y editables**, a la derecha del símbolo; si se muestran ambos, el número queda encima de la descripción. Se conservan X/Y/Z en WCS, independientemente del UCS, sin transformación geodésica ni conversión de unidades. Símbolos y textos usan la capa actual; los textos usan el estilo actual con altura explícita, sin modificar su definición. No se crean capas, bloques ni estilos.

**Agrupación por punto.** Cada punto importado con entidades visibles forma automáticamente un **GROUP nativo seleccionable** con todos los componentes de su símbolo y las etiquetas activadas. Son grupos separados incluso si dos puntos coinciden o tienen el mismo identificador P; no se agrupa el archivo completo ni se convierten los textos en bloques. Los nombres `MCIMPORT_<handle>` usan un identificador de entidad, con sufijo si ya existe ese nombre, sin modificar grupos anteriores. Un registro sin símbolo ni etiquetas efectivas no crea un grupo vacío.

La selectabilidad se consulta y, si hace falta, se activa mediante el **campo DXF `71 = 1` de GROUP**; no se llama a `VLA-PUT-SELECTABLE`, porque `AcadGroup` no expone esa propiedad en ActiveX. Referencias: [GROUP (DXF)](https://help.autodesk.com/cloudhelp/2018/ENU/AutoCAD-DXF/files/GUID-5F1372C4-37C8-4056-9303-EE1715F58E67.htm) y [Group Object (ActiveX)](https://help.autodesk.com/cloudhelp/2026/ENU/AutoCAD-ActiveX-Reference/files/GUID-1CA2C9D1-F8F7-4C11-B361-2998C4869119.htm).

Para seleccionar o mover un punto completo haciendo clic en uno de sus elementos, usar **`PICKSTYLE = 1` o `3`**. El comando no cambia esa variable; si la selección de grupos está desactivada, informa cómo activarla al terminar. `Ctrl+H` permite alternar la selección de grupos para editar elementos por separado; los textos siguen siendo TEXT editables. La agrupación se aplica a **nuevas importaciones**, no modifica puntos ya importados.

#### Archivo y formatos

- Extensión `.txt` o `.csv`, **separador coma** y un punto por línea. No se admiten archivos separados por punto y coma o tabulaciones.
- `E = X`, `N = Y`, `Z = altura`, `P = número/identificador`, `D = descripción`.
- Formatos de la propuesta: `ENZ`, `NEZ`, `PENZ`, `PNEZ`, `PENZD`, **`PNEZD` (inicial)**, `PEN`, `PNE`.
- Formatos adicionales: `EN`, `NE`, `END`, `NED`, `ENZD`, `NEZD`, `PEND`, `PNED`.
- Si falta `Z`, se usa `0`; si falta `P`, se numera desde `1` en orden de archivo; si falta `D` o está vacía, no se crea ese texto. Los identificadores P se conservan como texto, incluidos ceros iniciales; no se exige que sean únicos.
- Coordenadas decimales con punto, signo opcional y sin unidades ni exponentes. Se rechazan coordenadas vacías, `1abc`, columnas sobrantes/faltantes y comillas sin cerrar. Las líneas vacías se ignoran.
- Se admite una cabecera opcional en la primera línea no vacía, **exactamente con las letras del formato seleccionado** (sin distinguir mayúsculas). Ejemplo: `P,N,E,Z,D` para `PNEZD`.
- Descripciones con comas deben ir entre comillas; `""` representa una comilla literal dentro de un campo entrecomillado. No se admiten campos multilínea. Se recortan espacios exteriores de cada campo. P y D admiten hasta 255 caracteres.
- La codificación debe ser legible por la versión/configuración de AutoCAD; en versiones antiguas usar la codificación ANSI local para tildes. Se retira el BOM UTF-8 si AutoCAD lo entrega al leer la primera línea.

Ejemplo `PNEZD` de la propuesta:

```csv
1,2151544.225,343872.683,346.931,alambrada
```

Produce un punto en **WCS `(343872.683, 2151544.225, 346.931)`**, número `1` y descripción `alambrada`. Ejemplo de descripción con coma y comillas:

```csv
2,2151550.000,343880.000,347.000,"poste, lado ""norte"""
```

#### Errores y deshacer

Se valida **todo el archivo antes de crear entidades**. Un error indica la línea física y no importa puntos parciales. Una capa actual bloqueada impide la creación. Cancelar o fallar durante la creación elimina solamente los grupos y entidades creados en esa ejecución; se cierran archivos y se retira el DCL temporal, restaurando `OSMODE` y `CMDECHO`. Una importación correcta queda en una sola marca de deshacer: un `UNDO` retira sus símbolos, textos y definiciones de grupo. El resumen informa las cantidades de puntos, etiquetas y grupos creados. Si solo falla el ajuste de vista, se conservan los resultados y se informa el aviso. Si AutoCAD impide limpiar/restaurar recursos se informa para revisar el dibujo.

#### Verificación manual

**Comando y agrupación por punto aceptados tras pruebas manuales positivas en AutoCAD.** El usuario confirmó la versión inicial tras probar diferentes opciones («todo OK»). La primera prueba de agrupación falló con `MCIMPORT: no function definition: VLA-PUT-SELECTABLE`; se sustituyó esa llamada por el campo DXF 71 y el usuario confirmó después: «Pruebas manuales positivas, todo OK». Estas confirmaciones son generales, no acreditan individualmente cada casilla de la lista, que se conserva para futuras regresiones. No hay runner automatizado; la revisión de código no sustituye la prueba real de DCL, ActiveX y comportamiento del dibujo. Para futuras pruebas, usar un DWG de prueba y revisar coordenadas/entidades mediante Propiedades o `LIST`, no solamente las etiquetas.

- [ ] Cargar con `APPLOAD`: mensaje `MCIMPORT cargado. Escriba MCIMPORT para iniciar.`; abrir el diálogo, buscar TXT y CSV, cancelar el buscador y comprobar que conserva el archivo y los campos.
- [ ] Importar el ejemplo `PNEZD`: comprobar X `343872.683`, Y `2151544.225`, Z `346.931`, número `1`, descripción `alambrada` y zoom a la salida. Editar cada TEXT por separado.
- [ ] Probar los ocho formatos de la propuesta y los ocho adicionales con el mismo punto; comprobar E/N, Z=0 cuando falta, numeración desde 1 cuando falta P, y ausencia de descripción cuando falta D.
- [ ] Probar cabecera exacta, líneas vacías, BOM, P `001`, coordenadas cero/negativas, D vacía, coma y comillas escapadas en D; tildes con la codificación de AutoCAD utilizada.
- [ ] Cambiar los 20 estilos y comprobar previsualización y geometría, incluida marca invisible con etiquetas. Registrar `PDMODE`/`PDSIZE` y puntos preexistentes antes/después: deben permanecer intactos.
- [ ] Tamaño `2`: altura TEXT `2`, radio CIRCLE `2` y semilado del cuadrado `2`; número encima de descripción. Probar las cuatro combinaciones de etiquetas, distintos estilos de texto y UCS rotado, conservando XYZ y orientación WCS.
- [ ] Archivo con una fila válida seguida de `1abc`, coordenada vacía, columnas de más/de menos o comillas mal cerradas: aviso con línea correcta, ninguna entidad nueva, ninguna modificación de datos existentes ni de variables. Repetir archivo vacío, solo cabecera y ruta inexistente.
- [ ] Tamaño vacío, `1abc`, cero y negativo: diálogo abierto con aviso. Archivo con extensión no admitida, capa bloqueada y estilo invisible sin salida: rechazo limpio.
- [ ] ESC en diálogo, buscador, lectura y creación: sin salida parcial, archivos abiertos ni DCL residual; `OSMODE`, `CMDECHO`, `PDMODE`, `PDSIZE` y geometría preexistente intactos.
- [ ] **Corrección de selectabilidad:** recargar el script con `APPLOAD` e importar el ejemplo `PNEZD` con las opciones iniciales. No debe aparecer `MCIMPORT: no function definition: VLA-PUT-SELECTABLE`; el resumen debe indicar un punto, dos TEXT y un grupo. Con `PICKSTYLE=1`, seleccionar símbolo y ambos textos juntos. Si falla la creación, verificar que no queden grupos ni entidades de esa ejecución y que las variables y grupos preexistentes permanezcan intactos.
- [ ] **Grupos / puntos próximos:** importar dos filas `PNEZD`, `1,100,200,10,poste` y `1,100.1,200.1,10,alambrada`, con círculo y cruz y ambas etiquetas. Con `PICKSTYLE=1` o `3`, hacer clic en cada punto: seleccionar solo su símbolo completo y sus dos TEXT, sin incluir el vecino pese a compartir P. Repetir con coordenadas coincidentes; consultar `GROUP` para comprobar dos grupos distintos. Guardar/reabrir el DWG y comprobar que los grupos persisten.
- [ ] **Regresión de opciones:** probar las 20 combinaciones de símbolos y las cuatro combinaciones de etiquetas: todos los elementos realmente creados de cada punto pertenecen a su grupo; coordenadas y apariencia no cambian. Probar símbolo invisible con un único TEXT y con descripción vacía: sin grupos vacíos. El resumen muestra el número real de grupos.
- [ ] **Selección / edición:** con `PICKSTYLE=0` o `2`, el comando conserva ese valor y muestra el aviso; cambiar manualmente a `1` o `3` permite selección conjunta. Alternar con `Ctrl+H` y editar solo un TEXT. Mover un grupo completo: símbolo y sus etiquetas se desplazan juntos sin mover puntos vecinos.
- [ ] **Rollback / deshacer:** conservar grupos preexistentes y cancelar con ESC durante una importación de volumen suficiente: desaparecen solamente grupos y entidades de esa ejecución. Importación correcta seguida de un solo `UNDO`: desaparecen sus símbolos, textos y definiciones de grupo; los grupos anteriores quedan intactos. Repetir ejecuciones, también con P repetidos, un único punto y un archivo de volumen representativo.

### MCFIX — Normalización segura de polilíneas

Convierte **POLYLINE antiguas 2D y POLYLINE 3D horizontales** a **LWPOLYLINE** sin depender de `PL32`, `CONVERT` ni otros scripts. No aplana alturas diferentes, no cierra contornos abiertos y no elimina vértices, duplicados ni autointersecciones. Las LWPOLYLINE existentes no se modifican.

#### Uso

1. Cargar `lisp/MC-FIX.lsp` con `APPLOAD` y ejecutar `MCFIX`.
2. Elegir **Seleccion** (por defecto) para seleccionar polilíneas, **Todo** para recorrer únicamente el espacio actual, o **Ayuda** para consultar los límites. En un layout con una ventana de modelo activa, el espacio actual es modelo; en papel, solo ese layout. No se recorren otros layouts ni definiciones de bloques o referencias externas.
3. **Configurar puntos** está desactivado por defecto. Elegir **Si** aplica deliberadamente `PDMODE=32` y `PDSIZE=1` al dibujo completo; afecta todos los POINT existentes, no solo la selección. Usar `REGEN` para actualizar su representación. Elegir **No** conserva ambas variables.
4. Leer el resumen de **convertidas / ya compatibles / omitidas / fallidas**. Cada omisión o fallo identifica el handle de la fuente y su motivo. Un fallo recuperable conserva esa fuente y permite continuar con las demás.

Las 2D conservan coordenadas **OCS**, normal, elevación, arcos (bulges), anchos inicial/final por vértice, cierre y generación continua del tipo de línea. Las 3D se admiten únicamente si **todos sus vértices tienen exactamente la misma Z WCS**; se conserva esa cota, no se fuerza Z=0 ni se usa una tolerancia para aplanar pequeñas diferencias. El UCS actual no interviene. Se conservan capa, color ACI/TrueColor, tipo y escala de línea, grosor de línea, espesor, visibilidad, transparencia y propietario/espacio; no se crean capas ni estilos. Las entidades convertidas tienen **handles nuevos**.

Se omiten capas bloqueadas, mallas/polyface, ajustes curve-fit/spline, secuencias inválidas, menos de dos vértices y 3D con arcos, anchos o espesor no compatibles. Por seguridad también se omiten fuentes o subentidades con XDATA, diccionarios o referencias de reactor/grupo: no se intenta transferir asociaciones a handles nuevos. No se ejecuta `PURGE` ni `OVERKILL`, no se cambia `PLINETYPE` ni se realiza transformación geodésica o conversión de unidades.

#### Errores y deshacer

Se examina todo el lote antes de modificar geometría. Cada reemplazo se verifica contra la fuente (vértices, arcos, anchos, elevación, normal, propiedades y propietario) **antes de retirar el original**. La retirada usa `entdel`, que permite recuperar la POLYLINE original completa durante la misma sesión de dibujo. ESC o un error no recuperable restaura los originales ya retirados y elimina los reemplazos de esa ejecución. Si AutoCAD impide alguna restauración, se imprime un aviso: revisar el dibujo y no asumir que quedó limpio.

Se restauran `CMDECHO` y `OSMODE`. Si se cancela o falla el lote, también se revierten los cambios visuales opcionales; tras el éxito se conservan porque fueron solicitados expresamente. Una ejecución con cambios se agrupa en una marca de deshacer: un solo `UNDO` debe recuperar las fuentes y retirar los reemplazos, sin afectar entidades anteriores. No hay comandos encolados ni conjuntos de selección COM compartidos.

#### Verificación manual

**Comando aceptado tras pruebas manuales positivas en AutoCAD.** El usuario confirmó: «las pruebas manuales fueron exitosas». La confirmación es general y no acredita individualmente cada casilla; la siguiente lista se conserva para futuras regresiones. No hay runner automatizado en este repositorio. Para repetir las pruebas, usar un DWG de prueba, guardar una copia y consultar Propiedades/`LIST` antes y después, incluyendo conteos y handles; no comprobar solamente la apariencia.

- [ ] **Carga y ayuda:** `APPLOAD` muestra `MCFIX cargado. Escriba MCFIX para iniciar.`. `Ayuda` explica opciones y vuelve al prompt. Enter en alcance usa selección manual; Enter sin selección no modifica geometría ni variables.
- [ ] **2D abierta/cerrada:** POLYLINE antigua `(0,0)-(10,0)-(10,10)-(0,10)` a cota 100, con y sin `C`: una sola LWPOLYLINE con iguales coordenadas, elevación y bandera de cierre; original retirada. Repetir con extremo final duplicado: no eliminarlo ni cerrar implícitamente la abierta.
- [ ] **Arcos y anchos:** POLYLINE 2D con bulge `1` y `-1`, ancho constante y anchos variables por segmento. Comparar bulges, anchos y longitud antes/después; no sustituir arcos por cuerdas. Repetir con espesor, normal inclinada y normal -Z, conservando el plano y la orientación.
- [ ] **3D horizontal:** vértices WCS `(343872,2151544,100)-(343882,2151544,100)-(343882,2151554,100)`, abiertos y cerrados: conservar todos los XYZ y el cierre. Repetir con Z=0 y Z negativa.
- [ ] **3D no horizontal:** mismo ejemplo con Z `100,100,101`, y después con `100,100,100.000000001`: omisión con motivo, original y conteos intactos, sin reemplazo. No proyectar a Z=0.
- [ ] **Apariencia/entorno:** distintas capas, ACI, TrueColor, ByLayer/ByBlock, tipos/escalas, grosores, transparencia y materiales/estilos de trazado disponibles. Cambiar antes `CLAYER`, `CECOLOR`, `CELTYPE`, `CELWEIGHT` y UCS: la salida conserva las propiedades fuente, no las actuales.
- [ ] **Selección/espacios:** procesar solo una parte del dibujo; `Todo` en modelo, en papel y dentro de una ventana de layout. Ninguna modificación de otros espacios, entidades dentro de bloques o referencias externas. LWPOLYLINE existentes intactas y contadas como compatibles.
- [ ] **Omisiones:** incluir capa bloqueada, malla/polyface, curve-fit/spline, entidad agrupada y fuente con XDATA/diccionario/reactor. Avisos con handle y motivo; conservar fuentes, metadatos, grupos y conteos. Un lote mixto procesa las compatibles sin modificar las omitidas.
- [ ] **Puntos:** anotar `PDMODE`/`PDSIZE` y crear POINT preexistentes. Por defecto/No permanecen intactos; Si aplica 32/1 a todo el dibujo. Ninguna selección no aplica la opción visual. Revisar restauración en cancelación/fallo y deshacer tras el éxito.
- [ ] **Cancelación/recuperación:** ESC en alcance, selección, opción visual y durante un lote suficientemente grande. Conservar todas las POLYLINE originales con sus subentidades y no dejar LWPOLYLINE temporales; restaurar variables. En un fallo recuperable del reemplazo, esa fuente queda intacta y se cuenta como fallida, nunca como convertida.
- [ ] **Deshacer/repetición:** tras el éxito, un solo `UNDO` recupera originales y retira reemplazos del lote; entidades anteriores intactas. Repetir `MCFIX` sobre la salida: cero nuevas conversiones, solo compatibles. Comparar conteos del resumen y probar un lote representativo sin estado residual.

### MCCOLIND — Simbología y etiquetas de colindancias

```
MCCOLIND
```

Dibuja uno de **siete estilos de lindero** sobre un **tramo parcial** de una `LINE` o `LWPOLYLINE` de tramos rectos y añade, por cada recorrido, un **par de etiquetas**: el nombre del estilo en el interior y el nombre de la colindancia en el exterior. La fuente **nunca se modifica**. El comando es independiente: no requiere cargar otros scripts.

#### Uso

1. Cargar `lisp/MC-COLIND.lsp` con `APPLOAD` y ejecutar `MCCOLIND`.
2. Seleccionar una **LINE o LWPOLYLINE de tramos rectos**, horizontal (normal `+Z`) y con cota constante, en el espacio activo.
3. En fuentes abiertas, indicar con un clic el **lado considerado interior**.
4. En el diálogo, mantener **Automático según la geometría seleccionada** (predeterminado), elegir el estilo y escribir el **nombre de la colindancia exterior**. Para introducir medidas de papel y escala `1:N`, desactivar Automático. «Aplicar a dos puntos...» suspende el diálogo para tomar dos clics sobre el borde.
5. Previsualizar el recorrido: `ENTER` o `ESPACIO` aplica, `I` invierte el sentido (solo en fuentes cerradas) y `ESC` cancela toda la ejecución.
6. Repetir el paso 4 tantas veces como tramos se quieran estilizar. «Deshacer última aplicación» retira solo la última y deja libre su tramo; si se deshizo todo, «Aceptar» cierra igualmente e informa **0 aplicaciones retenidas**. «Aceptar» conserva lo dibujado; «Cancelar» o `ESC` descartan toda la ejecución.

Un solo `UNDO` retira una ejecución aceptada y conserva la fuente.

#### Controles y valores iniciales

| Control | Valor inicial | Significado |
|---|---|---|
| Automático según la geometría seleccionada | Activado | Tamaños proporcionales a la fuente completa; no al tramo elegido, zoom ni extensión global del DWG |
| Escala `1:N` (manual) | `500` | El dibujo se interpreta en **metros**: `medida_en_dibujo = mm × N / 1000` |
| Altura de texto (mm, manual) | `2` | Altura de las dos etiquetas en modo manual |
| Repetición del patrón (mm, manual) | `4` | Paso entre marcas, excepto malla, que usa X contiguas |
| Ancho total de franja (mm) | `1` | Separación entre los dos bordes de la franja |
| Separación libre texto/patrón (mm) | `1` | Holgura mínima entre cada etiqueta y el patrón |
| Estilo | Alambrada | Uno de los siete patrones |
| Colindancia exterior | `Colindancia` | Texto de la etiqueta exterior |

**Modo automático.** Se calcula `D = max(ancho X, alto Y)` de la fuente seleccionada en WCS. Los tamaños son:

| Medida | Proporción | Ejemplo con D = 1000 m |
|---|---|---|
| Altura interior | `D / 100` | 10 m |
| Altura exterior | `1,5 × altura interior` | 15 m |
| Ancho total de franja | `1 × altura interior` | 10 m |
| Separación libre interior | `0,5 × altura interior` | 5 m |
| Separación libre exterior | `1,5 × altura interior` | 15 m |
| Repetición normal (puntos, paredes y zigzag) | `2 × altura interior` | 20 m |
| Repetición de alambrada | `3 × altura interior` | 30 m |

El diálogo muestra las medidas resultantes en metros; «Paso normal» es la referencia común, no el paso específico de alambrada o malla. Los símbolos (cruces y puntos) y el ancho de las franjas se ampliaron **al doble** respecto del perfil automático inicial, sin cambiar alturas de texto, holguras libres ni paso normal. Las etiquetas pueden desplazarse para respetar la franja mayor. Una LINE también usa su mayor extensión XY. La holgura se mide desde el borde del patrón hasta la **caja real** del texto, no hasta su inserción. No se garantiza que las etiquetas quepan en todo contorno estrecho: se conserva la ubicación manual validada.

**Modo manual.** Al desactivar Automático se habilitan la escala y las cuatro medidas en **milímetros de papel**. Conserva las alturas iguales, la separación común y el tratamiento de altura fija del estilo de la versión anterior; la malla conserva 75° y su paso contiguo en manual. El ajuste de menor densidad de alambrada/malla se aplica **solo en automático**. Se validan con un **parser positivo estricto**: se rechazan cero, negativos, comas, exponentes y textos como `1abc`. Se conservan el modo y **los textos crudos**, incluso inválidos, al alternar modos o reabrir el diálogo; los campos manuales deshabilitados no bloquean el automático.

**Ejemplo manual a 1:500, en metros:** texto `2 mm` → **1 m** de altura; repetición `4 mm` → una marca cada **2 m**; franja `1 mm` → **0,5 m** de ancho total; separación `1 mm` → **0,5 m**. Son parámetros iniciales propuestos, no dimensiones normativas.

#### Siete estilos

| Estilo | Trazado |
|---|---|
| Alambrada | Marcas `X` centradas sobre el lindero, sin franja |
| Lindero | Puntos centrados sobre el lindero, sin franja |
| Pared propia | Franja hacia el **interior** con diagonales |
| Pared medianera | Franja **centrada** en el lindero con diagonales |
| Pared colindante | Franja hacia el **exterior** con diagonales |
| Malla ciclónica | Franja centrada con X a 75°: separadas en automático, contiguas en manual |
| Lindero de árboles vivos | Franja centrada con zigzag continuo |

En automático, **alambrada y malla** usan un paso **1,5 veces** el anterior: aproximadamente **un tercio menos de cruces**, sin cambiar el tamaño de cada X, los textos, las holguras ni los otros estilos. La alambrada pasa de 20 a **30 m** entre centros en el ejemplo D=1000.

En las **paredes**, las diagonales conservan **30° con la perpendicular** al lindero (60° con el lindero). En la **malla**, forman **75° con el lindero**: la proyección longitudinal de cada X es `franja × cos(75°) / sin(75°)`. En **automático**, el paso entre centros es **1,5 veces esa proyección**, dejando pequeños huecos; en **manual** el paso sigue siendo la proyección y las X comparten extremos. Con franja de 10 m, la proyección es aproximadamente **2,679 m**, el paso automático **4,019 m** y el hueco **1,340 m**. Se calculan con `sin`/`cos`, porque AutoLISP no tiene `TAN`. El tamaño de cruces y puntos se deriva de la franja (`franja/2`). En **Pared propia** y **Pared colindante** el patrón dibuja solo el borde lejano: el borde cercano es el propio lindero de la fuente, que se conserva intacto; por eso esos dos estilos **dependen de que la fuente siga visible**.

Los patrones se calculan **por segmento**, con tamaño y paso constantes, y se **recortan en los extremos del tramo** para no prolongarse en las esquinas: las marcas que no caben completas se omiten. En el zigzag, la pierna final incompleta se **interpola** sobre la pierna completa (no cruza toda la franja) y el paso fijo se conserva. Los resultados son **estáticos**: editar después la fuente **no** actualiza las colindancias (no hay asociatividad).

#### Etiquetas

Cada recorrido recibe **un par**: el **nombre del estilo** en el interior y el **nombre de la colindancia** en el exterior, cerca de la **mitad de la longitud recorrida** y con rotación legible (nunca boca abajo). En automático, la exterior mide **1,5 veces** la interior y tiene **tres veces** su separación libre. Cada caja se mide con **`textbox`** a la altura real de su etiqueta y usando el estilo de texto actual. El `TEXT` recibe **altura explícita después de asignar el estilo**, además del mismo ancho y oblicuidad y **banderas de generación 0** (texto normal, sin espejo ni giro); si AutoCAD no expone alguna de esas últimas propiedades, se informa. La altura fija del estilo **no anula el automático** y no se modifica la definición global del estilo. En manual se conserva la altura fija y su aviso.

La **caja orientada completa** se valida en los **dos sentidos**: cada uno de sus cuatro lados contra cada tramo de referencia (no solo sus esquinas), de modo que una arista o un vértice de la fuente no puede quedar cerca de la mitad de un lado largo de la caja. Cruzar, tocar o quedar a menos de la holgura exigida invalida la posición. En contornos **cóncavos** se exige además que la caja quede completa dentro (o completa fuera) del polígono y que, en el exterior, no **contenga** ningún vértice del contorno: una caja que envuelve la fuente no es una posición exterior válida. No se usa una comprobación por centroide. Las dos etiquetas del par tampoco pueden solaparse entre sí. La misma comprobación se aplica a la ubicación automática y a la manual.

Cuando la **búsqueda acotada** (desplazamientos limitados junto a la mitad del recorrido) no encuentra posición válida, el comando pide el **centro de la etiqueta con un clic** y vuelve a validar; si el punto no sirve, avisa y vuelve a pedirlo. `ESC` cancela la ejecución. Las etiquetas **nunca se omiten en silencio ni se dibujan del lado equivocado**: si ninguna posición válida existe (por ejemplo, en una franja más estrecha que la holgura exigida), el comando lo indica y **descarta la ejecución completa**, como `ESC`, en lugar de dibujar mal la etiqueta.

#### Restricciones

- Solo **`LINE`** y **`LWPOLYLINE`** de tramos rectos, con normal `+Z` y cota constante. Se rechazan arcos (`bulge`), POLYLINE antigua, geometría 3D o inclinada y otros tipos de entidad. Los arcos **no se aproximan por cuerdas**.
- Se rechazan fuentes con **aristas nulas**, vértices consecutivos coincidentes, **retrocesos** (aristas superpuestas), **autointersecciones o contactos** y, en contornos cerrados, **superficie nula**.
- **Cierre geométrico:** si el extremo final coincide con el primero dentro de la tolerancia, ese extremo duplicado se retira **solo de la copia de trabajo** y la fuente se trata como cerrada aunque su bandera diga lo contrario. La entidad original conserva sus coordenadas y su bandera: **no se cierra físicamente** ni se reordena.
- La fuente debe estar en el **espacio de edición** real: modelo (con `TILEMODE` activo o dentro de una **ventana gráfica flotante**, `CVPORT > 1`) o el espacio papel del layout activo. El resultado se crea en el espacio de la fuente, en la capa actual (`CLAYER`) y con el estilo de texto actual (`TEXTSTYLE`), sin crear capas, estilos, bloques ni recursos globales, sin archivos `.lin` y sin reactores. Una capa actual bloqueada impide crear.
- **Fuentes abiertas:** el interior es el lado indicado con el clic. **Fuentes cerradas:** el interior se deduce de la orientación del contorno (antihorario u horario). Al **invertir** el recorrido se conservan los lados interior y exterior.
- Dos clics que se proyectan al **mismo punto** se rechazan y no crean nada.
- Dentro de una misma ejecución se **evita repetir un tramo ya cubierto**: si el recorrido elegido se superpone con una aplicación anterior, se avisa y no se crea nada. El registro de solapes es **de sesión**: **no hay memoria entre ejecuciones** distintas del comando. Sirve para no duplicar trabajo en la misma pasada, no para editar lo ya dibujado.
- Los clics se **proyectan** al punto más cercano del borde. El cálculo usa coordenadas locales cercanas a la fuente para no perder precisión en UTM, convierte de OCS a WCS la fuente y de UCS a WCS los clics, y conserva la cota de la fuente.
- **Límites de seguridad de dibujo:** una aplicación puede crear como máximo **20 000 entidades**, y un tramo, requerir como máximo **20 000 marcas** o vértices de zigzag. Si se supera el límite, se avisa y se descarta la ejecución en lugar de bloquear AutoCAD.
- Requiere AutoCAD 64-bit con ActiveX. El dibujo se interpreta en **metros**; en un dibujo con otras unidades los valores convertidos no serán los esperados.

#### Cancelación y deshacer

`ESC` en cualquier etapa, o un error, **descarta toda la ejecución**: se borran únicamente las entidades creadas por ese comando (el lote en curso y las aplicaciones ya registradas), se retira el DCL temporal y se restauran `OSMODE`, `CMDECHO` y `DIMZIN`. La fuente **no se borra ni se modifica**: las únicas entidades retiradas son las creadas por el propio comando; antes de borrar, cada entidad se compara por identidad con la fuente, de modo que ninguna ruta de limpieza puede alcanzarla. «Cancelar» en el diálogo hace lo mismo de forma ordenada.

El borrado es de **un solo intento y sin reintentos**. Si AutoCAD no retira alguna entidad, el comando lo **informa con el número exacto** y **no da por descartado lo que sigue en el dibujo**: conserva el registro de esas entidades (y su tramo sigue ocupado) en lugar de simular un éxito. «Deshacer última aplicación» retira **solo** la última aplicación y libera su tramo en el registro de solapes; si algo sobrevive, conserva su registro y lo avisa. «Aceptar» conserva los resultados y cierra una **única marca de deshacer**: un solo `UNDO` los retira. Si la marca de deshacer no se puede **iniciar**, la ejecución se **cancela antes de crear nada** (no se promete un `UNDO` único que no existiría); si no se puede **cerrar**, se informa y el mensaje final deja de garantizar el `UNDO` único. El resumen final informa el número de aplicaciones **retenidas**, no el contador acumulado, porque «Deshacer última aplicación» puede haber retirado algunas antes de aceptar.

#### Verificación manual

**Versión actual validada por el usuario tras pruebas manuales positivas en AutoCAD**, incluida la reducción de densidad de alambrada/malla: «Los test resultaron positivos. Todo esta OK». La confirmación es general y no acredita individualmente cada escenario; la lista se conserva para futuras regresiones. No hay AutoCAD disponible ni runner automatizado en el repositorio. Esta lista es la comprobación prevista (S13) y **no representa resultados individuales obtenidos**. Usar un DWG de prueba y revisar las entidades y las variables con Propiedades o `LIST`.

- [ ] **Carga y diálogo:** `APPLOAD` muestra `MCCOLIND cargado. Escriba MCCOLIND para iniciar.`; el comando pide la fuente sin cargar otros scripts; el diálogo abre con Automático activado, medidas manuales deshabilitadas (conservan `500`, `2`, `4`, `1`, `1`), estilo *Alambrada* y nombre `Colindancia`.
- [ ] **Automático:** rectángulo `(0,0)-(1000,0)-(1000,600)-(0,600)`: D=1000; altura interior/exterior **10/15 m**, paso normal **20 m**, franja **10 m**, holguras libres **5/15 m**. Medir alturas y separaciones reales con Propiedades y distancias, también en una selección parcial. Cambiar zoom y añadir un objeto lejano: no deben cambiar. Repetir con fuente escalada por 10: todas las medidas se multiplican por 10.
- [ ] **Modo y persistencia:** desactivar Automático, introducir valores manuales, aplicar y deshacer: el diálogo conserva modo y entradas. Introducir `1abc`, activar Automático y aplicar: el valor manual inválido no bloquea; al volver a manual, se conserva y se rechaza sin crear entidades.
- [ ] **Conversión manual 1:500:** desactivar Automático; con los valores iniciales, el resumen indica texto `1.000 m`, paso `2.000 m`, franja `0.500 m` y separación `0.500 m`, y el patrón repite cada 2 m de lindero.
- [ ] **Siete estilos:** dibujar los siete sobre un mismo polígono cerrado y comprobar el trazado: X y puntos sin franja; franja interior, centrada y exterior con diagonales inclinadas **30° respecto de la perpendicular** y **60° respecto del lindero**; malla con cruces a **75° respecto del lindero**, con huecos en automático y extremos contiguos en manual; zigzag continuo. Probar malla también en manual y con un tramo que no admita una X completa: no debe prolongarse fuera del tramo. Comprobar que la **fuente queda visible** y sin cambios (mismas coordenadas, capa y bandera).
- [ ] **Menor densidad automática:** con D=1000, alambrada repite cada **30 m** (X del mismo tamaño), malla de franja10 mantiene X a75° y proyección≈**2,679 m**, con centros cada **4,019 m** y hueco≈**1,340 m**. En un tramo largo habrá aproximadamente un tercio menos de X que antes, sin cambiar textos ni holguras. Confirmar que puntos, paredes y zigzag siguen iguales. En manual, alambrada conserva el paso introducido y malla las X contiguas; probar ambas en tramos cortos y extremos parciales sin prolongaciones.
- [ ] **Cadena abierta de tres vértices:** una LWPOLYLINE abierta de tres vértices no debe rechazarse como contorno inválido; sus dos tramos se estilizan con normalidad. Un retroceso (por ejemplo `(0,0)-(10,0)-(5,0)`) y un autotoque sí deben rechazarse.
- [ ] **UTM y zigzag:** con la fuente en UTM (por ejemplo origen `(500000, 2000000, 100)`), el estilo *Lindero de árboles vivos* y la etiqueta colocada manualmente deben aparecer **sobre la fuente**; ningún vértice debe quedar cerca del origen `(0,0)`, y la cota debe ser la de la fuente.
- [ ] **Ambos sentidos del polígono:** repetir con el contorno dibujado en sentido horario y antihorario; la franja de *Pared propia* queda dentro y la de *Pared colindante* fuera en ambos casos.
- [ ] **Inversión del recorrido:** con una fuente cerrada, elegir dos puntos y pulsar `I` antes de aplicar: cambia el camino y los lados **no** se invierten; un solo `UNDO` retira el resultado.
- [ ] **Fuente abierta:** elegir el lado interior con un clic; la etiqueta del estilo queda del lado señalado y la del nombre en el contrario; con un único tramo no se ofrece invertir.
- [ ] **Selecciones parciales:** aplicar a una parte del contorno y comprobar que el patrón empieza y termina en los puntos proyectados, sin prolongarse en las esquinas.
- [ ] **Coincidencia:** dos clics sobre el mismo punto avisan y no crean nada; `Enter` en el segundo punto vuelve al diálogo sin resultado.
- [ ] **Concavidades:** en un contorno en L/U o estrecho, comprobar que ninguna etiqueta cruza el lindero, invade el patrón o cae del lado contrario; si la búsqueda no encuentra sitio, aparece la petición de punto manual y, si el punto no vale, el aviso correspondiente.
- [ ] **Tramos cortos:** aplicar sobre un tramo más corto que la repetición: se dibujan los bordes de franja y solo las marcas que caben completas, sin prolongaciones. En el zigzag, con paso `4` y un tramo de longitud `4,5` (filas `s=0,1,2`), el último vértice debe quedar **interpolado** en la pierna incompleta, no cruzando toda la franja.
- [ ] **Holgura de etiqueta (dos sentidos):** con una caja `[-5,5]×[1,2]` y una arista de referencia `(-1, 0.9)-(1, 0.9)` con holgura exigida `0.5`, la posición debe rechazarse (la distancia real es `0.1`), y una caja que **envuelve** la fuente no debe aceptarse como etiqueta exterior. Comprobar que la búsqueda automática y la colocación manual aplican el mismo criterio.
- [ ] **UCS rotado y elevación:** con UCS girado y cota distinta de cero, los clics se interpretan correctamente y el resultado conserva la cota de la fuente.
- [ ] **Ventana gráfica flotante:** en un layout de papel con una ventana de modelo activa (`CVPORT > 1`), seleccionar una entidad de **modelo**: debe aceptarse y dibujarse en modelo, sin el aviso de «otro espacio». Con el espacio papel activo (`CVPORT = 1`), una entidad de modelo sí debe rechazarse.
- [ ] **Distintas escalas y altura fija:** en manual repetir a `1:100`, `1:1000` y `1:2000` y comprobar tamaño, paso y franja en metros; un estilo con altura fija debe avisar y usar su altura. En automático y con el rectángulo D=1000, usar un estilo de altura fija distinta de 10: ambos TEXT deben medir **10/15 m**, las cajas y holguras deben corresponder a esas alturas y la definición del estilo debe quedar intacta. Con un estilo de texto de **ancho distinto de 1 u oblicuidad distinta de 0**, la caja medida y el texto dibujado deben coincidir (propiedades `41`, `51` y banderas de generación `0` del `TEXT`).
- [ ] **Errores y rechazos:** arcos (`bulge`), normal `-Z`, LINE con distinta cota entre extremos, autointersecciones, retrocesos, vértices duplicados, superficie nula, capa bloqueada y fuente de otro espacio: aviso claro, sin entidades nuevas y sin cambios en la fuente.
- [ ] **Entradas inválidas:** en modo manual, `0`, `-1`, `1abc` o `0,5` en cualquier campo numérico muestran el aviso y conservan el texto crudo al reabrir el diálogo; el nombre vacío se rechaza.
- [ ] **Superposición:** aplicar dos veces sobre el mismo tramo: el segundo aviso indica que ya está cubierto y no se crea nada; tras «Deshacer última aplicación», el tramo vuelve a estar disponible.
- [ ] **Deshacer última aplicación:** con tres aplicaciones, deshacer retira solo la última (entidades y registro de solapes) y conserva las otras dos; sin aplicaciones, avisa. Tras deshacer y aceptar, el resumen final debe indicar **el número de aplicaciones retenidas**, no el total acumulado.
- [ ] **Aceptar y UNDO:** aceptar con dos aplicaciones y ejecutar un solo `UNDO`: desaparecen todas las entidades creadas y la fuente sigue intacta.
- [ ] **Cancelaciones:** `ESC` en la selección de la fuente, en el clic de interior, en los dos puntos, en la vista previa, en la ubicación manual y con «Cancelar»: sin entidades parciales, sin DCL temporal y con `OSMODE`, `CMDECHO` y `DIMZIN` restaurados. Repetir el comando después para descartar estado residual.
- [ ] **Fallos de borrado (solo si se pueden provocar):** si AutoCAD rechaza retirar alguna entidad al cancelar o al deshacer, el mensaje debe indicar el **número** de entidades que sobrevivieron y el registro no debe liberarse; no se debe leer «no se conservó ningún resultado» mientras queden entidades. No hay forma reproducible de forzar este fallo en una prueba normal; si no se provoca, registrar la casilla como no comprobada.

### MCELEMENTS — Edificaciones, vegetación, masas de agua y ríos

**T4/T5/T6 implementados; S1–S2 añade el rótulo interior certificado con hueco de trama y el rótulo de río paralelo y exterior; el patrón interior del agua se calcula por niveles desde el contorno original (S1–S5) y admite contornos compuestos de piezas SPLINE abiertas (S1–S3); sigue pendiente de prueba funcional en AutoCAD.** Crea geometría nueva sin seleccionar ni modificar objetos anteriores. Incluye seis estructuras, con ríos abiertos por centro o límite. Requiere AutoCAD Windows con ActiveX, patrones ANSI y, para agua, operaciones REGION/Boolean y Offset. Sin AutoCAD no se reproduce el fallo reportado ni se certifica la corrección; cambiar la estrategia a barrido desde el original reduce la acumulación de aproximaciones, pero **no garantiza** que el motor deje de fallar: necesita prueba real.

#### Uso

1. Cargar `lisp/MC-ELEMENTS.lsp` con `APPLOAD` y ejecutar `MCELEMENTS`; no necesita otros scripts.
2. Elegir estructura, **factor visual positivo** y un único rótulo: ninguno, texto centrado o círculo con tag (este último solo para polígonos). Ríos ofrece ninguno/texto paralelo, sin borrar la elección poligonal al alternar. El contenido se deshabilita sin rótulo y conserva su valor. Se exige contenido no vacío cuando hay rótulo. **Recta/ondulada** se habilita para ambas estructuras de agua; centro/límite y cantidad solo para ríos. Los campos deshabilitados conservan sus valores crudos y no se validan como parámetros de río para otros tipos.
3. Para polígonos, marcar al menos tres vértices y pulsar Enter para cerrar. Puede repetirse el primero al final. Para el octágono, indicar centro y un punto para su radio horizontal. Para ríos, dibujar dos o más puntos y pulsar Enter **sin cerrar**; elegir previamente centro/límite y total. En límite con más de una línea, señalar después del dibujo el lado hacia donde copiar.
4. Edificaciones/vegetación crean una **LWPOLYLINE cerrada** y un **HATCH no asociativo**. Masa de agua crea el contorno cerrado y sus desfases interiores, sin HATCH: LWPOLYLINE en recta, SPLINE en ondulada (los desfases pueden cambiar de tipo según AutoCAD). Según el rótulo se añade un TEXT o un CIRCLE con TEXT, y en edificaciones/vegetación la trama se evalúa con un **hueco interior** que despeja el rótulo. Los resultados son estáticos y editables; editar el contorno no recalcula el patrón ni el rótulo.

| Estructura | Patrón (ángulo adicional 0) | Capa propia |
|---|---|---|
| Edificación de 1 nivel | ANSI31 | `MC-EDIFICACION-1` |
| Edificación de 2 niveles | ANSI37 | `MC-EDIFICACION-2` |
| Edificación circular (octágono) | ANSI31 | `MC-EDIFICACION-CIRCULAR` |
| Área verde | ANSI36; TrueColor RGB **22,163,74** (`#16a34a`) en el HATCH | `MC-AREA-VERDE` |
| Masa de agua | Desfases interiores automáticos; TrueColor RGB **59,130,246** (`#3b82f6`) en contorno y copias | `MC-MASA-AGUA` |
| Ríos | Eje/límite abierto; copias por Offset en Recta o separación aproximada adaptable en Ondulada; rótulo recto **paralelo al tramo** y **por fuera** del conjunto; mismo azul RGB **59,130,246** | `MC-RIO` |

**Vista previa durante la captura:** tras cada vértice nuevo se muestran los lados ya capturados y, desde el tercero, el cierre provisional al primero en rojo discontinuo. Se mantienen `getpoint`, las coordenadas escritas, los OSNAP y la banda elástica nativa hacia el cursor; el cierre se actualiza al aceptar cada vértice, no al mover el cursor. Los ríos muestran solo sus tramos abiertos, sin cierre ficticio; el octágono conserva la interacción centro/radio. La vista usa segmentos rectos de captura incluso para agua **ondulada**: no anticipa la SPLINE final ni modifica su suavizado. Son vectores temporales, no entidades del DWG; se refrescan al aceptar otro vértice y se intenta limpiarlos al finalizar, cancelar o fallar. Pan/zoom puede ocultarlos hasta el siguiente vértice; no es geometría persistente.

El ángulo adicional cero conserva la orientación definida por cada patrón ANSI. El octágono tiene un vértice hacia el **norte +Y de WCS**, independientemente del UCS. Los clics se convierten de UCS a WCS y se proyectan al plano horizontal con la Z del primer vértice o centro. No hay transformación de CRS ni conversión de unidades.

Las capas nuevas usan sus propiedades predeterminadas. Las existentes se reutilizan **sin alterar su definición**; se rechazan si están apagadas, congeladas, bloqueadas o son externas. Todos los componentes de una estructura usan su capa; salvo la trama verde y la geometría azul del agua, el color es ByLayer (también los rótulos del agua). `CLAYER`, `TEXTSTYLE` y el UCS no cambian. El texto usa el estilo actual con altura explícita, también si el estilo define altura fija; no modifica el estilo. Los rótulos normales se orientan sin reflejo ni inversión mediante los booleanos ActiveX [Backward](https://help.autodesk.com/cloudhelp/2026/ENU/AutoCAD-ActiveX-Reference/files/GUID-A594237B-925A-4F5A-BF0E-3447DCA55456.htm) y [UpsideDown](https://help.autodesk.com/cloudhelp/2026/ENU/AutoCAD-ActiveX-Reference/files/GUID-48E13661-CC33-45CF-BDA2-7EE538EC72DF.htm) en falso, en lugar de asignar `TextGenerationFlag=0`. Se conserva la justificación centrada y la caja WCS real del TEXT (`GetBoundingBox`) para dimensionar el círculo/tag; los ríos comparten esa creación del texto y después lo **giran y desplazan** con su propio certificado, sin tag ni hueco de trama.

#### Fórmulas y límites

Sea `A` el área real de la REGION temporal, `L = sqrt(A)` y `f` el factor visual:

| Medida | Fórmula | Cuadrado 10×10, f=1 |
|---|---|---|
| Escala del patrón ANSI (edificaciones/vegetación) | `0.02 × L × f` | 0.2 |
| Altura TEXT `h` (sin círculo) | `0.04 × L × f` | 0.4 |
| Altura TEXT `h` (con círculo/tag) | `0.065 × L × f` | 0.65 |
| Radio del tag | `max(1.5 × h, 0.6 × sqrt(w² + b²))` | Al menos 0.975; depende del contenido |
| Margen libre `m` del rótulo | `0.2 × base` | 0.2 del radio del tag |
| Envolvente certificada (tag) | `base + m` | Disco que contiene tag y texto |
| Envolvente certificada (solo texto) | `sqrt((w/2 + m)² + (b/2 + m)²)` | Disco que contiene el rectángulo con margen |
| Separación del agua `d` | `0.05 × L`, **sin factor visual** | 0.5 |

`w` y `b` son ancho y alto de la caja WCS real del TEXT, medida con `GetBoundingBox` de la entidad creada: incluye estilo, ancho, oblicuidad y altura fija del estilo, y un tag largo agranda el círculo. Son proporciones visuales propuestas, no medidas normativas. La escala del patrón es su multiplicador, **no** la distancia entre líneas: esta depende de la definición ANSI. Con la misma figura y contenido, factores `0.5`, `1`, `2` reducen a la mitad, conservan o duplican las medidas de trama y rótulo; no alteran el contorno ni la separación del agua. Usar punto decimal: `0.5`; se rechazan vacío, cero, negativos, comas, exponentes y texto sobrante como `1abc`.

El **círculo con tag** parte de un tamaño **62.5 % mayor que el original** para texto y círculo juntos (aumento inicial del 25 % y otro 30 % sobre ese resultado), conservando la proporción entre ambos. Solo cambia el tamaño inicial: si no cabe con margen, el ajuste interior puede reducirlo. La escala de trama, el texto sin círculo y los rótulos de ríos no cambian.

#### Rótulo dentro del polígono (S1–S4)

El rótulo se coloca siempre **completo dentro del contorno final**, con margen libre, y la trama se abre alrededor. Los ríos tienen su propia regla (siguiente apartado): el rótulo se ancla en la **mitad de longitud**, se gira con la tangente local y se separa **por fuera** del conjunto; sigue sin tag y sin hueco de trama.

Orden de decisión, de más barato a más costoso:

1. **Centroide real** del área (REGION), si la envolvente completa del tamaño pedido cabe con margen.
2. **Reubicación** en una posición interior certificada: rejilla 7×7 de nodos interiores y refinamiento 5×5 alrededor del nodo más holgado, ordenados por distancia al contorno final.
3. **Reducción uniforme** solo si ninguna posición admite el tamaño pedido: factores `1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.25`, aplicados a la altura del texto y al radio del círculo con el **mismo factor** (proporciones conservadas).

**Qué se certifica y cómo.** La geometría de referencia no son los vértices de captura sino el **contorno final**: en masa ondulada, la SPLINE cerrada que realmente se dibuja. La distancia al contorno solo filtra y ordena candidatos; la prueba es una **diferencia REGION/Boolean sobre copias**: se crea un disco de prueba del radio de la envolvente, se convierte en REGION, se le resta una copia de la REGION del contorno final y solo se acepta si no queda superficie. Esa REGION, el disco y sus copias son recursos propios registrados que se retiran al terminar o con el rollback. **Envolvente conservadora explicada:** el texto se inscribe en su círculo circunscripto y el tag usa `0.6 × diagonal` en lugar del `0.5` mínimo, así que un disco certificado contiene texto, círculo y margen aunque el estilo sea ancho u oblicuo. Los muestreos del contorno no son el certificado: ninguna esquina ni conjunto de muestras sustituye esa diferencia.

**Hueco de trama.** En edificaciones y área verde el HATCH se evalúa con el bucle exterior y un **bucle interior no asociativo temporal**: círculo de radio `base + m` para el tag y rectángulo de semi-extremos `w/2 + m` y `b/2 + m` para el texto. El estilo de islas es el **normal** (`HatchStyle = 0`), el `PatternType` sigue siendo `1` (ANSI predefinido) y la forma temporal se retira **después** de `Evaluate`, también en error. No se usan máscaras, no se recorta ningún otro objeto y la masa de agua conserva sus desfases intactos: esa ruta no tiene HATCH ni pasa por el hueco. Sin rótulo no se crea hueco ni TEXT y el resultado es el anterior.

**Límites y fallo explícito.** La búsqueda es acotada, no exhaustiva: 9 tamaños, y por cada tamaño el **centroide más hasta 4 posiciones de rejilla** (5 certificaciones como máximo), con una sola pasada de refinamiento. Si se agotan, el comando **falla con mensaje propio y retira toda la ejecución** (rollback de recursos registrados); nunca deja el rótulo fuera ni lo omite en silencio. No se busca el círculo inscrito máximo exacto ni se garantiza la posición más estética posible: se garantiza que la posición aceptada está certificada. La consola informa si hubo **reubicación** y el **porcentaje de reducción** aplicado. La reducción depende de que AutoCAD acepte cambiar la altura del TEXT: con un estilo de altura fija puede no aplicarse, y entonces el ajuste termina en el fallo explícito en lugar de colocar el rótulo fuera del contorno.

En polígonos se rechazan menos de tres vértices, lados nulos, retrocesos, cruces, contactos consigo mismo, superficie nula o región no única. La tolerancia geométrica de los vértices es `max(1e-8, extensión XY × 1e-10)` en unidades de dibujo. Solo se admiten figuras horizontales sin huecos; no se convierte geometría existente.

#### Rótulo del río: paralelo y exterior (S1–S2)

El rótulo de río sigue siendo **una sola línea recta** de `TEXT` —sin tag, sin hueco de trama y sin curvatura letra por letra—, pero ya **no** queda horizontal sobre el eje: se ancla en la **mitad de longitud** del eje original, se gira con la **tangente local** y se separa **por fuera del conjunto** de líneas. La altura pedida no cambia: `0.04 × R × f`.

| Decisión | Regla |
|---|---|
| Estación | Mitad de longitud del eje/frontera original (`R/2`), la misma que informa el generador |
| Rotación | Tangente local XY en esa estación, corregida para ser **legible**: nunca boca abajo |
| Lado (automático) | Normal **+Y** si el tramo es horizontal dominante (`|Tx| ≥ |Ty|`); **−X** si es vertical dominante |
| Sentido de dibujo | No interviene: invertir el recorrido conserva el lado y la línea de texto |
| Holgura | `0.5 ×` el **alto real medido** del TEXT creado (`GetBoundingBox`), no la altura nominal |
| Altura, capa, color, estilo | Sin cambios: los aplica `mce:texto-rotulo` antes de la transformación rígida (giro y traslado) |

**Qué conjunto se despeja.** El rótulo debe quedar fuera de las **curvas realmente generadas**, no de un `paso × cantidad` nominal: Ondulada puede haber reducido el paso y Límite deja las copias de un solo lado. Antes de crear el TEXT se toma una **instantánea de las curvas vivas** ya registradas (`AcDbPolyline`/`AcDbSpline`), así que los generadores no cambian su contrato y los intentos rechazados no cuentan. El estado **borrado** se consulta primero: solo un borrado **confirmado** permite omitir un recurso, porque esos son los intentos que el generador descartó. Un estado de borrado ilegible, un tipo ilegible o un conjunto **vacío o sin el eje original** no se certifican como conjunto parcial: el comando **falla con mensaje propio y retira la ejecución** (`ESC` sigue cancelando por el camino habitual).

**Certificado acotado.** Se mide la **caja real** del TEXT con su estilo, todavía horizontal (rotación 0), y se conservan sus **semi-tamaños y su centro medido**. El giro es **rígido alrededor de ese centro** y después ese mismo centro se **traslada al punto certificado** (`Rotate` y `Move` sobre el centro medido, sin reescribir `TextAlignmentPoint`), así que la caja medida queda centrada exactamente en la posición certificada y el rectángulo contiene la tinta aunque la justificación del estilo sea asimétrica. El certificado usa un **rectángulo orientado** temporal sobre la tangente, con los semiejes medidos **más la holgura**, y lo comprueba con `IntersectWith` nativo contra **cada** curva del conjunto; además se rechaza cualquier curva cuyos **extremos** caigan dentro del rectángulo, porque un tramo interior no corta ningún borde. Es orientado con la tangente del texto, no una caja alineada a los ejes: en un tramo a 45° una caja alineada a los ejes de un TEXT de `10×4` mediría `9.90` de alto frente a `4` reales (`2.47` veces), y esa inflación sería separación falsa. El **desplazamiento** sí se aplica sobre la normal WCS de la tabla, y su valor inicial es la **proyección exacta** del rectángulo sobre esa normal, no su diagonal. La primera separación probada es la **extensión real** de las curvas en el sentido de la normal, medida por muestreo; esa estimación solo propone y el certificado decide. Se admiten hasta **9** comprobaciones, sumando `0.5 × alto` en cada reintento; si ninguna es libre, el comando **falla con mensaje propio y retira toda la ejecución**. El rectángulo temporal se registra **antes** de las consultas nativas y se retira al certificar; ante error queda a cargo del rollback habitual.

**Límites reales.** El certificado se apoya en la caja **horizontal medida** y en la transformación rígida que la centra en el punto certificado: no vuelve a medir el TEXT ya girado, así que el estilo no introduce un sesgo de centrado, pero tampoco se corrige una diferencia de caja posterior al giro (por ejemplo, un `REGEN` con métricas de fuente distintas). No se detecta solape con otros objetos del dibujo, solo con las curvas del río, y no se busca el lado más estético: el lado es el automático de la tabla. En tramos casi verticales el desempate por legibilidad puede cambiar el sentido de lectura (en la vertical exacta se elige +90°; una tangente a un ulp de ella puede caer en −90°), sin afectar la línea, la caja certificada ni el lado. No se agrega ningún clic ni opción de diálogo, y con UCS rotado o inclinado el cálculo sigue en WCS conservando la Z del eje.

#### Agua: suavizado, fragmentos y compatibilidad

- **Recta** conserva exactamente los vértices WCS capturados (con su proyección Z y sin repetir el cierre). **Ondulada** ajusta todo el recorrido con `AddSpline`: el primer punto de ajuste se repite al final para cerrar la curva geométricamente, y en ese punto común se usan **tangentes iguales y no nulas** (dirección `P1 − P(n−1)`, magnitud acotada por la media de las cuerdas adyacentes) antes de marcar **Closed2 escribible**. Es una curva suave continua, no redondeos locales ni ondas; puede apartarse de los clics. Si Closed2 no está disponible o falla, se rechaza con mensaje de incompatibilidad y no se degrada a una polilínea. Tras escribir Closed2 se **relee el cierre** de la SPLINE; si no quedó cerrada, se informa antes de intentar la REGION.
- Se valida el contorno **final** mediante REGION con los controles nativos, que se conservan en toda curva: la curva debe estar **cerrada**, `AddRegion` no puede fallar, debe devolver **exactamente una** región y su **área** debe ser positiva (`> 1e-16`). En una **SPLINE** (`AcDbSpline`) esos controles son el criterio completo: si se cumplen, la curva se acepta aunque `REGION.Perimeter` y la longitud de la curva difieran. Esos dos valores se imprimen **una sola vez** para el contorno original como diagnóstico informativo (`Agua: … REGION perímetro …; longitud de curva …; diferencia … (informativo…)`); no se imprime por cada copia interior ni en agua recta. La diferencia puede deberse al cálculo numérico o a geometría descartada; no distingue esas causas ni **certifica** que el mapeo sea completo, simple o sin lóbulos descartados: una diferencia pequeña también es compatible con un lóbulo pequeño descartado, y este criterio **retira un filtro secundario de completitud**. En **polilíneas u otras curvas** se conserva el guard previo `max(1e-8, longitud × 1e-8)`: una región positiva no prueba recorrido íntegro, así que el perímetro debe cubrir toda la longitud. El cierre inválido, el fallo del núcleo, varias regiones o un área no positiva siguen rechazándose aunque el polígono de entrada fuera válido; aceptar una SPLINE mediante esos controles no garantiza conservar todo su recorrido. El centroide y `A` corresponden a esa figura final, también en ondulada. Si el contorno no se puede validar, el comando informa la **causa medida**: curva no cerrada, texto nativo de `AddRegion`, número de regiones distinto de uno, superficie nula o —solo en curvas no SPLINE— discrepancia perímetro/longitud con su tolerancia. Los candidatos interiores que fallen conservan el aviso de **relleno no certificado**; ese diagnóstico es local a cada candidato y no arrastra una causa anterior.
- Cada nivel interior se calcula por **barrido desde el contorno original**: para el nivel `n` se llama a Offset una vez por signo sobre la **curva original** (nunca sobre la REGION `original`, que no es una curva, ni acumulando sobre la copia anterior) con distancia `±n·d`, de modo que cada distancia es múltiplo exacto del paso. Se examinan **todas** las curvas devueltas y cada fragmento se prueba contra **todos** los padres retenidos del nivel anterior: se conserva si su área supera la tolerancia, es estrictamente menor que al menos un padre y está contenido en **ese padre y en el original**. La contención se comprueba por diferencia REGION/Boolean de superficies completas, no por centroide ni muestras. Se conservan todas las ramas válidas y se deduplican por área y contención en todo el nivel, entre ambos signos.
- La tolerancia de área es `max(1e-16, A × 1e-9)`; los fragmentos deben superarla, el área debe disminuir más que ella y la diferencia fuera de cada región no puede superarla. La separación permanece constante entre generaciones; la cantidad surge del espacio disponible, **no se solicita** ni depende del factor, zoom u objetos lejanos.
- Límites explícitos: **256 niveles, 2048 llamadas Offset —como máximo dos por nivel, una por signo— y 4096 curvas devueltas** (incluidas rechazadas). Superarlos o no poder certificar un Boolean retira toda la ejecución con diagnóstico, sin truncar en silencio. Cuando no quedan candidatos admisibles, termina la búsqueda. Si Offset falla o devuelve una curva inválida, una salida vacía o un candidato decreciente no contenido, conserva las partes válidas pero advierte **«relleno completo NO certificado»**: un error del motor no prueba agotamiento del interior. Un candidato que no reduce respecto de ningún padre o cuya área no supera la tolerancia es una **exclusión ordinaria**, no un fallo. El resumen informa la separación, el máximo de niveles aceptados y el último nivel probado; el aviso registra de forma acotada la **primera incidencia** con su etapa (Offset nativo, rechazo REGION con su motivo, contención o salida vacía), nivel y desfase con signo, sin una línea por candidato, y solo cuenta las posteriores. Si esa primera incidencia es un rechazo REGION, añade **índice/total de fragmentos de esa llamada Offset**, **tipo de entidad** y **distancia WCS entre extremos**, en unidades de dibujo y notación científica para mostrar huecos pequeños. Las consultas son de solo lectura, antes de retirar el fragmento; si un dato no se puede obtener, muestra **«no disponible»** sin cambiar el rechazo (ESC sigue cancelando). Cuando esa llamada Offset devolvió **varias piezas SPLINE abiertas**, intenta la **admisión conjunta** (S1–S3): copia esas piezas (nunca el contorno original ni las piezas reales), llama **una sola vez** a `AddRegion` con todas las copias en un único vector de objetos y acepta el conjunto **solo** si devuelve **exactamente una** región positiva y esa superficie cumple las **mismas** condiciones que una individual: área sobre la tolerancia, menor que un padre retenido y contenida —por Boolean completo— en el original **y** en ese mismo padre mayor, con la misma deduplicación global del nivel. Si se admite, todas las piezas nativas se conservan **tal cual** (sin `Closed2`, sin reajuste, sin polilínea, sin GROUP ni REGION retenida) como **un solo contorno lógico editable**, y la región conjunta se usa **solo** como padre temporal: vive hasta procesar los dos signos del nivel siguiente y luego se retira. La deduplicación trata el conjunto como **una sola superficie**, pero retira o conserva **todas** sus piezas juntas. **Fallback conservador:** si `AddRegion` devuelve cero o varias regiones, no se puede asociar cada región con las piezas de esa llamada, el resultado no es válido o no está contenido, **no** se adivina propiedad ni se acepta geometría dudosa; se informa el motivo medido, se retiran las piezas del conjunto y se **preservan** las ramas individuales válidas. Un conjunto de **una sola** pieza abierta no forma contorno compuesto y se resuelve con la metadata individual. Los casos bajo la tolerancia o sin reducción siguen siendo **exclusiones ordinarias**. La prueba conjunta anterior de **8 fragmentos** era solo diagnóstico y **no** existe como límite de aceptación: los límites de producción siguen siendo 256 niveles, 2048 llamadas Offset y 4096 curvas devueltas. Si `AddRegion` responde pero su lista de regiones **no se puede enumerar**, la ejecución **aborta** con el texto nativo y un aviso explícito: las copias registradas siguen el camino de limpieza habitual, pero esas REGION no identificadas **pueden quedar** en el dibujo y **no se certifica** su limpieza; revisar el DWG de prueba o deshacer. **Una región nativa conjunta no certifica topología**, ausencia de lóbulos descartados ni un conteo fijo de niveles; ESC sigue cancelando y el conjunto aceptado no fuerza cierre, no cambia separación y no modifica el suavizado.

**Compatibilidad aún no probada:** AddSpline, Closed2, Offset y REGION/Boolean requieren ejecución real en la versión de AutoCAD del usuario. La conversión nativa y sus tolerancias limitan las curvas admitidas; formas demasiado estrechas o pequeñas pueden no producir ningún desfase. No se promete completar una geometría que el motor no pueda resolver.

#### Ríos: conteo exacto y separación

- **Centro:** el total incluye el eje original y debe ser impar. `3` genera eje + una copia a cada lado; `5`, eje + dos a cada lado. Un par se rechaza **en el diálogo antes de dibujar**. El eje se conserva.
- **Límite:** el total también incluye la frontera original. `3` genera original + dos copias hacia el punto señalado. Se convierten los clics a WCS y se proyectan a la Z inicial. Un punto sobre la curva o sobre una dirección tangente ambigua se rechaza; no se adivina el lado. Recta compara ambos signos reales de Offset con la tangente local; Ondulada usa normales XY orientadas por la tangente. Invertir el recorrido no debe invertir el lado físico elegido.
- **Total `1`:** solo original, tanto en centro como límite; no se pide punto de lado ni se llama a Offset. Cantidad exige exclusivamente dígitos, entero entre `1` y `2147483647`; se rechazan espacios, signos, decimales, exponentes, cero y texto sobrante. Los ceros iniciales son válidos si el valor es positivo.
- Sea `R` la **longitud de la curva original final** (no la cuerda ni un cierre ficticio): Recta conserva separación fija `d = 0.05 × R`; Ondulada parte de ese paso y puede reducirlo uniformemente para el conjunto. La altura sigue siendo `h = 0.04 × R × f`. Cada nivel se calcula desde el original con `i × d`, nunca acumulando sobre copias. El factor visual no afecta ni paso ni total. Ejemplo recto `(0,0)-(100,0)`: `R=100`, `d=5`; centro 3 ocupa `Y=-5,0,5`, centro 5 ocupa `Y=-10,-5,0,5,10`. Límite 3 hacia Norte ocupa `Y=0,5,10`; hacia Sur, `Y=0,-5,-10`. Con `f=0.5/1/2`, alturas `2/4/8`, mismas curvas.
- El rótulo es un **TEXT ByLayer en MC-RIO**, anclado en la **mitad de longitud** del eje/frontera original (no en un centroide de área ni en el promedio de puntos), girado según la tangente local y separado por fuera del conjunto según «Rótulo del río: paralelo y exterior». No hay CIRCLE/tag. Para `(0,0)-(60,0)-(60,40)`, `R=100`, estación `(50,0)` y tangente horizontal: el ancla sigue en `X=50`, pero el texto sube en `Y` fuera de las líneas.
- Recta produce LWPOLYLINE abierta conservando los puntos; ondulada produce SPLINE **abierta** con ajuste global, con tangentes de extremo **explícitas y no nulas** (`primer→segundo` al inicio y `penúltimo→último` al final; con dos puntos se repite la única cuerda) y sin Closed2. La respuesta del motor a esas tangentes requiere prueba en la versión de AutoCAD usada. El suavizado cerrado de masas de agua sigue independiente. Ambos admiten dos puntos; se rechazan cierres, puntos repetidos, retrocesos, cruces y contactos no adyacentes sin añadir tramo último→primero.
- **Límite conservador del suavizado:** la SPLINE final y cada SPLINE devuelta deben tener controles con avance estrictamente creciente al proyectarlos sobre su cuerda inicial→final. Esto certifica ausencia de retroceso/cruce sin confundir muestras con prueba; curvas en U o controles sin avance certificable pueden rechazarse aunque fueran simples. Usar recta o un recorrido más simple. Los desfases deben ser LWPOLYLINE o SPLINE abiertos y válidos; no se fuerza REGION ni área en ríos.
- **Pesos racionales vs polinómicos:** solo en una SPLINE **racional** (`IsRational` verdadero) se exigen además pesos presentes, tantos como controles y positivos. En una SPLINE **polinómica** (no racional) los pesos son **unitarios implícitos**: no se consultan, no se reescriben y no se interpreta ningún error COM atrapado como reserva. Pedir `Weights` en una polinómica es lo que produce el error reportado `No hay ningún grosor disponible para la spline polinómica`.
- **Ondulada aproximada, sin Offset:** se toman 65 muestras de la SPLINE original, en 64 intervalos de longitud, y sus normales locales XY. Cada nueva SPLINE se ajusta a puntos desplazados `i × d` sobre esas normales, a la misma Z. No son copias idénticas ni offsets perpendiculares exactos: el ajuste entre muestras puede variar la distancia. Se comprueban el avance de los controles reales, el lado local y las intersecciones nativas entre curvas completas, incluido el original. Si un intento produce pliegues no certificables, lado incorrecto o cruces, se retiran **todas** sus copias y se divide el paso común por dos, recalculando desde el original. Hay hasta **12 intentos**; no se conserva una mezcla de pasos ni se baja el total pedido. La consola informa **«separación aproximada»**, si fue **«reducida»**, el **«paso usado»** y el **«paso inicial»**. No se modifica el original para acomodar las copias.
- **Todo o nada:** en Recta cada Offset debe devolver exactamente una curva válida, con lado inequívoco y consistente; salida vacía, fragmentada o incompatible aborta como antes. En Ondulada, agotar los intentos informa **«Río ondulado: no se obtuvo un conjunto válido en 12 intentos; se retira todo el río.»**. Un error COM, ESC o fallo de limpieza aborta, no se oculta como ajuste del paso. Se retira **toda** la ejecución fallida, incluido original, copias y capas propias; no se conservan fragmentos parciales. Masas de agua conserva su ruta independiente.

#### Reprueba acotada del agua ondulada (S1–S5, pendiente)

Sin AutoCAD no se ejecutó ninguno de estos casos: son pasos mínimos repetibles, no resultados. La forma **ondulada** no conserva las constantes del polígono dibujado; hay que medir la **curva final** y su REGION, no los vértices de entrada. Solo la forma **recta** usa los valores conocidos del polígono. En cada caso registrar el **cierre real** (`Closed`/`Closed2`), regiones, área, perímetro, centroide, conteos, **color** RGB y **variables** antes y después.

**Caso S1–S3, repro focal del corte del patrón (pendiente).** Sin AutoCAD no se reproduce el corte ni el aviso; esta es la comparación mínima entre la salida reportada y el barrido por niveles. Usar el **mismo DWG original** del reporte (masa ondulada, factor visual `1`, sin rótulo); si no se dispone de él, el fixture manual de ocho vértices del caso S1 de abajo reproduce la forma, pero **no** el valor exacto del DWG.

1. Medir la REGION final: `A` y `d = 0.05×sqrt(A)` deben dar **`45.70165783`** para esa curva. La fórmula y el factor visual no cambian; no se ajusta `d` para forzar o maquillar niveles.
2. Conservar la **forma suavizada**: anillos cerrados suaves anidados hacia dentro, **no** ondas periódicas ni HATCH. El motor puede producir **más de los dos interiores** observados o no; no se promete un conteo fijo.
3. Comprobar que cada interior está **contenido** en el original y en un padre del nivel anterior, que las **distancias reales** son múltiplos `n·d` desde el contorno original y que se probaron **todos** los fragmentos de ambos signos, incluidas las **ramas válidas desconectadas** del fixture de dos lóbulos (ver abajo).
4. Recargar `lisp/MC-ELEMENTS.lsp` con **`APPLOAD`** en el **mismo DWG** y repetir los mismos clics y opciones. Copiar la **salida completa**: etapa, nivel, desfase con signo y, para el primer rechazo REGION, **fragmento `i/total`, tipo, distancia entre extremos WCS** y, si esa llamada Offset devolvió varias piezas SPLINE abiertas, la **admisión conjunta**: una única llamada a `AddRegion` sobre copias que se acepta solo con **exactamente una** región positiva y las mismas condiciones de área, reducción, contención en el original y en el mismo padre mayor, y dedup global del nivel. Al aceptarse, el resumen añade **«Contornos compuestos aceptados: N»** y las piezas nativas quedan editables como un contorno compuesto; la región conjunta es padre temporal y se retira tras el nivel siguiente. La última prueba del usuario dio **3 interiores**, último nivel **4**, desfase **`-182.80663133`**, «la curva suave no quedó cerrada», `fragmento 1/2` `AcDbSpline` con hueco `892.5859117335` y `1` región conjunta de área `330143.19653743`: esa cifra **no certifica** contención ni un conteo fijo de niveles, porque el motor puede seguir devolviendo varias piezas. Comparar antes/después sobre el mismo DWG: deben conservarse **las ramas individuales que ya eran válidas, la geometría exterior, la separación, las capas, las variables y la independencia del factor**; la admisión conjunta puede **añadir** piezas nativas, interiores y niveles posteriores, así que **los conteos pueden cambiar** y no se exige un número fijo ni se afirma que el corte quede resuelto. El conjunto aceptado debe poder editarse pieza por pieza. Si `AddRegion` responde pero su lista no se enumera, el comando **aborta** con el aviso de REGION no identificadas. Un error del motor **no** certifica agotamiento del interior.
5. Regresiones compartidas: agua **recta** `20×10` (`A=200`, `d≈0.70710678`, ideal 7 interiores) y **ocho puntos rectos** (`A=752028.0772`, `d≈43.359776`); **independencia del factor** `0.5/1/2` (mismas curvas, solo cambian altura y rótulo); **cancelación** y segunda ejecución sin REGION temporales; **geometría y capas preexistentes** intactas.

**Historial del rechazo (criterio superado).** El reporte S2 fue literal: «MCELEMENTS: El contorno final de agua es inválido, se cruza o no produce una región simple completa: el perímetro 754.98716622 no coincide con la longitud de la curva 754.98739403 (tolerancia 0.00007550).». Ese texto sigue existiendo en el código para polilíneas y otras curvas no SPLINE, y ya **no se emite para una SPLINE** que cumple cierre, región única y área positiva. No se subió el epsilon: se retiró un veto numérico secundario. Tampoco se usan muestreos, solver NURBS ni cambios de suavizado como prueba.

**Caso S1, polígono aportado por el usuario (pendiente).** Fixture manual, **no** reproducción del DWG original: la imagen entregada no informa Z ni versión de AutoCAD, así que estos ocho vértices se capturan en **WCS con Z=0** por conveniencia y no se atribuye esa Z al dibujo del usuario. Masa de agua **ondulada**, **factor visual `1`**, **sin rótulo**. Escribir en este orden exacto:

| Vértice | Este X | Norte Y |
|---|---:|---:|
| 1 | 520.15 | 1056.26 |
| 2 | 966.08 | 1009.76 |
| 3 | 1000.98 | 730.82 |
| 4 | 900.16 | 246.54 |
| 5 | 489.13 | 29.58 |
| 6 | 105.24 | 91.57 |
| 7 | 62.59 | 463.50 |
| 8 | 175.04 | 847.05 |

Tras el octavo punto pulsar **Enter** para cerrar, **sin repetir** el primer vértice. Comprobar: SPLINE cerrada, **una sola** REGION positiva, ausencia del mensaje de perímetro del historial y **un único** diagnóstico informativo del contorno original (`Agua: … REGION perímetro …; longitud de curva …; diferencia …`), sin repetirlo por copia interior. Registrar área, perímetro, longitud, diferencia, conteos, RGB y variables. El área del polígono de entrada (`752028.0772` en valor absoluto) **no** es el área esperada de la SPLINE: la curva suavizada se aparta de los vértices y solo se mide sobre la REGION final. Este caso tampoco demuestra que no se descarten lóbulos pequeños.

**Caso S1, control recto (pendiente).** Mismos ocho puntos en forma **recta**: conservan exactamente los vértices, `A = 752028.0772` unidades de dibujo al cuadrado y `d = 0.05 × sqrt(A) ≈ 43.359776`. Ese valor pertenece **solo** a la polilínea de control; no se traslada a la masa ondulada. Aquí sigue vigente el guard `max(1e-8, longitud × 1e-8)`. El agua recta no lleva HATCH.

**Caso S1, error o cancelación y segunda ejecución inmediata (pendiente).** Rechazar una entrada o cancelar con ESC y repetir `MCELEMENTS` acto seguido, sin ESC de recuperación intermedio: el segundo intento abre el diálogo, captura los ocho puntos y crea la estructura sin arrastrar el error anterior ni una REGION temporal previa. Registrar conteos, RGB y variables tras ambos intentos.

**Caso S4, DWG original del reporte (pendiente; criterio anterior superado).** El reporte negativo trae una masa ondulada cuyo **perímetro** de REGION es `4017.88183137` y cuya **longitud** de curva es `4017.88160809`: diferencia `0.00022328`, relativa `≈5.56e-8`. Con el umbral recto `1e-8` la tolerancia era `0.00004018` y el caso se rechazaba; la corrección previa subió el umbral SPLINE a `1e-7` (`≈0.00040179`). Ese ajuste empírico queda **superado**: hoy la diferencia no veta una SPLINE y solo se informa. Repetir sobre el mismo DWG y comprobar que el mensaje de perímetro no reaparece y que la REGION sigue siendo única, positiva y contenida.

**Intención visual S5 (pendiente, sin conteo fijo).** La imagen de referencia muestra polígonos cerrados concéntricos que pasan a contornos suaves **anidados hacia el interior**: no son ondas periódicas, no llevan HATCH, no exigen cuatro curvas ni simetría. Se mantiene el orden ya implementado: se suaviza el contorno exterior y los desfases nativos interiores se calculan **por niveles desde esa misma curva** a distancia `n·d` (ni acumulando sobre cada copia ni sobre polígonos suavizados por separado). Las cuatro curvas del ejemplo son ilustrativas y no cambian la cantidad automática ni autorizan alterar separación o forma para forzar un conteo. Los ríos quedan fuera de esa unidad de masas de agua; su nueva aproximación con paso adaptable se describe en «Ríos: conteo exacto y separación» y sigue pendiente de prueba en AutoCAD.

**Caso S5, río polinómico (pendiente).** El segundo error `AutoCAD.Application: No hay ningún grosor disponible para la spline polinómica` proviene de consultar `Weights` en una SPLINE no racional, cuyos pesos son unitarios implícitos. Repetir un río **ondulado** sobre el DWG original y comprobar que ese mensaje no aparece, que la SPLINE sigue **abierta** y que un río **recto** de control no cambia. No se alteran los pesos de la entidad.

- [ ] **Río ondulado, caso del reporte con 5 líneas (pendiente):** cargar la versión nueva y capturar `(65.79,1248.50)`, `(132.44,996.59)`, `(65.79,804.03)`, `(135.34,559.36)`, `(72.14,374.81)`, `(129.61,181.95)`, `(63.49,34.18)` a Z=0. Probar Centro con `3` y `5`, y Límite con `3` y `5` hacia **ambos lados**; repetir invirtiendo los puntos y señalando el mismo lado físico. Registrar la salida completa, paso inicial/usado, conteos exactos (incluido original), curvas abiertas suaves, azul RGB 59,130,246 y ausencia de cruces. El paso inicial es `0.05 × R`; el efectivo puede ser menor, siempre único para todos los niveles. Inspeccionar visualmente forma y separación: se acepta aproximación, no identidad ni equidistancia perpendicular exacta. El fallo original no se ha reproducido localmente ni se afirma resuelto sin esta prueba.

- [ ] **Masa ondulada cerrada, triángulo y rectángulo en ambos sentidos:** con `(0,0)-(6,0)-(0,4)` y su inverso `(0,0)-(0,4)-(6,0)`, forma **ondulada** y sin rótulo, dibujar los tres vértices y cerrar con Enter; repetir con el rectángulo `(0,0)-(20,0)-(20,10)-(0,10)` en ambos sentidos. La SPLINE debe quedar cerrada y producir **una** REGION. Como la curva suavizada difiere del polígono, **no** exigir área 12/200 ni conteos derivados del polígono: medir el área `A` real de esa REGION final, comprobar que la separación usada es `d = 0.05 × sqrt(A)` y que área, perímetro y centroide son coherentes con esa curva. Confirmar que el error reportado no reaparece y que el suavizado no degenera en un polígono de esquinas.
- [ ] **Masa recta de control:** con el rectángulo `(0,0)-(20,0)-(20,10)-(0,10)` en forma **recta**, el contorno conserva exactamente los vértices, `A=200` y `d=0.05 × sqrt(200)≈0.70710678`; su guard de perímetro sigue siendo el de polilínea `max(1e-8, longitud × 1e-8)`. La SPLINE ondulada ya **no** tiene umbral de perímetro: no se hereda ni se sube ningún epsilon. El agua recta no lleva **HATCH**; edificaciones y vegetación sí lo llevan, así que comparar contra una edificación poligonal en ambos sentidos.
- [ ] **Diferencia perímetro/longitud en SPLINE (criterio nuevo, no forzable aquí):** en una SPLINE cerrada con una única región positiva, cualquier diferencia entre `REGION.Perimeter` y la longitud de la curva debe **aceptarse** e imprimirse una sola vez en el diagnóstico informativo; no existe veto numérico. Sin AutoCAD no hay forma reproducible de fabricar esa diferencia, así que este punto se verifica por lectura del código y no se simula con mocks, runners falsos ni pruebas de API.
- [ ] **Guard de perímetro en curvas no SPLINE:** el rechazo `el perímetro … no coincide con la longitud de la curva … (tolerancia …)` se conserva para polilíneas y otras curvas, junto con los controles de cierre, región única, área positiva y contención. Tampoco es forzable localmente; en AutoCAD basta comprobar que el agua **recta** mantiene ese control mientras la ondulada solo informa.
- [ ] **Admisión conjunta de piezas SPLINE abiertas (S1–S3):** en el **mismo DWG** recargado con `APPLOAD`, cuando una llamada Offset devuelva **varias piezas SPLINE abiertas**, el comando debe intentar **una sola** llamada a `AddRegion` sobre **copias** y aceptar el conjunto únicamente con **exactamente una** región positiva que, además, supere la tolerancia, sea menor que un padre retenido y esté contenida —por Boolean completo— en el original **y** en ese mismo padre mayor, con dedup global del nivel. Al aceptarse, todas las piezas nativas se conservan **editables** como un contorno compuesto (sin `Closed2`, reajuste, polilínea, GROUP ni REGION retenida), el resumen muestra **«Contornos compuestos aceptados: N»** y la región conjunta sobrevive solo hasta procesar los dos signos del nivel siguiente. Cero o varias regiones, asociación ambigua, resultado inválido o no contenido: **fallback conservador**, sin adivinar propiedad, informando el motivo y preservando las ramas individuales válidas. Probar también el control recto `20×10`, cancelación/ESC, limpieza de copias y regiones, y una segunda ejecución sin estado residual. La región nativa conjunta **no certifica** topología, ausencia de lóbulos descartados ni un conteo fijo de niveles.
- [ ] **Colores, variables y residuos:** en esas masas, contorno y copias con RGB **59,130,246** en `MC-MASA-AGUA`; `CMDECHO` y `OSMODE` restaurados; `CLAYER`, `TEXTSTYLE` y UCS sin cambios; sin REGION, DCL ni capas temporales residuales.
- [ ] **Río ondulado abierto:** con `(0,0)-(60,0)-(60,40)` comprobar que la SPLINE final queda **abierta** (extremos distintos, sin Closed2) y con tangentes de extremo alineadas con el primero y el último tramo; repetir con dos puntos `(0,0)-(100,0)`. En centro con total `1`, `3` y `5`, y en límite con total `1` y `3` hacia ambos lados: el total `1` no pide lado ni crea copias; en los demás, medir la longitud real `R` de la curva original, comparar `0.05 × R` con el paso usado que informa la consola y verificar los conteos exactos y el mismo azul, sin curvas cerradas ficticias. Para el recorrido de dos puntos, el paso inicial debe bastar; comprobar normales y Z con UCS rotado/inclinado. Forzar una reducción y cancelar con ESC durante el procesamiento: no deben quedar copias de intentos descartados; repetir de inmediato y verificar variables, rótulo y UNDO.
- [ ] **Regresión sin cambios:** edificaciones y vegetación conservan LWPOLYLINE/contorno y **HATCH** (incluida una edificación poligonal en ambos sentidos); los ríos rectos conservan sus vértices capturados; el agua recta no genera HATCH.
- [ ] **Entrada inválida o cancelación y segundo `MCELEMENTS` inmediato:** rechazar una entrada o cancelar (ESC) y volver a ejecutar el comando **acto seguido, sin un ESC de recuperación intermedio**: el segundo intento abre el diálogo, captura y, con una masa ondulada válida, crea la estructura sin arrastrar el error anterior. Repetir también con un río ondulado para descartar que el error de `Weights` o de perímetro deje estado residual. Registrar conteos, RGB y variables tras ambos intentos.

#### Cancelación, recursos y deshacer

ESC o error retira **solo los objetos y capas creados por esa ejecución**, incluida la REGION temporal, y cierra/descarga/borra el DCL temporal. No se usan comandos encolados de limpieza. Se restaura `CMDECHO`; `OSMODE` se conserva durante los clics y también se restituye al terminar. Si AutoCAD impide borrar un recurso o restaurar variables, se imprime un aviso: revisar el dibujo, no asumir limpieza completa.

Se exige UNDO habilitado: se comprueba **antes de capturar vértices** y nuevamente antes de crear resultados. Sin grupo abierto, el comando inicia una marca propia después de validar la entrada y antes de escribir en el dibujo; solo cierra esa marca. En ese caso, **un solo `UNDO` debe retirar la ejecución**, incluidas sus capas nuevas, sin tocar objetos anteriores. Cancelar el diálogo o dar entrada inválida no inicia una marca. Si falla el inicio, no se crean resultados; si falla el cierre, se advierte que no se garantiza un deshacer único.

Con un **grupo UNDO previo abierto**, se incorpora a él sin llamar a StartUndoMark ni EndUndoMark: el grupo ajeno **permanece abierto**. Antes de dibujar se advierte que un `UNDO` posterior puede afectar **todas las acciones previas de ese grupo**, además de esta ejecución; no se promete deshacerla de forma aislada. Se reconsulta el grupo antes de crear resultados y se advierte si apareció durante la captura. El comando no ejecuta `UNDO`, no cierra ni reclama grupos ajenos y no presupone quién los abrió. El rollback ante ESC/error sigue retirando solo objetos y capas propios, también dentro del grupo heredado.

#### Verificación manual pendiente (T4/T5/T6)

No hay runtime AutoCAD ni runner, linter, build o CI disponible. La lectura y los controles estructurales no prueban DCL, ActiveX, REGION, HATCH ni UNDO. **Todas las casillas siguientes están sin comprobar**. Usar un DWG aislado con objetos/capas preexistentes y registrar entidades, propiedades, conteos y variables antes/después; no bastan capturas de pantalla. Los ejemplos oficiales de [AddRegion](https://help.autodesk.com/cloudhelp/2020/ENU/AutoCAD-ActiveX-Reference/files/GUID-74C8765E-EB4A-4773-ADD4-6C0F318FE6BE.htm) también deben ejecutarse allí, nunca como prueba automatizada inferida.

**Reprueba de S19/UNDO (pendiente):** el segundo reporte (L20) terminó sin resultados tras «Primer vértice del polígono» y cuatro peticiones «Siguiente vértice <Enter para cerrar>», con `Cierre el grupo UNDO existente antes de ejecutar MCELEMENTS.`. Es evidencia funcional negativa, no reproducida localmente; no se conoce quién abrió aquel grupo.

- [ ] **S19, secuencia L20:** recargar con `APPLOAD` y repetir los mismos clics/Enter y opciones del DWG original, registrándolos porque el log no los detalla. Con grupo abierto debe aparecer la advertencia antes del primer vértice y generarse la estructura, sin el rechazo anterior.
- [ ] **S19/S2, grupo heredado controlado:** en un DWG aislado, abrir explícitamente un grupo con `UNDO` → `Begin` y realizar acciones de prueba identificables antes de MCELEMENTS. Registrar handles, propiedades, variables y `UNDOCTL`. Probar éxito, ESC en captura/procesamiento y un error de creación (por ejemplo, capa destino bloqueada), repitiendo el comando. Verificar que bit 8 sigue activo, no hubo cierre forzado ni cambios/deshacer de acciones anteriores y solo se retiran recursos propios al cancelar/fallar. Cerrar después el grupo **manualmente** con `UNDO` → `End` y comprobar que un UNDO puede retirar también aquellas acciones previas, como advertía el mensaje.
- [ ] **S19/S2, marca propia y UNDO deshabilitado:** sin grupo abierto, probar éxito y un solo UNDO: retira únicamente esa ejecución y sus capas nuevas; repetir el comando. Cancelar diálogo y rechazar entradas inválidas no debe abrir marca; ESC/error conserva objetos anteriores. Deshabilitar UNDO en el DWG de prueba: debe rechazar antes de pedir vértices, sin resultados; rehabilitarlo manualmente. Registrar estado y restauración de variables.

**Reprueba de los fallos reportados S17/S18 (pendiente):** el usuario observó falta de visualización y el error `Argumento no válido textGenFlag en IAcadText::put_TextGenerationFlag`. Es evidencia funcional negativa; sin AutoCAD no se ha reproducido aquí ni confirmado la corrección. Repetir primero estos casos y después las regresiones T4/T5/T6:

- [ ] **S17/S18, secuencia reportada:** recargar con `APPLOAD`, elegir polígono con texto/tag y repetir el primer vértice y las **cinco peticiones «Siguiente vértice <Enter para cerrar>»** del reporte, con los mismos clics/Enter del DWG original. Verificar lados capturados visibles y cierre provisional distinto desde el tercer vértice; al terminar deben aparecer contorno y rótulo centrado sin error `textGenFlag`, sin vectores residuales. Registrar estructura, opciones, coordenadas y resultado real; el log original no detalla esos valores.
- [ ] **S17, captura compartida:** probar clics, coordenadas escritas y OSNAP, repetir el primer punto para cerrar, UCS rotado/inclinado y clics con Z distinta: vista y resultado conservan la proyección horizontal WCS a la Z inicial. Pan/zoom puede borrar la vista hasta el siguiente vértice. Río recto/ondulado: solo tramos abiertos. Agua ondulada: vista recta y resultado suavizado, sin alterar curvas, separación ni colores. Octágono: centro/radio y norte WCS sin cambios.
- [ ] **S18/S7/S13, rótulos compartidos:** en edificaciones, vegetación y masa de agua probar ninguno/texto/tag; en ríos ninguno/texto. Incluir estilos existentes reflejados, boca abajo, con altura fija, ancho y oblicuo distintos, y tags cortos/largos. Comprobar orientación normal, altura explícita, posición interior certificada en polígonos y rótulo paralelo y por fuera en ríos, círculo medido sin recorte y definición del estilo intacta. Ninguno no crea TEXT/CIRCLE ni hueco; las tramas, contornos y colores deben conservarse.
- [ ] **S17/S18/S2, limpieza y diferencial:** en DWG aislado conservar conteos, handles y variables de referencia; ESC durante vértices (con vista visible), centro/radio y procesamiento, además de entrada degenerada/rechazada. Sin vectores ni resultados propios residuales, y sin borrar objetos previos. Tras éxito sin grupo previo, un UNDO retira solo esa ejecución; con grupo heredado, aplicar las comprobaciones S19 anteriores. Registrar `CMDECHO`/`OSMODE` antes/después y `CLAYER`/`TEXTSTYLE`/UCS sin cambios; comparar captura polígono/río y rótulos de todas las estructuras contra la base, incluidos rechazos y conteos. Esta comparación sigue sin ejecutarse.

- [ ] **S1:** cargar solo este script; comprobar mensaje, diálogo, sus seis opciones y creación de entidades nuevas en modelo, papel y ventana flotante. Alternar agua→edificación→agua: recta/ondulada se deshabilita y conserva su valor; el contenido del rótulo también se conserva.
- [ ] **S3/S4/S15:** crear los cuatro tipos; revisar ANSI31/ANSI37/ANSI31/ANSI36, PatternAngle=0, PatternScale y RGB exacto de la trama verde. Contorno y rótulos en su capa, sin recolorear entidades anteriores.
- [ ] **S3:** octágono de centro `(20,30,5)` y radio 10: ocho vértices, primero `(20,40,5)`, área `200 × sqrt(2)`, centroide `(20,30,5)`. Repetir con UCS rotado e inclinado: la figura sigue horizontal al norte WCS.
- [ ] **S7/S13:** probar los tres rótulos excluyentes y contenido vacío; ningún rótulo, un TEXT o un CIRCLE más TEXT. Trapecio `(0,0)-(10,0)-(6,4)-(0,4)`: área 32 y centroide `(4.083333…,1.833333…)`, también en sentido inverso y elevación 100. Cóncavo con centroide exterior: el rótulo se reubica dentro y la consola lo informa (detalle en los casos S1–S2).
- [ ] **S14:** cuadrado 10×10 con factores 0.5/1/2: escalas 0.1/0.2/0.4 y alturas iniciales 0.2/0.4/0.8 para texto sin círculo, 0.325/0.65/1.3 para tag; medir radio con tag corto y largo, distintos estilos y altura fija. Contorno sin cambios; zoom y objetos lejanos no influyen.
- [ ] **S2/S14/S15:** valores inválidos (`1abc`, `0`, `-1`, `0,5`, vacío), polígonos cruzados/tocados/degenerados y capas destino apagadas/congeladas/bloqueadas: rechazo sin salida parcial. Capa existente usable conserva todas sus propiedades. Revisar también coordenadas UTM y precisión de REGION.
- [ ] **S2:** ESC en diálogo, primer punto, vértices, centro/radio y procesamiento; repetir ejecución. Sin REGION, DCL, capas nuevas ni resultados residuales; objetos previos intactos, `CMDECHO`/`OSMODE` restaurados y `CLAYER`/`TEXTSTYLE`/UCS sin cambios.
- [ ] **S2/S19:** sin grupo previo, éxito seguido de un solo `UNDO`: retirar contorno, trama, rótulo y capas creadas, conservando lo anterior. Con UNDO deshabilitado o grupo previo abierto, seguir los casos S19 anteriores (rechazo antes de captura o incorporación advertida sin cierre, respectivamente). Si se puede provocar un error de limpieza, comprobar aviso explícito y examinar los recursos supervivientes.

**Casos adicionales T5, también sin comprobar:**

- [ ] **S5/S11:** rectángulo WCS `(0,0)-(20,0)-(20,10)-(0,10)`, recta, Z=0: `A=200`, `d=sqrt(200)/20≈0.70710678`. Resultado ideal del motor: contorno + 7 interiores, último rectángulo de dimensiones `20−14d` por `10−14d`; no debe aparecer un octavo degenerado o exterior. Verificar coordenadas, áreas, contención y distancias reales; registrar cualquier aviso de Offset, no inferir éxito del conteo esperado.
- [ ] **S16:** forma estrecha con dos lóbulos: `(0,0)-(8,0)-(8,3)-(12,3)-(12,0)-(20,0)-(20,8)-(12,8)-(12,5)-(8,5)-(8,8)-(0,8)`. `A=136`, `d≈0.58309519`; al desaparecer el puente deben conservarse ambas partes válidas y continuar dentro de cada una. Revisar cada frontera mediante REGION/Boolean de copias en el DWG; ningún fragmento exterior ni simplemente menor se acepta. Repetir L/U y sentidos inversos.
- [ ] **S8/S12/S7:** mismos clics en recta/ondulada: recta conserva vértices, ondulada es SPLINE cerrada suave también en la unión. Comparar área y centroide del rótulo con REGION de la **curva final**, no del polígono de entrada. Provocar una curva final inválida y comprobar rechazo sin temporales; si Closed2 falta, mensaje de incompatibilidad sin degradación.
- [ ] **S5/S14/S15:** repetir la misma masa con factores 0.5/1/2: idénticas curvas, conteo y separación, solo altura/tag cambian. Contorno y todos los interiores RGB59,130,246 en `MC-MASA-AGUA`; TEXT/CIRCLE ByLayer. Capa existente y geometría previa conservan definición, propiedades y handles; capa bloqueada se rechaza. Repetir en UTM, Z=100, UCS rotado/inclinado y ambos espacios.
- [ ] **S2:** ESC durante captura, suavizado y desfases: sin resultados/REGION/copias/capas propias residuales, DCL retirado y variables restauradas. Tras éxito sin grupo previo, un solo UNDO retira toda la ejecución, no lo anterior; con grupo heredado, verificar la agrupación compartida según S19. Registrar también errores Offset, límites y fallos de borrado; un aviso de resultado no certificado no equivale a relleno completo.

**Casos adicionales T6, también sin comprobar:**

- [ ] **S6/S9/S10:** eje `(0,0)-(100,0)`; centro 3/5 y límite 3 a Norte/Sur: comprobar los totales y coordenadas del ejemplo anterior. Repetir invirtiendo los clics, con total 1 en ambos modos (sin petición de lado), Z=100, UTM y UCS rotado/inclinado. Consultar propiedades: curvas abiertas, RGB59,130,246 en MC-RIO y separación 5; ningún cierre ficticio.
- [ ] **S2/S10:** centro 2/4 no sale del diálogo, no crea nada ni altera variables. Rechazar cantidad vacía, `0`, `-1`, `+3`, `2.5`, `1abc`, `1e2`, espacios y `2147483648`. Alternar río inválido→edificación/masa: no se valida cantidad deshabilitada; volver y comprobar conservación exacta del texto y modo. Polígono con círculo/tag→río→polígono restaura la selección del tag.
- [ ] **S8/S12:** abiertas de 2 y 3 puntos en recta/ondulada: LWPOLYLINE/SPLINE abierta, sin pérdida de puntos en recta y ajuste continuo en ondulada. Probar cruz, retroceso, cierre y controles no certificables: rechazo íntegro. Masa ondulada sigue cerrándose suavemente con Closed2.
- [ ] **S7/S13/S14:** quebrada `(0,0)-(60,0)-(60,40)` con texto: ancla en la mitad de longitud `(50,0)`, girada y desplazada por fuera del conjunto. Ninguno/texto solamente, sin círculos. Repetir sobre SPLINE y medir la mitad de longitud real; factores 0.5/1/2 cambian solo altura. Rótulo ByLayer, curvas azules; no cambia CLAYER/TEXTSTYLE/UCS.
- [ ] **S2/S6:** lado sobre el eje y prolongación tangente ambigua: rechazo sin resultados. Probar ambos lados de una quebrada y ambos sentidos. Ante Offset fragmentado, inexistente, no certificable o fallo a mitad del conteo, toda la ejecución desaparece y no se anuncia un total diferente. Revisar cantidad exacta de curvas excluyendo el TEXT.
- [ ] **S2/S15:** ESC al elegir lado, al suavizar y durante copias; comprobar variables, DCL, capas/curvas propias retiradas y objetos previos intactos. Sin grupo previo, una ejecución correcta se retira con un solo UNDO; con grupo heredado, verificar la agrupación compartida según S19. Probar capa MC-RIO existente y bloqueada, conservando sus propiedades y entidades anteriores.

**Casos adicionales S1–S2 (rótulo interior), también sin comprobar.** Ninguno declara apariencia: cada casilla exige medir geometría real y contar entidades temporales. Abrir un DWG aislado y registrar antes/después los **conteos por tipo** (`LWPOLYLINE`, `SPLINE`, `HATCH`, `TEXT`, `CIRCLE`, `REGION`) y los handles: al terminar, el conteo de REGION debe volver al valor inicial y el de HATCH coincidir con el de estructuras creadas.

- [ ] **S3/S4 tamaño del tag:** repetir la misma figura, estilo, contenido `A` y factor visual respecto de la versión anterior a los aumentos. Si hay espacio suficiente y no se informa reducción, la altura del texto, el radio del círculo y su margen deben medir 1.625 veces los originales (1.3 veces respecto del primer aumento), sin cambiar la proporción letra/círculo ni la escala del HATCH. Texto sin círculo, sin rótulo y río con texto mantienen sus tamaños previos. En una figura estrecha sigue aplicándose el ajuste interior: el aumento final puede ser menor.
- [ ] **S1 convexo, texto y tag:** cuadrado `(0,0)-(10,0)-(10,10)-(0,10)` con tag corto y factor `1`. Comprobar en propiedades que el TEXT es una sola línea, `Rotation=0`, justificación media-centro, y que **caja WCS** (`GetBoundingBox`) del TEXT y del CIRCLE quedan completas dentro de la LWPOLYLINE; con `LIST`/`DIST` verificar que el hueco del HATCH es un bucle interior de radio `radio del tag + 20 %` y que el patrón no atraviesa el rótulo. Repetir invirtiendo el sentido de captura (misma área, mismo resultado dentro de la tolerancia).
- [ ] **S1 cóncavo L con centroide exterior:** L de brazos de 6 y caja 20×20, `(0,0)-(20,0)-(20,6)-(6,6)-(6,20)-(0,20)`, con texto y tag corto, factor `1`. Área `204` y centroide real `(121/17, 121/17) = (7.117647…, 7.117647…)`, que cae en el cuadrante ausente (`x > 6`, `y > 6`): está **fuera** del polígono. Evidencia aritmética por fórmula del polígono (shoelace) y clasificación de punto, **no** prueba en AutoCAD. Comprobar que el rótulo **no** queda en el centroide, que la consola informa **«reubicado»**, y que sin reducción la posición aceptada está a una distancia al contorno mayor o igual que la envolvente; el cuadrado de esquina `6×6` y los brazos dejan `3` unidades de holgura a los bordes. Verificar con `REGION` de una copia que el disco del rótulo no toca el contorno.
- [ ] **S1 cóncavo U con centroide exterior:** U abierta hacia arriba con brazos de 6, `(0,0)-(20,0)-(20,20)-(14,20)-(14,6)-(6,6)-(6,20)-(0,20)`, con texto y tag corto, factor `1`. Área `288` y centroide real `(10, 53/6) = (10, 8.833333…)`, que cae en la **cavidad** `x ∈ (6,14)`, `y > 6`: también **fuera** del polígono (aritmética, no AutoCAD). Repetir las mismas comprobaciones: reubicación informada, centro distinto del centroide, holgura de `3` unidades en base y brazos, y certificado del disco contra la REGION del contorno. Repetir ambos fixtures en sentido inverso de captura y verificar que el resultado no depende del sentido.
- [ ] **S2 estrecho con tag largo y reducción:** pasillo de `2 × 40` (o el ancho que fuerce el ajuste) con tag largo y factor `1`. Debe informar el **porcentaje de reducción**; medir altura del TEXT y radio del CIRCLE y confirmar que ambos bajaron con el **mismo factor** respecto del tamaño inicial pedido (`0.065 × L × f` para el tag y su radio). Comprobar que el hueco sigue el tamaño reducido y que el texto completo está dentro del círculo y del contorno. Repetir hasta provocar el fallo explícito con un polígono mínimo: el mensaje debe ser propio («no caben completos … ni al 25 %») y **no** debe quedar ninguna entidad ni REGION.
- [ ] **S1/S2 sin rótulo, solo texto y solo tag:** con `Sin rótulo` no se crea TEXT, CIRCLE ni bucle interior, y el HATCH conserva el resultado previo. Con `Texto centrado` el hueco es **rectangular** y no hay CIRCLE. Con `Círculo con tag centrado` el hueco es **circular** y el texto queda centrado en el tag. En los tres casos comparar contorno, patrón, escala y capas contra la base: solo debe cambiar lo indicado.
- [ ] **Estilos y medición real:** repetir el mismo cuadrado y tag con estilos de ancho `0.5`/`2` y oblicuidad `15°`/`30°`, más un estilo con altura fija. El radio del tag y el hueco deben **cambiar con la caja medida** aunque la altura pedida sea la misma; la definición del estilo no se altera y `TEXTSTYLE`/`CLAYER` no cambian. Verificar además con un tag de una sola letra y otro de veinte caracteres.
- [ ] **Cota, UCS y ambos espacios:** Z=100, UTM y UCS rotado/inclinado. El rótulo, el hueco y el CIRCLE deben quedar a la Z del contorno y horizontales en WCS (`Rotation=0`, sin reflejo), y la certificación debe seguir usando WCS. Repetir en espacio papel y en ventana flotante.
- [ ] **Masa de agua sin cambios en desfases:** masa recta y ondulada con texto y tag: el rótulo debe quedar dentro del contorno **final** (no del polígono capturado en ondulada), y los desfases interiores deben conservar exactamente su conteo, geometría y RGB59,130,246. No debe aparecer ningún HATCH ni bucle interior en esta estructura. Comparar cada curva contra la base por handles de referencia del mismo DWG.
- [ ] **Rótulo de río paralelo y exterior (S1–S2), sin comprobar:** cargar `lisp/MC-ELEMENTS.lsp` con `APPLOAD` en un DWG aislado, elegir `Ríos` + `Texto paralelo al río` y factor `1`. Registrar antes/después los conteos por tipo (`LWPOLYLINE`, `SPLINE`, `TEXT`, `CIRCLE`, `REGION`) y los handles: al terminar no debe quedar ninguna LWPOLYLINE temporal del certificado, ni CIRCLE, ni REGION.
  1. **Horizontal, ambos sentidos:** `(0,0)-(100,0)` y el inverso `(100,0)-(0,0)` con Centro `3`: `R=100`, `h=4`, holgura `2`. Las líneas quedan en `Y=-5,0,5`; el TEXT debe medir 4 de alto, quedar **paralelo** (`Rotation=0` en ambos sentidos), centrado en `X=50` y con el centro en `Y≈9`, es decir borde inferior `≈7`, dos unidades sobre la línea exterior `Y=5`. Invertir los clics no debe moverlo al otro lado. Con `5` (copias hasta `Y=±10`) el centro sube a `Y≈14`.
  2. **Vertical, ambos sentidos:** `(0,0)-(0,100)` y `(0,100)-(0,0)` con Centro `3`: `Rotation=90`, legible de abajo hacia arriba, a la **izquierda** (`X` negativa, fuera de `X=0,±5`) en ambos sentidos.
  3. **Oblicuo y ondulado:** quebrada `(0,0)-(60,0)-(60,40)` y río Ondulada de 5–7 puntos: la rotación sigue la **tangente de la mitad de la longitud** y el texto queda fuera de la línea más externa **real**, aunque Ondulada haya reducido el paso; ningún tramo del río cruza el rectángulo del texto. Repetir con `Total 1` en Centro y en Límite: sin copias, el rótulo queda junto al eje y no se pide lado.
  4. **Centro/Límite y totales:** `1`, `3`, `5` en Centro (impar) y Límite hacia los dos lados, incluidos los recorridos invertidos: en Límite el rótulo se separa del conjunto **real de ese lado**, no del nominal.
  5. **Estilos y caja:** estilos de ancho `0.5`/`2`, oblicuidad `15°`/`30°` y altura fija; un texto largo desplaza **más** el rótulo porque la caja medida es mayor, y la holgura sigue siendo la mitad del alto medido. Añadir un texto con descendentes (`gjpq`) y otro sin ellos: el centro de la caja medida no coincide con el punto medio-centro del ancla, y aun así el **centro de la caja** debe quedar en la posición certificada y la holgura perpendicular debe medir la mitad del alto. `TEXTSTYLE`, `CLAYER` y la definición del estilo no cambian.
  6. **Z, UCS y espacios:** Z=100, UTM y UCS rotado/inclinado: el TEXT conserva la Z del eje y la rotación se mide en WCS. Repetir en espacio papel.
  7. **Cancelación, fallo y recursos:** ESC durante las copias y durante el certificado; forzar el fallo de posición (estilo de altura fija grande junto a un conjunto ancho) y comprobar que el mensaje es propio y que se retiran TEXT, rectángulo temporal, curvas y capas propias. Los fallos de **estado de borrado** ilegible, **tipo ilegible** o conjunto **vacío/sin el eje** no se pueden provocar desde el diálogo: se comprueban por lectura del código, sin simularlos. Tras un éxito sin grupo previo, un solo `UNDO` retira la ejecución completa.
  8. **Sin rótulo y regresión de polígonos:** `Sin rótulo` no crea TEXT ni rectángulo temporal; `Texto centrado` y `Círculo con tag centrado` en edificaciones, área verde y masa de agua conservan `Rotation=0`, justificación media-centro, hueco de trama y tamaños `0.04`/`0.065`, y ningún polígono gana rotación ni desplazamiento.
- [ ] **ESC, UNDO y temporales:** cancelar con ESC durante la búsqueda del rótulo y durante la evaluación del HATCH. Después, el conteo de REGION debe volver al inicial, no debe quedar ningún CIRCLE/LWPOLYLINE de hueco ni TEXT a medias, el DCL debe estar retirado y `CMDECHO`/`OSMODE` restaurados. Tras un éxito sin grupo previo, un solo `UNDO` retira contorno, trama, rótulo y capas creadas. El fallo explícito del rótulo también debe retirar todo lo propio.

Las regresiones manuales T4 y T5 anteriores siguen obligatorias: se compartieron diálogo y constructor LWPOLYLINE (ahora cierre explícito), aunque Closed2, REGION/Boolean y tramas conservan sus rutas. No pudo ejecutarse comparación funcional/diferencial contra la base porque no hay AutoCAD disponible; **no se considera aprobada**. La ruta de rótulo **sí** cambió respecto de la base: el centroide ya no se conserva cuando la envolvente completa no cabe y el tag se mide con `GetBoundingBox` en lugar de `textbox`, así que ningún resultado manual anterior sobre rótulos de polígono cubre este código. El rótulo de río también cambió: ya no es un TEXT horizontal en la mitad de longitud, sino uno paralelo al tramo y desplazado por fuera del conjunto, así que las observaciones anteriores de ríos tampoco lo cubren.

## Estructura del repositorio

```
lisp/           # Scripts .lsp (el producto)
cuix/icons/     # Iconos para botones CUIX (pendiente)
```

## Licencia

MIT
