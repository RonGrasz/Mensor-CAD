;;; ============================================================
;;; MCAREA.LSP - Calculadora de Áreas Catastrales para AutoCAD
;;; ============================================================
;;; Requiere: AutoCAD 64-bit con soporte ActiveX/VLA
;;; ============================================================

(vl-load-com) ; Cargar soporte ActiveX/VLA

;;; ============================================================
;;; SECCIÓN 1: GENERACIÓN DEL ARCHIVO DCL TEMPORAL
;;; ============================================================

(defun mcarea:generar-dcl (dcl-path / f)
  "Escribe el archivo DCL temporal en la ruta especificada."
  (setq f (open dcl-path "w"))
  (if (null f)
    (progn (alert "ERROR: No se pudo crear el archivo DCL temporal.") nil)
    (progn
      (write-line "mcarea_dialog : dialog {" f)
      (write-line "  label = \"Comando MCAREA - Cálculo de Áreas\";" f)
      (write-line "  : row {" f)
      ;; Columna Izquierda: Método de Cálculo
      (write-line "    : boxed_radio_column {" f)
      (write-line "      label = \"Método de Cálculo (Normativa)\";" f)
      (write-line "      : radio_button {" f)
      (write-line "        key   = \"rb_estandar\";" f)
      (write-line "        label = \"Estándar (Coordenadas Originales)\";" f)
      (write-line "        value = \"1\";" f)
      (write-line "      }" f)
      (write-line "      : radio_button {" f)
      (write-line "        key   = \"rb_mimp\";" f)
      (write-line "        label = \"MIMP / Mensuras RD (Redondeo 2 dec.)\";" f)
      (write-line "        value = \"0\";" f)
      (write-line "      }" f)
      (write-line "    }" f)
      ;; Columna Derecha: Modo de Selección
      (write-line "    : boxed_radio_column {" f)
      (write-line "      label = \"Modo de Selección\";" f)
      (write-line "      : radio_button {" f)
      (write-line "        key   = \"rb_poligono\";" f)
      (write-line "        label = \"Seleccionar Polígono Existente\";" f)
      (write-line "        value = \"1\";" f)
      (write-line "      }" f)
      (write-line "      : radio_button {" f)
      (write-line "        key   = \"rb_boundary\";" f)
      (write-line "        label = \"Detectar Contorno (Boundary)\";" f)
      (write-line "        value = \"0\";" f)
      (write-line "      }" f)
      (write-line "    }" f)
      (write-line "  }" f)
      ;; Sección: Formato y Estilo
      (write-line "  : boxed_column {" f)
      (write-line "    label = \"Formato y Estilo\";" f)
      (write-line "    : row {" f)
      (write-line "      : text { label = \"Precisión Decimal en Texto:\"; alignment = left; } " f)
      (write-line "      : popup_list {" f)
      (write-line "        key   = \"lst_precision\";" f)
      (write-line "        width = 8;" f)
      (write-line "        value = \"2\";" f)
      (write-line "      }" f)
      (write-line "    }" f)
      (write-line "    : row {" f)
      (write-line "      : text { label = \"Altura de Texto (Unidades):  \"; alignment = left; }" f)
      (write-line "      : edit_box {" f)
      (write-line "        key   = \"eb_altura\";" f)
      (write-line "        value = \"2.5\";" f)
      (write-line "        width = 10;" f)
      (write-line "      }" f)
      (write-line "    }" f)
      (write-line "    : toggle {" f)
      (write-line "      key   = \"ck_sufijo\";" f)
      (write-line "      label = \"Añadir Sufijo (m\\U+00B2)\";" f)
      (write-line "      value = \"1\";" f)
      (write-line "    }" f)
      (write-line "  }" f)
      (write-line "  ok_cancel;" f)
      (write-line "}" f)
      (close f)
      T
    )
  )
)

;;; ============================================================
;;; SECCIÓN 2: FUNCIÓN DE REDONDEO A N DECIMALES
;;; ============================================================

(defun mcarea:redondear (valor decimales / factor)
  "Redondea VALOR algebraicamente a la cantidad de DECIMALES especificada."
  (setq factor (expt 10.0 decimales))
  (/ (float (fix (+ (* valor factor) (if (minusp valor) -0.5 0.5))))
     factor)
)

