# Construir el paquete de instalación de MensorCAD

`tools/build_bundle.py` arma `MensorCAD-Windows.zip`, su sidecar SHA-256, una copia standalone de `Install-MensorCAD.ps1` estampada con la versión del release y el bootstrap `install.ps1`, usando solo la biblioteca estándar de Python 3. El paquete contiene un bundle de AutoCAD (`MensorCAD.bundle`) con los 13 comandos LISP, el CUIX generado con AutoCAD y los archivos de instalación. El contrato de nombres está congelado: el ZIP sirve como adjunto de release y el instalador lo valida antes de copiar nada.

## Ruta rápida

1. Coloca `Install-MensorCAD.ps1`, `install.ps1`, `Instalar.bat`, `Desinstalar.bat` y `LICENSE` en la raíz del repositorio.
2. Construye el paquete:

   ```bash
   python3 tools/build_bundle.py --output-dir dist
   ```

3. Verifica las cuatro salidas:

   ```bash
   ls dist/MensorCAD-Windows.zip dist/MensorCAD-Windows.zip.sha256 dist/Install-MensorCAD.ps1 dist/install.ps1
   cat dist/MensorCAD-Windows.zip.sha256
   ```

4. Comprueba el contrato con las pruebas:

   ```bash
   python3 -m unittest discover -s tests -p 'test_build_bundle.py' -v
   ```

El comando imprime la ruta del ZIP, la del sidecar, la del script standalone, la del bootstrap, el SHA-256 del ZIP y cuántos archivos viajan dentro de `MensorCAD.bundle`.

## Salidas en el directorio de destino

| Salida | Contenido |
|---|---|
| `MensorCAD-Windows.zip` | Paquete de release con el inventario de la tabla siguiente |
| `MensorCAD-Windows.zip.sha256` | Una línea `<hash-sha256>  MensorCAD-Windows.zip` |
| `Install-MensorCAD.ps1` | Copia standalone estampada con `--version`, byte a byte igual a la que viaja en la raíz del ZIP |
| `install.ps1` | Bootstrap corto de la entrada remota, copia byte a byte de `--bootstrap-script`; vive **fuera** del ZIP |

El bootstrap `install.ps1` es la cuarta salida y **no** se agrega como entrada del ZIP: el inventario del ZIP no cambia. El script standalone no se agrega como una entrada extra dentro del bundle: su lugar en el paquete es la raíz del ZIP. La copia standalone y la entrada `Install-MensorCAD.ps1` del ZIP son **byte a byte iguales entre sí**, pero no iguales a la plantilla del repositorio porque esta conserva el marcador de desarrollo.

## Inventario del ZIP

| Entrada | Origen | Contenido |
|---|---|---|
| `MensorCAD.bundle/PackageContents.xml` | `PackageContents.xml` | Manifiesto del bundle, copiado byte a byte |
| `MensorCAD.bundle/Contents/Lisp/MC-*.lsp` | `lisp/MC-*.lsp` | Los 13 comandos, copiados byte a byte |
| `MensorCAD.bundle/Contents/UI/MensorCAD.cuix` | árbol `cuix/` | ZIP OPC reconstruido sin editar ningún archivo |
| `bundle.sha256` | calculado | Hash de cada archivo de `MensorCAD.bundle` |
| `Install-MensorCAD.ps1` | `Install-MensorCAD.ps1` | Instalador local estampado; misma copia que el standalone |
| `Instalar.bat` | `Instalar.bat` | Instalación por doble clic |
| `Desinstalar.bat` | `Desinstalar.bat` | Desinstalación por doble clic; delega en `Instalar.bat -Uninstall` |
| `LICENSE` | `LICENSE` | Licencia del proyecto |

En total son 20 entradas: 15 archivos dentro de `MensorCAD.bundle` (`PackageContents.xml`, 13 LISP y el CUIX) y 5 en la raíz del ZIP. No hay más entradas y no hay anidamiento extra. El sidecar `MensorCAD-Windows.zip.sha256` vive fuera del ZIP, junto a él, con una sola línea:

```text
<hash-sha256>  MensorCAD-Windows.zip
```

`bundle.sha256` queda fuera de `MensorCAD.bundle` en la raíz del ZIP y usa rutas relativas al bundle:

```text
<hash-sha256>  Contents/Lisp/MC-AREA.lsp
...
<hash-sha256>  PackageContents.xml
```

Las líneas van ordenadas, con hash en minúsculas, dos espacios separadores y rutas con `/`.

## Versión estampada en el artefacto

La plantilla `Install-MensorCAD.ps1` contiene exactamente una asignación marcada:

```text
$script:MensorCadReleaseVersion = '__MENSORCAD_RELEASE_VERSION__'
```

El constructor lee la plantilla como **bytes**, exige exactamente un marcador y
reemplaza solo ese marcador por `--version`, que ya fue validado contra
`Version`/`AppVersion` del manifiesto. No decodifica ni reescribe el archivo: el
BOM UTF-8 y los fines de línea de la plantilla se conservan. La plantilla nunca
se modifica; si se ejecuta sin construir, el badge muestra «desarrollo».

El marcador debe aparecer exactamente una vez. Ausente, duplicado o inválido
produce un rechazo **antes** de crear o reemplazar cualquier salida. La salida
Ninguna de las cuatro salidas (`MensorCAD-Windows.zip`,
`MensorCAD-Windows.zip.sha256`, `Install-MensorCAD.ps1` e `install.ps1`) puede ser
el mismo archivo que la plantilla del instalador **ni** que el bootstrap fuente. Usar la raíz del repositorio como `--output-dir` se
rechaza sin escribir nada. Ya no existe la omisión de copia cuando origen y
destino coincidían, porque produciría un artefacto sin estampar o mutaría la
fuente.

Los artefactos son deterministas y idénticos entre sí. Su hash difiere del hash
de la plantilla únicamente por el token de versión renderizado; las fuentes LISP,
XML y CUIX se copian sin cambios.

## Qué se valida antes de escribir

El constructor valida todo primero y recién después crea la salida. Si algo falla, termina con código distinto de cero, explica el motivo en `stderr` y deja intactas las salidas anteriores.

| Validación | Regla |
|---|---|
| Versión | `--version` (por defecto `0.1.0`) debe tener formato `MAJOR.MINOR.PATCH` y coincidir con `Version`/`AppVersion` de `PackageContents.xml` |
| Plantilla | `--install-script` debe contener exactamente un marcador `__MENSORCAD_RELEASE_VERSION__`; se estampa antes de cualquier escritura |
| Solapamiento | Las cuatro salidas (`MensorCAD-Windows.zip`, `MensorCAD-Windows.zip.sha256`, `Install-MensorCAD.ps1`, `install.ps1`) se comparan con las **dos** fuentes de script: no pueden ser el mismo archivo que `--install-script` ni que `--bootstrap-script`; se rechaza antes de escribir |
| Bootstrap | `--bootstrap-script` debe ser un archivo regular y no puede contener el marcador `__MENSORCAD_RELEASE_VERSION__`: la versión del producto la lleva solo el instalador real |
| Manifiesto | Raíz `ApplicationPackage`, `Name="MensorCAD"`, `RuntimeRequirements` con `OS="Win64"` y `Platform="AutoCAD*"`; no se declara una versión mínima (`SeriesMin`/`SeriesMax`) ni un locale (`SupportedLocales`) que el proyecto no haya pedido |
| Componentes LISP | Un `ComponentEntry` por archivo, `PerDocument="True"`, sin `LoadOnAutoCADStartup` |
| Componentes CUIX | Exactamente `./Contents/UI/MensorCAD.cuix` |
| Correspondencia | El conjunto de archivos de `lisp/` y el de entradas LISP del manifiesto deben ser idénticos; un archivo ajeno en `lisp/` es un error, nunca una omisión silenciosa |
| CUIX | Debe contener `[Content_Types].xml`; se empaqueta todo el árbol, incluidas rutas como `_rels/.rels` |
| Entradas inseguras | Se rechazan enlaces simbólicos, rutas absolutas, componentes `..`, archivos ocultos (salvo `.rels`) y `__pycache__` |
| Salida | `--output-dir` no puede ser igual a ni quedar dentro de `lisp/` ni de `cuix/` |
| Colisiones | Antes de escribir se rechazan enlaces simbólicos o directorios en `--output-dir` y en las cuatro rutas de salida (`MensorCAD-Windows.zip`, su sidecar, `Install-MensorCAD.ps1` e `install.ps1`) |
| Duplicados | Se rechazan rutas del CUIX o LISP que colisionen al ignorar mayúsculas, como en Windows |

