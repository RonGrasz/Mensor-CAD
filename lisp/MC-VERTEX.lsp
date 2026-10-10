;;; ============================================================
;;; MC-VERTEX.LSP - Círculos y etiquetas de vértices
;;; Comando: MCVERTEX
;;; Requiere: AutoCAD 64-bit con ActiveX/VLA (vl-load-com)
;;; ============================================================
;;;
;;; Dibuja un CIRCLE centrado en la coordenada exacta de cada vértice
;;; de una fuente planar horizontal (LWPOLYLINE cerrada o abierta,
;;; LINE, o contorno generado con -BOUNDARY desde un punto interior)
;;; y, opcionalmente, una etiqueta "PREFIJO-n" cerca del vértice,
;;; después del círculo y sobre el lado exterior del contorno,
;;; paralela a la dirección de salida y legible. La caja real del texto
;;; se mide con TEXTBOX y debe quedar completa fuera del polígono y sin
;;; invadir ningún círculo; si no existe posición segura dentro de una
;;; búsqueda acotada, la etiqueta se omite con un aviso identificatorio.
;;;
;;; Convenciones:
;;;   - Cierres: origen en el vértice real más cercano y recorrido
;;;     horario (según área con signo en WCS XY).
;;;   - Cierre por imán: una LWPOLYLINE sin bandera de cierre, con al menos
;;;     cuatro vértices y extremos dentro de la tolerancia, se anota como
;;;     circuito horario desde el vértice elegido, sin modificar la fuente.
;;;   - Abiertos reales: origen en el extremo más cercano al clic; se
;;;     preserva la continuidad de todos los vértices.
;;;   - Los clics en UCS se transforman a WCS; las coordenadas de la
;;;     fuente se leen en OCS y se convierten a WCS.
;;;
;;; Limitaciones (documentadas, no silenciadas):
;;;   - Solo fuentes planas horizontales (extrusión +Z y Z constante).
;;;     Se rechazan explícitamente entidades inclinadas o reflejadas
;;;     (normal -Z) en lugar de proyectarlas.
;;;   - No se soporta la POLYLINE antigua ni geometría 3D.
;;;   - Los arcos (bulge) se tratan por la cuerda entre vértices; no se
;;;     crean vértices nuevos sobre los arcos. La comprobación de
;;;     exterior/colisión usa esas cuerdas, no la curva real del arco.
;;;   - No hay transformación geodésica: el dibujo ya debe estar en el
;;;     CRS previsto.

(vl-load-com)

;;; ============================================================
;;; SECCIÓN 1: ARCHIVO DCL TEMPORAL
;;; ============================================================

(defun mcvertex:escribir-dcl (ruta-dcl / f lineas)
  "Escribe el diálogo DCL temporal en RUTA-DCL. Devuelve T si pudo."
  (setq f (open ruta-dcl "w"))
  (if (null f)
    nil
    (progn
      (setq lineas
        '("mcvertex_dlg : dialog {"
          "  label = \"MCVERTEX - Círculos y etiquetas de vértices\";"
          "  width = 60;"
          "  : boxed_radio_column {"
          "    label = \"Tipo de fuente\";"
          "    : radio_button { key = \"rb_cerrada\";  label = \"Polilínea ligera cerrada\"; value = \"1\"; }"
          "    : radio_button { key = \"rb_linea\";    label = \"Línea (LINE)\"; }"
          "    : radio_button { key = \"rb_abierta\";  label = \"Polilínea ligera abierta\"; }"
          "    : radio_button { key = \"rb_contorno\"; label = \"Contorno desde punto interior\"; }"
          "  }"
          "  : boxed_column {"
          "    label = \"Geometría y origen\";"
          "    : row {"
          "      : button { key = \"btn_geom\"; label = \"Seleccionar geometría...\"; fixed_width = true; width = 26; }"
          "      : text { key = \"lbl_geom\"; label = \"Sin seleccionar\"; width = 30; }"
          "    }"
          "    : row {"
          "      : button { key = \"btn_origen\"; label = \"Seleccionar origen...\"; fixed_width = true; width = 26; }"
          "      : text { key = \"lbl_origen\"; label = \"Predeterminado\"; width = 30; }"
          "    }"
          "    : row {"
          "      : text { label = \"Tolerancia (m):\"; }"
          "      : edit_box { key = \"eb_tol\"; value = \"0.001\"; width = 8; edit_width = 6; }"
          "    }"
          "  }"
          "  : boxed_column {"
          "    label = \"Apariencia\";"
          "    : row {"
          "      : text { label = \"Radio:\"; }"
          "      : edit_box { key = \"eb_radio\"; value = \"1.0\"; width = 8; edit_width = 6; }"
          "      : toggle { key = \"ck_etiquetas\"; label = \"Mostrar etiquetas\"; value = \"1\"; }"
          "    }"
          "    : row {"
          "      : text { label = \"Prefijo etiquetas:\"; }"
          "      : edit_box { key = \"eb_prefijo\"; value = \"E\"; width = 8; edit_width = 6; }"
          "    }"
          "  }"
          "  ok_cancel;"
          "}"))
      (foreach l lineas (write-line l f))
      (close f)
      T)))

;;; ============================================================
;;; SECCIÓN 2: UTILIDADES GEOMÉTRICAS PURAS (sin dependencia de UCS)
;;; ============================================================

(defun mcvertex:dist2d (p1 p2 / dx dy)
  "Distancia plana entre P1 y P2."
  (setq dx (- (car p2) (car p1))
        dy (- (cadr p2) (cadr p1)))
  (sqrt (+ (* dx dx) (* dy dy))))

(defun mcvertex:nthcdr (n lst)
  (while (and (> n 0) lst)
    (setq lst (cdr lst)
          n   (1- n)))
  lst)

