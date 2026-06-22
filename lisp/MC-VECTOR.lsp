;;; ============================================================
;;; MCVECTOR.LSP - Anotador de Rumbos y Distancias Topograficos
;;; Comando: MCVECTOR
;;; Compatible: AutoCAD 2010+ / Civil 3D (con VLISP)
;;; ============================================================

(vl-load-com)

;;; ============================================================
;;; SECCION 0: UTILIDADES MATEMATICAS PROPIAS
;;; ============================================================

;;; Modulo matematico estricto (AutoLISP 'rem' no maneja wrap-around negativo)
(defun mcv:mod (x y / r)
  (setq r (- x (* y (fix (/ x y)))))
  (if (and (< r 0) (> y 0)) (setq r (+ r y)))
  (if (and (> r 0) (< y 0)) (setq r (+ r y)))
  r
)

;;; ============================================================
;;; SECCION 1: MATEMATICAS Y UTILIDADES
;;; ============================================================

(defun mcv:rad->deg (rad)
  (* rad (/ 180.0 pi))
)

(defun mcv:midpoint (p1 p2)
  (list
    (/ (+ (car  p1) (car  p2)) 2.0)
    (/ (+ (cadr p1) (cadr p2)) 2.0)
  )
)

(defun mcv:dist2d (p1 p2 / dx dy)
  (setq dx (- (car  p2) (car  p1)))
  (setq dy (- (cadr p2) (cadr p1)))
  (sqrt (+ (* dx dx) (* dy dy)))
)

(defun mcv:angulo->rumbo (ang-rad /
  deg-mat az-raw az
  ns ew qa
  grados min-dec minutos segs
  s-min s-seg)

  (setq deg-mat (mcv:rad->deg ang-rad))
  (setq az-raw (- 90.0 deg-mat))
  (setq az (mcv:mod az-raw 360.0))

  (cond
    ((and (>= az   0.0) (< az  90.0))  (setq ns "N"  ew "E"  qa az))
    ((and (>= az  90.0) (< az 180.0))  (setq ns "S"  ew "E"  qa (- 180.0 az)))
    ((and (>= az 180.0) (< az 270.0))  (setq ns "S"  ew "W"  qa (- az 180.0)))
    (t                                 (setq ns "N"  ew "W"  qa (- 360.0 az)))
  )

  (setq grados (fix qa))
  (setq min-dec (* (- qa (float grados)) 60.0))
  (setq minutos (fix min-dec))
  (setq segs (fix (+ 0.5 (* (- min-dec (float minutos)) 60.0))))

  (if (>= segs 60)
    (progn (setq segs 0) (setq minutos (1+ minutos)))
  )
  (if (>= minutos 60)
    (progn (setq minutos 0) (setq grados (1+ grados)))
  )

  (setq s-min (itoa minutos))
  (setq s-seg (itoa segs))
  (if (< minutos 10) (setq s-min (strcat "0" s-min)))
  (if (< segs    10) (setq s-seg (strcat "0" s-seg)))

  (strcat ns " " (itoa grados) "%%d " s-min "' " s-seg "\" " ew)
)

(defun mcv:fmt-distancia (dist decimales)
  (strcat (rtos dist 2 decimales) " m")
)

(defun mcv:texto-height (/ h)
  (setq h (getvar "TEXTSIZE"))
  (if (zerop h) 2.5 h)
)

;;; ============================================================
;;; SECCION 2: INSERCION DE ANOTACIONES
;;; ============================================================

