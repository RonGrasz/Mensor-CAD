;;; ============================================================
;;; MCEXPORTEX.lsp
;;; Herramienta híbrida de extracción de coordenadas desde
;;; polígonos (LWPOLYLINE) o textos (TEXT / MTEXT) en AutoCAD.
;;;
;;; Comando: MCEXPORTEX
;;; ============================================================

(vl-load-com)

;;; ============================================================
;;; FUNCIÓN PRINCIPAL
;;; ============================================================
(defun C:MCEXPORTEX (/ *error*
                        dcl-file  dcl-id
                        modo      direccion
                        decimales formato
                        sel-poly  pt-origen
                        sel-texts
                        estado-dlg
                        osmode-orig cmdecho-orig)

  ;; ----------------------------------------------------------
  ;; 1. MANEJADOR DE ERRORES LOCAL
  ;; ----------------------------------------------------------
  (defun *error* (msg)
    (if osmode-orig  (setvar "OSMODE"  osmode-orig))
    (if cmdecho-orig (setvar "CMDECHO" cmdecho-orig))
    
    (if (and dcl-id (>= dcl-id 0))
      (progn
        (done_dialog 0)
        (unload_dialog dcl-id)
      )
    )
    (if (and dcl-file (findfile dcl-file))
      (vl-file-delete dcl-file)
    )
    (if (and msg (not (member msg '("Function cancelled" "quit / exit abort"))))
      (princ (strcat "\nError: " msg))
    )
    (princ)
  )

  ;; ----------------------------------------------------------
  ;; 2. VARIABLES DE SISTEMA ORIGINALES
  ;; ----------------------------------------------------------
  (setq osmode-orig  (getvar "OSMODE")
        cmdecho-orig (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)

  ;; ----------------------------------------------------------
  ;; 3. VALORES INICIALES DE CONTROLES DCL
  ;; ----------------------------------------------------------
  (setq modo      "poly"   
        direccion "cw"    
        decimales "2"      
        formato   "txt"    
        sel-poly  nil
        sel-texts nil
        pt-origen nil)

  ;; ----------------------------------------------------------
  ;; 4. CREACIÓN DEL ARCHIVO .DCL TEMPORAL
  ;; ----------------------------------------------------------
  (setq dcl-file (vl-filename-mktemp "extract_coords" nil ".dcl"))
  (ECT:escribir-dcl dcl-file)

  ;; ----------------------------------------------------------
  ;; 5. CARGAR EL DIÁLOGO
  ;; ----------------------------------------------------------
  (setq dcl-id (load_dialog dcl-file))
  (if (< dcl-id 0)
    (progn
      (alert "No se pudo cargar el diálogo DCL.")
      (*error* nil)
      (exit)
    )
  )

  ;; ----------------------------------------------------------
  ;; 6. BUCLE PRINCIPAL DEL DIÁLOGO
  ;; ----------------------------------------------------------
  (setq estado-dlg 1) 

  (while (= estado-dlg 1)

    (if (not (new_dialog "extract_coords_dlg" dcl-id))
      (progn
        (alert "No se pudo inicializar el diálogo.")
        (*error* nil)
        (exit)
      )
    )

    (ECT:inicializar-controles modo direccion decimales formato
                               sel-poly sel-texts)

    (action_tile "rb_poly" "(setq modo \"poly\") (ECT:actualizar-modo modo)")
    (action_tile "rb_text" "(setq modo \"text\") (ECT:actualizar-modo modo)")
    (action_tile "rb_cw"  "(setq direccion \"cw\")")
    (action_tile "rb_ccw" "(setq direccion \"ccw\")")
    (action_tile "eb_decimales" "(setq decimales $value)")
    (action_tile "rb_txt" "(setq formato \"txt\")")
    (action_tile "rb_csv" "(setq formato \"csv\")")
    (action_tile "btn_seleccionar" "(done_dialog 10)")
    (action_tile "accept" "(done_dialog 1)")
    (action_tile "cancel" "(done_dialog 0)")

    (setq estado-dlg (start_dialog))

    (cond
      ((= estado-dlg 10)
       (ECT:seleccionar-en-modelo modo 'sel-poly 'pt-origen 'sel-texts)
       (setq estado-dlg 1) 
      )

      ((= estado-dlg 1)
       (ECT:ejecutar-exportacion modo    direccion
                                 decimales formato
                                 sel-poly  pt-origen
                                 sel-texts)
       (setq estado-dlg 0) 
      )

      (t
       (princ "\nOperación cancelada.")
       (setq estado-dlg 0)
     )
    )
  ) 

  ;; ----------------------------------------------------------
  ;; 7. LIMPIEZA FINAL
  ;; ----------------------------------------------------------
  (unload_dialog dcl-id)
  (if (findfile dcl-file)
    (vl-file-delete dcl-file)
  )

  (setvar "OSMODE"  osmode-orig)
  (setvar "CMDECHO" cmdecho-orig)

  (princ)
)

;;; ============================================================
;;; ECT:ESCRIBIR-DCL
;;; ============================================================
(defun ECT:escribir-dcl (ruta-dcl / f)
  (setq f (open ruta-dcl "w"))
  (foreach linea
    '(
      "extract_coords_dlg : dialog {"
      "  label = \"Extractor de Coordenadas\";"
      "  width = 54;"
      "  : boxed_radio_column {"
      "    label = \"Modo de Operación\";"
      "    : radio_button { key = \"rb_poly\"; label = \"Polígono (LWPOLYLINE)\"; value = \"1\"; }"
      "    : radio_button { key = \"rb_text\"; label = \"Texto (TEXT / MTEXT)\"; }"
      "  }"
      "  : boxed_column {"
      "    key  = \"box_dir\";"
      "    label = \"Dirección del Polígono\";"
      "    : radio_button { key = \"rb_ccw\"; label = \"Antihoraria (CCW)\"; }"
      "    : radio_button { key = \"rb_cw\";  label = \"Horaria (CW)\"; value = \"1\"; }"
      "  }"
      "  : boxed_row {"
      "    label = \"Precisión Decimal\";"
      "    : text   { label = \"Decimales:\"; }"
      "    : edit_box { key = \"eb_decimales\"; value = \"2\"; edit_width = 4; }"
      "  }"
      "  : boxed_radio_row {"
      "    label = \"Formato de Exportación\";"
      "    : radio_button { key = \"rb_txt\"; label = \".TXT  (tabulado)\"; value = \"1\"; }"
      "    : radio_button { key = \"rb_csv\"; label = \".CSV  (comas)\"; }"
      "  }"
      "  : button {"
      "    key     = \"btn_seleccionar\";"
      "    label   = \"  Seleccionar Origen / Entidades...  \";"
      "    is_default = false;"
      "  }"
      "  : text { key = \"lbl_estado\"; label = \"Sin selección.\"; alignment = centered; }"
      "  ok_cancel;"
      "}"
     )
    (write-line linea f)
  )
  (close f)
)

;;; ============================================================
;;; ECT:INICIALIZAR-CONTROLES
;;; ============================================================
(defun ECT:inicializar-controles (modo direccion decimales formato
                                   sel-poly sel-texts / lbl)
  (set_tile "rb_poly" (if (= modo "poly") "1" "0"))
  (set_tile "rb_text" (if (= modo "text") "1" "0"))

  (ECT:actualizar-modo modo)

  (set_tile "rb_ccw" (if (= direccion "ccw") "1" "0"))
  (set_tile "rb_cw"  (if (= direccion "cw")  "1" "0"))

  (set_tile "eb_decimales" decimales)

  (set_tile "rb_txt" (if (= formato "txt") "1" "0"))
  (set_tile "rb_csv" (if (= formato "csv") "1" "0"))

  (setq lbl
    (cond
      ((and (= modo "poly") sel-poly)
       (strcat "Polígono seleccionado: "
               (vla-get-Handle (vlax-ename->vla-object sel-poly))))
      ((and (= modo "text") sel-texts (> (sslength sel-texts) 0))
       (strcat (itoa (sslength sel-texts)) " texto(s) seleccionado(s)."))
      (t "Sin selección.")
    )
  )
  (set_tile "lbl_estado" lbl)
)

;;; ============================================================
;;; ECT:ACTUALIZAR-MODO
;;; ============================================================
(defun ECT:actualizar-modo (modo)
  (mode_tile "box_dir" (if (= modo "poly") 0 1))
  (mode_tile "rb_ccw"  (if (= modo "poly") 0 1))
  (mode_tile "rb_cw"   (if (= modo "poly") 0 1))
)

;;; ============================================================
;;; ECT:SELECCIONAR-EN-MODELO
;;; ============================================================
(defun ECT:seleccionar-en-modelo (modo sym-poly sym-pt sym-texts 
                                   / ent edatos tipo cerrada ss pt-click listo)
  (cond
    ((= modo "poly")
     (setq ent nil listo nil)
     (while (not listo)
       (princ "\nSelecciona una LWPOLYLINE cerrada [Presiona ENTER/ESC para volver]: ")
       (setq ent (car (entsel)))
       (if ent
         (progn
           (setq edatos (entget ent)
                 tipo   (cdr (assoc 0 edatos))
                 cerrada (logand (cdr (assoc 70 edatos)) 1))
           (if (and (= tipo "LWPOLYLINE") (= cerrada 1))
             (setq listo t)
             (alert "Selección inválida.\nDebe ser una LWPOLYLINE cerrada.")
           )
         )
         (setq listo t) 
       )
     )
     (set sym-poly ent)

     (if ent
       (progn
         (princ "\nHaz clic cerca del vértice que será el Punto 1 (origen): ")
         (setq pt-click (getpoint))
         (set sym-pt pt-click)
       )
     )
    )

    ((= modo "text")
     (princ "\nSelecciona los textos mediante una ventana/arrastre: ")
     (setq ss (ssget '((0 . "TEXT,MTEXT"))))
     (set sym-texts ss)
    )
  )
)

;;; ============================================================
;;; ECT:EJECUTAR-EXPORTACION
;;; ============================================================
(defun ECT:ejecutar-exportacion (modo      direccion
                                  decimales formato
                                  sel-poly  pt-origen
                                  sel-texts
                                  / prec vertexes lineas)

  (setq prec (atoi decimales))
  (if (or (< prec 0) (> prec 8)) (setq prec 2))

  (cond
    ((= modo "poly")
     (if (not sel-poly)
       (alert "No hay ninguna LWPOLYLINE seleccionada.")
       (progn
         (setq vertexes (ECT:obtener-vertices sel-poly))
         (if pt-origen
           (setq vertexes (ECT:reordenar-vertices vertexes pt-origen))
         )
         (setq vertexes (ECT:ajustar-direccion vertexes direccion))
         (setq lineas (ECT:formatear-vertices vertexes prec formato))
         (ECT:guardar-archivo lineas formato)
       )
     )
    )

    ((= modo "text")
     (if (or (not sel-texts) (= (sslength sel-texts) 0))
       (alert "No hay textos seleccionados.")
       (progn
         (setq lineas (ECT:procesar-textos sel-texts formato prec))
         (ECT:guardar-archivo lineas formato)
       )
     )
    )
  )
)

;;; ============================================================
;;; ECT:OBTENER-VERTICES
;;; ============================================================
(defun ECT:obtener-vertices (ename / edatos pts par)
  (setq edatos (entget ename)
        pts    '())
  (foreach par edatos
    (if (= (car par) 10)
      (setq pts (append pts (list (cdr par))))
    )
  )
  pts
)

;;; ============================================================
;;; ECT:REORDENAR-VERTICES
;;; ============================================================
(defun ECT:reordenar-vertices (pts pt-click / idx-min dist-min i dist vx vy cx cy)
  (setq idx-min 0
        dist-min 1e38
        i        0
        cx       (car  pt-click)
        cy       (cadr pt-click))

  (foreach v pts
    (setq vx   (car  v)
          vy   (cadr v)
          dist (sqrt (+ (* (- vx cx) (- vx cx))
                        (* (- vy cy) (- vy cy)))))
    (if (< dist dist-min)
      (setq dist-min dist
            idx-min  i)
    )
    (setq i (1+ i))
  )

  (append (ECT:nthcdr idx-min pts)
          (ECT:firstn idx-min pts))
)

;;; Utilidad para saltar N elementos
(defun ECT:nthcdr (n lst)
  (while (and (> n 0) lst)
    (setq lst (cdr lst)
          n (1- n))
  )
  lst
)

;;; Utilidad para tomar primeros N elementos
(defun ECT:firstn (n lst / res)
  (setq res '())
  (while (and (> n 0) lst)
    (setq res (append res (list (car lst)))
          lst (cdr lst)
          n   (1- n))
  )
  res
)

;;; ============================================================
;;; ECT:CALCULAR-AREA-SIGNO
;;; ============================================================
(defun ECT:calcular-area-signo (pts / suma n i p1 p2)
  (setq suma 0.0
        n    (length pts))
  (setq i 0)
  (while (< i n)
    (setq p1  (nth i pts)
          p2  (nth (rem (1+ i) n) pts)
          suma (+ suma (- (* (car p1) (cadr p2))
                          (* (car p2) (cadr p1)))))
    (setq i (1+ i))
  )
  (* 0.5 suma)
)

;;; ============================================================
;;; ECT:AJUSTAR-DIRECCION
;;; ============================================================
(defun ECT:ajustar-direccion (pts dir-usuario / area-signo dir-actual cola-inv)
  (setq area-signo (ECT:calcular-area-signo pts)
        dir-actual  (if (> area-signo 0.0) "ccw" "cw"))

  (if (not (= dir-actual dir-usuario))
    (progn
      (setq cola-inv (reverse (cdr pts)))
      (setq pts (cons (car pts) cola-inv))
    )
  )
  pts
)

;;; ============================================================
;;; ECT:FORMATEAR-VERTICES
;;; ============================================================
(defun ECT:formatear-vertices (pts prec fmt / lineas n v xs ys)
  (setq lineas   '()
        n        1)
  (if (= fmt "txt")
    (setq lineas (list "\tx\ty"))
  )

  (foreach v pts
    (setq xs (rtos (car  v) 2 prec)
          ys (rtos (cadr v) 2 prec))
    (setq lineas
      (append lineas
        (list
          (if (= fmt "txt")
            (strcat (itoa n) "\t" xs "\t" ys)
            (strcat (itoa n) "," ys "," xs)
          )
        )
      )
    )
    (setq n (1+ n))
  )
  lineas
)

;;; ============================================================
;;; ECT:PROCESAR-TEXTOS
;;; ============================================================
(defun ECT:procesar-textos (ss fmt prec / n total idx ent edatos pt pts lineas xs ys)
  (setq total (sslength ss)
        idx 0
        pts '())
  
  (repeat total
    (setq ent (ssname ss idx)
          edatos (entget ent)
          pt (cdr (assoc 10 edatos)) 
    )
    (setq pts (cons pt pts))
    (setq idx (1+ idx))
  )

  (setq pts (vl-sort pts '(lambda (a b) (> (cadr a) (cadr b)))))

  (setq lineas '()
        n 1)
  (if (= fmt "txt")
    (setq lineas (list "\tx\ty"))
  )

  (foreach v pts
    (setq xs (rtos (car v) 2 prec)
          ys (rtos (cadr v) 2 prec))
    (setq lineas
      (append lineas
        (list
          (if (= fmt "txt")
            (strcat (itoa n) "\t" xs "\t" ys)
            (strcat (itoa n) "," ys "," xs)
          )
        )
      )
    )
    (setq n (1+ n))
  )
  lineas
)

;;; ============================================================
;;; ECT:GUARDAR-ARCHIVO EN TXT O CSV (FORMATO PARA EL MÓDULO DE INGRESO DE MENSURAS PARA PARCELAS v4.0.1.)
;;; ============================================================
(defun ECT:guardar-archivo (lineas fmt / ext titulo filename f)
  (setq ext   fmt
        titulo (strcat "Guardar exportación de coordenadas (." ext ")"))

  (setq filename (getfiled titulo "" ext 1))

  (if filename
    (progn
      (setq f (open filename "w"))
      (if f 
        (progn
          (foreach linea lineas
            (write-line linea f)
          )
          (close f)
          (princ (strcat "\nArchivo guardado con éxito en: " filename))
        )
        (alert (strcat "Error de Escritura:\nNo se pudo escribir en el archivo.\n"
                       "Asegúrate de que no esté abierto en otro programa."))
      )
    )
    (princ "\nGuardado cancelado.")
  )
)

(princ "\nComando cargado exitosamente. Ejecuta: MCEXPORTEX")
(princ)