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

## Estructura del repositorio

```
lisp/           # Scripts .lsp (el producto)
cuix/icons/     # Iconos para botones CUIX (pendiente)
```

## Licencia

MIT
