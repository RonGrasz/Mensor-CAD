;;; ============================================================
;;; MCFIX — convierte POLYLINE compatibles a LWPOLYLINE.
;;; Conserva las 2D en su OCS y las 3D horizontales en su cota WCS.
;;; No aplana alturas diferentes ni repara la topología del dibujo.
;;; Requiere AutoCAD Windows con ActiveX. Pruebas manuales positivas.
;;; ============================================================
(vl-load-com)

;;; El estado mcfix-* es local a C:MCFIX (ámbito dinámico de AutoLISP).
(defun mcfix:valor (codigo datos defecto / par)
  (if (setq par (assoc codigo datos)) (cdr par) defecto))

(defun mcfix:omitir (motivo)
  (setq mcfix-motivo motivo)
  (exit))

(defun mcfix:fallar (motivo)
  (setq mcfix-fallo motivo)
  (exit))

(defun mcfix:cancelacion-p (msg)
  (wcmatch (strcase msg) "*CANCEL*,*BREAK*,*ABORT*"))

(defun mcfix:dependencias-p (datos)
  ;; No transferir XDATA, diccionarios ni referencias de reactores/grupos.
  (or (assoc -3 datos) (assoc 102 datos)))

(defun mcfix:propiedades (datos / salida codigo par)
  ;; Explicitar valores por defecto evita heredar color/tipo/grosor actuales.
  (setq salida
    (list (cons 8 (mcfix:valor 8 datos "0"))
          (cons 6 (mcfix:valor 6 datos "BYLAYER"))
          (cons 62 (mcfix:valor 62 datos 256))
          (cons 48 (mcfix:valor 48 datos 1.0))
          (cons 370 (mcfix:valor 370 datos -1))
          (cons 60 (mcfix:valor 60 datos 0))
          (cons 440 (mcfix:valor 440 datos 0))))
  (foreach codigo '(420 430 390 347)
    (if (setq par (assoc codigo datos)) (setq salida (cons par salida))))
  salida)

;;; Registro por vértice: (XY ancho-inicial ancho-final bulge).
(defun mcfix:vertices-lw (datos / salida punto ancho0 ancho1 bulge par)
  (foreach par datos
    (cond
      ((= (car par) 10)
        (if punto (setq salida (cons (list punto ancho0 ancho1 bulge) salida)))
        (setq punto (cdr par) ancho0 0.0 ancho1 0.0 bulge 0.0))
      ((= (car par) 40) (setq ancho0 (cdr par)))
      ((= (car par) 41) (setq ancho1 (cdr par)))
      ((= (car par) 42) (setq bulge (cdr par)))))
  (if punto (setq salida (cons (list punto ancho0 ancho1 bulge) salida)))
  (reverse salida))

(defun mcfix:wcs (vertices elevacion normal)
  (mapcar
    '(lambda (v)
       (trans (list (caar v) (cadar v) elevacion) normal 0))
    vertices))

