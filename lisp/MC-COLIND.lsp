;;; ============================================================
;;; MCCOLIND — Simbología y etiquetas de colindancias.
;;;
;;; Dibuja uno de siete estilos de lindero sobre un tramo parcial de
;;; una LINE o LWPOLYLINE de tramos rectos y añade, por recorrido, un
;;; par de etiquetas: el nombre del estilo en el interior y el nombre
;;; de la colindancia en el exterior. La fuente nunca se modifica.
;;;
;;; Geometría explícita en la capa y el estilo de texto actuales.
;;; Sin reactores, sin archivos .lin, sin recursos globales y sin
;;; dependencia de otros comandos del proyecto.
;;;
;;; Requiere AutoCAD 64-bit con ActiveX/VLA. El dibujo se interpreta
;;; en metros. Por defecto, D es la mayor dimensión XY de la fuente:
;;; texto interior D/100; exterior 1,5 veces; franja 1 vez;
;;; holguras interior/exterior 0,5/1,5 veces; paso normal 2 veces.
;;; En modo manual, las medidas están en milímetros de papel y
;;; se convierten con la escala 1:N:
;;;   medida_en_dibujo = milímetros * N / 1000
;;; Ejemplo a 1:500: texto 2 mm -> 1 m; repetición 4 mm -> 2 m;
;;; franja 1 mm -> 0,5 m; separación libre 1 mm -> 0,5 m.
;;;
;;; Los patrones son geometría independiente: editar después la fuente
;;; no actualiza las colindancias ya creadas (no hay asociatividad).
;;; El recuento de entidades por aplicación está acotado para evitar
;;; dibujos impracticables con repeticiones diminutas.
;;; ============================================================
(vl-load-com)

;;; ============================================================
;;; SECCIÓN 1: DIÁLOGO DCL TEMPORAL
;;; ============================================================
(defun mccolind:escribir-dcl (ruta / f lineas)
  (setq f (open ruta "w"))
  (if (null f)
    nil
    (progn
      (setq lineas
        '("mccolind_dlg : dialog { label = \"MCCOLIND - Simbología de colindancias\";"
          "  width = 68;"
          "  : text { key = \"fuente\"; width = 66; }"
          "  : boxed_column {"
          "    label = \"Tamaño de símbolos y etiquetas\";"
          "    : toggle { key = \"automatico\"; label = \"Automático según la geometría seleccionada\"; }"
          "    : text { label = \"Alternativa manual: escala 1:N y medidas en papel.\"; }"
          "    : edit_box { key = \"escala\"; label = \"Escala 1:N:\"; edit_width = 12; }"
          "    : edit_box { key = \"texto\"; label = \"Altura de texto en mm:\"; edit_width = 12; }"
          "    : edit_box { key = \"repeticion\"; label = \"Repetición del patrón en mm:\"; edit_width = 12; }"
          "    : edit_box { key = \"franja\"; label = \"Ancho total de franja en mm:\"; edit_width = 12; }"
          "    : edit_box { key = \"separacion\"; label = \"Separación libre texto/patrón en mm:\"; edit_width = 12; }"
          "    : text { key = \"medidas\"; width = 66; }"
          "    : text { key = \"medidas2\"; width = 66; }"
          "    : text { key = \"medidas3\"; width = 66; }"
          "  }"
          "  : boxed_column {"
          "    label = \"Estilo de colindancia\";"
          "    : popup_list { key = \"estilo\"; label = \"Tipo:\"; edit_width = 36; }"
          "    : text { key = \"lado\"; width = 66; }"
          "  }"
          "  : boxed_column {"
          "    label = \"Etiquetas del recorrido\";"
          "    : edit_box { key = \"nombre\"; label = \"Colindancia exterior:\"; edit_width = 32; }"
          "    : text { label = \"El nombre del estilo se rotula en el interior.\"; }"
          "  }"
          "  : row {"
          "    : button { key = \"aplicar\"; label = \"Aplicar a dos puntos...\"; }"
          "    : button { key = \"deshacer\"; label = \"Deshacer última aplicación\"; }"
          "  }"
          "  : text { key = \"estado\"; width = 66; }"
          "  : text { label = \"Aceptar conserva lo dibujado; Cancelar o ESC descarta la ejecución.\"; }"
          "  : row {"
          "    : button { key = \"accept\"; label = \"Aceptar\"; is_default = true; }"
          "    : button { key = \"cancel\"; label = \"Cancelar\"; is_cancel = true; }"
          "  }"
          "}"))
      (foreach l lineas (write-line l f))
      (close f)
      T)))

;;; ============================================================
;;; SECCIÓN 2: UTILIDADES GEOMÉTRICAS PURAS (plano local XY)
;;; Todo el cálculo se hace en coordenadas locales cercanas a la
;;; fuente para no restar coordenadas UTM grandes; la conversión a WCS
;;; ocurre solo al crear entidades.
;;; ============================================================
(defun mccolind:fallar (msg)
  (setq mccolind-msg msg)
  (exit))

(defun mccolind:xy (p) (list (car p) (cadr p)))
(defun mccolind:restar (a b) (list (- (car a) (car b)) (- (cadr a) (cadr b))))
(defun mccolind:sumar (a b) (list (+ (car a) (car b)) (+ (cadr a) (cadr b))))
(defun mccolind:escalar (v k) (list (* (car v) k) (* (cadr v) k)))
(defun mccolind:cruz (a b) (- (* (car a) (cadr b)) (* (cadr a) (car b))))
(defun mccolind:dot (a b) (+ (* (car a) (car b)) (* (cadr a) (cadr b))))
(defun mccolind:izq (u) (list (- (cadr u)) (car u)))
(defun mccolind:der (u) (list (cadr u) (- (car u))))

(defun mccolind:mod (x m / r)
  ;; REM es nativa de AutoLISP; ajustar su resto negativo para M positivo.
  (setq r (rem x m))
  (if (< r 0.0) (+ r m) r))

(defun mccolind:clamp (x lo hi)
  (cond ((< x lo) lo) ((> x hi) hi) (T x)))

(defun mccolind:unitaria (v / l)
  (setq l (distance '(0.0 0.0) v))
  (if (< l mccolind-eps) nil (mccolind:escalar v (/ 1.0 l))))

(defun mccolind:normaliza (a / r)
  (setq r (mccolind:mod (+ a pi) (* 2.0 pi)))
  (- r pi))

;; Rotación legible: nunca deja el texto boca abajo.
(defun mccolind:rot-legible (a / r)
  (setq r (mccolind:normaliza a))
  (cond ((> r (/ pi 2.0)) (- r pi))
        ((<= r (- (/ pi 2.0))) (+ r pi))
        (T r)))

;; PAR es el parámetro 0..1 del punto más cercano sobre el segmento. El
;; símbolo T está reservado en AutoLISP y no se usa como variable.
(defun mccolind:dist-punto-seg (p a b / v l2 par)
  (setq v (mccolind:restar b a)
        l2 (mccolind:dot v v))
  (if (<= l2 0.0)
    (distance p a)
    (progn
      (setq par (mccolind:clamp (/ (mccolind:dot (mccolind:restar p a) v) l2) 0.0 1.0))
      (distance p (mccolind:sumar a (mccolind:escalar v par))))))

;; Distancia mínima entre dos segmentos: se calcula en los dos sentidos
;; (extremos de cada uno contra el otro). 0 si se cortan o se tocan, de
;; modo que una arista de la fuente no puede quedar cerca de la mitad de
;; un lado largo de la caja sin detectarse.
(defun mccolind:dist-seg-seg (a b c d)
  (if (mccolind:segmentos-tocan a b c d)
    0.0
    (min (mccolind:dist-punto-seg a c d)
         (mccolind:dist-punto-seg b c d)
         (mccolind:dist-punto-seg c a b)
         (mccolind:dist-punto-seg d a b))))

(defun mccolind:signo-lado (a b p / v tol)
  (setq v (mccolind:cruz (mccolind:restar b a) (mccolind:restar p a))
        tol (* mccolind-eps (distance a b)))
  (cond ((> v tol) 1) ((< v (- tol)) -1) (T 0)))

(defun mccolind:en-segmento (p a b / ab ap len)
  (setq ab (mccolind:restar b a) ap (mccolind:restar p a) len (distance a b))
  (and (> len mccolind-eps)
       (<= (abs (mccolind:cruz ab ap)) (* mccolind-eps len))
       (>= (mccolind:dot ap ab) (- (* mccolind-eps len)))
       (<= (mccolind:dot ap ab) (+ (* len len) (* mccolind-eps len)))))

;; T si los segmentos se cruzan o se tocan; el contacto cuenta.
(defun mccolind:segmentos-tocan (a b c d / s1 s2 s3 s4)
  (setq s1 (mccolind:signo-lado a b c) s2 (mccolind:signo-lado a b d)
        s3 (mccolind:signo-lado c d a) s4 (mccolind:signo-lado c d b))
  (or (and (< (* s1 s2) 0) (< (* s3 s4) 0))
      (mccolind:en-segmento c a b) (mccolind:en-segmento d a b)
      (mccolind:en-segmento a c d) (mccolind:en-segmento b c d)))

;; T si el punto está dentro o sobre el contorno cerrado.
(defun mccolind:punto-dentro (p pts / dentro borde ar a b x y cruce)
  (setq dentro nil borde nil x (car p) y (cadr p))
  (foreach ar (mccolind:aristas pts T)
    (setq a (car ar) b (cadr ar))
    (if (mccolind:en-segmento p a b) (setq borde T))
    (if (and (<= (min (cadr a) (cadr b)) y) (< y (max (cadr a) (cadr b))))
      (progn
        (setq cruce (+ (car a) (* (- y (cadr a))
                                  (/ (- (car b) (car a)) (- (cadr b) (cadr a))))))
        (if (< x cruce) (setq dentro (not dentro))))))
  (or borde dentro))

(defun mccolind:area-firmada (pts / n s i p1 p2)
  (setq n (length pts) s 0.0 i 0)
  (while (< i n)
    (setq p1 (nth i pts)
          p2 (nth (fix (mccolind:mod (1+ i) n)) pts))
    (setq s (+ s (- (* (car p1) (cadr p2)) (* (car p2) (cadr p1)))))
    (setq i (1+ i)))
  (* 0.5 s))

(defun mccolind:tolerancia (pts / xs ys span)
  (setq xs (mapcar 'car pts) ys (mapcar 'cadr pts)
        span (max (- (apply 'max xs) (apply 'min xs))
                  (- (apply 'max ys) (apply 'min ys))))
  (max 1e-8 (* span 1e-10)))

(defun mccolind:local (p) (mccolind:restar (mccolind:xy p) mccolind-origen))

(defun mccolind:wcs (p)
  (list (+ (car p) (car mccolind-origen))
        (+ (cadr p) (cadr mccolind-origen))
        mccolind-z))

(defun mccolind:dobles (valores / arr)
  (setq arr (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length valores)))))
  (vlax-safearray-fill arr valores)
  arr)

