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
      (write-line "  label = \"Configuración de Coordenadas UTM\";" f)
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
      (write-line "    label = \"Apariencia de Vértices\";" f)
      (write-line "    : row {" f)
      (write-line "      : text { label = \"Prefijo:\"; }" f)
      (write-line "      : edit_box { key = \"txt_prefijo_tag\"; value = \"E\"; width = 6; edit_width = 4; }" f)
      (write-line "      : text { label = \"Radio:\"; }" f)
      (write-line "      : edit_box { key = \"txt_radio_vertice\"; value = \"1.0\"; width = 8; edit_width = 6; }" f)
      (write-line "    }" f)
      (write-line "    : row {" f)
      (write-line "      : text { label = \"Fuente:\"; }" f)
      (write-line "      : edit_box { key = \"txt_fuente_tag\"; value = \"Standard\"; width = 24; edit_width = 16; }" f)
      (write-line "    }" f)
      (write-line "  }" f)
      (write-line "" f)
      (write-line "  : boxed_column {" f)
      (write-line "    label = \"Vértice inicial (E-1)\";" f)
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

(defun MCTABLE:label-vertices (vlist layer-name prefijo radio fuente borde
                             / n i v ang u nor th gap claro paso ja jb a0 b0 a b
                               ins rect texto caja x1 y1 x2 y2 rot proy ef hallado fallo e)
  (setq n (length vlist) i 0 fallo nil label-created nil
        th (* radio 0.9) gap (* radio 0.35) claro (* radio 0.35)
        paso (* radio 0.5))
  (while (and (< i n) (not fallo))
    (setq v (nth i vlist)
          texto (strcat prefijo "-" (itoa (1+ i))))
    (if (not (MCTABLE:label-create
               (list '(0 . "CIRCLE") (cons 8 layer-name)
                     (cons 10 v) (cons 40 radio) '(210 0.0 0.0 1.0))))
      (setq fallo T))
    (if (and (not fallo) (>= n 2))
      (progn
        (setq ang (MCTABLE:label-angulo v (nth (rem (1+ i) n) vlist))
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
                  a0 (- (+ radio gap) (car proy))
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
                (if (MCTABLE:label-etiqueta-valida rect borde nil vlist radio gap claro T)
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
  (if (< n 2)
    (princ "\nMCTABLE: un solo vértice; no hay dirección definida y se omite la etiqueta."))
  (if fallo
    (foreach e label-created (MCTABLE:label-delete e))
    (princ (strcat "\n  " (itoa n) " vértices procesados (círculo + etiqueta exterior segura).")))
  (setq label-created nil)
  (not fallo))

;; ============================================================
;; SECCIÓN 5: CREACIÓN DE TABLAS CON PROTECCIÓN ACTIVEX
;; ============================================================

;; 5.1: Tabla de Coordenadas
(defun MCTABLE:create-table (ins-pt vlist decimals xy-order title-str /
                             tbl-obj rows cols row-idx v xval yval
                             col1-hdr col2-hdr doc space cell-align
                             actual-rows expected-rows row-height i)
  (if xy-order
    (setq col1-hdr "ESTE (X)"   col2-hdr "NORTE (Y)")
    (setq col1-hdr "NORTE (Y)"  col2-hdr "ESTE (X)")
  )

  (setq rows  (+ 2 (length vlist))
        cols  3
        doc   (vla-get-ActiveDocument (vlax-get-acad-object))
        space (vla-get-ModelSpace doc)
        cell-align 5
        row-height (* (getvar "TEXTSIZE") 2.2) 
  )

  (setq tbl-obj
    (vla-AddTable space (vlax-3d-point ins-pt) rows cols row-height (* (getvar "TEXTSIZE") 8.0))
  )

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

  (setq row-idx 2)
  (foreach v vlist
    (setq xval (car v) yval (cadr v))
    (vl-catch-all-apply 'vla-SetText (list tbl-obj row-idx 0 (itoa (- row-idx 1))))
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
    (setq row-idx (1+ row-idx))
  )

  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 0 (* (getvar "TEXTSIZE") 5.0)))
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 1 (* (getvar "TEXTSIZE") 16.0)))
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 2 (* (getvar "TEXTSIZE") 16.0)))

  (setq i 0)
  (while (< i rows)
    (if (= i 0)
      (vl-catch-all-apply 'vla-SetRowHeight (list tbl-obj i (* row-height 1.5)))
      (vl-catch-all-apply 'vla-SetRowHeight (list tbl-obj i row-height))
    )
    (setq i (1+ i))
  )

  (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-obj :vlax-false))
  (vla-Update tbl-obj)
  tbl-obj
)

;; 5.2: Tabla de Rumbos y Distancias
(defun MCTABLE:create-bearing-table (ins-pt vlist decimals title-str /
                                     tbl-obj rows cols row-idx i n p1 p2
                                     doc space cell-align row-height
                                     est-lbl rumbo-lbl dist-lbl)
  (setq n             (length vlist)
        rows          (+ 2 n)
        cols          3
        doc           (vla-get-ActiveDocument (vlax-get-acad-object))
        space         (vla-get-ModelSpace doc)
        cell-align    5
        row-height    (* (getvar "TEXTSIZE") 2.2) 
  )

  (setq tbl-obj
    (vla-AddTable space (vlax-3d-point ins-pt) rows cols row-height (* (getvar "TEXTSIZE") 8.0))
  )

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
          est-lbl   (strcat "{\\b " (itoa (1+ i)) "}") 
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

  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 0 (* (getvar "TEXTSIZE") 5.0)))
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 1 (* (getvar "TEXTSIZE") 18.0)))
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 2 (* (getvar "TEXTSIZE") 14.0)))

  (setq i 0)
  (while (< i rows)
    (if (= i 0)
      (vl-catch-all-apply 'vla-SetRowHeight (list tbl-obj i (* row-height 1.5)))
      (vl-catch-all-apply 'vla-SetRowHeight (list tbl-obj i row-height))
    )
    (setq i (1+ i))
  )

  (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl-obj :vlax-false))
  (vla-Update tbl-obj)
  tbl-obj
)

