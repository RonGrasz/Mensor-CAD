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

## Estructura del repositorio

```
lisp/           # Scripts .lsp (el producto)
cuix/icons/     # Iconos para botones CUIX (pendiente)
```

## Licencia

MIT
