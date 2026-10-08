;;; ============================================================================
;;; MC-COORD.LSP - Tabla de coordenadas UTM vinculada a un punto
;;; Comando: MCCOORD
;;; Requiere: AutoCAD de 64 bits con ActiveX/VLA habilitado (vl-load-com)
;;; ============================================================================
;;;
;;; Crea una TABLE nativa de 3x3 con el titulo COORDENADAS UTM 19 NORTE, los
;;; encabezados ESTE/NORTE/ALTURA y los valores X/Y/Z del punto seleccionado;
;;; ademas crea una LINE anclada al punto original cuyo extremo sigue a la
;;; tabla cuando esta se mueve (MOVE o pinzamientos).
;;;
;;; Notas y limitaciones:
;;;   - No realiza conversion geodesica. El dibujo ya debe estar en el CRS
;;;     previsto (por defecto se rotula UTM zona 19 Norte).
;;;   - La LINE se actualiza al terminar/cancelar el comando, no durante el
;;;     arrastre en vivo del pinzamiento.
;;;   - El extremo de origen queda fijo con el punto capturado (instantanea);
;;;     si la geometria de origen cambia despues, la tabla no se recalcula.
;;;   - Copias, rotaciones y escalados de la tabla no se reasocian de forma
;;;     garantizada; el caso soportado es el desplazamiento (MOVE).
;;;   - Los callbacks de reactor usan unicamente ActiveX: no ejecutan command,
;;;     entget, entmod, handent ni ssget.

(vl-load-com)

;;; ----------------------------------------------------------------------------
;;; SECCION 0: ESTADO GLOBAL DEL COMANDO
;;; ----------------------------------------------------------------------------

(setq *mccoord-app*   "MCCOORD")
(setq *mccoord-pairs* nil)   ; lista de (tabla-vla linea-vla punto-origen)
(setq *mccoord-busy*  nil)   ; guarda anti-recursion de callbacks
(setq *mccoord-dirty* nil)   ; los reactores de tabla marcan cambios

;;; ----------------------------------------------------------------------------
;;; SECCION 1: UTILIDADES ACTIVEX PURAS (seguras dentro de callbacks)
;;; ----------------------------------------------------------------------------