;;; ============================================================
;;; SECCIÓN 3: FÓRMULA DE GAUSS (SHOELACE) PARA ÁREA
;;; ============================================================

(defun mcarea:shoelace (puntos / n suma i xi yi xi1 yi1)
  "Calcula el área de un polígono usando la Fórmula de Gauss."
  (setq n    (length puntos)
        suma  0.0
        i     0)
  (while (< i n)
    (setq xi  (car  (nth i puntos))
          yi  (cadr (nth i puntos))
          xi1 (car  (nth (rem (1+ i) n) puntos))
          yi1 (cadr (nth (rem (1+ i) n) puntos))
          suma (+ suma (- (* xi yi1) (* xi1 yi)))
          i   (1+ i))
  )
  (/ (abs suma) 2.0)
)

;;; ============================================================
;;; SECCIÓN 4: EXTRACCIÓN DE VÉRTICES DE UNA LWPOLYLINE
;;; ============================================================

(defun mcarea:obtener-vertices (vla-obj / coords puntos i)
  "Extrae la lista de vértices 2D de una LWPOLYLINE (coordenadas OCS)."
  (setq coords (vlax-get vla-obj 'Coordinates)
        puntos '()
        i      0)
  (while (< i (length coords))
    (setq puntos (append puntos (list (list (nth i coords) (nth (1+ i) coords)))))
    (setq i (+ i 2))
  )
  puntos
)

;;; ============================================================
;;; SECCIÓN 5: CÁLCULO DEL CENTROIDE GEOMÉTRICO REAL (CENTRO DE MASA)
;;; ============================================================

(defun mcarea:centroide-verdadero (puntos / n suma-x suma-y suma-a i p1 p2 xi yi xi1 yi1 factor)
  "Calcula el centroide geométrico real de un polígono irregular 2D."
  (setq n      (length puntos)
        suma-x 0.0
        suma-y 0.0
        suma-a 0.0
        i      0)
  (while (< i n)
    (setq p1 (nth i puntos)
          p2 (nth (rem (1+ i) n) puntos)
          xi  (car p1)
          yi  (cadr p1)
          xi1 (car p2)
          yi1 (cadr p2)
          factor (- (* xi yi1) (* xi1 yi))
          suma-x (+ suma-x (* (+ xi xi1) factor))
          suma-y (+ suma-y (* (+ yi yi1) factor))
          suma-a (+ suma-a factor)
          i   (1+ i))
  )
  (if (zerop suma-a)
    ;; Fallback al baricentro de puntos si la superficie es plana/nula
    (list (/ (apply '+ (mapcar 'car puntos)) n)
          (/ (apply '+ (mapcar 'cadr puntos)) n))
    ;; Retorna el centroide geométrico real (OCS)
    (list (/ suma-x (* 3.0 suma-a)) (/ suma-y (* 3.0 suma-a)))
  )
)

;;; ============================================================
;;; SECCIÓN 6: INSERCIÓN DE MTEXT EN EL DIBUJO (CORREGIDA)
;;; ============================================================

(defun mcarea:insertar-mtext (punto texto altura / espacio mtext-obj)
  "Inserta un objeto MTEXT centrado en la capa activa utilizando WCS."
  (setq espacio  (vla-get-modelspace
                   (vla-get-activedocument (vlax-get-acad-object)))
        mtext-obj (vla-addmtext
                    espacio
                    (vlax-3d-point punto)
                    0.0
                    texto))
  (vla-put-height          mtext-obj altura)
  (vla-put-attachmentpoint mtext-obj acAttachmentPointMiddleCenter)
  (vla-put-insertionpoint  mtext-obj (vlax-3d-point punto))
  mtext-obj
)

;;; ============================================================
;;; SECCIÓN 7: VALIDACIÓN DE ENTIDAD LWPOLYLINE CERRADA
;;; ============================================================

