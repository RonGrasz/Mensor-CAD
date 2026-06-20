;;; ============================================================================
;;; MCTABLE.LSP - Comando de Tabla de Coordenadas UTM para AutoCAD y Civil 3D
;;; ============================================================================

;; ============================================================
;; SECCIÓN 1: ESCRITURA DEL ARCHIVO DCL TEMPORAL
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
      (write-line "    : radio_button { label = \"Horaria (CW)\"; key = \"rb_cw\"; value = \"1\"; }" f)
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

(defun MCTABLE:label-vertices (vlist txt-height layer-name / i pt lbl offset)
  (setq i      1
        offset (* txt-height 1.2))
  (foreach pt vlist
    (setq lbl (itoa i))
    (entmake
      (list
        '(0 . "TEXT")
        (cons 8  layer-name)
        (cons 10 (list (+ (car pt) offset) (+ (cadr pt) offset) 0.0))
        (cons 40 txt-height)
        (cons 1  lbl)
        '(7  . "Standard")
        '(72 . 0)
      )
    )
    (setq i (1+ i))
  )
  (princ (strcat "\n  " (itoa (1- i)) " etiquetas de vértices colocadas."))
)

;; ============================================================
;; SECCIÓN 5: CREACIÓN DE LA TABLA NATIVA DE AUTOCAD
;; ============================================================

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
        cell-align 5 ; acAlignmentMiddleCenter
        ;; [FIX] Aumentamos ligeramente la altura base a 2.2 para evitar conflictos con los márgenes internos
        row-height (* (getvar "TEXTSIZE") 2.2) 
  )

  (setq tbl-obj
    (vla-AddTable space (vlax-3d-point ins-pt) rows cols row-height (* (getvar "TEXTSIZE") 8.0))
  )

  ;; [FIX] Suprimimos la regeneración temporal de la tabla para acelerar el proceso
  (vla-put-RegenerateTableSuppressed tbl-obj :vlax-true)

  (setq actual-rows   (vl-catch-all-apply 'vla-get-Rows (list tbl-obj))
        expected-rows rows)
  (if (and (not (vl-catch-all-error-p actual-rows))
           (> actual-rows expected-rows))
    (vl-catch-all-apply 'vla-DeleteRows
      (list tbl-obj expected-rows (- actual-rows expected-rows)))
  )

  ;; Título
  (vla-SetText tbl-obj 0 0 title-str)
  (vl-catch-all-apply 'vla-MergeCells (list tbl-obj 0 0 0 (1- cols)))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 0 0 cell-align))

  ;; Encabezados
  (vla-SetText tbl-obj 1 0 "EST")
  (vla-SetText tbl-obj 1 1 col1-hdr)
  (vla-SetText tbl-obj 1 2 col2-hdr)
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 0 cell-align))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 1 cell-align))
  (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj 1 2 cell-align))

  ;; Datos
  (setq row-idx 2)
  (foreach v vlist
    ;; [FIX] Eliminado el redondeo manual, usamos directamente rtos que es más seguro y nativo
    (setq xval (car v)
          yval (cadr v))
          
    (vla-SetText tbl-obj row-idx 0 (itoa (- row-idx 1)))
    (if xy-order
      (progn
        (vla-SetText tbl-obj row-idx 1 (rtos xval 2 decimals))
        (vla-SetText tbl-obj row-idx 2 (rtos yval 2 decimals))
      )
      (progn
        (vla-SetText tbl-obj row-idx 1 (rtos yval 2 decimals))
        (vla-SetText tbl-obj row-idx 2 (rtos xval 2 decimals))
      )
    )
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 0 cell-align))
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 1 cell-align))
    (vl-catch-all-apply 'vla-SetCellAlignment (list tbl-obj row-idx 2 cell-align))
    (setq row-idx (1+ row-idx))
  )

  ;; Ajuste de ancho de columnas
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 0 (* (getvar "TEXTSIZE") 5.0)))
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 1 (* (getvar "TEXTSIZE") 16.0)))
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl-obj 2 (* (getvar "TEXTSIZE") 16.0)))

  ;; [FIX] BUCLE PARA FORZAR LA ALTURA CONSTANTE DE TODAS LAS FILAS
  (setq i 0)
  (while (< i rows)
    (vl-catch-all-apply 'vla-SetRowHeight (list tbl-obj i row-height))
    (setq i (1+ i))
  )

  ;; [FIX] Reactivamos la regeneración de la tabla y la actualizamos
  (vla-put-RegenerateTableSuppressed tbl-obj :vlax-false)
  (vla-Update tbl-obj)
  
  (princ "\n  Tabla de coordenadas creada, centrada y uniformizada exitosamente.")
  tbl-obj
)