Sobre el CUIX: el contenido proviene de AutoCAD y se reconstruye sin tocar metadatos internos. Si `Menu_Package_Info.xml` menciona partes que no existen como archivo físico (`VirtualMNRRoot`), el paquete se construye igual; no es motivo de rechazo ni de edición.

## Detalles

| Tema | Decisión |
|---|---|
| Determinismo | Marcas de tiempo ZIP fijas, orden estable y compresión `deflate`: dos construcciones con las mismas fuentes producen bytes idénticos |
| Reproducibilidad | El ZIP no incluye fechas del sistema ni rutas absolutas del equipo |
| Escritura de salida | Se construye en un directorio temporal del sistema; al publicar se usan temporales exclusivos (`mkstemp`) en el directorio destino y reemplazos atómicos por archivo |
| Temporales | Nunca se sigue ni se borra un temporal preexistente: el constructor solo elimina el temporal propio, así que un `.MensorCAD-Windows.zip.tmp` ajeno queda intacto |
| Transacción | El reemplazo es atómico por archivo, no una transacción de cuatro archivos: las validaciones y colisiones se resuelven antes de mutar nada, pero un fallo inesperado de E/S a mitad de la publicación puede dejar una mezcla de archivos nuevos y anteriores |
| Fuentes | `lisp/`, `cuix/`, `PackageContents.xml` y la plantilla del instalador solo se leen; nunca se modifican |
| Plantilla sin construir | Muestra «desarrollo» en el badge; no inventa una versión |
| Firma | SHA-256 detecta corrupción, no autentica al publicador |

## Uso en scripts

El constructor acepta rutas explícitas para poder probarse con fixtures aislados:

```bash
python3 tools/build_bundle.py \
  --output-dir dist \
  --version 0.1.0 \
  --package-contents PackageContents.xml \
  --lisp-dir lisp \
  --cuix-dir cuix \
  --install-script Install-MensorCAD.ps1 \
  --bootstrap-script install.ps1 \
  --bat-script Instalar.bat \
  --uninstall-bat-script Desinstalar.bat \
  --license LICENSE
```

Las banderas de ruta son opcionales y, por defecto, apuntan a la raíz del repositorio. `--bootstrap-script` acepta una ruta explícita para fixtures aislados y solo se copia byte a byte: no se estampa ni se reescribe.

## Límites de esta verificación

- Las pruebas se ejecutan en Linux con Python 3 y usan directorios temporales; no tocan `Program Files`.
- El armado real (`python3 tools/build_bundle.py --output-dir dist`) necesita que existan `Install-MensorCAD.ps1`, `install.ps1`, `Instalar.bat` y `Desinstalar.bat`; es responsabilidad de la integración final.
- Ninguna prueba de este documento demuestra que AutoCAD cargue el bundle: eso requiere una ejecución manual en Windows con AutoCAD.

## Lista de comprobación

- [ ] El ZIP contiene únicamente las 20 entradas del inventario (15 del bundle y 5 de la raíz).
- [ ] `bundle.sha256` cubre cada archivo de `MensorCAD.bundle` y ninguna ruta fuera de él.
- [ ] `MensorCAD-Windows.zip.sha256` nombra `MensorCAD-Windows.zip`.
- [ ] `dist/Install-MensorCAD.ps1` existe, no contiene el marcador y es byte a byte igual a la entrada `Install-MensorCAD.ps1` del ZIP.
- [ ] `dist/install.ps1` existe, es byte a byte igual a `install.ps1` del repositorio y no aparece dentro del ZIP.
- [ ] La plantilla `Install-MensorCAD.ps1` conserva el marcador y sus bytes originales.
- [ ] Ninguna salida (`MensorCAD-Windows.zip`, el sidecar, el standalone o el bootstrap) es el mismo archivo que la plantilla ni que el bootstrap fuente.
- [ ] El CUIX contiene `_rels/.rels` y el resto de rutas del árbol `cuix/` con bytes idénticos.
- [ ] Un rechazo de validación no cambia la salida anterior.
