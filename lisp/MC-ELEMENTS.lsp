;;; MCELEMENTS — Edificaciones, vegetación, masas de agua y ríos. AutoCAD Windows / ActiveX.
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

(defun mce:limpiar-vista (/ resultado)
  ;; Refrescar solo la vista: grdraw no crea objetos ni entradas de UNDO.
  (if mce:vista
    (progn
      (setq resultado (vl-catch-all-apply 'redraw nil))
      (if (vl-catch-all-error-p resultado)
        (princ "\nAviso: no se pudo refrescar la previsualización; revisar la vista.")
        (setq mce:vista nil)
      )
    )
  )
)

(defun mce:limpiar (revertir / obj par resultado)
  ;; También se intenta retirar la vista ante ESC/error y al terminar.
  (mce:limpiar-vista)
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

(defun mce:entero (texto / codigos codigo valido valor)
  ;; Acumulación real para evitar desbordamiento de atoi; rango entero COM.
  (setq codigos (vl-string->list texto) valido (not (null codigos)) valor 0.0)
  (foreach codigo codigos
    (if (and (>= codigo 48) (<= codigo 57))
      (setq valor (+ (* valor 10.0) (- codigo 48)))
      (setq valido nil)
    )
    (if (> valor 2147483647.0) (setq valido nil))
  )
  (if (and valido (> valor 0.0)) (fix valor))
)

(defun mce:agua-ui (/ rio)
  ;; Dos listas de rótulos: recordar la opción poligonal, nunca borrarla.
  (setq rio (= (get_tile "tipo") "5"))
  (if (not (eq rio mce:ui-rio))
    (progn
      (if mce:ui-rio
        (setq mce:rotulo-rio (get_tile "rotulo"))
        (setq mce:rotulo-poligono (get_tile "rotulo"))
      )
      (start_list "rotulo")
      (add_list "Sin rótulo") (add_list (if rio "Texto paralelo al río" "Texto centrado"))
      (if (not rio) (add_list "Círculo con tag centrado"))
      (end_list)
      (set_tile "rotulo" (if rio mce:rotulo-rio mce:rotulo-poligono))
      (setq mce:ui-rio rio)
    )
  )
  (mode_tile "agua" (if (member (get_tile "tipo") '("4" "5")) 0 1))
  (mode_tile "rio" (if rio 0 1))
  (mode_tile "cantidad" (if rio 0 1))
  (mce:rotulo-ui)
)

(defun mce:aceptar-ui (/ factor modo texto rio cantidad)
  (setq factor (mce:positivo (get_tile "factor"))
        modo (atoi (get_tile "rotulo"))
        texto (vl-string-trim " \t" (get_tile "contenido"))
        rio (= (get_tile "tipo") "5"))
  (if rio (setq cantidad (mce:entero (get_tile "cantidad"))))
  (cond
    ((not factor) (set_tile "aviso" "Factor: use un decimal positivo con punto (ej. 0.5)."))
    ((and rio (not cantidad)) (set_tile "aviso" "Líneas: entero de 1 a 2147483647, solo dígitos."))
    ((and rio (= (get_tile "rio") "0") (= (rem cantidad 2) 0))
      (set_tile "aviso" "Centro exige un total impar, incluido el eje (1, 3, 5...)."))
    ((and (> modo 0) (= texto "")) (set_tile "aviso" "Escriba el texto o tag del rótulo."))
    (T
      (setq mce:opciones (list (atoi (get_tile "tipo")) factor modo texto
                               (atoi (get_tile "agua"))
                               (atoi (get_tile "rio")) cantidad))
      (done_dialog 1)
    )
  )
)

(defun mce:dialogo (/ linea estado)
  (setq mce:dcl-ruta (vl-filename-mktemp "mce-" nil ".dcl")
        mce:archivo (open mce:dcl-ruta "w"))
  (if (not mce:archivo) (mce:fallar "No se pudo crear el DCL temporal."))
  (foreach linea
    '("mce_dialog : dialog { label = \"MCELEMENTS — Estructuras\";"
      ": popup_list { key = \"tipo\"; label = \"Estructura:\"; width = 40; }"
      ": popup_list { key = \"agua\"; label = \"Forma del agua:\"; }"
      ": popup_list { key = \"rio\"; label = \"Río desde:\"; }"
      ": edit_box { key = \"cantidad\"; label = \"Líneas totales (incluye original):\"; edit_width = 12; }"
      ": edit_box { key = \"factor\"; label = \"Factor visual positivo:\"; edit_width = 12; }"
      ": popup_list { key = \"rotulo\"; label = \"Rótulo:\"; }"
      ": edit_box { key = \"contenido\"; label = \"Texto / tag:\"; edit_width = 32; edit_limit = 120; }"
      ": text { label = \"Polígono: rótulo interior con margen y hueco en la trama.\"; }"
      ": text { label = \"Si no cabe se reduce; ríos: texto paralelo y por fuera.\"; }"
      ": text { label = \"Río ondulado: separación aproximada y adaptable.\"; }"
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
  (foreach linea '("Edificación de 1 nivel" "Edificación de 2 niveles" "Edificación circular (octágono)" "Área verde" "Masa de agua" "Ríos")
    (add_list linea)
  )
  (end_list)
  (start_list "agua")
  (foreach linea '("Recta" "Ondulada (SPLINE continua)") (add_list linea))
  (end_list)
  (set_tile "agua" "0")
  (action_tile "tipo" "(mce:agua-ui)")
  (start_list "rotulo")
  (foreach linea '("Sin rótulo" "Texto centrado" "Círculo con tag centrado") (add_list linea))
  (end_list)
  (start_list "rio")
  (add_list "Centro (total impar)") (add_list "Límite (elegir lado)")
  (end_list)
  (set_tile "rio" "0") (set_tile "cantidad" "3")
  (setq mce:ui-rio nil mce:rotulo-poligono "0" mce:rotulo-rio "0")
  (set_tile "tipo" "0")
  (mce:agua-ui)
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

(defun mce:previsualizar (puntos cerrado / primero anterior siguiente)
  ;; Puntos WCS en orden de captura; convertir solo la representación a UCS.
  ;; El refresco puede perderse con pan/zoom hasta el siguiente vértice.
  (mce:limpiar-vista)
  (if (cdr puntos)
    (progn
      ;; Marcar antes de dibujar para limpiar incluso tras un fallo parcial.
      (setq mce:vista T primero (car puntos) anterior primero)
      (foreach siguiente (cdr puntos)
        (grdraw (trans anterior 0 1) (trans siguiente 0 1) 7 0)
        (setq anterior siguiente)
      )
      ;; Cierre provisional rojo discontinuo; nunca cerrar un río.
      (if (and cerrado (cddr puntos))
        (grdraw (trans anterior 0 1) (trans primero 0 1) 1 1)
      )
    )
  )
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
      (setq p (getpoint (if (= tipo 5) "\nPrimer punto del río: " "\nPrimer vértice del polígono: "))
            q (trans p 1 0) z (caddr q) puntos (list q))
      (while (setq p (getpoint (trans q 0 1) (if (= tipo 5) "\nSiguiente punto <Enter para terminar>: " "\nSiguiente vértice <Enter para cerrar>: ")))
        (setq q (mce:plano p z) puntos (cons q puntos))
        (mce:previsualizar (reverse puntos) (/= tipo 5))
      )
      (mce:limpiar-vista)
      (setq puntos (reverse puntos))
      (if (and (/= tipo 5) (> (length puntos) 3) (equal (car puntos) (last puntos) 1e-8))
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

(defun mce:validar-abierta (puntos / n extension tol i j a b c)
  ;; No añadir arista de cierre ni exigir área en una cadena abierta.
  (setq n (length puntos))
  (if (< n 2) (mce:fallar "Río: se necesitan al menos dos puntos distintos."))
  (setq extension (max (- (apply 'max (mapcar 'car puntos)) (apply 'min (mapcar 'car puntos)))
                       (- (apply 'max (mapcar 'cadr puntos)) (apply 'min (mapcar 'cadr puntos))))
        tol (max 1e-8 (* extension 1e-10)) i 0)
  (if (equal (car puntos) (last puntos) tol) (mce:fallar "El río no puede cerrarse."))
  (while (< i (1- n))
    (setq a (nth i puntos) b (nth (1+ i) puntos))
    (if (<= (distance a b) tol) (mce:fallar "Río: puntos coincidentes."))
    (if (< (+ i 2) n)
      (progn
        (setq c (nth (+ i 2) puntos))
        (if (or (mce:sobre a b c tol) (mce:sobre c a b tol))
          (mce:fallar "Río: retroceso entre tramos consecutivos."))
      )
    )
    (setq j (+ i 2))
    (while (< j (1- n))
      (if (mce:contacto a b (nth j puntos) (nth (1+ j) puntos) tol)
        (mce:fallar "El río se cruza o se toca a sí mismo."))
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

(defun mce:poligono (puntos capa cerrado / coords matriz obj p)
  ;; Normal +Z: XY de OCS coincide con WCS; elevación explícita, sin UCS.
  (foreach p puntos (setq coords (cons (cadr p) (cons (car p) coords))))
  (setq coords (reverse coords)
        matriz (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length coords)))) )
  (vlax-safearray-fill matriz coords)
  (setq obj (mce:registrar (vla-AddLightWeightPolyline mce:espacio matriz)))
  (vla-put-Normal obj (vlax-3d-point '(0.0 0.0 1.0)))
  (vla-put-Elevation obj (caddr (car puntos)))
  (vla-put-Closed obj (if cerrado :vlax-true :vlax-false))
  (vla-put-Layer obj capa)
  (vla-put-Color obj 256)
  obj
)

(defun mce:cota (contorno)
  ;; SPLINE no expone Elevation; vlax-curve devuelve siempre puntos WCS.
  (caddr (vlax-curve-getStartPoint contorno))
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
  (list area (list (car centro) (cadr centro) (mce:cota contorno)))
)

(defun mce:descartar (obj)
  (if (not (mce:retirar obj))
    (mce:fallar "No se pudo retirar una entidad temporal de agua.")
  )
)

(defun mce:azul (obj capa)
  (vla-put-Layer obj capa)
  (setq mce:color (vla-get-TrueColor obj))
  (vla-SetRGB mce:color 59 130 246)
  (vla-put-TrueColor obj mce:color)
  (vlax-release-object mce:color)
  (setq mce:color nil)
)

(defun mce:tangente-cierre (puntos tol / d m c)
  ;; Dirección tangente periódica en el primer punto: P1 - P(n-1). La media de
  ;; las cuerdas adyacentes fija una magnitud razonable y nunca sobredimensionada.
  (setq d (mapcar '- (cadr puntos) (last puntos))
        m (distance '(0.0 0.0 0.0) d))
  (if (<= m tol)
    (setq d (mapcar '- (cadr puntos) (car puntos))
          m (distance '(0.0 0.0 0.0) d))
  )
  (if (<= m tol)
    nil
    (progn
      (setq c (/ (+ (distance (car puntos) (cadr puntos))
                    (distance (last puntos) (car puntos)))
                 2.0))
      (list (* (/ (car d) m) c) (* (/ (cadr d) m) c) (* (/ (caddr d) m) c))
    )
  )
)

(defun mce:suave (puntos capa tol / cerrados coords matriz obj tangente)
  ;; Ajuste global, no fillets ni ondas. El primer punto de ajuste se repite al
  ;; final para que la SPLINE cierre geométricamente; en el punto común las
  ;; tangentes coinciden y no son nulas; Closed2 refuerza la continuidad.
  (setq tangente (mce:tangente-cierre puntos tol))
  (if (not tangente)
    (mce:fallar "No se pudo calcular una tangente de cierre no nula.")
  )
  (setq cerrados (append puntos (list (car puntos)))
        coords (apply 'append cerrados)
        matriz (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length coords)))))
  (vlax-safearray-fill matriz coords)
  (setq obj (mce:registrar
              (vla-AddSpline mce:espacio matriz
                (vlax-3d-point tangente) (vlax-3d-point tangente))))
  (if (not (vlax-property-available-p obj 'Closed2 T))
    (mce:fallar "Incompatibilidad: SPLINE requiere Closed2 escribible para cierre suave.")
  )
  (if (vl-catch-all-error-p
        (vl-catch-all-apply 'vlax-put-property (list obj 'Closed2 :vlax-true)))
    (mce:fallar "Incompatibilidad: AutoCAD no permite cerrar suavemente la SPLINE con Closed2.")
  )
  (vla-put-Layer obj capa)
  ;; Sin Update: la escritura de propiedades ActiveX es inmediata y el
  ;; readback no necesita commit adicional. Evitamos tragar un ESC atrapado.
  ;; Lectura de vuelta: sin cierre real no se puede validar la REGION temporal.
  (if (not (vlax-curve-isClosed obj))
    (mce:fallar "La SPLINE no quedó cerrada tras Closed2; no se puede validar el contorno de agua.")
  )
  obj
)

(defun mce:suave-abierta (puntos capa tol / n coords matriz obj inicio fin)
  ;; Tangentes de extremo explícitas y no nulas; el río debe seguir abierto.
  (setq n (length puntos)
        inicio (mapcar '- (cadr puntos) (car puntos))
        fin (if (> n 2) (mapcar '- (last puntos) (nth (- n 2) puntos)) inicio))
  (if (or (<= (distance '(0.0 0.0 0.0) inicio) tol)
          (<= (distance '(0.0 0.0 0.0) fin) tol))
    (mce:fallar "No se pudo calcular una tangente no nula para el río.")
  )
  (setq coords (apply 'append puntos)
        matriz (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length coords)))))
  (vlax-safearray-fill matriz coords)
  (setq obj (mce:registrar
              (vla-AddSpline mce:espacio matriz
                (vlax-3d-point inicio) (vlax-3d-point fin))))
  (vla-put-Layer obj capa)
  obj
)

(defun mce:terna (valores / puntos)
  (while valores
    (setq puntos (cons (list (car valores) (cadr valores) (caddr valores)) puntos)
          valores (cdddr valores)))
  (reverse puntos)
)

(defun mce:curva-rio (curva tol / nombre valores puntos direccion norma anterior actual p i peso pesos)
  (if (or (vlax-curve-isClosed curva)
          (equal (vlax-curve-getStartPoint curva) (vlax-curve-getEndPoint curva) tol))
    (mce:fallar "Offset/río devolvió una curva cerrada o degenerada."))
  (setq nombre (vla-get-ObjectName curva))
  (cond
    ((= nombre "AcDbPolyline")
      (setq valores (vlax-get curva 'Coordinates) i 0)
      (while valores
        (if (/= (vla-GetBulge curva i) 0.0)
          (mce:fallar "Offset devolvió arcos no certificables en el río recto."))
        (setq puntos (cons (list (car valores) (cadr valores) (mce:cota curva)) puntos)
              valores (cddr valores) i (1+ i)))
      (mce:validar-abierta (reverse puntos))
    )
    ((= nombre "AcDbSpline")
      ;; Certificado conservador: proyección estrictamente monótona del polígono
      ;; de control sobre la cuerda. Su derivada no puede retroceder ni cruzarse.
      ;; No se confunde muestreo finito con una prueba de curva simple.
      (setq puntos (mce:terna (vlax-get curva 'ControlPoints)))
      (if (< (length puntos) 2) (mce:fallar "SPLINE sin controles suficientes."))
      ;; Pesos positivos conservan la propiedad de variación decreciente, pero
      ;; Weights solo se consulta en splines racionales. En una polinómica los
      ;; pesos son unitarios implícitos y pedirlos dispara el error nativo COM
      ;; "No hay ningún grosor disponible para la spline polinómica". El gate usa
      ;; el boolean COM :vlax-true (0 es no-nil en Lisp) y NO convierte un error
      ;; atrapado en reserva polinómica: la consulta directa sigue fallando si
      ;; COM la rechaza. Tampoco se escriben pesos de la entidad.
      (if (= (vla-get-IsRational curva) :vlax-true)
        (progn
          (setq pesos (vlax-get curva 'Weights))
          ;; Certificado no vacío: un racional sin pesos devueltos o desacoplado
          ;; de sus controles no se valida con un FOREACH vacío.
          (if (/= (length pesos) (length puntos))
            (mce:fallar "SPLINE racional con pesos ausentes o desacoplados de sus controles."))
          (foreach peso pesos
            (if (<= peso 0.0) (mce:fallar "SPLINE con pesos no certificables.")))
        )
      )
      (foreach p puntos
        (if (> (abs (- (caddr p) (mce:cota curva))) tol)
          (mce:fallar "SPLINE de río no horizontal.")))
      (setq direccion (mapcar '- (last puntos) (car puntos))
            norma (distance '(0.0 0.0 0.0) direccion))
      (if (<= norma tol) (mce:fallar "SPLINE de río no certificable: cuerda nula."))
      (foreach p puntos
        (setq actual (/ (apply '+ (mapcar '* (mapcar '- p (car puntos)) direccion)) norma))
        (if (and anterior (<= (- actual anterior) tol))
          (mce:fallar "SPLINE no certificable: controles sin avance estricto. Use recta o un recorrido más simple."))
        (setq anterior actual)
      )
    )
    (T (mce:fallar "Offset devolvió un tipo de curva de río no compatible."))
  )
  (if (<= (vlax-curve-getDistAtParam curva (vlax-curve-getEndParam curva)) tol)
    (mce:fallar "Longitud de río degenerada."))
  curva
)

(defun mce:offset-rio (original distancia tol / resultado curvas curva)
  (setq resultado (vl-catch-all-apply 'vla-Offset (list original distancia)))
  (mce:interrupcion resultado)
  (if (vl-catch-all-error-p resultado)
    (mce:fallar "Offset no pudo completar el total solicitado; se retira todo el río."))
  (setq curvas (vlax-safearray->list (vlax-variant-value resultado)))
  ;; Registrar todo antes de propiedades, validaciones o rechazo de fragmentación.
  (foreach curva curvas (mce:registrar curva))
  (if (/= (length curvas) 1)
    (mce:fallar "Offset fragmentado, vacío o ambiguo: se exige una curva por copia."))
  (mce:curva-rio (car curvas) tol)
)

(defun mce:lado-rio (origen tangente punto tol / cruz norma)
  (setq norma (distance '(0.0 0.0 0.0) tangente)
        cruz (- (* (car tangente) (- (cadr punto) (cadr origen)))
                (* (cadr tangente) (- (car punto) (car origen)))))
  (if (or (<= norma tol) (<= (abs cruz) (* tol norma)))
    (mce:fallar "Lado ambiguo: elija un punto separado del río y de su prolongación tangente."))
  (if (> cruz 0.0) 1 -1)
)

(defun mce:rio (original capa modo total tol / longitud paso centro punto base tangente lado
                 positiva negativa lp ln signo cantidad i copia)
  (mce:curva-rio original tol)
  (setq longitud (vlax-curve-getDistAtParam original (vlax-curve-getEndParam original))
        paso (* 0.05 longitud)
        centro (vlax-curve-getPointAtDist original (/ longitud 2.0)))
  (mce:azul original capa)
  ;; Total 1 conserva solamente el original; no requiere selección de lado.
  (if (> total 1)
    (progn
      (if (= modo 1)
        (progn
          (initget 1)
          (setq punto (mce:plano (getpoint "\nPunto hacia el lado de los desfases: ") (mce:cota original))
                base (vlax-curve-getClosestPointTo original punto)
                tangente (vlax-curve-getFirstDeriv original (vlax-curve-getParamAtPoint original base)))
          (if (<= (distance punto base) tol) (mce:fallar "El punto de lado está sobre el río."))
          (setq lado (mce:lado-rio base tangente punto tol))
        )
        (setq base centro
              tangente (vlax-curve-getFirstDeriv original (vlax-curve-getParamAtPoint original base)))
      )
      ;; Calibrar ambos signos con curvas REALES, nunca suponer sentido de Offset.
      (setq positiva (mce:offset-rio original paso tol)
            negativa (mce:offset-rio original (- paso) tol)
            lp (mce:lado-rio base tangente (vlax-curve-getClosestPointTo positiva base) tol)
            ln (mce:lado-rio base tangente (vlax-curve-getClosestPointTo negativa base) tol))
      (if (= lp ln) (mce:fallar "Offset no distingue ambos lados; se retira todo el río."))
      (if (= modo 0)
        (progn (mce:azul positiva capa) (mce:azul negativa capa)
               (setq cantidad (/ (1- total) 2)))
        (progn
          (setq signo (if (= lp lado) 1.0 -1.0) cantidad (1- total))
          (mce:azul (if (= lp lado) positiva negativa) capa)
          (mce:descartar (if (= lp lado) negativa positiva))
        )
      )
      (setq i 2)
      (while (<= i cantidad)
        (foreach signo (if (= modo 0) '(1.0 -1.0) (list signo))
          ;; Cada nivel se mide desde el original: múltiplos exactos del paso fijo.
          (setq copia (mce:offset-rio original (* signo i paso) tol))
          (if (/= (mce:lado-rio base tangente (vlax-curve-getClosestPointTo copia base) tol)
                   (if (> signo 0.0) lp ln))
            (mce:fallar "Offset cambió de lado; no se puede certificar el total solicitado."))
          (mce:azul copia capa)
        )
        (setq i (1+ i))
      )
    )
  )
  (princ (strcat "\nRío: " (itoa total) " líneas totales; separación " (rtos paso 2 8) "."))
  (list longitud centro)
)

(defun mce:onda-avance-p (puntos tol / direccion norma anterior actual valido p)
  ;; Precondición geométrica, no prueba por muestreo: también se aplica después
  ;; a los CONTROLES de la SPLINE real, antes del certificado mce:curva-rio.
  (if (cdr puntos)
    (progn
      (setq direccion (mapcar '- (last puntos) (car puntos))
            norma (distance '(0.0 0.0 0.0) direccion) valido (> norma tol))
      (if valido
        (foreach p puntos
          (setq actual (/ (apply '+ (mapcar '* (mapcar '- p (car puntos)) direccion)) norma))
          (if (and anterior (<= (- actual anterior) tol)) (setq valido nil))
          (setq anterior actual)))
      valido
    )
  )
)

(defun mce:onda-muestras (original longitud tol / i parametro punto tangente norma muestras)
  ;; Una sola referencia para todos los niveles: 64 intervalos de longitud.
  ;; AddSpline recibe puntos de AJUSTE; los controles finales se leen aparte.
  (setq i 0)
  (repeat 65
    (setq parametro (cond ((= i 0) (vlax-curve-getStartParam original))
                          ((= i 64) (vlax-curve-getEndParam original))
                          (T (vlax-curve-getParamAtDist original (* longitud (/ i 64.0)))))
          punto (vlax-curve-getPointAtParam original parametro)
          tangente (vlax-curve-getFirstDeriv original parametro)
          norma (sqrt (+ (* (car tangente) (car tangente))
                         (* (cadr tangente) (cadr tangente)))))
    (if (<= norma tol) (mce:fallar "Río ondulado: normal local indefinida."))
    (setq muestras (cons (list punto (list (/ (- (cadr tangente)) norma)
                                          (/ (car tangente) norma) 0.0)) muestras)
          i (1+ i))
  )
  (reverse muestras)
)

(defun mce:onda-copia (muestras distancia capa tol / puntos muestra)
  (foreach muestra muestras
    (setq puntos (cons (mapcar '+ (car muestra)
                          (mapcar '(lambda (v) (* distancia v)) (cadr muestra))) puntos)))
  (setq puntos (reverse puntos))
  ;; Un pliegue previo al ajuste solicita otro paso, no una SPLINE degenerada.
  (if (mce:onda-avance-p puntos tol) (mce:suave-abierta puntos capa tol))
)

(defun mce:onda-compatible-p (curva anteriores base tangente signo tol
                              / valido cercano delta lateral norma otra)
  ;; El certificado se evalúa sobre controles reales, nunca sobre muestras.
  (setq valido (and (not (vlax-curve-isClosed curva))
                   (mce:onda-avance-p (mce:terna (vlax-get curva 'ControlPoints)) tol)))
  (if valido
    (progn
      (setq cercano (vlax-curve-getClosestPointTo curva base)
            delta (mapcar '- cercano base)
            lateral (- (* (car tangente) (cadr delta)) (* (cadr tangente) (car delta)))
            norma (distance '(0.0 0.0 0.0) tangente)
            valido (> (* signo lateral) (* tol norma)))
      ;; Intersección NATIVA entre curvas completas, incluido el original.
      ;; Error COM o ESC no se disfraza de reducción de separación: aborta.
      (foreach otra anteriores
        (if (and valido (vlax-invoke curva 'IntersectWith otra 0)) (setq valido nil)))
    )
  )
  valido
)

(defun mce:rio-ondulado (original capa modo total tol
                         / longitud inicial paso centro base tangente punto signo signos cantidad
                           muestras intento aceptado valido copias anteriores i copia)
  (mce:curva-rio original tol)
  (setq longitud (vlax-curve-getDistAtParam original (vlax-curve-getEndParam original))
        inicial (* 0.05 longitud) paso inicial
        centro (vlax-curve-getPointAtDist original (/ longitud 2.0)))
  (mce:azul original capa)
  (if (> total 1)
    (progn
      (setq base centro)
      (if (= modo 1)
        (progn
          (initget 1)
          (setq punto (mce:plano (getpoint "\nPunto hacia el lado de los desfases: ") (mce:cota original))
                base (vlax-curve-getClosestPointTo original punto))
          (if (<= (distance punto base) tol) (mce:fallar "El punto de lado está sobre el río."))))
      (setq tangente (vlax-curve-getFirstDeriv original (vlax-curve-getParamAtPoint original base))
            signos (if (= modo 0) '(1.0 -1.0) (list (mce:lado-rio base tangente punto tol)))
            cantidad (if (= modo 0) (/ (1- total) 2) (1- total))
            muestras (mce:onda-muestras original longitud tol) intento 0)
      (while (and (not aceptado) (< intento 12) (> paso tol))
        (setq copias nil anteriores (list original) valido T i 1)
        (while (and valido (<= i cantidad))
          (foreach signo signos
            (if valido
              (progn
                (setq copia (mce:onda-copia muestras (* signo i paso) capa tol))
                ;; Registrar incluso la copia rechazada para retirar el intento entero.
                (if copia (setq copias (cons copia copias)))
                (setq valido (and copia (mce:onda-compatible-p copia anteriores base tangente signo tol)))
                (if valido (setq anteriores (cons copia anteriores)))
              )))
          (setq i (1+ i)))
        (if valido
          (setq aceptado T)
          (progn
            (foreach copia copias (mce:descartar copia))
            (setq copias nil paso (/ paso 2.0))))
        (setq intento (1+ intento))
      )
      (if (not aceptado)
        (mce:fallar "Río ondulado: no se obtuvo un conjunto válido en 12 intentos; se retira todo el río."))
      (foreach copia copias
        (mce:curva-rio copia tol)
        (mce:azul copia capa))
      (princ (strcat "\nRío ondulado: separación aproximada"
                     (if (< paso inicial) " reducida" "")
                     "; paso usado " (rtos paso 2 8)
                     "; paso inicial " (rtos inicial 2 8) "."))
    )
  )
  (princ (strcat "\nRío: " (itoa total) " líneas totales"
                 (if (> total 1) "; separación perpendicular aproximada." "; sin copias.")))
  (list longitud centro)
)

(defun mce:interrupcion (resultado)
  ;; No convertir ESC atrapado por COM en un aviso de geometría incompleta.
  (if (and (vl-catch-all-error-p resultado)
           (wcmatch (strcase (vl-catch-all-error-message resultado))
                    "*CANCEL*,*QUIT*,*ABORT*,*BREAK*,*INTERRUP*"))
    (mce:fallar "Operación cancelada; se retiran los resultados propios.")
  )
)

(defun mce:diagnostico-fragmento (curva indice cantidad / tipo inicio fin hueco)
  ;; Solo lectura, antes de retirar el primer fragmento rechazado. Un dato no
  ;; disponible no cambia la validación; ESC conserva la cancelación habitual.
  (setq tipo (vl-catch-all-apply 'vla-get-ObjectName (list curva)))
  (mce:interrupcion tipo)
  (setq inicio (vl-catch-all-apply 'vlax-curve-getStartPoint (list curva)))
  (mce:interrupcion inicio)
  (setq fin (vl-catch-all-apply 'vlax-curve-getEndPoint (list curva)))
  (mce:interrupcion fin)
  (if (and (not (vl-catch-all-error-p inicio)) inicio
           (not (vl-catch-all-error-p fin)) fin)
    (progn
      (setq hueco (vl-catch-all-apply 'distance (list inicio fin)))
      (mce:interrupcion hueco)
    )
  )
  (strcat "; fragmento " (itoa indice) "/" (itoa cantidad)
          " de esta llamada Offset; tipo "
          (if (= (type tipo) 'STR) tipo "no disponible")
          "; distancia entre extremos WCS "
          (if (numberp hueco) (rtos hueco 1 12) "no disponible")
          " (unidades de dibujo; informativo, no altera el cierre)")
)

(defun mce:pieza-abierta (curva / tipo abierta)
  ;; S1 — Pieza nativa SPLINE que Offset devolvió abierta: candidata a contorno
  ;; compuesto, nunca a aceptación individual. Lectura con red de seguridad: un
  ;; error COM no convierte la pieza en abierta.
  (setq tipo (vl-catch-all-apply 'vla-get-ObjectName (list curva)))
  (mce:interrupcion tipo)
  (if (and (not (vl-catch-all-error-p tipo)) (= tipo "AcDbSpline"))
    (progn
      (setq abierta (vl-catch-all-apply 'vlax-curve-isClosed (list curva)))
      (mce:interrupcion abierta)
      (and (not (vl-catch-all-error-p abierta)) (not abierta))
    )
  )
)

(defun mce:region-conjunta (piezas / copias fallo curva copia resultado regiones reg region motivo)
  ;; S1–S3 — Admisión conjunta: una sola prueba nativa con AddRegion sobre COPIA
  ;; de las piezas abiertas de la MISMA llamada Offset, todavía existentes. No se
  ;; envían el contorno original ni las piezas reales como entrada mutable.
  ;; Devuelve (region motivo): region es la ÚNICA región positiva obtenida o nil;
  ;; motivo describe la causa medida. No decide admisión: mce:agua la contrasta
  ;; con original, padres y dedup. Registra copias y regiones antes de leer
  ;; cualquier área y retira solo los recursos propios que no devuelve.
  (setq copias nil regiones nil region nil)
  (foreach curva piezas
    (if (not fallo)
      (progn
        (setq resultado (vl-catch-all-apply 'vla-Copy (list curva)))
        (mce:interrupcion resultado)
        (if (vl-catch-all-error-p resultado)
          (setq fallo (vl-catch-all-error-message resultado))
          (setq copia (mce:registrar resultado) copias (cons copia copias))
        )
      )
    )
  )
  (cond
    (fallo
      (setq motivo (strcat "no se pudo copiar una pieza nativa para la prueba conjunta (" fallo ")"))
    )
    (T
      ;; Una sola llamada con todas las copias en un único vector de objetos.
      (setq resultado (vl-catch-all-apply 'vla-AddRegion
                          (list mce:espacio (mce:vector-objetos copias))))
      (mce:interrupcion resultado)
      (cond
        ((vl-catch-all-error-p resultado)
          (setq motivo (strcat "AddRegion falló: " (vl-catch-all-error-message resultado)))
        )
        (T
          (setq regiones (vl-catch-all-apply
                           '(lambda ()
                              (vlax-safearray->list (vlax-variant-value resultado)))))
          (mce:interrupcion regiones)
          (cond
            ((vl-catch-all-error-p regiones)
              ;; D3 heredado — AddRegion respondió pero la lista no se pudo
              ;; enumerar: sin referencias no se pueden registrar ni retirar esas
              ;; regiones. Se aborta con el error nativo y aviso explícito; nunca
              ;; se continúa como si la limpieza fuera completa ni se borra global.
              (mce:fallar
                (strcat "AddRegion respondió, pero su lista de regiones no se pudo enumerar ("
                        (vl-catch-all-error-message regiones)
                        "). Pueden quedar REGION temporales sin identificar y no se puede certificar su limpieza. Revisar el DWG de prueba o deshacer."))
            )
            (T
              ;; Registrar TODAS antes de leer cualquier área. `reg` itera y
              ;; `region` solo se asigna con exactamente una: en cualquier otro
              ;; caso queda nil para que la limpieza retire todas las regiones.
              (foreach reg regiones (mce:registrar reg))
              (if (/= (length regiones) 1)
                (setq motivo (strcat "AddRegion devolvió " (itoa (length regiones))
                                     " regiones; no se puede asociar cada región con las piezas de esta llamada Offset"))
                (setq region (car regiones))
              )
            )
          )
        )
      )
    )
  )
  ;; Limpieza SOLO de los recursos propios por el camino existente; si no se
  ;; pueden retirar, mce:descartar conserva su fallo real.
  (foreach copia copias (mce:descartar copia))
  (if (not region)
    (progn
      (foreach reg regiones (mce:descartar reg))
      (if (not motivo) (setq motivo "no se obtuvo una región conjunta única"))
    )
  )
  (list region motivo)
)

(defun mce:region-agua (curva / copia resultado regiones region area perimetro
                         longitud fin motivo ok reg suave diagnostico)
  ;; Devuelve (region motivo [diagnostico]): region válida o (nil motivo con la
  ;; causa medida). Los dos primeros elementos conservan el contrato previo; el
  ;; tercero es metadata informativa (perímetro y longitud de la curva final) y
  ;; SOLO existe cuando una SPLINE se acepta. region solo se asigna a una región
  ;; válida; reg es el iterador. El núcleo REGION valida la curva FINAL, no solo
  ;; las cuerdas de entrada.
  (if (not (vlax-curve-isClosed curva))
    (setq motivo "la curva suave no quedó cerrada")
    (progn
      (setq copia (mce:registrar (vla-Copy curva))
            resultado (vl-catch-all-apply 'vla-AddRegion
                        (list mce:espacio (mce:vector-objetos (list copia)))))
      (mce:interrupcion resultado)
      (cond
        ((vl-catch-all-error-p resultado)
          (setq motivo (strcat "AddRegion falló: "
                               (vl-catch-all-error-message resultado))))
        (T
          (setq regiones (vlax-safearray->list (vlax-variant-value resultado)))
          ;; Registrar TODOS antes de leer propiedades, incluso si se rechazan.
          (foreach reg regiones (mce:registrar reg))
          (cond
            ((/= (length regiones) 1)
              (setq motivo (strcat "AddRegion produjo " (itoa (length regiones))
                                   " regiones en lugar de una")))
            (T
              (setq area (vla-get-Area (car regiones))
                    perimetro (vla-get-Perimeter (car regiones))
                    longitud (vlax-curve-getDistAtParam curva (vlax-curve-getEndParam curva))
                    suave (= (vla-get-ObjectName curva) "AcDbSpline"))
              (cond
                ((<= area 1e-16)
                  (setq motivo "la región tiene superficie nula"))
                (suave
                  ;; SPLINE: cierre nativo + AddRegion exitoso + exactamente una
                  ;; región con área positiva son el criterio. Perímetro y
                  ;; longitud ya no vetan: solo se devuelven como diagnóstico.
                  ;; No prueban mapeo íntegro ni ausencia de lóbulos descartados.
                  (setq ok T region (car regiones)
                        diagnostico (list perimetro longitud)))
                (T
                  ;; Polilíneas y demás curvas conservan el guard previo: una
                  ;; región positiva no demuestra recorrido íntegro, así que el
                  ;; perímetro debe cubrir toda la longitud.
                  (setq fin (max 1e-8 (* longitud 1e-8)))
                  (if (equal perimetro longitud fin)
                    (setq ok T region (car regiones))
                    (setq motivo (strcat "el perímetro " (rtos perimetro 2 8)
                                         " no coincide con la longitud de la curva "
                                         (rtos longitud 2 8) " (tolerancia " (rtos fin 2 8) ")")))
                )
              )
            )
          )
        )
      )
      (mce:descartar copia)
      ;; Todo rechazo devuelve (nil motivo): nunca una región ya borrada.
      (if (not ok)
        (progn
          (foreach reg regiones (mce:descartar reg))
          (setq region nil)
          (if (not motivo) (setq motivo "AddRegion no produjo una región válida"))
        )
      )
    )
  )
  (if diagnostico
    (list region motivo diagnostico)
    (list region motivo))
)

(defun mce:contenida (hija madre tolerancia / resto molde resultado dentro)
  ;; Diferencia de superficies completas: no basta área menor, centroide o muestras.
  ;; Boolean solo modifica copias propias; acSubtraction = 2.
  (setq resto (mce:registrar (vla-Copy hija))
        molde (mce:registrar (vla-Copy madre))
        resultado (vl-catch-all-apply 'vla-Boolean (list resto 2 molde)))
  (if (vl-catch-all-error-p resultado)
    (mce:fallar "REGION/Boolean no pudo certificar contención; se retira la ejecución.")
  )
  (setq dentro (or (vlax-erased-p resto) (<= (vla-get-Area resto) tolerancia)))
  (mce:descartar resto)
  (mce:descartar molde)
  dentro
)

(defun mce:agua (contorno capa / original area centro medidas paso tolerancia
                  padres nivel nuevos par area-padre signo resultado fragmentos
                  fragmento region motivo superficie admitida menor duplicado
                  total niveles intentos incompleto analisis diagnostico
                  nivel-probado incidencia incidencias exclusiones indice-fragmento
                  abiertos piezas pieza compuestos region-conjunta motivo-conjunto
                  incidencia-region region-en-incidencia)
  (setq analisis (mce:region-agua contorno)
        original (car analisis)
        diagnostico (caddr analisis))
  (if (not original)
    (mce:fallar
      (strcat "El contorno final de agua es inválido, se cruza o no produce una región simple completa: "
              (if (cadr analisis) (cadr analisis) "causa no determinada") "."))
  )
  (setq area (vla-get-Area original) centro (vlax-get original 'Centroid)
        medidas (list area (list (car centro) (cadr centro) (mce:cota contorno)))
        paso (* 0.05 (sqrt area)) tolerancia (max 1e-16 (* area 1e-9))
        padres (list (list original 0)) total 0 niveles 0 intentos 0
        nivel 1 nivel-probado 0 incompleto nil incidencia nil incidencias 0
        exclusiones 0 compuestos 0 abiertos nil piezas nil
        region-conjunta nil motivo-conjunto nil
        incidencia-region nil region-en-incidencia nil)
  ;; Diagnóstico informativo del contorno ORIGINAL: se imprime una sola vez, no
  ;; por fragmento. Solo la SPLINE aporta esta metadata; las polilíneas no.
  (if diagnostico
    (princ (strcat
             "\nAgua: SPLINE original aceptada por validación nativa de REGION "
             "(cerrada, una región, área positiva)."
             "\n  REGION perímetro " (rtos (car diagnostico) 2 8)
             "; longitud de curva " (rtos (cadr diagnostico) 2 8)
             "; diferencia " (rtos (abs (- (car diagnostico) (cadr diagnostico))) 2 8)
             " (informativo: no certifica topología ni ausencia de lóbulos descartados)."))
  )
  (mce:azul contorno capa)
  ;; Barrido por niveles desde el contorno ORIGINAL: cada nivel calcula ±n·d una
  ;; sola vez por signo sobre `contorno` (NUNCA sobre la REGION `original`, que
  ;; no es una curva) y prueba TODOS los fragmentos devueltos contra TODOS los
  ;; padres retenidos del nivel anterior. Cada distancia es múltiplo exacto del
  ;; paso y no se acumulan aproximaciones de nivel en nivel. La REGION original
  ;; vive hasta el final; los padres de un nivel se retiran solo tras probar los
  ;; dos signos.
  (while padres
    (if (> nivel 256)
      (mce:fallar "Límite de agua: 256 niveles; no se garantiza relleno completo. Se retira la ejecución.")
    )
    (setq nivel-probado nivel nuevos nil)
    (foreach signo '(1.0 -1.0)
      (setq intentos (1+ intentos))
      (if (> intentos 2048)
        (mce:fallar "Límite de agua: 2048 intentos de desfase. Se retira la ejecución.")
      )
      (setq resultado (vl-catch-all-apply 'vla-Offset (list contorno (* signo nivel paso))))
      (mce:interrupcion resultado)
      (if (vl-catch-all-error-p resultado)
        (progn
          ;; Error nativo: no certifica agotamiento; guardar causa, nivel y signo.
          (setq incompleto T incidencias (1+ incidencias))
          (if (not incidencia)
            (setq incidencia (list "Offset" (vl-catch-all-error-message resultado)
                                   nivel (* signo nivel paso)))
          )
        )
        (progn
          (setq fragmentos (vlax-safearray->list (vlax-variant-value resultado))
                indice-fragmento 0)
          (foreach fragmento fragmentos (mce:registrar fragmento))
          (setq total (+ total (length fragmentos)))
          (if (> total 4096)
            (mce:fallar "Límite de agua: 4096 curvas devueltas. Se retira la ejecución.")
          )
          (if (not fragmentos)
            (progn
              (setq incompleto T incidencias (1+ incidencias))
              (if (not incidencia)
                (setq incidencia (list "Offset vacío" "no se devolvió ninguna curva"
                                       nivel (* signo nivel paso)))
              )
            )
          )
          (foreach fragmento fragmentos
            (setq indice-fragmento (1+ indice-fragmento)
                  analisis (mce:region-agua fragmento)
                  region (car analisis) motivo (cadr analisis)
                  admitida nil menor nil duplicado nil)
            (if region
              (progn
                (setq superficie (vla-get-Area region))
                ;; ¿Algún padre es estrictamente mayor dentro de la tolerancia?
                (foreach par padres
                  (setq area-padre (vla-get-Area (car par)))
                  (if (< superficie (- area-padre tolerancia))
                    (setq menor T)
                  )
                )
                ;; Admisible: menor y contenida en un padre Y en el original. La
                ;; contención se mide por diferencia REGION/Boolean completa.
                (if (and (> superficie tolerancia) menor
                         (mce:contenida region original tolerancia))
                  (foreach par padres
                    (setq area-padre (vla-get-Area (car par)))
                    (if (and (not admitida)
                             (< superficie (- area-padre tolerancia))
                             (mce:contenida region (car par) tolerancia))
                      (setq admitida T)
                    )
                  )
                )
                (if admitida
                  (progn
                    ;; Ambos signos pueden devolver la misma solución: dedup
                    ;; global del nivel por área y contención dentro de la
                    ;; tolerancia.
                    (foreach par nuevos
                      (if (and (equal superficie (vla-get-Area (car par)) tolerancia)
                               (mce:contenida region (car par) tolerancia))
                        (setq duplicado T)
                      )
                    )
                    (if duplicado
                      (progn (mce:descartar region) (mce:descartar fragmento))
                      (progn
                        (mce:azul fragmento capa)
                        (setq nuevos (cons (list region nivel) nuevos)
                              niveles (max niveles nivel))
                      )
                    )
                  )
                  (progn
                    ;; Un candidato que no reduce respecto de ningún padre apunta
                    ;; hacia fuera: exclusión ordinaria, no fallo del motor.
                    (if (and (> superficie tolerancia) menor)
                      (progn
                        (setq incompleto T incidencias (1+ incidencias))
                        (if (not incidencia)
                          (setq incidencia
                                (list "contención"
                                      (strcat "candidato de área " (rtos superficie 2 8)
                                              " sin contención certificada en original y algún padre de área mayor")
                                      nivel (* signo nivel paso)))
                        )
                      )
                      (setq exclusiones (1+ exclusiones))
                    )
                    (mce:descartar region)
                    (mce:descartar fragmento)
                  )
                )
              )
              (progn
                ;; Rechazo de validación nativa/forma: el motivo medido viaja en
                ;; el segundo elemento de mce:region-agua.
                (if (mce:pieza-abierta fragmento)
                  ;; S1–S3 — Pieza nativa abierta de esta MISMA llamada Offset.
                  ;; No se informa ni se retira todavía: primero se resuelve la
                  ;; admisión conjunta. Así no se emite un aviso incompleto falso
                  ;; si el grupo resulta aceptable y no se contamina la rama
                  ;; individual válida de otro fragmento.
                  (setq abiertos (cons (list fragmento indice-fragmento motivo) abiertos))
                  (progn
                    (setq incompleto T incidencias (1+ incidencias))
                    ;; El primer rechazo de validación individual recibe metadata
                    ;; acotada una sola vez: motivo, índice/total, tipo y hueco
                    ;; WCS. La prueba conjunta ya no es diagnóstica: es la
                    ;; admisión real de mce:region-conjunta.
                    (if (not incidencia-region)
                      (progn
                        (setq incidencia-region
                              (list "REGION"
                                    (strcat
                                      (if motivo motivo "AddRegion no produjo una región válida")
                                      (mce:diagnostico-fragmento
                                        fragmento indice-fragmento (length fragmentos)))
                                    nivel (* signo nivel paso)))
                        (if (not incidencia)
                          (setq incidencia incidencia-region
                                region-en-incidencia T)
                        )
                      )
                    )
                    (mce:descartar fragmento)
                  )
                )
              )
            )
          )
          ;; S1–S3 — Conjunto de piezas abiertas de esta llamada Offset. La
          ;; admisión nativa se prueba sobre COPIA con las piezas reales todavía
          ;; presentes y sin la cota diagnóstica de 8, que nunca fue límite de
          ;; aceptación. Un solo fragmento no forma contorno compuesto: se
          ;; resuelve como rechazo individual para no inventar un grupo.
          (cond
            ((cdr abiertos)
              (setq piezas (mapcar 'car (reverse abiertos))
                    analisis (mce:region-conjunta piezas)
                    region-conjunta (car analisis)
                    motivo-conjunto (cadr analisis)
                    admitida nil menor nil duplicado nil)
              (if region-conjunta
                (progn
                  (setq superficie (vla-get-Area region-conjunta))
                  (foreach par padres
                    (setq area-padre (vla-get-Area (car par)))
                    (if (< superficie (- area-padre tolerancia))
                      (setq menor T)
                    )
                  )
                  ;; Mismas condiciones que la rama individual: área sobre la
                  ;; tolerancia, menor que un padre y contenida en el original Y
                  ;; en ese mismo padre mayor, todo por Boolean completo.
                  (if (and (> superficie tolerancia) menor
                           (mce:contenida region-conjunta original tolerancia))
                    (foreach par padres
                      (setq area-padre (vla-get-Area (car par)))
                      (if (and (not admitida)
                               (< superficie (- area-padre tolerancia))
                               (mce:contenida region-conjunta (car par) tolerancia))
                        (setq admitida T)
                      )
                    )
                  )
                  (cond
                    (admitida
                      ;; Dedup del nivel, igual que una superficie individual.
                      (foreach par nuevos
                        (if (and (equal superficie (vla-get-Area (car par)) tolerancia)
                                 (mce:contenida region-conjunta (car par) tolerancia))
                          (setq duplicado T)
                        )
                      )
                      (if duplicado
                        ;; Superficie repetida: se retiran la región y TODAS las
                        ;; piezas del conjunto juntas, sin dejar piezas sueltas.
                        (progn
                          (mce:descartar region-conjunta)
                          (foreach pieza piezas (mce:descartar pieza))
                        )
                        (progn
                          ;; Un solo contorno lógico: cada pieza nativa se conserva
                          ;; tal cual (sin Closed2, sin reajuste, sin polilínea) y
                          ;; la región conjunta queda como padre del nivel
                          ;; siguiente; se retira al terminar ese nivel posterior.
                          (foreach pieza piezas (mce:azul pieza capa))
                          (setq nuevos (cons (list region-conjunta nivel) nuevos)
                                niveles (max niveles nivel)
                                compuestos (1+ compuestos))
                        )
                      )
                    )
                    (T
                      ;; Igual que la rama individual: bajo la tolerancia o sin
                      ;; reducción es exclusión ordinaria; con reducción pero sin
                      ;; contención, incidencia de contención.
                      (if (and (> superficie tolerancia) menor)
                        (progn
                          (setq incompleto T incidencias (1+ incidencias))
                          (if (not incidencia)
                            (setq incidencia
                                  (list "contención"
                                        (strcat "conjunto de " (itoa (length piezas))
                                                " piezas nativas de área " (rtos superficie 2 8)
                                                " sin contención certificada en original y algún padre de área mayor")
                                        nivel (* signo nivel paso)))
                          )
                        )
                        (setq exclusiones (1+ exclusiones))
                      )
                      (mce:descartar region-conjunta)
                      (foreach pieza piezas (mce:descartar pieza))
                    )
                  )
                )
                (progn
                  ;; Sin región conjunta única: no se adivina propiedad ni se
                  ;; acepta geometría dudosa. Se informa el motivo medido y se
                  ;; retiran todas las piezas del conjunto juntas.
                  (setq incompleto T incidencias (1+ incidencias))
                  (if (not incidencia)
                    (setq incidencia
                          (list "conjunto"
                                (strcat "prueba conjunta de " (itoa (length piezas))
                                        " piezas abiertas de la misma llamada Offset: "
                                        (if motivo-conjunto motivo-conjunto "sin región única"))
                                nivel (* signo nivel paso)))
                  )
                  (foreach pieza piezas (mce:descartar pieza))
                )
              )
              (setq abiertos nil)
            )
            ((car abiertos)
              ;; Un solo fragmento abierto no forma un contorno compuesto; se
              ;; resuelve con la metadata individual, sin llamar a AddRegion
              ;; sobre una sola pieza ni inventar un grupo.
              (setq incompleto T incidencias (1+ incidencias))
              (if (not incidencia-region)
                (progn
                  (setq incidencia-region
                        (list "REGION"
                              (strcat
                                (if (caddr (car abiertos)) (caddr (car abiertos))
                                  "la curva suave no quedó cerrada")
                                (mce:diagnostico-fragmento
                                  (car (car abiertos)) (cadr (car abiertos)) (length fragmentos)))
                              nivel (* signo nivel paso)))
                  (if (not incidencia)
                    (setq incidencia incidencia-region
                          region-en-incidencia T)
                  )
                )
              )
              (mce:descartar (car (car abiertos)))
              (setq abiertos nil)
            )
          )
        )
      )
    )
    ;; Ambos signos ya se probaron: recién ahora se retiran los padres del nivel.
    ;; La REGION original nunca se retira aquí; vive hasta el final.
    (foreach par padres
      (if (not (eq (car par) original)) (mce:descartar (car par)))
    )
    (setq padres nuevos)
    (setq nivel (1+ nivel))
  )
  (mce:descartar original)
  (princ (strcat "\nAgua: separación " (rtos paso 2 8)
                 "; niveles interiores " (itoa niveles)
                 "; último nivel probado " (itoa nivel-probado) "."))
  (if (> compuestos 0)
    (princ (strcat "\n  Contornos compuestos aceptados: " (itoa compuestos)
                   " (piezas nativas conservadas como un único contorno lógico; la región conjunta solo se usa como padre temporal)."))
  )
  (if incompleto
    (progn
      (if incidencia
        (princ (strcat "\nAviso: " (car incidencia)
                       " en nivel " (itoa (caddr incidencia))
                       " (desfase " (rtos (cadddr incidencia) 2 8) "): "
                       (cadr incidencia)
                       ". Se conserva lo válido; relleno completo NO certificado."))
        (princ "\nAviso: se conservó lo válido; relleno completo NO certificado.")
      )
      (if (> incidencias 1)
        (princ (strcat "\n  Incidencias adicionales registradas: " (itoa (1- incidencias)) "."))
      )
      (if (and incidencia-region (not region-en-incidencia))
        (princ (strcat "\n  Primer rechazo REGION en nivel " (itoa (caddr incidencia-region))
                       " (desfase " (rtos (cadddr incidencia-region) 2 8) "): "
                       (cadr incidencia-region)
                       ". Informativo; no altera aceptación, cierre ni relleno."))
      )
    )
    (princ "\nBúsqueda interior agotada dentro de la tolerancia geométrica.")
  )
  (if (> exclusiones 0)
    (princ (strcat "\n  Candidatos descartados por área insuficiente o sin reducción: " (itoa exclusiones) "."))
  )
  medidas
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

;;; --- Rótulo interior (S1–S2): envolvente conservadora, búsqueda acotada y
;;; --- hueco de trama. La posición se certifica contra la REGION del contorno
;;; --- FINAL (SPLINE incluida) por diferencia REGION/Boolean; los vértices de
;;; --- captura y las muestras del contorno solo filtran y ordenan candidatos.
;;; --- Ríos: sin cambios en esta ruta.

(defun mce:lista-coordenadas (valor / lista)
  ;; Los métodos ActiveX por referencia pueden entregar un safearray o una
  ;; variante que lo contiene. Se prueba la forma documentada y después el
  ;; desempaquetado; un fallo real de ambas aborta con mensaje propio.
  (setq lista (vl-catch-all-apply 'vlax-safearray->list (list valor)))
  (if (vl-catch-all-error-p lista)
    (progn
      (setq lista (vl-catch-all-apply
                    '(lambda () (vlax-safearray->list (vlax-variant-value valor)))))
      (mce:interrupcion lista)
      (if (vl-catch-all-error-p lista)
        (mce:fallar "No se pudo leer un extremo de la caja WCS.")
      )
    )
  )
  lista
)

(defun mce:caja (obj / caja minimo maximo)
  ;; GetBoundingBox devuelve extremos WCS alineados a los ejes, no OCS ni UCS.
  (setq caja (vl-catch-all-apply '(lambda () (vla-GetBoundingBox obj 'minimo 'maximo))))
  (mce:interrupcion caja)
  (if (vl-catch-all-error-p caja)
    (mce:fallar "No se pudo medir la caja WCS de una entidad propia.")
  )
  (list (mce:lista-coordenadas minimo) (mce:lista-coordenadas maximo))
)

(defun mce:caja-medidas (caja)
  ;; Semiancho, semialto y centro XY de una caja WCS ya medida con mce:caja.
  (list (/ (- (car (cadr caja)) (car (car caja))) 2.0)
        (/ (- (cadr (cadr caja)) (cadr (car caja))) 2.0)
        (list (/ (+ (car (car caja)) (car (cadr caja))) 2.0)
              (/ (+ (cadr (car caja)) (cadr (cadr caja))) 2.0)))
)

(defun mce:muestras-contorno (contorno / largo i puntos valores z)
  ;; Referencia de interiores para filtrar candidatos: en una LWPOLYLINE cerrada
  ;; son sus vértices EXACTOS (el contorno recto real); en una SPLINE, 129
  ;; muestras por longitud de la curva FINAL. Ambas son solo heurística de
  ;; búsqueda: el certificado es la diferencia REGION/Boolean, nunca esta lista ni
  ;; sus esquinas.
  (if (= (vla-get-ObjectName contorno) "AcDbPolyline")
    (progn
      (setq valores (vlax-get contorno 'Coordinates) z (mce:cota contorno))
      (while valores
        (setq puntos (cons (list (car valores) (cadr valores) z) puntos)
              valores (cddr valores))
      )
      (reverse puntos)
    )
    (progn
      (setq largo (vlax-curve-getDistAtParam contorno (vlax-curve-getEndParam contorno))
            i 0)
      (while (<= i 128)
        (setq puntos (cons (vlax-curve-getPointAtDist contorno (* largo (/ i 128.0))) puntos)
              i (1+ i))
      )
      (reverse puntos)
    )
  )
)

(defun mce:alejamiento (punto contorno / cercano)
  ;; Distancia exacta al contorno final completo, WCS. Ordena candidatos: un
  ;; punto exterior también está lejos, así que no certifica nada por sí sola.
  (setq cercano (vlax-curve-getClosestPointTo contorno punto))
  (distance punto cercano)
)

(defun mce:holgura (punto muestras contorno radio / d)
  ;; Filtro barato: interior según el muestreo del contorno y distancia mínima
  ;; `radio` a la curva final. Devuelve el alejamiento o nil.
  (setq d (mce:alejamiento punto contorno))
  (if (and (mce:dentro punto muestras) (>= d radio)) d)
)

(defun mce:region-rotulo (contorno / copia resultado regiones region)
  ;; S1 — REGION de referencia del contorno FINAL (LWPOLYLINE o SPLINE) para
  ;; certificar la posición del rótulo. Reutiliza el patrón nativo de
  ;; mce:region-agua SIN duplicar ni relajar sus guardas de relleno de agua: aquí
  ;; solo se exige copia válida, AddRegion sin error, exactamente una región y
  ;; área positiva. Orden de propiedad igual que mce:region-conjunta: primero se
  ;; enumeran y registran TODAS las regiones devueltas y solo después se retira la
  ;; copia, de modo que un fallo de borrado nunca deje regiones fuera del
  ;; rollback. La región se retira al terminar el rótulo o con mce:limpiar.
  (setq copia (mce:registrar (vla-Copy contorno))
        resultado (vl-catch-all-apply 'vla-AddRegion
                    (list mce:espacio (mce:vector-objetos (list copia)))))
  (mce:interrupcion resultado)
  (if (vl-catch-all-error-p resultado)
    ;; Sin regiones devueltas: se retira la copia y se conserva el diagnóstico.
    (progn
      (mce:descartar copia)
      (mce:fallar
        (strcat "Rótulo: el contorno final no produce una región de referencia ("
                (vl-catch-all-error-message resultado) "); se retira la ejecución."))
    )
  )
  ;; B1 — Registrar todas antes de cualquier limpieza que pueda abortar.
  (setq regiones (vlax-safearray->list (vlax-variant-value resultado)))
  (foreach region regiones (mce:registrar region))
  (mce:descartar copia)
  (if (/= (length regiones) 1)
    (progn
      (foreach region regiones (mce:descartar region))
      (mce:fallar "Rótulo: el contorno final no produce una única región; se retira la ejecución.")
    )
  )
  (if (not (> (vla-get-Area (car regiones)) 1e-16))
    (progn
      (mce:descartar (car regiones))
      (mce:fallar "Rótulo: la región de referencia tiene superficie nula; se retira la ejecución.")
    )
  )
  (car regiones)
)

(defun mce:disco-region (centro radio / circulo copia resultado regiones region)
  ;; Disco temporal de certificación: círculo propio, copia y AddRegion. Ambas
  ;; formas nativas se registran al crearse y se retiran aquí; la REGION
  ;; devuelta queda registrada para que la retire quien la pidió.
  (setq circulo (mce:registrar (vla-AddCircle mce:espacio (vlax-3d-point centro) radio))
        copia (mce:registrar (vla-Copy circulo))
        resultado (vl-catch-all-apply 'vla-AddRegion
                    (list mce:espacio (mce:vector-objetos (list copia)))))
  (mce:interrupcion resultado)
  (if (vl-catch-all-error-p resultado)
    (progn
      (mce:descartar circulo)
      (mce:descartar copia)
      (mce:fallar "Rótulo: AddRegion no pudo construir el disco de certificación; se retira la ejecución.")
    )
  )
  (setq regiones (vlax-safearray->list (vlax-variant-value resultado)))
  (foreach region regiones (mce:registrar region))
  (mce:descartar circulo)
  (mce:descartar copia)
  (if (/= (length regiones) 1)
    (progn
      (foreach region regiones (mce:descartar region))
      (mce:fallar "Rótulo: el disco de certificación no produjo una única región; se retira la ejecución.")
    )
  )
  (car regiones)
)

(defun mce:libre (centro radio region / disco tolerancia dentro)
  ;; Certificado exacto de una posición: la REGION del disco debe quedar
  ;; contenida en la REGION del contorno final, medida por diferencia
  ;; REGION/Boolean sobre copias completas (mce:contenida), no por muestras.
  (setq disco (mce:disco-region centro radio)
        tolerancia (max 1e-12 (* 1e-6 pi radio radio))
        dentro (mce:contenida disco region tolerancia))
  (mce:descartar disco)
  dentro
)

(defun mce:envolvente-dentro-p (centro radio muestras / i angulo valido)
  ;; Pre-filtro barato ANTES del Boolean: el centro y 8 puntos del borde de la
  ;; envolvente deben quedar interiores según el muestreo del contorno. No
  ;; certifica nada; solo evita llevar a la diferencia REGION/Boolean un disco
  ;; completamente exterior, que no puede certificar contención. Un disco que
  ;; corta el borde sí se lleva: el Boolean lo rechaza por superficie restante.
  (setq valido (mce:dentro centro muestras) i 0)
  (while (and valido (< i 8))
    (setq angulo (* i (/ pi 4.0))
          valido (mce:dentro (list (+ (car centro) (* radio (cos angulo)))
                                   (+ (cadr centro) (* radio (sin angulo)))) muestras)
          i (1+ i))
  )
  valido
)

(defun mce:certificar (candidatos radio muestras region limite / ubicado)
  ;; Acotado: solo las posiciones mejor ordenadas se prueban por Boolean contra
  ;; la región final; la primera contenida gana y las demás no se evalúan.
  (while (and candidatos (not ubicado) (> limite 0))
    (if (and (mce:envolvente-dentro-p (car candidatos) radio muestras)
             (mce:libre (car candidatos) radio region))
      (setq ubicado (car candidatos))
    )
    (setq candidatos (cdr candidatos) limite (1- limite))
  )
  ubicado
)

(defun mce:candidatos-rotulo (contorno muestras z radio
                              / xmin xmax ymin ymax paso-x paso-y i j p d lista holgado
                                refinados)
  ;; Rejilla 7×7 de nodos interiores de la caja de muestras y refinamiento 5×5
  ;; de media celda alrededor del nodo más holgado. Cada nodo pasa el filtro
  ;; barato de mce:holgura; el orden final es por alejamiento descendente.
  (setq xmin (apply 'min (mapcar 'car muestras)) xmax (apply 'max (mapcar 'car muestras))
        ymin (apply 'min (mapcar 'cadr muestras)) ymax (apply 'max (mapcar 'cadr muestras))
        paso-x (/ (- xmax xmin) 8.0) paso-y (/ (- ymax ymin) 8.0) i 1)
  (while (< i 8)
    (setq j 1)
    (while (< j 8)
      (setq p (list (+ xmin (* i paso-x)) (+ ymin (* j paso-y)) z))
      (if (setq d (mce:holgura p muestras contorno radio))
        (setq lista (cons (list p d) lista)
              holgado (if (or (not holgado) (> d (cadr holgado))) (list p d) holgado))
      )
      (setq j (1+ j))
    )
    (setq i (1+ i))
  )
  (if holgado
    (progn
      (setq i -2)
      (while (<= i 2)
        (setq j -2)
        (while (<= j 2)
          (setq p (list (+ (car (car holgado)) (* i paso-x 0.5))
                        (+ (cadr (car holgado)) (* j paso-y 0.5)) z))
          (if (setq d (mce:holgura p muestras contorno radio))
            (setq refinados (cons (list p d) refinados)))
          (setq j (1+ j))
        )
        (setq i (1+ i))
      )
    )
  )
  (mapcar 'car (vl-sort (append refinados lista) '(lambda (a b) (> (cadr a) (cadr b)))))
)

(defun mce:ubicar-rotulo (contorno centro muestras region radio z / ubicado)
  ;; Orden de búsqueda: centroide real primero; después la rejilla acotada. Como
  ;; máximo se certifican el centroide y 4 posiciones de rejilla por tamaño (5 en
  ;; total): la distancia al contorno final solo filtra y ordena, la diferencia
  ;; REGION/Boolean decide.
  (if (and (mce:holgura centro muestras contorno radio)
           (mce:envolvente-dentro-p centro radio muestras)
           (mce:libre centro radio region))
    centro
    (mce:certificar (mce:candidatos-rotulo contorno muestras z radio) radio muestras region 4)
  )
)

(defun mce:centrar-texto (texto ancla destino / caja centro desplazamiento)
  ;; Justificación media-centro y rotación 0: se corrige el punto de alineación
  ;; una sola vez para que el centro de la caja WCS real coincida con `destino`.
  ;; Devuelve la caja WCS definitiva, que es la que se certifica.
  (setq caja (mce:caja texto) centro (caddr (mce:caja-medidas caja)))
  (setq desplazamiento (list (- (car destino) (car centro)) (- (cadr destino) (cadr centro))))
  (vla-put-TextAlignmentPoint texto
    (vlax-3d-point (list (+ (car ancla) (car desplazamiento))
                         (+ (cadr ancla) (cadr desplazamiento))
                         (caddr destino))))
  (mce:caja texto)
)

(defun mce:forma-hueco (hueco capa / centro forma)
  ;; Contorno temporal no asociativo que despeja la trama alrededor del rótulo:
  ;; círculo para el tag y rectángulo para el texto. Se registra al crearse y se
  ;; retira después de Evaluate; en error lo retira mce:limpiar.
  (setq centro (cadr hueco))
  (if (= (car hueco) "circulo")
    (progn
      (setq forma (mce:registrar (vla-AddCircle mce:espacio (vlax-3d-point centro) (caddr hueco))))
      (vla-put-Layer forma capa)
      (vla-put-Color forma 256)
      forma
    )
    (mce:poligono
      (list (list (- (car centro) (caddr hueco)) (- (cadr centro) (cadddr hueco)) (caddr centro))
            (list (+ (car centro) (caddr hueco)) (- (cadr centro) (cadddr hueco)) (caddr centro))
            (list (+ (car centro) (caddr hueco)) (+ (cadr centro) (cadddr hueco)) (caddr centro))
            (list (- (car centro) (caddr hueco)) (+ (cadr centro) (cadddr hueco)) (caddr centro)))
      capa T)
  )
)

(defun mce:trama (contorno patron escala verde capa hueco / trama sombra)
  (setq trama (mce:registrar (vla-AddHatch mce:espacio 1 patron :vlax-false)))
  ;; 1 = ANSI predefinido, como el resto del proyecto (el 0 del ejemplo de
  ;; Autodesk selecciona un patrón definido por el usuario y no aplica aquí).
  ;; AutoCAD exige el bucle exterior antes de consultar/modificar el HATCH.
  (vla-AppendOuterLoop trama (mce:vector-objetos (list contorno)))
  (if hueco
    (progn
      ;; S1 — Hueco interior: bucle no asociativo temporal que se retira tras
      ;; Evaluate. HatchStyle 0 es el estilo "normal" (islas alternadas), así
      ;; que el rótulo queda despejado sin máscaras ni cambios en el resto del
      ;; dibujo; los desfases de agua no pasan por esta ruta.
      (vla-put-HatchStyle trama 0)
      (setq sombra (mce:forma-hueco hueco capa))
      (if (vl-catch-all-error-p
            (vl-catch-all-apply 'vla-AppendInnerLoop
              (list trama (mce:vector-objetos (list sombra)))))
        (mce:fallar "No se pudo añadir el hueco interior de la trama; se retira la ejecución.")
      )
    )
  )
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
  ;; Normal: el hueco ya está evaluado y la forma temporal no se conserva.
  (if sombra (mce:descartar sombra))
  trama
)

(defun mce:texto-rotulo (centro contenido altura capa / texto)
  ;; TEXT simple, horizontal, centrado medio en WCS; no se generan códigos MTEXT.
  ;; Ruta compartida por ríos y polígonos: mismos atributos y mismas capas.
  (setq texto (mce:registrar (vla-AddText mce:espacio contenido (vlax-3d-point centro) altura)))
  (vla-put-StyleName texto (getvar "TEXTSTYLE"))
  (vla-put-Height texto altura)
  (vla-put-Layer texto capa)
  (vla-put-Color texto 256)
  (vla-put-Rotation texto 0.0)
  ;; Booleanos documentados: texto legible aunque el estilo esté invertido.
  (vla-put-Backward texto :vlax-false)
  (vla-put-UpsideDown texto :vlax-false)
  (vla-put-Alignment texto 10)
  (vla-put-TextAlignmentPoint texto (vlax-3d-point centro))
  texto
)

(defun mce:rio-marco (original tol / largo tangente norma normal giro)
  ;; S1–S2 — Marco local en la mitad de la longitud del eje: tangente unitaria XY,
  ;; normal EXTERIOR automática (+Y si el tramo es horizontal dominante, -X si es
  ;; vertical dominante; ejes WCS de este repositorio) y giro legible. La normal no
  ;; depende del sentido de dibujo; el giro se corrige para no quedar boca abajo.
  (setq largo (vlax-curve-getDistAtParam original (vlax-curve-getEndParam original))
        tangente (vlax-curve-getFirstDeriv original
                   (vlax-curve-getParamAtDist original (/ largo 2.0)))
        norma (distance '(0.0 0.0 0.0) tangente))
  (if (<= norma tol)
    (mce:fallar "Rótulo del río: tangente no certificable en la mitad de la longitud.")
  )
  (setq normal (if (>= (abs (car tangente)) (abs (cadr tangente)))
                 (list 0.0 1.0 0.0)
                 (list -1.0 0.0 0.0))
        giro (atan (cadr tangente) (car tangente)))
  (if (> giro (* 0.5 pi)) (setq giro (- giro pi)))
  ;; El desempate en el límite -90° se incluye: un tramo vertical invertido da el
  ;; mismo giro que el directo (la normal ya era independiente del sentido).
  (if (<= giro (* -0.5 pi)) (setq giro (+ giro pi)))
  (list (list (/ (car tangente) norma) (/ (cadr tangente) norma) 0.0) normal giro)
)

(defun mce:rio-curvas (original / curvas obj borrado tipo)
  ;; Instantánea ANTES del TEXT: curvas vivas ya registradas por el generador. No se
  ;; infiere el conjunto del paso nominal —Ondulada puede reducirlo— ni del sentido de
  ;; Offset. El estado borrado se consulta PRIMERO: solo un borrado CONFIRMADO permite
  ;; omitir un recurso (son los intentos descartados del generador). Un estado de
  ;; borrado desconocido o un tipo ilegible cierran el paso en lugar de omitir en
  ;; silencio: ESC sigue propagándose por mce:interrupcion antes de cada fallo.
  (foreach obj mce:objetos
    (setq borrado (vl-catch-all-apply 'vlax-erased-p (list obj)))
    (mce:interrupcion borrado)
    (if (vl-catch-all-error-p borrado)
      (mce:fallar
        (strcat "Rótulo del río: no se pudo certificar el estado de borrado de un"
                " recurso propio; se retira la ejecución sin resultados parciales."))
    )
    (if (not borrado)
      (progn
        (setq tipo (vl-catch-all-apply 'vla-get-ObjectName (list obj)))
        (mce:interrupcion tipo)
        (if (vl-catch-all-error-p tipo)
          (mce:fallar
            (strcat "Rótulo del río: no se pudo leer el tipo de un recurso vivo del"
                    " conjunto; se retira la ejecución sin resultados parciales."))
        )
        (if (and (= (type tipo) 'STR) (wcmatch tipo "AcDbPolyline,AcDbSpline"))
          (setq curvas (cons obj curvas))
        )
      )
    )
  )
  ;; Nunca certificar un conjunto vacío ni sin el eje: el rótulo se separa de ESTAS
  ;; curvas, así que un conjunto incompleto es un fallo, no una aproximación.
  (if (not curvas)
    (mce:fallar
      (strcat "Rótulo del río: no quedó ninguna curva viva certificable para separar el"
              " rótulo; se retira la ejecución sin resultados parciales."))
  )
  (if (not (member original curvas))
    (mce:fallar
      (strcat "Rótulo del río: el eje original no figura entre las curvas vivas"
              " certificadas; se retira la ejecución sin resultados parciales."))
  )
  curvas
)

(defun mce:rio-libre-p (curvas centro tangente semiancho semialto capa
                        / lado forma esquinas esquina par curva punto delta x y libre)
  ;; Certificado acotado: el rectángulo ORIENTADO temporal con la tangente —el TEXT ya
  ;; ampliado por la holgura— no puede intersecar ninguna curva del río, y ninguna curva
  ;; puede quedar completa dentro de él (un tramo interior no corta ningún borde). Es
  ;; orientado, no una caja alineada a los ejes, así que en diagonales no infla la
  ;; separación. La forma se registra ANTES de las consultas nativas: ante error, el
  ;; rollback la retira.
  (setq lado (list (- (cadr tangente)) (car tangente)))
  (foreach par '((1 1) (-1 1) (-1 -1) (1 -1))
    (setq esquina (list (+ (car centro) (* semiancho (car tangente) (car par))
                                      (* semialto (car lado) (cadr par)))
                        (+ (cadr centro) (* semiancho (cadr tangente) (car par))
                                         (* semialto (cadr lado) (cadr par)))
                        (caddr centro))
          esquinas (cons esquina esquinas))
  )
  (setq forma (mce:poligono esquinas capa T) libre T)
  (foreach curva curvas
    (if (and libre (vlax-invoke forma 'IntersectWith curva 0)) (setq libre nil))
    (if libre
      (foreach punto (list (vlax-curve-getStartPoint curva) (vlax-curve-getEndPoint curva))
        (setq delta (mapcar '- punto centro)
              x (apply '+ (mapcar '* delta tangente))
              y (apply '+ (mapcar '* delta lado)))
        (if (and (<= (abs x) semiancho) (<= (abs y) semialto)) (setq libre nil))
      )
    )
  )
  (mce:descartar forma)
  libre
)

(defun mce:rotular-rio (original centro contenido altura capa tol
                        / marco tangente normal giro curvas texto caja medida semiancho
                          semialto ancla holgura limite alcance curva largo i punto
                          proyeccion destino sonda libre intento)
  ;; S1–S2 — Rótulo exclusivo de río: UNA línea recta de TEXT, paralela al tramo
  ;; central y separada por fuera del conjunto REAL de líneas. La altura pedida, la
  ;; capa, el color y el estilo siguen viniendo de mce:texto-rotulo (firma y cuerpo
  ;; intactos); aquí solo se agrega una transformación rígida —giro y traslado— en WCS,
  ;; conservando la Z del eje.
  (setq marco (mce:rio-marco original tol)
        tangente (car marco) normal (cadr marco) giro (caddr marco))
  (setq curvas (mce:rio-curvas original))
  (setq texto (mce:texto-rotulo centro contenido altura capa)
        caja (mce:caja texto)                ; rotación 0: caja WCS real del estilo
        medida (mce:caja-medidas caja)
        semiancho (car medida) semialto (cadr medida)
        ;; Centro REAL de la caja horizontal, a la Z del eje: pivote rígido del giro.
        ancla (list (car (caddr medida)) (cadr (caddr medida)) (caddr centro)))
  (if (or (<= semiancho tol) (<= semialto tol))
    (mce:fallar "Rótulo del río: el TEXT no tiene una caja medible a esta precisión.")
  )
  ;; Holgura ligera: 0.5 × alto REAL medido. El rectángulo de prueba la incluye en sus
  ;; cuatro lados, así que la caja del TEXT queda al menos a esa distancia de las curvas.
  (setq holgura semialto
        semiancho (+ semiancho holgura)
        semialto (* 2.0 semialto))
  ;; Alcance de la caja orientada sobre la normal exterior: proyección exacta del
  ;; rectángulo, no la diagonal de una caja alineada a los ejes.
  (setq alcance (+ (* (abs (+ (* (car tangente) (car normal))
                              (* (cadr tangente) (cadr normal)))) semiancho)
                   (* (abs (- (* (car tangente) (cadr normal))
                              (* (cadr tangente) (car normal)))) semialto)))
  ;; Separación inicial: extensión REAL del conjunto en el sentido de la normal. El
  ;; muestreo solo propone; el certificado —nunca la estimación— decide la posición.
  (setq limite 0.0)
  (foreach curva curvas
    (setq largo (vlax-curve-getDistAtParam curva (vlax-curve-getEndParam curva)) i 0)
    (while (<= i 16)
      (setq punto (vlax-curve-getPointAtDist curva (* largo (/ i 16.0)))
            proyeccion (+ (* (- (car punto) (car centro)) (car normal))
                          (* (- (cadr punto) (cadr centro)) (cadr normal))))
      (if (> proyeccion limite) (setq limite proyeccion))
      (setq i (1+ i))
    )
  )
  (setq destino (+ limite alcance) intento 0 libre nil)
  (while (and (not libre) (<= intento 8))
    (setq sonda (list (+ (car centro) (* destino (car normal)))
                      (+ (cadr centro) (* destino (cadr normal)))
                      (caddr centro))
          libre (mce:rio-libre-p curvas sonda tangente semiancho semialto capa))
    (if (not libre) (setq destino (+ destino holgura) intento (1+ intento)))
  )
  (if (not libre)
    (mce:fallar (strcat "Rótulo del río: no se halló una posición libre de las líneas"
                        " del río en 9 intentos con holgura de 0.5 veces el alto; se"
                        " retira la ejecución sin resultados parciales."))
  )
  ;; B1 — Transformación RÍGIDA: la caja horizontal medida gira alrededor de SU centro
  ;; real (`ancla`) y ese mismo centro se traslada al punto certificado (`sonda`). No se
  ;; reescribe `TextAlignmentPoint` después: el centro de la caja queda exactamente en
  ;; `sonda` y el rectángulo certificado contiene la tinta para cualquier estilo.
  (vla-Rotate texto (vlax-3d-point ancla) giro)
  (vla-Move texto (vlax-3d-point ancla) (vlax-3d-point sonda))
  (princ (strcat "\nRío: rótulo paralelo al tramo central, giro "
                 (rtos (/ (* giro 180.0) pi) 2 1) " grados, separado "
                 (rtos destino 2 6) " de la mitad del eje; holgura "
                 (rtos holgura 2 6) "."))
  texto
)

(defun mce:rotular (contorno centro modo contenido altura capa
                    / texto region muestras factores factor alto caja semiancho semialto
                      diagonal base margen envuelto ubicacion circulo hueco)
  ;; S1–S2 — Coloca el rótulo COMPLETO dentro del contorno FINAL: primero el
  ;; tamaño pedido y, solo si no cabe, reubicándolo y reduciendo texto y círculo
  ;; con el MISMO factor (proporciones conservadas). Envolvente conservadora: el
  ;; texto se inscribe en su círculo circunscripto y el tag usa 0.6·diagonal
  ;; (> 0.5), así que un disco certificado contiene texto, círculo y margen
  ;; aunque el estilo tenga ancho u oblicuidad distintos. El margen libre es el
  ;; 20 % de esa base. Devuelve el hueco de trama o nil.
  (if (> modo 0)
    (progn
      (setq region (mce:region-rotulo contorno)
            muestras (mce:muestras-contorno contorno)
            texto (mce:texto-rotulo centro contenido altura capa)
            factores '(1.0 0.9 0.8 0.7 0.6 0.5 0.4 0.3 0.25))
      (while (and factores (not ubicacion))
        (setq factor (car factores) factores (cdr factores) alto (* altura factor))
        (vla-put-Height texto alto)
        (vla-put-TextAlignmentPoint texto (vlax-3d-point centro))
        ;; Caja WCS REAL del TEXT: incluye estilo, ancho, oblicuidad y altura fija.
        (setq caja (mce:caja texto)
              semiancho (/ (- (car (cadr caja)) (car (car caja))) 2.0)
              semialto (/ (- (cadr (cadr caja)) (cadr (car caja))) 2.0)
              diagonal (* 2.0 (sqrt (+ (* semiancho semiancho) (* semialto semialto))))
              base (if (= modo 2) (max (* alto 1.5) (* 0.6 diagonal)) (/ diagonal 2.0))
              margen (* 0.2 base)
              envuelto (if (= modo 2)
                         (+ base margen)
                         (sqrt (+ (* (+ semiancho margen) (+ semiancho margen))
                                  (* (+ semialto margen) (+ semialto margen))))))
        (setq ubicacion (mce:ubicar-rotulo contorno centro muestras region envuelto (caddr centro)))
        (if ubicacion
          (progn
            (setq caja (mce:centrar-texto texto centro ubicacion)
                  semiancho (/ (- (car (cadr caja)) (car (car caja))) 2.0)
                  semialto (/ (- (cadr (cadr caja)) (cadr (car caja))) 2.0))
            ;; Certificado final sobre la caja definitiva: si el estilo redondea
            ;; distinto al medir, esta posición no se acepta y se prueba el
            ;; siguiente tamaño.
            (if (> (sqrt (+ (* semiancho semiancho) (* semialto semialto))) (* 1.001 base))
              (setq ubicacion nil)
            )
          )
        )
      )
      (if (not ubicacion)
        (mce:fallar
          (strcat "Rótulo: el texto y el círculo no caben completos dentro del contorno final"
                  " ni al 25 % del tamaño pedido (con la altura que el estilo permita);"
                  " se retira la ejecución sin resultados parciales."))
      )
      (if (< factor 1.0)
        (princ (strcat "\nRótulo: reducido al " (rtos (* 100.0 factor) 2 0)
                       " % del tamaño pedido para quedar completo dentro del contorno con margen."))
      )
      (if (not (equal (list (car ubicacion) (cadr ubicacion))
                      (list (car centro) (cadr centro)) 1e-8))
        (princ "\nRótulo: reubicado en el interior certificado; el centroide real no admitía la envolvente completa.")
      )
      (if (= modo 2)
        (progn
          (setq circulo (mce:registrar (vla-AddCircle mce:espacio (vlax-3d-point ubicacion) base)))
          (vla-put-Layer circulo capa)
          (vla-put-Color circulo 256)
        )
      )
      (setq hueco (if (= modo 2)
                     (list "circulo" ubicacion (+ base margen))
                     (list "rect" ubicacion (+ semiancho margen) (+ semialto margen))))
      (mce:descartar region)
      hueco
    )
  )
)

(defun C:MCELEMENTS (/ *error* mce:doc mce:espacio mce:objetos mce:capas
                       mce:archivo mce:dcl-ruta mce:dcl-id mce:variables mce:color
                       mce:undo mce:motivo mce:opciones mce:vista tipo factor modo contenido
                       puntos tol capa contorno medidas longitud centro forma rio total grupo-previo
                       hueco mce:ui-rio mce:rotulo-poligono mce:rotulo-rio)
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
      (if (= 0 (logand (getvar "UNDOCTL") 1))
        (mce:fallar "Active UNDO antes de dibujar.")
      )
      (setq grupo-previo (/= 0 (logand (getvar "UNDOCTL") 8)))
      (if grupo-previo
        (princ "\nAviso: el grupo UNDO existente seguirá abierto; un UNDO posterior puede afectar todas sus acciones previas y esta ejecución.")
      )
      (setq tipo (nth 0 mce:opciones) factor (nth 1 mce:opciones)
            modo (nth 2 mce:opciones) contenido (nth 3 mce:opciones)
            forma (nth 4 mce:opciones) rio (nth 5 mce:opciones) total (nth 6 mce:opciones)
            puntos (mce:puntos tipo)
            tol (if (= tipo 5) (mce:validar-abierta puntos) (mce:validar puntos)))
      (if (= 0 (logand (getvar "UNDOCTL") 1))
        (mce:fallar "Active UNDO antes de crear resultados.")
      )
      ;; Reconsultar antes de escribir: nunca iniciar ni cerrar una marca ajena.
      (if (/= 0 (logand (getvar "UNDOCTL") 8))
        (if (not grupo-previo)
          (princ "\nAviso: el grupo UNDO existente seguirá abierto; un UNDO posterior puede afectar todas sus acciones previas y esta ejecución.")
        )
        (progn
          (vla-StartUndoMark mce:doc)
          (setq mce:undo T)
        )
      )
      (setq capa (mce:capa (nth tipo '("MC-EDIFICACION-1" "MC-EDIFICACION-2" "MC-EDIFICACION-CIRCULAR" "MC-AREA-VERDE" "MC-MASA-AGUA" "MC-RIO")))
            contorno (cond
                       ((and (= tipo 5) (= forma 1)) (mce:suave-abierta puntos capa tol))
                       ((and (= tipo 4) (= forma 1)) (mce:suave puntos capa tol))
                       (T (mce:poligono puntos capa (/= tipo 5))))
            medidas (cond
                      ((and (= tipo 5) (= forma 1)) (mce:rio-ondulado contorno capa rio total tol))
                      ((= tipo 5) (mce:rio contorno capa rio total tol))
                      ((= tipo 4) (mce:agua contorno capa))
                      (T (mce:medidas contorno)))
            longitud (if (= tipo 5) (car medidas) (sqrt (car medidas))) centro (cadr medidas))
      (if (<= longitud tol) (mce:fallar "Figura degenerada para la precisión del dibujo."))
      ;; S1–S2 — Rótulo antes de la trama: el hueco interior necesita su tamaño
      ;; final ya medido y certificado. Sin rótulo (modo 0) no se crea nada y la
      ;; trama conserva exactamente el resultado anterior.
      (setq hueco
        (cond
          ((<= modo 0) nil)
          ;; Ríos: rótulo recto paralelo al tramo central y por fuera del conjunto real.
          ((= tipo 5)
            (progn (mce:rotular-rio contorno centro contenido (* longitud factor 0.04)
                                   capa tol)
                   nil))
          ;; Tag: texto y círculo otro 30 % mayores (62.5 % sobre la base).
          ;; El ajuste interior sigue aplicándose al conjunto si no cabe.
          (T (mce:rotular contorno centro modo contenido
                         (* longitud factor (if (= modo 2) 0.065 0.04)) capa))))
      (if (< tipo 4)
        (mce:trama contorno (nth tipo '("ANSI31" "ANSI37" "ANSI31" "ANSI36"))
                   (* longitud factor 0.02) (= tipo 3) capa hueco)
      )
      (mce:limpiar nil)
      (princ "\nMCELEMENTS: estructura creada.")
    )
    (progn (mce:limpiar T) (princ "\nMCELEMENTS cancelado."))
  )
  (princ)
)

(princ "\nMCELEMENTS cargado. Escriba MCELEMENTS para iniciar.")
(princ)