;; ============================================================
;; SECCIÓN 6: FUNCIÓN PRINCIPAL - COMANDO MCTABLE
;; ============================================================

(defun C:MCTABLE (/
  *error* old-osmode old-cmdecho old-blipmode
  dcl-file dcl-id sel ent ent-type vertices
  opt-cw opt-yx decimals origin-idx ordered-verts
  ins-pt ins-pt2 lyr-etiq click-pt dlg-result start-pt
  lyr-data lyr-ent lyr-ed
  tag-prefix circle-rad tag-font label-verts label-border label-created e
)

  (defun *error* (msg)
    (vl-catch-all-apply
      '(lambda ()
         (foreach e label-created
           (vl-catch-all-apply 'MCTABLE:label-delete (list e)))
         (setq label-created nil)
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
        tag-font   "Standard"
  )

  (setq dcl-file (vl-filename-mktemp "mctbl" nil ".dcl"))
  (if (not (MCTABLE:write-dcl dcl-file)) (exit))

  (setq dcl-id (load_dialog dcl-file))
  (if (< dcl-id 0) (progn (if (findfile dcl-file) (vl-file-delete dcl-file)) (exit)))

  (if (not (new_dialog "mctable_dlg" dcl-id))
    (progn (unload_dialog dcl-id) (if (findfile dcl-file) (vl-file-delete dcl-file)) (exit))
  )

  (set_tile "rb_ccw"  "0")
  (set_tile "rb_cw"   "1")
  (set_tile "eb_dec"  "2")
  (set_tile "txt_prefijo_tag"   "E")
  (set_tile "txt_radio_vertice" "1.0")
  (set_tile "txt_fuente_tag"    "Standard")
  (set_tile "txt_orig"
    (strcat "Vértice 1: (" (rtos (car (car vertices)) 2 2) ", " (rtos (cadr (car vertices)) 2 2) ")")
  )

  (action_tile "rb_ccw"   "(setq opt-cw nil)")
  (action_tile "rb_cw"    "(setq opt-cw T)")
  (action_tile "rb_xy"    "(setq opt-yx nil)")
  (action_tile "rb_yx"    "(setq opt-yx T)")
  (action_tile "eb_dec"   "(setq decimals (atoi (get_tile \"eb_dec\")))(if (or (< decimals 0)(> decimals 8))(progn (set_tile \"eb_dec\" \"2\")(setq decimals 2)))")
  (action_tile "txt_prefijo_tag"   "(setq tag-prefix (get_tile \"txt_prefijo_tag\"))")
  (action_tile "txt_radio_vertice" "(setq circle-rad (atof (get_tile \"txt_radio_vertice\")))(if (<= circle-rad 0.0)(progn (set_tile \"txt_radio_vertice\" \"1.0\")(setq circle-rad 1.0)))")
  (action_tile "txt_fuente_tag"    "(setq tag-font (get_tile \"txt_fuente_tag\"))")
  (action_tile "btn_orig" "(done_dialog 2)")
  (action_tile "accept"   "(setq decimals (atoi (get_tile \"eb_dec\")))(setq tag-prefix (get_tile \"txt_prefijo_tag\"))(setq circle-rad (atof (get_tile \"txt_radio_vertice\")))(if (<= circle-rad 0.0)(setq circle-rad 1.0))(setq tag-font (get_tile \"txt_fuente_tag\"))(done_dialog 1)")
  (action_tile "cancel"   "(done_dialog 0)")

  (setq dlg-result 0)
  (while (= (setq dlg-result (start_dialog)) 2)
    (setvar "OSMODE" 1)
    (setq click-pt (getpoint "\nHaga clic cerca del vértice que desea como Origen (Punto 1): "))

    (if (not (new_dialog "mctable_dlg" dcl-id))
      (setq dlg-result 0)
      (progn
        (if opt-cw (set_tile "rb_cw" "1") (set_tile "rb_ccw" "1"))
        (if opt-yx (set_tile "rb_yx" "1") (set_tile "rb_xy" "1"))
        (set_tile "eb_dec" (itoa decimals))
        (set_tile "txt_prefijo_tag"   tag-prefix)
        (set_tile "txt_radio_vertice" (rtos circle-rad 2 2))
        (set_tile "txt_fuente_tag"    tag-font)
        (if click-pt
          (progn
            (setq origin-idx (MCTABLE:closest-vertex (list (car click-pt) (cadr click-pt)) vertices))
            (set_tile "txt_orig" (strcat "Vértice " (itoa (1+ origin-idx)) ": ("
                                         (rtos (car (nth origin-idx vertices)) 2 2) ", "
                                         (rtos (cadr (nth origin-idx vertices)) 2 2) ")"))
          )
          (set_tile "txt_orig" "Vértice 1 (Predeterminado)")
        )
        (action_tile "rb_ccw"   "(setq opt-cw nil)")
        (action_tile "rb_cw"    "(setq opt-cw T)")
        (action_tile "rb_xy"    "(setq opt-yx nil)")
        (action_tile "rb_yx"    "(setq opt-yx T)")
        (action_tile "eb_dec"   "(setq decimals (atoi (get_tile \"eb_dec\")))(if (or (< decimals 0)(> decimals 8))(progn (set_tile \"eb_dec\" \"2\")(setq decimals 2)))")
        (action_tile "txt_prefijo_tag"   "(setq tag-prefix (get_tile \"txt_prefijo_tag\"))")
        (action_tile "txt_radio_vertice" "(setq circle-rad (atof (get_tile \"txt_radio_vertice\")))(if (<= circle-rad 0.0)(progn (set_tile \"txt_radio_vertice\" \"1.0\")(setq circle-rad 1.0)))")
        (action_tile "txt_fuente_tag"    "(setq tag-font (get_tile \"txt_fuente_tag\"))")
        (action_tile "btn_orig" "(done_dialog 2)")
        (action_tile "accept"   "(setq decimals (atoi (get_tile \"eb_dec\")))(setq tag-prefix (get_tile \"txt_prefijo_tag\"))(setq circle-rad (atof (get_tile \"txt_radio_vertice\")))(if (<= circle-rad 0.0)(setq circle-rad 1.0))(setq tag-font (get_tile \"txt_fuente_tag\"))(done_dialog 1)")
        (action_tile "cancel"   "(done_dialog 0)")
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

  (princ "\nDibujando numeración de vértices...")
  (setq label-verts (MCTABLE:label-wcs ent ordered-verts)
        label-border (MCTABLE:label-wcs ent
                       (MCTABLE:reverse-if-needed (MCTABLE:get-vertices ent) (not opt-cw))))
  (if label-verts
    (if (not (MCTABLE:label-vertices label-verts lyr-etiq tag-prefix circle-rad tag-font label-border))
      (progn
        (princ "\nMCTABLE: falló la creación de anotaciones; se revirtieron las creadas.")
        (exit)))
    (princ "\nMCTABLE: etiquetas omitidas; se requiere una polilínea horizontal con normal +Z."))

  (setvar "OSMODE" 0)
  (setq ins-pt (getpoint "\nIndique el punto de inserción para la TABLA DE COORDENADAS: "))
  (if ins-pt
    (progn
      (princ "\nConstruyendo tabla de coordenadas...")
      (MCTABLE:create-table
        (list (car ins-pt) (cadr ins-pt) (if (caddr ins-pt) (caddr ins-pt) 0.0))
        ordered-verts
        decimals
        (not opt-yx)
        "COORDENADAS GEORREFERENCIADAS"
      )
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
      (MCTABLE:create-bearing-table
        (list (car ins-pt2) (cadr ins-pt2) (if (caddr ins-pt2) (caddr ins-pt2) 0.0))
        ordered-verts
        decimals
        "CUADRO DE RUMBOS Y DISTANCIAS"
      )
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