(defun mcfix:leer (ent / datos flags tipo3d normal elevacion sub vd punto
                         vertices objeto indice ancho0 ancho1 bulge instantaneas)
  (setq datos (entget ent '("*")))
  (if (= (mcfix:valor 0 datos "") "LWPOLYLINE")
    (list 'lista)
    (progn
      (if (mcfix:dependencias-p datos)
        (mcfix:omitir "Tiene XDATA, diccionario o referencias de reactor/grupo."))
      (if (/= 0 (logand 4 (mcfix:valor 70 (tblsearch "LAYER" (cdr (assoc 8 datos))) 0)))
        (mcfix:omitir "La capa está bloqueada."))
      (setq flags (mcfix:valor 70 datos 0) tipo3d (/= 0 (logand flags 8)))
      (if (or (/= 0 (logand flags 118)) (/= 0 (mcfix:valor 75 datos 0)))
        (mcfix:omitir "Es malla/polyface o tiene ajustes curve-fit/spline."))
      (setq normal (if tipo3d '(0.0 0.0 1.0)
                     (mcfix:valor 210 datos '(0.0 0.0 1.0)))
            elevacion (caddr (mcfix:valor 10 datos '(0.0 0.0 0.0)))
            sub (entnext ent) indice 0)
      (if tipo3d
        (if (or (/= 0.0 (mcfix:valor 39 datos 0.0))
                (/= 0.0 (mcfix:valor 40 datos 0.0))
                (/= 0.0 (mcfix:valor 41 datos 0.0)))
          (mcfix:omitir "La POLYLINE 3D tiene grosor o anchos no compatibles."))
        (setq objeto (vlax-ename->vla-object ent)))
      (while (and sub (= (mcfix:valor 0 (setq vd (entget sub '("*"))) "") "VERTEX"))
        (if (or (mcfix:dependencias-p vd)
                (/= (mcfix:valor 70 vd 0) (if tipo3d 32 0)))
          (mcfix:omitir "Un vértice tiene metadatos o banderas no compatibles."))
        (setq punto (cdr (assoc 10 vd)) bulge (mcfix:valor 42 vd 0.0))
        (if (or (/= (length punto) 3) (not (vl-every 'numberp punto)))
          (mcfix:omitir "Un vértice no tiene coordenadas XYZ válidas."))
        (if tipo3d
          (progn
            ;; Comparación estricta: no descartar ni siquiera pequeñas diferencias Z.
            (if vertices
              (if (/= (caddr punto) elevacion)
                (mcfix:omitir "La POLYLINE 3D tiene alturas diferentes; no se aplana."))
              (setq elevacion (caddr punto)))
            (if (or (/= bulge 0.0) (/= 0.0 (mcfix:valor 40 vd 0.0))
                    (/= 0.0 (mcfix:valor 41 vd 0.0)))
              (mcfix:omitir "Un vértice 3D tiene arco o anchos no compatibles."))
            (setq ancho0 0.0 ancho1 0.0))
          ;; GetWidth resuelve los anchos efectivos, incluidos los del encabezado.
          (vla-GetWidth objeto indice 'ancho0 'ancho1))
        (setq vertices (cons (list (list (car punto) (cadr punto)) ancho0 ancho1 bulge) vertices)
              instantaneas (cons vd instantaneas)
              indice (1+ indice) sub (entnext sub)))
      (if (or (null sub) (/= (mcfix:valor 0 vd "") "SEQEND")
              (mcfix:dependencias-p vd))
        (mcfix:omitir "La secuencia de vértices no termina en un SEQEND compatible."))
      (if (< indice 2) (mcfix:omitir "La polilínea tiene menos de dos vértices."))
      (setq vertices (reverse vertices))
      ;; Incluir VERTEX/SEQEND: un cambio en subentidades puede no alterar el encabezado.
      (list 'convertir ent datos vertices elevacion normal (logand flags 129)
            (reverse (cons vd instantaneas))))))

(defun mcfix:datos-nuevos (registro / fuente vertices salida v par)
  (setq fuente (nth 2 registro) vertices (nth 3 registro))
  (foreach v vertices
    (foreach par (list (cons 10 (car v)) (cons 40 (cadr v))
                       (cons 41 (caddr v)) (cons 42 (cadddr v)))
      (setq salida (cons par salida))))
  (append (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity"))
          (mcfix:propiedades fuente)
          (list (cons 67 (mcfix:valor 67 fuente 0))
                (assoc 410 fuente) '(100 . "AcDbPolyline")
                (cons 90 (length vertices)) (cons 70 (nth 6 registro))
                '(43 . 0.0) (cons 38 (nth 4 registro))
                (cons 39 (mcfix:valor 39 fuente 0.0))
                (cons 210 (nth 5 registro)))
          (reverse salida)))

(defun mcfix:comprobar (registro nueva / datos fuente vertices props)
  (setq datos (entget nueva) fuente (nth 2 registro)
        vertices (mcfix:vertices-lw datos) props (mcfix:propiedades fuente))
  (and (= (mcfix:valor 0 datos "") "LWPOLYLINE")
       (equal (assoc 330 fuente) (assoc 330 datos))
       (equal (assoc 410 fuente) (assoc 410 datos))
       (= (mcfix:valor 67 fuente 0) (mcfix:valor 67 datos 0))
       (= (mcfix:valor 90 datos 0) (length (nth 3 registro)))
       (= (mcfix:valor 70 datos 0) (nth 6 registro))
       (= (mcfix:valor 39 fuente 0.0) (mcfix:valor 39 datos 0.0))
       (= (nth 4 registro) (mcfix:valor 38 datos 0.0))
       (equal (nth 5 registro) (mcfix:valor 210 datos '(0.0 0.0 1.0)) 1e-12)
       (equal (nth 3 registro) vertices 1e-12)
       (equal (mcfix:wcs (nth 3 registro) (nth 4 registro) (nth 5 registro))
              (mcfix:wcs vertices (mcfix:valor 38 datos 0.0)
                          (mcfix:valor 210 datos '(0.0 0.0 1.0))) 1e-8)
       (vl-every
         '(lambda (p)
            (if (= (car p) 6)
              (= (strcase (cdr p)) (strcase (mcfix:valor 6 datos "BYLAYER")))
              (equal (cdr p) (mcfix:valor (car p) datos
                                (mcfix:valor (car p) (mcfix:propiedades nil) nil)))))
         props)))

(defun mcfix:fuente-intacta-p (registro / sub)
  (setq sub (cadr registro))
  (and (equal (nth 2 registro) (entget sub '("*")))
       (vl-every
         '(lambda (datos)
            (setq sub (entnext sub))
            (and sub (equal datos (entget sub '("*")))))
         (nth 7 registro))))

(defun mcfix:convertir (registro / fuente nueva)
  (setq fuente (cadr registro))
  (if (not (mcfix:fuente-intacta-p registro))
    (mcfix:fallar "La fuente cambió después de la validación."))
  (if (not (entmake (mcfix:datos-nuevos registro)))
    (mcfix:fallar "AutoCAD no pudo crear la LWPOLYLINE."))
  ;; Registrar el par ANTES de verificar o borrar; entdel es reversible.
  (setq nueva (entlast) mcfix-cambios (cons (cons fuente nueva) mcfix-cambios))
  (if (not (mcfix:comprobar registro nueva))
    (mcfix:fallar "El reemplazo no conserva geometría, propiedades o propietario."))
  (if (not (mcfix:fuente-intacta-p registro))
    (mcfix:fallar "La fuente cambió durante la creación; no se borra."))
  (if (or (null (entdel fuente)) (entget fuente))
    (mcfix:fallar "No se pudo retirar la fuente; se revierte el reemplazo."))
  T)

(defun mcfix:restaurar (par)
  ;; Recuperar primero el original; no retirar su reemplazo si esto falla.
  (if (not (entget (car par)))
    (if (or (null (entdel (car par))) (null (entget (car par))))
      (mcfix:fallar "No se pudo recuperar una POLYLINE original.")))
  (if (entget (cdr par))
    (if (or (null (entdel (cdr par))) (entget (cdr par)))
      (mcfix:fallar "No se pudo retirar una LWPOLYLINE temporal.")))
  T)

(defun mcfix:limpiar (revertir / par resultado fallos)
  (setq fallos 0)
  (if revertir
    (foreach par mcfix-cambios
      (setq resultado (vl-catch-all-apply 'mcfix:restaurar (list par)))
      (if (vl-catch-all-error-p resultado) (setq fallos (1+ fallos)))))
  (foreach par (append mcfix-entorno (if revertir mcfix-puntos-previos))
    (setq resultado (vl-catch-all-apply 'setvar (list (car par) (cdr par))))
    (if (vl-catch-all-error-p resultado) (setq fallos (1+ fallos))))
  (if mcfix-undo
    (progn
      (setq resultado (vl-catch-all-apply 'vla-EndUndoMark (list mcfix-doc)))
      (if (vl-catch-all-error-p resultado) (setq fallos (1+ fallos)))))
  (setq mcfix-undo nil mcfix-cambios nil mcfix-entorno nil mcfix-puntos-previos nil)
  (if (> fallos 0)
    (princ "\nAVISO MCFIX: restauración incompleta. Revise el dibujo y las variables; use UNDO si corresponde."))
  (= fallos 0))

(defun mcfix:aviso (ent estado motivo)
  (princ (strcat "\nMCFIX " estado " [" (mcfix:valor 5 (entget ent) "?") "]: " motivo)))

(defun mcfix:ayuda ()
  (princ "\nMCFIX: Seleccion elige polilíneas; Todo recorre solo el espacio actual.")
  (princ "\nConvierte POLYLINE simples; conserva las LWPOLYLINE y omite Z variables/metadatos.")
  (princ "\nConfigurar puntos es opcional (PDMODE=32, PDSIZE=1). Un UNDO revierte el lote."))

(defun C:MCFIX (/ *error* mcfix-doc mcfix-entorno mcfix-puntos-previos mcfix-undo
                 mcfix-cambios mcfix-motivo mcfix-fallo mcfix-msg alcance espacio filtro ss
                 visual indice ent resultado motivo registros registro anteriores
                 convertidas compatibles omitidas fallidas restaurado)
  (defun *error* (msg / limpio)
    (setq limpio (mcfix:limpiar T))
    (cond
      (mcfix-msg (princ (strcat "\nMCFIX: " mcfix-msg)))
      ((wcmatch (strcase (if msg msg "")) "*CANCEL*,*QUIT*,*EXIT*,*BREAK*,*ABORT*")
        (princ "\nMCFIX cancelado."))
      (T (princ (strcat "\nMCFIX error: " (if msg msg "")))))
    (if limpio (princ " No se conservan cambios de esta ejecución."))
    (princ))
  (setq mcfix-doc (vla-get-ActiveDocument (vlax-get-acad-object))
        mcfix-entorno (mapcar '(lambda (v) (cons v (getvar v))) '("CMDECHO" "OSMODE"))
        convertidas 0 compatibles 0 omitidas 0 fallidas 0)
  (setvar "CMDECHO" 0)
  (princ "\n=== MCFIX: normalización segura de polilíneas ===")
  (setq alcance "Ayuda")
  (while (equal alcance "Ayuda")
    (initget "Seleccion Todo Ayuda")
    (setq alcance (getkword "\nAlcance [Seleccion/Todo/Ayuda] <Seleccion>: "))
    (if (equal alcance "Ayuda") (mcfix:ayuda)))
  ;; En una ventana de un layout, CVPORT>1 indica espacio modelo.
  (setq espacio (if (or (= (getvar "TILEMODE") 1) (> (getvar "CVPORT") 1))
                  "Model" (getvar "CTAB"))
        filtro (list '(0 . "POLYLINE,LWPOLYLINE") (cons 410 espacio)))
  (setq ss (if (equal alcance "Todo") (ssget "_X" filtro) (ssget filtro)))
  (if ss
    (progn
      (initget "Si No")
      (setq visual (equal "Si" (getkword "\nConfigurar puntos: PDMODE=32, PDSIZE=1 [Si/No] <No>: "))
            indice 0)
      ;; Validar todo el lote antes de crear o borrar cualquier entidad.
      (repeat (sslength ss)
        (setq ent (ssname ss indice) mcfix-motivo nil
              resultado (vl-catch-all-apply 'mcfix:leer (list ent)))
        (cond
          (mcfix-motivo
            (setq omitidas (1+ omitidas)) (mcfix:aviso ent "omitida" mcfix-motivo))
          ((vl-catch-all-error-p resultado)
            (if (mcfix:cancelacion-p (vl-catch-all-error-message resultado)) (exit))
            (setq fallidas (1+ fallidas))
            (mcfix:aviso ent "fallida" (vl-catch-all-error-message resultado)))
          ((eq (car resultado) 'lista) (setq compatibles (1+ compatibles)))
          (T (setq registros (cons resultado registros))))
        (setq indice (1+ indice)))
      (if (or registros visual)
        (progn
          (vla-StartUndoMark mcfix-doc)
          (setq mcfix-undo T)
          (foreach registro (reverse registros)
            (setq anteriores mcfix-cambios mcfix-fallo nil
                  resultado (vl-catch-all-apply 'mcfix:convertir (list registro)))
            (if (vl-catch-all-error-p resultado)
              (progn
                (setq motivo (if mcfix-fallo mcfix-fallo (vl-catch-all-error-message resultado)))
                (if (and (null mcfix-fallo) (mcfix:cancelacion-p motivo)) (exit))
                (if (not (eq anteriores mcfix-cambios))
                  (progn
                    (setq restaurado (vl-catch-all-apply 'mcfix:restaurar (list (car mcfix-cambios))))
                    (if (vl-catch-all-error-p restaurado)
                      (progn (setq mcfix-msg "Falló la recuperación de una entidad; se revierte el lote.") (exit)))
                    (setq mcfix-cambios anteriores)))
                (setq fallidas (1+ fallidas))
                (mcfix:aviso (cadr registro) "fallida" motivo))
              (setq convertidas (1+ convertidas))))
          (if visual
            (progn
              (setq mcfix-puntos-previos
                (mapcar '(lambda (v) (cons v (getvar v))) '("PDMODE" "PDSIZE")))
              (setvar "PDMODE" 32) (setvar "PDSIZE" 1.0)))))
      (mcfix:limpiar nil)
      (princ (strcat "\nMCFIX: convertidas " (itoa convertidas)
                     "; ya compatibles " (itoa compatibles) "; omitidas " (itoa omitidas)
                     "; fallidas " (itoa fallidas) "."))
      (if visual (princ "\nPuntos configurados. Use REGEN para actualizar su representación.")))
    (progn (mcfix:limpiar nil) (princ "\nMCFIX: ninguna polilínea seleccionada; sin cambios.")))
  (princ))

(princ "\nMCFIX cargado. Escriba MCFIX para iniciar.")
(princ)
