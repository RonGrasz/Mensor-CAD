;;; MCELEMENTS — Edificaciones y vegetación. AutoCAD Windows / ActiveX.
;;; Estado de ejecución por enlace dinámico, siempre local a C:MCELEMENTS.
(vl-load-com)

(defun mce:fallar (mensaje)
  (setq mce:motivo mensaje)
  (quit)
)

(defun mce:registrar (obj)
  (setq mce:objetos (cons obj mce:objetos))
  obj
)

(defun mce:vector-objetos (objetos / matriz)
  (setq matriz (vlax-make-safearray vlax-vbObject (cons 0 (1- (length objetos)))))
  (vlax-safearray-fill matriz objetos)
  matriz
)

(defun mce:retirar (obj / resultado borrado)
  (setq borrado (vl-catch-all-apply 'vlax-erased-p (list obj)))
  (if (or (vl-catch-all-error-p borrado) (not borrado))
    (progn
      (setq resultado (vl-catch-all-apply 'vla-Delete (list obj)))
      (if (vl-catch-all-error-p resultado)
        (progn (princ "\nAviso: no se pudo retirar un recurso propio; revisar el dibujo.") nil)
        T
      )
    )
    T
  )
)

(defun mce:limpiar (revertir / obj par resultado)
  ;; Orden inverso: entidades antes que las capas propias que las contienen.
  (if revertir
    (progn
      (foreach obj mce:objetos (mce:retirar obj))
      (foreach obj mce:capas (mce:retirar obj))
    )
  )
  (if mce:archivo
    (progn
      (setq resultado (vl-catch-all-apply 'close (list mce:archivo)))
      (if (vl-catch-all-error-p resultado) (princ "\nAviso: revisar el cierre del archivo DCL."))
      (setq mce:archivo nil)
    )
  )
  (if (and mce:dcl-id (>= mce:dcl-id 0))
    (progn
      (setq resultado (vl-catch-all-apply 'unload_dialog (list mce:dcl-id)))
      (if (vl-catch-all-error-p resultado) (princ "\nAviso: revisar la descarga del DCL."))
      (setq mce:dcl-id nil)
    )
  )
  (if (and mce:dcl-ruta (findfile mce:dcl-ruta))
    (if (not (vl-file-delete mce:dcl-ruta))
      (princ "\nAviso: no se pudo borrar el DCL temporal.")
    )
  )
  (if mce:color
    (progn (vl-catch-all-apply 'vlax-release-object (list mce:color)) (setq mce:color nil))
  )
  (foreach par mce:variables
    (setq resultado (vl-catch-all-apply 'setvar (list (car par) (cdr par))))
    (if (vl-catch-all-error-p resultado)
      (princ (strcat "\nAviso: revisar la variable " (car par) "."))
    )
  )
  (if mce:undo
    (progn
      (setq resultado (vl-catch-all-apply 'vla-EndUndoMark (list mce:doc)))
      (setq mce:undo nil)
      (if (vl-catch-all-error-p resultado)
        (princ "\nAviso: no se pudo cerrar UNDO; no se garantiza un deshacer único.")
      )
    )
  )
  ;; Liberar envoltorios COM no borra los resultados de una ejecución correcta.
  (foreach obj (append mce:objetos mce:capas)
    (vl-catch-all-apply 'vlax-release-object (list obj))
  )
  (setq mce:objetos nil mce:capas nil)
)

(defun mce:positivo (texto / caracteres puntos digitos valido codigo valor)
  ;; Decimal estricto, punto decimal; sin unidades, exponentes ni texto residual.
  (setq caracteres (vl-string->list (vl-string-trim " \t" texto))
        puntos 0 digitos 0 valido T)
  (foreach codigo caracteres
    (cond
      ((and (>= codigo 48) (<= codigo 57)) (setq digitos (1+ digitos)))
      ((= codigo 46) (setq puntos (1+ puntos)))
      (T (setq valido nil))
    )
  )
  (if (and valido (> digitos 0) (<= puntos 1))
    (progn
      (setq valor (distof (vl-string-trim " \t" texto) 2))
      (if (and valor (> valor 0.0)) valor)
    )
  )
)

(defun mce:rotulo-ui ()
  (mode_tile "contenido" (if (= (get_tile "rotulo") "0") 1 0))
)

(defun mce:aceptar-ui (/ factor modo texto)
  (setq factor (mce:positivo (get_tile "factor"))
        modo (atoi (get_tile "rotulo"))
        texto (vl-string-trim " \t" (get_tile "contenido")))
  (cond
    ((not factor) (set_tile "aviso" "Factor: use un decimal positivo con punto (ej. 0.5)."))
    ((and (> modo 0) (= texto "")) (set_tile "aviso" "Escriba el texto o tag del rótulo."))
    (T
      (setq mce:opciones (list (atoi (get_tile "tipo")) factor modo texto))
      (done_dialog 1)
    )
  )
)

(defun mce:dialogo (/ linea estado)
  (setq mce:dcl-ruta (vl-filename-mktemp "mce-" nil ".dcl")
        mce:archivo (open mce:dcl-ruta "w"))
  (if (not mce:archivo) (mce:fallar "No se pudo crear el DCL temporal."))
  (foreach linea
    '("mce_dialog : dialog { label = \"MCELEMENTS — Edificaciones y vegetación\";"
      ": popup_list { key = \"tipo\"; label = \"Estructura:\"; width = 40; }"
      ": edit_box { key = \"factor\"; label = \"Factor visual positivo:\"; edit_width = 12; }"
      ": popup_list { key = \"rotulo\"; label = \"Rótulo:\"; }"
      ": edit_box { key = \"contenido\"; label = \"Texto / tag:\"; edit_width = 32; edit_limit = 120; }"
      ": text { label = \"Centroide real; puede quedar fuera de un cóncavo.\"; }"
      ": text { key = \"aviso\"; width = 64; }"
      "ok_cancel; }")
    (write-line linea mce:archivo)
  )
  (close mce:archivo)
  (setq mce:archivo nil mce:dcl-id (load_dialog mce:dcl-ruta))
  (if (or (< mce:dcl-id 0) (not (new_dialog "mce_dialog" mce:dcl-id)))
    (mce:fallar "No se pudo abrir el diálogo.")
  )
  (start_list "tipo")
  (foreach linea '("Edificación de 1 nivel" "Edificación de 2 niveles" "Edificación circular (octágono)" "Área verde")
    (add_list linea)
  )
  (end_list)
  (start_list "rotulo")
  (foreach linea '("Sin rótulo" "Texto centrado" "Círculo con tag centrado") (add_list linea))
  (end_list)
  (set_tile "tipo" "0")
  (set_tile "factor" "1")
  (set_tile "rotulo" "0")
  (set_tile "contenido" "")
  (mce:rotulo-ui)
  (action_tile "rotulo" "(mce:rotulo-ui)")
  (action_tile "accept" "(mce:aceptar-ui)")
  (action_tile "cancel" "(done_dialog 0)")
  (setq estado (start_dialog))
  (unload_dialog mce:dcl-id)
  (setq mce:dcl-id nil)
  (= estado 1)
)

(defun mce:plano (p z / w)
  (setq w (trans p 1 0))
  (list (car w) (cadr w) z)
)

(defun mce:puntos (tipo / p q z puntos centro radio i angulo)
  (if (= tipo 2)
    (progn
      (initget 1)
      (setq p (getpoint "\nCentro del octágono: ") centro (trans p 1 0) z (caddr centro))
      (initget 1)
      (setq q (mce:plano (getpoint p "\nPunto para el radio horizontal: ") z)
            radio (distance centro q) i 0)
      (if (<= radio 1e-8) (mce:fallar "El radio horizontal debe ser positivo."))
      (repeat 8
        (setq angulo (+ (/ pi 2.0) (* i (/ pi 4.0)))
              puntos (cons (list (+ (car centro) (* radio (cos angulo)))
                                 (+ (cadr centro) (* radio (sin angulo))) z) puntos)
              i (1+ i))
      )
      (reverse puntos)
    )
    (progn
      (initget 1)
      (setq p (getpoint "\nPrimer vértice del polígono: ")
            q (trans p 1 0) z (caddr q) puntos (list q))
      (while (setq p (getpoint (trans q 0 1) "\nSiguiente vértice <Enter para cerrar>: "))
        (setq q (mce:plano p z) puntos (cons q puntos))
      )
      (setq puntos (reverse puntos))
      (if (and (> (length puntos) 3) (equal (car puntos) (last puntos) 1e-8))
        (setq puntos (reverse (cdr (reverse puntos))))
      )
      puntos
    )
  )
)

(defun mce:cruz (a b c)
  (- (* (- (car b) (car a)) (- (cadr c) (cadr a)))
     (* (- (cadr b) (cadr a)) (- (car c) (car a))))
)

(defun mce:sobre (p a b tol)
  (and (<= (abs (mce:cruz a b p)) (* tol (distance a b)))
       (<= (- (min (car a) (car b)) tol) (car p) (+ (max (car a) (car b)) tol))
       (<= (- (min (cadr a) (cadr b)) tol) (cadr p) (+ (max (cadr a) (cadr b)) tol)))
)

(defun mce:contacto (a b c d tol)
  (or (and (< (* (mce:cruz a b c) (mce:cruz a b d)) 0.0)
           (< (* (mce:cruz c d a) (mce:cruz c d b)) 0.0))
      (mce:sobre a c d tol) (mce:sobre b c d tol)
      (mce:sobre c a b tol) (mce:sobre d a b tol))
)

(defun mce:validar (puntos / n i j a b c d tol extension)
  (setq n (length puntos))
  (if (< n 3) (mce:fallar "Se necesitan al menos tres vértices."))
  (setq extension (max (- (apply 'max (mapcar 'car puntos)) (apply 'min (mapcar 'car puntos)))
                       (- (apply 'max (mapcar 'cadr puntos)) (apply 'min (mapcar 'cadr puntos))))
        tol (max 1e-8 (* extension 1e-10)) i 0)
  (while (< i n)
    (setq a (nth i puntos) b (nth (rem (1+ i) n) puntos)
          c (nth (rem (+ i 2) n) puntos))
    (if (or (<= (distance a b) tol)
            (mce:sobre a b c tol) (mce:sobre c a b tol))
      (mce:fallar "Contorno degenerado: vértices coincidentes o retroceso.")
    )
    (setq j (+ i 2))
    (while (< j n)
      (if (not (and (= i 0) (= j (1- n))))
        (progn
          (setq c (nth j puntos) d (nth (rem (1+ j) n) puntos))
          (if (mce:contacto a b c d tol)
            (mce:fallar "El contorno se cruza o se toca a sí mismo.")
          )
        )
      )
      (setq j (1+ j))
    )
    (setq i (1+ i))
  )
  tol
)

(defun mce:capa (nombre / datos capa)
  (if (setq datos (tblsearch "LAYER" nombre))
    (progn
      (if (or (/= 0 (logand (cdr (assoc 70 datos)) 21))
              (< (cdr (assoc 62 datos)) 0))
        (mce:fallar (strcat "Capa destino apagada, congelada, bloqueada o externa: " nombre))
      )
      (setq capa (vla-Item (vla-get-Layers mce:doc) nombre))
    )
    (progn
      (setq capa (vla-Add (vla-get-Layers mce:doc) nombre)
            mce:capas (cons capa mce:capas))
    )
  )
  nombre
)

(defun mce:poligono (puntos capa / coords matriz obj p)
  ;; Normal +Z: XY de OCS coincide con WCS; elevación explícita, sin UCS.
  (foreach p puntos (setq coords (cons (cadr p) (cons (car p) coords))))
  (setq coords (reverse coords)
        matriz (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length coords)))) )
  (vlax-safearray-fill matriz coords)
  (setq obj (mce:registrar (vla-AddLightWeightPolyline mce:espacio matriz)))
  (vla-put-Normal obj (vlax-3d-point '(0.0 0.0 1.0)))
  (vla-put-Elevation obj (caddr (car puntos)))
  (vla-put-Closed obj :vlax-true)
  (vla-put-Layer obj capa)
  (vla-put-Color obj 256)
  obj
)

(defun mce:medidas (contorno / regiones region centro area)
  ;; REGION temporal: exige una sola superficie; nunca usar promedio de vértices.
  (setq regiones (vlax-safearray->list
                   (vlax-variant-value
                     (vla-AddRegion mce:espacio (mce:vector-objetos (list contorno))))))
  (foreach region regiones (mce:registrar region))
  (if (/= (length regiones) 1) (mce:fallar "El contorno no produce una única región válida."))
  (setq region (car regiones) area (vla-get-Area region) centro (vlax-get region 'Centroid))
  (if (<= area 1e-16) (mce:fallar "La superficie es nula o demasiado pequeña."))
  (if (not (mce:retirar region)) (mce:fallar "No se pudo retirar la región temporal."))
  (list area (list (car centro) (cadr centro) (vla-get-Elevation contorno)))
)

(defun mce:dentro (p puntos / dentro a b)
  (setq a (last puntos))
  (foreach b puntos
    (if (and (not (eq (> (cadr a) (cadr p)) (> (cadr b) (cadr p))))
             (< (car p) (+ (car a) (* (- (cadr p) (cadr a))
                                      (/ (- (car b) (car a)) (- (cadr b) (cadr a)))))))
      (setq dentro (not dentro))
    )
    (setq a b)
  )
  dentro
)

(defun mce:trama (contorno patron escala verde capa / trama)
  (setq trama (mce:registrar (vla-AddHatch mce:espacio 1 patron :vlax-false)))
  ;; AutoCAD exige el bucle exterior antes de consultar/modificar el HATCH.
  (vla-AppendOuterLoop trama (mce:vector-objetos (list contorno)))
  (vla-put-Layer trama capa)
  (vla-put-PatternAngle trama 0.0)
  (vla-put-PatternScale trama escala)
  (vla-put-Elevation trama (vla-get-Elevation contorno))
  (if verde
    (progn
      (setq mce:color (vla-get-TrueColor trama))
      (vla-SetRGB mce:color 22 163 74)
      (vla-put-TrueColor trama mce:color)
    )
    (vla-put-Color trama 256)
  )
  (vla-Evaluate trama)
  trama
)

(defun mce:rotular (centro modo contenido altura capa / circulo texto ancho alto caja radio)
  (if (> modo 0)
    (progn
      ;; TEXT simple, centrado medio en WCS; no se generan códigos MTEXT.
      (setq texto (mce:registrar (vla-AddText mce:espacio contenido (vlax-3d-point centro) altura)))
      (vla-put-StyleName texto (getvar "TEXTSTYLE"))
      (vla-put-Height texto altura)
      (vla-put-Layer texto capa)
      (vla-put-Color texto 256)
      (vla-put-Rotation texto 0.0)
      (vla-put-TextGenerationFlag texto 0)
      (vla-put-Alignment texto 10)
      (vla-put-TextAlignmentPoint texto (vlax-3d-point centro))
      (if (= modo 2)
        (progn
          (setq caja (textbox (entget (vlax-vla-object->ename texto))))
          (if (not caja) (mce:fallar "No se pudo medir el tag."))
          (setq ancho (- (caadr caja) (caar caja))
                alto (- (cadadr caja) (cadar caja))
                radio (max (* altura 1.5) (* 0.6 (sqrt (+ (* ancho ancho) (* alto alto))))))
          (setq circulo (mce:registrar (vla-AddCircle mce:espacio (vlax-3d-point centro) radio)))
          (vla-put-Layer circulo capa)
          (vla-put-Color circulo 256)
        )
      )
    )
  )
)

(defun C:MCELEMENTS (/ *error* mce:doc mce:espacio mce:objetos mce:capas
                       mce:archivo mce:dcl-ruta mce:dcl-id mce:variables mce:color
                       mce:undo mce:motivo mce:opciones tipo factor modo contenido
                       puntos tol capa contorno medidas longitud centro)
  (defun *error* (mensaje)
    (mce:limpiar T)
    (princ (strcat "\nMCELEMENTS: " (if mce:motivo mce:motivo mensaje)))
    (princ)
  )
  (setq mce:doc (vla-get-ActiveDocument (vlax-get-acad-object))
        mce:espacio (if (= (getvar "CVPORT") 1) (vla-get-PaperSpace mce:doc) (vla-get-ModelSpace mce:doc))
        mce:variables (mapcar '(lambda (nombre) (cons nombre (getvar nombre))) '("CMDECHO" "OSMODE")))
  (setvar "CMDECHO" 0)
  ;; OSMODE se conserva durante los clics; no se cambia UCS, CLAYER ni TEXTSTYLE.
  (if (mce:dialogo)
    (progn
      (setq tipo (nth 0 mce:opciones) factor (nth 1 mce:opciones)
            modo (nth 2 mce:opciones) contenido (nth 3 mce:opciones)
            puntos (mce:puntos tipo) tol (mce:validar puntos))
      (if (= 0 (logand (getvar "UNDOCTL") 1))
        (mce:fallar "Active UNDO antes de crear resultados.")
      )
      (if (/= 0 (logand (getvar "UNDOCTL") 8))
        (mce:fallar "Cierre el grupo UNDO existente antes de ejecutar MCELEMENTS.")
      )
      (vla-StartUndoMark mce:doc)
      (setq mce:undo T
            capa (mce:capa (nth tipo '("MC-EDIFICACION-1" "MC-EDIFICACION-2" "MC-EDIFICACION-CIRCULAR" "MC-AREA-VERDE")))
            contorno (mce:poligono puntos capa)
            medidas (mce:medidas contorno)
            longitud (sqrt (car medidas)) centro (cadr medidas))
      (if (<= longitud tol) (mce:fallar "Superficie degenerada para la precisión del dibujo."))
      (mce:trama contorno (nth tipo '("ANSI31" "ANSI37" "ANSI31" "ANSI36"))
                 (* longitud factor 0.02) (= tipo 3) capa)
      (if (and (> modo 0) (not (mce:dentro centro puntos)))
        (princ "\nAviso: el centroide real queda fuera del contorno; se conserva esa posición.")
      )
      (mce:rotular centro modo contenido (* longitud factor 0.04) capa)
      (mce:limpiar nil)
      (princ "\nMCELEMENTS: estructura creada.")
    )
    (progn (mce:limpiar T) (princ "\nMCELEMENTS cancelado."))
  )
  (princ)
)

(princ "\nMCELEMENTS cargado. Escriba MCELEMENTS para iniciar.")
(princ)
