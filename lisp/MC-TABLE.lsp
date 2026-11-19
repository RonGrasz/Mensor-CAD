;;; ============================================================================
;;; MCTABLE.LSP - Comando de Tabla de Coordenadas UTM, Rumbos y Distancias
;;; Versión Corregida con Formato Homogéneo de Rumbos (00° 00' 00")
;;; ============================================================================

;; ============================================================
;; SECCIÓN 1: ESCRITURA DEL ARCHIVO DCL TEMPORAL ÚNICO
;; ============================================================

(defun MCTABLE:write-dcl (dcl-file / f)
  (setq f (open dcl-file "w"))
  (if (null f)
    (progn (princ "\nError: No se pudo crear el archivo DCL temporal.") nil)
    (progn
      (write-line "mctable_dlg : dialog {" f)
      (write-line "  label = \"Tabla de Coordenadas\";" f)
      (write-line "  width = 52;" f)
      (write-line "" f)
      (write-line "  : boxed_radio_column {" f)
      (write-line "    label = \"Dirección de Recorrido\";" f)
      (write-line "    key = \"grp_dir\";" f)
      (write-line "    : radio_button { label = \"Antihoraria (CCW) \"; key = \"rb_ccw\"; value = \"0\"; }" f)
      (write-line "    : radio_button { label = \"Horaria (CW) [predeterminado]\"; key = \"rb_cw\"; value = \"1\"; }" f)
      (write-line "  }" f)
      (write-line "" f)
      (write-line "  : boxed_radio_column {" f)
      (write-line "    label = \"Orden de Coordenadas\";" f)
      (write-line "    key = \"grp_ord\";" f)
      (write-line "    : radio_button { label = \"Este (X)  ,  Norte (Y)  [predeterminado]\"; key = \"rb_xy\"; value = \"1\"; }" f)
      (write-line "    : radio_button { label = \"Norte (Y)  ,  Este (X)\"; key = \"rb_yx\"; value = \"0\"; }" f)
      (write-line "  }" f)
      (write-line "" f)
      (write-line "  : boxed_column {" f)
      (write-line "    label = \"Precisión Decimal\";" f)
      (write-line "    : row {" f)
      (write-line "      : text { label = \"Número de decimales:\"; }" f)
      (write-line "      : edit_box { key = \"eb_dec\"; value = \"2\"; width = 6; edit_width = 4; }" f)
      (write-line "    }" f)
      (write-line "  }" f)
      (write-line "" f)
      (write-line "  : boxed_column {" f)
      (write-line "    label = \"Apariencia de las Tablas\";" f)
      (write-line "    key = \"grp_tablas\";" f)
      (write-line "    : row {" f)
      (write-line "      : text { label = \"Altura del texto (unidades de dibujo):\"; }" f)
      (write-line "      : edit_box { key = \"eb_altura_tabla\"; value = \"1.0\"; width = 8; edit_width = 6; }" f)
      (write-line "    }" f)
      (write-line "    : text { key = \"txt_altura_error\"; label = \"\"; width = 46; }" f)
      (write-line "  }" f)
      (write-line "" f)
      (write-line "  : boxed_column {" f)
      (write-line "    label = \"Apariencia de Vértices\";" f)
      (write-line "    : row {" f)
      (write-line "      : text { label = \"Radio:\"; }" f)
      (write-line "      : edit_box { key = \"txt_radio_vertice\"; value = \"1.0\"; width = 8; edit_width = 6; }" f)
      (write-line "      : toggle { key = \"ck_etiquetas\"; label = \"Mostrar etiquetas\"; value = \"1\"; }" f)
      (write-line "    }" f)
      (write-line "    : row {" f)
      (write-line "      : text { label = \"Prefijo etiquetas:\"; }" f)
      (write-line "      : edit_box { key = \"txt_prefijo_tag\"; value = \"E\"; width = 8; edit_width = 6; }" f)
      (write-line "      : text { label = \"Fuente:\"; }" f)
      (write-line "      : edit_box { key = \"txt_fuente_tag\"; value = \"Standard\"; width = 18; edit_width = 12; }" f)
      (write-line "    }" f)
      (write-line "    : edit_box { key = \"txt_inicio\"; label = \"Número inicial:\"; value = \"1\"; edit_width = 12; }" f)
      (write-line "    : edit_box { key = \"txt_omitir\"; label = \"Vértices a omitir entre puntos:\"; value = \"0\"; edit_width = 12; }" f)
      (write-line "    : text { label = \"La omisión afecta solo a las etiquetas; las tablas no cambian.\"; }" f)
      (write-line "    : text { key = \"txt_vertice_error\"; label = \"\"; width = 46; }" f)
      (write-line "  }" f)
      (write-line "" f)
      (write-line "  : boxed_column {" f)
      (write-line "    label = \"Símbolo del vértice\";" f)
      (write-line "    : row {" f)
      (write-line "      : popup_list { key = \"pl_simbolo\"; label = \"Tipo:\"; edit_width = 30; }" f)
      (write-line "      : image { key = \"preview_simbolo\"; width = 10; height = 4; fixed_width = true; fixed_height = true; color = -2; }" f)
      (write-line "    }" f)
      (write-line "  }" f)
      (write-line "" f)
      (write-line "  : boxed_column {" f)
      (write-line "    label = \"Origen de la numeración\";" f)
      (write-line "    : row {" f)
      (write-line "      : text { key = \"txt_orig\"; label = \"Sin seleccionar\"; width = 32; }" f)
      (write-line "      : button { key = \"btn_orig\"; label = \"Seleccionar...\"; width = 14; fixed_width = true; }" f)
      (write-line "    }" f)
      (write-line "  }" f)
      (write-line "" f)
      (write-line "  ok_cancel;" f)
      (write-line "}" f)
      (close f)
      T
    )
  )
)

;; ============================================================
;; SECCIÓN 2: UTILIDADES MATEMÁTICAS, GEOMÉTRICAS Y LIMPIEZA
;; ============================================================

(defun MCTABLE:distance-2d (p1 p2)
  (sqrt (+ (expt (- (car p2)  (car p1))  2)
           (expt (- (cadr p2) (cadr p1)) 2)))
)

;; NUEVA FUNCIÓN DE RUMBOS: Formato homogéneo con ceros a la izquierda y orden correcto (' ")
(defun MCTABLE:get-bearing (p1 p2 / ang az deg min sec quad pref suff rem pad2)
  ;; Subfunción local para añadir un cero a la izquierda si el número es < 10
  (defun pad2 (num)
    (if (< num 10)
      (strcat "0" (itoa num))
      (itoa num)
    )
  )

  (setq ang (angle p1 p2)) 
  (setq az (- 90.0 (/ (* ang 180.0) pi)))
  (while (< az 0.0) (setq az (+ az 360.0)))
  (while (>= az 360.0) (setq az (- az 360.0)))
  
  (cond
    ((and (>= az 0.0) (<= az 90.0))
     (setq quad az pref "N" suff "E"))
    ((and (> az 90.0) (<= az 180.0))
     (setq quad (- 180.0 az) pref "S" suff "E"))
    ((and (> az 180.0) (<= az 270.0))
     (setq quad (- az 180.0) pref "S" suff "W"))
    (T
     (setq quad (- 360.0 az) pref "N" suff "W"))
  )
  
  (setq deg (fix quad)
        rem (* (- quad deg) 60.0)
        min (fix rem)
        sec (fix (+ (* (- rem min) 60.0) 0.5))
  )
  (if (= sec 60) (setq sec 0 min (1+ min)))
  (if (= min 60) (setq min 0 deg (1+ deg)))
  
  ;; Retorna el formato estandarizado: ej. N 05° 09' 02" E
  (strcat pref " " (pad2 deg) "%%d " (pad2 min) "' " (pad2 sec) "\" " suff)
)

(defun MCTABLE:clean-vertices (lst / clean-lst pt last-pt)
  (if lst
    (progn
      (setq clean-lst (list (car lst)))
      (foreach pt (cdr lst)
        (if (not (equal pt (car clean-lst) 1e-4))
          (setq clean-lst (cons pt clean-lst))
        )
      )
      (setq clean-lst (reverse clean-lst))
      (setq last-pt (nth (1- (length clean-lst)) clean-lst))
      (if (and (> (length clean-lst) 2)
               (equal (car clean-lst) last-pt 1e-4))
        (setq clean-lst (reverse (cdr (reverse clean-lst))))
      )
    )
  )
  clean-lst
)

(defun MCTABLE:closest-vertex (pt vlist / best-idx best-dist d i)
  (setq best-dist 1e300  best-idx 0  i 0)
  (foreach v vlist
    (setq d (MCTABLE:distance-2d pt v))
    (if (< d best-dist)
      (setq best-dist d  best-idx i)
    )
    (setq i (1+ i))
  )
  best-idx
)

(defun MCTABLE:rotate-list (lst n / len)
  (setq len (length lst))
  (if (and (> len 0) (> n 0))
    (progn
      (setq n (rem n len))
      (repeat n
        (setq lst (append (cdr lst) (list (car lst))))
      )
    )
  )
  lst
)

(defun MCTABLE:signed-area (vlist / n sum i p1 p2)
  (setq n   (length vlist)
        sum 0.0
        i   0)
  (while (< i n)
    (setq p1 (nth i vlist)
          p2 (nth (rem (1+ i) n) vlist)
          sum (+ sum (- (* (car p1) (cadr p2))
                        (* (car p2) (cadr p1))))
          i (1+ i)
    )
  )
  (/ sum 2.0)
)

(defun MCTABLE:reverse-if-needed (vlist want-ccw / area)
  (setq area (MCTABLE:signed-area vlist))
  (cond
    ((and want-ccw (< area 0.0)) (reverse vlist))
    ((and (not want-ccw) (> area 0.0)) (reverse vlist))
    (T vlist)
  )
)

;; ============================================================
;; SECCIÓN 3: EXTRACCIÓN DE VÉRTICES DE LWPOLYLINE
;; ============================================================

(defun MCTABLE:get-vertices (ent / vla-obj coords pts)
  (setq vla-obj (vlax-ename->vla-object ent)
        coords  (vlax-get vla-obj 'Coordinates)
        pts     '())
  (while coords
    (setq pts (cons (list (car coords) (cadr coords)) pts)
          coords (cddr coords))
  )
  (reverse pts)
)

;; ============================================================
;; SECCIÓN 3b: ENTRADA NUMÉRICA, SÍMBOLOS E ÍNDICES DE ETIQUETA
;; ============================================================

;; Convierte TXT en un real positivo o devuelve nil. Acepta un signo
;; opcional, dígitos y un único punto decimal; rechaza texto sobrante,
;; exponentes, comas y valores <= 0. Evita el silencio de atof ante
;; entradas como "1abc". Mismo criterio que MC-VERTEX, sin depender de él.
(defun MCTABLE:parsear-positivo (txt / s len i c punto digitos valido val)
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

;; Entero decimal estricto en el rango de AutoLISP; no trunca decimales
;; ni acepta el texto sobrante que atoi ignoraría. MINIMO permite 0 o 1.
(defun MCTABLE:parsear-entero (txt minimo / s i valido val)
  (setq s (if txt (vl-string-trim " \t" txt) "")
        i 1 valido (> (strlen s) 0))
  (while (and valido (<= i (strlen s)))
    (if (not (member (substr s i 1) '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9")))
      (setq valido nil))
    (setq i (1+ i)))
  (if valido
    (progn
      (setq val (atof s))
      (if (and (>= val minimo) (<= val 2147483647.0)) (fix val) nil))
    nil))

;; Las 20 combinaciones de DDPTYPE del catálogo de MC-VERTEX, reproducidas
;; de forma independiente en el espacio de nombres MCTABLE. No hay
;; dependencia de MC-VERTEX ni cambios en PDMODE/PDSIZE.
(defun MCTABLE:lista-modos ()
  '(0 1 2 3 4 32 33 34 35 36 64 65 66 67 68 96 97 98 99 100))

;; Índice del símbolo por defecto: modo 33 = círculo sin marca central, el
;; mismo círculo liso que MCTABLE ya dibujaba. La lista compartida coloca el
;; modo 33 en el índice 6 (el índice 7 corresponde al modo 34, círculo + cruz).
(defun MCTABLE:modo-inicial () 6)

;; Nombres legibles en el mismo orden que MCTABLE:lista-modos.
(defun MCTABLE:nombres-modos ( / nombres outer base)
  (setq nombres nil)
  (foreach outer '("" "Círculo + " "Cuadrado + " "Círculo y cuadrado + ")
    (foreach base '("Punto" "Sin marca central" "Cruz +" "Cruz X" "Trazo vertical")
      (setq nombres (cons (strcat outer base) nombres))))
  (reverse nombres))

;; Radio máximo real del símbolo: base conservadora para las colisiones de
;; etiquetas. Cuadrado o cruz X alcanzan sqrt(2)*radio en sus esquinas; el
;; punto solo es un SOLID diminuto; el estilo invisible no deja huella.
(defun MCTABLE:radio-envolvente (modo radio / base outer rb ro)
  (setq base (rem modo 32)
        outer (- modo base)
        rb (cond ((= base 0) (* radio 0.08 (sqrt 2.0)))
                 ((= base 1) 0.0)
                 ((= base 3) (* radio (sqrt 2.0)))
                 (T radio))
        ro (cond ((= outer 0) 0.0)
                 ((member outer '(64 96)) (* radio (sqrt 2.0)))
                 (T radio)))
  (max rb ro))

;; Previsualización DCL del símbolo elegido en el popup (índice de texto).
(defun MCTABLE:preview (index / modo base outer w h cx cy r i ang x y px py)
  (setq modo (nth (atoi (if index index "0")) (MCTABLE:lista-modos)))
  (if (null modo) (setq modo 33))
  (setq base (rem modo 32)
        outer (- modo base)
        w (dimx_tile "preview_simbolo")
        h (dimy_tile "preview_simbolo")
        cx (fix (/ w 2))
        cy (fix (/ h 2))
        r (fix (/ (min w h) 3)))
  (start_image "preview_simbolo")
  (fill_image 0 0 w h -2)
  (cond
    ((= base 0) (fill_image (1- cx) (1- cy) 3 3 7))
    ((= base 2)
     (vector_image (- cx r) cy (+ cx r) cy 7)
     (vector_image cx (- cy r) cx (+ cy r) 7))
    ((= base 3)
     (vector_image (- cx r) (- cy r) (+ cx r) (+ cy r) 7)
     (vector_image (+ cx r) (- cy r) (- cx r) (+ cy r) 7))
    ((= base 4) (vector_image cx cy cx (- cy r) 7)))
  (if (member outer '(32 96))
    (progn
      (setq i 0
            px (+ cx r)
            py cy)
      (repeat 32
        (setq i (1+ i)
              ang (* 2.0 pi (/ i 32.0))
              x (+ cx (fix (* r (cos ang))))
              y (+ cy (fix (* r (sin ang)))))
        (vector_image px py x y 7)
        (setq px x py y))))
  (if (member outer '(64 96))
    (progn
      (vector_image (- cx r) (- cy r) (+ cx r) (- cy r) 7)
      (vector_image (+ cx r) (- cy r) (+ cx r) (+ cy r) 7)
      (vector_image (+ cx r) (+ cy r) (- cx r) (+ cy r) 7)
      (vector_image (- cx r) (+ cy r) (- cx r) (- cy r) 7)))
  (end_image))

;; Devuelve índices de etiquetas, no una geometría simplificada: los
;; símbolos, las tablas y las colisiones usan todos los vértices.
(defun MCTABLE:indices-anotacion (n omitir / i salto indices)
  (setq i 0 salto (if (>= n 5) (+ 1.0 omitir) 1) indices nil)
  (while (< i n)
    (setq indices (cons (fix i) indices) i (+ i salto)))
  (reverse indices))

;; ============================================================
;; SECCIÓN 4: COLOCACIÓN DE ETIQUETAS DE VÉRTICES
;; ============================================================

;; Motor de colocación equivalente a MC-VERTEX, independiente de su carga.
;; TEXTBOX y TEXT usan la fuente elegida en MCTABLE, sin cambiar TEXTSTYLE.
;; El borde y los centros se reciben en WCS horizontal, con su elevación.

(defun MCTABLE:label-pt-en-poligono (pt verts / n i j inside x y xi yi xj yj)
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

(defun MCTABLE:label-angulo (p1 p2 / dx dy a)
  (setq dx (- (car p2) (car p1))
        dy (- (cadr p2) (cadr p1)))
  (if (and (zerop dx) (zerop dy))
    0.0
    (progn
      (setq a (atan dy dx))
      (if (< a 0.0) (setq a (+ a (* 2.0 pi))))
      a)))

(defun MCTABLE:label-normalizar-angulo (ang / r flip)
  (setq r ang
        flip nil)
  (if (and (>= r (/ pi 2.0)) (< r (/ (* 3.0 pi) 2.0)))
    (progn (setq r (- r pi) flip T))
    (if (>= r (/ (* 3.0 pi) 2.0))
      (setq r (- r (* 2.0 pi)))))
  (list r flip))

(defun MCTABLE:label-clamp (x lo hi)
  (cond ((< x lo) lo) ((> x hi) hi) (T x)))

(defun MCTABLE:label-orient (p q r)
  (- (* (- (car q) (car p)) (- (cadr r) (cadr p)))
     (* (- (cadr q) (cadr p)) (- (car r) (car p)))))

(defun MCTABLE:label-en-segmento (p q r / eps)
  (setq eps 1e-9)
  (and (>= (car q) (- (min (car p) (car r)) eps))
       (<= (car q) (+ (max (car p) (car r)) eps))
       (>= (cadr q) (- (min (cadr p) (cadr r)) eps))
       (<= (cadr q) (+ (max (cadr p) (cadr r)) eps))))

(defun MCTABLE:label-seg-inters (p1 p2 p3 p4 / d1 d2 d3 d4 eps)
  (setq eps 1e-9
        d1 (MCTABLE:label-orient p1 p2 p3)
        d2 (MCTABLE:label-orient p1 p2 p4)
        d3 (MCTABLE:label-orient p3 p4 p1)
        d4 (MCTABLE:label-orient p3 p4 p2))
  (cond
    ;; Contacto colineal: el extremo colineal debe caer dentro del otro.
    ((and (< (abs d1) eps) (MCTABLE:label-en-segmento p1 p3 p2)) T)
    ((and (< (abs d2) eps) (MCTABLE:label-en-segmento p1 p4 p2)) T)
    ((and (< (abs d3) eps) (MCTABLE:label-en-segmento p3 p1 p4)) T)
    ((and (< (abs d4) eps) (MCTABLE:label-en-segmento p3 p2 p4)) T)
    ;; Cruce propio (signos estrictamente opuestos en ambas rectas).
    ((and (< (* d1 d2) 0.0) (< (* d3 d4) 0.0)) T)
    (T nil)))

(defun MCTABLE:label-dist-punto-seg (p a b / dx dy l2 par q)
  (setq dx (- (car b) (car a))
        dy (- (cadr b) (cadr a))
        l2 (+ (* dx dx) (* dy dy)))
  (if (< l2 1e-18)
    (MCTABLE:distance-2d p a)
    (progn
      (setq par (/ (+ (* (- (car p) (car a)) dx)
                      (* (- (cadr p) (cadr a)) dy))
                   l2))
      (if (< par 0.0) (setq par 0.0))
      (if (> par 1.0) (setq par 1.0))
      (setq q (list (+ (car a) (* par dx)) (+ (cadr a) (* par dy))))
      (MCTABLE:distance-2d p q))))

(defun MCTABLE:label-recto-local (rect p / ox oy e1 e2)
  (setq ox (- (car p) (car (nth 0 rect)))
        oy (- (cadr p) (cadr (nth 0 rect)))
        e1 (nth 1 rect)
        e2 (nth 2 rect))
  (list (+ (* ox (car e1)) (* oy (cadr e1)))
        (+ (* ox (car e2)) (* oy (cadr e2)))))

(defun MCTABLE:label-recto-esquinas (rect / o e1 e2 lx ly)
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

(defun MCTABLE:label-punto-en-recto (rect p / l eps)
  (setq l (MCTABLE:label-recto-local rect p)
        eps 1e-9)
  (and (>= (car l) (- eps)) (<= (car l) (+ (nth 3 rect) eps))
       (>= (cadr l) (- eps)) (<= (cadr l) (+ (nth 4 rect) eps))))

(defun MCTABLE:label-dist-punto-recto (rect p / l cx cy o e1 e2)
  (setq l  (MCTABLE:label-recto-local rect p)
        cx (MCTABLE:label-clamp (car l) 0.0 (nth 3 rect))
        cy (MCTABLE:label-clamp (cadr l) 0.0 (nth 4 rect))
        o  (nth 0 rect)
        e1 (nth 1 rect)
        e2 (nth 2 rect))
  (MCTABLE:distance-2d p (list (+ (car o) (* cx (car e1)) (* cy (car e2)))
                           (+ (cadr o) (* cx (cadr e1)) (* cy (cadr e2))))))

(defun MCTABLE:label-recto-seg-inters (rect a b / esq res i)
  (setq esq (MCTABLE:label-recto-esquinas rect)
        res nil
        i 0)
  (while (and (not res) (< i 4))
    (if (MCTABLE:label-seg-inters (nth i esq) (nth (rem (1+ i) 4) esq) a b)
      (setq res T))
    (setq i (1+ i)))
  res)

(defun MCTABLE:label-dist-recto-seg (rect a b / d esq i)
  (if (MCTABLE:label-recto-seg-inters rect a b)
    0.0
    (progn
      (setq d (min (MCTABLE:label-dist-punto-recto rect a)
                   (MCTABLE:label-dist-punto-recto rect b))
            esq (MCTABLE:label-recto-esquinas rect)
            i 0)
      (while (< i 4)
        (setq d (min d (MCTABLE:label-dist-punto-seg (nth i esq) a b)))
        (setq i (1+ i)))
      d)))

(defun MCTABLE:label-recto-fuera-poligono (rect borde / esq fuera i n)
  (setq esq (MCTABLE:label-recto-esquinas rect)
        fuera T
        n (length borde)
        i 0)
  (while (and fuera (< i 4))
    (if (MCTABLE:label-pt-en-poligono (nth i esq) borde) (setq fuera nil))
    (setq i (1+ i)))
  (setq i 0)
  (while (and fuera (< i n))
    (if (MCTABLE:label-punto-en-recto rect (nth i borde)) (setq fuera nil))
    (setq i (1+ i)))
  (setq i 0)
  (while (and fuera (< i n))
    (if (MCTABLE:label-recto-seg-inters rect
                                   (nth i borde)
                                   (nth (rem (1+ i) n) borde))
      (setq fuera nil))
    (setq i (1+ i)))
  fuera)

(defun MCTABLE:label-recto-claro (rect borde abierto claro / n res i b distancia holgura)
  (setq n (length borde)
        res T
        i 0
        ;; La holgura nunca consume un margen positivo, aunque sea diminuto.
        holgura (min 1e-9 (* claro 1e-6)))
  (while (and res (< i n))
    (setq b (if (and abierto (= i (1- n))) nil (nth (rem (1+ i) n) borde)))
    (if b
      (progn
        (setq distancia (MCTABLE:label-dist-recto-seg rect (nth i borde) b))
        (if (or (<= distancia 0.0) (< distancia (- claro holgura)))
          (setq res nil))))
    (setq i (1+ i)))
  res)

(defun MCTABLE:label-recto-libre-circulos (rect circulos env gap / res d c)
  (setq res T)
  (foreach c circulos
    (if res
      (progn
        (setq d (MCTABLE:label-dist-punto-recto rect c))
        (if (< d (+ env gap)) (setq res nil)))))
  res)

(defun MCTABLE:label-recto-candidato (ins rot x1 y1 x2 y2 / cosr sinr e1 e2)
  (setq cosr (cos rot)
        sinr (sin rot)
        e1 (list cosr sinr)
        e2 (list (- sinr) cosr))
  (list (list (+ (car ins) (* x1 (car e1)) (* y1 (car e2)))
              (+ (cadr ins) (* x1 (cadr e1)) (* y1 (cadr e2))))
        e1 e2 (- x2 x1) (- y2 y1)))

(defun MCTABLE:label-proyecciones-caja (rot u nor x1 y1 x2 y2
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

(defun MCTABLE:label-estilo-texto (fuente / st w o)
  (setq st (tblsearch "STYLE" fuente))
  (setq w (if (and st (assoc 41 st)) (cdr (assoc 41 st)) 1.0)
        o (if (and st (assoc 51 st)) (cdr (assoc 51 st)) 0.0))
  (if (< w 1e-6) (setq w 1.0))
  (cons w o))

(defun MCTABLE:label-medir-texto (texto th fuente / ef w o tb p1 p2)
  (setq ef (MCTABLE:label-estilo-texto fuente)
        w  (car ef)
        o  (cdr ef))
  (setq tb (vl-catch-all-apply
             'textbox
             (list (list '(0 . "TEXT")
                         (cons 1 texto)
                         (cons 7 fuente)
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

(defun MCTABLE:label-normal-exterior (ang hay-pol borde / area)
  (if hay-pol
    (progn
      (setq area (MCTABLE:signed-area borde))
      (if (< area 0.0)
        (list (- (sin ang)) (cos ang))
        (list (sin ang) (- (cos ang)))))
    (list (- (sin ang)) (cos ang))))

(defun MCTABLE:label-etiqueta-valida (rect borde abierto circulos env gap claro hay-pol)
  (and (if hay-pol (MCTABLE:label-recto-fuera-poligono rect borde) T)
       (MCTABLE:label-recto-claro rect borde abierto claro)
       (MCTABLE:label-recto-libre-circulos rect circulos env gap)))

;; Convierte solo la copia para anotaciones; las tablas mantienen sus datos.
;; Como MCVERTEX, el motor exterior requiere una fuente horizontal +Z.
(defun MCTABLE:label-wcs (ent verts / ed normal elev)
  (setq ed (entget ent)
        normal (cdr (assoc 210 ed))
        elev (cdr (assoc 38 ed)))
  (if (null normal) (setq normal '(0.0 0.0 1.0)))
  (if (null elev) (setq elev 0.0))
  (if (equal normal '(0.0 0.0 1.0) 1e-6)
    (mapcar '(lambda (pt) (trans (list (car pt) (cadr pt) elev) ent 0)) verts)
    nil))

;; ENTDEL alterna borrado/restauración: nunca repetirlo sobre una borrada.
;; La lista puede conservarse si ESC interrumpe el rollback; el segundo
;; pase desde *error* solo retira las entidades que todavía están activas.
(defun MCTABLE:label-delete (ent)
  (if (and ent (entget ent)) (entdel ent))
  nil)

;; LABEL-CREATED es local al comando: *error* puede limpiar ante ESC.
(defun MCTABLE:label-create (data / antes nuevo)
  (setq antes (entlast))
  (entmake data)
  (setq nuevo (entlast))
  (if (equal antes nuevo)
    nil
    (progn
      (setq label-created (cons nuevo label-created))
      nuevo)))

;; --- Símbolos de vértice ---
;; Equivalentes locales a DDPTYPE con entidades LINE, CIRCLE y un SOLID
;; diminuto; nunca se crean entidades POINT ni se tocan PDMODE/PDSIZE.

(defun MCTABLE:desplazar (p dx dy)
  (list (+ (car p) dx) (+ (cadr p) dy) (caddr p)))

(defun MCTABLE:simbolo-linea (a b layer-name)
  (MCTABLE:label-create
    (list '(0 . "LINE") (cons 8 layer-name) (cons 10 a) (cons 11 b)
          '(210 0.0 0.0 1.0))))

(defun MCTABLE:simbolo-circulo (p r layer-name)
  (MCTABLE:label-create
    (list '(0 . "CIRCLE") (cons 8 layer-name) (cons 10 p) (cons 40 r)
          '(210 0.0 0.0 1.0))))

;; Marca puntual: SOLID diminuto, como el estilo «Punto» de DDPTYPE.
(defun MCTABLE:simbolo-punto (p r layer-name / dot)
  (setq dot (* r 0.08))
  (MCTABLE:label-create
    (list '(0 . "SOLID") (cons 8 layer-name)
          (cons 10 (MCTABLE:desplazar p (- dot) (- dot)))
          (cons 11 (MCTABLE:desplazar p dot (- dot)))
          (cons 12 (MCTABLE:desplazar p (- dot) dot))
          (cons 13 (MCTABLE:desplazar p dot dot))
          '(210 0.0 0.0 1.0))))

;; Símbolo completo (marca central y/o envolvente) en P con radio R.
;; Devuelve T solo si todas sus entidades se crearon; el estilo invisible
;; no crea ninguna y también devuelve T.
(defun MCTABLE:simbolo (p modo r layer-name / base outer a b c d ok)
  (setq base (rem modo 32)
        outer (- modo base)
        a (MCTABLE:desplazar p (- r) (- r))
        b (MCTABLE:desplazar p r (- r))
        c (MCTABLE:desplazar p r r)
        d (MCTABLE:desplazar p (- r) r)
        ok T)
  (cond
    ((= base 0) (setq ok (MCTABLE:simbolo-punto p r layer-name)))
    ((= base 1) nil)
    ((= base 2)
     (setq ok (and (MCTABLE:simbolo-linea (MCTABLE:desplazar p (- r) 0.0)
                                         (MCTABLE:desplazar p r 0.0) layer-name)
                   (MCTABLE:simbolo-linea (MCTABLE:desplazar p 0.0 (- r))
                                         (MCTABLE:desplazar p 0.0 r) layer-name))))
    ((= base 3)
     (setq ok (and (MCTABLE:simbolo-linea a c layer-name)
                   (MCTABLE:simbolo-linea b d layer-name))))
    ((= base 4)
     (setq ok (MCTABLE:simbolo-linea p (MCTABLE:desplazar p 0.0 r) layer-name))))
  (if (member outer '(32 96))
    (setq ok (and ok (MCTABLE:simbolo-circulo p r layer-name))))
  (if (member outer '(64 96))
    (setq ok (and ok
                  (MCTABLE:simbolo-linea a b layer-name)
                  (MCTABLE:simbolo-linea b c layer-name)
                  (MCTABLE:simbolo-linea c d layer-name)
                  (MCTABLE:simbolo-linea d a layer-name))))
  (if ok T nil))

;; Dibuja el símbolo en TODOS los vértices y, opcionalmente, la etiqueta
;; exterior segura. La omisión solo filtra etiquetas; las tablas y los
;; símbolos conservan todos los vértices. Si un entmake falla, se revierten
;; todas las entidades creadas en esta llamada (símbolos y etiquetas).
(defun MCTABLE:label-vertices (vlist layer-name prefijo radio fuente borde
                               inicio omitir modo etiquetar
                             / n i indices v ang u nor th gap claro paso env
                               ja jb a0 b0 a b ins rect texto caja x1 y1 x2 y2 rot proy
                               ef hallado fallo e)
  (setq n (length vlist) i 0 fallo nil label-created nil
        indices (MCTABLE:indices-anotacion n omitir)
        ;; Envolvente máxima del símbolo para colisiones conservadoras.
        env (MCTABLE:radio-envolvente modo radio)
        th (* radio 0.9) gap (* radio 0.35) claro (* radio 0.35)
        paso (* radio 0.5))
  (while (and (< i n) (not fallo))
    (setq v (nth i vlist))
    ;; El símbolo va en todos los vértices: la omisión solo filtra etiquetas.
    (if (not (MCTABLE:simbolo v modo radio layer-name))
      (setq fallo T))
    (if (and (not fallo) etiquetar (member i indices) (>= n 2))
      (progn
        ;; El número corresponde al vértice completo, no al orden de etiquetas.
        (setq texto (strcat prefijo "-" (itoa (+ inicio i)))
              ang (MCTABLE:label-angulo v (nth (rem (1+ i) n) vlist))
              u (list (cos ang) (sin ang))
              nor (MCTABLE:label-normal-exterior ang T borde)
              caja (MCTABLE:label-medir-texto texto th fuente))
        (if (null caja)
          (princ (strcat "\nMCTABLE: textbox no disponible para \"" texto
                         "\"; etiqueta omitida en el vértice " (itoa (1+ i)) "."))
          (progn
            (setq x1 (nth 0 caja) y1 (nth 1 caja)
                  x2 (nth 2 caja) y2 (nth 3 caja)
                  rot (car (MCTABLE:label-normalizar-angulo ang))
                  proy (MCTABLE:label-proyecciones-caja rot u nor x1 y1 x2 y2)
                  a0 (- (+ env gap) (car proy))
                  b0 (- gap (cadr proy))
                  jb 0 hallado nil)
            ;; Mismo orden de búsqueda 8x8: exterior mínimo, luego salida.
            (while (and (not hallado) (< jb 8))
              (setq b (+ b0 (* jb paso)) ja 0)
              (while (and (not hallado) (< ja 8))
                (setq a (+ a0 (* ja paso))
                      ins (list (+ (car v) (* a (car u)) (* b (car nor)))
                                (+ (cadr v) (* a (cadr u)) (* b (cadr nor)))
                                (caddr v))
                      rect (MCTABLE:label-recto-candidato ins rot x1 y1 x2 y2))
                (if (MCTABLE:label-etiqueta-valida rect borde nil vlist env gap claro T)
                  (setq hallado T))
                (setq ja (1+ ja)))
              (setq jb (1+ jb)))
            (if (not hallado)
              (princ (strcat "\nMCTABLE: sin posición exterior válida para \"" texto
                             "\" en el vértice " (itoa (1+ i)) "; etiqueta omitida."))
              (progn
                (setq ef (MCTABLE:label-estilo-texto fuente))
                (if (not (MCTABLE:label-create
                           (list '(0 . "TEXT") (cons 8 layer-name) (cons 7 fuente)
                                 (cons 40 th) (cons 41 (car ef)) (cons 51 (cdr ef))
                                 '(71 . 0) (cons 1 texto) (cons 10 ins) (cons 11 ins)
                                 (cons 50 rot) '(72 . 0) '(73 . 0) '(210 0.0 0.0 1.0))))
                  (setq fallo T))))))))
    (setq i (1+ i)))
  (if (and etiquetar (< n 2))
    (princ "\nMCTABLE: un solo vértice; no hay dirección definida y se omite la etiqueta."))
  (if fallo
    (foreach e label-created (MCTABLE:label-delete e))
    (princ (strcat "\n  " (itoa n) " vértices procesados; "
                   (itoa (if (and etiquetar (>= n 2)) (length indices) 0))
                   " etiquetas exteriores seguras.")))
  (setq label-created nil)
  (not fallo))

;; ============================================================
;; SECCIÓN 5: CREACIÓN DE TABLAS CON PROTECCIÓN ACTIVEX
;; ============================================================

;; --- Altura y estilo de texto de las tablas (independientes del usuario) ---

;; Solo dígitos y un punto decimal: sin signos, comas ni exponentes.
;; Devuelve la altura numérica o nil; nunca acepta un prefijo numérico.
(defun MCTABLE:altura-tabla-valida (texto / limpio n i c punto digitos valido valor)
  (setq limpio  (vl-string-trim " \t" (if texto texto ""))
        n       (strlen limpio)
        i       1
        punto   nil
        digitos 0
        valido  (> n 0))
  (while (and valido (<= i n))
    (setq c (ascii (substr limpio i 1)))
    (cond
      ((= c 46) (if punto (setq valido nil) (setq punto T)))
      ((and (>= c 48) (<= c 57)) (setq digitos (1+ digitos)))
      (T (setq valido nil)))
    (setq i (1+ i)))
  (if (or (not valido) (zerop digitos))
    nil
    (progn
      (setq valor (atof limpio))
      (if (> valor 0.0) valor nil))))

;; Un estilo sirve solo si su fuente es la elegida y tiene altura fija 0, ancho 1,
;; sin oblicuidad y sin las marcas de texto vertical (DXF 70) ni invertido/hacia
;; atrás (DXF 71).
(defun MCTABLE:table-style-compatible (ed esperada / fuente grande fijo ancho
                                       oblicuo flags gen)
  (if ed
    (progn
      (setq fuente  (if (assoc 3 ed) (strcase (cdr (assoc 3 ed)) T) nil)
            grande  (if (assoc 4 ed) (cdr (assoc 4 ed)) "")
            fijo    (if (assoc 40 ed) (cdr (assoc 40 ed)) 0.0)
            ancho   (if (assoc 41 ed) (cdr (assoc 41 ed)) 1.0)
            oblicuo (if (assoc 50 ed) (cdr (assoc 50 ed)) 0.0)
            flags   (if (assoc 70 ed) (cdr (assoc 70 ed)) 0)
            gen     (if (assoc 71 ed) (cdr (assoc 71 ed)) 0))
      (and (equal fuente (strcase esperada T))
           (equal grande "")
           (equal fijo 0.0)
           (equal ancho 1.0)
           (equal oblicuo 0.0)
           (zerop (logand 6 flags))
           (zerop (logand 6 gen))))))

;; Crea una sola vez, o reutiliza, el estilo privado de las tablas. Si el nombre
;; ya existe con otra definición se prueba un sufijo nuevo en vez de redefinirlo.
(defun MCTABLE:table-style ( / base nombre n estilo fuente dir ruta fallo)
  (setq base   "MCTABLE-TABLAS"
        n      0
        estilo nil
        fuente nil
        fallo  nil)
  ;; Elección determinista de fuente: Arial si se localiza (rutas de AutoCAD o
  ;; carpeta Fonts de Windows) y, si no, la fuente estándar de AutoCAD. El
  ;; nombre se guarda sin ruta para que el dibujo no dependa de otra máquina.
  (setq ruta (findfile "arial.ttf"))
  (if (null ruta)
    (progn
      (setq dir (getenv "WINDIR"))
      (if (null dir) (setq dir (getenv "SystemRoot")))
      (if dir
        (setq ruta (findfile (strcat dir "\\Fonts\\arial.ttf"))))))
  (cond
    (ruta (setq fuente "arial.ttf"))
    ((findfile "txt.shx") (setq fuente "txt.shx"))
    ((findfile "simplex.shx") (setq fuente "simplex.shx")))
  (cond
    ((null fuente)
     (princ (strcat "\nMCTABLE: error: no se encontró ninguna fuente admitida"
                    " (Arial, txt.shx, simplex.shx)."
                    "\nMCTABLE: no se creó el estilo de texto ni se dibujó ninguna tabla."))
     nil)
    (T
     ;; Aviso explícito cuando se usa el respaldo estándar en lugar de Arial.
     (if (/= fuente "arial.ttf")
       (princ (strcat "\nMCTABLE: aviso: no se encontró Arial (arial.ttf);"
                      " las tablas usarán la fuente " fuente ".")))
     ;; Bucle acotado: solo prueba nombres con sufijo mientras el anterior existe
     ;; con otra definición. Un fallo de creación termina el bucle de inmediato.
     (while (and (null estilo) (not fallo) (< n 100))
       (setq nombre (if (zerop n) base (strcat base "-" (itoa n))))
       (cond
         ((null (tblsearch "STYLE" nombre))
          (setq estilo
            (if (entmake
                  (list '(0 . "STYLE")
                        '(100 . "AcDbSymbolTableRecord")
                        '(100 . "AcDbTextStyleTableRecord")
                        (cons 2 nombre)
                        '(70 . 0)
                        '(40 . 0.0)
                        '(41 . 1.0)
                        '(50 . 0.0)
                        '(71 . 0)
                        '(42 . 2.5)
                        (cons 3 fuente)
                        '(4 . "")))
              (tblsearch "STYLE" nombre)
              nil))
          ;; Un fallo de creación, o un registro creado que no cumple el
          ;; predicado, termina el bucle: no se reintenta crear ni se sufija.
          (if (or (null estilo)
                  (not (MCTABLE:table-style-compatible estilo fuente)))
            (setq fallo T
                  estilo nil)))
         ((MCTABLE:table-style-compatible (tblsearch "STYLE" nombre) fuente)
          (setq estilo (tblsearch "STYLE" nombre)))
         (T (setq n (1+ n)))))
     (cond
       ((and (not fallo) estilo
             (MCTABLE:table-style-compatible estilo fuente))
        (cdr (assoc 2 estilo)))
       (fallo
        (princ (strcat "\nMCTABLE: error: no se pudo crear el estilo privado de las tablas ("
                       base ")."
                       "\nMCTABLE: no se dibujó ninguna tabla."))
        nil)
       (T
        (princ (strcat "\nMCTABLE: error: no hay un nombre libre y compatible para el estilo privado "
                       base "."
                       "\nMCTABLE: no se dibujó ninguna tabla."))
        nil)))))

;; Medir texto visible, no los códigos de formato de TABLE/MTEXT.
(defun MCTABLE:table-text-box (texto altura fuente)
  (setq texto (vl-string-subst "" "{\\b " texto)
        texto (vl-string-subst "" "}" texto)
        texto (vl-string-subst (chr 176) "%%d" texto))
  (MCTABLE:label-medir-texto texto altura fuente))

;; Los rótulos de estación se escriben en negrita con el código «{\b N}».
;; La medición descarta ese código, así que se detecta aquí para dejar una
;; holgura pequeña solo en esas celdas y que la negrita no recorte el glifo.
(defun MCTABLE:table-texto-negrita (texto)
  (and texto (vl-string-search "{\\b " texto)))

;; El texto y la geometría usan la misma escala, sin modificar TABLESTYLE.
;; La altura y el estilo llegan explícitos: aquí no se leen TEXTSIZE ni TEXTSTYLE.
;; Se mide cada celda para conservar títulos, encabezados y datos en una línea.
;; Las dos tablas usan el mismo criterio compacto: ancho medido más los márgenes,
;; sin porcentajes extra sobre el texto. La única excepción es un mínimo fijo en
;; la columna de estaciones: la caja de tinta medida queda más ajustada que el
;; ancho real de ajuste de la tabla nativa, y sin ese mínimo el encabezado «EST»
;; se parte en dos líneas. MCTABLE:equalize-tables iguala después el tamaño final
;; de ambas.
(defun MCTABLE:format-table (tbl rows alto fuente / margen-h margen-v
                            widths title-width r c altura caja ancho alto-caja
                            row-heights row-height extra result texto negrita)
  (setq margen-h (* alto 0.5)
        margen-v (* alto 0.5)
        ;; Mínimo de la columna de estaciones: cuatro alturas de texto cubren
        ;; los tres caracteres de «EST» más el margen horizontal de cada lado
        ;; en las fuentes privadas admitidas. Es un piso, no un tope: los datos
        ;; medidos y la holgura de la negrita siguen ampliándola.
        widths (list (* 4.0 alto) 0.0 0.0)
        ;; El número de vértices solo añade filas; nunca comprime el formato.
        row-heights nil
        title-width 0.0)
  (setq result
    (vl-catch-all-apply
      '(lambda ()
         ;; 7 incluye título, encabezados y datos; las alturas se fijan por celda.
         (vla-SetTextStyle tbl 7 fuente)
         (vla-SetTextHeight tbl 7 alto)
         (vla-put-HorzCellMargin tbl margen-h)
         (vla-put-VertCellMargin tbl margen-v)
         (setq r 0)
         (while (< r rows)
           (setq c 0
                 altura (if (= r 0) (* alto 1.25) alto)
                 row-height (* altura 2.2))
           (while (< c (if (= r 0) 1 3))
             (vla-SetCellTextHeight tbl r c altura)
             (vla-SetCellAlignment tbl r c 5)
             (setq texto (vla-GetText tbl r c)
                   caja (MCTABLE:table-text-box texto altura fuente)
                   ;; Ancho medido más márgenes, sin inflarlo. La única holgura
                   ;; es la de los rótulos en negrita, cuya medición es más fina.
                   negrita (if (MCTABLE:table-texto-negrita texto) 1.08 1.0)
                   ancho (+ (* negrita (- (nth 2 caja) (nth 0 caja))) (* 2.0 margen-h))
                   alto-caja (+ (* 1.2 (- (nth 3 caja) (nth 1 caja))) (* 2.0 margen-v))
                   row-height (max row-height alto-caja))
             (if (= r 0)
               (setq title-width ancho)
               (setq widths
                 (list (if (= c 0) (max (car widths) ancho) (car widths))
                       (if (= c 1) (max (cadr widths) ancho) (cadr widths))
                       (if (= c 2) (max (caddr widths) ancho) (caddr widths)))))
             (setq c (1+ c)))
           (setq row-heights (cons row-height row-heights)
                 r (1+ r)))
         ;; Si el título requiere más espacio, ensanchar las columnas de datos,
         ;; no la columna de estaciones. No partir palabras ni reducir el texto.
         (setq extra (max 0.0 (- title-width (apply '+ widths)))
               widths (list (car widths)
                            (+ (cadr widths) (/ extra 2.0))
                            (+ (caddr widths) (/ extra 2.0)))
               c 0)
         (foreach ancho widths
           (vla-SetColumnWidth tbl c ancho)
           (setq c (1+ c)))
         (setq r 0)
         (foreach row-height (reverse row-heights)
           (vla-SetRowHeight tbl r row-height)
           (setq r (1+ r))))
      nil))
  (if (vl-catch-all-error-p result)
    (progn
      (princ (strcat "\nMCTABLE: no se pudo ajustar la tabla: "
                     (vl-catch-all-error-message result)))
      (exit)))
  tbl)

;; Ancho total de una tabla ya dibujada: suma de sus columnas.
(defun MCTABLE:table-total-width (tbl / c total)
  (setq c 0
        total 0.0)
  (while (< c (vla-get-Columns tbl))
    (setq total (+ total (vla-GetColumnWidth tbl c))
          c (1+ c)))
  total)

;; Iguala el tamaño de las dos tablas ya dibujadas: mismo ancho total y la misma
;; altura en cada fila correspondiente. Solo se amplía la tabla más angosta y las
;; filas más bajas, nunca se reduce lo medido, así que no se recorta el texto.
;; El ancho extra va a las columnas de datos (1 y 2); la columna de estaciones
;; conserva su ancho medido.
(defun MCTABLE:equalize-tables (tbl-a tbl-b / total-a total-b delta destino
                               extra-a extra-b filas r alto-a alto-b alto-ambas
                               result)
  (setq result
    (vl-catch-all-apply
      '(lambda ()
         (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-a :vlax-true))
         (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-b :vlax-true))
         (setq total-a (MCTABLE:table-total-width tbl-a)
               total-b (MCTABLE:table-total-width tbl-b))
         ;; Ancho: se amplía la más angosta hasta el ancho de la otra.
         (if (< total-a total-b)
           (setq destino tbl-a delta (- total-b total-a))
           (setq destino tbl-b delta (- total-a total-b)))
         (if (> delta 1e-6)
           (progn
             (setq extra-a (/ delta 2.0)
                   extra-b (- delta extra-a))
             (vla-SetColumnWidth destino 1
               (+ (vla-GetColumnWidth destino 1) extra-a))
             (vla-SetColumnWidth destino 2
               (+ (vla-GetColumnWidth destino 2) extra-b))))
         ;; Alturas: cada fila toma la mayor de las dos, sin bajar ninguna.
         (setq filas (min (vla-get-Rows tbl-a) (vla-get-Rows tbl-b))
               r 0)
         (while (< r filas)
           (setq alto-a (vla-GetRowHeight tbl-a r)
                 alto-b (vla-GetRowHeight tbl-b r)
                 alto-ambas (max alto-a alto-b))
           (if (> (- alto-ambas (min alto-a alto-b)) 1e-6)
             (progn
               (vla-SetRowHeight tbl-a r alto-ambas)
               (vla-SetRowHeight tbl-b r alto-ambas)))
           (setq r (1+ r)))
         (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-a :vlax-false))
         (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-b :vlax-false))
         (vla-Update tbl-a)
         (vla-Update tbl-b))
      nil)
  )
  (if (vl-catch-all-error-p result)
    (progn
      ;; Las dos tablas ya están dibujadas: solo se avisa, no se borra ninguna.
      (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-a :vlax-false))
      (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-b :vlax-false))
      (princ (strcat "\nMCTABLE: aviso: no se pudieron igualar las tablas: "
                     (vl-catch-all-error-message result)))))
  )

;; 5.1: Tabla de Coordenadas
(defun MCTABLE:create-table (ins-pt vlist decimals xy-order title-str alto fuente inicio /
                             tbl-obj rows cols row-idx idx v xval yval
                             col1-hdr col2-hdr doc space cell-align
                             row-height)
  (if xy-order
    (setq col1-hdr "ESTE (X)"   col2-hdr "NORTE (Y)")
    (setq col1-hdr "NORTE (Y)"  col2-hdr "ESTE (X)")
  )

  (setq rows  (+ 2 (length vlist))
        cols  3
        doc   (vla-get-ActiveDocument (vlax-get-acad-object))
        space (vla-get-ModelSpace doc)
        cell-align 5
        row-height (* alto 2.2)
  )

  (setq tbl-obj
    (vla-AddTable space (vlax-3d-point ins-pt) rows cols row-height (* alto 8.0))
  )
  (setq table-pending tbl-obj)

  (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-obj :vlax-true))

  (vl-catch-all-apply 'vla-SetText (list tbl-obj 0 0 title-str))
  (vl-catch-all-apply 'vla-MergeCells (list tbl-obj 0 0 0 (1- cols)))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 0 0 cell-align))

  (vl-catch-all-apply 'vla-SetText (list tbl-obj 1 0 "EST"))
  (vl-catch-all-apply 'vla-SetText (list tbl-obj 1 1 col1-hdr))
  (vl-catch-all-apply 'vla-SetText (list tbl-obj 1 2 col2-hdr))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 0 cell-align))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 1 cell-align))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 2 cell-align))

  (setq row-idx 2
        idx 0)
  (foreach v vlist
    (setq xval (car v) yval (cadr v))
    ;; La columna EST de la tabla usa la misma numeración que las etiquetas.
    (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 0 (itoa (+ inicio idx))))
    (if xy-order
      (progn
        (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 1 (rtos xval 2 decimals)))
        (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 2 (rtos yval 2 decimals)))
      )
      (progn
        (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 1 (rtos yval 2 decimals)))
        (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 2 (rtos xval 2 decimals)))
      )
    )
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 0 cell-align))
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 1 cell-align))
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 2 cell-align))
    (setq row-idx (1+ row-idx)
          idx (1+ idx))
  )

  (MCTABLE:format-table tbl-obj rows alto fuente)

  (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-obj :vlax-false))
  (vla-Update tbl-obj)
  (setq table-pending nil)
  tbl-obj
)

;; 5.2: Tabla de Rumbos y Distancias
(defun MCTABLE:create-bearing-table (ins-pt vlist decimals title-str alto fuente inicio /
                                     tbl-obj rows cols row-idx i n p1 p2
                                     doc space cell-align row-height
                                     est-lbl rumbo-lbl dist-lbl)
  (setq n             (length vlist)
        rows          (+ 2 n)
        cols          3
        doc           (vla-get-ActiveDocument (vlax-get-acad-object))
        space         (vla-get-ModelSpace doc)
        cell-align    5
        row-height    (* alto 2.2)
  )

  (setq tbl-obj
    (vla-AddTable space (vlax-3d-point ins-pt) rows cols row-height (* alto 8.0))
  )
  (setq table-pending tbl-obj)

  (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-obj :vlax-true))

  (vl-catch-all-apply 'vla-SetText (list tbl-obj 0 0 title-str))
  (vl-catch-all-apply 'vla-MergeCells (list tbl-obj 0 0 0 (1- cols)))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 0 0 cell-align))

  (vl-catch-all-apply 'vla-SetText (list tbl-obj 1 0 "EST"))
  (vl-catch-all-apply 'vla-SetText (list tbl-obj 1 1 "RUMBO"))
  (vl-catch-all-apply 'vla-SetText (list tbl-obj 1 2 "DISTANCIA (m)"))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 0 cell-align))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 1 cell-align))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 2 cell-align))

  (setq i 0)
  (while (< i n)
    (setq p1        (nth i vlist)
          p2        (if (= i (1- n)) (nth 0 vlist) (nth (1+ i) vlist))
          est-lbl   (strcat "{\\b " (itoa (+ inicio i)) "}")
          rumbo-lbl (MCTABLE:get-bearing p1 p2)
          dist-lbl  (rtos (MCTABLE:distance-2d p1 p2) 2 decimals)
          row-idx   (+ i 2)
    )
    
    (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 0 est-lbl))
    (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 1 rumbo-lbl))
    (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 2 dist-lbl))
    
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 0 cell-align))
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 1 cell-align))
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 2 cell-align))
    
    (setq i (1+ i))
  )

  (MCTABLE:format-table tbl-obj rows alto fuente)

  (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-obj :vlax-false))
  (vla-Update tbl-obj)
  (setq table-pending nil)
  tbl-obj
)

;; Guarda lo escrito en el diálogo, incluidas las entradas inválidas: se
;; conservan las cadenas crudas de radio, inicio y omisión para reponerlas
;; al reabrir el cuadro tras elegir el origen.
(defun MCTABLE:guardar-apariencia ()
  (setq radio-raw  (get_tile "txt_radio_vertice")
        inicio-raw (get_tile "txt_inicio")
        omitir-raw (get_tile "txt_omitir")
        tag-prefix (get_tile "txt_prefijo_tag")
        tag-font   (get_tile "txt_fuente_tag")
        label-on   (= (get_tile "ck_etiquetas") "1")
        symbol-idx (atoi (get_tile "pl_simbolo")))
  (if (or (< symbol-idx 0) (>= symbol-idx (length (MCTABLE:lista-modos))))
    (setq symbol-idx (MCTABLE:modo-inicial)))
  (princ))

;; Repone todos los controles desde el estado del comando. El popup del
;; símbolo conserva el índice elegido y actualiza la previsualización.
(defun MCTABLE:cargar-dialogo ()
  (set_tile "rb_ccw"  (if opt-cw "0" "1"))
  (set_tile "rb_cw"   (if opt-cw "1" "0"))
  (set_tile "rb_xy"   (if opt-yx "0" "1"))
  (set_tile "rb_yx"   (if opt-yx "1" "0"))
  (set_tile "eb_dec"  (itoa decimals))
  (set_tile "txt_radio_vertice" radio-raw)
  (set_tile "txt_inicio"        inicio-raw)
  (set_tile "txt_omitir"        omitir-raw)
  (set_tile "txt_prefijo_tag"   tag-prefix)
  (set_tile "txt_fuente_tag"    tag-font)
  (set_tile "ck_etiquetas"      (if label-on "1" "0"))
  ;; Se repone la altura escrita, aunque no se haya aceptado el cuadro.
  (set_tile "eb_altura_tabla"   altura-tile)
  (set_tile "txt_altura_error"  "")
  (set_tile "txt_vertice_error" "")
  (start_list "pl_simbolo")
  (mapcar 'add_list (MCTABLE:nombres-modos))
  (end_list)
  (set_tile "pl_simbolo" (itoa symbol-idx))
  (MCTABLE:preview (itoa symbol-idx))
  (princ))

;; Aceptar valida altura, radio, inicio y omisión: si algo no sirve, el
;; cuadro sigue abierto con el foco en el campo inválido y sin perder texto.
(defun MCTABLE:aceptar-dialogo (/ error-foco error-texto)
  (MCTABLE:guardar-apariencia)
  (setq decimals (atoi (get_tile "eb_dec")))
  (if (or (< decimals 0) (> decimals 8))
    (progn (set_tile "eb_dec" "2") (setq decimals 2)))
  (setq altura-tabla (MCTABLE:altura-tabla-valida (get_tile "eb_altura_tabla"))
        circle-rad   (MCTABLE:parsear-positivo radio-raw)
        inicio       (MCTABLE:parsear-entero inicio-raw 1)
        omitir       (MCTABLE:parsear-entero omitir-raw 0)
        symbol-mode  (nth symbol-idx (MCTABLE:lista-modos)))
  (setq error-foco  nil
        error-texto "")
  (cond
    ((null altura-tabla)
     (setq error-texto "Altura inválida: escriba un número mayor que cero (ejemplo 1.0)."
           error-foco "eb_altura_tabla"))
    ((null circle-rad)
     (setq error-texto "Radio inválido: escriba un número positivo (ejemplo 1.0)."
           error-foco "txt_radio_vertice"))
    ((null inicio)
     (setq error-texto "Número inicial inválido: entero entre 1 y 2147483647."
           error-foco "txt_inicio"))
    ((null omitir)
     (setq error-texto "Vértices a omitir inválidos: entero entre 0 y 2147483647."
           error-foco "txt_omitir")))
  (cond
    (error-foco
     (set_tile "txt_altura_error"  (if (= error-foco "eb_altura_tabla") error-texto ""))
     (set_tile "txt_vertice_error" (if (= error-foco "eb_altura_tabla") "" error-texto))
     (mode_tile error-foco 2))
    ;; El estilo invisible solo produce etiquetas: sin ellas no habría
    ;; ninguna salida que crear, porque ese estilo no dibuja símbolos.
    ((and (= symbol-mode 1) (not label-on))
     (alert (strcat "El símbolo invisible no genera símbolos de vértice.\n"
                    "Active las etiquetas o elija otro símbolo.")))
    (T
     (set_tile "txt_altura_error" "")
     (set_tile "txt_vertice_error" "")
     (setq altura-tile (get_tile "eb_altura_tabla"))
     (done_dialog 1))))

;; Acciones del diálogo, compartidas por la apertura inicial y las reaperturas.
;; Las expresiones escriben las variables locales de C:MCTABLE (ámbito dinámico).
(defun MCTABLE:dialog-actions ()
  (action_tile "rb_ccw"   "(setq opt-cw nil)")
  (action_tile "rb_cw"    "(setq opt-cw T)")
  (action_tile "rb_xy"    "(setq opt-yx nil)")
  (action_tile "rb_yx"    "(setq opt-yx T)")
  (action_tile "eb_dec"   "(setq decimals (atoi (get_tile \"eb_dec\")))(if (or (< decimals 0)(> decimals 8))(progn (set_tile \"eb_dec\" \"2\")(setq decimals 2)))")
  (action_tile "txt_prefijo_tag"   "(setq tag-prefix (get_tile \"txt_prefijo_tag\"))")
  (action_tile "txt_radio_vertice" "(setq radio-raw (get_tile \"txt_radio_vertice\"))")
  (action_tile "txt_fuente_tag"    "(setq tag-font (get_tile \"txt_fuente_tag\"))")
  (action_tile "pl_simbolo" "(MCTABLE:preview $value)")
  ;; Guardar lo escrito —incluidas entradas inválidas— antes de salir a
  ;; elegir el origen: al volver se reponen también las opciones nuevas.
  (action_tile "eb_altura_tabla"   "(setq altura-tile (get_tile \"eb_altura_tabla\"))")
  (action_tile "btn_orig" "(MCTABLE:guardar-apariencia)(setq altura-tile (get_tile \"eb_altura_tabla\"))(done_dialog 2)")
  (action_tile "accept" "(MCTABLE:aceptar-dialogo)")
  (action_tile "cancel"   "(done_dialog 0)")
  (princ))

;; ============================================================
;; SECCIÓN 6: FUNCIÓN PRINCIPAL - COMANDO MCTABLE
;; ============================================================

(defun C:MCTABLE (/
  *error* old-osmode old-cmdecho old-blipmode
  dcl-file dcl-id sel ent ent-type vertices
  opt-cw opt-yx decimals origin-idx ordered-verts
  ins-pt ins-pt2 lyr-etiq click-pt dlg-result start-pt
  lyr-data lyr-ent lyr-ed
  tag-prefix circle-rad tag-font label-verts label-border label-created e table-pending
  radio-raw inicio-raw omitir-raw label-on inicio omitir
  symbol-idx symbol-mode
  tbl-coord tbl-rumbo
  altura-tabla altura-tile estilo-tabla
)

  (defun *error* (msg)
    (vl-catch-all-apply
      '(lambda ()
         (foreach e label-created
           (vl-catch-all-apply 'MCTABLE:label-delete (list e)))
         (setq label-created nil)
         ;; Solo retirar la tabla nueva que todavía no terminó de formatearse.
         (if table-pending
           (vl-catch-all-apply 'vla-Delete (list table-pending)))
         (setq table-pending nil)
         (if old-osmode   (setvar "OSMODE"   old-osmode))
         (if old-cmdecho  (setvar "CMDECHO"  old-cmdecho))
         (if old-blipmode (setvar "BLIPMODE" old-blipmode))
         (if (and dcl-id (>= dcl-id 0))
           (vl-catch-all-apply 'done_dialog '(0))
         )
         (if (and dcl-file (findfile dcl-file))
           (vl-file-delete dcl-file)
         )
       )
      nil
    )
    (if (not (member msg '("Function cancelled" "quit / exit abort" "")))
      (princ (strcat "\nError MCTABLE: " msg))
    )
    (princ "\nComando MCTABLE finalizado de forma segura.\n")
    (princ)
  )

  (setq old-osmode   (getvar "OSMODE")
        old-cmdecho  (getvar "CMDECHO")
        old-blipmode (getvar "BLIPMODE")
  )
  (setvar "CMDECHO"  0)
  (setvar "BLIPMODE" 0)

  (vl-load-com)
  (princ "\n=== MCTABLE: Cuadros Técnicos UTM ===")

  (setq ent nil)
  (while (null ent)
    (setq sel (entsel "\nSeleccione una POLILÍNEA CERRADA (LWPOLYLINE): "))
    (if (null sel)
      (princ "\nNo se seleccionó ningún objeto. Intente de nuevo.")
      (progn
        (setq ent      (car sel)
              ent-type (cdr (assoc 0 (entget ent)))
        )
        (cond
          ((not (equal ent-type "LWPOLYLINE"))
           (princ (strcat "\n¡Objeto no válido! Tipo: " ent-type ". Seleccione solo polilíneas."))
           (setq ent nil)
          )
          ((zerop (cdr (assoc 70 (entget ent))))
           (princ "\n¡La polilínea NO está cerrada!")
           (setq ent nil)
          )
          (T (princ "\n  Polilínea cerrada seleccionada correctamente."))
        )
      )
    )
  )

  (setq vertices (MCTABLE:get-vertices ent))
  (setq vertices (MCTABLE:clean-vertices vertices))
  (princ (strcat "\n  Vértices Únicos Encontrados: " (itoa (length vertices))))

  (setq opt-cw     T
        opt-yx     nil
        decimals   2
        origin-idx 0
        click-pt   nil
        tag-prefix "E"
        circle-rad 1.0
        ;; Cadenas crudas del cuadro: conservan incluso las entradas inválidas.
        radio-raw  "1.0"
        label-on   T
        inicio     1
        inicio-raw "1"
        omitir     0
        omitir-raw "0"
        ;; 6 -> modo 33: círculo sin marca central (predeterminado).
        symbol-idx (MCTABLE:modo-inicial)
        symbol-mode 33
        tag-font   "Standard"
        ;; Altura de texto de las tablas: predeterminado fijo, nunca TEXTSIZE.
        altura-tabla 1.0
        altura-tile  "1.0"
  )

  (setq dcl-file (vl-filename-mktemp "mctbl" nil ".dcl"))
  (if (not (MCTABLE:write-dcl dcl-file)) (exit))

  (setq dcl-id (load_dialog dcl-file))
  (if (< dcl-id 0) (progn (if (findfile dcl-file) (vl-file-delete dcl-file)) (exit)))

  (if (not (new_dialog "mctable_dlg" dcl-id))
    (progn (unload_dialog dcl-id) (if (findfile dcl-file) (vl-file-delete dcl-file)) (exit))
  )

  (MCTABLE:cargar-dialogo)
  (set_tile "txt_orig"
    (strcat "Vértice 1: (" (rtos (car (car vertices)) 2 2) ", " (rtos (cadr (car vertices)) 2 2) ")")
  )

  (MCTABLE:dialog-actions)

  (setq dlg-result 0)
  (while (= (setq dlg-result (start_dialog)) 2)
    (setvar "OSMODE" 1)
    (setq click-pt (getpoint "\nHaga clic cerca del vértice que desea como Origen (Punto 1): "))

    (if (not (new_dialog "mctable_dlg" dcl-id))
      (setq dlg-result 0)
      (progn
        ;; Se reponen todos los controles desde el estado crudo del comando:
        ;; las opciones nuevas y la previsualización conservan su valor.
        (MCTABLE:cargar-dialogo)
        (if click-pt
          (progn
            (setq origin-idx (MCTABLE:closest-vertex (list (car click-pt) (cadr click-pt)) vertices))
            (set_tile "txt_orig" (strcat "Vértice " (itoa (1+ origin-idx)) ": ("
                                         (rtos (car (nth origin-idx vertices)) 2 2) ", "
                                         (rtos (cadr (nth origin-idx vertices)) 2 2) ")"))
          )
          (set_tile "txt_orig" "Vértice 1 (Predeterminado)")
        )
        (MCTABLE:dialog-actions)
      )
    )
  )

  (unload_dialog dcl-id)
  (setq dcl-id nil)
  (if (findfile dcl-file) (vl-file-delete dcl-file))

  (if (/= dlg-result 1)
    (progn
      (princ "\nComando MCTABLE cancelado por el usuario.")
      (setvar "OSMODE" old-osmode) (setvar "CMDECHO" old-cmdecho) (setvar "BLIPMODE" old-blipmode)
      (exit)
    )
  )

  ;; TODAS las filas de las tablas llevan número de estación: se valida el
  ;; desbordamiento con el último vértice completo (las omisiones solo
  ;; afectan a las etiquetas) antes de crear etiquetas o tablas.
  (if (> (+ (float inicio) (float (1- (length vertices)))) 2147483647.0)
    (progn
      (alert (strcat "La numeración de las tablas excede 2147483647.\n"
                     "Reduzca el número inicial."))
      (princ "\nMCTABLE: numeración fuera de rango; no se dibujó nada.")
      (setvar "OSMODE" old-osmode) (setvar "CMDECHO" old-cmdecho) (setvar "BLIPMODE" old-blipmode)
      (exit)
    )
  )

  ;; Estilo privado de las tablas: se resuelve antes de dibujar, para que un
  ;; fallo de recurso no deje anotaciones a medias.
  (setq estilo-tabla (MCTABLE:table-style))
  (if (null estilo-tabla)
    (progn
      (princ "\nMCTABLE: no se pudo crear el estilo privado de las tablas (Arial).")
      (princ "\nNo se dibujó nada.")
      (setvar "OSMODE" old-osmode) (setvar "CMDECHO" old-cmdecho) (setvar "BLIPMODE" old-blipmode)
      (exit)
    )
  )

  (princ "\nProcesando matrices topográficas...")
  (setq ordered-verts (MCTABLE:reverse-if-needed vertices (not opt-cw)))
  (setq start-pt (if click-pt (list (car click-pt) (cadr click-pt)) (car vertices)))
  (setq origin-idx (MCTABLE:closest-vertex start-pt ordered-verts))
  (setq ordered-verts (MCTABLE:rotate-list ordered-verts origin-idx))

  (setq lyr-etiq "MCTABLE-LABELS")
  (setq lyr-data (tblsearch "LAYER" lyr-etiq))
  (if (null lyr-data)
    (entmake
      (list
        '(0  . "LAYER")
        '(100 . "AcDbSymbolTableRecord")
        '(100 . "AcDbLayerTableRecord")
        (cons 2  lyr-etiq)
        '(70 . 0)
        '(62 . 3)
        '(6  . "Continuous")
      )
    )
    (if (/= (cdr (assoc 62 lyr-data)) 3)
      (progn
        (setq lyr-ent (tblobjname "LAYER" lyr-etiq)
              lyr-ed  (entget lyr-ent))
        (entmod
          (subst (cons 62 3)
                 (assoc 62 lyr-ed)
                 lyr-ed)
        )
      )
    )
  )

  (princ "\nDibujando símbolos y numeración de vértices...")
  (setq label-verts (MCTABLE:label-wcs ent ordered-verts)
        label-border (MCTABLE:label-wcs ent
                       (MCTABLE:reverse-if-needed (MCTABLE:get-vertices ent) (not opt-cw))))
  (if label-verts
    (if (not (MCTABLE:label-vertices label-verts lyr-etiq tag-prefix circle-rad tag-font label-border
                                     inicio omitir symbol-mode label-on))
      (progn
        (princ "\nMCTABLE: falló la creación de anotaciones; se revirtieron las creadas.")
        (exit)))
    (princ "\nMCTABLE: símbolos y etiquetas omitidos; se requiere una polilínea horizontal con normal +Z."))

  (setvar "OSMODE" 0)
  (setq ins-pt (getpoint "\nIndique el punto de inserción para la TABLA DE COORDENADAS: "))
  (if ins-pt
    (progn
      (princ "\nConstruyendo tabla de coordenadas...")
      (setq tbl-coord
        (MCTABLE:create-table
          (list (car ins-pt) (cadr ins-pt) (if (caddr ins-pt) (caddr ins-pt) 0.0))
          ordered-verts
          decimals
          (not opt-yx)
          "COORDENADAS GEORREFERENCIADAS"
          altura-tabla
          estilo-tabla
          inicio
        ))
      (princ "\nTabla de coordenadas dibujada.")
    )
    (progn
      (princ "\nPunto inválido. Ejecución abortada.")
      (setvar "OSMODE" old-osmode) (setvar "CMDECHO" old-cmdecho) (setvar "BLIPMODE" old-blipmode)
      (exit)
    )
  )

  (setq ins-pt2 (getpoint "\nIndique el punto de inserción para la TABLA DE RUMBOS Y DISTANCIAS: "))
  (if ins-pt2
    (progn
      (princ "\nConstruyendo tabla de rumbos y distancias...")
      (setq tbl-rumbo
        (MCTABLE:create-bearing-table
          (list (car ins-pt2) (cadr ins-pt2) (if (caddr ins-pt2) (caddr ins-pt2) 0.0))
          ordered-verts
          decimals
          "CUADRO DE RUMBOS Y DISTANCIAS"
          altura-tabla
          estilo-tabla
          inicio
        ))
      ;; Con las dos tablas dibujadas se iguala su tamaño final: mismo ancho
      ;; total y la misma altura por fila. Con una sola tabla no hay nada que
      ;; igualar y el proceso parcial no se altera.
      (if (and tbl-coord tbl-rumbo)
        (MCTABLE:equalize-tables tbl-coord tbl-rumbo))
    )
    (princ "\nNo se indicó punto para el cuadro de rumbos. Proceso parcial.")
  )

  (setvar "OSMODE"   old-osmode)
  (setvar "CMDECHO"  old-cmdecho)
  (setvar "BLIPMODE" old-blipmode)

  (princ "\n\n=== MCTABLE: Proceso completado exitosamente ===\n")
  (princ)
)

(princ "\n» Comando MCTABLE cargado. Escriba MCTABLE para arrancar.")
(princ)