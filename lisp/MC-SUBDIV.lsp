;;; ============================================================
;;; MC-SUBDIV — subdivisión por área, porcentaje o partes iguales
;;; AutoCAD Windows con ActiveX. Dibujo en metros, orientaciones WCS.
;;; LWPOLYLINE horizontal +Z, sin arcos; abiertas mediante copia cerrada.
;;; Cortes paralelos o abanico por área con ancla fija en un vértice.
;;; La fuente nunca se modifica. Las mejoras requieren prueba en AutoCAD.
;;; ============================================================
(vl-load-com)

;;; Las variables mcsdiv-* se enlazan localmente en C:MCSUBDIV.
;;; Los ayudantes comparten ese contexto por ámbito dinámico de AutoLISP.
(defun mcsdiv:fallar (msg)
  (setq mcsdiv-msg msg)
  (exit))

(defun mcsdiv:sumar (a b) (mapcar '+ a b))
(defun mcsdiv:restar (a b) (mapcar '- a b))
(defun mcsdiv:escalar (a k) (mapcar '(lambda (v) (* v k)) a))
(defun mcsdiv:dot (a b) (+ (* (car a) (car b)) (* (cadr a) (cadr b))))
(defun mcsdiv:cruz (a b) (- (* (car a) (cadr b)) (* (cadr a) (car b))))
(defun mcsdiv:xy (p) (list (car p) (cadr p)))
(defun mcsdiv:local (p)
  (mcsdiv:restar (mcsdiv:xy p) (mcsdiv:xy mcsdiv-origen)))
(defun mcsdiv:wcs (p)
  (list (+ (car p) (car mcsdiv-origen))
        (+ (cadr p) (cadr mcsdiv-origen)) (caddr mcsdiv-origen)))

(defun mcsdiv:aristas (pts)
  (mapcar 'list pts (append (cdr pts) (list (car pts)))))

(defun mcsdiv:area-firmada (pts / suma ar)
  (setq suma 0.0)
  (foreach ar (mcsdiv:aristas pts)
    (setq suma (+ suma (mcsdiv:cruz (car ar) (cadr ar)))))
  (/ suma 2.0))

(defun mcsdiv:en-segmento (p a b / ab ap len)
  (setq ab (mcsdiv:restar b a) ap (mcsdiv:restar p a) len (distance a b))
  (and (> len mcsdiv-eps)
       (<= (abs (mcsdiv:cruz ab ap)) (* mcsdiv-eps len))
       (>= (mcsdiv:dot ap ab) (- (* mcsdiv-eps len)))
       (<= (mcsdiv:dot ap ab) (+ (* len len) (* mcsdiv-eps len)))))

(defun mcsdiv:signo-lado (a b p / v tol)
  (setq v (mcsdiv:cruz (mcsdiv:restar b a) (mcsdiv:restar p a))
        tol (* mcsdiv-eps (distance a b)))
  (cond ((> v tol) 1) ((< v (- tol)) -1) (T 0)))

(defun mcsdiv:segmentos-tocan (a b c d / s1 s2 s3 s4)
  (setq s1 (mcsdiv:signo-lado a b c) s2 (mcsdiv:signo-lado a b d)
        s3 (mcsdiv:signo-lado c d a) s4 (mcsdiv:signo-lado c d b))
  (or (and (< (* s1 s2) 0) (< (* s3 s4) 0))
      (mcsdiv:en-segmento c a b) (mcsdiv:en-segmento d a b)
      (mcsdiv:en-segmento a c d) (mcsdiv:en-segmento b c d)))

(defun mcsdiv:validar-simple (pts / ars num i j a b anterior siguiente)
  (setq ars (mcsdiv:aristas pts) num (length ars) i 0)
  (if (< num 3) (mcsdiv:fallar "El contorno requiere al menos tres vértices."))
  (foreach a ars
    (if (<= (distance (car a) (cadr a)) mcsdiv-eps)
      (mcsdiv:fallar "El contorno tiene vértices consecutivos coincidentes.")))
  (while (< i num)
    ;; También se rechaza una arista que retrocede sobre su vecina.
    (setq anterior (nth (rem (+ i num -1) num) pts)
          a (nth i pts) siguiente (nth (rem (1+ i) num) pts))
    (if (and (= 0 (mcsdiv:signo-lado anterior a siguiente))
             (< (mcsdiv:dot (mcsdiv:restar a anterior)
                            (mcsdiv:restar siguiente a)) 0.0))
      (mcsdiv:fallar "El contorno tiene aristas superpuestas."))
    (setq j (1+ i) a (nth i ars))
    (while (< j num)
      (if (and (/= j (1+ i)) (not (and (= i 0) (= j (1- num)))))
        (progn
          (setq b (nth j ars))
          (if (mcsdiv:segmentos-tocan (car a) (cadr a) (car b) (cadr b))
            (mcsdiv:fallar "El contorno se cruza o se toca a sí mismo."))))
      (setq j (1+ j)))
    (setq i (1+ i)))
  (if (<= (abs (mcsdiv:area-firmada pts)) (* mcsdiv-eps mcsdiv-eps))
    (mcsdiv:fallar "La superficie del contorno es nula o degenerada."))
  T)

(defun mcsdiv:leer-fuente (ent / ed normal elev pts par xs ys span)
  (setq ed (entget ent))
  (if (/= (cdr (assoc 0 ed)) "LWPOLYLINE")
    (mcsdiv:fallar "Seleccione una LWPOLYLINE; no se admite POLYLINE 3D ni antigua."))
  (setq mcsdiv-abierta (= 0 (logand 1 (cdr (assoc 70 ed)))))
  (setq normal (if (assoc 210 ed) (cdr (assoc 210 ed)) '(0.0 0.0 1.0)))
  (if (not (equal normal '(0.0 0.0 1.0) 1e-10))
    (mcsdiv:fallar "Solo se admiten contornos horizontales con normal +Z."))
  (foreach par ed
    (if (and (= (car par) 42) (/= (cdr par) 0.0))
      (mcsdiv:fallar "Esta versión no admite arcos (bulge). No se sustituyen por cuerdas.")))
  (setq elev (if (assoc 38 ed) (cdr (assoc 38 ed)) 0.0) pts nil)
  (foreach par ed
    (if (= (car par) 10)
      (setq pts (cons (trans (list (cadr par) (caddr par) elev) ent 0) pts))))
  (setq pts (reverse pts))
  (if (< (length pts) 3) (mcsdiv:fallar "El contorno requiere al menos tres vértices."))
  (setq mcsdiv-origen (car pts)
        mcsdiv-vertices pts
        mcsdiv-puntos (mapcar 'mcsdiv:local pts)
        xs (mapcar 'car mcsdiv-puntos) ys (mapcar 'cadr mcsdiv-puntos)
        span (max (- (apply 'max xs) (apply 'min xs))
                  (- (apply 'max ys) (apply 'min ys)))
        mcsdiv-eps (max 1e-8 (* span 1e-10)))
  ;; Cierre geométrico: retirar solo la copia del extremo duplicado.
  ;; No fusionar vértices ni introducir una tolerancia de área en metros.
  ;; En AutoLISP, last devuelve el punto completo; car extraería solo su X.
  (if (and mcsdiv-abierta
           (<= (distance (car pts) (last pts)) mcsdiv-eps))
    (setq mcsdiv-vertices (reverse (cdr (reverse pts)))
          mcsdiv-puntos (mapcar 'mcsdiv:local mcsdiv-vertices)))
  (mcsdiv:validar-simple mcsdiv-puntos)
  (if mcsdiv-abierta
    (princ "\nFuente abierta: se trabajará con una copia cerrada; la original se conserva."))
  (setq mcsdiv-total (abs (mcsdiv:area-firmada mcsdiv-puntos))
        mcsdiv-espacio (vlax-ename->vla-object (cdr (assoc 330 ed))))
  T)

;;; Número decimal completo; nunca usar atof sin validar el texto.
;;; Se aceptan signo y punto decimal, no comas ni notación científica.
(defun mcsdiv:numero (txt / s i c digitos punto valido)
  (setq s (vl-string-trim " \t" (if txt txt ""))
        i 1 digitos 0 punto nil valido T)
  (if (member (substr s 1 1) '("+" "-")) (setq i 2))
  (while (and valido (<= i (strlen s)))
    (setq c (substr s i 1))
    (cond
      ((and (>= (ascii c) 48) (<= (ascii c) 57)) (setq digitos (1+ digitos)))
      ((and (= c ".") (not punto)) (setq punto T))
      (T (setq valido nil)))
    (setq i (1+ i)))
  (if (and valido (> digitos 0)) (distof s 2) nil))

(defun mcsdiv:lista-com (v)
  (if (eq (type v) 'VARIANT) (setq v (vlax-variant-value v)))
  (if (eq (type v) 'SAFEARRAY) (vlax-safearray->list v) v))

(defun mcsdiv:dobles (valores / arr)
  (setq arr (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length valores)))))
  (vlax-safearray-fill arr valores)
  arr)

(defun mcsdiv:temporal (obj)
  (setq mcsdiv-temporales (cons obj mcsdiv-temporales))
  obj)

(defun mcsdiv:salida (obj)
  (setq mcsdiv-salidas (cons obj mcsdiv-salidas))
  obj)

(defun mcsdiv:borrar (obj / r)
  ;; Un operando puede haber sido consumido por Boolean.
  (setq r (vl-catch-all-apply
    '(lambda ()
       (if (and (not (vlax-object-released-p obj)) (not (vlax-erased-p obj)))
         (vla-Delete obj))) nil))
  (not (vl-catch-all-error-p r)))

(defun mcsdiv:retirar (obj)
  (if (not (mcsdiv:borrar obj))
    (mcsdiv:fallar "No se pudo eliminar una entidad temporal; se intenta revertir la ejecución."))
  (setq mcsdiv-temporales (vl-remove obj mcsdiv-temporales)))

(defun mcsdiv:polilinea (pts temporal / obj)
  (setq obj (vla-AddLightWeightPolyline mcsdiv-espacio
              (mcsdiv:dobles (apply 'append (mapcar 'mcsdiv:xy pts)))))
  ;; Registrar antes de cualquier modificación susceptible de fallar.
  (if temporal (mcsdiv:temporal obj) (mcsdiv:salida obj))
  (vla-put-Closed obj :vlax-true)
  (vla-put-Layer obj mcsdiv-capa)
  (vla-put-Elevation obj (if temporal 0.0 (caddr mcsdiv-origen)))
  (if temporal (vla-put-Visible obj :vlax-false))
  obj)

(defun mcsdiv:region (pts / poly arr regs reg)
  (setq poly (mcsdiv:polilinea pts T)
        arr (vlax-make-safearray vlax-vbObject '(0 . 0)))
  (vlax-safearray-put-element arr 0 poly)
  (setq regs (mcsdiv:lista-com (vla-AddRegion mcsdiv-espacio arr)))
  (foreach reg regs (mcsdiv:temporal reg))
  (mcsdiv:retirar poly)
  (if (/= (length regs) 1)
    (mcsdiv:fallar "AutoCAD no pudo formar una única región válida del contorno."))
  (setq reg (car regs))
  (vla-put-Visible reg :vlax-false)
  reg)

(defun mcsdiv:tramos-region (reg / objs obj tramos a b)
  (setq objs (mcsdiv:lista-com (vla-Explode reg)) tramos nil)
  ;; Registrar todo el array antes de inspeccionar el primer elemento.
  (foreach obj objs (mcsdiv:temporal obj))
  (foreach obj objs
    (if (/= (vla-get-ObjectName obj) "AcDbLine")
      (mcsdiv:fallar "La región produjo curvas no soportadas; no se aproxima su frontera."))
    (setq a (mcsdiv:xy (mcsdiv:lista-com (vla-get-StartPoint obj)))
          b (mcsdiv:xy (mcsdiv:lista-com (vla-get-EndPoint obj))))
    (if (<= (distance a b) mcsdiv-eps)
      (mcsdiv:fallar "La región produjo un tramo degenerado."))
    (setq tramos (cons (list a b) tramos)))
  (foreach obj objs (mcsdiv:retirar obj))
  (if (null tramos) (mcsdiv:fallar "La región resultante no tiene frontera."))
  tramos)

(defun mcsdiv:marco (u normal / us ns margen)
  (setq us (mapcar '(lambda (p) (mcsdiv:dot p u)) mcsdiv-puntos)
        ns (mapcar '(lambda (p) (mcsdiv:dot p normal)) mcsdiv-puntos)
        mcsdiv-umin (apply 'min us) mcsdiv-umax (apply 'max us)
        mcsdiv-nmin (apply 'min ns) mcsdiv-nmax (apply 'max ns)
        margen (max 1.0 (* 0.1 (max (- mcsdiv-umax mcsdiv-umin)
                                      (- mcsdiv-nmax mcsdiv-nmin)))))
  (setq mcsdiv-umin (- mcsdiv-umin margen)
        mcsdiv-umax (+ mcsdiv-umax margen)
        mcsdiv-inferior (- mcsdiv-nmin margen)
        mcsdiv-superior (+ mcsdiv-nmax margen)))

(defun mcsdiv:desde-marco (x y)
  (mcsdiv:sumar (mcsdiv:escalar mcsdiv-u x) (mcsdiv:escalar mcsdiv-normal y)))

(defun mcsdiv:recortar (inferior superior / reg mascara area tramos ar p proy)
  (if (<= (- superior inferior) mcsdiv-eps)
    (mcsdiv:fallar "La separación de los cortes es menor que la tolerancia geométrica."))
  (setq reg (mcsdiv:temporal (vla-Copy mcsdiv-base))
        mascara (mcsdiv:region
          (list (mcsdiv:desde-marco mcsdiv-umin inferior)
                (mcsdiv:desde-marco mcsdiv-umax inferior)
                (mcsdiv:desde-marco mcsdiv-umax superior)
                (mcsdiv:desde-marco mcsdiv-umin superior))))
  (vla-Boolean reg acIntersection mascara)
  (mcsdiv:retirar mascara)
  (setq area (vla-get-Area reg) tramos (mcsdiv:tramos-region reg))
  ;; Boolean sin intersección puede dejar REG intacta. Comprobar la
  ;; frontera efectiva, no inferir éxito de un retorno sin excepción.
  (foreach ar tramos
    (foreach p ar
      (setq proy (mcsdiv:dot p mcsdiv-normal))
      (if (or (< proy (- inferior (* 10.0 mcsdiv-eps)))
              (> proy (+ superior (* 10.0 mcsdiv-eps))))
        (mcsdiv:fallar "AutoCAD no produjo la intersección esperada; se revierte la operación."))))
  (if (or (<= area (* mcsdiv-eps mcsdiv-eps))
          (> area (+ mcsdiv-total mcsdiv-tol-area)))
    (mcsdiv:fallar "La intersección produjo una superficie inválida."))
  (list reg area tramos))

(defun mcsdiv:area-acumulada (pos / r area)
  (cond
    ((<= pos mcsdiv-nmin) 0.0)
    ((>= pos mcsdiv-nmax) mcsdiv-total)
    (T
      (setq r (mcsdiv:recortar mcsdiv-inferior pos) area (cadr r))
      (mcsdiv:retirar (car r))
      area)))

(defun mcsdiv:resolver (objetivo / bajo alto medio area iter listo)
  (setq bajo mcsdiv-nmin alto mcsdiv-nmax iter 0 listo nil)
  (while (and (< iter 80) (not listo))
    (setq medio (/ (+ bajo alto) 2.0)
          area (mcsdiv:area-acumulada medio)
          listo (<= (abs (- area objetivo)) (/ mcsdiv-tol-area 4.0)))
    (if (not listo)
      (if (< area objetivo) (setq bajo medio) (setq alto medio)))
    (setq iter (1+ iter)))
  (if (not listo)
    (mcsdiv:fallar "No se alcanzó la superficie solicitada dentro de la tolerancia (80 iteraciones)."))
  medio)

(defun mcsdiv:un-contorno (tramos / resto primero inicio actual pts candidatos ar elegido)
  (setq primero (car tramos) resto (cdr tramos)
        inicio (car primero) actual (cadr primero) pts (list inicio actual))
  (while (and resto (> (distance actual inicio) mcsdiv-eps))
    (setq candidatos nil)
    (foreach ar resto
      (cond
        ((<= (distance actual (car ar)) mcsdiv-eps)
         (setq candidatos (cons (list ar (cadr ar)) candidatos)))
        ((<= (distance actual (cadr ar)) mcsdiv-eps)
         (setq candidatos (cons (list ar (car ar)) candidatos)))))
    (if (/= (length candidatos) 1)
      (mcsdiv:fallar "La frontera está abierta o se ramifica; pruebe otra dirección de corte."))
    (setq elegido (car candidatos)
          resto (vl-remove (car elegido) resto) actual (cadr elegido))
    (if (> (distance actual inicio) mcsdiv-eps)
      (setq pts (append pts (list actual)))))
  (if (> (distance actual inicio) mcsdiv-eps)
    (mcsdiv:fallar "No se pudo cerrar el contorno de una parcela."))
  (if resto
    (mcsdiv:fallar "La dirección elegida genera una parcela con fragmentos separados. No se creó ninguna subdivisión."))
  (mcsdiv:validar-simple pts)
  pts)

(defun mcsdiv:parcelas (objetivos / cortes limites limite anterior r pts area centro salida suma esperado)
  (setq cortes nil salida nil suma 0.0)
  (foreach esperado objetivos
    (setq cortes (append cortes (list (mcsdiv:resolver esperado)))))
  (setq limites (append cortes (list mcsdiv-superior)) anterior mcsdiv-inferior
        objetivos (append objetivos (list mcsdiv-total)) esperado 0.0)
  (foreach limite limites
    (setq r (mcsdiv:recortar anterior limite)
          pts (mcsdiv:un-contorno (caddr r)) area (cadr r))
    (if (> (abs (- area (- (car objetivos) esperado))) mcsdiv-tol-area)
      (mcsdiv:fallar "Una parcela no cumple la tolerancia de área; no se publican resultados."))
    (if (> (abs (- (abs (mcsdiv:area-firmada pts)) area)) mcsdiv-tol-area)
      (mcsdiv:fallar "El contorno reconstruido no conserva el área de la región."))
    (setq centro (mcsdiv:lista-com (vla-get-Centroid (car r))))
    (setq salida (append salida (list (list pts area centro)))
          suma (+ suma area) anterior limite
          esperado (car objetivos) objetivos (cdr objetivos))
    (mcsdiv:retirar (car r)))
  (if (> (abs (- suma mcsdiv-total)) mcsdiv-tol-area)
    (mcsdiv:fallar "Las parcelas no conservan la superficie total del polígono."))
  (list cortes salida))

;;; ============================================================
;;; ANCLAJE: cuerdas interiores desde un vértice fijo
;;; El área de cada prefijo de frontera es afín dentro de cada arista.
;;; No se supone monotonicidad global del área respecto del ángulo.
;;; ============================================================
(defun mcsdiv:limpiar-anillo (pts / salida p)
  (setq salida nil)
  (foreach p pts
    (if (or (null salida) (> (distance p (car salida)) mcsdiv-eps))
      (setq salida (cons p salida))))
  (setq salida (reverse salida))
  ;; Comparar puntos completos: last ya devuelve el último punto.
  (if (and (> (length salida) 1)
           (<= (distance (car salida) (last salida)) mcsdiv-eps))
    (setq salida (reverse (cdr (reverse salida)))))
  salida)

(defun mcsdiv:orden-desde-ancla (pts / indice)
  ;; Reordenar la lista, nunca rotar ni redondear las coordenadas.
  (setq indice (mcsdiv:indice-vertice mcsdiv-ancla pts))
  (while (> indice 0)
    (setq pts (append (cdr pts) (list (car pts))) indice (1- indice)))
  pts)

(defun mcsdiv:cuerda-interior (p / valido ar a b d len2 ua ub)
  (setq valido T d (mcsdiv:restar p mcsdiv-ancla)
        len2 (mcsdiv:dot d d))
  (if (<= len2 (* mcsdiv-eps mcsdiv-eps))
    nil
    (progn
      (foreach ar (mcsdiv:aristas mcsdiv-puntos)
        (setq a (car ar) b (cadr ar))
        (if (mcsdiv:segmentos-tocan mcsdiv-ancla p a b)
          (cond
            ;; Rechazar solape con frontera, incluso en aristas del ancla.
            ((and (= 0 (mcsdiv:signo-lado mcsdiv-ancla p a))
                  (= 0 (mcsdiv:signo-lado mcsdiv-ancla p b)))
              (setq ua (/ (mcsdiv:dot (mcsdiv:restar a mcsdiv-ancla) d) len2)
                    ub (/ (mcsdiv:dot (mcsdiv:restar b mcsdiv-ancla) d) len2))
              (if (> (- (min 1.0 (max ua ub)) (max 0.0 (min ua ub)))
                     (/ mcsdiv-eps (sqrt len2)))
                (setq valido nil)))
            ;; Solo se admiten contactos en los dos extremos de la cuerda.
            ;; Cualquier salida/reentrada o contacto intermedio la invalida.
            ((not (or (mcsdiv:en-segmento mcsdiv-ancla a b)
                      (mcsdiv:en-segmento p a b)))
              (setq valido nil)))))
      (and valido
           (mcsdiv:punto-dentro
             (mcsdiv:escalar (mcsdiv:sumar mcsdiv-ancla p) 0.5) mcsdiv-puntos)))))

(defun mcsdiv:lado-anclado (p signo / d normal)
  (if (= (mcsdiv:opcion "metodo") "0")
    T
    (progn
      (setq d (mcsdiv:restar p mcsdiv-ancla)
            normal (mcsdiv:escalar (list (cadr d) (- (car d)))
                     (/ signo (distance p mcsdiv-ancla))))
      (> (mcsdiv:dot normal (mcsdiv:vector-lado)) 1e-8))))

(defun mcsdiv:buscar-cuerda (pts objetivo anterior / signo acumulado i a b delta f margen p hallado)
  (setq signo (if (> (mcsdiv:area-firmada pts) 0.0) 1.0 -1.0)
        acumulado 0.0 i 1 hallado nil)
  (while (and (< i (1- (length pts))) (null hallado))
    (setq a (nth i pts) b (nth (1+ i) pts)
          delta (* signo 0.5 (mcsdiv:cruz (mcsdiv:restar a mcsdiv-ancla)
                                        (mcsdiv:restar b mcsdiv-ancla))))
    (if (> (abs delta) (* mcsdiv-eps mcsdiv-eps))
      (progn
        (setq f (/ (- objetivo acumulado) delta)
              margen (/ mcsdiv-eps (distance a b)))
        (if (and (>= f (- margen)) (<= f (+ 1.0 margen)))
          (progn
            (setq f (max 0.0 (min 1.0 f))
                  p (mcsdiv:sumar a (mcsdiv:escalar (mcsdiv:restar b a) f)))
            (if (and (> (+ i f) (+ anterior 1e-10))
                     (mcsdiv:cuerda-interior p) (mcsdiv:lado-anclado p signo))
              (setq hallado (list i f p)))))))
    (setq acumulado (+ acumulado delta) i (1+ i)))
  hallado)

(defun mcsdiv:buscar-abanico (pts objetivos / cortes anterior valido objetivo corte)
  (setq cortes nil anterior 0.0 valido T)
  (foreach objetivo objetivos
    (if valido
      (progn
        (setq corte (mcsdiv:buscar-cuerda pts objetivo anterior))
        (if corte
          (setq cortes (append cortes (list corte)) anterior (+ (car corte) (cadr corte)))
          (setq valido nil)))))
  (if valido cortes nil))

(defun mcsdiv:trozo-abanico (pts anterior corte / trozo i)
  (setq trozo (list mcsdiv-ancla (caddr anterior)) i (1+ (car anterior)))
  (while (<= i (car corte))
    (setq trozo (append trozo (list (nth i pts))) i (1+ i)))
  (mcsdiv:limpiar-anillo (append trozo (list (caddr corte)))))

(defun mcsdiv:parcela-anclada (pts objetivo / reg area contorno centro)
  (mcsdiv:validar-simple pts)
  (setq reg (mcsdiv:region pts) area (vla-get-Area reg)
        contorno (mcsdiv:un-contorno (mcsdiv:tramos-region reg)))
  (if (or (> (abs (- area objetivo)) mcsdiv-tol-area)
          (> (abs (- (abs (mcsdiv:area-firmada contorno)) area)) mcsdiv-tol-area))
    (mcsdiv:fallar "Una parcela anclada no conserva la superficie solicitada."))
  (setq centro (mcsdiv:lista-com (vla-get-Centroid reg)))
  (mcsdiv:retirar reg)
  (list contorno area centro))

(defun mcsdiv:parcelas-ancladas (objetivos / indice pts cortes anterior limites corte acumulado parcela salida suma)
  (setq indice (mcsdiv:indice-vertice (mcsdiv:ancla-elegida) mcsdiv-vertices)
        mcsdiv-ancla (nth indice mcsdiv-puntos)
        pts mcsdiv-puntos)
  (if (< (mcsdiv:area-firmada pts) 0.0) (setq pts (reverse pts)))
  (setq pts (mcsdiv:orden-desde-ancla pts)
        cortes (mcsdiv:buscar-abanico pts objetivos))
  (if (null cortes)
    (setq pts (mcsdiv:orden-desde-ancla (reverse pts))
          cortes (mcsdiv:buscar-abanico pts objetivos)))
  (if (null cortes)
    (mcsdiv:fallar "No se encontró un abanico interior conectado con este ancla y lado. Elija otro vértice o el modo paralelo."))
  (setq anterior (list 0 0.0 mcsdiv-ancla) acumulado 0.0 salida nil suma 0.0
        limites (append cortes (list (list (1- (length pts)) 1.0 mcsdiv-ancla)))
        objetivos (append objetivos (list mcsdiv-total)))
  (foreach corte limites
    (setq parcela (mcsdiv:parcela-anclada (mcsdiv:trozo-abanico pts anterior corte)
                                        (- (car objetivos) acumulado))
          salida (append salida (list parcela)) suma (+ suma (cadr parcela))
          anterior corte acumulado (car objetivos) objetivos (cdr objetivos)))
  (if (> (abs (- suma mcsdiv-total)) mcsdiv-tol-area)
    (mcsdiv:fallar "El abanico no conserva la superficie total; no se publican resultados."))
  (list (mapcar 'caddr cortes) salida))

;;; ============================================================
;;; DIÁLOGO: estado crudo preservado al volver al dibujo
;;; ============================================================
(defun mcsdiv:opcion (clave) (cdr (assoc clave mcsdiv-opciones)))
(defun mcsdiv:anclado-p () (= (mcsdiv:opcion "corte") "1"))
(defun mcsdiv:indice-vertice (p pts / indice encontrado q)
  (setq indice 0 encontrado nil)
  (foreach q pts
    (if (<= (distance (mcsdiv:xy p) (mcsdiv:xy q)) mcsdiv-eps)
      (setq encontrado indice))
    (setq indice (1+ indice)))
  encontrado)
(defun mcsdiv:ancla-elegida ()
  (if mcsdiv-guia (nth (atoi (mcsdiv:opcion "ancla")) mcsdiv-guia)))
(defun mcsdiv:fijar-opcion (clave valor)
  (setq mcsdiv-opciones
    (subst (cons clave valor) (assoc clave mcsdiv-opciones) mcsdiv-opciones)))

(defun mcsdiv:guardar-dlg (/ clave)
  (foreach clave '("metodo" "partes" "area" "porcentaje" "guia_modo"
                   "corte" "ancla" "rotar" "angulo" "lado" "altura" "precision" "tolerancia")
    (mcsdiv:fijar-opcion clave (get_tile clave))))

(defun mcsdiv:actualizar-dlg (/ partes rotacion)
  (setq partes (= (mcsdiv:opcion "metodo") "0")
        rotacion (and (not (mcsdiv:anclado-p)) (= (mcsdiv:opcion "rotar") "1")))
  (mode_tile "partes" (if partes 0 1))
  (mode_tile "area" (if (= (mcsdiv:opcion "metodo") "1") 0 1))
  (mode_tile "porcentaje" (if (= (mcsdiv:opcion "metodo") "2") 0 1))
  (mode_tile "lado" (if partes 1 0))
  (mode_tile "ancla" (if (mcsdiv:anclado-p) 0 1))
  (mode_tile "rotar" (if (mcsdiv:anclado-p) 1 0))
  (mode_tile "angulo" (if rotacion 0 1))
  (mode_tile "pivote" (if (and rotacion mcsdiv-guia) 0 1))
  (set_tile "estado_guia"
    (if mcsdiv-guia "Dirección definida (se ajustará por superficie)." "Falta definir la dirección de corte."))
  (set_tile "estado_pivote"
    (if mcsdiv-pivote "Pivote seleccionado." "Sin pivote.")))

(defun mcsdiv:escribir-dcl (ruta / linea)
  (setq mcsdiv-archivo (open ruta "w"))
  (if (null mcsdiv-archivo) (mcsdiv:fallar "No se pudo escribir el DCL temporal."))
  (foreach linea
    '("mcsdiv_dlg : dialog { label = \"MCSUBDIV - Subdividir por superficie\";"
      " : text { key = \"total\"; width = 58; }"
      " : boxed_column { label = \"Método\";"
      "  : popup_list { key = \"metodo\"; label = \"Subdividir por:\"; edit_width = 25; }"
      "  : edit_box { key = \"partes\"; label = \"Número de partes iguales:\"; edit_width = 18; }"
      "  : edit_box { key = \"area\"; label = \"Área objetivo (m2):\"; edit_width = 18; }"
      "  : edit_box { key = \"porcentaje\"; label = \"Porcentaje del área original:\"; edit_width = 18; }"
      " }"
      " : boxed_column { label = \"Dirección de corte\";"
      "  : popup_list { key = \"guia_modo\"; label = \"Definir mediante:\"; edit_width = 25; }"
      "  : button { key = \"guia\"; label = \"Definir dirección...\"; }"
      "  : text { key = \"estado_guia\"; width = 58; }"
      "  : popup_list { key = \"corte\"; label = \"Tipo de corte:\"; edit_width = 25; }"
      "  : popup_list { key = \"ancla\"; label = \"Vértice fijo de la guía:\"; edit_width = 25; }"
      "  : toggle { key = \"rotar\"; label = \"Rotar la guía antes de calcular los cortes\"; }"
      "  : edit_box { key = \"angulo\"; label = \"Ángulo relativo (grados, + antihorario):\"; edit_width = 12; }"
      "  : row { : button { key = \"pivote\"; label = \"Seleccionar pivote...\"; }"
      "          : text { key = \"estado_pivote\"; width = 25; } }"
      " }"
      " : boxed_column { label = \"Ubicación del área o porcentaje objetivo\";"
      "  : popup_list { key = \"lado\"; label = \"Lado (WCS):\"; edit_width = 25; }"
      "  : text { label = \"Paralelo: trasladar. Anclado: girar con vértice fijo.\"; }"
      " }"
      " : boxed_column { label = \"Precisión y etiquetas\";"
      "  : edit_box { key = \"tolerancia\"; label = \"Tolerancia de área (m2):\"; edit_width = 18; }"
      "  : edit_box { key = \"altura\"; label = \"Altura del texto (m):\"; edit_width = 18; }"
      "  : popup_list { key = \"precision\"; label = \"Decimales de la etiqueta:\"; edit_width = 18; }"
      " }"
      " : text { label = \"Solo parcelas conectadas. La fuente se conserva.\"; }"
      " : row { : button { key = \"accept\"; label = \"Subdividir\"; is_default = true; }"
      "          : button { key = \"cancel\"; label = \"Cancelar\"; is_cancel = true; } }"
      "}")
    (write-line linea mcsdiv-archivo))
  (close mcsdiv-archivo)
  (setq mcsdiv-archivo nil))

(defun mcsdiv:llenar-lista (clave valores)
  (start_list clave)
  (mapcar 'add_list valores)
  (end_list))

(defun mcsdiv:rotar-punto (p pivote ang / d cs sn)
  (setq d (mcsdiv:restar (mcsdiv:xy p) (mcsdiv:xy pivote))
        cs (cos ang) sn (sin ang))
  (list (+ (car pivote) (- (* (car d) cs) (* (cadr d) sn)))
        (+ (cadr pivote) (+ (* (car d) sn) (* (cadr d) cs)))
        (caddr mcsdiv-origen)))

(defun mcsdiv:guia-final (/ ang)
  (if (and (not (mcsdiv:anclado-p)) (= (mcsdiv:opcion "rotar") "1"))
    (progn
      (setq ang (* pi (/ (mcsdiv:numero (mcsdiv:opcion "angulo")) 180.0)))
      (mapcar '(lambda (p) (mcsdiv:rotar-punto p mcsdiv-pivote ang)) mcsdiv-guia))
    mcsdiv-guia))

(defun mcsdiv:direccion-guia (/ guia v len)
  (setq guia (mcsdiv:guia-final)
        v (mcsdiv:restar (mcsdiv:xy (cadr guia)) (mcsdiv:xy (car guia)))
        len (distance '(0.0 0.0) v))
  (if (<= len mcsdiv-eps) nil (mcsdiv:escalar v (/ 1.0 len))))

(defun mcsdiv:vector-lado ()
  (nth (atoi (mcsdiv:opcion "lado"))
    '((0.0 1.0) (0.0 -1.0) (1.0 0.0) (-1.0 0.0)
      (1.0 1.0) (-1.0 1.0) (1.0 -1.0) (-1.0 -1.0))))

(defun mcsdiv:validar-opciones (/ metodo valor tol altura ang u normal)
  (setq metodo (mcsdiv:opcion "metodo")
        valor (mcsdiv:numero (mcsdiv:opcion
                (cond ((= metodo "0") "partes") ((= metodo "1") "area") (T "porcentaje"))))
        tol (mcsdiv:numero (mcsdiv:opcion "tolerancia"))
        altura (mcsdiv:numero (mcsdiv:opcion "altura"))
        ang (mcsdiv:numero (mcsdiv:opcion "angulo")))
  (cond
    ((or (null tol) (<= tol 0.0)) "La tolerancia de área debe ser un número positivo (por ejemplo, 0.01).")
    ((or (null altura) (<= altura 0.0)) "La altura del texto debe ser un número positivo.")
    ((null valor) "Introduzca un número completo, sin comas ni texto sobrante (por ejemplo, 200.5).")
    ((and (= metodo "0")
          (or (< valor 2.0) (> valor 2147483647.0) (/= valor (fix valor))))
      "El número de partes debe ser un entero mayor o igual a 2.")
    ((and (= metodo "1") (or (<= valor 0.0) (>= valor mcsdiv-total)))
      "El área objetivo debe ser positiva y menor que el área total.")
    ((and (= metodo "2") (or (<= valor 0.0) (>= valor 100.0)))
      "El porcentaje debe ser mayor que 0 y menor que 100.")
    ((and (= metodo "0") (<= (/ mcsdiv-total valor) tol))
      "Cada parcela debe superar la tolerancia de área; reduzca la tolerancia o el número de partes.")
    ((and (= metodo "1") (or (<= valor tol) (<= (- mcsdiv-total valor) tol)))
      "El área objetivo y el resto deben superar la tolerancia de área.")
    ((and (= metodo "2")
          (or (<= (* mcsdiv-total (/ valor 100.0)) tol)
              (<= (* mcsdiv-total (- 1.0 (/ valor 100.0))) tol)))
      "El área objetivo y el resto deben superar la tolerancia de área.")
    ((null mcsdiv-guia) "Defina primero una dirección de corte.")
    ((and (mcsdiv:anclado-p)
          (null (mcsdiv:indice-vertice (mcsdiv:ancla-elegida) mcsdiv-vertices)))
      "El ancla debe coincidir con un vértice del contorno. Use dos vértices o dibuje la guía con ENDPOINT.")
    ((and (not (mcsdiv:anclado-p)) (= (mcsdiv:opcion "rotar") "1") (null ang))
      "El ángulo debe ser un número válido; se admiten cero y negativos.")
    ((and (not (mcsdiv:anclado-p)) (= (mcsdiv:opcion "rotar") "1") (null mcsdiv-pivote))
      "Seleccione el pivote de rotación.")
    ((null (setq u (mcsdiv:direccion-guia))) "Los puntos de la guía deben ser distintos después de rotar.")
    ((and (not (mcsdiv:anclado-p)) (/= metodo "0")
          (progn
            (setq normal (list (- (cadr u)) (car u)))
            (<= (abs (mcsdiv:dot normal (mcsdiv:vector-lado))) 1e-8)))
      "La orientación elegida es paralela a la guía. Cambie la guía, su rotación o el lado.")
    (T nil)))

(defun mcsdiv:vertice-cercano (p / mejor dist actual v)
  (setq mejor (car mcsdiv-vertices) dist (distance p mejor))
  (foreach v (cdr mcsdiv-vertices)
    (setq actual (distance p v))
    (if (< actual dist) (setq mejor v dist actual)))
  mejor)

(defun mcsdiv:capturar-guia (/ p1 p2 vertices)
  (setq vertices (= (mcsdiv:opcion "guia_modo") "1"))
  (setvar "OSMODE" (logior (cdr (assoc "OSMODE" mcsdiv-entorno)) 1))
  (setq p1 (getpoint (if vertices "\nHaga clic cerca del primer vértice de la fuente: "
                                           "\nPrimer punto de la línea guía: ")))
  (if p1
    (setq p2 (getpoint p1 (if vertices "\nHaga clic cerca de otro vértice de la fuente: "
                                                "\nSegundo punto de la línea guía: "))))
  (setvar "OSMODE" 0)
  (if (and p1 p2)
    (progn
      (setq p1 (trans p1 1 0) p2 (trans p2 1 0))
      (if vertices
        (setq p1 (mcsdiv:vertice-cercano p1) p2 (mcsdiv:vertice-cercano p2)))
      (if (<= (distance (mcsdiv:xy p1) (mcsdiv:xy p2)) mcsdiv-eps)
        (alert "Seleccione dos puntos o vértices distintos.")
        (setq mcsdiv-guia
          (list (list (car p1) (cadr p1) (caddr mcsdiv-origen))
                (list (car p2) (cadr p2) (caddr mcsdiv-origen)))
          mcsdiv-pivote nil)))))

(defun mcsdiv:dialogo (/ estado continuar clave aviso p)
  (setq mcsdiv-dcl-ruta (vl-filename-mktemp "mcsubdiv" nil ".dcl"))
  (mcsdiv:escribir-dcl mcsdiv-dcl-ruta)
  (setq mcsdiv-dcl-id (load_dialog mcsdiv-dcl-ruta))
  (if (< mcsdiv-dcl-id 0) (mcsdiv:fallar "No se pudo cargar el DCL temporal."))
  (setq continuar T estado 0)
  (while continuar
    (if (not (new_dialog "mcsdiv_dlg" mcsdiv-dcl-id))
      (mcsdiv:fallar "No se encontró la definición del diálogo MCSUBDIV."))
    (mcsdiv:llenar-lista "metodo" '("Partes iguales" "Área + resto" "Porcentaje + resto"))
    (mcsdiv:llenar-lista "guia_modo" '("Dibujar línea por dos puntos" "Seleccionar dos vértices"))
    (mcsdiv:llenar-lista "corte" '("Paralelo (trasladar)" "Anclado (girar / abanico)"))
    (mcsdiv:llenar-lista "ancla" '("Primer punto de la guía" "Segundo punto de la guía"))
    (mcsdiv:llenar-lista "lado" '("Norte" "Sur" "Este" "Oeste" "Noreste" "Noroeste" "Sureste" "Suroeste"))
    (mcsdiv:llenar-lista "precision" '("0" "1" "2" "3" "4"))
    (foreach clave mcsdiv-opciones (set_tile (car clave) (cdr clave)))
    (set_tile "total" (strcat "Área original: " (rtos mcsdiv-total 2 4) " m2"))
    (mcsdiv:actualizar-dlg)
    (action_tile "metodo" "(mcsdiv:guardar-dlg) (mcsdiv:actualizar-dlg)")
    (action_tile "rotar" "(mcsdiv:guardar-dlg) (mcsdiv:actualizar-dlg)")
    (action_tile "corte" "(mcsdiv:guardar-dlg) (mcsdiv:actualizar-dlg)")
    (action_tile "guia_modo"
      "(mcsdiv:guardar-dlg) (setq mcsdiv-guia nil mcsdiv-pivote nil) (mcsdiv:actualizar-dlg)")
    (action_tile "guia" "(mcsdiv:guardar-dlg) (done_dialog 2)")
    (action_tile "pivote" "(mcsdiv:guardar-dlg) (done_dialog 3)")
    (action_tile "accept"
      "(mcsdiv:guardar-dlg) (setq aviso (mcsdiv:validar-opciones)) (if aviso (alert aviso) (done_dialog 1))")
    (action_tile "cancel" "(done_dialog 0)")
    (setq estado (start_dialog))
    (cond
      ((= estado 2) (mcsdiv:capturar-guia))
      ((= estado 3)
        (setvar "OSMODE" (logior (cdr (assoc "OSMODE" mcsdiv-entorno)) 1))
        (setq p (getpoint "\nPivote de rotación de la guía: "))
        (setvar "OSMODE" 0)
        (if p
          (progn
            (setq p (trans p 1 0)
                  mcsdiv-pivote (list (car p) (cadr p) (caddr mcsdiv-origen))))))
      (T (setq continuar nil))))
  (unload_dialog mcsdiv-dcl-id)
  (setq mcsdiv-dcl-id nil)
  (if (not (vl-file-delete mcsdiv-dcl-ruta))
    (mcsdiv:fallar "No se pudo eliminar el DCL temporal."))
  (setq mcsdiv-dcl-ruta nil)
  (= estado 1))

;;; ============================================================
;;; PUBLICACIÓN: solo después de validar todas las parcelas
;;; ============================================================
(defun mcsdiv:punto-dentro (p pts / dentro borde ar a b x y cruce)
  (setq dentro nil borde nil x (car p) y (cadr p))
  (foreach ar (mcsdiv:aristas pts)
    (setq a (car ar) b (cadr ar))
    (if (mcsdiv:en-segmento p a b) (setq borde T))
    (if (and (<= (min (cadr a) (cadr b)) y) (< y (max (cadr a) (cadr b))))
      (progn
        (setq cruce (+ (car a) (* (- y (cadr a))
                       (/ (- (car b) (car a)) (- (cadr b) (cadr a))))))
        (if (< x cruce) (setq dentro (not dentro))))))
  (or borde dentro))

(defun mcsdiv:intervalos-corte (pts corte / ar a b valores orden unidos actual tramo)
  (setq valores nil)
  (foreach ar (mcsdiv:aristas pts)
    (if (and (<= (abs (- (mcsdiv:dot (car ar) mcsdiv-normal) corte)) (* 10.0 mcsdiv-eps))
             (<= (abs (- (mcsdiv:dot (cadr ar) mcsdiv-normal) corte)) (* 10.0 mcsdiv-eps)))
      (progn
        (setq a (mcsdiv:dot (car ar) mcsdiv-u) b (mcsdiv:dot (cadr ar) mcsdiv-u))
        (setq valores (cons (list (min a b) (max a b)) valores)))))
  (if (null valores) (mcsdiv:fallar "No se pudo reconstruir una línea divisoria."))
  (setq orden (vl-sort valores '(lambda (a b) (< (car a) (car b))))
        actual (car orden) unidos nil)
  (foreach tramo (cdr orden)
    (if (<= (car tramo) (+ (cadr actual) mcsdiv-eps))
      (setq actual (list (car actual) (max (cadr actual) (cadr tramo))))
      (setq unidos (cons actual unidos) actual tramo)))
  (reverse (cons actual unidos)))

(defun mcsdiv:publicar (resultado / cortes parcelas indice parcela obj centro texto altura precision corte tramo pts)
  (setq cortes (car resultado) parcelas (cadr resultado) indice 1
        altura (mcsdiv:numero (mcsdiv:opcion "altura"))
        precision (atoi (mcsdiv:opcion "precision")))
  (foreach parcela parcelas
    (setq pts (car parcela) centro (caddr parcela))
    (mcsdiv:polilinea (mapcar 'mcsdiv:wcs pts) nil)
    (setq texto (strcat "Lote " (itoa indice) "\\PÁrea: "
                       (rtos (cadr parcela) 2 precision) " m\\U+00B2")
          obj (mcsdiv:salida (vla-AddMText mcsdiv-espacio
                (vlax-3d-point (mcsdiv:wcs centro)) 0.0 texto)))
    (vla-put-Layer obj mcsdiv-capa)
    (vla-put-StyleName obj mcsdiv-estilo)
    (vla-put-Height obj altura)
    (vla-put-AttachmentPoint obj acAttachmentPointMiddleCenter)
    (vla-put-InsertionPoint obj (vlax-3d-point (mcsdiv:wcs centro)))
    (if (not (mcsdiv:punto-dentro centro pts))
      (princ (strcat "\nAviso: el centroide real del lote " (itoa indice)
                     " queda fuera del contorno; se conserva su posición matemática.")))
    (setq indice (1+ indice)))
  (if (mcsdiv:anclado-p)
    ;; Cada corte es una cuerda interior verificada con origen invariable.
    (foreach corte cortes
      (setq obj (mcsdiv:salida (vla-AddLine mcsdiv-espacio
          (vlax-3d-point (mcsdiv:wcs mcsdiv-ancla))
          (vlax-3d-point (mcsdiv:wcs corte)))))
      (vla-put-Layer obj mcsdiv-capa))
    (progn
      ;; Fronteras paralelas: fusionar sin tender una LINE sobre un hueco.
      (setq indice 0)
      (foreach corte cortes
        (foreach tramo (mcsdiv:intervalos-corte (car (nth indice parcelas)) corte)
          (setq obj (mcsdiv:salida (vla-AddLine mcsdiv-espacio
              (vlax-3d-point (mcsdiv:wcs (mcsdiv:desde-marco (car tramo) corte)))
              (vlax-3d-point (mcsdiv:wcs (mcsdiv:desde-marco (cadr tramo) corte))))))
          (vla-put-Layer obj mcsdiv-capa))
        (setq indice (1+ indice))))))

(defun mcsdiv:limpiar (/ obj par fallos r)
  (setq fallos 0)
  (vl-catch-all-apply '(lambda () (done_dialog 0)) nil)
  (if mcsdiv-archivo
    (progn (vl-catch-all-apply 'close (list mcsdiv-archivo)) (setq mcsdiv-archivo nil)))
  (if (and mcsdiv-dcl-id (>= mcsdiv-dcl-id 0))
    (vl-catch-all-apply 'unload_dialog (list mcsdiv-dcl-id)))
  (setq mcsdiv-dcl-id nil)
  (if (and mcsdiv-dcl-ruta (findfile mcsdiv-dcl-ruta))
    (if (not (vl-file-delete mcsdiv-dcl-ruta)) (setq fallos (1+ fallos))))
  (setq mcsdiv-dcl-ruta nil)
  (foreach obj (append mcsdiv-temporales (if (not mcsdiv-completado) mcsdiv-salidas))
    (if (not (mcsdiv:borrar obj)) (setq fallos (1+ fallos))))
  (setq mcsdiv-temporales nil mcsdiv-salidas nil)
  (foreach par mcsdiv-entorno
    (setq r (vl-catch-all-apply 'setvar (list (car par) (cdr par))))
    (if (vl-catch-all-error-p r) (setq fallos (1+ fallos))))
  (if mcsdiv-undo
    (progn
      (setq r (vl-catch-all-apply 'vla-EndUndoMark (list mcsdiv-doc)))
      (if (vl-catch-all-error-p r) (setq fallos (1+ fallos)))
      (setq mcsdiv-undo nil)))
  (if (> fallos 0)
    (princ "\nAVISO: AutoCAD impidió parte de la limpieza/restauración. Revise el dibujo y las variables del sistema.")))

;;; ============================================================
;;; COMANDO
;;; ============================================================
(defun C:MCSUBDIV (/ *error* seleccion metodo valor objetivos k resultado aviso
                    mcsdiv-doc mcsdiv-espacio mcsdiv-entorno mcsdiv-undo
                    mcsdiv-msg mcsdiv-completado mcsdiv-temporales mcsdiv-salidas
                    mcsdiv-archivo mcsdiv-dcl-ruta mcsdiv-dcl-id mcsdiv-opciones
                    mcsdiv-guia mcsdiv-pivote mcsdiv-ancla mcsdiv-abierta
                    mcsdiv-origen mcsdiv-vertices mcsdiv-puntos
                    mcsdiv-total mcsdiv-eps mcsdiv-tol-area mcsdiv-base
                    mcsdiv-u mcsdiv-normal mcsdiv-umin mcsdiv-umax
                    mcsdiv-nmin mcsdiv-nmax mcsdiv-inferior mcsdiv-superior
                    mcsdiv-capa mcsdiv-estilo)
  (defun *error* (msg)
    (mcsdiv:limpiar)
    (cond
      (mcsdiv-msg (princ (strcat "\nMCSUBDIV: " mcsdiv-msg)))
      ((member (strcase (if msg msg "")) '("FUNCTION CANCELLED" "QUIT / EXIT ABORT" ""))
        (princ "\nMCSUBDIV cancelado. No se conserva ningún resultado parcial."))
      (T (princ (strcat "\nMCSUBDIV error: " msg))))
    (princ))

  (setq mcsdiv-doc (vla-get-ActiveDocument (vlax-get-acad-object))
        mcsdiv-entorno (mapcar '(lambda (v) (cons v (getvar v))) '("OSMODE" "CMDECHO" "DIMZIN"))
        mcsdiv-capa (getvar "CLAYER") mcsdiv-estilo (getvar "TEXTSTYLE"))
  (setvar "CMDECHO" 0)
  (setvar "DIMZIN" 0)
  (setvar "OSMODE" 0)
  (princ "\n=== MCSUBDIV: subdivisión por superficie ===")
  (setq seleccion (entsel "\nSeleccione una LWPOLYLINE de tramos rectos (cerrada o abierta): "))
  (if (null seleccion) (exit))
  (mcsdiv:leer-fuente (car seleccion))
  (if (/= 0 (logand 4 (cdr (assoc 70 (tblsearch "LAYER" mcsdiv-capa)))))
    (mcsdiv:fallar "La capa actual está bloqueada. Elija una capa desbloqueada para los resultados."))
  (setq mcsdiv-opciones
    (list '("metodo" . "0") '("partes" . "2") '("area" . "200") '("porcentaje" . "50")
          '("guia_modo" . "0") '("corte" . "0") '("ancla" . "0")
          '("rotar" . "0") '("angulo" . "0") '("lado" . "2")
          (cons "altura" (rtos (max 0.01 (getvar "TEXTSIZE")) 2 4))
          '("precision" . "2") '("tolerancia" . "0.01")))
  (if (not (mcsdiv:dialogo)) (exit))
  (setq aviso (mcsdiv:validar-opciones))
  (if aviso (mcsdiv:fallar aviso))
  (setq mcsdiv-tol-area (mcsdiv:numero (mcsdiv:opcion "tolerancia"))
        mcsdiv-u (mcsdiv:direccion-guia)
        mcsdiv-normal (list (- (cadr mcsdiv-u)) (car mcsdiv-u))
        metodo (mcsdiv:opcion "metodo") objetivos nil)
  ;; El lado solicitado corresponde al extremo inferior de la proyección.
  (if (and (not (mcsdiv:anclado-p)) (/= metodo "0")
           (> (mcsdiv:dot mcsdiv-normal (mcsdiv:vector-lado)) 0.0))
    (setq mcsdiv-normal (mcsdiv:escalar mcsdiv-normal -1.0)))
  (cond
    ((= metodo "0")
      (setq valor (fix (mcsdiv:numero (mcsdiv:opcion "partes"))) k 1)
      (while (< k valor)
        (setq objetivos (cons (* mcsdiv-total (/ (float k) valor)) objetivos) k (1+ k)))
      (setq objetivos (reverse objetivos)))
    ((= metodo "1") (setq objetivos (list (mcsdiv:numero (mcsdiv:opcion "area")))))
    (T (setq objetivos (list (* mcsdiv-total (/ (mcsdiv:numero (mcsdiv:opcion "porcentaje")) 100.0))))))
  (vla-StartUndoMark mcsdiv-doc)
  (setq mcsdiv-undo T)
  (mcsdiv:marco mcsdiv-u mcsdiv-normal)
  (setq mcsdiv-base (mcsdiv:region mcsdiv-puntos))
  (if (> (abs (- (vla-get-Area mcsdiv-base) mcsdiv-total)) (/ mcsdiv-tol-area 4.0))
    (mcsdiv:fallar "La región de AutoCAD no coincide con el área del contorno fuente."))
  (princ "\nCalculando superficies y verificando conectividad...")
  (setq resultado (if (mcsdiv:anclado-p)
                    (mcsdiv:parcelas-ancladas objetivos)
                    (mcsdiv:parcelas objetivos)))
  (mcsdiv:retirar mcsdiv-base)
  ;; Publicar la copia de trabajo solo si toda la subdivisión es válida.
  ;; También pertenece a la ejecución y se revierte ante error o UNDO.
  (if mcsdiv-abierta
    (mcsdiv:polilinea (mapcar 'mcsdiv:wcs mcsdiv-puntos) nil))
  (mcsdiv:publicar resultado)
  (setq mcsdiv-completado T)
  (mcsdiv:limpiar)
  (princ (strcat "\nMCSUBDIV: " (itoa (length (cadr resultado)))
                 " parcelas creadas. Área total: " (rtos mcsdiv-total 2 4)
                 " m2. Fuente conservada."))
  (princ))

(princ "\nMCSUBDIV cargado. Escriba MCSUBDIV para iniciar.")
(princ)