(defun mcarea:cerrada-p (vla-obj / raw)
  "Evaluador de la propiedad Closed para LWPOLYLINE."
  (setq raw (vlax-get vla-obj 'Closed))
  (not (zerop raw))
)

(defun mcarea:validar-polilinea (ename / vla-obj tipo)
  "Verifica que la entidad sea una LWPOLYLINE cerrada."
  (if (null ename)
    nil
    (progn
      (setq vla-obj (vlax-ename->vla-object ename)
            tipo    (vla-get-objectname vla-obj))
      (if (wcmatch tipo "AcDbPolyline")
        (if (mcarea:cerrada-p vla-obj)
          vla-obj
          (progn
            (alert "La polilínea seleccionada NO está cerrada.")
            nil)
        )
        (progn
          (alert (strcat "Entidad inválida: " tipo "\nSe requiere una LWPOLYLINE cerrada."))
          nil)
      )
    )
  )
)

;;; ============================================================
;;; SECCIÓN 8: SELECCIÓN POR BOUNDARY (CONTORNO INTERNO)
;;; ============================================================

(defun mcarea:seleccionar-boundary (/ pt ename-antes ename-despues)
  "Ejecuta el comando -BOUNDARY y retorna el ename de la entidad generada."
  (setq pt (getpoint "\nIndique un punto interior del área: "))
  (if (null pt)
    nil
    (progn
      (setq ename-antes (entlast))
      (command "._-BOUNDARY" pt "")
      (setq ename-despues (entlast))

      (if (equal ename-antes ename-despues)
        (progn
          (alert "No se pudo generar un contorno. Verifique que el área esté cerrada.")
          nil)
        ename-despues)
    )
  )
)

;;; ============================================================
;;; SECCIÓN 9: FORMATEO DEL NÚMERO DE ÁREA
;;; ============================================================

(defun mcarea:formatear-area (area decimales sufijo-p / resultado)
  "Formatea el número de área para el texto final."
  (setq resultado (rtos area 2 decimales))
  (if sufijo-p
    (strcat resultado " m\\U+00B2")
    resultado)
)

;;; ============================================================
;;; SECCIÓN 10: LÓGICA PRINCIPAL DEL COMANDO MCAREA
;;; ============================================================

(defun C:MCAREA (/ *error*
                   ;; Variables de estado del diálogo
                   dcl-path dcl-id
                   metodo-mimp seleccion-boundary
                   precision altura-txt sufijo-activo
                   ;; Variables de proceso
                   ename continuar resultado-dlg puntos-redondeados
                   vla-obj puntos area centroide-ocs elev centroide-pt
                   texto-area
                   ;; Variables de restauración de entorno
                   cmd-echo osmode)

  ;;; ----------------------------------------------------------
  ;;; 10.1 MANEJADOR LOCAL DE ERRORES
  ;;; ----------------------------------------------------------
  (defun *error* (msg)
    (if cmd-echo  (setvar "CMDECHO" cmd-echo))
    (if osmode    (setvar "OSMODE"  osmode))
    (if (and dcl-id (>= dcl-id 0)) (unload_dialog dcl-id))
    (if (and dcl-path (findfile dcl-path)) (vl-file-delete dcl-path))
    (if (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*EXIT*"))
      (princ (strcat "\nError en MCAREA: " msg))
    )
    (princ)
  )

  (setq cmd-echo (getvar "CMDECHO")
        osmode   (getvar "OSMODE"))
  (setvar "CMDECHO" 0)

  ;;; ----------------------------------------------------------
  ;;; 10.2 CARGAR DIÁLOGO DCL TEMPORAL
  ;;; ----------------------------------------------------------
  (setq dcl-path (strcat (getvar "TEMPPREFIX") "mcarea_temp.dcl"))
  (if (not (mcarea:generar-dcl dcl-path)) (exit))

  (setq dcl-id (load_dialog dcl-path))
  (if (< dcl-id 0)
    (progn (alert "ERROR: No se pudo cargar el diálogo DCL.") (exit))
  )

  ;;; ----------------------------------------------------------
  ;;; 10.3 BUCLE INTERACTIVO
  ;;; ----------------------------------------------------------
  (setq continuar T)
  (while continuar
    (if (not (new_dialog "mcarea_dialog" dcl-id))
      (progn (alert "ERROR: Estructura DCL no encontrada.") (setq continuar nil))
      (progn
        (start_list "lst_precision")
        (add_list "0 decimales") (add_list "1 decimal") (add_list "2 decimales")
        (add_list "3 decimales") (add_list "4 decimales")
        (end_list)
        (set_tile "lst_precision" "2")
        (set_tile "rb_estandar"  "1")
        (set_tile "rb_poligono"  "1")
        (set_tile "eb_altura"    "2.5")
        (set_tile "ck_sufijo"    "1")

        (action_tile "rb_estandar" "(set_tile \"rb_mimp\" \"0\") (set_tile \"rb_estandar\" \"1\")")
        (action_tile "rb_mimp"     "(set_tile \"rb_estandar\" \"0\") (set_tile \"rb_mimp\" \"1\")")
        (action_tile "rb_poligono" "(set_tile \"rb_boundary\" \"0\") (set_tile \"rb_poligono\" \"1\")")
        (action_tile "rb_boundary" "(set_tile \"rb_poligono\" \"0\") (set_tile \"rb_boundary\" \"1\")")

        (action_tile "accept"
          (strcat
            "(setq metodo-mimp      (= (get_tile \"rb_mimp\") \"1\")"
            "      seleccion-boundary (= (get_tile \"rb_boundary\") \"1\")"
            "      precision         (atoi (get_tile \"lst_precision\"))"
            "      altura-txt        (atof (get_tile \"eb_altura\"))"
            "      sufijo-activo     (= (get_tile \"ck_sufijo\") \"1\"))"
            "(if (or (null altura-txt) (<= altura-txt 0.0))"
            "  (progn (alert \"Altura inválida.\") (setq altura-txt 2.5))"
            "  (done_dialog 1))"
          )
        )
        (action_tile "cancel" "(done_dialog 0)")

        (setq resultado-dlg (start_dialog))

        (cond
          ((= resultado-dlg 0)
           (setq continuar nil)
           (princ "\nComando cancelado."))
          ((= resultado-dlg 1)
           (progn
             (setvar "OSMODE" 0)
             (if (not seleccion-boundary)
               (setq ename (car (entsel "\nSeleccione la LWPOLYLINE cerrada: ")))
               (setq ename (mcarea:seleccionar-boundary))
             )
             (setq vla-obj (mcarea:validar-polilinea ename))
             (if (null vla-obj) (setq continuar T) (setq continuar nil))
           )
          )
        )
      )
    )
  )

  ;;; ----------------------------------------------------------
  ;;; 10.4 CÁLCULO DE ÁREA Y CENTROIDE REAL
  ;;; ----------------------------------------------------------
  (if vla-obj
    (progn
      (setq puntos (mcarea:obtener-vertices vla-obj))

      (if (not metodo-mimp)
        (progn
          (setq area (vla-get-area vla-obj))
          (setq centroide-ocs (mcarea:centroide-verdadero puntos))
          (princ (strcat "\n[Estándar] Área: " (rtos area 2 4) " u²"))
        )
        (progn
          (setq puntos-redondeados
            (mapcar
              (function
                (lambda (p) (list (mcarea:redondear (car p) 2) (mcarea:redondear (cadr p) 2))))
              puntos))
          (setq area (mcarea:shoelace puntos-redondeados))
          (setq centroide-ocs (mcarea:centroide-verdadero puntos-redondeados))
          (princ (strcat "\n[MIMP/RD] Área (Redondeada): " (rtos area 2 4) " u²"))
        )
      )

      ;; Conversión OCS -> WCS global usando la geometría nativa de la polilínea
      (setq elev (vla-get-elevation vla-obj))
      (setq centroide-pt (trans (list (car centroide-ocs) (cadr centroide-ocs) elev) ename 0))

      ;; Inserción del rótulo
      (setq texto-area (mcarea:formatear-area area precision sufijo-activo))
      (mcarea:insertar-mtext centroide-pt texto-area altura-txt)

      (princ (strcat "\nTexto insertado en centroide real WCS: (" 
                     (rtos (car centroide-pt) 2 2) ", " (rtos (cadr centroide-pt) 2 2) ")"))
    )
  )

  ;;; ----------------------------------------------------------
  ;;; 10.5 LIMPIEZA
  ;;; ----------------------------------------------------------
  (if (and dcl-id (>= dcl-id 0)) (unload_dialog dcl-id))
  (if (and dcl-path (findfile dcl-path)) (vl-file-delete dcl-path))
  (setvar "CMDECHO" cmd-echo)
  (setvar "OSMODE"  osmode)
  (princ)
)

(princ "\nMCAREA cargado. Escriba MCAREA para iniciar.")
(princ)