;;; ============================================================
;;; SECCIÓN 3: LECTURA Y VALIDACIÓN DE LA FUENTE
;;; ============================================================
;; Aristas en el orden almacenado. Cerrada incluye el cierre.
(defun mccolind:aristas (pts cerrada / n i r)
  (setq n (length pts) i 0 r nil)
  (while (< i (if cerrada n (1- n)))
    (setq r (cons (list (nth i pts) (nth (fix (mccolind:mod (1+ i) n)) pts)) r))
    (setq i (1+ i)))
  (reverse r))

;; Longitud acumulada al inicio de cada vértice.
(defun mccolind:acumulado (lenes n / r total k)
  (setq r (list 0.0) total 0.0 k 0)
  (while (< (1+ k) n)
    (setq total (+ total (nth k lenes)))
    (setq r (cons total r))
    (setq k (1+ k)))
  (reverse r))

(defun mccolind:validar-simple (pts cerrada / aristas num n i j a b anterior siguiente)
  (setq aristas (mccolind:aristas pts cerrada)
        num (length aristas)
        n (length pts)
        i 0)
  (if (and cerrada (< (length pts) 3))
    (mccolind:fallar "El contorno cerrado requiere al menos tres vértices distintos."))
  (if (and (not cerrada) (< (length pts) 2))
    (mccolind:fallar "La fuente requiere al menos dos puntos distintos."))
  (foreach a aristas
    (if (<= (distance (car a) (cadr a)) mccolind-eps)
      (mccolind:fallar "La fuente tiene vértices consecutivos coincidentes o aristas nulas.")))
  (while (< i num)
    ;; Vecinos reales: en una cadena abierta no se envuelve; el módulo se
    ;; aplica solo en contornos cerrados, donde hay tantas aristas como
    ;; vértices. Con el módulo de aristas, una abierta de tres vértices
    ;; tomaría v0 como vecino anterior y siguiente a la vez.
    (if cerrada
      (setq anterior (nth (fix (mccolind:mod (+ i n -1) n)) pts)
            siguiente (nth (fix (mccolind:mod (1+ i) n)) pts))
      (setq anterior (if (> i 0) (nth (1- i) pts) nil)
            siguiente (nth (1+ i) pts)))
    (setq a (nth i pts))
    ;; Retroceso sobre la arista vecina: en abiertas solo existe en los
    ;; vértices interiores de la cadena.
    (if (and anterior siguiente
             (= 0 (mccolind:signo-lado anterior a siguiente))
             (< (mccolind:dot (mccolind:restar a anterior)
                              (mccolind:restar siguiente a)) 0.0))
      (mccolind:fallar "La fuente retrocede sobre sí misma: aristas superpuestas."))
    (setq j (1+ i) a (nth i aristas))
    (while (< j num)
      (if (and (/= j (1+ i)) (not (and cerrada (= i 0) (= j (1- num)))))
        (progn
          (setq b (nth j aristas))
          (if (mccolind:segmentos-tocan (car a) (cadr a) (car b) (cadr b))
            (mccolind:fallar "La fuente se cruza o se toca a sí misma en un contorno inválido."))))
      (setq j (1+ j)))
    (setq i (1+ i)))
  (if (and cerrada (<= (abs (mccolind:area-firmada pts)) (* mccolind-eps mccolind-eps)))
    (mccolind:fallar "La superficie del contorno es nula o degenerada."))
  T)

