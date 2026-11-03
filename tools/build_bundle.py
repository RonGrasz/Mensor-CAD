#!/usr/bin/env python3
"""Empaqueta el bundle de AutoCAD de MensorCAD.

Solo biblioteca estándar de Python 3. Construye:

* ``MensorCAD.bundle/Contents/UI/MensorCAD.cuix`` a partir de ``cuix/``,
  preservando bytes y rutas relativas.
* ``MensorCAD.bundle/Contents/Lisp/MC-*.lsp`` y ``PackageContents.xml``.
* ``bundle.sha256`` con el hash de cada archivo del bundle.
* ``MensorCAD-Windows.zip``, su sidecar ``MensorCAD-Windows.zip.sha256`` y
  una copia standalone ``Install-MensorCAD.ps1`` ya estampada con la version.
* ``install.ps1``, el bootstrap corto de la entrada remota, copiado byte a byte
  **fuera** del ZIP (el inventario del ZIP no cambia).

La plantilla ``Install-MensorCAD.ps1`` nunca se modifica: el constructor lee
sus bytes, exige exactamente un marcador ``__MENSORCAD_RELEASE_VERSION__`` y
reemplaza solo ese marcador. El script dentro del ZIP y el standalone son
byte a byte iguales entre sí; no son iguales a la plantilla porque esta
conserva el marcador de desarrollo.

El contrato de inventario está congelado: no se agregan archivos al ZIP fuera
de ``MensorCAD.bundle/``, ``bundle.sha256``, ``Install-MensorCAD.ps1``,
``Instalar.bat``, ``Desinstalar.bat`` y ``LICENSE``. Las fuentes de entrada
nunca se modifican y
toda validación ocurre antes de escribir la salida.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import os
import posixpath
import re
import stat
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
import xml.etree.ElementTree as ElementTree

NOMBRE_BUNDLE = "MensorCAD.bundle"
ZIP_SALIDA = "MensorCAD-Windows.zip"
ZIP_CLI_SALIDA = "MensorCAD-CLI.zip"
SUFIJO_SIDECAR = ".sha256"
VERSION_POR_DEFECTO = "0.2.0"
PATRON_VERSION = re.compile(r"^\d+\.\d+\.\d+$")
PATRON_LISP = "MC-*.lsp"
RUTA_CUIX = "Contents/UI/MensorCAD.cuix"
RUTA_LISP = "Contents/Lisp"
NOMBRE_PRODUCTO = "MensorCAD"
NOMBRE_SCRIPT = "Install-MensorCAD.ps1"
NOMBRE_GESTOR = "mensorcad.ps1"
NOMBRE_LANZADOR = "mensorcad.cmd"
NOMBRE_BOOTSTRAP = "install.ps1"
MARCADOR_VERSION_SCRIPT = b"__MENSORCAD_RELEASE_VERSION__"
MARCADOR_VERSION_GESTOR = b"__MENSORCAD_MANAGER_VERSION__"
ENTRADAS_CLI = (NOMBRE_SCRIPT, NOMBRE_GESTOR, NOMBRE_LANZADOR)
COMPONENTES_PROHIBIDOS = {"__pycache__"}
COMPONENTES_OCULTOS_PERMITIDOS = {".rels"}
MARCA_TIEMPO_ZIP = (1980, 1, 1, 0, 0, 0)
TAMANO_BLOQUE = 1024 * 1024


class ErrorConstruccion(Exception):
    """Error de validación o de entrada que impide construir el paquete."""


@dataclass(frozen=True)
class Resultado:
    zip_salida: Path
    sidecar: Path
    install_script: Path
    bootstrap: Path
    cli_zip: Path
    cli_sidecar: Path
    hash_zip: str
    hash_cli: str
    archivos_bundle: int


@dataclass(frozen=True)
class Fuentes:
    package_contents: Path
    lisp_dir: Path
    cuix_dir: Path
    install_script: Path
    bootstrap_script: Path
    manager_script: Path
    launcher_script: Path
    bat_script: Path
    uninstall_bat_script: Path
    license: Path


def _frontend(etiqueta: str) -> str:
    """Normaliza una ruta de entrada y rechaza componentes inseguros."""
    if not etiqueta or etiqueta.startswith("/") or re.match(r"^[A-Za-z]:", etiqueta):
        raise ErrorConstruccion("ruta absoluta o vacía no permitida: {!r}".format(etiqueta))
    normalizada = posixpath.normpath(etiqueta.replace("\\", "/"))
    if normalizada in ("", ".", "..") or normalizada.startswith("../"):
        raise ErrorConstruccion("ruta fuera del paquete: {!r}".format(etiqueta))
    for parte in normalizada.split("/"):
        if parte.startswith(".") and parte not in COMPONENTES_OCULTOS_PERMITIDOS:
            raise ErrorConstruccion(
                "archivo oculto no permitido dentro del paquete: {!r}".format(normalizada)
            )
        if parte in COMPONENTES_PROHIBIDOS:
            raise ErrorConstruccion(
                "caché no permitida dentro del paquete: {!r}".format(normalizada)
            )
    return normalizada


def _comprobar_archivo_regular(ruta: Path, etiqueta: str) -> Path:
    if ruta.is_symlink():
        raise ErrorConstruccion("enlace simbólico no permitido en {}: {}".format(etiqueta, ruta))
    if not ruta.exists():
        raise ErrorConstruccion("falta {}: {}".format(etiqueta, ruta))
    if not stat.S_ISREG(ruta.lstat().st_mode):
        raise ErrorConstruccion("se esperaba un archivo regular en {}: {}".format(etiqueta, ruta))
    return ruta


def _comprobar_duplicados_case_insensitive(rutas: list[str], etiqueta: str) -> None:
    vistos: dict[str, str] = {}
    for ruta in rutas:
        clave = ruta.casefold()
        if clave in vistos:
            raise ErrorConstruccion(
                "rutas duplicadas sin distinguir mayúsculas en {}: {} y {}".format(
                    etiqueta, vistos[clave], ruta
                )
            )
        vistos[clave] = ruta


def listar_lisp(lisp_dir: Path) -> list[Path]:
    """Devuelve los ``MC-*.lsp`` de ``lisp_dir`` y rechaza cualquier otro archivo."""
    if lisp_dir.is_symlink():
        raise ErrorConstruccion("enlace simbólico no permitido: {}".format(lisp_dir))
    if not lisp_dir.is_dir():
        raise ErrorConstruccion("falta el directorio de LISP: {}".format(lisp_dir))
    archivos: list[Path] = []
    ajenos: list[str] = []
    for entrada in sorted(lisp_dir.iterdir(), key=lambda item: item.name):
        if entrada.is_symlink():
            raise ErrorConstruccion("enlace simbólico no permitido en lisp: {}".format(entrada))
        if not entrada.is_file():
            ajenos.append(entrada.name + "/")
        elif not fnmatch.fnmatchcase(entrada.name, PATRON_LISP):
            ajenos.append(entrada.name)
        else:
            archivos.append(entrada)
    if ajenos:
        raise ErrorConstruccion(
            "el directorio lisp solo debe contener {}; sobra(n): {}".format(
                PATRON_LISP, ", ".join(ajenos)
            )
        )
    if not archivos:
        raise ErrorConstruccion("no se encontró ningún {} en {}".format(PATRON_LISP, lisp_dir))
    _comprobar_duplicados_case_insensitive([ruta.name for ruta in archivos], "lisp")
    return archivos


def listar_cuix(cuix_dir: Path) -> list[tuple[str, Path]]:
    """Devuelve pares (ruta relativa POSIX, archivo) de todo el árbol CUIX."""
    if cuix_dir.is_symlink():
        raise ErrorConstruccion("enlace simbólico no permitido: {}".format(cuix_dir))
    if not cuix_dir.is_dir():
        raise ErrorConstruccion("falta el directorio del CUIX: {}".format(cuix_dir))
    archivos: list[tuple[str, Path]] = []

    def recorrer(directorio: Path, prefijo: str) -> None:
        for entrada in sorted(directorio.iterdir(), key=lambda item: item.name):
            if entrada.is_symlink():
                raise ErrorConstruccion(
                    "enlace simbólico no permitido dentro del CUIX: {}".format(entrada)
                )
            relativa = prefijo + entrada.name
            if entrada.is_dir():
                recorrer(entrada, relativa + "/")
            elif entrada.is_file():
                archivos.append((_frontend(relativa), entrada))
            else:
                raise ErrorConstruccion(
                    "tipo de archivo no soportado dentro del CUIX: {}".format(entrada)
                )

    recorrer(cuix_dir, "")
    if not archivos:
        raise ErrorConstruccion("el CUIX de origen está vacío: {}".format(cuix_dir))
    if "[Content_Types].xml" not in {relativa for relativa, _ in archivos}:
        raise ErrorConstruccion(
            "el CUIX de origen no contiene [Content_Types].xml: {}".format(cuix_dir)
        )
    _comprobar_duplicados_case_insensitive([relativa for relativa, _ in archivos], "CUIX")
    return archivos


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _normalizar_modulo(valor: str) -> str:
    if valor.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", valor):
        raise ErrorConstruccion("ModuleName absoluto no permitido: {!r}".format(valor))
    normalizado = posixpath.normpath(valor.replace("\\", "/"))
    if normalizado.startswith("../") or normalizado in ("..", "."):
        raise ErrorConstruccion("ModuleName fuera del paquete: {!r}".format(valor))
    return normalizado


def validar_manifiesto(ruta: Path, version: str, nombres_lisp: list[str]) -> None:
    """Valida el manifiesto antes de que cualquier byte llegue a la salida."""
    contenido = _comprobar_archivo_regular(ruta, "PackageContents.xml").read_bytes()
    try:
        raiz = ElementTree.fromstring(contenido)
    except ElementTree.ParseError as exc:
        raise ErrorConstruccion(
            "PackageContents.xml no es XML válido: {}".format(exc)
        ) from exc
    if _local(raiz.tag) != "ApplicationPackage":
        raise ErrorConstruccion(
            "PackageContents.xml debe tener ApplicationPackage como raíz, no {}".format(
                _local(raiz.tag)
            )
        )

    nombre = raiz.get("Name") or raiz.get("AppName") or ""
    if nombre != NOMBRE_PRODUCTO:
        raise ErrorConstruccion(
            "PackageContents.xml debe declarar Name=\"{}\", no {!r}".format(
                NOMBRE_PRODUCTO, nombre
            )
        )
    if not (raiz.get("Version") or raiz.get("AppVersion")):
        raise ErrorConstruccion(
            "PackageContents.xml debe declarar Version o AppVersion"
        )
    for atributo in ("Version", "AppVersion"):
        declarada = raiz.get(atributo)
        if declarada is None:
            continue
        if declarada != version:
            raise ErrorConstruccion(
                "la versión del manifiesto ({}) no coincide con --version ({})".format(
                    declarada, version
                )
            )

    requisitos = [nodo for nodo in raiz.iter() if _local(nodo.tag) == "RuntimeRequirements"]
    if not requisitos:
        raise ErrorConstruccion("PackageContents.xml no declara RuntimeRequirements")
    if not any(
        "win64" in (nodo.get("OS") or "").lower()
        and "autocad" in (nodo.get("Platform") or "").lower()
        for nodo in requisitos
    ):
        raise ErrorConstruccion(
            "RuntimeRequirements debe declarar OS=\"Win64\" y Platform=\"AutoCAD*\""
        )

    entradas = [nodo for nodo in raiz.iter() if _local(nodo.tag) == "ComponentEntry"]
    if not entradas:
        raise ErrorConstruccion("PackageContents.xml no declara ComponentEntry")

    modulos: dict[str, str] = {}
    lisp_declarados: set[str] = set()
    for entrada in entradas:
        modulo = entrada.get("ModuleName")
        if not modulo:
            raise ErrorConstruccion("ComponentEntry sin ModuleName en PackageContents.xml")
        modulo_normalizado = _normalizar_modulo(modulo)
        if modulo_normalizado in modulos:
            raise ErrorConstruccion(
                "ComponentEntry duplicado para {}".format(modulo_normalizado)
            )
        modulos[modulo_normalizado] = entrada.get("AppName") or modulo_normalizado
        if modulo_normalizado.casefold().endswith(".cuix"):
            if modulo_normalizado != RUTA_CUIX:
                raise ErrorConstruccion(
                    "el CUIX debe declararse como ./{}, no {}".format(
                        RUTA_CUIX, modulo_normalizado
                    )
                )
            continue
        if not modulo_normalizado.startswith(RUTA_LISP + "/"):
            raise ErrorConstruccion(
                "ModuleName no reconocido en PackageContents.xml: {}".format(modulo_normalizado)
            )
        esperado_lisp = RUTA_LISP + "/" + posixpath.basename(modulo_normalizado)
        if modulo_normalizado != esperado_lisp:
            raise ErrorConstruccion(
                "el LISP debe declararse como ./{}, no {}".format(
                    esperado_lisp, modulo_normalizado
                )
            )
        if entrada.get("LoadOnAutoCADStartup") is not None:
            raise ErrorConstruccion(
                "LoadOnAutoCADStartup no está permitido en las entradas LISP ({})".format(
                    modulo_normalizado
                )
            )
        if (entrada.get("PerDocument") or "").lower() != "true":
            raise ErrorConstruccion(
                "la entrada LISP debe declarar PerDocument=\"True\": {}".format(
                    modulo_normalizado
                )
            )
        lisp_declarados.add(posixpath.basename(modulo_normalizado))

    if RUTA_CUIX not in modulos:
        raise ErrorConstruccion(
            "PackageContents.xml no declara el componente CUIX ./{}".format(RUTA_CUIX)
        )
    faltantes = sorted(set(nombres_lisp) - lisp_declarados)
    sobrantes = sorted(lisp_declarados - set(nombres_lisp))
    if faltantes:
        raise ErrorConstruccion(
            "LISP presente(s) en lisp/ sin ComponentEntry: {}".format(", ".join(faltantes))
        )
    if sobrantes:
        raise ErrorConstruccion(
            "ComponentEntry LISP sin archivo en lisp/: {}".format(", ".join(sobrantes))
        )


def comprobar_salida_fuera_de_fuentes(output_dir: Path, fuentes: Fuentes) -> None:
    salida = output_dir.resolve()
    for etiqueta, fuente in (
        ("lisp", fuentes.lisp_dir),
        ("cuix", fuentes.cuix_dir),
    ):
        origen = fuente.resolve()
        if salida == origen or origen in salida.parents:
            raise ErrorConstruccion(
                "la salida no puede estar dentro de las fuentes ({}): {}".format(etiqueta, salida)
            )


def comprobar_destinos(output_dir: Path, destinos: list[Path]) -> None:
    """Rechaza colisiones antes de mutar cualquier salida.

    Se niegan enlaces simbólicos y directorios en las rutas de salida para no
    seguir ni reemplazar elementos ajenos al constructor.
    """
    if output_dir.is_symlink():
        raise ErrorConstruccion(
            "la salida no puede ser un enlace simbólico: {}".format(output_dir)
        )
    if output_dir.exists() and not output_dir.is_dir():
        raise ErrorConstruccion(
            "la salida no es un directorio: {}".format(output_dir)
        )
    for destino in destinos:
        if destino.is_symlink():
            raise ErrorConstruccion(
                "destino de salida es un enlace simbólico: {}".format(destino)
            )
        if not destino.exists():
            continue
        if destino.is_dir():
            raise ErrorConstruccion(
                "destino de salida es un directorio: {}".format(destino)
            )
        if not destino.is_file():
            raise ErrorConstruccion(
                "destino de salida no es un archivo regular: {}".format(destino)
            )


def _info_zip(nombre: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(nombre, date_time=MARCA_TIEMPO_ZIP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (0o100644 & 0xFFFF) << 16
    return info


def _copiar_a_zip(destino: zipfile.ZipFile, nombre: str, ruta: Path) -> str:
    digest = hashlib.sha256()
    with ruta.open("rb") as origen, destino.open(_info_zip(nombre), "w") as salida:
        while True:
            bloque = origen.read(TAMANO_BLOQUE)
            if not bloque:
                break
            digest.update(bloque)
            salida.write(bloque)
    return digest.hexdigest()


def construir_cuix(archivos: list[tuple[str, Path]], destino: Path) -> None:
    """Reconstruye el CUIX como ZIP OPC preservando cada byte de origen."""
    with zipfile.ZipFile(destino, "w", compression=zipfile.ZIP_DEFLATED) as cuix:
        for relativa, ruta in archivos:
            _copiar_a_zip(cuix, relativa, ruta)


def _escribir_zip(
    destino: Path,
    manifiesto: Path,
    archivos_lisp: list[Path],
    cuix: Path,
    install_script: Path,
    bat_script: Path,
    uninstall_bat_script: Path,
    license: Path,
) -> int:
    entradas_bundle: list[tuple[str, Path]] = [
        ("PackageContents.xml", manifiesto),
        (NOMBRE_SCRIPT, install_script),
        *((RUTA_LISP + "/" + ruta.name, ruta) for ruta in archivos_lisp),
        (RUTA_CUIX, cuix),
    ]
    entradas_bundle.sort(key=lambda par: par[0])
    hashes: list[tuple[str, str]] = []
    with zipfile.ZipFile(destino, "w", compression=zipfile.ZIP_DEFLATED) as paquete:
        for relativa, ruta in entradas_bundle:
            hashes.append((_copiar_a_zip(paquete, NOMBRE_BUNDLE + "/" + relativa, ruta), relativa))
        resumen = "".join(
            "{}  {}\n".format(digest, relativa) for digest, relativa in hashes
        ).encode("utf-8")
        paquete.writestr(_info_zip("bundle.sha256"), resumen)
        for nombre_fijo, ruta in (
            ("Install-MensorCAD.ps1", install_script),
            ("Instalar.bat", bat_script),
            ("Desinstalar.bat", uninstall_bat_script),
            ("LICENSE", license),
        ):
            _copiar_a_zip(paquete, nombre_fijo, ruta)
    return len(entradas_bundle)


def _escribir_zip_cli(
    destino: Path, install_script: Path, manager_script: Path, launcher_script: Path
) -> None:
    """Escribe el ZIP plano del gestor con orden y marcas de tiempo fijas."""
    entradas = sorted(
        (
            (NOMBRE_SCRIPT, install_script),
            (NOMBRE_GESTOR, manager_script),
            (NOMBRE_LANZADOR, launcher_script),
        ),
        key=lambda par: par[0],
    )
    if tuple(nombre for nombre, _ in entradas) != tuple(sorted(ENTRADAS_CLI)):
        raise ErrorConstruccion(
            "el ZIP del gestor debe contener exactamente {}".format(
                ", ".join(sorted(ENTRADAS_CLI))
            )
        )
    with zipfile.ZipFile(destino, "w", compression=zipfile.ZIP_DEFLATED) as paquete:
        for nombre, ruta in entradas:
            _copiar_a_zip(paquete, nombre, ruta)


def _escribir_sidecar(destino: Path, hash_zip: str, nombre_zip: str) -> None:
    destino.write_text(
        "{}  {}\n".format(hash_zip, nombre_zip), encoding="utf-8", newline="\n"
    )


def _estampar_plantilla(
    ruta: Path, etiqueta: str, marcador: bytes, version: str
) -> bytes:
    """Devuelve la plantilla con su unico marcador reemplazado por ``version``.

    Solo se aceptan bytes: no se decodifica ni se reescribe el archivo, de modo
    que el BOM y los fines de linea de la plantilla se conservan. La cantidad
    de marcadores se valida antes de que exista cualquier escritura de salida.
    """
    contenido = _comprobar_archivo_regular(ruta, etiqueta).read_bytes()
    cantidad = contenido.count(marcador)
    if cantidad != 1:
        raise ErrorConstruccion(
            "{} debe contener exactamente un marcador {}; encontrados {}".format(
                etiqueta,
                marcador.decode("ascii"),
                cantidad,
            )
        )
    estampado = contenido.replace(marcador, version.encode("ascii"))
    if marcador in estampado:
        raise ErrorConstruccion(
            "el marcador {} sigue presente después de estampar {}".format(
                marcador.decode("ascii"), etiqueta
            )
        )
    return estampado


def _estampar_script_install(ruta: Path, version: str) -> bytes:
    return _estampar_plantilla(ruta, NOMBRE_SCRIPT, MARCADOR_VERSION_SCRIPT, version)


def _estampar_gestor(ruta: Path, version: str) -> bytes:
    """Estampa la version del comando gestor; no lleva version de producto."""
    contenido = _comprobar_archivo_regular(ruta, NOMBRE_GESTOR).read_bytes()
    if MARCADOR_VERSION_SCRIPT in contenido:
        raise ErrorConstruccion(
            "{} no debe contener el marcador {}; la version del producto la lleva "
            "{}".format(
                NOMBRE_GESTOR,
                MARCADOR_VERSION_SCRIPT.decode("ascii"),
                NOMBRE_SCRIPT,
            )
        )
    return _estampar_plantilla(ruta, NOMBRE_GESTOR, MARCADOR_VERSION_GESTOR, version)


def _leer_lanzador(ruta: Path) -> bytes:
    """Devuelve el lanzador CMD byte a byte y rechaza BOM o texto no ASCII."""
    contenido = _comprobar_archivo_regular(ruta, NOMBRE_LANZADOR).read_bytes()
    if contenido.startswith(b"\xef\xbb\xbf") or any(byte >= 0x80 for byte in contenido):
        raise ErrorConstruccion(
            "{} debe ser ASCII sin BOM para que CMD lo ejecute igual en todas las "
            "configuraciones regionales".format(NOMBRE_LANZADOR)
        )
    for marcador in (MARCADOR_VERSION_SCRIPT, MARCADOR_VERSION_GESTOR):
        if marcador in contenido:
            raise ErrorConstruccion(
                "{} no debe contener el marcador {}".format(
                    NOMBRE_LANZADOR, marcador.decode("ascii")
                )
            )
    return contenido


def _comprobar_solapamiento_fuente(
    destino: Path, fuente: Path, etiqueta_fuente: str = "la plantilla"
) -> None:
    """Rechaza antes de escribir que una salida sea el archivo de la plantilla."""
    try:
        mismo = destino.resolve() == fuente.resolve()
        if not mismo and destino.exists() and fuente.exists():
            mismo = destino.samefile(fuente)
    except OSError as exc:
        raise ErrorConstruccion(
            "no se pudo comprobar la plantilla de salida: {}".format(exc)
        ) from exc
    if mismo:
        raise ErrorConstruccion(
            "la salida {} no puede ser el mismo archivo que {} fuente: {}".format(
                destino.name, etiqueta_fuente, fuente
            )
        )


def _leer_bootstrap(ruta: Path) -> bytes:
    """Devuelve los bytes del bootstrap sin estampar ni reescribir nada.

    El bootstrap no lleva la version del producto: el instalador real es el
    unico duenio del numero de version y del marcador de la plantilla.
    """
    contenido = _comprobar_archivo_regular(ruta, NOMBRE_BOOTSTRAP).read_bytes()
    if MARCADOR_VERSION_SCRIPT in contenido:
        raise ErrorConstruccion(
            "{} no debe contener el marcador {}; la version la lleva "
            "{}".format(
                NOMBRE_BOOTSTRAP,
                MARCADOR_VERSION_SCRIPT.decode("ascii"),
                NOMBRE_SCRIPT,
            )
        )
    return contenido


def _hash_archivo(ruta: Path) -> str:
    digest = hashlib.sha256()
    with ruta.open("rb") as archivo:
        while True:
            bloque = archivo.read(TAMANO_BLOQUE)
            if not bloque:
                break
            digest.update(bloque)
    return digest.hexdigest()


def _instalar_salida(origen: Path, destino: Path) -> None:
    """Publica un artefacto con creación exclusiva del temporal.

    ``mkstemp`` falla si la ruta ya existe, así que nunca se sigue un temporal
    preexistente ni se borran archivos temporales ajenos. Solo se elimina el
    temporal que este proceso creó. El reemplazo final es atómico por archivo;
    publicar varios archivos no es una transacción (ver docs/build-bundle.md).
    """
    descriptor, ruta_temporal = tempfile.mkstemp(
        prefix="." + destino.name + ".", suffix=".tmp", dir=str(destino.parent)
    )
    try:
        with os.fdopen(descriptor, "wb") as salida, origen.open("rb") as entrada:
            while True:
                bloque = entrada.read(TAMANO_BLOQUE)
                if not bloque:
                    break
                salida.write(bloque)
        os.replace(ruta_temporal, destino)
    finally:
        try:
            os.unlink(ruta_temporal)
        except FileNotFoundError:
            pass


def construir(fuentes: Fuentes, output_dir: Path, version: str) -> Resultado:
    """Valida todas las entradas y, solo entonces, escribe la salida."""
    if not PATRON_VERSION.match(version):
        raise ErrorConstruccion(
            "formato de versión inválido: {!r} (se espera MAJOR.MINOR.PATCH)".format(version)
        )
    for etiqueta, ruta in (
        ("Install-MensorCAD.ps1", fuentes.install_script),
        (NOMBRE_BOOTSTRAP, fuentes.bootstrap_script),
        (NOMBRE_GESTOR, fuentes.manager_script),
        (NOMBRE_LANZADOR, fuentes.launcher_script),
        ("Instalar.bat", fuentes.bat_script),
        ("Desinstalar.bat", fuentes.uninstall_bat_script),
        ("LICENSE", fuentes.license),
    ):
        _comprobar_archivo_regular(ruta, etiqueta)

    # Validación y estampado antes de cualquier escritura de salida.
    script_estampado = _estampar_script_install(fuentes.install_script, version)
    bootstrap_bytes = _leer_bootstrap(fuentes.bootstrap_script)
    gestor_estampado = _estampar_gestor(fuentes.manager_script, version)
    lanzador_bytes = _leer_lanzador(fuentes.launcher_script)

    archivos_lisp = listar_lisp(fuentes.lisp_dir)
    archivos_cuix = listar_cuix(fuentes.cuix_dir)
    validar_manifiesto(
        fuentes.package_contents, version, [ruta.name for ruta in archivos_lisp]
    )
    comprobar_salida_fuera_de_fuentes(output_dir, fuentes)
    zip_salida = output_dir / ZIP_SALIDA
    sidecar = output_dir / (ZIP_SALIDA + SUFIJO_SIDECAR)
    cli_zip = output_dir / ZIP_CLI_SALIDA
    cli_sidecar = output_dir / (ZIP_CLI_SALIDA + SUFIJO_SIDECAR)
    script_salida = output_dir / NOMBRE_SCRIPT
    bootstrap_salida = output_dir / NOMBRE_BOOTSTRAP
    destinos = (
        zip_salida,
        sidecar,
        script_salida,
        bootstrap_salida,
        cli_zip,
        cli_sidecar,
    )
    # Cada salida se compara con TODAS las fuentes: ninguna plantilla, ni el
    # bootstrap, ni el gestor, ni el lanzador pueden ser reemplazados por un
    # artefacto. El orden de los mensajes es estable y probado.
    fuentes_protegidas = (
        (fuentes.install_script, "la plantilla"),
        (fuentes.bootstrap_script, "el bootstrap"),
        (fuentes.manager_script, "el comando gestor"),
        (fuentes.launcher_script, "el lanzador"),
    )
    for destino in destinos:
        for fuente, etiqueta_fuente in fuentes_protegidas:
            _comprobar_solapamiento_fuente(destino, fuente, etiqueta_fuente)
    comprobar_destinos(output_dir, list(destinos))

    with tempfile.TemporaryDirectory(prefix="mensorcad-bundle-") as temporal:
        cuix_temporal = Path(temporal) / "MensorCAD.cuix"
        construir_cuix(archivos_cuix, cuix_temporal)
        script_temporal = Path(temporal) / NOMBRE_SCRIPT
        script_temporal.write_bytes(script_estampado)
        bootstrap_temporal = Path(temporal) / NOMBRE_BOOTSTRAP
        bootstrap_temporal.write_bytes(bootstrap_bytes)
        gestor_temporal = Path(temporal) / NOMBRE_GESTOR
        gestor_temporal.write_bytes(gestor_estampado)
        lanzador_temporal = Path(temporal) / NOMBRE_LANZADOR
        lanzador_temporal.write_bytes(lanzador_bytes)
        zip_temporal = Path(temporal) / ZIP_SALIDA
        total_bundle = _escribir_zip(
            zip_temporal,
            fuentes.package_contents,
            archivos_lisp,
            cuix_temporal,
            script_temporal,
            fuentes.bat_script,
            fuentes.uninstall_bat_script,
            fuentes.license,
        )
        hash_zip = _hash_archivo(zip_temporal)
        sidecar_temporal = Path(temporal) / (ZIP_SALIDA + SUFIJO_SIDECAR)
        _escribir_sidecar(sidecar_temporal, hash_zip, ZIP_SALIDA)
        cli_temporal = Path(temporal) / ZIP_CLI_SALIDA
        _escribir_zip_cli(
            cli_temporal, script_temporal, gestor_temporal, lanzador_temporal
        )
        hash_cli = _hash_archivo(cli_temporal)
        cli_sidecar_temporal = Path(temporal) / (ZIP_CLI_SALIDA + SUFIJO_SIDECAR)
        _escribir_sidecar(cli_sidecar_temporal, hash_cli, ZIP_CLI_SALIDA)
        output_dir.mkdir(parents=True, exist_ok=True)
        _instalar_salida(zip_temporal, zip_salida)
        _instalar_salida(sidecar_temporal, sidecar)
        _instalar_salida(script_temporal, script_salida)
        _instalar_salida(bootstrap_temporal, bootstrap_salida)
        _instalar_salida(cli_temporal, cli_zip)
        _instalar_salida(cli_sidecar_temporal, cli_sidecar)

    return Resultado(
        zip_salida=zip_salida,
        sidecar=sidecar,
        install_script=script_salida,
        bootstrap=bootstrap_salida,
        cli_zip=cli_zip,
        cli_sidecar=cli_sidecar,
        hash_zip=hash_zip,
        hash_cli=hash_cli,
        archivos_bundle=total_bundle,
    )


def _analizar_argumentos(argv: list[str] | None) -> argparse.Namespace:
    raiz_defecto = Path(__file__).resolve().parents[1]
    analizador = argparse.ArgumentParser(
        description=(
            "Construye MensorCAD-Windows.zip, su sidecar SHA-256, el script "
            "standalone, el bootstrap install.ps1 y los assets del comando gestor "
            "MensorCAD-CLI.zip y MensorCAD-CLI.zip.sha256. El motor estampado "
            "también queda dentro del inventario del bundle."
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    analizador.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="directorio de salida, fuera de lisp/ y cuix/",
    )
    analizador.add_argument(
        "--version",
        default=VERSION_POR_DEFECTO,
        help="versión del paquete; debe coincidir con PackageContents.xml",
    )
    analizador.add_argument("--package-contents", type=Path,
                            default=raiz_defecto / "PackageContents.xml")
    analizador.add_argument("--lisp-dir", type=Path, default=raiz_defecto / "lisp")
    analizador.add_argument("--cuix-dir", type=Path, default=raiz_defecto / "cuix")
    analizador.add_argument(
        "--install-script",
        type=Path,
        default=raiz_defecto / "Install-MensorCAD.ps1",
        help=(
            "plantilla PowerShell; debe contener exactamente un marcador "
            "__MENSORCAD_RELEASE_VERSION__ que se reemplaza con --version"
        ),
    )
    analizador.add_argument("--bat-script", type=Path, default=raiz_defecto / "Instalar.bat")
    analizador.add_argument(
        "--bootstrap-script",
        type=Path,
        default=raiz_defecto / NOMBRE_BOOTSTRAP,
        help=(
            "bootstrap corto de la entrada remota que se copia byte a byte como "
            "cuarta salida, fuera del ZIP; no se estampa y no puede contener "
            "__MENSORCAD_RELEASE_VERSION__"
        ),
    )
    analizador.add_argument(
        "--manager-script",
        type=Path,
        default=raiz_defecto / NOMBRE_GESTOR,
        help=(
            "comando gestor mensorcad.ps1; debe contener exactamente un marcador "
            "__MENSORCAD_MANAGER_VERSION__ que se reemplaza con --version y viaja "
            "dentro de MensorCAD-CLI.zip"
        ),
    )
    analizador.add_argument(
        "--launcher-script",
        type=Path,
        default=raiz_defecto / NOMBRE_LANZADOR,
        help=(
            "lanzador CMD mensorcad.cmd; se copia byte a byte dentro de "
            "MensorCAD-CLI.zip y debe ser ASCII sin BOM"
        ),
    )
    analizador.add_argument(
        "--uninstall-bat-script", type=Path, default=raiz_defecto / "Desinstalar.bat",
        help="BAT de desinstalación por doble clic que se incluye en el ZIP",
    )
    analizador.add_argument("--license", type=Path, default=raiz_defecto / "LICENSE")
    return analizador.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    opciones = _analizar_argumentos(argv)
    fuentes = Fuentes(
        package_contents=opciones.package_contents,
        lisp_dir=opciones.lisp_dir,
        cuix_dir=opciones.cuix_dir,
        install_script=opciones.install_script,
        bootstrap_script=opciones.bootstrap_script,
        manager_script=opciones.manager_script,
        launcher_script=opciones.launcher_script,
        bat_script=opciones.bat_script,
        uninstall_bat_script=opciones.uninstall_bat_script,
        license=opciones.license,
    )
    try:
        resultado = construir(fuentes, opciones.output_dir, opciones.version)
    except ErrorConstruccion as exc:
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 1
    except OSError as exc:
        print("ERROR de entrada/salida: {}".format(exc), file=sys.stderr)
        return 1

    print("Paquete construido: {}".format(resultado.zip_salida))
    print("Sidecar SHA-256:    {}".format(resultado.sidecar))
    print("Script standalone:  {}".format(resultado.install_script))
    print("Bootstrap:          {}".format(resultado.bootstrap))
    print("ZIP del gestor:     {}".format(resultado.cli_zip))
    print("Sidecar del gestor: {}".format(resultado.cli_sidecar))
    print("SHA-256 del ZIP:    {}".format(resultado.hash_zip))
    print("SHA-256 del gestor: {}".format(resultado.hash_cli))
    print("Archivos del bundle: {}".format(resultado.archivos_bundle))
    return 0


if __name__ == "__main__":
    sys.exit(main())