;; Normaliza list / VARIANT / SAFEARRAY a un triple numerico (x y z) o nil.
;; vlax-get suele devolver la lista; vla-get-* puede devolver VARIANT/SAFEARRAY.
(defun mccoord:to-point (v / r)
  (cond
    ((null v) nil)
    ((and (listp v)
          (numberp (car v)) (numberp (cadr v)) (numberp (caddr v)))
     (list (car v) (cadr v) (caddr v)))
    (T
     (setq r (vl-catch-all-apply 'vlax-variant-value (list v)))
     (if (vl-catch-all-error-p r) (setq r v))
     (setq r (vl-catch-all-apply 'vlax-safearray->list (list r)))
     (if (and (not (vl-catch-all-error-p r))
              (listp r)
              (numberp (car r)) (numberp (cadr r)) (numberp (caddr r)))
       (list (car r) (cadr r) (caddr r))
       nil))))

;; Verdadero solo para un triple numerico (no cualquier valor).
(defun mccoord:point-p (p)
  (and (listp p)
       (numberp (car p)) (numberp (cadr p)) (numberp (caddr p))))

;; Verdadero si el objeto VLA existe y no esta borrado.
(defun mccoord:alive-p (obj / r)
  (if (null obj)
    nil
    (progn
      (setq r (vl-catch-all-apply 'vlax-erased-p (list obj)))
      (and (not (vl-catch-all-error-p r)) (not r)))))

;; Lee una propiedad de tipo punto como triple numerico o nil.
(defun mccoord:safe-point (obj prop / v)
  (setq v (vl-catch-all-apply 'vlax-get (list obj prop)))
  (if (vl-catch-all-error-p v)
    nil
    (mccoord:to-point v)))

;; Ejecuta una lista de operaciones (fn . args); T solo si todas funcionaron.
(defun mccoord:all-critical (ops / fail)
  (setq fail nil)
  (foreach op ops
    (if (vl-catch-all-error-p (vl-catch-all-apply (car op) (cdr op)))
      (setq fail T)))
  (not fail))

;;; ----------------------------------------------------------------------------
;;; SECCION 2: XDATA PERSISTENTE (solo fuera de callbacks)
;;; ----------------------------------------------------------------------------

(defun mccoord:ensure-app ()
  (if (not (tblsearch "APPID" *mccoord-app*))
    (vl-catch-all-apply 'regapp (list *mccoord-app*)))
  *mccoord-app*)

;; Construye la lista XDATA: handle del par + punto original (1010, WCS).
(defun mccoord:coord-items (handle orig)
  (list (cons 1005 handle)
        (list 1010 (car orig) (cadr orig) (caddr orig))))

(defun mccoord:item-handle (items)
  (cdr (assoc 1005 items)))

(defun mccoord:item-point (items / p)
  (setq p (assoc 1010 items))
  (if p (cdr p) nil))

;; Quita solo la entrada de la propia aplicacion (reemplazo, no duplicado).
(defun mccoord:strip-own (apps)
  (if apps
    (vl-remove-if '(lambda (a) (equal *mccoord-app* (car a))) apps)
    nil))

;; Escribe XDATA preservando otras aplicaciones. Devuelve T solo si entmod
;; acepto el cambio Y la metadata quedo verificable.
(defun mccoord:set-xdata (ent items / ed old rec res)
  (mccoord:ensure-app)
  (setq ed  (entget ent)
        old (assoc -3 ed)
        ;; Cada aplicacion va directamente en el cdr del grupo -3.
        rec (cons -3 (cons (cons *mccoord-app* items)
                           (mccoord:strip-own (if old (cdr old) nil)))))
  (if old
    (setq ed (subst rec old ed))
    (setq ed (append ed (list rec))))
  (setq res (entmod ed))
  (and res (mccoord:xdata-matches ent items)))

(defun mccoord:xdata-matches (ent items / got)
  (setq got (mccoord:get-xdata ent))
  (and got
       (equal (mccoord:item-handle got) (mccoord:item-handle items))
       (equal (mccoord:item-point got)  (mccoord:item-point items))))

;; Devuelve los items XDATA del comando para una entidad, o nil.
(defun mccoord:get-xdata (ent / ed rec)
  (setq ed  (entget ent (list *mccoord-app*))
        rec (assoc -3 ed))
  (if rec
    (cdr (assoc *mccoord-app* (cdr rec)))
    nil))

;;; ----------------------------------------------------------------------------
;;; SECCION 3: REACTORES, CALLBACKS Y SINCRONIZACION
;;; ----------------------------------------------------------------------------

(defun mccoord:our-p (r / d)
  (setq d (vl-catch-all-apply 'vlr-data (list r)))
  (and (not (vl-catch-all-error-p d))
       (listp d)
       (equal *mccoord-app* (car d))))

;; vlr-reactors devuelve grupos ((tipo reactor...)...): iterar el cdr de cada
;; grupo y eliminar solo los reactores propios (evita duplicados al recargar).
(defun mccoord:remove-own-reactors ( / groups grp r)
  (foreach ty '(:vlr-object-reactor :vlr-command-reactor)
    (setq groups (vl-catch-all-apply 'vlr-reactors (list ty)))
    (if (not (vl-catch-all-error-p groups))
      (foreach grp groups
        (if (listp grp)
          (foreach r (cdr grp)
            (if (mccoord:our-p r)
              (vl-catch-all-apply 'vlr-remove (list r))))))))
  (princ))

;; Observa solo la tabla; :vlr-modifyUndone cubre UNDO/REDO marcando sucio.
(defun mccoord:attach-table-reactor (tbl tbl-h line-h)
  (vlr-object-reactor (list tbl)
    (list *mccoord-app* tbl-h line-h)
    '((:vlr-modified     . mccoord:object-event)
      (:vlr-erased       . mccoord:object-event)
      (:vlr-unerased     . mccoord:object-event)
      (:vlr-modifyUndone . mccoord:object-event))))

(defun mccoord:ensure-command-reactor ()
  (vlr-command-reactor (list *mccoord-app*)
    '((:vlr-commandEnded     . mccoord:command-event)
      (:vlr-commandCancelled . mccoord:command-event)
      (:vlr-commandFailed    . mccoord:command-event))))

;; Reactor de objeto: solo marca "sucio". No accede al dibujo por entidades.
(defun mccoord:object-event (owner reactor args / res)
  (if (not *mccoord-busy*)
    (progn
      (setq *mccoord-busy* T)
      (setq res (vl-catch-all-apply '(lambda () (setq *mccoord-dirty* T)) nil))
      (setq *mccoord-busy* nil)))
  (princ))

;; Reactor de comandos: sincroniza las LINE por ActiveX. La guarda siempre se
;; libera aunque sync-lines falle (catch externo).
(defun mccoord:command-event (reactor args / res)
  (if (and (not *mccoord-busy*) *mccoord-dirty*)
    (progn
      (setq *mccoord-busy* T
            *mccoord-dirty* nil)
      (setq res (vl-catch-all-apply 'mccoord:sync-lines nil))
      (setq *mccoord-busy* nil)))
  (princ))

;; Ajusta la LINE al punto de insercion de la tabla. Solo ActiveX; evita
;; escrituras si los extremos ya coinciden. El origen guardado no se reescribe.
(defun mccoord:sync-lines ( / pair tbl line orig ins cs ce)
  (foreach pair *mccoord-pairs*
    (setq tbl  (car pair)
          line (cadr pair)
          orig (caddr pair))
    (if (and (mccoord:alive-p tbl) (mccoord:alive-p line))
      (progn
        (setq ins (mccoord:safe-point tbl 'InsertionPoint))
        (if ins
          (progn
            (setq cs (mccoord:safe-point line 'StartPoint)
                  ce (mccoord:safe-point line 'EndPoint))
            (if (not (and cs ce
                          (equal cs orig 1e-6)
                          (equal ce ins  1e-6)))
              (vl-catch-all-apply
                '(lambda ()
                   (vla-put-StartPoint line (vlax-3d-point orig))
                   (vla-put-EndPoint   line (vlax-3d-point ins)))
                nil)))))))
  (princ))

;;; ----------------------------------------------------------------------------
;;; SECCION 4: FORMATEO DE LA TABLE
;;; ----------------------------------------------------------------------------

;; Valor con tres decimales fijos (DIMZIN ya esta forzado a 0 en el comando).
(defun mccoord:fmt (v)
  (rtos v 2 3))

;; Titulo, combinacion, encabezados y valores son criticos: si alguno falla
;; devuelve nil para que el comando limpie las entidades incompletas.
;; Dimensiones/alineacion/altura de texto son mejor esfuerzo.
(defun mccoord:format-table (tbl textsize x y z / row-h col-w)
  ;; Holgura para coordenadas UTM largas, incluso con cuatro decimales.
  ;; La salida numerica conserva los tres decimales de mccoord:fmt.
  (setq row-h (* textsize 2.2)
        col-w (* textsize 16.0))
  (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl :vlax-true))
  (if (not (mccoord:all-critical
             (list (cons 'vla-SetText   (list tbl 0 0 "COORDENADAS UTM 19 NORTE"))
                   (cons 'vla-MergeCells (list tbl 0 0 0 2))
                   (cons 'vla-SetText   (list tbl 1 0 "ESTE"))
                   (cons 'vla-SetText   (list tbl 1 1 "NORTE"))
                   (cons 'vla-SetText   (list tbl 1 2 "ALTURA"))
                   (cons 'vla-SetText   (list tbl 2 0 (mccoord:fmt x)))
                   (cons 'vla-SetText   (list tbl 2 1 (mccoord:fmt y)))
                   (cons 'vla-SetText   (list tbl 2 2 (mccoord:fmt z))))))
    nil
    (progn
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl 0 0 5))
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl 1 0 5))
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl 1 1 5))
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl 1 2 5))
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl 2 0 5))
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl 2 1 5))
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl 2 2 5))
      (vl-catch-all-apply 'vla-SetColumnWidth (list tbl 0 col-w))
      (vl-catch-all-apply 'vla-SetColumnWidth (list tbl 1 col-w))
      (vl-catch-all-apply 'vla-SetColumnWidth (list tbl 2 col-w))
      (vl-catch-all-apply 'vla-SetRowHeight (list tbl 0 (* row-h 1.4)))
      (vl-catch-all-apply 'vla-SetRowHeight (list tbl 1 row-h))
      (vl-catch-all-apply 'vla-SetRowHeight (list tbl 2 row-h))
      ;; SetTextHeight(RowTypes, Height): 1 titulo, 2 encabezado, 4 datos -> 7.
      (vl-catch-all-apply 'vla-SetTextHeight (list tbl 7 textsize))
      (vl-catch-all-apply 'vla-put-RegenerateTableSuppressed (list tbl :vlax-false))
      (vl-catch-all-apply 'vla-Update (list tbl))
      T)))

;; Espacio de edicion activo correcto segun TILEMODE/CVPORT.
(defun mccoord:active-space (doc / cv)
  (if (= 1 (getvar "TILEMODE"))
    (vla-get-ModelSpace doc)
    (progn
      (setq cv (getvar "CVPORT"))
      (if (and cv (> cv 1))
        (vla-get-ModelSpace doc)
        (vla-get-PaperSpace doc)))))

;;; ----------------------------------------------------------------------------
;;; SECCION 5: RECONEXION DE REACTORES (carga y arranque del comando)
;;; ----------------------------------------------------------------------------

;; Valida una tabla con XDATA propia: linea LINE viva, handles reciprocos y
;; punto de origen coincidente. Devuelve (tabla linea origen handle-tabla
;; handle-linea) o nil. Rechaza metadatos malformados; no usa valores de rescate.
(defun mccoord:scan-table (ent / tdata orig lh tbl-h line-ent ldata back lpt)
  (setq tdata (mccoord:get-xdata ent)
        orig  (mccoord:item-point tdata)
        lh    (mccoord:item-handle tdata)
        tbl-h (cdr (assoc 5 (entget ent))))
  (if (and lh (mccoord:point-p orig) tbl-h)
    (progn
      (setq line-ent (vl-catch-all-apply 'handent (list lh)))
      (if (or (vl-catch-all-error-p line-ent) (null line-ent))
        nil
        (progn
          (setq ldata (mccoord:get-xdata line-ent)
                back  (mccoord:item-handle ldata)
                lpt   (mccoord:item-point ldata))
          (if (and (equal (cdr (assoc 0 (entget line-ent))) "LINE")
                   (equal back tbl-h)
                   (mccoord:point-p lpt)
                   (equal lpt orig 1e-6)
                   (mccoord:alive-p (vlax-ename->vla-object line-ent)))
            (list (vlax-ename->vla-object ent)
                  (vlax-ename->vla-object line-ent)
                  orig
                  tbl-h
                  lh)
            nil))))))

;; Escanea el dibujo y reconstruye pares validos. Cada par se procesa de forma
;; aislada: un handle obsoleto no aborta la inicializacion completa.
(defun mccoord:reconnect ( / ss n i ent pair lh claimed)
  (mccoord:ensure-app)
  (mccoord:remove-own-reactors)
  (setq *mccoord-pairs* nil
        *mccoord-dirty* nil
        *mccoord-busy*  nil
        claimed         nil)
  (setq ss (vl-catch-all-apply
             'ssget (list "X" '((0 . "ACAD_TABLE") (-3 ("MCCOORD"))))))
  (if (vl-catch-all-error-p ss) (setq ss nil))
  (if ss
    (progn
      (setq n (sslength ss) i 0)
      (while (< i n)
        (setq ent  (ssname ss i)
              pair (vl-catch-all-apply 'mccoord:scan-table (list ent)))
        (if (and (not (vl-catch-all-error-p pair)) pair)
          (progn
            (setq lh (nth 4 pair))
            (if (not (member lh claimed))
              (progn
                (setq claimed (cons lh claimed))
                (mccoord:attach-table-reactor (car pair) (nth 3 pair) lh)
                (setq *mccoord-pairs*
                      (cons (list (car pair) (cadr pair) (caddr pair))
                            *mccoord-pairs*))))))
        (setq i (1+ i)))))
  (mccoord:ensure-command-reactor)
  ;; Reconstruir extremos de LINE existentes (recarga/reapertura) fuera de
  ;; callbacks, sin reescribir el origen guardado. La guarda se libera siempre.
  (setq *mccoord-busy* T)
  (vl-catch-all-apply 'mccoord:sync-lines nil)
  (setq *mccoord-busy* nil)
  (princ))

;;; ----------------------------------------------------------------------------
;;; SECCION 6: COMANDO PRINCIPAL MCCOORD
;;; ----------------------------------------------------------------------------

(defun C:MCCOORD ( / *error* old-osmode old-cmdecho old-dimzin
                    doc space src-ucs src-wcs ins-ucs ins-wcs textsize
                    tbl-obj line-obj tbl-ent line-ent tbl-h line-h
                    undo-result undo-started completed m)

  ;; *error* es local a este comando: aislado y autorrestaurado al salir.
  (defun *error* (msg)
    (setq m (if msg (strcase msg) ""))
    (if (and line-obj (not completed) (mccoord:alive-p line-obj))
      (vl-catch-all-apply 'vla-delete (list line-obj)))
    (if (and tbl-obj (not completed) (mccoord:alive-p tbl-obj))
      (vl-catch-all-apply 'vla-delete (list tbl-obj)))
    (if (and undo-started doc)
      (progn
        (vl-catch-all-apply 'vla-EndUndoMark (list doc))
        (setq undo-started nil)))
    (if old-osmode  (setvar "OSMODE"  old-osmode))
    (if old-cmdecho (setvar "CMDECHO" old-cmdecho))
    (if old-dimzin  (setvar "DIMZIN"  old-dimzin))
    (setq *mccoord-busy* nil)
    (if (not (member m '("FUNCTION CANCELLED" "QUIT / EXIT ABORT" "")))
      (princ (strcat "\nMCCOORD error: " (if msg msg ""))))
    (princ))

  (setq old-osmode  (getvar "OSMODE")
        old-cmdecho (getvar "CMDECHO")
        old-dimzin  (getvar "DIMZIN"))

  (setvar "CMDECHO" 0)
  ;; DIMZIN 0 garantiza los tres decimales con ceros finales en rtos.
  (setvar "DIMZIN" 0)

  (princ "\n=== MCCOORD: tabla de coordenadas vinculada ===")

  ;; Reconectar reactores existentes (fuera de callbacks).
  (mccoord:reconnect)

  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))

  ;; 1) Punto/nodo/vertice de origen con snaps endpoint+nodo habilitados.
  (setvar "OSMODE" (logand (logior old-osmode 1 8) (~ 16384)))
  (setq src-ucs (getpoint "\nSeleccione el punto, nodo o vertice de origen: "))
  (setvar "OSMODE" old-osmode)

  (if (null src-ucs)
    (princ "\nMCCOORD: cancelado por el usuario.")
    (progn
      (setq src-wcs (trans src-ucs 1 0))

      ;; 2) Punto de insercion de la tabla.
      (setq ins-ucs (getpoint "\nIndique el punto de insercion de la tabla: "))

      (if (null ins-ucs)
        (princ "\nMCCOORD: cancelado por el usuario.")
        (progn
          (setq ins-wcs (trans ins-ucs 1 0))

          ;; 3) Espacio activo y tamano de texto.
          (setq space    (mccoord:active-space doc)
                textsize (getvar "TEXTSIZE"))
          (if (or (null textsize) (<= textsize 0.0))
            (setq textsize 2.5))

          ;; 4) Agrupacion UNDO (StartUndoMark exitoso devuelve nil).
          (setq undo-result (vl-catch-all-apply 'vla-StartUndoMark (list doc))
                undo-started (not (vl-catch-all-error-p undo-result)))
          (if (not undo-started)
            (progn
              (princ "\nMCCOORD: no se pudo abrir el grupo UNDO; no se crearon entidades.")
              (exit)))

          ;; 5) TABLE asignada de inmediato para la limpieza por error.
          (setq tbl-obj (vla-AddTable space (vlax-3d-point ins-wcs) 3 3
                           (* textsize 2.2) (* textsize 16.0)))

          (if (and tbl-obj (mccoord:format-table tbl-obj textsize
                               (car src-wcs) (cadr src-wcs) (caddr src-wcs)))
            (progn
              (setq tbl-ent (vlax-vla-object->ename tbl-obj)
                    tbl-h   (vla-get-Handle tbl-obj))

              ;; 6) LINE asignada de inmediato antes de escribir metadata.
              (setq line-obj (vla-AddLine space (vlax-3d-point src-wcs)
                               (vlax-3d-point ins-wcs)))

              (if line-obj
                (progn
                  (setq line-ent (vlax-vla-object->ename line-obj)
                        line-h   (vla-get-Handle line-obj))

                  ;; 7) XDATA reciproca; ambas escrituras deben verificarse.
                  (if (and (mccoord:set-xdata line-ent
                                            (mccoord:coord-items tbl-h src-wcs))
                           (mccoord:set-xdata tbl-ent
                                            (mccoord:coord-items line-h src-wcs)))
                    (progn
                      ;; 8) Reactor de la tabla y registro en memoria.
                      (mccoord:attach-table-reactor tbl-obj tbl-h line-h)
                      (setq *mccoord-pairs*
                            (cons (list tbl-obj line-obj src-wcs) *mccoord-pairs*))
                      (setq completed T)
                      (princ "\nMCCOORD: tabla creada y vinculada."))
                    (princ "\nMCCOORD: no se pudo registrar la metadata del vinculo.")))
                (princ "\nMCCOORD: no se pudo crear la LINE de vinculo.")))
            (princ "\nMCCOORD: no se pudo crear o formatear la tabla."))))))

  ;; 10) Limpieza suave: solo entidades incompletas de ESTA ejecucion.
  (if (and (not completed) (mccoord:alive-p line-obj))
    (vl-catch-all-apply 'vla-delete (list line-obj)))
  (if (and (not completed) (mccoord:alive-p tbl-obj))
    (vl-catch-all-apply 'vla-delete (list tbl-obj)))

  ;; Cerrar UNDO despues de limpiar: no dejar eliminaciones fuera del grupo.
  (if undo-started
    (progn
      (vl-catch-all-apply 'vla-EndUndoMark (list doc))
      (setq undo-started nil)))

  ;; Restaurar entorno.
  (setvar "OSMODE" old-osmode)
  (setvar "CMDECHO" old-cmdecho)
  (setvar "DIMZIN" old-dimzin)
  (princ))

;;; ----------------------------------------------------------------------------
;;; SECCION 7: CARGA Y MENSAJE FINAL
;;; ----------------------------------------------------------------------------

;; Reconectar al cargar el LISP (permite acaddoc.lsp / APPLOAD en cada dibujo).
(vl-catch-all-apply 'mccoord:reconnect nil)

(princ "\nMCCOORD cargado. Escriba MCCOORD para iniciar.")
(princ)