;; ============================================================
;; SECCIÓN 6: FUNCIÓN PRINCIPAL - COMANDO MCTABLE
;; ============================================================

(defun C:MCTABLE (/
  *error* old-osmode old-cmdecho old-blipmode
  dcl-file dcl-id sel ent ent-type vertices
  opt-cw opt-yx decimals origin-idx ordered-verts
  ins-pt txt-height lyr-etiq click-pt dlg-result start-pt
  lyr-data lyr-ent lyr-ed
)

  (defun *error* (msg)
    (vl-catch-all-apply
      '(lambda ()
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
  (princ "\n=== MCTABLE: Tabla de Coordenadas UTM ===")

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

  (setq opt-cw     nil
        opt-yx     nil
        decimals   2
        origin-idx 0
        click-pt   nil
  )

  (setq dcl-file (strcat (getvar "TEMPPREFIX") "MCTABLE_DLG_TEMP.dcl"))
  (if (not (MCTABLE:write-dcl dcl-file)) (exit))

  (setq dcl-id (load_dialog dcl-file))
  (if (< dcl-id 0) (progn (if (findfile dcl-file) (vl-file-delete dcl-file)) (exit)))

  (if (not (new_dialog "mctable_dlg" dcl-id))
    (progn (unload_dialog dcl-id) (if (findfile dcl-file) (vl-file-delete dcl-file)) (exit))
  )

  (set_tile "rb_ccw"  "1")
  (set_tile "eb_dec"  "2")
  (set_tile "txt_orig"
    (strcat "Vértice 1: (" (rtos (car (car vertices)) 2 2) ", " (rtos (cadr (car vertices)) 2 2) ")")
  )

  (action_tile "rb_ccw"   "(setq opt-cw nil)")
  (action_tile "rb_cw"    "(setq opt-cw T)")
  (action_tile "rb_xy"    "(setq opt-yx nil)")
  (action_tile "rb_yx"    "(setq opt-yx T)")
  (action_tile "eb_dec"   "(setq decimals (atoi (get_tile \"eb_dec\")))(if (or (< decimals 0)(> decimals 8))(progn (set_tile \"eb_dec\" \"2\")(setq decimals 2)))")
  (action_tile "btn_orig" "(done_dialog 2)")
  (action_tile "accept"   "(setq decimals (atoi (get_tile \"eb_dec\")))(done_dialog 1)")
  (action_tile "cancel"   "(done_dialog 0)")

  (setq dlg-result 0)
  (while (= (setq dlg-result (start_dialog)) 2)
    (setvar "OSMODE" 512)
    (setq click-pt (getpoint "\nHaga clic cerca del vértice que desea como Origen (Punto 1): "))

    (if (not (new_dialog "mctable_dlg" dcl-id))
      (setq dlg-result 0)
      (progn
        (if opt-cw (set_tile "rb_cw" "1") (set_tile "rb_ccw" "1"))
        (if opt-yx (set_tile "rb_yx" "1") (set_tile "rb_xy" "1"))
        (set_tile "eb_dec" (itoa decimals))
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
        (action_tile "btn_orig" "(done_dialog 2)")
        (action_tile "accept"   "(setq decimals (atoi (get_tile \"eb_dec\")))(done_dialog 1)")
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

  (princ "\nProcesando matriz geométrica...")
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
    ;; [FIX] tblsearch NO devuelve el ename. Para usar entmod en un layer existente, 
    ;; necesitamos usar tblobjname para obtener la entidad del registro.
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

  (setq txt-height (max (getvar "TEXTSIZE") 0.20))
  (princ "\nDibujando numeración de vértices...")
  (MCTABLE:label-vertices ordered-verts txt-height lyr-etiq)

  (setvar "OSMODE" 0)
  (setq ins-pt (getpoint "\nIndique el punto de inserción para la tabla: "))
  (if (null ins-pt)
    (progn
      (princ "\nPunto inválido. Ejecución abortada.")
      (setvar "OSMODE" old-osmode) (setvar "CMDECHO" old-cmdecho) (setvar "BLIPMODE" old-blipmode)
      (exit)
    )
  )

  (princ "\nConstruyendo tabla nativa...")

  (MCTABLE:create-table
    (list (car ins-pt) (cadr ins-pt) (if (caddr ins-pt) (caddr ins-pt) 0.0))
    ordered-verts
    decimals
    (not opt-yx)
    "COORDENADAS GEORREFERENCIADAS"
  )

  (setvar "OSMODE"   old-osmode)
  (setvar "CMDECHO"  old-cmdecho)
  (setvar "BLIPMODE" old-blipmode)

  (princ "\n\n=== MCTABLE: Proceso completado exitosamente ===\n")
  (princ)
)

(princ "\n» Comando MCTABLE cargado. Escriba MCTABLE para arrancar.")
(princ)