(defun mcvertex:firstn (n lst / r)
  (setq r '())
  (while (and (> n 0) lst)
    (setq r   (append r (list (car lst)))
          lst (cdr lst)
          n   (1- n)))
  r)

(defun mcvertex:rotar (lst n / len)
  "Rota la lista N posiciones a la izquierda."
  (setq len (length lst))
  (if (or (zerop len) (zerop n))
    lst
    (append (mcvertex:nthcdr n lst) (mcvertex:firstn n lst))))

;; Área con signo (shoelace) en el plano XY del WCS. Positiva = CCW.
(defun mcvertex:area-firmada (verts / n s i p1 p2)
  (setq n (length verts)
        s 0.0
        i 0)
  (while (< i n)
    (setq p1 (nth i verts)
          p2 (nth (rem (1+ i) n) verts))
    (setq s (+ s (- (* (car p1) (cadr p2)) (* (car p2) (cadr p1)))))
    (setq i (1+ i)))
  (* 0.5 s))

(defun mcvertex:idx-mas-cercano (pt verts / i mejor dist-min d)
  "Índice del vértice de VERTS más cercano a PT (plano XY)."
  (setq i 0 mejor 0 dist-min 1.0e308)
  (foreach v verts
    (setq d (mcvertex:dist2d pt v))
    (if (< d dist-min)
      (setq dist-min d
            mejor    i))
    (setq i (1+ i)))
  mejor)

;; Prueba punto-en-polígono por lanzamiento de rayo (plano XY).
(defun mcvertex:pt-en-poligono (pt verts / n i j inside x y xi yi xj yj)
  (setq n (length verts)
        i 0
        inside nil
        x (car pt)
        y (cadr pt))
  (while (< i n)
    (setq xi (car (nth i verts))
          yi (cadr (nth i verts))
          j  (rem (1+ i) n)
          xj (car (nth j verts))
          yj (cadr (nth j verts)))
    (if (and (or (and (> yi y) (<= yj y)) (and (> yj y) (<= yi y)))
             (< x (+ xi (/ (* (- xj xi) (- y yi)) (- yj yi)))))
      (setq inside (not inside)))
    (setq i (1+ i)))
  inside)

;; Ángulo plano en WCS [0, 2pi); independiente de ANGBASE/ANGDIR y del UCS.
(defun mcvertex:angulo (p1 p2 / dx dy a)
  (setq dx (- (car p2) (car p1))
        dy (- (cadr p2) (cadr p1)))
  (if (and (zerop dx) (zerop dy))
    0.0
    (progn
      (setq a (atan dy dx))
      (if (< a 0.0) (setq a (+ a (* 2.0 pi))))
      a)))

;; Normaliza el ángulo de texto para que nunca quede boca abajo.
;; Devuelve (rotacion . invertido): si el texto se voltea 180°, el
;; llamador debe justificarlo a la derecha para conservar el avance.
(defun mcvertex:normalizar-angulo (ang / r flip)
  (setq r ang
        flip nil)
  (if (and (>= r (/ pi 2.0)) (< r (/ (* 3.0 pi) 2.0)))
    (progn (setq r (- r pi) flip T))
    (if (>= r (/ (* 3.0 pi) 2.0))
      (setq r (- r (* 2.0 pi)))))
  (list r flip))

;; Punto a distancia DIST y ángulo ANG desde PT, en WCS (sin usar polar).
(defun mcvertex:polar-wcs (pt ang dist)
  (list (+ (car pt) (* dist (cos ang)))
        (+ (cadr pt) (* dist (sin ang)))
        (caddr pt)))

;;; ============================================================
;;; SECCIÓN 2b: ENTRADA NUMÉRICA ESTRICTA
;;; ============================================================

;; Convierte TXT en un real positivo o devuelve nil. Acepta un signo
;; opcional, dígitos y un único punto decimal; rechaza texto sobrante,
;; exponentes, comas y valores <= 0. Evita el silencio de atof ante
;; entradas como "1abc". No aplica conversión de unidades.
(defun mcvertex:parsear-positivo (txt / s len i c punto digitos valido val)
  (setq s (if txt (vl-string-trim " \t" txt) "")
        len (strlen s)
        i 1
        punto nil
        digitos 0
        valido T)
  ;; Signo opcional inicial (el signo negativo se rechaza por valor <= 0).
  (if (and (>= len 1)
           (member (substr s 1 1) '("+" "-")))
    (setq i 2))
  (while (and (<= i len) valido)
    (setq c (substr s i 1))
    (cond
      ((and (>= (ascii c) 48) (<= (ascii c) 57))
       (setq digitos (1+ digitos)))
      ((and (= c ".") (not punto))
       (setq punto T))
      (T (setq valido nil)))
    (setq i (1+ i)))
  (if (or (not valido) (zerop digitos))
    nil
    (progn
      (setq val (atof s))
      (if (> val 0.0) val nil))))

;;; ============================================================
;;; SECCIÓN 3: LECTURA DE FUENTES (OCS -> WCS, validación planar)
;;; ============================================================

;; Lectura silenciosa de una LWPOLYLINE horizontal. Devuelve
;; (vertices-wcs cerrada) o nil si no es soportada.
(defun mcvertex:leer-lwpoly (ent / ed nor elev verts par)
  (setq ed (entget ent))
  (if (and ed (/= "LWPOLYLINE" (cdr (assoc 0 ed))))
    nil
    (progn
      (setq nor (cdr (assoc 210 ed)))
      (if (null nor) (setq nor '(0.0 0.0 1.0)))
      (if (not (equal nor '(0.0 0.0 1.0) 1e-6))
        nil
        (progn
          (setq elev (cdr (assoc 38 ed)))
          (if (null elev) (setq elev 0.0))
          (setq verts '())
          (foreach par ed
            (if (= (car par) 10)
              (setq verts
                (append verts
                  (list (trans (list (cadr par) (caddr par) elev) ent 0))))))
          (if (< (length verts) 2)
            nil
            (list verts
                  (not (zerop (logand 1
                    (if (assoc 70 ed) (cdr (assoc 70 ed)) 0)))))))))))

;; Lectura silenciosa de una LINE horizontal. Devuelve (p1 p2) en WCS.
(defun mcvertex:leer-line (ent / ed nor p1 p2)
  (setq ed (entget ent))
  (if (and ed (/= "LINE" (cdr (assoc 0 ed))))
    nil
    (progn
      (setq nor (cdr (assoc 210 ed)))
      (if (null nor) (setq nor '(0.0 0.0 1.0)))
      (setq p1 (cdr (assoc 10 ed))
            p2 (cdr (assoc 11 ed)))
      (if (and (equal nor '(0.0 0.0 1.0) 1e-6)
               p1 p2
               (equal (caddr p1) (caddr p2) 1e-6))
        (list p1 p2)
        nil))))

(defun mcvertex:extraer-lwpoly (ent / r)
  "LWPOLYLINE validada con aviso. Devuelve (ent verts cerrada) o nil."
  (setq r (mcvertex:leer-lwpoly ent))
  (if (null r)
    (progn
      (alert (strcat "Entidad no soportada.\n"
                     "Se requiere una LWPOLYLINE horizontal (normal +Z)."))
      nil)
    (list ent (car r) (cadr r))))

(defun mcvertex:extraer-line (ent / r)
  "LINE validada con aviso. Devuelve (ent verts nil) o nil."
  (setq r (mcvertex:leer-line ent))
  (if (null r)
    (progn
      (alert (strcat "Entidad no soportada.\n"
                     "Se requiere una LINE horizontal (misma cota Z y normal +Z)."))
      nil)
    (list ent r nil)))

;;; ============================================================
;;; SECCIÓN 4: CONTORNO CON -BOUNDARY (temporales y limpieza)
;;; ============================================================

;; Entidades creadas después de ANTES (incluye islas). ANTES nil => todo.
(defun mcvertex:nuevas-entidades (antes / e lst)
  (setq e (if antes (entnext antes) (entnext)))
  (while e
    (setq lst (cons e lst)
          e   (entnext e)))
  (reverse lst))

;; Cola REAL de la base de datos (último objeto, incluidas subentidades).
;; entlast puede devolver solo la última entidad principal; se avanza con
;; entnext hasta el final. Devuelve nil si el dibujo está vacío.
(defun mcvertex:cola-bd ( / e sig)
  (setq e (entlast))
  (if e
    (progn
      (while (setq sig (entnext e))
        (setq e sig))
      e)
    nil))

;; Borrado tolerante: entidades ya eliminadas o subentidades no abortan.
(defun mcvertex:borrar (e)
  (if e
    (vl-catch-all-apply 'entdel (list e)))
  nil)

;; Elige el contorno determinista: LWPOLYLINE que contiene el punto y de
;; menor área; si ninguna contiene el punto, la última LWPOLYLINE creada.
(defun mcvertex:elegir-contorno (nuevas pt-wcs / mejor mejor-area e r ar)
  (setq mejor nil
        mejor-area nil)
  (foreach e nuevas
    (setq r (mcvertex:leer-lwpoly e))
    (if (and r (mcvertex:pt-en-poligono pt-wcs (car r)))
      (progn
        (setq ar (abs (mcvertex:area-firmada (car r))))
        (if (or (null mejor) (< ar mejor-area))
          (setq mejor e
                mejor-area ar)))))
  (if (null mejor)
    (foreach e nuevas
      (if (mcvertex:leer-lwpoly e) (setq mejor e))))
  mejor)

;; Genera el contorno desde un punto interior y devuelve (nil verts T).
;; Elimina TODAS las entidades temporales creadas (borde e islas).
;; El marcador se conserva hasta limpiar y ante ESC lo usa *error*.
(defun mcvertex:generar-contorno ( / pt-ucs pt-wcs nuevas elegida r e)
  (setq pt-ucs (getpoint "\nIndique un punto interior del contorno: "))
  (if (null pt-ucs)
    nil
    (progn
      (setq pt-wcs (trans pt-ucs 1 0))
      ;; Cola real antes de BOUNDARY: protege subentidades preexistentes.
      ;; La bandera activa es independiente de la cola (que puede ser nil
      ;; en un dibujo vacío) y evita que *error* omita la limpieza.
      (setq *mcvertex-contorno-antes* (mcvertex:cola-bd))
      (setq *mcvertex-contorno-activo* T)
      ;; Forzar salida de polilínea (tipo de objeto) y polilínea ligera.
      ;; El "" tras _P sale de las opciones Advanced antes del punto.
      (setq *mcvertex-plinetype* (getvar "PLINETYPE"))
      (setvar "PLINETYPE" 2)
      (command "._-BOUNDARY" "_A" "_O" "_P" "" pt-ucs "")
      ;; BOUNDARY terminó: restaurar PLINETYPE (o lo hará *error* si hay ESC).
      (if *mcvertex-plinetype*
        (progn
          (setvar "PLINETYPE" *mcvertex-plinetype*)
          (setq *mcvertex-plinetype* nil)))
      (setq nuevas (mcvertex:nuevas-entidades *mcvertex-contorno-antes*))
      (if (null nuevas)
        (progn
          ;; Nada creado: igualmente se cierra la operación activa.
          (setq *mcvertex-contorno-antes* nil
                *mcvertex-contorno-activo* nil)
          (alert (strcat "No se pudo generar el contorno.\n"
                         "Verifique que el punto esté dentro de un área cerrada."))
          nil)
        (progn
          (setq elegida (mcvertex:elegir-contorno nuevas pt-wcs))
          (setq r (if elegida (mcvertex:leer-lwpoly elegida) nil))
          ;; Eliminar solo lo generado por BOUNDARY en esta operación.
          (foreach e nuevas (mcvertex:borrar e))
          ;; Marcador y bandera se limpian recién después de borrar.
          (setq *mcvertex-contorno-antes* nil
                *mcvertex-contorno-activo* nil)
          (if r
            (list nil (car r) T)
            (progn
              (alert "El contorno generado no es una LWPOLYLINE horizontal soportada.")
              nil)))))))

;;; ============================================================
;;; SECCIÓN 5: SELECCIÓN DE GEOMETRÍA
;;; ============================================================

(defun mcvertex:seleccionar-geometria (modo / sel ent info)
  (cond
    ((= modo "contorno")
     (mcvertex:generar-contorno))

    ((= modo "linea")
     (setq sel (entsel "\nSeleccione una LINE horizontal: "))
     (if (null sel)
       nil
       (progn
         (setq ent (car sel))
         (if (/= "LINE" (cdr (assoc 0 (entget ent))))
           (progn (alert "La entidad seleccionada no es una LINE.") nil)
           (mcvertex:extraer-line ent)))))

    ((= modo "abierta")
     (setq sel (entsel "\nSeleccione una LWPOLYLINE ABIERTA: "))
     (if (null sel)
       nil
       (progn
         (setq info (mcvertex:extraer-lwpoly (car sel)))
         (if (and info (caddr info))
           (progn
             (alert "La polilínea está cerrada.\nSeleccione una abierta o cambie el tipo de fuente.")
             nil)
           info))))

    ((= modo "cerrada")
     (setq sel (entsel "\nSeleccione una LWPOLYLINE CERRADA: "))
     (if (null sel)
       nil
       (progn
         (setq info (mcvertex:extraer-lwpoly (car sel)))
         (if (and info (not (caddr info)))
           (progn
             (alert "La polilínea está abierta.\nSeleccione una cerrada o cambie el tipo de fuente.")
             nil)
           info))))

    (T nil)))

;;; ============================================================
;;; SECCIÓN 6: ORDEN DE VÉRTICES (origen, horario, continuidad)
;;; ============================================================

;; Cerradas: origen en el vértice real más cercano y recorrido horario.
;; Abiertas: origen en el extremo más cercano conservando la continuidad.
(defun mcvertex:ordenar (verts cerrada pt-origen / idx lista n)
  (setq n (length verts))
  (if cerrada
    (progn
      (setq idx (if pt-origen (mcvertex:idx-mas-cercano pt-origen verts) 0))
      (setq lista (mcvertex:rotar verts idx))
      ;; Área positiva = antihorario -> invertir recorrido conservando
      ;; el primer vértice (origen elegido) en su lugar.
      (if (> (mcvertex:area-firmada lista) 0.0)
        (setq lista (cons (car lista) (reverse (cdr lista)))))
      lista)
    (progn
      (setq lista verts)
      (if pt-origen
        (progn
          (setq idx (if (< (mcvertex:dist2d pt-origen (car verts))
                           (mcvertex:dist2d pt-origen (last verts)))
                        0
                        (1- n)))
          (if (= idx (1- n))
            (setq lista (reverse verts)))))
      lista)))

;;; ============================================================
;;; SECCIÓN 6b: FUSIÓN POR TOLERANCIA
;;; ============================================================

;; Anota una sola vez los vértices consecutivos (y el par primero/último)
;; cuyo representante quede dentro de TOL. Reglas:
;;   - Solo compara vecinos consecutivos: nunca fusiona vértices no
;;     adyacentes, de modo que las topologías cóncavas quedan intactas.
;;   - La distancia se mide contra el REPRESENTANTE conservado del grupo
;;     y no contra el vecino inmediato; así no se encadenan vértices
;;     distintos por vecindades transitivas.
;;   - El representante es la coordenada fuente EXACTA del primer vértice
;;     del grupo (nunca un centroide).
;;   - En cerradas, tras el pase lineal se descartan las colas cercanas
;;     al origen conservado (el primer vértice manda).
;;   - En abiertas, si el último vértice cae dentro de la tolerancia del
;;     origen se elimina solo su anotación duplicada; la fuente y el
;;     recorrido siguen abiertos (no se cierra físicamente).
;;   - Si todo colapsa a un único representante se conserva ese vértice
;;     (no se reintroducen duplicados).
;;
;; Contrato estable para T5 (lista asociativa):
;;   (verts         . lista-fusionada) vértices representativos contiguos
;;   (cerrada       . T/nil)           recorrido cerrado real de la fuente
;;   (casi-cierre   . T/nil)           abierta con extremos ORIGINALES en TOL
;;   (cola-ref      . punto-wcs/nil)   extremo final original descartado
;;   (origen        . punto-wcs)       primer representante (origen conservado)
;;   (n-fuente      . entero)          vértices fuente ordenados
;;   (n-conservados . entero)          representantes tras la fusión
(defun mcvertex:fusionar (verts cerrada tol
                          / out n v casi-cierre cola-ref origen-orig final-orig)
  (setq n (length verts))
  (if (zerop n)
    (list (cons 'verts nil)
          (cons 'cerrada cerrada)
          (cons 'casi-cierre nil)
          (cons 'cola-ref nil)
          (cons 'origen nil)
          (cons 'n-fuente 0)
          (cons 'n-conservados 0))
    (progn
      ;; Extremos ORIGINALES antes de fusionar: la clasificación de casi
      ;; cierre y la dirección del extremo final salen de la fuente original,
      ;; no de representantes ya fusionados.
      (setq origen-orig (car verts)
            final-orig  (last verts))

      ;; Pase lineal: conserva el primer vértice de cada grupo y compara
      ;; cada candidato contra el representante vigente.
      (setq out '())
      (foreach v verts
        (if (or (null out)
                (> (mcvertex:dist2d (car out) v) tol))
          (setq out (cons v out))))
      (setq out (reverse out))

      ;; Cola: solo el par primero/último usando representantes conservados
      ;; (no encadena vértices distintos). Esto NO decide el casi cierre:
      ;; solo elimina anotaciones duplicadas del final.
      (while (and (or cerrada
                      (<= (mcvertex:dist2d origen-orig final-orig) tol))
                  (> (length out) 1)
                  (<= (mcvertex:dist2d (car out) (last out)) tol))
        (setq out (mcvertex:firstn (1- (length out)) out)))

      ;; Casi cierre por extremos ORIGINALES <= TOL. La fuente sigue abierta;
      ;; solo habilita la envolvente virtual para validar exteriores.
      (setq casi-cierre (and (not cerrada)
                             (<= (mcvertex:dist2d origen-orig final-orig) tol)))
      ;; Si el extremo final original se fusionó/descartó, el nuevo último
      ;; vértice conserva su salida hacia ese extremo original (no hacia un
      ;; representante intermedio).
      (setq cola-ref (if (or cerrada (equal (last out) final-orig))
                       nil
                       final-orig))

      (list (cons 'verts out)
            (cons 'cerrada cerrada)
            (cons 'casi-cierre casi-cierre)
            (cons 'cola-ref cola-ref)
            (cons 'origen (car out))
            (cons 'n-fuente n)
            (cons 'n-conservados (length out))))))

;;; ============================================================
;;; SECCIÓN 7: ANOTACIONES (círculos y etiquetas)
;;; ============================================================

;; Ángulo del segmento de salida de cada vértice. El último vértice
;; abierto usa el último segmento real (paralelo al segmento previo).
(defun mcvertex:angulo-salida (verts i cerrada / n)
  (setq n (length verts))
  (cond
    ((< i (1- n)) (mcvertex:angulo (nth i verts) (nth (1+ i) verts)))
    (cerrada      (mcvertex:angulo (nth i verts) (nth 0 verts)))
    (T            (if (>= i 1)
                    (mcvertex:angulo (nth (1- i) verts) (nth i verts))
                    0.0))))

;;; ============================================================
;;; SECCIÓN 7a: GEOMETRÍA DE ETIQUETAS (medición y colisiones)
;;; ============================================================

(defun mcvertex:clamp (x lo hi)
  (cond ((< x lo) lo) ((> x hi) hi) (T x)))

;; Producto cruzado de P->Q con P->R; su signo indica el lado.
(defun mcvertex:orient (p q r)
  (- (* (- (car q) (car p)) (- (cadr r) (cadr p)))
     (* (- (cadr q) (cadr p)) (- (car r) (car p)))))

;; T si Q cae sobre el segmento PR (casos colineales).
(defun mcvertex:en-segmento (p q r / eps)
  (setq eps 1e-9)
  (and (>= (car q) (- (min (car p) (car r)) eps))
       (<= (car q) (+ (max (car p) (car r)) eps))
       (>= (cadr q) (- (min (cadr p) (cadr r)) eps))
       (<= (cadr q) (+ (max (cadr p) (cadr r)) eps))))

;; T si P1P2 y P3P4 se cortan o se tocan (el contacto cuenta como corte).
;; en-segmento(p,q,r) = Q sobre el segmento PR.
(defun mcvertex:seg-inters (p1 p2 p3 p4 / d1 d2 d3 d4 eps)
  (setq eps 1e-9
        d1 (mcvertex:orient p1 p2 p3)
        d2 (mcvertex:orient p1 p2 p4)
        d3 (mcvertex:orient p3 p4 p1)
        d4 (mcvertex:orient p3 p4 p2))
  (cond
    ;; Contacto colineal: el extremo colineal debe caer dentro del otro.
    ((and (< (abs d1) eps) (mcvertex:en-segmento p1 p3 p2)) T)
    ((and (< (abs d2) eps) (mcvertex:en-segmento p1 p4 p2)) T)
    ((and (< (abs d3) eps) (mcvertex:en-segmento p3 p1 p4)) T)
    ((and (< (abs d4) eps) (mcvertex:en-segmento p3 p2 p4)) T)
    ;; Cruce propio (signos estrictamente opuestos en ambas rectas).
    ((and (< (* d1 d2) 0.0) (< (* d3 d4) 0.0)) T)
    (T nil)))

;; Distancia mínima de P al segmento AB.
(defun mcvertex:dist-punto-seg (p a b / dx dy l2 par q)
  (setq dx (- (car b) (car a))
        dy (- (cadr b) (cadr a))
        l2 (+ (* dx dx) (* dy dy)))
  (if (< l2 1e-18)
    (mcvertex:dist2d p a)
    (progn
      (setq par (/ (+ (* (- (car p) (car a)) dx)
                      (* (- (cadr p) (cadr a)) dy))
                   l2))
      (if (< par 0.0) (setq par 0.0))
      (if (> par 1.0) (setq par 1.0))
      (setq q (list (+ (car a) (* par dx)) (+ (cadr a) (* par dy))))
      (mcvertex:dist2d p q))))

;; Rectángulo orientado: (O e1 e2 Lx Ly) con e1/e2 unitarios ortogonales.
(defun mcvertex:recto-local (rect p / ox oy e1 e2)
  (setq ox (- (car p) (car (nth 0 rect)))
        oy (- (cadr p) (cadr (nth 0 rect)))
        e1 (nth 1 rect)
        e2 (nth 2 rect))
  (list (+ (* ox (car e1)) (* oy (cadr e1)))
        (+ (* ox (car e2)) (* oy (cadr e2)))))

(defun mcvertex:recto-esquinas (rect / o e1 e2 lx ly)
  (setq o  (nth 0 rect)
        e1 (nth 1 rect)
        e2 (nth 2 rect)
        lx (nth 3 rect)
        ly (nth 4 rect))
  (list o
        (list (+ (car o) (* lx (car e1))) (+ (cadr o) (* lx (cadr e1))))
        (list (+ (car o) (* lx (car e1)) (* ly (car e2)))
              (+ (cadr o) (* lx (cadr e1)) (* ly (cadr e2))))
        (list (+ (car o) (* ly (car e2))) (+ (cadr o) (* ly (cadr e2))))))

(defun mcvertex:punto-en-recto (rect p / l eps)
  (setq l (mcvertex:recto-local rect p)
        eps 1e-9)
  (and (>= (car l) (- eps)) (<= (car l) (+ (nth 3 rect) eps))
       (>= (cadr l) (- eps)) (<= (cadr l) (+ (nth 4 rect) eps))))

;; Distancia real de P al rectángulo orientado (punto más cercano clavado).
(defun mcvertex:dist-punto-recto (rect p / l cx cy o e1 e2)
  (setq l  (mcvertex:recto-local rect p)
        cx (mcvertex:clamp (car l) 0.0 (nth 3 rect))
        cy (mcvertex:clamp (cadr l) 0.0 (nth 4 rect))
        o  (nth 0 rect)
        e1 (nth 1 rect)
        e2 (nth 2 rect))
  (mcvertex:dist2d p (list (+ (car o) (* cx (car e1)) (* cy (car e2)))
                           (+ (cadr o) (* cx (cadr e1)) (* cy (cadr e2))))))

(defun mcvertex:recto-seg-inters (rect a b / esq res i)
  (setq esq (mcvertex:recto-esquinas rect)
        res nil
        i 0)
  (while (and (not res) (< i 4))
    (if (mcvertex:seg-inters (nth i esq) (nth (rem (1+ i) 4) esq) a b)
      (setq res T))
    (setq i (1+ i)))
  res)

;; Distancia mínima del rectángulo al segmento AB (0 si se cortan/tocan).
(defun mcvertex:dist-recto-seg (rect a b / d esq i)
  (if (mcvertex:recto-seg-inters rect a b)
    0.0
    (progn
      (setq d (min (mcvertex:dist-punto-recto rect a)
                   (mcvertex:dist-punto-recto rect b))
            esq (mcvertex:recto-esquinas rect)
            i 0)
      (while (< i 4)
        (setq d (min d (mcvertex:dist-punto-seg (nth i esq) a b)))
        (setq i (1+ i)))
      d)))

;; T si RECT está completamente fuera del polígono cerrado BORDE.
;; Se comprueban esquinas dentro, vértices del polígono dentro del
;; rectángulo y cortes/contactos entre los lados de ambos.
(defun mcvertex:recto-fuera-poligono (rect borde / esq fuera i n)
  (setq esq (mcvertex:recto-esquinas rect)
        fuera T
        n (length borde)
        i 0)
  (while (and fuera (< i 4))
    (if (mcvertex:pt-en-poligono (nth i esq) borde) (setq fuera nil))
    (setq i (1+ i)))
  (setq i 0)
  (while (and fuera (< i n))
    (if (mcvertex:punto-en-recto rect (nth i borde)) (setq fuera nil))
    (setq i (1+ i)))
  (setq i 0)
  (while (and fuera (< i n))
    (if (mcvertex:recto-seg-inters rect
                                   (nth i borde)
                                   (nth (rem (1+ i) n) borde))
      (setq fuera nil))
    (setq i (1+ i)))
  fuera)

;; T si cada tramo de BORDE queda a distancia >= CLARO del rectángulo.
;; ABIERTO=T omite el cierre (fuente realmente abierta, sin interior).
(defun mcvertex:recto-claro (rect borde abierto claro / n res i b distancia holgura)
  (setq n (length borde)
        res T
        i 0
        ;; La holgura nunca consume un margen positivo, aunque sea diminuto.
        holgura (min 1e-9 (* claro 1e-6)))
  (while (and res (< i n))
    (setq b (if (and abierto (= i (1- n))) nil (nth (rem (1+ i) n) borde)))
    (if b
      (progn
        (setq distancia (mcvertex:dist-recto-seg rect (nth i borde) b))
        (if (or (<= distancia 0.0) (< distancia (- claro holgura)))
          (setq res nil))))
    (setq i (1+ i)))
  res)

;; T si cada centro de círculo queda a distancia >= RADIO + GAP del rect.
(defun mcvertex:recto-libre-circulos (rect circulos radio gap / res d)
  (setq res T)
  (foreach c circulos
    (if res
      (progn
        (setq d (mcvertex:dist-punto-recto rect c))
        (if (< d (+ radio gap)) (setq res nil)))))
  res)

;; Rectángulo orientado con inserción INS y rotación ROT.
(defun mcvertex:recto-candidato (ins rot x1 y1 x2 y2 / cosr sinr e1 e2)
  (setq cosr (cos rot)
        sinr (sin rot)
        e1 (list cosr sinr)
        e2 (list (- sinr) cosr))
  (list (list (+ (car ins) (* x1 (car e1)) (* y1 (car e2)))
              (+ (cadr ins) (* x1 (cadr e1)) (* y1 (cadr e2))))
        e1 e2 (- x2 x1) (- y2 y1)))

;; Menores proyecciones de la caja girada ROT sobre U (salida) y NOR (exterior).
(defun mcvertex:proyecciones-caja (rot u nor x1 y1 x2 y2
                                   / cosr sinr c mU mN rx ry pu pn)
  (setq cosr (cos rot)
        sinr (sin rot)
        mU 1.0e308
        mN 1.0e308)
  (foreach c (list (list x1 y1) (list x2 y1) (list x2 y2) (list x1 y2))
    (setq rx (- (* (car c) cosr) (* (cadr c) sinr))
          ry (+ (* (car c) sinr) (* (cadr c) cosr))
          pu (+ (* rx (car u)) (* ry (cadr u)))
          pn (+ (* rx (car nor)) (* ry (cadr nor))))
    (if (< pu mU) (setq mU pu))
    (if (< pn mN) (setq mN pn)))
  (list mU mN))

;; (ancho . oblicuo) efectivos del estilo de texto actual.
(defun mcvertex:estilo-texto ( / st w o)
  (setq st (tblsearch "STYLE" (getvar "TEXTSTYLE")))
  (setq w (if (and st (assoc 41 st)) (cdr (assoc 41 st)) 1.0)
        o (if (and st (assoc 51 st)) (cdr (assoc 51 st)) 0.0))
  (if (< w 1e-6) (setq w 1.0))
  (cons w o))

;; Mide TEXTBOX de TEXTO con estilo, altura, ancho, oblicuo y banderas de
;; generación idénticos al TEXT final, en rotación 0 e inserción (0,0,0).
;; Devuelve (x1 y1 x2 y2) o nil si textbox no está disponible.
(defun mcvertex:medir-texto (texto th / ef w o tb p1 p2)
  (setq ef (mcvertex:estilo-texto)
        w  (car ef)
        o  (cdr ef))
  (setq tb (vl-catch-all-apply
             'textbox
             (list (list '(0 . "TEXT")
                         (cons 1 texto)
                         (cons 7 (getvar "TEXTSTYLE"))
                         (cons 40 th)
                         (cons 41 w)
                         (cons 51 o)
                         (cons 71 0)
                         (cons 72 0)
                         (cons 73 0)
                         (cons 10 '(0.0 0.0 0.0))
                         (cons 11 '(0.0 0.0 0.0))))))
  (if (or (vl-catch-all-error-p tb) (null tb) (< (length tb) 2))
    nil
    (progn
      (setq p1 (car tb)
            p2 (cadr tb))
      (list (min (car p1) (car p2)) (min (cadr p1) (cadr p2))
            (max (car p1) (car p2)) (max (cadr p1) (cadr p2))))))

;; Normal unitaria exterior. Con polígono (cerrada/virtual) se deduce del
;; área con signo del anillo ORIGINAL; sin interior (abierta real) se usa
;; la izquierda del recorrido de forma consistente.
(defun mcvertex:normal-exterior (ang hay-pol borde / area)
  (if hay-pol
    (progn
      (setq area (mcvertex:area-firmada borde))
      (if (< area 0.0)
        (list (- (sin ang)) (cos ang))
        (list (sin ang) (- (cos ang)))))
    (list (- (sin ang)) (cos ang))))

;; Validación completa de un candidato de etiqueta.
(defun mcvertex:etiqueta-valida (rect borde abierto circulos radio gap claro hay-pol)
  (and (if hay-pol (mcvertex:recto-fuera-poligono rect borde) T)
       (mcvertex:recto-claro rect borde abierto claro)
       (mcvertex:recto-libre-circulos rect circulos radio gap)))

;; Dibuja todas las anotaciones. Cada etiqueta se mide con TEXTBOX y se
;; ubica tras una búsqueda acotada hacia el exterior/lo largo de la salida;
;; si no hay posición segura se omite con aviso conservando su círculo.
;; Si un entmake falla, se revierten solo las entidades de esta llamada.
(defun mcvertex:anotar (verts cerrada radio prefijo etiquetar cola-ref borde abierto
                        / n i v ang u nor th gap claro paso na nb ja jb a0 b0 a b
                          ins rect texto caja x1 y1 x2 y2 rot proy mU mN hay-pol
                          ef hallado antes nuevo fallo)
  (setq n (length verts)
        i 0
        fallo nil
        *mcvertex-creadas* nil)
  (setq th (* radio 0.9)
        gap (* radio 0.35)
        ;; Un pequeño margen visual adicional separa la caja tanto del
        ;; círculo como de todos los tramos: claro = gap = 0.35 * radio.
        claro (* radio 0.35)
        paso (* radio 0.5)
        na 8
        nb 8
        hay-pol (and (not abierto) (>= (length borde) 3)))
  (while (and (< i n) (not fallo))
    (setq v (nth i verts))

    ;; Círculo exacto en la coordenada del vértice (WCS, extrusión +Z).
    (setq antes (entlast))
    (entmake (list '(0 . "CIRCLE")
                   (cons 8 (getvar "CLAYER"))
                   (cons 10 v)
                   (cons 40 radio)
                   '(210 0.0 0.0 1.0)))
    (setq nuevo (entlast))
    (if (equal antes nuevo)
      (setq fallo T)
      (setq *mcvertex-creadas* (cons nuevo *mcvertex-creadas*)))

    ;; Etiqueta opcional. Con un único vértice no hay dirección de salida
    ;; definida: se omite la etiqueta (el círculo ya quedó dibujado).
    (if (and etiquetar (not fallo) (>= n 2))
      (progn
        (setq texto (strcat prefijo "-" (itoa (1+ i))))
        (setq ang (mcvertex:angulo-salida verts i cerrada))
        ;; Casi cierre abierto: el nuevo último vértice conserva su salida
        ;; hacia el extremo original descartado, no hacia el tramo previo.
        (if (and cola-ref (not cerrada) (= i (1- n)))
          (setq ang (mcvertex:angulo (nth i verts) cola-ref)))
        (setq u   (list (cos ang) (sin ang))
              nor (mcvertex:normal-exterior ang hay-pol borde))
        (setq caja (mcvertex:medir-texto texto th))
        (if (null caja)
          (princ (strcat "\nMCVERTEX: textbox no disponible para \""
                         texto "\"; etiqueta omitida en el vértice "
                         (itoa (1+ i)) "."))
          (progn
            (setq x1 (nth 0 caja) y1 (nth 1 caja)
                  x2 (nth 2 caja) y2 (nth 3 caja))
            (setq rot (car (mcvertex:normalizar-angulo ang)))
            (setq proy (mcvertex:proyecciones-caja rot u nor x1 y1 x2 y2)
                  mU (car proy)
                  mN (cadr proy))
            ;; Desplazamiento mínimo que separa la caja del círculo y del
            ;; borde; luego búsqueda acotada priorizando el margen exterior
            ;; pequeño y, dentro de él, la cercanía al vértice.
            (setq a0 (- (+ radio gap) mU)
                  b0 (- gap mN)
                  jb 0
                  hallado nil)
            (while (and (not hallado) (< jb nb))
              (setq b (+ b0 (* jb paso)))
              (setq ja 0)
              (while (and (not hallado) (< ja na))
                (setq a (+ a0 (* ja paso)))
                (setq ins (list (+ (car v) (* a (car u)) (* b (car nor)))
                                (+ (cadr v) (* a (cadr u)) (* b (cadr nor)))
                                (caddr v)))
                (setq rect (mcvertex:recto-candidato ins rot x1 y1 x2 y2))
                (if (mcvertex:etiqueta-valida rect borde abierto verts radio
                                              gap claro hay-pol)
                  (setq hallado T))
                (setq ja (1+ ja)))
              (setq jb (1+ jb)))
            (if (null hallado)
              (princ (strcat "\nMCVERTEX: sin posición exterior válida para \""
                             texto "\" en el vértice " (itoa (1+ i))
                             "; etiqueta omitida."))
              (progn
                (setq ef (mcvertex:estilo-texto))
                (setq antes (entlast))
                (entmake (list '(0 . "TEXT")
                               (cons 8 (getvar "CLAYER"))
                               (cons 7 (getvar "TEXTSTYLE"))
                               (cons 40 th)
                               (cons 41 (car ef))
                               (cons 51 (cdr ef))
                               (cons 71 0)
                               (cons 1 texto)
                               (cons 10 ins)
                               (cons 11 ins)
                               (cons 50 rot)
                               (cons 72 0)
                               (cons 73 0)
                               '(210 0.0 0.0 1.0)))
                (setq nuevo (entlast))
                (if (equal antes nuevo)
                  (setq fallo T)
                  (setq *mcvertex-creadas* (cons nuevo *mcvertex-creadas*)))))))))

    (setq i (1+ i)))

  (if (and etiquetar (< n 2))
    (princ (strcat "\nMCVERTEX: un solo vértice tras la tolerancia; "
                   "no hay dirección definida y se omite la etiqueta.")))

  (if fallo
    (progn
      (foreach e *mcvertex-creadas* (if e (entdel e)))
      (setq *mcvertex-creadas* nil)
      nil)
    T))

;;; ============================================================
;;; SECCIÓN 8: CARGA DE CONTROLES DEL DIÁLOGO
;;; ============================================================

(defun mcvertex:cargar-dlg (modo radio-raw tol-raw prefijo etiquetar verts pt-origen
                            / lbl-g lbl-o)
  (set_tile "rb_cerrada"  (if (= modo "cerrada")  "1" "0"))
  (set_tile "rb_linea"    (if (= modo "linea")    "1" "0"))
  (set_tile "rb_abierta"  (if (= modo "abierta")  "1" "0"))
  (set_tile "rb_contorno" (if (= modo "contorno") "1" "0"))
  ;; Se conservan las cadenas crudas de radio y tolerancia (sin convertir)
  ;; para no perder entradas inválidas entre reaperturas del diálogo.
  (set_tile "eb_radio"    radio-raw)
  (set_tile "eb_tol"      tol-raw)
  (set_tile "eb_prefijo"  prefijo)
  (set_tile "ck_etiquetas" (if etiquetar "1" "0"))

  (setq lbl-g (if verts
                (strcat "Fuente: " (itoa (length verts)) " vértices")
                "Sin seleccionar"))
  (setq lbl-o (if pt-origen
                (strcat "Origen: (" (rtos (car pt-origen) 2 2) ", "
                                    (rtos (cadr pt-origen) 2 2) ")")
                "Predeterminado"))
  (set_tile "lbl_geom" lbl-g)
  (set_tile "lbl_origen" lbl-o))

;;; ============================================================
;;; SECCIÓN 9: COMANDO PRINCIPAL - C:MCVERTEX
;;; ============================================================

(defun C:MCVERTEX ( / *error*
                      old-osmode old-cmdecho old-dimzin
                      dcl-ruta dcl-id estado continuar cancelado
                      modo radio radio-raw tol tol-raw prefijo etiquetar
                      ent-geom verts cerrada pt-origen
                      completado listo fusion orden-fuente abierto r
                      cierre-virtual cerrada-anotacion verts-anotacion borde-fuente)

  ;; ----------------------------------------------------------
  ;; 9.1 MANEJADOR LOCAL DE ERRORES
  ;; ----------------------------------------------------------
  (defun *error* (msg)
    (if old-osmode  (setvar "OSMODE"  old-osmode))
    (if old-cmdecho (setvar "CMDECHO" old-cmdecho))
    (if old-dimzin (setvar "DIMZIN"  old-dimzin))
    ;; Restaurar PLINETYPE si -BOUNDARY quedó a medias.
    (if *mcvertex-plinetype*
      (progn
        (setvar "PLINETYPE" *mcvertex-plinetype*)
        (setq *mcvertex-plinetype* nil)))
    ;; El diálogo podría estar activo: cerrarlo de forma segura.
    (vl-catch-all-apply '(lambda () (done_dialog 0)) nil)
    (vl-catch-all-apply
      '(lambda () (if (and dcl-id (>= dcl-id 0)) (unload_dialog dcl-id)))
      nil)
    (if (and dcl-ruta (findfile dcl-ruta))
      (vl-file-delete dcl-ruta))
    ;; ESC durante -BOUNDARY: limpiar por la BANDERA activa, no por la cola
    ;; (que puede ser nil en un dibujo vacío). nuevas-entidades nil => todo.
    (if *mcvertex-contorno-activo*
      (progn
        (foreach e (mcvertex:nuevas-entidades *mcvertex-contorno-antes*)
          (mcvertex:borrar e))
        (setq *mcvertex-contorno-antes* nil
              *mcvertex-contorno-activo* nil)))
    ;; Fallo parcial: revertir solo las anotaciones de ESTA ejecución.
    (if (and *mcvertex-creadas* (not completado))
      (progn
        (foreach e *mcvertex-creadas* (mcvertex:borrar e))
        (setq *mcvertex-creadas* nil)))
    (if (not (member (strcase (if msg msg ""))
                     '("FUNCTION CANCELLED" "QUIT / EXIT ABORT" "")))
      (princ (strcat "\nMCVERTEX error: " msg)))
    (princ))

  ;; ----------------------------------------------------------
  ;; 9.2 ENTORNO
  ;; ----------------------------------------------------------
  (setq old-osmode  (getvar "OSMODE")
        old-cmdecho (getvar "CMDECHO")
        old-dimzin  (getvar "DIMZIN"))
  (setvar "CMDECHO" 0)
  ;; DIMZIN 0 garantiza decimales visibles en los rtos del diálogo.
  (setvar "DIMZIN" 0)
  (setvar "OSMODE" 0)
  (setq *mcvertex-creadas* nil
        *mcvertex-contorno-antes* nil
        *mcvertex-contorno-activo* nil
        *mcvertex-plinetype* nil)

  (princ "\n=== MCVERTEX: círculos y etiquetas de vértices ===")

  ;; ----------------------------------------------------------
  ;; 9.3 ESTADO DEL DIÁLOGO
  ;; ----------------------------------------------------------
  (setq modo      "cerrada"
        radio     1.0
        radio-raw "1.0"
        tol       0.001
        tol-raw   "0.001"
        prefijo   "E"
        etiquetar T
        ent-geom  nil
        verts     nil
        cerrada   nil
        pt-origen nil
        completado nil)

  ;; ----------------------------------------------------------
  ;; 9.4 DIÁLOGO TEMPORAL
  ;; ----------------------------------------------------------
  (setq dcl-ruta (vl-filename-mktemp "mcvertex" nil ".dcl"))
  (if (not (mcvertex:escribir-dcl dcl-ruta))
    (progn (alert "No se pudo crear el archivo DCL temporal.") (exit)))
  (setq dcl-id (load_dialog dcl-ruta))
  (if (< dcl-id 0)
    (progn
      (if (findfile dcl-ruta) (vl-file-delete dcl-ruta))
      (alert "No se pudo cargar el diálogo DCL.")
      (exit)))

  (setq continuar T
        cancelado nil
        estado    0)

  (while continuar
    (if (not (new_dialog "mcvertex_dlg" dcl-id))
      (progn
        (alert "No se encontró la definición del diálogo.")
        (setq continuar nil cancelado T))
      (progn
        (mcvertex:cargar-dlg modo radio-raw tol-raw prefijo etiquetar verts pt-origen)

        ;; Cambiar de tipo de fuente invalida la geometría ya elegida.
        (action_tile "rb_cerrada"
          "(setq modo \"cerrada\") (setq verts nil cerrada nil ent-geom nil pt-origen nil)")
        (action_tile "rb_linea"
          "(setq modo \"linea\") (setq verts nil cerrada nil ent-geom nil pt-origen nil)")
        (action_tile "rb_abierta"
          "(setq modo \"abierta\") (setq verts nil cerrada nil ent-geom nil pt-origen nil)")
        (action_tile "rb_contorno"
          "(setq modo \"contorno\") (setq verts nil cerrada nil ent-geom nil pt-origen nil)")

        ;; Los botones persisten TODOS los controles (incluido el radio
        ;; crudo sin convertir) antes de salir y reabrir el diálogo.
        (action_tile "btn_geom"
          (strcat
            "(setq radio-raw (get_tile \"eb_radio\"))"
            "(setq tol-raw (get_tile \"eb_tol\"))"
            "(setq prefijo (get_tile \"eb_prefijo\"))"
            "(setq etiquetar (= (get_tile \"ck_etiquetas\") \"1\"))"
            "(done_dialog 10)"))
        (action_tile "btn_origen"
          (strcat
            "(setq radio-raw (get_tile \"eb_radio\"))"
            "(setq tol-raw (get_tile \"eb_tol\"))"
            "(setq prefijo (get_tile \"eb_prefijo\"))"
            "(setq etiquetar (= (get_tile \"ck_etiquetas\") \"1\"))"
            "(done_dialog 11)"))

        (action_tile "accept"
          (strcat
            "(setq radio-raw (get_tile \"eb_radio\"))"
            "(setq tol-raw (get_tile \"eb_tol\"))"
            "(setq prefijo (get_tile \"eb_prefijo\"))"
            "(setq etiquetar (= (get_tile \"ck_etiquetas\") \"1\"))"
            "(setq radio (mcvertex:parsear-positivo radio-raw))"
            "(setq tol (mcvertex:parsear-positivo tol-raw))"
            "(if (null radio)"
            "  (alert \"El radio debe ser un número positivo (p. ej. 1.0).\")"
            "  (if (null tol)"
            "    (alert \"La tolerancia debe ser un número positivo en metros (p. ej. 0.001).\")"
            "    (if (null verts)"
            "      (alert \"Seleccione primero la geometría.\")"
            "      (done_dialog 1))))"))
        (action_tile "cancel" "(done_dialog 0)")

        (setq estado (start_dialog))

        (cond
          ((= estado 10)
           (setq r (mcvertex:seleccionar-geometria modo))
           (if r
             (setq ent-geom  (car r)
                   verts     (cadr r)
                   cerrada   (caddr r)
                   pt-origen nil)
             (princ "\nMCVERTEX: sin selección.")))

          ((= estado 11)
           (if (null verts)
             (alert "Seleccione primero la geometría.")
             (progn
               ;; Snaps endpoint+nodo solo durante la captura del origen.
               (setvar "OSMODE" (logior old-osmode 1 8))
               (setq r (getpoint "\nHaga clic cerca del vértice de origen: "))
               (setvar "OSMODE" 0)
               (if r (setq pt-origen (trans r 1 0))))))

          ((= estado 1)
           (setq continuar nil))

          (T
           (setq continuar nil cancelado T))))))

  ;; ----------------------------------------------------------
  ;; 9.5 CIERRE Y LIMPIEZA DEL DIÁLOGO
  ;; ----------------------------------------------------------
  (unload_dialog dcl-id)
  (setq dcl-id nil)
  (if (findfile dcl-ruta) (vl-file-delete dcl-ruta))

  ;; ----------------------------------------------------------
  ;; 9.6 PROCESO
  ;; ----------------------------------------------------------
  (if cancelado
    (princ "\nComando cancelado.")
    (progn
      ;; El cierre por imán no activa la bandera de AutoCAD. Reconocerlo
      ;; ANTES de ordenar permite elegir cualquier vértice como origen.
      ;; Solo se aplica a LWPOLYLINE con al menos tres vértices más la cola;
      ;; LINE, contornos y cerradas nativas conservan su tratamiento previo.
      (setq cierre-virtual
        (and (not cerrada)
             ent-geom
             (= "LWPOLYLINE" (cdr (assoc 0 (entget ent-geom))))
             (>= (length verts) 4)
             (<= (mcvertex:dist2d (car verts) (last verts)) tol)))
      (setq cerrada-anotacion (or cerrada cierre-virtual)
            ;; Retirar la cola duplicada ANTES de rotar, solo en esta copia:
            ;; evita un tramo nulo junto al origen original del circuito.
            verts-anotacion (if cierre-virtual
                              (mcvertex:firstn (1- (length verts)) verts)
                              verts))
      (setq orden-fuente
        (mcvertex:ordenar verts-anotacion cerrada-anotacion pt-origen))
      (setq fusion (mcvertex:fusionar orden-fuente cerrada-anotacion tol))
      (setq listo (cdr (assoc 'verts fusion)))
      ;; Validar contra la frontera SIN fusionar. En el cierre virtual se
      ;; conserva también el extremo final original para las colisiones.
      (setq borde-fuente (if cierre-virtual
                          (mcvertex:ordenar verts T pt-origen)
                          orden-fuente)
            abierto (not (or cerrada-anotacion
                             (cdr (assoc 'casi-cierre fusion)))))
      (princ (strcat "\nMCVERTEX: " (itoa (length verts))
                     " vértices fuente, " (itoa (length listo))
                     " tras tolerancia " (rtos tol 2 6) " m."))
      (if cierre-virtual
        (princ (strcat "\nMCVERTEX: cierre geométrico detectado dentro de la tolerancia; "
                       "origen elegido y recorrido horario para anotar. "
                       "La entidad conserva su marca abierta en AutoCAD.")))
      (if (cdr (assoc 'casi-cierre fusion))
        (princ (strcat "\nMCVERTEX: extremos originales abiertos dentro de la tolerancia; "
                       "se usa envolvente virtual para el exterior y la fuente sigue abierta.")))
      (if (mcvertex:anotar listo cerrada-anotacion radio prefijo etiquetar
                           (cdr (assoc 'cola-ref fusion))
                           borde-fuente abierto)
        (progn
          (setq completado T)
          (princ "\nMCVERTEX: anotación completada."))
        (princ "\nMCVERTEX: falló la creación de anotaciones; se revirtieron las creadas."))))

  ;; ----------------------------------------------------------
  ;; 9.7 RESTAURAR ENTORNO
  ;; ----------------------------------------------------------
  (setvar "OSMODE"  old-osmode)
  (setvar "CMDECHO" old-cmdecho)
  (setvar "DIMZIN"  old-dimzin)
  (if *mcvertex-plinetype*
    (progn
      (setvar "PLINETYPE" *mcvertex-plinetype*)
      (setq *mcvertex-plinetype* nil)))
  (setq *mcvertex-creadas* nil
        *mcvertex-contorno-antes* nil
        *mcvertex-contorno-activo* nil)
  (princ))

;;; ============================================================
;;; MENSAJE DE CARGA
;;; ============================================================

(princ "\nMCVERTEX cargado. Escriba MCVERTEX para iniciar.")
(princ)