(defun mcv:insertar-anotacion (p1 p2 decimales /
  mid ang ang-deg texto-rumbo texto-dist
  h offset-dist flip? ang-texto
  perp-x perp-y sign
  rx-r ry-r rx-d ry-d
  pt-rumbo pt-dist)

  (setq mid     (mcv:midpoint p1 p2))
  (setq ang     (angle p1 p2))
  (setq ang-deg (mcv:rad->deg ang))

  (setq texto-rumbo (mcv:angulo->rumbo ang))
  (setq texto-dist  (mcv:fmt-distancia (mcv:dist2d p1 p2) decimales))

  (setq h           (mcv:texto-height))
  (setq offset-dist (* h 0.8))

  (setq flip? (and (> ang-deg 90.0) (<= ang-deg 270.0)))
  (setq ang-texto (if flip? (+ ang pi) ang))

  (setq perp-x (- (sin ang)))
  (setq perp-y    (cos ang))

  (setq sign (if flip? -1.0 1.0))

  (setq rx-r (+ (car  mid) (* sign perp-x offset-dist)))
  (setq ry-r (+ (cadr mid) (* sign perp-y offset-dist)))

  (setq rx-d (- (car  mid) (* sign perp-x offset-dist)))
  (setq ry-d (- (cadr mid) (* sign perp-y offset-dist)))

  (entmake
    (list
      '(0 . "TEXT")
      (cons 8  (getvar "CLAYER"))
      (cons 7  (getvar "TEXTSTYLE"))
      (cons 10 (list rx-r ry-r 0.0))
      (cons 40 h)
      (cons 1  texto-rumbo)
      (cons 50 ang-texto)
      (cons 72 1)
      (cons 73 0)
      (cons 11 (list rx-r ry-r 0.0))
    )
  )

  (entmake
    (list
      '(0 . "TEXT")
      (cons 8  (getvar "CLAYER"))
      (cons 7  (getvar "TEXTSTYLE"))
      (cons 10 (list rx-d ry-d 0.0))
      (cons 40 h)
      (cons 1  texto-dist)
      (cons 50 ang-texto)
      (cons 72 1)
      (cons 73 0)
      (cons 11 (list rx-d ry-d 0.0))
    )
  )
)

;;; ============================================================
;;; SECCION 3: GENERACION DEL ARCHIVO DCL TEMPORAL
;;; ============================================================

(defun mcv:escribir-dcl (ruta-dcl / fh)
  (setq fh (open ruta-dcl "w"))
  (if (null fh)
    nil
    (progn
      (write-line "// MCVECTOR.DCL - generado por mcvector.lsp" fh)
      (write-line "mcvector_dlg : dialog {" fh)
      (write-line "  label = \"MCVECTOR - Anotar Rumbos y Distancias\";" fh)
      (write-line "  : column {" fh)
      (write-line "    : boxed_radio_column {" fh)
      (write-line "      label = \"Metodo de Seleccion\";" fh)
      (write-line "      key   = \"metodo\";" fh)
      (write-line "      : radio_button {" fh)
      (write-line "        label = \"Poligono  (LWPOLYLINE / POLYLINE)\";" fh)
      (write-line "        key   = \"modo_poligono\";" fh)
      (write-line "      }" fh)
      (write-line "      : radio_button {" fh)
      (write-line "        label = \"Manual  (Punto a Punto)\";" fh)
      (write-line "        key   = \"modo_manual\";" fh)
      (write-line "      }" fh)
      (write-line "    }" fh)
      (write-line "    : boxed_radio_row {" fh)
      (write-line "      label = \"Sentido de Recorrido  (Poligono)\";" fh)
      (write-line "      key   = \"sentido_box\";" fh)
      (write-line "      : radio_button {" fh)
      (write-line "        label = \"Inverso\";" fh)
      (write-line "        key   = \"sentido_h\";" fh)
      (write-line "      }" fh)
      (write-line "      : radio_button {" fh)
      (write-line "        label = \"directo\";" fh)
      (write-line "        key   = \"sentido_ah\";" fh)
      (write-line "      }" fh)
      (write-line "    }" fh)
      (write-line "    : boxed_column {" fh)
      (write-line "      label = \"Precision Decimal  (Distancia)\";" fh)
      (write-line "      : row {" fh)
      (write-line "        : text { label = \"Decimales : \"; }" fh)
      (write-line "        : edit_box {" fh)
      (write-line "          key        = \"decimales\";" fh)
      (write-line "          width      = 6;" fh)
      (write-line "          edit_limit = 2;" fh)
      (write-line "        }" fh)
      (write-line "      }" fh)
      (write-line "    }" fh)
      (write-line "    : row {" fh)
      (write-line "      : spacer { width = 1; }" fh)
      (write-line "      ok_cancel;" fh)
      (write-line "      : spacer { width = 1; }" fh)
      (write-line "    }" fh)
      (write-line "  }" fh)
      (write-line "}" fh)
      (close fh)
      T
    )
  )
)

