;;; ============================================================
;;; MC-IMPORT.LSP - Importacion de puntos TXT/CSV con simbolos locales
;;; Comando: MCIMPORT | AutoCAD Windows con ActiveX
;;; No modifica PDMODE/PDSIZE ni requiere otros scripts.
;;; ============================================================
(vl-load-com)

(defun mcimport:trim (s)
  (vl-string-trim " \t\r\n" s))

(defun mcimport:fail (msg)
  (princ (strcat "\nMCIMPORT: " msg))
  (exit))

;;; Numeros decimales estrictos: sin unidades, comas ni exponentes.
;;; No se usa READ sobre contenido del archivo.
(defun mcimport:number (s / i n code digits dots valid result)
  (setq s (mcimport:trim s) i 1 n (strlen s)
        digits 0 dots 0 valid T)
  (if (and (> n 0) (member (substr s 1 1) '("+" "-")))
    (setq i 2))
  (while (and valid (<= i n))
    (setq code (ascii (substr s i 1)))
    (cond
      ((and (>= code 48) (<= code 57)) (setq digits (1+ digits)))
      ((= code 46) (setq dots (1+ dots) valid (<= dots 1)))
      (t (setq valid nil)))
    (setq i (1+ i)))
  (if (and valid (> digits 0))
    (progn
      (setq result (vl-catch-all-apply 'distof (list s 2)))
      (if (and (not (vl-catch-all-error-p result)) (numberp result))
        result))))

;;; TrueColor RGB: seis digitos hexadecimales, con # inicial opcional.
;;; Devuelve nil si es invalido; 0 (negro) es un color valido.
(defun mcimport:hex-color (s / i code digit value valid)
  (setq s (strcase (mcimport:trim s)))
  (if (= (substr s 1 1) "#") (setq s (substr s 2)))
  (setq i 1 value 0 valid (= (strlen s) 6))
  (while (and valid (<= i 6))
    (setq code (ascii (substr s i 1))
          digit (cond
                  ((and (>= code 48) (<= code 57)) (- code 48))
                  ((and (>= code 65) (<= code 70)) (- code 55))))
    (if (null digit)
      (setq valid nil)
      (setq value (+ (* value 16) digit)))
    (setq i (1+ i)))
  (if valid value))

;;; CSV de una linea, con campos vacios, comas entre comillas y "".
;;; Devuelve una lista de campos o un mensaje de error.
(defun mcimport:csv (line / i n ch field fields state err)
  (setq i 1 n (strlen line) field "" fields nil state 'start)
  (while (and (<= i n) (not err))
    (setq ch (substr line i 1))
    (cond
      ((eq state 'quoted)
       (if (= ch "\"")
         (if (and (< i n) (= (substr line (1+ i) 1) "\""))
           (setq field (strcat field "\"") i (1+ i))
           (setq state 'after))
         (setq field (strcat field ch))))
      ((= ch ",")
       (setq fields (cons (mcimport:trim field) fields)
             field "" state 'start))
      ((eq state 'after)
       (if (not (member ch '(" " "\t")))
         (setq err "Texto despues del cierre de comillas.")))
      ((and (eq state 'start) (member ch '(" " "\t"))))
      ((= ch "\"")
       (if (eq state 'start)
         (setq state 'quoted)
         (setq err "Comillas dentro de un campo sin entrecomillar.")))
      (t (setq field (strcat field ch) state 'plain)))
    (setq i (1+ i)))
  (cond
    (err err)
    ((eq state 'quoted) "Comillas sin cerrar; no se admiten campos multilinea.")
    (t (reverse (cons (mcimport:trim field) fields)))))

(defun mcimport:strip-bom (line / codes)
  (setq codes (vl-string->list line))
  (cond
    ((equal (car codes) 65279) (substr line 2))
    ((equal (list (car codes) (cadr codes) (caddr codes)) '(239 187 191))
     (substr line 4))
    (t line)))

(defun mcimport:columns (format / i cols)
  (setq i 1)
  (while (<= i (strlen format))
    (setq cols (cons (substr format i 1) cols) i (1+ i)))
  (reverse cols))

;;; Valida TODO el archivo antes de crear entidades. P ausente se numera
;;; consecutivamente; Z ausente es 0; D ausente queda vacia.
(defun mcimport:read-points (path format / cols line fields pairs idx row
                             first err records x y z p d value name)
  (setq cols (mcimport:columns format) idx 0 row 0 first T
        mcimport:input (open path "r"))
  (if (not mcimport:input)
    (list nil "No se pudo abrir el archivo para lectura.")
    (progn
      (while (and (not err) (setq line (read-line mcimport:input)))
        (setq row (1+ row))
        (if (= row 1) (setq line (mcimport:strip-bom line)))
        (if (/= (mcimport:trim line) "")
          (progn
            (setq fields (mcimport:csv line))
            (cond
              ((eq (type fields) 'STR) (setq err fields))
              ((/= (length fields) (length cols))
               (setq err (strcat "Se esperaban " (itoa (length cols))
                                " campos para " format ".")))
              ((and first (equal (mapcar 'strcase fields) cols))
               (setq first nil))
              (t
               (setq first nil pairs (mapcar 'cons cols fields)
                     x nil y nil z 0.0)
               (foreach name '("E" "N" "Z")
                 (if (assoc name pairs)
                   (progn
                     (setq value (mcimport:number (cdr (assoc name pairs))))
                     (if (null value)
                       (setq err (strcat "Coordenada " name " invalida."))
                       (cond
                         ((= name "E") (setq x value))
                         ((= name "N") (setq y value))
                         (t (setq z value)))))))
               (setq p (if (assoc "P" pairs) (cdr (assoc "P" pairs))
                         (itoa (1+ idx)))
                     d (if (assoc "D" pairs) (cdr (assoc "D" pairs)) ""))
               (cond
                 ((= p "") (setq err "El numero de punto P esta vacio."))
                 ((or (> (strlen p) 255) (> (strlen d) 255))
                  (setq err "P y D admiten hasta 255 caracteres cada uno.")))
               (if (not err)
                 (setq idx (1+ idx)
                       records (cons (list (list x y z) p d) records))))))))
      (close mcimport:input)
      (setq mcimport:input nil)
      (cond
        (err (list nil (strcat "Linea " (itoa row) ": " err)))
        ((not records) (list nil "El archivo no contiene puntos."))
        (t (list (reverse records) nil))))))

;;; Entidades independientes en WCS, en la capa actual y con el color elegido.
;;; El mismo color se aplica al simbolo y a todas sus etiquetas.
;;; La lista de limpieza pertenece solo a la invocacion actual.
(defun mcimport:make (data / ent)
  (if (not (entmake (append data (list (cons 8 mcimport:layer))
                           mcimport:color-data)))
    (mcimport:fail "No se pudo crear una entidad de la importacion."))
  (setq ent (entlast)
        mcimport:created (cons ent mcimport:created)
        mcimport:point-entities (cons ent mcimport:point-entities))
  ent)

;;; Un GROUP seleccionable por registro, sin mezclar puntos cercanos.
;;; El handle evita depender de identificadores P repetidos o no validos
;;; como nombres. Si el nombre ya existe, no se modifica ese grupo.
(defun mcimport:group-point (/ objects array collection dictionary base name suffix group
                              group-ename group-data)
  (if mcimport:point-entities
    (progn
      (setq objects (mapcar 'vlax-ename->vla-object mcimport:point-entities)
            array (vlax-make-safearray vlax-vbObject
                    (cons 0 (1- (length objects))))
            collection (vla-get-Groups mcimport:doc)
            dictionary (cdr (assoc -1 (dictsearch (namedobjdict) "ACAD_GROUP")))
            base (strcat "MCIMPORT_" (vla-get-Handle (car objects)))
            name base suffix 0)
      (while (and dictionary (dictsearch dictionary name))
        (setq suffix (1+ suffix) name (strcat base "_" (itoa suffix))))
      (vlax-safearray-fill array objects)
      (setq group (vla-Add collection name)
            mcimport:groups-created (cons group mcimport:groups-created))
      ;; Registrar antes de AppendItems: tambien se limpia si este falla.
      (vla-AppendItems group (vlax-make-variant array))
      ;; AcadGroup ActiveX no expone Selectable. GROUP usa DXF 71 = 1.
      ;; Este codigo corre en el comando, nunca en un callback de reactor.
      (setq group-ename (vlax-vla-object->ename group)
            group-data (entget group-ename))
      (if (not (equal (assoc 71 group-data) '(71 . 1)))
        (progn
          (if (or (not (assoc 71 group-data))
                  (not (entmod (subst '(71 . 1) (assoc 71 group-data) group-data))))
            (mcimport:fail "No se pudo activar la seleccion del grupo de punto."))
          (if (not (equal (assoc 71 (entget group-ename)) '(71 . 1)))
            (mcimport:fail "El grupo de punto no quedo seleccionable.")))))))

(defun mcimport:line (a b)
  (mcimport:make (list '(0 . "LINE") (cons 10 a) (cons 11 b))))

(defun mcimport:offset (p dx dy)
  (list (+ (car p) dx) (+ (cadr p) dy) (caddr p)))

(defun mcimport:marker (p mode r / base outer a b c d dot)
  (setq base (rem mode 32) outer (- mode base)
        a (mcimport:offset p (- r) (- r))
        b (mcimport:offset p r (- r))
        c (mcimport:offset p r r)
        d (mcimport:offset p (- r) r))
  (cond
    ((= base 0)
     ;; El punto se representa por un pequeno SOLID, no un POINT global.
     (setq dot (* r 0.08))
     (mcimport:make
       (list '(0 . "SOLID")
             (cons 10 (mcimport:offset p (- dot) (- dot)))
             (cons 11 (mcimport:offset p dot (- dot)))
             (cons 12 (mcimport:offset p (- dot) dot))
             (cons 13 (mcimport:offset p dot dot)) '(210 0.0 0.0 1.0))))
    ((= base 2)
     (mcimport:line (mcimport:offset p (- r) 0.0) (mcimport:offset p r 0.0))
     (mcimport:line (mcimport:offset p 0.0 (- r)) (mcimport:offset p 0.0 r)))
    ((= base 3) (mcimport:line a c) (mcimport:line b d))
    ((= base 4) (mcimport:line p (mcimport:offset p 0.0 r))))
  (if (member outer '(32 96))
    (mcimport:make (list '(0 . "CIRCLE") (cons 10 p) (cons 40 r)
                        '(210 0.0 0.0 1.0))))
  (if (member outer '(64 96))
    (progn (mcimport:line a b) (mcimport:line b c)
           (mcimport:line c d) (mcimport:line d a))))

(defun mcimport:text (p s h)
  (mcimport:make
    (list '(0 . "TEXT") (cons 10 p) (cons 40 h) (cons 1 s)
          (cons 7 mcimport:style) '(50 . 0.0) '(41 . 1.0)
          '(51 . 0.0) '(71 . 0) '(72 . 0) '(73 . 0)
          '(210 0.0 0.0 1.0))))

;;; Previsualizacion DCL del mismo estilo local (20 combinaciones).
(defun mcimport:preview (index / mode base outer w h cx cy r i ang x y px py)
  (setq mode (nth (atoi index) mcimport:modes) base (rem mode 32)
        outer (- mode base) w (dimx_tile "preview") h (dimy_tile "preview")
        cx (fix (/ w 2)) cy (fix (/ h 2)) r (fix (/ (min w h) 3)))
  (start_image "preview")
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
      (setq i 0 px (+ cx r) py cy)
      (repeat 32
        (setq i (1+ i) ang (* 2.0 pi (/ i 32.0))
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

(defun mcimport:write-dcl (path / lines line)
  (setq mcimport:dcl-file (open path "w"))
  (if mcimport:dcl-file
    (progn
      (setq lines
        '("mcimport_dialog : dialog { label = \"Importar puntos\";"
          ": column {"
          ": boxed_column { label = \"Archivo TXT / CSV separado por comas\";"
          ": edit_box { key = \"path\"; label = \"Archivo:\"; edit_width = 52; edit_limit = 2048; }"
          ": button { key = \"browse\"; label = \"Buscar archivo...\"; }"
          ": popup_list { key = \"format\"; label = \"Formato de puntos:\"; edit_width = 20; }"
          "}"
          ": boxed_column { label = \"Simbolos independientes (estilos DDPTYPE)\";"
          ": row { : popup_list { key = \"mode\"; label = \"Tipo:\"; edit_width = 30; }"
          ": image { key = \"preview\"; width = 10; height = 4; fixed_width = true; fixed_height = true; color = -2; } }"
          "}"
          ": boxed_column { label = \"Color del simbolo y las etiquetas\";"
          ": popup_list { key = \"color\"; label = \"Color:\"; edit_width = 24; }"
          ": edit_box { key = \"hex\"; label = \"HEX (#RRGGBB):\"; edit_width = 12; edit_limit = 32; }"
          ": text { label = \"Elija Personalizado HEX para ingresar un color RGB.\"; }"
          "}"
          ": boxed_column { label = \"Etiquetas y tamano (unidades del dibujo)\";"
          ": toggle { key = \"showp\"; label = \"Colocar numero de punto\"; }"
          ": toggle { key = \"showd\"; label = \"Colocar descripcion\"; }"
          ": edit_box { key = \"size\"; label = \"Altura de texto / radio del simbolo:\"; edit_width = 12; }"
          "}"
          "errtile; ok_cancel; } }"))
      (foreach line lines (write-line line mcimport:dcl-file))
      (close mcimport:dcl-file)
      (setq mcimport:dcl-file nil)
      T)))

(defun mcimport:save-dialog ()
  (setq mcimport:path (get_tile "path")
        mcimport:format-index (atoi (get_tile "format"))
        mcimport:mode-index (atoi (get_tile "mode"))
        mcimport:showp (get_tile "showp") mcimport:showd (get_tile "showd")
        mcimport:color-index (atoi (get_tile "color"))
        mcimport:hex-raw (get_tile "hex")
        mcimport:size-raw (get_tile "size")))

(defun mcimport:color-controls ()
  (mode_tile "hex" (if (= (atoi (get_tile "color")) 8) 0 1)))

(defun mcimport:accept (/ ext size mode rgb)
  (mcimport:save-dialog)
  (setq mcimport:path (mcimport:trim mcimport:path)
        ext (vl-filename-extension mcimport:path)
        size (mcimport:number mcimport:size-raw)
        mode (nth mcimport:mode-index mcimport:modes)
        rgb (if (= mcimport:color-index 8)
              (mcimport:hex-color mcimport:hex-raw)))
  (cond
    ((or (null ext) (not (member (strcase ext) '(".TXT" ".CSV"))))
     (set_tile "error" "Seleccione un archivo .txt o .csv."))
    ((not (findfile mcimport:path))
     (set_tile "error" "El archivo no existe o no es accesible."))
    ((or (null size) (<= size 0.0))
     (set_tile "error" "La altura / radio debe ser un numero positivo."))
    ((and (= mode 1) (= mcimport:showp "0") (= mcimport:showd "0"))
     (set_tile "error" "El tipo invisible necesita al menos una etiqueta."))
    ((and (= mcimport:color-index 8) (null rgb))
     (set_tile "error" "HEX invalido: use seis digitos 0-9/A-F, con # opcional."))
    (t
     ;; DXF 420 guarda RRGGBB; tiene prioridad sobre el indice ACI 62.
     (setq mcimport:size size
           mcimport:color-data
             (if (= mcimport:color-index 8)
               (list '(62 . 256) (cons 420 rgb))
               (list (cons 62 (if (= mcimport:color-index 0)
                               256 mcimport:color-index)))))
     (done_dialog 1))))

(defun mcimport:dialog (/ result picked names outer base)
  (setq names nil)
  (foreach outer '("" "Circulo + " "Cuadrado + " "Circulo y cuadrado + ")
    (foreach base '("Punto" "Sin marca central" "Cruz +" "Cruz X" "Trazo vertical")
      (setq names (cons (strcat outer base) names))))
  (setq result 2)
  (while (= result 2)
    (if (not (new_dialog "mcimport_dialog" mcimport:dcl-id))
      (mcimport:fail "No se pudo abrir el dialogo MCIMPORT."))
    (start_list "format") (mapcar 'add_list mcimport:formats) (end_list)
    (start_list "mode") (mapcar 'add_list (reverse names)) (end_list)
    (start_list "color")
    (mapcar 'add_list '("Por capa" "Rojo" "Amarillo" "Verde" "Cian" "Azul"
                       "Magenta" "Blanco / negro (ACI 7)" "Personalizado HEX"))
    (end_list)
    (set_tile "color" (itoa mcimport:color-index))
    (set_tile "hex" mcimport:hex-raw)
    (mcimport:color-controls)
    (action_tile "color" "(mcimport:color-controls)")
    (set_tile "path" mcimport:path)
    (set_tile "format" (itoa mcimport:format-index))
    (set_tile "mode" (itoa mcimport:mode-index))
    (set_tile "showp" mcimport:showp) (set_tile "showd" mcimport:showd)
    (set_tile "size" mcimport:size-raw)
    (mcimport:preview (itoa mcimport:mode-index))
    (action_tile "mode" "(mcimport:preview $value)")
    (action_tile "browse" "(mcimport:save-dialog) (done_dialog 2)")
    (action_tile "accept" "(mcimport:accept)")
    (action_tile "cancel" "(done_dialog 0)")
    (setq result (start_dialog))
    (if (= result 2)
      (progn
        (setq picked (getfiled "Importar puntos TXT / CSV" mcimport:path "txt;csv" 0))
        (if picked (setq mcimport:path picked)))))
  (= result 1))

(defun mcimport:safe (fn args / result)
  (setq result (vl-catch-all-apply fn args))
  (if (vl-catch-all-error-p result)
    (progn
      (princ (strcat "\nMCIMPORT: revise la limpieza/restauracion: "
                     (vl-catch-all-error-message result)))
      nil)
    T))

(defun mcimport:cleanup (rollback / ent group)
  (if mcimport:input
    (progn (mcimport:safe 'close (list mcimport:input)) (setq mcimport:input nil)))
  (if mcimport:dcl-file
    (progn (mcimport:safe 'close (list mcimport:dcl-file)) (setq mcimport:dcl-file nil)))
  (if rollback
    (progn
      ;; Borrar solo los GROUP propios antes de retirar sus miembros.
      (foreach group mcimport:groups-created
        (mcimport:safe 'vla-Delete (list group)))
      (foreach ent mcimport:created
        (mcimport:safe '(lambda (e) (vla-Delete (vlax-ename->vla-object e))) (list ent)))))
  (foreach group mcimport:groups-created
    (mcimport:safe 'vlax-release-object (list group)))
  (setq mcimport:created nil mcimport:point-entities nil mcimport:groups-created nil)
  (if mcimport:undo
    (progn (mcimport:safe 'vla-EndUndoMark (list mcimport:doc))
           (setq mcimport:undo nil)))
  (if (and mcimport:dcl-id (> mcimport:dcl-id 0))
    (mcimport:safe 'unload_dialog (list mcimport:dcl-id)))
  (setq mcimport:dcl-id nil)
  (if (and mcimport:dcl-path (findfile mcimport:dcl-path))
    (mcimport:safe 'vl-file-delete (list mcimport:dcl-path)))
  (setq mcimport:dcl-path nil)
  (mcimport:safe 'setvar (list "OSMODE" mcimport:old-osmode))
  (mcimport:safe 'setvar (list "CMDECHO" mcimport:old-cmdecho)))

;;; Zoom solo a lo creado, usando las cajas reales (incluidas etiquetas).
;;; ZoomWindow de ActiveX recibe coordenadas WCS, no puntos del UCS.
(defun mcimport:zoom (/ ent obj lo hi a b lower upper dx dy pad center)
  (foreach ent mcimport:created
    (setq obj (vlax-ename->vla-object ent))
    (vla-GetBoundingBox obj 'lo 'hi)
    (setq a (vlax-safearray->list lo) b (vlax-safearray->list hi))
    (if lower
      (setq lower (mapcar 'min lower a) upper (mapcar 'max upper b))
      (setq lower a upper b)))
  (setq dx (- (car upper) (car lower)) dy (- (cadr upper) (cadr lower))
        pad (* 0.1 (max dx dy (* 2.0 mcimport:size)))
        lower (mcimport:offset lower (- pad) (- pad))
        upper (mcimport:offset upper pad pad)
        center (/ (+ (caddr lower) (caddr upper)) 2.0))
  (vla-ZoomWindow mcimport:app
    (vlax-3d-point (list (car lower) (cadr lower) center))
    (vlax-3d-point (list (car upper) (cadr upper) center))))

(defun C:MCIMPORT (/ *error* mcimport:old-osmode mcimport:old-cmdecho
                     mcimport:app mcimport:doc mcimport:undo mcimport:created
                     mcimport:point-entities mcimport:groups-created
                     mcimport:input mcimport:dcl-file mcimport:dcl-path mcimport:dcl-id
                     mcimport:path mcimport:formats mcimport:modes
                     mcimport:format-index mcimport:mode-index mcimport:showp
                     mcimport:showd mcimport:size-raw mcimport:size
                     mcimport:color-index mcimport:hex-raw mcimport:color-data
                     mcimport:layer mcimport:style result records record p labelpos
                     mode labels zoom-result layer-data)
  (setq mcimport:old-osmode (getvar "OSMODE")
        mcimport:old-cmdecho (getvar "CMDECHO"))
  (defun *error* (msg)
    (mcimport:cleanup T)
    (if (and msg (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*BREAK*,*ABORT*")))
      (princ (strcat "\nMCIMPORT: " msg)))
    (princ))
  (setq mcimport:app (vlax-get-acad-object)
        mcimport:doc (vla-get-ActiveDocument mcimport:app)
        mcimport:layer (getvar "CLAYER") mcimport:style (getvar "TEXTSTYLE")
        mcimport:formats '("ENZ" "NEZ" "PENZ" "PNEZ" "PENZD" "PNEZD" "PEN" "PNE"
                            "EN" "NE" "END" "NED" "ENZD" "NEZD" "PEND" "PNED")
        mcimport:modes '(0 1 2 3 4 32 33 34 35 36 64 65 66 67 68 96 97 98 99 100)
        mcimport:path "" mcimport:format-index 5 mcimport:mode-index 7
        mcimport:showp "1" mcimport:showd "1" mcimport:size-raw "1.0"
        mcimport:color-index 2 mcimport:hex-raw "#FF0000")
  (setvar "CMDECHO" 0)
  (setq mcimport:dcl-path (vl-filename-mktemp "MC-IMPORT-" nil ".dcl"))
  (if (not (mcimport:write-dcl mcimport:dcl-path))
    (mcimport:fail "No se pudo escribir el archivo DCL temporal."))
  (setq mcimport:dcl-id (load_dialog mcimport:dcl-path))
  (if (or (null mcimport:dcl-id) (< mcimport:dcl-id 0))
    (mcimport:fail "No se pudo cargar el archivo DCL temporal."))
  (if (mcimport:dialog)
    (progn
      (setq result (mcimport:read-points mcimport:path
                       (nth mcimport:format-index mcimport:formats)))
      (if (cadr result)
        (alert (strcat "MCIMPORT: " (cadr result) "\nNo se importo ningun punto."))
        (progn
          (setq records (car result) mode (nth mcimport:mode-index mcimport:modes)
                labels 0 layer-data (tblsearch "LAYER" mcimport:layer))
          (if (/= 0 (logand 4 (cdr (assoc 70 layer-data))))
            (mcimport:fail "La capa actual esta bloqueada. Desbloqueela antes de importar."))
          (if (and (= mode 1)
                   (not (vl-some
                     '(lambda (rec)
                        (or (= mcimport:showp "1")
                            (and (= mcimport:showd "1") (/= (caddr rec) "")))) records)))
            (mcimport:fail "El estilo invisible y las etiquetas elegidas no generan salida."))
          (vla-StartUndoMark mcimport:doc)
          (setq mcimport:undo T)
          (foreach record records
            (setq p (car record) mcimport:point-entities nil)
            (mcimport:marker p mode mcimport:size)
            (setq labelpos (mcimport:offset p (* mcimport:size 1.35)
                                             (* mcimport:size 0.35)))
            (if (= mcimport:showp "1")
              (progn
                (mcimport:text labelpos (cadr record) mcimport:size)
                (setq labels (1+ labels)
                      labelpos (mcimport:offset labelpos 0.0 (* mcimport:size -1.4)))))
            (if (and (= mcimport:showd "1") (/= (caddr record) ""))
              (progn (mcimport:text labelpos (caddr record) mcimport:size)
                     (setq labels (1+ labels))))
            (mcimport:group-point))
          (vla-Regen mcimport:doc 1)
          ;; Un fallo de zoom no elimina una importacion ya completada.
          (setq zoom-result (vl-catch-all-apply 'mcimport:zoom nil))
          (if (vl-catch-all-error-p zoom-result)
            (if (wcmatch (strcase (vl-catch-all-error-message zoom-result))
                         "*CANCEL*,*QUIT*,*BREAK*,*ABORT*")
              (exit)
              (princ "\nMCIMPORT: puntos creados; no se pudo ajustar la vista automaticamente.")))
          (princ (strcat "\nMCIMPORT: " (itoa (length records)) " puntos importados, "
                         (itoa labels) " etiquetas TEXT y "
                         (itoa (length mcimport:groups-created)) " grupos creados."))
          (if (= 0 (logand 1 (getvar "PICKSTYLE")))
            (princ "\nPara seleccionar cada punto completo, active grupos con PICKSTYLE = 1 o 3."))))))
  (mcimport:cleanup nil)
  (princ))

(princ "\nMCIMPORT cargado. Escriba MCIMPORT para iniciar.")
(princ)
