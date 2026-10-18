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
      (add_list "Sin rótulo") (add_list "Texto centrado")
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
      ": text { label = \"Polígono: centroide real. Río: mitad de longitud.\"; }"
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
      )
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

(defun mce:suave (puntos capa / coords matriz obj tangente)
  ;; Ajuste global, no fillets ni ondas. Closed2 exige continuidad en la unión.
  (setq coords (apply 'append puntos)
        matriz (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length coords))))
        tangente (mapcar '- (cadr puntos) (last puntos)))
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
  obj
)

(defun mce:suave-abierta (puntos capa / coords matriz obj)
  ;; Se suministran tangentes nulas; su compatibilidad requiere prueba en AutoCAD.
  (setq coords (apply 'append puntos)
        matriz (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length coords)))))
  (vlax-safearray-fill matriz coords)
  (setq obj (mce:registrar
              (vla-AddSpline mce:espacio matriz
                (vlax-3d-point '(0.0 0.0 0.0)) (vlax-3d-point '(0.0 0.0 0.0)))))
  (vla-put-Layer obj capa)
  obj
)

(defun mce:terna (valores / puntos)
  (while valores
    (setq puntos (cons (list (car valores) (cadr valores) (caddr valores)) puntos)
          valores (cdddr valores)))
  (reverse puntos)
)