;; Lee la fuente (LINE o LWPOLYLINE), la valida y construye el marco de
;; trabajo local. Rechaza arcos, geometría inclinada y contornos inválidos.
(defun mccolind:leer-fuente (ent / ed tipo normal elev pts cerrada duplicado repetido)
  (setq ed (entget ent) tipo (cdr (assoc 0 ed)))
  (cond
    ((= tipo "LINE")
      (setq normal (if (assoc 210 ed) (cdr (assoc 210 ed)) '(0.0 0.0 1.0)))
      (if (not (equal normal '(0.0 0.0 1.0) 1e-10))
        (mccolind:fallar "Solo se admiten líneas horizontales con normal +Z."))
      (setq pts (list (trans (cdr (assoc 10 ed)) ent 0)
                      (trans (cdr (assoc 11 ed)) ent 0))
            cerrada nil)
      ;; Cota constante: el resultado conserva la Z de la fuente.
      (if (> (abs (- (caddr (car pts)) (caddr (cadr pts)))) 1e-9)
        (mccolind:fallar "La línea debe ser horizontal: sus dos extremos no comparten la misma cota.")))
    ((= tipo "LWPOLYLINE")
      (setq normal (if (assoc 210 ed) (cdr (assoc 210 ed)) '(0.0 0.0 1.0)))
      (if (not (equal normal '(0.0 0.0 1.0) 1e-10))
        (mccolind:fallar "Solo se admiten contornos horizontales con normal +Z."))
      (foreach repetido ed
        (if (and (= (car repetido) 42) (/= (cdr repetido) 0.0))
          (mccolind:fallar "Esta versión no admite arcos (bulge). No se sustituyen por cuerdas.")))
      (setq elev (if (assoc 38 ed) (cdr (assoc 38 ed)) 0.0))
      (foreach repetido ed
        (if (= (car repetido) 10)
          (setq pts (cons (trans (list (cadr repetido) (caddr repetido) elev) ent 0) pts))))
      (setq pts (reverse pts)
            cerrada (/= 0 (logand 1 (if (assoc 70 ed) (cdr (assoc 70 ed)) 0)))))
    (T (mccolind:fallar "Seleccione una LINE o una LWPOLYLINE; no se admiten otros tipos.")))
  (setq mccolind-z (caddr (car pts))
        mccolind-origen (mccolind:xy (car pts))
        mccolind-puntos (mapcar 'mccolind:local pts)
        mccolind-eps (mccolind:tolerancia mccolind-puntos))
  ;; Cierre geométrico: un extremo final coincidente con el primero se
  ;; retira de la copia de trabajo. Si la fuente venía abierta, pasa a
  ;; tratarse como cerrada; la entidad original conserva todo.
  (setq duplicado (and (>= (length mccolind-puntos) 2)
                       (<= (distance (car mccolind-puntos) (last mccolind-puntos))
                           mccolind-eps)))
  (if duplicado
    (setq mccolind-puntos (reverse (cdr (reverse mccolind-puntos)))))
  (setq mccolind-cerrada (or cerrada duplicado))
  (mccolind:validar-simple mccolind-puntos mccolind-cerrada)
  (if mccolind-cerrada
    (setq mccolind-lado-canonico
          (if (> (mccolind:area-firmada mccolind-puntos) 0.0) 1 -1)))
  (setq mccolind-aristas (mccolind:aristas mccolind-puntos mccolind-cerrada)
        mccolind-len (mapcar '(lambda (ar) (distance (car ar) (cadr ar))) mccolind-aristas)
        mccolind-cum (mccolind:acumulado mccolind-len (length mccolind-puntos))
        mccolind-total (apply '+ mccolind-len)
        mccolind-dimension
          (max (- (apply 'max (mapcar 'car mccolind-puntos))
                  (apply 'min (mapcar 'car mccolind-puntos)))
               (- (apply 'max (mapcar 'cadr mccolind-puntos))
                  (apply 'min (mapcar 'cadr mccolind-puntos)))))
  T)

;;; ============================================================
;;; SECCIÓN 4: PROYECCIÓN SOBRE LA FUENTE Y RECORRIDOS
;;; ============================================================
(defun mccolind:arista-de (u / n k l enc)
  (setq n (length mccolind-aristas) k 0 enc nil)
  (while (and (< k n) (null enc))
    (setq l (nth k mccolind-len))
    (if (and (>= u (- (nth k mccolind-cum) mccolind-eps))
             (< u (+ (nth k mccolind-cum) l)))
      (setq enc k)
      (setq k (1+ k))))
  (if enc enc (1- n)))

(defun mccolind:punto-param (u / ind ar l par)
  (setq ind (mccolind:arista-de u)
        ar (nth ind mccolind-aristas)
        l (nth ind mccolind-len)
        par (if (<= l mccolind-eps)
              0.0
              (mccolind:clamp (/ (- u (nth ind mccolind-cum)) l) 0.0 1.0)))
  (mccolind:sumar (car ar) (mccolind:escalar (mccolind:restar (cadr ar) (car ar)) par)))

;; Proyección al punto más cercano del recorrido: (arista parámetro distancia punto).
(defun mccolind:proyectar (p / k ar a b v l2 par q d mejor)
  (setq k 0 mejor nil)
  (foreach ar mccolind-aristas
    (setq a (car ar) b (cadr ar) v (mccolind:restar b a) l2 (mccolind:dot v v))
    (setq par (if (<= l2 0.0)
                0.0
                (mccolind:clamp (/ (mccolind:dot (mccolind:restar p a) v) l2) 0.0 1.0))
          q (mccolind:sumar a (mccolind:escalar v par))
          d (distance p q))
    (if (or (null mejor) (< d (nth 2 mejor)))
      (setq mejor (list k par d q)))
    (setq k (1+ k)))
  mejor)

(defun mccolind:u-de (proy)
  (+ (nth (car proy) mccolind-cum) (* (cadr proy) (nth (car proy) mccolind-len))))

;; En fuentes abiertas el usuario indica el lado considerado interior.
(defun mccolind:elegir-interior (/ p local proy ar s)
  (while (null mccolind-lado-canonico)
    (setq p (getpoint "\nIndique con un clic el lado interior de la fuente abierta: "))
    (if (null p) (mccolind:fallar "No se indicó el lado interior de la fuente abierta."))
    (setq local (mccolind:local (trans p 1 0))
          proy (mccolind:proyectar local)
          ar (nth (car proy) mccolind-aristas)
          s (mccolind:signo-lado (car ar) (cadr ar) local))
    (if (= s 0)
      (alert "El clic quedó sobre el lindero; elija un punto claramente a un lado.")
      (setq mccolind-lado-canonico s)))
  T)

;; Dos clics sobre el borde; se proyectan y se guardan sus parámetros.
(defun mccolind:capturar-par (/ p1 p2 proy1 proy2)
  (setvar "OSMODE" (logior (cdr (assoc "OSMODE" mccolind-entorno)) 1 512))
  (setq p1 (getpoint "\nPrimer punto sobre el borde de la fuente: "))
  (if p1
    (setq p2 (getpoint p1 "\nSegundo punto sobre el borde: ")))
  (setvar "OSMODE" 0)
  (if (or (null p1) (null p2))
    nil
    (progn
      (setq proy1 (mccolind:proyectar (mccolind:local (trans p1 1 0)))
            proy2 (mccolind:proyectar (mccolind:local (trans p2 1 0))))
      (if (< (distance (nth 3 proy1) (nth 3 proy2)) mccolind-eps)
        (progn
          (alert "Los dos puntos proyectados coinciden sobre el borde; elija puntos distintos.")
          nil)
        (setq mccolind-uA (mccolind:u-de proy1)
              mccolind-uB (mccolind:u-de proy2))))))

;; Cadena de puntos desde el parámetro U0 avanzando DELTA en el sentido
;; almacenado. Recorta los extremos en los puntos proyectados.
(defun mccolind:cadena (u0 delta / lista k rig fin)
  (setq lista (list (cons 0.0 (mccolind:punto-param u0)))
        k 0)
  (while (< k (length mccolind-puntos))
    (setq rig (if mccolind-cerrada
                (mccolind:mod (- (nth k mccolind-cum) u0) mccolind-total)
                (- (nth k mccolind-cum) u0)))
    (if (and (> rig mccolind-eps) (< rig (- delta mccolind-eps)))
      (setq lista (cons (cons rig (nth k mccolind-puntos)) lista)))
    (setq k (1+ k)))
  (setq lista (mapcar 'cdr (vl-sort lista '(lambda (a b) (< (car a) (car b))))))
  (setq fin (if mccolind-cerrada
              (mccolind:punto-param (mccolind:mod (+ u0 delta) mccolind-total))
              (mccolind:punto-param (+ u0 delta))))
  (append lista (list fin)))

;; Recorridos candidatos: (puntos u-inicial longitud sentido).
;; En cerradas hay dos alternativas; en abiertas, un único intervalo.
(defun mccolind:rutas (/ delta alt tmp)
  (if mccolind-cerrada
    (progn
      (setq delta (mccolind:mod (- mccolind-uB mccolind-uA) mccolind-total)
            alt (- mccolind-total delta))
      (list (list (mccolind:cadena mccolind-uA delta) mccolind-uA delta 1)
            (list (reverse (mccolind:cadena mccolind-uB alt)) mccolind-uB alt -1)))
    (progn
      (if (> mccolind-uA mccolind-uB)
        (setq tmp mccolind-uA mccolind-uA mccolind-uB mccolind-uB tmp))
      (setq delta (- mccolind-uB mccolind-uA))
      (list (list (mccolind:cadena mccolind-uA delta) mccolind-uA delta 1)))))

;; Conjunto de parámetros cubierto, como uno o dos intervalos.
(defun mccolind:intervalos (u0 delta / resto)
  (if (not mccolind-cerrada)
    (list (list u0 (+ u0 delta)))
    (progn
      (setq resto (- (+ u0 delta) mccolind-total))
      (if (<= resto 0.0)
        (list (list u0 (+ u0 delta)))
        (list (list u0 mccolind-total) (list 0.0 resto))))))

(defun mccolind:intervalo-solapa (a b)
  (< (+ (max (car a) (car b)) mccolind-eps) (min (cadr a) (cadr b))))

;; Evita aplicaciones superpuestas dentro de la misma ejecución. El
;; registro es de sesión: no hay memoria entre ejecuciones del comando.
(defun mccolind:rutas-solapan (intervalos / previo nuevo viejo res)
  (setq res nil)
  (foreach previo mccolind-sesion
    (setq viejo (nth 2 previo))
    (foreach nuevo intervalos
      (foreach v viejo
        (if (mccolind:intervalo-solapa nuevo v) (setq res T)))))
  res)

;;; ============================================================
;;; SECCIÓN 5: PREVISUALIZACIÓN CON GRÁFICOS TRANSITORIOS
;;; Los vectores de grdraw no son entidades: no quedan en la base.
;;; ============================================================
(defun mccolind:aristas-ruta (puntos) (mccolind:aristas puntos nil))

(defun mccolind:longitud-ruta (puntos / total ar)
  (setq total 0.0)
  (foreach ar (mccolind:aristas-ruta puntos)
    (setq total (+ total (distance (car ar) (cadr ar)))))
  total)

;; Punto y dirección en la mitad de la longitud recorrida.
(defun mccolind:mitad-ruta (puntos / segs resto k ar l u)
  (setq segs (mccolind:aristas-ruta puntos)
        resto (/ (mccolind:longitud-ruta puntos) 2.0)
        k 0)
  (while (and (< k (1- (length segs)))
              (>= resto (distance (car (nth k segs)) (cadr (nth k segs)))))
    (setq resto (- resto (distance (car (nth k segs)) (cadr (nth k segs)))) k (1+ k)))
  (setq ar (nth k segs)
        l (distance (car ar) (cadr ar))
        u (mccolind:unitaria (mccolind:restar (cadr ar) (car ar))))
  (if (null u) (setq u '(1.0 0.0)))
  (list (mccolind:sumar (car ar) (mccolind:escalar u (min resto l))) u))

(defun mccolind:arista-mas-cercana (puntos p / mejor d ar)
  (foreach ar (mccolind:aristas-ruta puntos)
    (setq d (mccolind:dist-punto-seg p (car ar) (cadr ar)))
    (if (or (null mejor) (< d (car mejor))) (setq mejor (list d ar))))
  (cadr mejor))

(defun mccolind:normal-lado (ar lado / u)
  (setq u (mccolind:unitaria (mccolind:restar (cadr ar) (car ar))))
  (if u
    (if (> lado 0) (mccolind:izq u) (mccolind:der u))
    nil))

(defun mccolind:limpiar-pantalla ()
  ;; Los vectores de grdraw desaparecen al refrescar el viewport; si el
  ;; refresco no está disponible, el aviso de vista es solo cosmético.
  (vl-catch-all-apply '(lambda () (redraw)) nil)
  T)

(defun mccolind:pintar (ruta / puntos par a b medio u lado n m)
  (mccolind:limpiar-pantalla)
  (setq puntos (car ruta))
  (foreach par (mccolind:aristas-ruta puntos)
    (setq a (trans (mccolind:wcs (car par)) 0 1)
          b (trans (mccolind:wcs (cadr par)) 0 1))
    (grdraw a b 3 0))
  (setq medio (mccolind:mitad-ruta puntos)
        m (car medio)
        u (cadr medio)
        lado (* mccolind-lado-canonico (nth 3 ruta))
        n (if (> lado 0) (mccolind:izq u) (mccolind:der u)))
  ;; Aguja corta hacia el interior del recorrido, como referencia visual.
  (grdraw (trans (mccolind:wcs m) 0 1)
          (trans (mccolind:wcs (mccolind:sumar m (mccolind:escalar n mccolind-paso))) 0 1)
          1 0))

(defun mccolind:borrar-pintado () (mccolind:limpiar-pantalla))

;; Vista previa del recorrido; ENTER/ESPACIO aplica, I invierte, ESC cancela.
(defun mccolind:previsualizar (rutas / elegida invertida sig)
  (setq elegida nil invertida nil)
  (princ "\nVista previa del recorrido: ENTER o ESPACIO aplica")
  (if (cdr rutas)
    (princ ", I invierte el sentido; ESC cancela.")
    (princ ". Fuente abierta: un único recorrido; ESC cancela."))
  (while (null elegida)
    (mccolind:pintar (if invertida (cadr rutas) (car rutas)))
    ;; ALLKEYS y CURTYPE requieren enteros; NIL solo es válido para TRACK.
    (setq sig (grread nil 0 0))
    (if (and sig (= 2 (car sig)))
      (cond
        ((member (cadr sig) '(13 32))
         (setq elegida (if invertida (cadr rutas) (car rutas))))
        ((member (cadr sig) '(73 105))
         (if (cdr rutas)
           (setq invertida (not invertida))
           (princ "\nLa fuente abierta tiene un único recorrido; no se puede invertir.")))
        ((= (cadr sig) 27) (setq elegida 'cancelar))
        (T nil))))
  (mccolind:borrar-pintado)
  elegida)

;;; ============================================================
;;; SECCIÓN 6: PATRONES DE LINDERO (SIETE ESTILOS)
;;; ============================================================
(defun mccolind:nombres ()
  '("Alambrada" "Lindero" "Pared propia" "Pared medianera"
    "Pared colindante" "Malla ciclónica" "Lindero de árboles vivos"))

(defun mccolind:descripciones ()
  '("Marcas X sobre el lindero, sin franja."
    "Puntos sobre el lindero, sin franja."
    "Franja hacia el interior del recorrido."
    "Franja centrada en el lindero."
    "Franja hacia el exterior del recorrido."
    "Franja centrada: X a 75 grados del lindero."
    "Franja centrada con zigzag continuo."))

;; Extensión absoluta del patrón a cada lado: (interior . exterior).
(defun mccolind:banda (estilo / f)
  (setq f mccolind-franja)
  (cond ((= estilo 2) (cons f 0.0))
        ((= estilo 4) (cons 0.0 f))
        (T (cons (/ f 2.0) (/ f 2.0)))))

;; Punto del tramo: P + s*U + o*N (s a lo largo, o por la normal interior).
(defun mccolind:fram (p u n s o)
  (mccolind:sumar p (mccolind:sumar (mccolind:escalar u s) (mccolind:escalar n o))))

(defun mccolind:entidad (obj)
  (setq mccolind-actual (cons obj mccolind-actual)
        mccolind-cuenta (1+ mccolind-cuenta))
  (if (> mccolind-cuenta mccolind-tope)
    (mccolind:fallar "La aplicación generaría demasiadas entidades; aumente la repetición o acorte el recorrido."))
  obj)

(defun mccolind:linea (a b / obj)
  (setq obj (vla-AddLine mccolind-espacio
                         (vlax-3d-point (mccolind:wcs a))
                         (vlax-3d-point (mccolind:wcs b))))
  (mccolind:entidad obj)
  (vla-put-Layer obj mccolind-capa)
  obj)

(defun mccolind:circulo (centro radio / obj)
  (setq obj (vla-AddCircle mccolind-espacio (vlax-3d-point (mccolind:wcs centro)) radio))
  (mccolind:entidad obj)
  (vla-put-Layer obj mccolind-capa)
  obj)

(defun mccolind:polilinea (pts / obj wpts)
  ;; Una polilínea ligera requiere al menos dos vértices. Los puntos
  ;; locales se convierten a WCS antes de crear la entidad: la polilínea
  ;; usa coordenadas WCS (OCS con normal +Z) y elevación igual a la cota
  ;; de la fuente, como el resto de la geometría creada.
  (if (< (length pts) 2)
    nil
    (progn
      (setq wpts (mapcar 'mccolind:wcs pts))
      (setq obj (vla-AddLightWeightPolyline
                  mccolind-espacio
                  (mccolind:dobles (apply 'append
                                          (mapcar '(lambda (q) (list (car q) (cadr q))) wpts)))))
      (mccolind:entidad obj)
      (vla-put-Layer obj mccolind-capa)
      (vla-put-Elevation obj mccolind-z)
      (vla-put-Closed obj :vlax-false)
      obj)))

(defun mccolind:segmento-linea (p u n largo off)
  (mccolind:linea (mccolind:fram p u n 0.0 off) (mccolind:fram p u n largo off)))

;; Cota del número de marcas de un tramo: límite de seguridad de dibujo.
(defun mccolind:n-marcas (largo paso / n)
  (setq n (fix (/ largo paso)))
  (if (> n mccolind-tope)
    (mccolind:fallar "El patrón requeriría demasiadas marcas en un tramo; aumente la repetición."))
  n)

;; Tangente de 30° con funciones soportadas: AutoLISP no tiene TAN. Es el
;; valor que mantiene las diagonales de pared a 30° de la perpendicular
;; al lindero (60° respecto del lindero).
(defun mccolind:tan30 () (/ (sin (/ pi 6.0)) (cos (/ pi 6.0))))

;; Zigzag continuo entre los dos bordes de la franja. Se avanza en medias
;; piernas de paso fijo; si el tramo termina a mitad de una pierna, el
;; último vértice se interpola sobre esa pierna completa en lugar de
;; cruzar toda la franja.
(defun mccolind:zigzag (p u n largo / f2 h pts s signo resto off)
  ;; Límite de seguridad: el zigzag es una sola polilínea, así que el
  ;; tope de entidades no lo protege de un vértice por cada medio paso.
  (if (> (fix (/ (* 2.0 largo) mccolind-paso)) mccolind-tope)
    (mccolind:fallar "El zigzag requeriría demasiados vértices en un tramo; aumente la repetición."))
  (setq f2 (/ mccolind-franja 2.0)
        h (/ mccolind-paso 2.0)
        pts nil
        s 0.0
        signo 1.0)
  (setq pts (list (mccolind:fram p u n s (* signo f2))))
  ;; Solo los vértices estrictamente anteriores al extremo entran en
  ;; el bucle. El extremo se añade una vez, incluso a un paso exacto.
  (while (< (+ s h) (- largo mccolind-eps))
    (setq s (+ s h)
          signo (- signo)
          pts (cons (mccolind:fram p u n s (* signo f2)) pts)))
  ;; Recortar la última pierna completa sin cambiar su pendiente.
  (setq resto (max 0.0 (min 1.0 (/ (- largo s) h)))
        off (* signo f2 (- 1.0 (* 2.0 resto)))
        pts (cons (mccolind:fram p u n largo off) pts))
  (mccolind:polilinea (reverse pts)))

;; Patrón de un tramo recto. Tamaño y paso constantes; las marcas que no
;; caben completas en el tramo se omiten para no prolongar el patrón en
;; las esquinas. Las diagonales de pared forman 30° con la perpendicular.
(defun mccolind:tramo-patron (p u largo n / estilo f f2 paso du k c o1 o2)
  (setq estilo mccolind-estilo
        f mccolind-franja
        f2 (/ f 2.0)
        paso mccolind-paso)
  ;; Bordes de franja. En pared propia y colindante se dibuja solo el
  ;; borde lejano: el borde cercano es el propio lindero de la fuente,
  ;; que se conserva sin modificar.
  (cond
    ((= estilo 2) (mccolind:segmento-linea p u n largo f))
    ((= estilo 4) (mccolind:segmento-linea p u n largo (- f)))
    ((member estilo '(3 5 6))
     (mccolind:segmento-linea p u n largo f2)
     (mccolind:segmento-linea p u n largo (- f2))))
  (cond
    ;; Alambrada: en automático, 50 % más de paso sin agrandar las X.
    ((= estilo 0)
     (if (= mccolind-automatico "1") (setq paso (* paso 1.5)))
     (setq k (mccolind:n-marcas largo paso))
     (while (>= k 0)
       (setq c (* (+ k 0.5) paso))
       (if (and (>= (- c f2) (- mccolind-eps)) (<= (+ c f2) (+ largo mccolind-eps)))
         (progn
           (mccolind:linea (mccolind:fram p u n (- c f2) (- f2))
                           (mccolind:fram p u n (+ c f2) f2))
           (mccolind:linea (mccolind:fram p u n (- c f2) f2)
                           (mccolind:fram p u n (+ c f2) (- f2)))))
       (setq k (1- k))))
    ;; Lindero: puntos sobre el lindero.
    ((= estilo 1)
     (setq k (mccolind:n-marcas largo paso))
     (while (>= k 0)
       (setq c (* (+ k 0.5) paso))
       (if (and (>= (- c f2) (- mccolind-eps)) (<= (+ c f2) (+ largo mccolind-eps)))
         (mccolind:circulo (mccolind:fram p u n c 0.0) f2))
       (setq k (1- k))))
    ;; Paredes: diagonales a 30° de la perpendicular al lindero.
    ((member estilo '(2 3 4))
     (setq o1 (cond ((= estilo 2) 0.0) ((= estilo 3) (- f2)) (T 0.0))
           o2 (cond ((= estilo 2) f) ((= estilo 3) f2) (T (- f)))
           ;; Extensión longitudinal de la diagonal a 30° de la perpendicular.
           du (* f (mccolind:tan30) 0.5)
           k (mccolind:n-marcas largo paso))
     (while (>= k 0)
       (setq c (* (+ k 0.5) paso))
       (if (and (>= (- c du) (- mccolind-eps)) (<= (+ c du) (+ largo mccolind-eps)))
         (mccolind:linea (mccolind:fram p u n (- c du) o1)
                         (mccolind:fram p u n (+ c du) o2)))
       (setq k (1- k))))
    ;; Malla: conservar la proyección de cada X a 75°: franja*cot(75°).
    ;; DU se fija antes de ampliar el paso: en automático hay huecos;
    ;; en manual las X siguen contiguas. No cambia el tamaño ni el ángulo.
    ((= estilo 5)
     (setq paso (* f (/ (cos (* pi (/ 75.0 180.0)))
                        (sin (* pi (/ 75.0 180.0)))))
           du (/ paso 2.0))
     (if (= mccolind-automatico "1") (setq paso (* paso 1.5)))
     (setq k (mccolind:n-marcas largo paso))
     (while (>= k 0)
       (setq c (* (+ k 0.5) paso))
       (if (and (>= (- c du) (- mccolind-eps)) (<= (+ c du) (+ largo mccolind-eps)))
         (progn
           (mccolind:linea (mccolind:fram p u n (- c du) f2)
                           (mccolind:fram p u n (+ c du) (- f2)))
           (mccolind:linea (mccolind:fram p u n (- c du) (- f2))
                           (mccolind:fram p u n (+ c du) f2))))
       (setq k (1- k))))
    ;; Lindero de árboles vivos: zigzag continuo dentro de la franja.
    ((= estilo 6) (mccolind:zigzag p u n largo)))
  T)

;; Recorre la cadena del recorrido manteniendo el lado interior pedido.
(defun mccolind:patron-ruta (puntos sentido / lado n k a b u)
  (setq lado (* mccolind-lado-canonico sentido)
        n (1- (length puntos))
        k 0)
  (while (< k n)
    (setq a (nth k puntos)
          b (nth (1+ k) puntos)
          u (mccolind:unitaria (mccolind:restar b a)))
    (if u
      (mccolind:tramo-patron a u (distance a b) (if (> lado 0) (mccolind:izq u) (mccolind:der u))))
    (setq k (1+ k)))
  T)

;;; ============================================================
;;; SECCIÓN 7: ETIQUETAS (MEDICIÓN REAL Y CAJA ORIENTADA)
;;; ============================================================
(defun mccolind:estilo-datos ( / st w o fijo)
  (setq st (tblsearch "STYLE" (getvar "TEXTSTYLE")))
  (setq w (if (and st (assoc 41 st)) (cdr (assoc 41 st)) 1.0)
        o (if (and st (assoc 51 st)) (cdr (assoc 51 st)) 0.0)
        fijo (if (and st (assoc 40 st)) (cdr (assoc 40 st)) 0.0))
  (if (< w 1e-6) (setq w 1.0))
  (list w o fijo))

;; Caja real del texto con el estilo actual, medida a rotación 0.
(defun mccolind:medir-texto (texto altura / ef w o tb p1 p2)
  (setq ef (mccolind:estilo-datos)
        w (car ef)
        o (cadr ef))
  (setq tb (vl-catch-all-apply
             'textbox
             (list (list '(0 . "TEXT")
                         (cons 1 texto)
                         (cons 7 (getvar "TEXTSTYLE"))
                         (cons 40 altura)
                         (cons 41 w)
                         (cons 51 o)
                         (cons 71 0) (cons 72 0) (cons 73 0)
                         (cons 10 '(0.0 0.0 0.0))
                         (cons 11 '(0.0 0.0 0.0))))))
  (if (or (vl-catch-all-error-p tb) (null tb) (< (length tb) 2))
    nil
    (progn
      (setq p1 (car tb) p2 (cadr tb))
      (list (min (car p1) (car p2)) (min (cadr p1) (cadr p2))
            (max (car p1) (car p2)) (max (cadr p1) (cadr p2))))))

;; Rectángulo orientado: (origen e1 e2 ancho alto).
(defun mccolind:recto-candidato (ins rot x1 y1 x2 y2 / cs sn e1 e2)
  (setq cs (cos rot) sn (sin rot)
        e1 (list cs sn)
        e2 (list (- sn) cs))
  (list (list (+ (car ins) (* x1 (car e1)) (* y1 (car e2)))
              (+ (cadr ins) (* x1 (cadr e1)) (* y1 (cadr e2))))
        e1 e2 (- x2 x1) (- y2 y1)))

(defun mccolind:recto-esquinas (rect / o e1 e2 lx ly)
  (setq o (nth 0 rect) e1 (nth 1 rect) e2 (nth 2 rect)
        lx (nth 3 rect) ly (nth 4 rect))
  (list o
        (list (+ (car o) (* lx (car e1))) (+ (cadr o) (* lx (cadr e1))))
        (list (+ (car o) (* lx (car e1)) (* ly (car e2)))
              (+ (cadr o) (* lx (cadr e1)) (* ly (cadr e2))))
        (list (+ (car o) (* ly (car e2))) (+ (cadr o) (* ly (cadr e2))))))

(defun mccolind:recto-local (rect p / ox oy e1 e2)
  (setq ox (- (car p) (car (nth 0 rect)))
        oy (- (cadr p) (cadr (nth 0 rect)))
        e1 (nth 1 rect)
        e2 (nth 2 rect))
  (list (+ (* ox (car e1)) (* oy (cadr e1)))
        (+ (* ox (car e2)) (* oy (cadr e2)))))

(defun mccolind:dist-punto-recto (rect p / l cx cy o e1 e2)
  (setq l (mccolind:recto-local rect p)
        cx (mccolind:clamp (car l) 0.0 (nth 3 rect))
        cy (mccolind:clamp (cadr l) 0.0 (nth 4 rect))
        o (nth 0 rect) e1 (nth 1 rect) e2 (nth 2 rect))
  (distance p (list (+ (car o) (* cx (car e1)) (* cy (car e2)))
                    (+ (cadr o) (* cx (cadr e1)) (* cy (cadr e2))))))

;; T si el punto cae dentro del rectángulo orientado (incluido su borde).
(defun mccolind:punto-en-recto (rect p / l tole)
  (setq l (mccolind:recto-local rect p)
        tole 1e-9)
  (and (>= (car l) (- tole))
       (<= (car l) (+ (nth 3 rect) tole))
       (>= (cadr l) (- tole))
       (<= (cadr l) (+ (nth 4 rect) tole))))

(defun mccolind:recto-seg-inters (rect a b / esq i res)
  (setq esq (mccolind:recto-esquinas rect) i 0 res nil)
  (while (< i 4)
    (if (mccolind:segmentos-tocan (nth i esq)
                                  (nth (fix (mccolind:mod (1+ i) 4)) esq) a b)
      (setq res T))
    (setq i (1+ i)))
  res)

;; Separación entre dos cajas: 0 si se cortan o se contienen.
;; Separación entre dos cajas: 0 si se cortan, se tocan o una contiene a
;; la otra. La distancia mínima entre rectángulos se obtiene de la
;; distancia entre sus lados, con los cuatro lados de cada caja.
(defun mccolind:rectos-distancia (r1 r2 / e1 e2 l1 l2 d)
  (setq e1 (mccolind:recto-esquinas r1)
        e2 (mccolind:recto-esquinas r2)
        l1 (mccolind:aristas e1 T)
        l2 (mccolind:aristas e2 T)
        d 1.0e308)
  (foreach a l1
    (foreach b l2
      (setq d (min d (mccolind:dist-seg-seg (car a) (cadr a) (car b) (cadr b))))))
  (if (or (mccolind:punto-en-recto r1 (car e2))
          (mccolind:punto-en-recto r2 (car e1)))
    (setq d 0.0))
  d)

;; Inserción para que el centro de la caja quede en CENTRO.
(defun mccolind:insercion-centrada (centro rot x1 y1 x2 y2 / cx cy cs sn)
  (setq cx (/ (+ x1 x2) 2.0)
        cy (/ (+ y1 y2) 2.0)
        cs (cos rot)
        sn (sin rot))
  (list (- (car centro) (- (* cx cs) (* cy sn)))
        (- (cadr centro) (+ (* cx sn) (* cy cs)))))

;; Devuelve nil si la etiqueta es válida; si no, el motivo en español.
;; SIGNO: +1 interior, -1 exterior. LADO: +1 interior a la izquierda del
;; recorrido. HOLGURA: separación mínima exigida desde el patrón.
(defun mccolind:etiqueta-aviso (rect puntos lado signo holgura otras
                                / esq lados segs msj v d mejor n ar)
  (setq esq (mccolind:recto-esquinas rect)
        lados (mccolind:aristas esq T)
        segs (if mccolind-cerrada
               (mccolind:aristas mccolind-puntos T)
               (mccolind:aristas-ruta puntos))
        msj nil)
  ;; Holgura completa en los dos sentidos: cada lado de la caja contra
  ;; cada tramo de referencia. Cruzar, tocar o quedar a menos de HOLGURA
  ;; invalida la posición, así no se escapa un vértice de la fuente cerca
  ;; de la mitad de un lado largo de la caja.
  (foreach ar segs
    (foreach v lados
      (if (null msj)
        (if (<= (mccolind:dist-seg-seg (car v) (cadr v) (car ar) (cadr ar))
                (- holgura 1e-9))
          (setq msj "la caja cruza el lindero o invade la franja.")))))
  ;; Contorno cerrado: la caja completa dentro o completa fuera, sin
  ;; contener vértices del contorno; una caja que envuelve la fuente
  ;; tampoco es una posición exterior válida.
  (if (and (null msj) mccolind-cerrada)
    (if (> signo 0)
      (foreach v esq
        (if (null msj)
          (if (not (mccolind:punto-dentro v mccolind-puntos))
            (setq msj "la caja no cabe completa en el interior."))))
      (progn
        (foreach v esq
          (if (null msj)
            (if (mccolind:punto-dentro v mccolind-puntos)
              (setq msj "la caja no queda completa en el exterior."))))
        (foreach v mccolind-puntos
          (if (null msj)
            (if (mccolind:punto-en-recto rect v)
              (setq msj "la caja contendría parte del contorno; elija una posición exterior.")))))))
  ;; Fuente abierta: el lado interior lo indicó el usuario. Cada esquina
  ;; debe quedar del lado pedido respecto del tramo más cercano.
  (if (and (null msj) (not mccolind-cerrada))
    (foreach v esq
      (if (null msj)
        (progn
          (setq mejor nil)
          (foreach ar segs
            (setq d (mccolind:dist-punto-seg v (car ar) (cadr ar)))
            (if (or (null mejor) (< d (car mejor))) (setq mejor (list d ar))))
          (setq n (mccolind:normal-lado (cadr mejor) (* lado signo)))
          (if (or (null n)
                  (<= (mccolind:dot (mccolind:restar v (car (cadr mejor))) n) 0.0))
            (setq msj (if (> signo 0)
                        "la caja no queda completa en el lado interior."
                        "la caja no queda completa en el lado exterior.")))))))
  ;; Las etiquetas de un mismo recorrido no deben solaparse entre sí.
  (foreach ar otras
    (if (null msj)
      (if (< (mccolind:rectos-distancia rect ar) (- mccolind-sep 1e-9))
        (setq msj "la caja se solapa con la otra etiqueta."))))
  msj)

;; Búsqueda acotada: primero lo más cerca posible de la mitad de la
;; longitud recorrida y del borde de la franja. Devuelve (inserción caja
;; rotación) o nil si no hay posición válida en el límite de la búsqueda.
(defun mccolind:ubicar-etiqueta (texto altura signo medio lado holgura otras
                                 / caja x1 y1 x2 y2 u n rot b0 b j dx ins rect objetivo enc)
  (setq caja (mccolind:medir-texto texto altura))
  (if (null caja) (mccolind:fallar "textbox no está disponible para medir las etiquetas."))
  (setq x1 (nth 0 caja) y1 (nth 1 caja) x2 (nth 2 caja) y2 (nth 3 caja)
        u (cadr medio)
        rot (mccolind:rot-legible (atan (cadr u) (car u)))
        n (if (> (* lado signo) 0) (mccolind:izq u) (mccolind:der u))
        b0 (+ holgura (/ (- y2 y1) 2.0))
        enc nil
        j 0)
  (while (and (null enc) (< j 5))
    (setq b (+ b0 (* j (/ mccolind-paso 2.0))))
    (foreach dx '(0.0 -1.0 1.0 -2.0 2.0 -3.0 3.0)
      (if (null enc)
        (progn
          (setq objetivo (mccolind:sumar (car medio)
                              (mccolind:sumar (mccolind:escalar u (* dx mccolind-paso))
                                              (mccolind:escalar n b)))
                ins (mccolind:insercion-centrada objetivo rot x1 y1 x2 y2)
                rect (mccolind:recto-candidato ins rot x1 y1 x2 y2))
          (if (null (mccolind:etiqueta-aviso rect puntos lado signo holgura otras))
            (setq enc (list ins rect rot))))))
    (setq j (1+ j)))
  enc)

;; Ubicación manual validada cuando la búsqueda acotada no encuentra sitio.
(defun mccolind:ubicar-manual (texto altura signo puntos lado holgura otras
                               / res caja x1 y1 x2 y2 p ar u rot ins rect aviso intentos)
  (princ (strcat "\nMCCOLIND: no hay posición segura para la etiqueta "
                 (if (> signo 0) "interior" "exterior")
                 " cerca de la mitad del recorrido."))
  (setq caja (mccolind:medir-texto texto altura))
  (if (null caja) (mccolind:fallar "textbox no está disponible para medir las etiquetas."))
  (setq x1 (nth 0 caja) y1 (nth 1 caja) x2 (nth 2 caja) y2 (nth 3 caja)
        res nil
        intentos 0)
  (while (and (null res) (< intentos 100))
    (setq p (getpoint "\nMCCOLIND: centro de la etiqueta (ESC cancela la ejecución): "))
    (if (null p)
      (setq intentos 100)
      (progn
        ;; El clic llega en UCS: a WCS y luego a coordenadas locales de
        ;; la fuente, que son las que usan las pruebas de la caja. La
        ;; creación vuelve a WCS una sola vez.
        (setq p (mccolind:local (trans p 1 0))
              ar (mccolind:arista-mas-cercana puntos p)
              u (mccolind:unitaria (mccolind:restar (cadr ar) (car ar)))
              rot (if u (mccolind:rot-legible (atan (cadr u) (car u))) 0.0)
              ins (mccolind:insercion-centrada p rot x1 y1 x2 y2)
              rect (mccolind:recto-candidato ins rot x1 y1 x2 y2)
              aviso (mccolind:etiqueta-aviso rect puntos lado signo holgura otras))
        (if aviso
          (progn
            (alert (strcat "Posición no válida: " aviso
                           "\nElija otro punto o pulse ESC para cancelar."))
            (setq intentos (1+ intentos)))
          (setq res (list ins rect rot))))))
  (if (null res)
    (mccolind:fallar "No se indicó una posición válida para la etiqueta; se descarta la ejecución. La fuente no se modifica."))
  res)

;; Paridad explícita con lo medido: el TEXT recibe el ancho y la
;; oblicuidad efectivos del estilo (los mismos valores con los que se
;; midió la caja) y banderas de generación 0, es decir texto normal, sin
;; espejo ni giro de 180°. Si AutoCAD no expone alguna propiedad, se
;; informa y se conserva lo que asigne el estilo.
(defun mccolind:propiedades-texto (obj / ef fallos)
  (setq ef (mccolind:estilo-datos)
        fallos 0)
  (if (vl-catch-all-error-p
        (vl-catch-all-apply 'vla-put-ScaleFactor (list obj (car ef))))
    (setq fallos (1+ fallos)))
  (if (vl-catch-all-error-p
        (vl-catch-all-apply 'vla-put-ObliqueAngle (list obj (cadr ef))))
    (setq fallos (1+ fallos)))
  (if (vl-catch-all-error-p
        (vl-catch-all-apply 'vla-put-TextGenerationFlag (list obj 0)))
    (setq fallos (1+ fallos)))
  (if (> fallos 0)
    (princ (strcat "\nAVISO: no se pudieron fijar " (itoa fallos)
                   " propiedad(es) del TEXT; compare la caja medida con el texto dibujado.")))
  fallos)

(defun mccolind:crear-texto (ins rot texto altura / obj)
  (setq obj (vla-AddText mccolind-espacio texto
                         (vlax-3d-point (mccolind:wcs ins))
                         altura))
  (mccolind:entidad obj)
  (vla-put-Layer obj mccolind-capa)
  (vla-put-StyleName obj (getvar "TEXTSTYLE"))
  ;; Fijar después de asignar el estilo: su altura fija no debe anular
  ;; el perfil automático. Solo se modifica este TEXT, nunca el STYLE.
  (vla-put-Height obj altura)
  (vla-put-Rotation obj rot)
  (mccolind:propiedades-texto obj)
  obj)

;; Un par de etiquetas por recorrido: el nombre del estilo dentro y el
;; nombre de la colindancia fuera. Nunca se omiten en silencio.
(defun mccolind:etiquetas-ruta (puntos lado / medio datos interior exterior
                                cint cext holgura-int holgura-ext)
  (setq medio (mccolind:mitad-ruta puntos)
        datos (mccolind:banda mccolind-estilo)
        interior (nth mccolind-estilo (mccolind:nombres))
        exterior mccolind-nombre
        holgura-int (+ (car datos) mccolind-sep)
        holgura-ext (+ (cdr datos) mccolind-sep-ext))
  (setq cint (mccolind:ubicar-etiqueta interior mccolind-h-efectiva 1 medio lado holgura-int nil))
  (if (null cint)
    (setq cint (mccolind:ubicar-manual interior mccolind-h-efectiva 1 puntos lado holgura-int nil)))
  (setq cext (mccolind:ubicar-etiqueta exterior mccolind-h-ext -1 medio lado holgura-ext (list (cadr cint))))
  (if (null cext)
    (setq cext (mccolind:ubicar-manual exterior mccolind-h-ext -1 puntos lado holgura-ext (list (cadr cint)))))
  (mccolind:crear-texto (car cint) (nth 2 cint) interior mccolind-h-efectiva)
  (mccolind:crear-texto (car cext) (nth 2 cext) exterior mccolind-h-ext)
  T)

;;; ============================================================
;;; SECCIÓN 8: SESIÓN, APLICACIÓN Y DESHACER
;;; ============================================================
;; Borra una entidad creada por este comando. Devuelve T solo si la
;; entidad ya no está en el dibujo. La fuente nunca entra en el libro de
;; entidades creadas y, además, se rechaza explícitamente por identidad
;; antes de borrar: ningún camino puede alcanzarla.
(defun mccolind:borrar (obj / ent borrado)
  (setq borrado
        (vl-catch-all-apply
          '(lambda ()
             (setq ent (vl-catch-all-apply 'vlax-vla-object->ename (list obj)))
             (if (and (not (vl-catch-all-error-p ent))
                      mccolind-fuente
                      (eq ent mccolind-fuente))
               nil
               (if (or (vlax-object-released-p obj) (vlax-erased-p obj))
                 T
                 (progn (vla-Delete obj) T)))) nil))
  (and (not (vl-catch-all-error-p borrado)) borrado))

;; Devuelve la lista de entidades que NO se pudieron retirar; el llamador
;; decide qué hacer con ellas en lugar de dar por hecho el borrado.
(defun mccolind:borrar-lote (objs / vivos)
  (setq vivos nil)
  (foreach obj objs
    (if (not (mccolind:borrar obj)) (setq vivos (cons obj vivos))))
  vivos)

;; Aplica el recorrido elegido: patrón, etiquetas y registro de sesión.
(defun mccolind:aplicar-ruta (ruta / puntos sentido lado)
  (setq puntos (car ruta)
        sentido (nth 3 ruta)
        lado (* mccolind-lado-canonico sentido)
        mccolind-actual nil
        mccolind-cuenta 0)
  (mccolind:patron-ruta puntos sentido)
  (mccolind:etiquetas-ruta puntos lado)
  (setq mccolind-sesion
        (cons (list mccolind-estilo
                    (reverse mccolind-actual)
                    (mccolind:intervalos (nth 1 ruta) (nth 2 ruta))
                    (1+ mccolind-aplicaciones))
              mccolind-sesion)
        mccolind-aplicaciones (1+ mccolind-aplicaciones)
        mccolind-actual nil
        mccolind-cuenta 0)
  (princ (strcat "\nMCCOLIND: aplicación " (itoa mccolind-aplicaciones)
                 " creada (" (itoa (length (cadr (car mccolind-sesion))))
                 " entidades)."))
  T)

;; Deshacer última aplicación: retira solo sus entidades y libera su
;; tramo en el registro de solapes de la sesión. Si alguna entidad
;; sobrevive, no se libera ni el registro ni el tramo.
(defun mccolind:deshacer-ultima (/ ultima vivos)
  (if (null mccolind-sesion)
    (alert "No hay aplicaciones que deshacer en esta ejecución.")
    (progn
      (setq ultima (car mccolind-sesion)
            vivos (mccolind:borrar-lote (cadr ultima)))
      (cond
        (vivos
         ;; Quedan entidades: se conserva el registro y su tramo sigue
         ;; ocupado, para no perder geometría creada por la ejecución.
         (setq mccolind-sesion
               (cons (list (nth 0 ultima) vivos (nth 2 ultima) (nth 3 ultima))
                     (cdr mccolind-sesion)))
         (princ (strcat "\nAVISO: AutoCAD no retiró " (itoa (length vivos))
                        " entidad(es) de la aplicación " (itoa (nth 3 ultima))
                        "; se conserva su registro y su tramo sigue ocupado.")))
        (T
         (setq mccolind-sesion (cdr mccolind-sesion))
         (princ (strcat "\nMCCOLIND: se deshizo la aplicación " (itoa (nth 3 ultima))
                        " (" (itoa (length (cadr ultima)))
                        " entidades). Quedan " (itoa (length mccolind-sesion))
                        " aplicación(es) retenida(s) en esta ejecución.")))))))

(defun mccolind:limpiar (/ r fallos previo vivos conservar)
  (setq fallos 0)
  (setq mccolind-vivos 0
        mccolind-undo-fallo nil)
  (vl-catch-all-apply '(lambda () (done_dialog 0)) nil)
  (if (and mccolind-id (>= mccolind-id 0))
    (vl-catch-all-apply 'unload_dialog (list mccolind-id)))
  (setq mccolind-id nil)
  (if (and mccolind-ruta (findfile mccolind-ruta))
    (if (not (vl-file-delete mccolind-ruta)) (setq fallos (1+ fallos))))
  (setq mccolind-ruta nil)
  ;; Sin aceptación explícita se intentan retirar, una sola vez y sin
  ;; reintentos, todas las entidades de la ejecución: el lote en curso y
  ;; las aplicaciones registradas. Los fallos se cuentan, se informan y
  ;; las entidades que sobreviven no se pierden de vista.
  (if (not mccolind-completado)
    (progn
      (setq vivos (mccolind:borrar-lote mccolind-actual)
            mccolind-actual (if vivos (reverse vivos) nil)
            mccolind-vivos (length vivos))
      (setq conservar nil)
      (foreach previo mccolind-sesion
        (setq vivos (mccolind:borrar-lote (cadr previo)))
        (if vivos
          (setq conservar (cons (list (nth 0 previo) vivos (nth 2 previo) (nth 3 previo))
                                conservar)))
        (setq mccolind-vivos (+ mccolind-vivos (length vivos))))
      (setq mccolind-sesion (reverse conservar))))
  (foreach previo mccolind-entorno
    (setq r (vl-catch-all-apply 'setvar (list (car previo) (cdr previo))))
    (if (vl-catch-all-error-p r) (setq fallos (1+ fallos))))
  (if mccolind-undo
    (progn
      (setq r (vl-catch-all-apply 'vla-EndUndoMark (list mccolind-doc)))
      (if (vl-catch-all-error-p r) (setq mccolind-undo-fallo T))
      (setq mccolind-undo nil)))
  (if (> fallos 0)
    (princ "\nAVISO: AutoCAD impidió parte de la limpieza/restauración de variables o temporales. Revise el dibujo y las variables del sistema."))
  (if (> mccolind-vivos 0)
    (princ (strcat "\nAVISO: quedaron " (itoa mccolind-vivos)
                   " entidad(es) de esta ejecución que AutoCAD no retiró; el registro se conserva.")))
  (if mccolind-undo-fallo
    (princ "\nAVISO: AutoCAD no pudo cerrar la marca de deshacer; el UNDO único no está garantizado."))
  T)

;;; ============================================================
;;; SECCIÓN 9: CAMPOS DEL DIÁLOGO Y ESTADO
;;; ============================================================
;; Número positivo estricto: sin texto sobrante, comas ni exponentes.
(defun mccolind:positivo (txt / s len i c punto digitos valido val)
  (setq s (if txt (vl-string-trim " \t" txt) "")
        len (strlen s)
        i 1
        punto nil
        digitos 0
        valido T)
  (if (and (>= len 1) (member (substr s 1 1) '("+" "-"))) (setq i 2))
  (while (and (<= i len) valido)
    (setq c (substr s i 1))
    (cond ((and (>= (ascii c) 48) (<= (ascii c) 57)) (setq digitos (1+ digitos)))
          ((and (= c ".") (not punto)) (setq punto T))
          (T (setq valido nil)))
    (setq i (1+ i)))
  (if (or (not valido) (zerop digitos))
    nil
    (progn
      (setq val (atof s))
      (if (> val 0.0) val nil))))

;; Perfil en metros: (altura interior, altura exterior, paso normal,
;; ancho de franja, holgura interior, holgura exterior). Sin modificar
;; campos ni recursos globales; también sirve para el resumen del DCL.
(defun mccolind:perfil-medidas (/ h k fijo)
  (if (= mccolind-automatico "1")
    (progn
      (setq h (/ mccolind-dimension 100.0))
      ;; Símbolos y franjas al doble; textos, holguras y paso conservados.
      (list h (* h 1.5) (* h 2.0) h (* h 0.5) (* h 1.5)))
    (progn
      (setq k (* (mccolind:positivo mccolind-escala-raw) 0.001)
            h (* (mccolind:positivo mccolind-texto-raw) k)
            fijo (nth 2 (mccolind:estilo-datos)))
      ;; El modo manual conserva la altura fija y las dos etiquetas
      ;; iguales del comportamiento anterior.
      (if (> fijo 1e-9) (setq h fijo))
      (list h h
            (* (mccolind:positivo mccolind-paso-raw) k)
            (* (mccolind:positivo mccolind-franja-raw) k)
            (* (mccolind:positivo mccolind-sep-raw) k)
            (* (mccolind:positivo mccolind-sep-raw) k)))))

;; Auto: proporciones respecto de la fuente completa seleccionada.
;; Manual: milímetros de papel a metros, con la escala 1:N conservada.
(defun mccolind:calcular-medidas (/ perfil fijo)
  (setq perfil (mccolind:perfil-medidas)
        mccolind-h-efectiva (nth 0 perfil)
        mccolind-h-ext (nth 1 perfil)
        mccolind-paso (nth 2 perfil)
        mccolind-franja (nth 3 perfil)
        mccolind-sep (nth 4 perfil)
        mccolind-sep-ext (nth 5 perfil))
  (if (/= mccolind-automatico "1")
    (progn
      (setq mccolind-h (* mccolind-texto-m mccolind-escala 0.001)
            fijo (nth 2 (mccolind:estilo-datos)))
      (if (and (> fijo 1e-9) (> (abs (- fijo mccolind-h)) 1e-9))
        (princ (strcat "\nMCCOLIND: el estilo de texto actual tiene altura fija "
                       (rtos fijo 2 4) "; se usa esa altura en lugar de la medida del diálogo.")))))
  T)

(defun mccolind:validar-campos (/ msg)
  (setq mccolind-escala (mccolind:positivo mccolind-escala-raw)
        mccolind-texto-m (mccolind:positivo mccolind-texto-raw)
        mccolind-paso-m (mccolind:positivo mccolind-paso-raw)
        mccolind-franja-m (mccolind:positivo mccolind-franja-raw)
        mccolind-sep-m (mccolind:positivo mccolind-sep-raw)
        mccolind-nombre (if mccolind-nombre-raw
                          (vl-string-trim " \t" mccolind-nombre-raw)
                          ""))
  (cond
    ((and (/= mccolind-automatico "1") (null mccolind-escala))
     "La escala 1:N debe ser un número positivo (por ejemplo, 500).")
    ((and (/= mccolind-automatico "1") (null mccolind-texto-m))
     "La altura de texto debe ser un número positivo en milímetros (por ejemplo, 2).")
    ((and (/= mccolind-automatico "1") (null mccolind-paso-m))
     "La repetición del patrón debe ser un número positivo en milímetros (por ejemplo, 4).")
    ((and (/= mccolind-automatico "1") (null mccolind-franja-m))
     "El ancho total de franja debe ser un número positivo en milímetros (por ejemplo, 1).")
    ((and (/= mccolind-automatico "1") (null mccolind-sep-m))
     "La separación libre debe ser un número positivo en milímetros (por ejemplo, 1).")
    ((= (strlen mccolind-nombre) 0)
     "Escriba el nombre de la colindancia exterior que se rotulará fuera.")
    ((> (strlen mccolind-nombre) 200)
     "El nombre de la colindancia no debe superar 200 caracteres.")
    (T (mccolind:calcular-medidas) nil)))

(defun mccolind:resumen-medidas (/ perfil)
  (if (and (/= mccolind-automatico "1")
           (or (null (mccolind:positivo mccolind-escala-raw))
               (null (mccolind:positivo mccolind-texto-raw))
               (null (mccolind:positivo mccolind-paso-raw))
               (null (mccolind:positivo mccolind-franja-raw))
               (null (mccolind:positivo mccolind-sep-raw))))
    (list "Medidas: complete números positivos para ver la conversión." "" "")
    (progn
      (setq perfil (mccolind:perfil-medidas))
      (list
        (strcat (if (= mccolind-automatico "1")
                  (strcat "D=" (rtos mccolind-dimension 2 3) " m. ")
                  "Manual. ")
                "Texto int./ext.: " (rtos (nth 0 perfil) 2 3) " / "
                (rtos (nth 1 perfil) 2 3) " m.")
        (strcat "Paso normal: " (rtos (nth 2 perfil) 2 3)
                " m; franja: " (rtos (nth 3 perfil) 2 3) " m.")
        (strcat "Separación libre int./ext.: " (rtos (nth 4 perfil) 2 3)
                " / " (rtos (nth 5 perfil) 2 3) " m.")))))

(defun mccolind:resumen-sesion ()
  (if (null mccolind-sesion)
    "Sin aplicaciones en esta ejecución."
    (strcat "Aplicaciones en esta ejecución: " (itoa (length mccolind-sesion))
            ". Última: " (nth (car (car mccolind-sesion)) (mccolind:nombres)) ".")))

(defun mccolind:guardar-dlg ()
  (setq mccolind-automatico (get_tile "automatico")
        mccolind-escala-raw (get_tile "escala")
        mccolind-texto-raw (get_tile "texto")
        mccolind-paso-raw (get_tile "repeticion")
        mccolind-franja-raw (get_tile "franja")
        mccolind-sep-raw (get_tile "separacion")
        mccolind-nombre-raw (get_tile "nombre")
        mccolind-estilo (atoi (get_tile "estilo")))
  (if (or (< mccolind-estilo 0) (> mccolind-estilo 6)) (setq mccolind-estilo 0))
  T)

(defun mccolind:actualizar-dlg (/ resumen)
  (foreach clave '("escala" "texto" "repeticion" "franja" "separacion")
    (mode_tile clave (if (= mccolind-automatico "1") 1 0)))
  (set_tile "lado" (nth mccolind-estilo (mccolind:descripciones)))
  (setq resumen (mccolind:resumen-medidas))
  (set_tile "medidas" (nth 0 resumen))
  (set_tile "medidas2" (nth 1 resumen))
  (set_tile "medidas3" (nth 2 resumen))
  (set_tile "estado" (mccolind:resumen-sesion))
  T)

;; Los campos crudos se conservan al reabrir el diálogo, incluso si son
;; inválidos, para no perder lo escrito por el usuario.
(defun mccolind:cargar-dlg ()
  (set_tile "fuente" mccolind-descripcion-fuente)
  (set_tile "automatico" mccolind-automatico)
  (set_tile "escala" mccolind-escala-raw)
  (set_tile "texto" mccolind-texto-raw)
  (set_tile "repeticion" mccolind-paso-raw)
  (set_tile "franja" mccolind-franja-raw)
  (set_tile "separacion" mccolind-sep-raw)
  (set_tile "nombre" mccolind-nombre-raw)
  (start_list "estilo")
  (mapcar 'add_list (mccolind:nombres))
  (end_list)
  (set_tile "estilo" (itoa mccolind-estilo))
  (mccolind:actualizar-dlg))

;;; ============================================================
;;; SECCIÓN 10: FLUJO DE UNA APLICACIÓN
;;; ============================================================
(defun mccolind:flujo-aplicar (/ rutas ruta)
  (setq mccolind-msg nil)
  (if (mccolind:capturar-par)
    (progn
      (setq rutas (mccolind:rutas)
            ruta (mccolind:previsualizar rutas))
      (cond
        ((eq ruta 'cancelar)
         (setq mccolind-abortado T)
         (princ "\nMCCOLIND cancelado: se descartan todas las aplicaciones de esta ejecución."))
        ((null ruta) nil)
        ((mccolind:rutas-solapan (mccolind:intervalos (nth 1 ruta) (nth 2 ruta)))
         (alert (strcat "Ese tramo ya está cubierto por una aplicación de esta ejecución.\n"
                        "Elija otro tramo o deshaga la aplicación anterior.")))
        (T (mccolind:aplicar-ruta ruta)))))
  T)

;;; ============================================================
;;; SECCIÓN 11: COMANDO C:MCCOLIND
;;; ============================================================
;; Espacio de edición real: modelo cuando TILEMODE está activo o cuando se
;; trabaja dentro de una ventana gráfica flotante (CVPORT > 1); en caso
;; contrario, el espacio papel del layout activo. Comparar solo contra el
;; layout activo rechazaría una fuente de modelo abierta en una ventana.
(defun mccolind:espacio-edicion (/ tile cv)
  (setq tile (getvar "TILEMODE")
        cv (getvar "CVPORT"))
  (if (or (= tile 1) (> cv 1))
    (vla-get-ModelSpace mccolind-doc)
    (vla-get-PaperSpace mccolind-doc)))

(defun C:MCCOLIND (/ *error* seleccion continuar estado aviso r
                     mccolind-fuente mccolind-undo-fallo mccolind-vivos
                     mccolind-doc mccolind-entorno mccolind-undo mccolind-msg
                     mccolind-completado mccolind-abortado
                     mccolind-ruta mccolind-id mccolind-capa mccolind-espacio
                     mccolind-origen mccolind-z mccolind-puntos mccolind-cerrada
                     mccolind-eps mccolind-lado-canonico mccolind-aristas
                     mccolind-len mccolind-cum mccolind-total mccolind-uA mccolind-uB
                     mccolind-automatico mccolind-dimension mccolind-h-ext mccolind-sep-ext
                     mccolind-actual mccolind-sesion mccolind-aplicaciones
                     mccolind-cuenta mccolind-tope
                     mccolind-escala-raw mccolind-texto-raw mccolind-paso-raw
                     mccolind-franja-raw mccolind-sep-raw mccolind-nombre-raw
                     mccolind-escala mccolind-texto-m mccolind-paso-m
                     mccolind-franja-m mccolind-sep-m
                     mccolind-h mccolind-h-efectiva mccolind-paso mccolind-franja
                     mccolind-sep mccolind-estilo mccolind-nombre
                     mccolind-descripcion-fuente)
  (defun *error* (msg)
    (mccolind:limpiar)
    (cond
      (mccolind-msg (princ (strcat "\nMCCOLIND: " mccolind-msg)))
      ((member (strcase (if msg msg "")) '("FUNCTION CANCELLED" "QUIT / EXIT ABORT" ""))
       (if (and mccolind-vivos (> mccolind-vivos 0))
         (princ (strcat "\nMCCOLIND cancelado, pero AutoCAD no retiró "
                        (itoa mccolind-vivos)
                        " entidad(es). Revise el dibujo antes de continuar."))
         (princ "\nMCCOLIND cancelado. No se conserva ningún resultado parcial.")))
      (T (princ (strcat "\nMCCOLIND error: " (if msg msg "")))))
    (princ))

  ;; -------- entorno --------
  (setq mccolind-doc (vla-get-ActiveDocument (vlax-get-acad-object))
        mccolind-entorno (mapcar '(lambda (v) (cons v (getvar v)))
                                 '("OSMODE" "CMDECHO" "DIMZIN"))
        mccolind-capa (getvar "CLAYER")
        mccolind-msg nil
        mccolind-completado nil
        mccolind-abortado nil
        mccolind-undo nil
        mccolind-actual nil
        mccolind-sesion nil
        mccolind-aplicaciones 0
        mccolind-cuenta 0
        mccolind-tope 20000
        mccolind-estilo 0
        mccolind-automatico "1"
        mccolind-escala-raw "500"
        mccolind-texto-raw "2"
        mccolind-paso-raw "4"
        mccolind-franja-raw "1"
        mccolind-sep-raw "1"
        mccolind-nombre-raw "Colindancia"
        mccolind-lado-canonico nil
        mccolind-ruta nil
        mccolind-id nil)
  (setvar "CMDECHO" 0)
  (setvar "DIMZIN" 0)
  (setvar "OSMODE" 0)
  (princ "\n=== MCCOLIND: simbología y etiquetas de colindancias ===")

  ;; -------- selección y validación de la fuente --------
  (setq seleccion (entsel "\nSeleccione una LINE o LWPOLYLINE de tramos rectos: "))
  (if (null seleccion) (exit))
  (setq mccolind-fuente (car seleccion))
  (mccolind:leer-fuente mccolind-fuente)
  ;; La fuente debe estar en el espacio activo: no se estilizan entidades
  ;; de otro espacio ni se crean resultados mezclados. El resultado se crea
  ;; siempre en el espacio propietario de la fuente.
  (setq mccolind-espacio
        (vlax-ename->vla-object (cdr (assoc 330 (entget (car seleccion))))))
  (setq r (vl-catch-all-apply
            '(lambda ()
               (/= (vla-get-ObjectID mccolind-espacio)
                   (vla-get-ObjectID (mccolind:espacio-edicion))))
            nil))
  (cond
    ((vl-catch-all-error-p r)
     (princ "\nAVISO: no se pudo comprobar el espacio activo; el resultado se creará en el espacio de la fuente."))
    (r (mccolind:fallar "La fuente está en otro espacio; actívela o cambie al espacio que la contiene.")))
  (if (/= 0 (logand 4 (cdr (assoc 70 (tblsearch "LAYER" mccolind-capa)))))
    (mccolind:fallar "La capa actual está bloqueada. Elija una capa desbloqueada para el resultado."))
  (if (not mccolind-cerrada) (mccolind:elegir-interior))
  (if mccolind-cerrada
    (princ "\nFuente cerrada: la franja y las etiquetas se ubican por orientación del contorno.")
    (princ "\nFuente abierta: el interior es el lado indicado con el clic."))
  (setq mccolind-descripcion-fuente
        (strcat "Fuente: " (if mccolind-cerrada "cerrada" "abierta") " de "
                (itoa (length mccolind-puntos)) " vértices; longitud "
                (rtos mccolind-total 2 3) " m; interior a la "
                (if (> mccolind-lado-canonico 0) "izquierda" "derecha")
                " del sentido almacenado."))
  (princ (strcat "\n" mccolind-descripcion-fuente))

  ;; -------- diálogo --------
  (setq mccolind-ruta (vl-filename-mktemp "mccolind" nil ".dcl"))
  (if (not (mccolind:escribir-dcl mccolind-ruta))
    (mccolind:fallar "No se pudo escribir el DCL temporal."))
  (setq mccolind-id (load_dialog mccolind-ruta))
  (if (< mccolind-id 0) (mccolind:fallar "No se pudo cargar el DCL temporal."))
  ;; Sin marca de deshacer no se puede prometer un UNDO único: se aborta
  ;; antes de crear cualquier entidad.
  (setq r (vl-catch-all-apply 'vla-StartUndoMark (list mccolind-doc)))
  (if (vl-catch-all-error-p r)
    (mccolind:fallar "No se pudo iniciar la marca de deshacer; se cancela la ejecución para no prometer un solo UNDO.")
    (setq mccolind-undo T))

  (setq continuar T estado 0)
  (while continuar
    (if (not (new_dialog "mccolind_dlg" mccolind-id))
      (mccolind:fallar "No se encontró la definición del diálogo MCCOLIND."))
    (mccolind:cargar-dlg)
    (action_tile "automatico" "(mccolind:guardar-dlg) (mccolind:actualizar-dlg)")
    (action_tile "estilo" "(mccolind:guardar-dlg) (mccolind:actualizar-dlg)")
    (action_tile "escala" "(mccolind:guardar-dlg) (mccolind:actualizar-dlg)")
    (action_tile "texto" "(mccolind:guardar-dlg) (mccolind:actualizar-dlg)")
    (action_tile "repeticion" "(mccolind:guardar-dlg) (mccolind:actualizar-dlg)")
    (action_tile "franja" "(mccolind:guardar-dlg) (mccolind:actualizar-dlg)")
    (action_tile "separacion" "(mccolind:guardar-dlg) (mccolind:actualizar-dlg)")
    (action_tile "aplicar"
      "(mccolind:guardar-dlg) (if (setq aviso (mccolind:validar-campos)) (alert aviso) (done_dialog 2))")
    (action_tile "deshacer" "(mccolind:guardar-dlg) (done_dialog 3)")
    (action_tile "accept" "(mccolind:guardar-dlg) (done_dialog 1)")
    (action_tile "cancel" "(done_dialog 0)")
    (setq estado (start_dialog))
    (cond
      ((= estado 2) (mccolind:flujo-aplicar))
      ((= estado 3) (mccolind:deshacer-ultima))
      ((= estado 1)
       (if (or mccolind-sesion (> mccolind-aplicaciones 0))
         (setq continuar nil mccolind-completado T)
         (alert (strcat "Todavía no se aplicó ningún estilo.\n"
                        "Use «Aplicar a dos puntos...» o «Cancelar» para descartar."))))
      (T (setq continuar nil)))
    (if mccolind-abortado (setq continuar nil)))

  (mccolind:limpiar)
  (if mccolind-completado
    (progn
      ;; Se informa el número de aplicaciones RETENIDAS, no el contador
      ;; acumulado: «Deshacer última aplicación» puede haber retirado
      ;; algunas antes de aceptar.
      (princ (strcat "\nMCCOLIND: ejecución aceptada con "
                     (itoa (length mccolind-sesion))
                     " aplicación(es) retenida(s)."))
      (if mccolind-undo-fallo
        (princ " AutoCAD no cerró la marca de deshacer; el UNDO único no está garantizado.")
        (princ " Un solo UNDO retira este resultado; la fuente quedó intacta.")))
    (if (> mccolind-vivos 0)
      (princ (strcat "\nMCCOLIND: ejecución descartada, pero AutoCAD no retiró "
                     (itoa mccolind-vivos)
                     " entidad(es); revíselas en el dibujo y bórrelas manualmente si procede."))
      (princ "\nMCCOLIND: no se conservó ningún resultado de esta ejecución.")))
  (princ))

(princ "\nMCCOLIND cargado. Escriba MCCOLIND para iniciar.")
(princ)