;;; ============================================================
;;; SECCION 4: LOGICA DE MODO POLIGONO Y MANUAL
;;; ============================================================

(defun mcv:seleccionar-poligono (/ ss)
  (princ "\nSeleccione una polilinea (LWPOLYLINE o POLYLINE): ")
  (setq ss (ssget ":S" '((0 . "LWPOLYLINE,POLYLINE"))))
  (if ss (ssname ss 0) nil)
)

(defun mcv:vertice-mas-cercano (ent pt-clic / entdata tipo idx-min dist-min i vx vy d sub-ent sub-data pt)
  (setq entdata  (entget ent))
  (setq tipo     (cdr (assoc 0 entdata)))
  (setq idx-min  0)
  (setq dist-min 1.0e+308)

  (cond
    ((= tipo "LWPOLYLINE")
      (setq i 0)
      (foreach par entdata
        (if (= (car par) 10)
          (progn
            (setq vx (cadr par)  vy (caddr par))
            (setq d (mcv:dist2d (list vx vy) pt-clic))
            (if (< d dist-min)
              (setq dist-min d  idx-min i)
            )
            (setq i (1+ i))
          )
        )
      )
    )
    ((= tipo "POLYLINE")
      (setq i 0)
      (setq sub-ent (entnext ent))
      (while (and sub-ent (not (= (cdr (assoc 0 (entget sub-ent))) "SEQEND")))
        (setq sub-data (entget sub-ent))
        (setq pt       (cdr (assoc 10 sub-data)))
        (setq vx (car pt)  vy (cadr pt))
        (setq d (mcv:dist2d (list vx vy) pt-clic))
        (if (< d dist-min)
          (setq dist-min d  idx-min i)
        )
        (setq i (1+ i))
        (setq sub-ent (entnext sub-ent))
      )
    )
  )
  idx-min
)

(defun mcv:obtener-vertices (ent / entdata tipo pts sub-ent sub-data pt)
  (setq entdata (entget ent))
  (setq tipo    (cdr (assoc 0 entdata)))
  (setq pts     '())

  (cond
    ((= tipo "LWPOLYLINE")
      (foreach par entdata
        (if (= (car par) 10)
          (setq pts (append pts (list (list (cadr par) (caddr par)))))
        )
      )
    )
    ((= tipo "POLYLINE")
      (setq sub-ent (entnext ent))
      (while (and sub-ent (not (= (cdr (assoc 0 (entget sub-ent))) "SEQEND")))
        (setq sub-data (entget sub-ent))
        (setq pt       (cdr (assoc 10 sub-data)))
        (setq pts (append pts (list (list (car pt) (cadr pt)))))
        (setq sub-ent (entnext sub-ent))
      )
    )
  )
  pts
)

(defun mcv:es-cerrada (ent / entdata flag70)
  (setq entdata (entget ent))
  (setq flag70  (cdr (assoc 70 entdata)))
  (if flag70
    ;; Uso de funcion nativa logand en lugar de workaround
    (not (zerop (logand flag70 1)))
    nil
  )
)

;;; Obtiene el resto de la lista empezando desde el indice N
;;; (Implementacion nativa para AutoLISP)
(defun mcv:nthcdr (n lst)
  (while (and (> n 0) lst)
    (setq lst (cdr lst))
    (setq n (1- n))
  )
  lst
)

;;; Rota la lista LST exactamente N posiciones a la izquierda
(defun mcv:rotar-lista (lst n / len n-mod cola cabeza)
  (setq len (length lst))
  (if (or (zerop len) (zerop n))
    lst
    (progn
      (setq n-mod  (fix (mcv:mod (float n) (float len))))
      (setq cola   (mcv:nthcdr n-mod lst))
      (setq cabeza (reverse (mcv:nthcdr (- len n-mod) (reverse lst))))
      (append cola cabeza)
    )
  )
)

(defun mcv:procesar-poligono (ent sentido-horario decimales /
  vertices n idx-inicio pt-clic
  vertices-ord es-cerrada
  i p1 p2 num-segs)

  (setq vertices (mcv:obtener-vertices ent))
  (setq n        (length vertices))

  (if (< n 2)
    (progn (alert "La polilinea no tiene suficientes vertices.") (exit))
  )

  (princ "\nIndique el vertice de inicio (clic cerca del vertice): ")
  (setq pt-clic (getpoint))
  (if (null pt-clic)
    (progn (princ "\nCancelado.") (exit))
  )

  (setq idx-inicio (mcv:vertice-mas-cercano ent pt-clic))
  (princ (strcat "\nVertice de inicio: #" (itoa (1+ idx-inicio))))

  (setq vertices-ord (mcv:rotar-lista vertices idx-inicio))

  (if sentido-horario
    (setq vertices-ord (reverse vertices-ord))
  )

  (setq es-cerrada (mcv:es-cerrada ent))

  (setq i 0)
  (while (< i (- n 1))
    (setq p1 (nth i      vertices-ord))
    (setq p2 (nth (1+ i) vertices-ord))
    (mcv:insertar-anotacion p1 p2 decimales)
    (setq i (1+ i))
  )

  (if es-cerrada
    (progn
      (setq p1 (last vertices-ord))
      (setq p2 (car  vertices-ord))
      (mcv:insertar-anotacion p1 p2 decimales)
      (setq num-segs n)
    )
    (setq num-segs (- n 1))
  )

  (princ (strcat "\n[MCVECTOR] " (itoa num-segs) " segmentos anotados."))
)

(defun mcv:procesar-manual (decimales / p1 p2 contador)
  (setq contador 0)
  (princ "\n[MCVECTOR] Modo Manual. ESC para terminar.")

  (while T
    (princ "\nPunto inicial <ESC para salir>: ")
    (setq p1 (getpoint))
    (if (null p1)
      (progn (princ "\n[MCVECTOR] Finalizado.") (exit))
    )
    (princ "\nPunto final: ")
    (setq p2 (getpoint p1))
    (if (null p2)
      (progn (princ "\n[MCVECTOR] Finalizado.") (exit))
    )
    (mcv:insertar-anotacion p1 p2 decimales)
    (setq contador (1+ contador))
    (princ (strcat "\n  Segmento " (itoa contador) " anotado."))
  )
)

;;; ============================================================
;;; SECCION 5: COMANDO PRINCIPAL - C:MCVECTOR
;;; ============================================================

(defun C:MCVECTOR (/ 
  mcv-olderr dcl-ruta dcl-id resultado
  modo-poligono sentido-horario decimales ent
  old-osmode old-cmdecho old-dimzin)

  ;; 1. AISLAR Y GUARDAR ENTORNO Y MANEJADOR DE ERRORES
  (setq mcv-olderr *error*)
  
  (defun *error* (msg)
    (if old-osmode  (setvar "OSMODE"  old-osmode))
    (if old-cmdecho (setvar "CMDECHO" old-cmdecho))
    (if old-dimzin  (setvar "DIMZIN"  old-dimzin))
    (if dcl-id
      (progn (done_dialog 0) (unload_dialog dcl-id))
    )
    (if (and dcl-ruta (findfile dcl-ruta))
      (vl-file-delete dcl-ruta)
    )
    (if (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*EXIT*"))
      (princ (strcat "\n[MCVECTOR] Error: " msg))
    )
    (setq *error* mcv-olderr) ;; Restaurar error original
    (princ)
  )

  (setq old-osmode  (getvar "OSMODE"))
  (setq old-cmdecho (getvar "CMDECHO"))
  (setq old-dimzin  (getvar "DIMZIN")) ;; Guardamos DIMZIN vital para rtos

  (setvar "CMDECHO" 0)
  ;; Congelamos DIMZIN a 0 para forzar a que siempre se muestren los decimales de distancia
  (setvar "DIMZIN" 0) 

  ;; 2. MANEJO NATIVO DE ARCHIVO TEMPORAL
  (setq dcl-ruta (vl-filename-mktemp "mcvector.dcl"))
  
  (if (not (mcv:escribir-dcl dcl-ruta))
    (progn
      (alert "No se pudo crear el archivo DCL temporal.")
      (*error* "Generacion DCL fallida")
      (exit)
    )
  )

  (setq dcl-id (load_dialog dcl-ruta))
  (if (< dcl-id 0)
    (progn
      (alert "No se pudo cargar el dialogo DCL.")
      (*error* "Carga DCL fallida")
      (exit)
    )
  )

  (if (not (new_dialog "mcvector_dlg" dcl-id))
    (progn
      (alert "No se encontro la definicion del dialogo.")
      (*error* "Definicion DCL no encontrada")
      (exit)
    )
  )

  (set_tile "modo_poligono" "1")
  (set_tile "modo_manual"   "0")
  (set_tile "sentido_h"     "0")
  (set_tile "sentido_ah"    "1")
  (set_tile "decimales"     "2")

  (action_tile "accept"
    "(progn
       (setq *mcv-modo-poligono (= (get_tile \"modo_poligono\") \"1\"))
       (setq *mcv-sentido-h     (= (get_tile \"sentido_h\")     \"1\"))
       (setq *mcv-decimales-str (get_tile \"decimales\"))
       (done_dialog 1)
     )"
  )
  (action_tile "cancel" "(done_dialog 0)")

  (setq resultado (start_dialog))
  
  (unload_dialog dcl-id)
  (setq dcl-id nil)
  (if (findfile dcl-ruta) (vl-file-delete dcl-ruta))

  (if (= resultado 0)
    (progn
      (princ "\n[MCVECTOR] Cancelado.")
      (*error* "Cancelado por el usuario")
      (exit)
    )
  )

  (setq modo-poligono   *mcv-modo-poligono)
  (setq sentido-horario *mcv-sentido-h)
  (setq decimales       (atoi *mcv-decimales-str))
  (if (or (< decimales 0) (> decimales 8)) (setq decimales 2))

  (setq *mcv-modo-poligono nil *mcv-sentido-h nil *mcv-decimales-str nil)

  (setvar "OSMODE" 0)

  (princ (strcat
    "\n[MCVECTOR] Modo: "    (if modo-poligono "Poligono" "Manual")
    " | Sentido: "           (if sentido-horario "Horario" "Antihorario")
    " | Decimales: "         (itoa decimales)
  ))

  (if modo-poligono
    (progn
      (setq ent (mcv:seleccionar-poligono))
      (if ent
        (mcv:procesar-poligono ent sentido-horario decimales)
        (princ "\n[MCVECTOR] No se selecciono ninguna polilinea.")
      )
    )
    (mcv:procesar-manual decimales)
  )

  ;; 3. RESTAURAR ENTORNO
  (setvar "OSMODE"  old-osmode)
  (setvar "CMDECHO" old-cmdecho)
  (setvar "DIMZIN"  old-dimzin)
  (setq *error* mcv-olderr) ;; Restaurar manejador de errores original

  (princ "\n[MCVECTOR] Completado.")
  (princ)
)

;;; ============================================================
;;; SECCION 6: MENSAJE DE CARGA
;;; ============================================================

(princ "\n--------------------------------------------")
(princ "\n  MCVECTOR - Rumbos y Distancias")
(princ "\n  Comando: MCVECTOR")
(princ "\n--------------------------------------------")
(princ)