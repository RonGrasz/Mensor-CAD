;;; ============================================================
;;; MC-HELP.LSP - Información de MensorCAD
;;; Requiere: AutoCAD 64-bit con soporte ActiveX/VLA
;;; ============================================================

(vl-load-com)

(defun mchelp:limpiar (archivo dcl-id ruta)
  ;; Liberar recursos incluso si la generación o la carga del DCL falla.
  (if archivo
    (vl-catch-all-apply 'close (list archivo)))
  (if (and dcl-id (>= dcl-id 0))
    (vl-catch-all-apply 'unload_dialog (list dcl-id)))
  (if (and ruta (findfile ruta))
    (vl-catch-all-apply 'vl-file-delete (list ruta)))
  (princ))

(defun C:MCHELP (/ *error* archivo dcl-id ruta linea resultado version repositorio apertura)
  (defun *error* (mensaje)
    (mchelp:limpiar archivo dcl-id ruta)
    (if (and mensaje (not (wcmatch (strcase mensaje) "*CANCEL*,*QUIT*,*EXIT*")))
      (princ (strcat "\nError en MCHELP: " mensaje)))
    (princ))

  ;; Información de presentación; no depende de Git ni de otros scripts.
  (setq version "v0.1.0"
        repositorio "https://github.com/RonGrasz/Mensor-CAD"
        ruta (vl-filename-mktemp "mchelp_" nil ".dcl"))
  (if (null ruta)
    (progn (alert "No se pudo obtener una ruta temporal para MCHELP.") (exit)))
  (setq archivo (open ruta "w"))
  (if (null archivo)
    (progn (alert "No se pudo crear el archivo DCL de MCHELP.") (exit)))

  (foreach linea
    '("mchelp_dialog : dialog {"
      "  label = \"MensorCAD™\";"
      "  : column {"
      "    : text { label = \"Herramientas para AutoCAD orientadas a trabajos\"; }"
      "    : text { label = \"topográficos y catastrales.\"; }"
      "    spacer;"
      "    : text { key = \"version\"; width = 56; }"
      "    : text { label = \"Autor: Ronny Garcia Guzman\"; }"
      "    spacer;"
      "    : boxed_column {"
      "      label = \"Repositorio\";"
      "      : text { key = \"repositorio\"; width = 56; }"
      "    }"
      "    spacer;"
      "    : row {"
      "      : button { key = \"abrir\"; label = \"Abrir repositorio\"; fixed_width = true; }"
      "      : button { key = \"cerrar\"; label = \"Cerrar\"; is_default = true; is_cancel = true; fixed_width = true; }"
      "    }"
      "  }"
      "}")
    (write-line linea archivo))
  (close archivo)
  (setq archivo nil
        dcl-id (load_dialog ruta))
  (if (< dcl-id 0)
    (progn (alert "No se pudo cargar el diálogo de MCHELP.") (exit)))
  (if (not (new_dialog "mchelp_dialog" dcl-id))
    (progn (alert "No se encontró la definición del diálogo de MCHELP.") (exit)))

  (set_tile "version" (strcat "Versión: " version))
  (set_tile "repositorio" repositorio)
  (action_tile "abrir" "(done_dialog 2)")
  (action_tile "cerrar" "(done_dialog 0)")
  (setq resultado (start_dialog))
  (mchelp:limpiar archivo dcl-id ruta)
  (setq archivo nil dcl-id nil ruta nil)

  ;; Abrir la URL fija fuera del callback y después de liberar el DCL.
  (if (= resultado 2)
    (progn
      (setq apertura
        (vl-catch-all-apply 'startapp (list "explorer.exe" repositorio)))
      (if (or (vl-catch-all-error-p apertura) (null apertura))
        (alert (strcat "No se pudo abrir el navegador. Abra este enlace manualmente:\n"
                       repositorio)))))
  (princ))

(princ "\nMCHELP cargado. Escriba MCHELP para iniciar.")
(princ)
