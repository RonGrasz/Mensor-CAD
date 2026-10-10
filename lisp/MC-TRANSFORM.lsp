;;; ============================================================
;;; MCTRANSFORM — escala un contorno al área indicada.
;;; LWPOLYLINE simple horizontal +Z, sin arcos, abierta o cerrada.
;;; La original se conserva; la copia cerrada usa color verde ACI 3.
;;; Área en unidades de dibujo al cuadrado; no convierte unidades.
;;; Requiere AutoCAD Windows con ActiveX. Pruebas manuales positivas.
;;; ============================================================
(vl-load-com)

;;; El estado mctransform-* es local a C:MCTRANSFORM y se comparte
;;; con los ayudantes por el ámbito dinámico de AutoLISP.
(defun mctransform:fallar (msg)
  (setq mctransform-msg msg)
  (exit))

(defun mctransform:xy (p) (list (car p) (cadr p)))
(defun mctransform:restar (a b) (mapcar '- a b))
(defun mctransform:cruz (a b)
  (- (* (car a) (cadr b)) (* (cadr a) (car b))))
(defun mctransform:dot (a b)
  (+ (* (car a) (car b)) (* (cadr a) (cadr b))))
(defun mctransform:local (p)
  (mctransform:restar (mctransform:xy p)
                     (mctransform:xy mctransform-origen)))
(defun mctransform:wcs (p)
  (list (+ (car p) (car mctransform-origen))
        (+ (cadr p) (cadr mctransform-origen))
        (caddr mctransform-origen)))
(defun mctransform:aristas (pts)
  (mapcar 'list pts (append (cdr pts) (list (car pts)))))

(defun mctransform:tolerancia (pts / xs ys span)
  (setq xs (mapcar 'car pts) ys (mapcar 'cadr pts)
        span (max (- (apply 'max xs) (apply 'min xs))
                  (- (apply 'max ys) (apply 'min ys))))
  (max 1e-8 (* span 1e-10)))

;;; Gauss y centroide de área para tramos rectos. El origen local
;;; evita restar productos de coordenadas UTM grandes. No se usa
;;; el promedio de vértices ni el centro de la caja envolvente.
(defun mctransform:medir (pts / suma sx sy ar a b cruz)
  (setq suma 0.0 sx 0.0 sy 0.0)
  (foreach ar (mctransform:aristas pts)
    (setq a (car ar) b (cadr ar) cruz (mctransform:cruz a b)
          suma (+ suma cruz)
          sx (+ sx (* (+ (car a) (car b)) cruz))
          sy (+ sy (* (+ (cadr a) (cadr b)) cruz))))
  (if (<= (abs suma) (* 2.0 mctransform-eps mctransform-eps))
    (mctransform:fallar "La superficie del contorno es nula o degenerada."))
  (list (/ (abs suma) 2.0)
        (list (/ sx (* 3.0 suma)) (/ sy (* 3.0 suma)))))

(defun mctransform:en-segmento (p a b / ab ap len)
  (setq ab (mctransform:restar b a)
        ap (mctransform:restar p a) len (distance a b))
  (and (> len mctransform-eps)
       (<= (abs (mctransform:cruz ab ap)) (* mctransform-eps len))
       (>= (mctransform:dot ap ab) (- (* mctransform-eps len)))
       (<= (mctransform:dot ap ab)
           (+ (* len len) (* mctransform-eps len)))))

(defun mctransform:signo-lado (a b p / v tol)
  (setq v (mctransform:cruz (mctransform:restar b a)
                           (mctransform:restar p a))
        tol (* mctransform-eps (distance a b)))
  (cond ((> v tol) 1) ((< v (- tol)) -1) (T 0)))

(defun mctransform:segmentos-tocan (a b c d / s1 s2 s3 s4)
  (setq s1 (mctransform:signo-lado a b c)
        s2 (mctransform:signo-lado a b d)
        s3 (mctransform:signo-lado c d a)
        s4 (mctransform:signo-lado c d b))
  (or (and (< (* s1 s2) 0) (< (* s3 s4) 0))
      (mctransform:en-segmento c a b) (mctransform:en-segmento d a b)
      (mctransform:en-segmento a c d) (mctransform:en-segmento b c d)))

(defun mctransform:validar-simple (pts / ars num i j a b anterior siguiente)
  (setq ars (mctransform:aristas pts) num (length ars) i 0)
  (if (< num 3)
    (mctransform:fallar "El contorno requiere al menos tres vértices."))
  (foreach a ars
    (if (<= (distance (car a) (cadr a)) mctransform-eps)
      (mctransform:fallar "El contorno tiene vértices consecutivos coincidentes.")))
  (while (< i num)
    (setq anterior (nth (rem (+ i num -1) num) pts)
          a (nth i pts) siguiente (nth (rem (1+ i) num) pts))
    (if (and (= 0 (mctransform:signo-lado anterior a siguiente))
             (< (mctransform:dot (mctransform:restar a anterior)
                                (mctransform:restar siguiente a)) 0.0))
      (mctransform:fallar "El contorno tiene aristas superpuestas."))
    (setq j (1+ i) a (nth i ars))
    (while (< j num)
      (if (and (/= j (1+ i)) (not (and (= i 0) (= j (1- num)))))
        (progn
          (setq b (nth j ars))
          (if (mctransform:segmentos-tocan (car a) (cadr a) (car b) (cadr b))
            (mctransform:fallar "El contorno se cruza o se toca a sí mismo."))))
      (setq j (1+ j)))
    (setq i (1+ i)))
  (mctransform:medir pts)
  T)

(defun mctransform:vertices (ent / ed elev pts par)
  (setq ed (entget ent)
        elev (if (assoc 38 ed) (cdr (assoc 38 ed)) 0.0) pts nil)
  (foreach par ed
    (if (= (car par) 10)
      (setq pts (cons (trans (list (cadr par) (caddr par) elev) ent 0) pts))))
  (reverse pts))

(defun mctransform:leer-fuente (ent / ed normal pts par)
  (setq ed (entget ent))
  (if (/= (cdr (assoc 0 ed)) "LWPOLYLINE")
    (mctransform:fallar "Seleccione una LWPOLYLINE; no se admite POLYLINE 3D ni antigua."))
  (setq normal (if (assoc 210 ed) (cdr (assoc 210 ed)) '(0.0 0.0 1.0)))
  (if (not (equal normal '(0.0 0.0 1.0) 1e-10))
    (mctransform:fallar "Solo se admiten contornos horizontales con normal +Z."))
  (foreach par ed
    (if (and (= (car par) 42) (/= (cdr par) 0.0))
      (mctransform:fallar "Esta versión no admite arcos (bulge). No se sustituyen por cuerdas.")))
  (setq pts (mctransform:vertices ent))
  (if (< (length pts) 3)
    (mctransform:fallar "El contorno requiere al menos tres vértices."))
  (setq mctransform-abierta (= 0 (logand 1 (cdr (assoc 70 ed))))
        mctransform-origen (car pts)
        mctransform-puntos (mapcar 'mctransform:local pts)
        mctransform-eps (mctransform:tolerancia mctransform-puntos))
  ;; En abiertas, retirar el extremo final duplicado solo de la copia.
  ;; En AutoLISP, last devuelve el último punto completo.
  (if (and mctransform-abierta
           (<= (distance (car pts) (last pts)) mctransform-eps))
    (setq mctransform-puntos (reverse (cdr (reverse mctransform-puntos)))))
  (mctransform:validar-simple mctransform-puntos))

(defun mctransform:crear-contorno (/ datos)
  ;; Sin anchos ni grosor: es un contorno, no una copia de propiedades.
  ;; entmake asigna propietario en el espacio actual del dibujo.
  (setq datos
    (append
      (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity")
            (cons 8 mctransform-capa) '(62 . 3) '(100 . "AcDbPolyline")
            (cons 90 (length mctransform-puntos)) '(70 . 1) '(43 . 0.0)
            (cons 38 (caddr mctransform-origen)) '(39 . 0.0)
            '(210 0.0 0.0 1.0))
      (mapcar '(lambda (p) (cons 10 (mctransform:xy (mctransform:wcs p))))
              mctransform-puntos)))
  (if (not (entmake datos))
    (mctransform:fallar "No se pudo crear el contorno de trabajo."))
  ;; Registrar antes de cualquier modificación que pueda fallar.
  (setq mctransform-contorno (entlast))
  (entupd mctransform-contorno))

(defun mctransform:escalar (pts centro factor)
  (mapcar
    '(lambda (p)
       (mapcar '+ centro
         (mapcar '(lambda (v) (* v factor)) (mctransform:restar p centro))))
    pts))

(defun mctransform:escribir-vertices (pts / datos par salida)
  (setq datos (entget mctransform-contorno) salida nil)
  (foreach par datos
    (if (= (car par) 10)
      (progn
        (setq par (cons 10 (mctransform:xy
                            (trans (mctransform:wcs (car pts))
                                   0 mctransform-contorno)))
              pts (cdr pts))))
    (setq salida (cons par salida)))
  (if (not (entmod (reverse salida)))
    (mctransform:fallar "AutoCAD no pudo transformar el contorno."))
  (entupd mctransform-contorno))

(defun mctransform:limpiar (/ r fallos par)
  (setq fallos 0)
  (if (and mctransform-contorno (not mctransform-completado))
    (progn
      (setq r (vl-catch-all-apply
                '(lambda ()
                   (if (entget mctransform-contorno)
                     (entdel mctransform-contorno)
                     T)) nil))
      (if (or (vl-catch-all-error-p r) (null r))
        (setq fallos (1+ fallos)))))
  (setq mctransform-contorno nil)
  (foreach par mctransform-entorno
    (setq r (vl-catch-all-apply 'setvar (list (car par) (cdr par))))
    (if (vl-catch-all-error-p r) (setq fallos (1+ fallos))))
  (setq mctransform-entorno nil)
  (if mctransform-undo
    (progn
      (setq r (vl-catch-all-apply 'vla-EndUndoMark (list mctransform-doc)))
      (if (vl-catch-all-error-p r) (setq fallos (1+ fallos)))
      (setq mctransform-undo nil)))
  (if (> fallos 0)
    (princ "\nAVISO: AutoCAD impidió parte de la limpieza/restauración. Revise el dibujo y las variables del sistema.")))

;;; ============================================================
;;; COMANDO: seleccionar → copia verde → área → transformación.
;;; ============================================================
(defun C:MCTRANSFORM (/ *error* seleccion medida area centro objetivo factor
                       nuevos comprobacion eps-fuente tol-area tol-centro
                       mctransform-doc mctransform-entorno mctransform-undo
                       mctransform-msg mctransform-completado mctransform-contorno
                       mctransform-capa mctransform-origen mctransform-abierta
                       mctransform-puntos mctransform-eps)
  (defun *error* (msg)
    (mctransform:limpiar)
    (cond
      (mctransform-msg (princ (strcat "\nMCTRANSFORM: " mctransform-msg)))
      ((wcmatch (strcase (if msg msg "")) "*CANCEL*,*QUIT*,*EXIT*")
        (princ "\nMCTRANSFORM cancelado. No se conserva ningún resultado parcial."))
      (T (princ (strcat "\nMCTRANSFORM error: " (if msg msg "")))))
    (princ))

  (setq mctransform-doc (vla-get-ActiveDocument (vlax-get-acad-object))
        mctransform-entorno
          (mapcar '(lambda (v) (cons v (getvar v))) '("OSMODE" "CMDECHO" "DIMZIN"))
        mctransform-capa (getvar "CLAYER"))
  (setvar "CMDECHO" 0)
  (setvar "OSMODE" 0)
  (setvar "DIMZIN" 0)
  (princ "\n=== MCTRANSFORM: escala de contorno por superficie ===")
  (setq seleccion (entsel "\nSeleccione una LWPOLYLINE de tramos rectos (cerrada o abierta): "))
  (if (null seleccion) (exit))
  (mctransform:leer-fuente (car seleccion))
  (if (/= 0 (logand 4 (cdr (assoc 70 (tblsearch "LAYER" mctransform-capa)))))
    (mctransform:fallar "La capa actual está bloqueada. Elija una capa desbloqueada para el contorno."))
  (setq medida (mctransform:medir mctransform-puntos)
        area (car medida) centro (cadr medida) eps-fuente mctransform-eps)
  (vla-StartUndoMark mctransform-doc)
  (setq mctransform-undo T)
  (mctransform:crear-contorno)
  (if mctransform-abierta
    (princ "\nFuente abierta: se cerró solo la copia de trabajo; la original se conserva."))
  (princ (strcat "\nÁrea original del contorno: " (rtos area 2 4) " u2."))
  ;; initget rechaza cero y negativos; Enter cancela y elimina la copia.
  (initget 6)
  (setq objetivo (getreal "\nÁrea objetivo positiva (u2), o Enter para cancelar: "))
  (if (null objetivo) (exit))
  (setq factor (sqrt (/ objetivo area))
        nuevos (mctransform:escalar mctransform-puntos centro factor)
        mctransform-eps (mctransform:tolerancia nuevos))
  (mctransform:validar-simple nuevos)
  (mctransform:escribir-vertices nuevos)
  ;; Comprobar las coordenadas realmente almacenadas, no solo la intención.
  (setq nuevos (mapcar 'mctransform:local
                      (mctransform:vertices mctransform-contorno))
        mctransform-eps (mctransform:tolerancia nuevos))
  (mctransform:validar-simple nuevos)
  (setq comprobacion (mctransform:medir nuevos)
        tol-area (* objetivo 1e-8)
        tol-centro (max eps-fuente mctransform-eps))
  (if (> (abs (- (car comprobacion) objetivo)) tol-area)
    (mctransform:fallar "El área resultante no cumple la precisión requerida; se retira el contorno."))
  (if (> (distance (cadr comprobacion) centro) tol-centro)
    (mctransform:fallar "El centroide resultante no coincide con el original; se retira el contorno."))
  (setq mctransform-completado T)
  (princ (strcat "\nMCTRANSFORM: contorno verde creado. Área: "
                 (rtos (car comprobacion) 2 4) " u2; factor: " (rtos factor 2 8)
                 ". Centroide conservado. Fuente intacta."))
  (mctransform:limpiar)
  (princ))

(princ "\nMCTRANSFORM cargado. Escriba MCTRANSFORM para iniciar.")
(princ)