(defun mce:curva-rio (curva tol / nombre valores puntos direccion norma anterior actual p i peso)
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
      ;; Pesos positivos conservan la propiedad de variación decreciente.
      (foreach peso (vlax-get curva 'Weights)
        (if (<= peso 0.0) (mce:fallar "SPLINE con pesos no certificables.")))
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

(defun mce:interrupcion (resultado)
  ;; No convertir ESC atrapado por COM en un aviso de geometría incompleta.
  (if (and (vl-catch-all-error-p resultado)
           (wcmatch (strcase (vl-catch-all-error-message resultado))
                    "*CANCEL*,*QUIT*,*ABORT*,*BREAK*,*INTERRUP*"))
    (mce:fallar "Operación cancelada; se retiran los resultados propios.")
  )
)

(defun mce:region-agua (curva / copia resultado regiones region area perimetro longitud valido)
  ;; El núcleo REGION valida la curva FINAL, no solo las cuerdas de entrada.
  ;; Una región única y perímetro completo evitan aceptar lóbulos descartados.
  (if (vlax-curve-isClosed curva)
    (progn
      (setq copia (mce:registrar (vla-Copy curva))
            resultado (vl-catch-all-apply 'vla-AddRegion
                        (list mce:espacio (mce:vector-objetos (list copia)))))
      (mce:interrupcion resultado)
      (if (not (vl-catch-all-error-p resultado))
        (progn
          (setq regiones (vlax-safearray->list (vlax-variant-value resultado)))
          ;; Registrar TODOS antes de leer propiedades, incluso si se rechazan.
          (foreach region regiones (mce:registrar region))
          (if (= (length regiones) 1)
            (progn
              (setq region (car regiones) area (vla-get-Area region)
                    perimetro (vla-get-Perimeter region)
                    longitud (vlax-curve-getDistAtParam curva (vlax-curve-getEndParam curva))
                    valido (and (> area 1e-16)
                                (equal perimetro longitud (max 1e-8 (* longitud 1e-8)))))
            )
          )
        )
      )
      (mce:descartar copia)
      (if valido
        region
        (progn (foreach region regiones (mce:descartar region)) nil)
      )
    )
  )
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
                  cola nodo curva padre profundidad siguientes signo resultado
                  fragmentos fragmento region superficie aceptadas par duplicado
                  total niveles intentos incompleto)
  (setq original (mce:region-agua contorno))
  (if (not original)
    (mce:fallar "El contorno final de agua es inválido, se cruza o no produce una región simple completa.")
  )
  (setq area (vla-get-Area original) centro (vlax-get original 'Centroid)
        medidas (list area (list (car centro) (cadr centro) (mce:cota contorno)))
        paso (* 0.05 (sqrt area)) tolerancia (max 1e-16 (* area 1e-9))
        cola (list (list contorno original 0)) total 0 niveles 0 intentos 0)
  (mce:azul contorno capa)
  ;; Búsqueda por niveles. Cada nodo conserva su región para probar a sus hijos.
  (while cola
    (setq siguientes nil)
    (foreach nodo cola
      (setq curva (car nodo) padre (cadr nodo) profundidad (caddr nodo)
            aceptadas nil)
      (if (>= profundidad 256)
        (mce:fallar "Límite de agua: 256 niveles; no se garantiza relleno completo. Se retira la ejecución.")
      )
      (foreach signo '(1.0 -1.0)
        (setq intentos (1+ intentos))
        (if (> intentos 2048)
          (mce:fallar "Límite de agua: 2048 intentos de desfase. Se retira la ejecución.")
        )
        (setq resultado (vl-catch-all-apply 'vla-Offset (list curva (* signo paso))))
        (mce:interrupcion resultado)
        (if (vl-catch-all-error-p resultado)
          ;; Offset no distingue agotamiento geométrico de incompatibilidad.
          ;; Conservar lo válido, pero JAMÁS anunciar relleno completo en este caso.
          (setq incompleto T)
          (progn
            (setq fragmentos (vlax-safearray->list (vlax-variant-value resultado)))
            (foreach fragmento fragmentos (mce:registrar fragmento))
            (setq total (+ total (length fragmentos)))
            (if (> total 4096)
              (mce:fallar "Límite de agua: 4096 curvas devueltas. Se retira la ejecución.")
            )
            (foreach fragmento fragmentos
              (setq region (mce:region-agua fragmento) duplicado nil)
              (if region
                (progn
                  (setq superficie (vla-get-Area region))
                  (if (and (> superficie tolerancia)
                           (< superficie (- (vla-get-Area padre) tolerancia))
                           (mce:contenida region padre tolerancia)
                           (mce:contenida region original tolerancia))
                    (progn
                      ;; Ambos signos pueden devolver la misma solución: no duplicarla.
                      (foreach par aceptadas
                        (if (and (equal superficie (vla-get-Area (cadr par)) tolerancia)
                                 (mce:contenida region (cadr par) tolerancia))
                          (setq duplicado T)
                        )
                      )
                      (if (not duplicado)
                        (progn
                          (mce:azul fragmento capa)
                          (setq aceptadas (cons (list fragmento region (1+ profundidad)) aceptadas)
                                niveles (max niveles (1+ profundidad)))
                        )
                      )
                    )
                    (progn
                      (if (and (> superficie tolerancia)
                               (< superficie (- (vla-get-Area padre) tolerancia)))
                        (setq incompleto T)
                      )
                      (setq duplicado T)
                    )
                  )
                  (if duplicado
                    (progn (mce:descartar region) (mce:descartar fragmento))
                  )
                )
                (progn (setq incompleto T) (mce:descartar fragmento))
              )
            )
          )
        )
      )
      (setq siguientes (append aceptadas siguientes))
      (if (not (eq padre original)) (mce:descartar padre))
    )
    (setq cola siguientes)
  )
  (mce:descartar original)
  (princ (strcat "\nAgua: separación " (rtos paso 2 8) "; niveles interiores " (itoa niveles) "."))
  (if incompleto
    (princ "\nAviso: Offset falló o devolvió curvas inválidas/no contenidas. Se conserva lo válido; relleno completo NO certificado.")
    (princ "\nBúsqueda interior agotada dentro de la tolerancia geométrica.")
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
                       puntos tol capa contorno medidas longitud centro forma rio total
                       mce:ui-rio mce:rotulo-poligono mce:rotulo-rio)
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
            forma (nth 4 mce:opciones) rio (nth 5 mce:opciones) total (nth 6 mce:opciones)
            puntos (mce:puntos tipo)
            tol (if (= tipo 5) (mce:validar-abierta puntos) (mce:validar puntos)))
      (if (= 0 (logand (getvar "UNDOCTL") 1))
        (mce:fallar "Active UNDO antes de crear resultados.")
      )
      (if (/= 0 (logand (getvar "UNDOCTL") 8))
        (mce:fallar "Cierre el grupo UNDO existente antes de ejecutar MCELEMENTS.")
      )
      (vla-StartUndoMark mce:doc)
      (setq mce:undo T
            capa (mce:capa (nth tipo '("MC-EDIFICACION-1" "MC-EDIFICACION-2" "MC-EDIFICACION-CIRCULAR" "MC-AREA-VERDE" "MC-MASA-AGUA" "MC-RIO")))
            contorno (cond
                       ((and (= tipo 5) (= forma 1)) (mce:suave-abierta puntos capa))
                       ((and (= tipo 4) (= forma 1)) (mce:suave puntos capa))
                       (T (mce:poligono puntos capa (/= tipo 5))))
            medidas (cond
                      ((= tipo 5) (mce:rio contorno capa rio total tol))
                      ((= tipo 4) (mce:agua contorno capa))
                      (T (mce:medidas contorno)))
            longitud (if (= tipo 5) (car medidas) (sqrt (car medidas))) centro (cadr medidas))
      (if (<= longitud tol) (mce:fallar "Figura degenerada para la precisión del dibujo."))
      (if (< tipo 4)
        (mce:trama contorno (nth tipo '("ANSI31" "ANSI37" "ANSI31" "ANSI36"))
                   (* longitud factor 0.02) (= tipo 3) capa)
      )
      (if (and (> modo 0) (/= tipo 5))
        (if (= tipo 4)
          (princ "\nRótulo en el centroide real del contorno final; en un cóncavo puede quedar fuera.")
          (if (not (mce:dentro centro puntos))
            (princ "\nAviso: el centroide real queda fuera del contorno; se conserva esa posición.")
          )
        )
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
