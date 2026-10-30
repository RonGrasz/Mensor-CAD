"""Pruebas de caja negra para tools/build_bundle.py.

Cada prueba ejecuta la CLI pública en un directorio de trabajo temporal. No se
tocan los archivos reales de ``lisp/`` ni de ``cuix/``: los casos usan fuentes
de prueba aisladas y, para el caso S3, solo se leen las fuentes del repositorio.
"""

from __future__ import annotations

import hashlib
import io
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
import xml.etree.ElementTree as ElementTree

RAIZ_REPO = Path(__file__).resolve().parents[1]
CONSTRUCTOR = RAIZ_REPO / "tools" / "build_bundle.py"
ZIP_SALIDA = "MensorCAD-Windows.zip"
SIDECAR = "MensorCAD-Windows.zip.sha256"
RUTA_SCRIPT_STANDALONE = "Install-MensorCAD.ps1"
TMP_PREVIO = ".MensorCAD-Windows.zip.tmp"
RAIZ_BUNDLE = "MensorCAD.bundle/"

LISP_FIXTURE = ("MC-AREA.lsp", "MC-TABLE.lsp")
CUIX_FIXTURE = {
    "[Content_Types].xml": (
        b'<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.'
        b'openxmlformats.org/package/2006/content-types" />'
    ),
    "_rels/.rels": (
        b'<?xml version="1.0" encoding="utf-8"?><Relationships xmlns="http://'
        b'schemas.openxmlformats.org/package/2006/relationships" />'
    ),
    "MenuGroup.cui": b'<?xml version="1.0"?>\n<MenuGroup Name="MENSORCAD" />\n',
    "Menu_Package_Info.xml": (
        b'<?xml version="1.0" encoding="utf-8"?>\n<MenuPackageParts>\n'
        b'  <PartData PartData_Name="/VirtualMNRRoot" />\n</MenuPackageParts>\n'
    ),
    "icons/mcarea16.png": b"\x89PNG\r\n\x1a\nICONO-DE-PRUEBA",
}


def sha256_bytes(datos: bytes) -> str:
    return hashlib.sha256(datos).hexdigest()


def sha256_archivo(ruta: Path) -> str:
    return sha256_bytes(ruta.read_bytes())


def manifiesto(version: str, lisp: tuple[str, ...] | list[str]) -> bytes:
    entradas = "\n".join(
        '    <ComponentEntry AppName="{0}" ModuleName="./Contents/Lisp/{0}" '
        'PerDocument="True" />'.format(nombre)
        for nombre in lisp
    )
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<ApplicationPackage SchemaVersion="1.0" ProductType="Application" '
        'Name="MensorCAD" AppVersion="{v}" Version="{v}" '
        'ProductCode="{{00000000-0000-0000-0000-000000000001}}" '
        'UpgradeCode="{{00000000-0000-0000-0000-000000000002}}" '
        'Author="RonGrasz" Description="Herramientas CAD para topografia">\n'
        '  <CompanyDetails Name="RonGrasz" />\n'
        '  <Components Description="Complementos MensorCAD">\n'
        '    <RuntimeRequirements OS="Win64" Platform="AutoCAD*" />\n'
        '    <ComponentEntry AppName="MensorCAD" '
        'ModuleName="./Contents/UI/MensorCAD.cuix" />\n'
        "{entradas}\n"
        "  </Components>\n"
        "</ApplicationPackage>\n"
    ).format(v=version, entradas=entradas).encode("utf-8")


class FuentesDePrueba:
    """Fuentes de entrada aisladas para una ejecución de la CLI."""

    def __init__(
        self,
        base: Path,
        version: str = "0.1.0",
        lisp: tuple[str, ...] = LISP_FIXTURE,
        cuix: dict[str, bytes] | None = None,
    ) -> None:
        self.base = base
        self.raiz = base / "repo"
        self.salida = base / "dist"
        self.lisp_dir = self.raiz / "lisp"
        self.cuix_dir = self.raiz / "cuix"
        self.package_contents = self.raiz / "PackageContents.xml"
        self.install_script = self.raiz / "Install-MensorCAD.ps1"
        self.bat_script = self.raiz / "Instalar.bat"
        self.license = self.raiz / "LICENSE"

        self.lisp_dir.mkdir(parents=True)
        self.cuix_dir.mkdir(parents=True)
        for nombre in lisp:
            (self.lisp_dir / nombre).write_bytes(
                "(princ \"\\n{} cargado.\")(princ)\n".format(nombre).encode("utf-8")
            )
        for relativa, contenido in (cuix or CUIX_FIXTURE).items():
            destino = self.cuix_dir / relativa
            destino.parent.mkdir(parents=True, exist_ok=True)
            destino.write_bytes(contenido)
        self.package_contents.write_bytes(manifiesto(version, lisp))
        self.install_script.write_bytes(
            b"param([switch]$Uninstall)\nWrite-Host 'instalador de prueba'\n"
        )
        self.bat_script.write_bytes(b"@echo off\r\npowershell -File Install-MensorCAD.ps1\r\n")
        self.license.write_bytes(b"MIT License\n\nCopyright (c) RonGrasz\n")

    def argumentos(self, output_dir: Path | None = None, version: str | None = None):
        argumentos = [
            "--output-dir",
            str(output_dir or self.salida),
            "--package-contents",
            str(self.package_contents),
            "--lisp-dir",
            str(self.lisp_dir),
            "--cuix-dir",
            str(self.cuix_dir),
            "--install-script",
            str(self.install_script),
            "--bat-script",
            str(self.bat_script),
            "--license",
            str(self.license),
        ]
        if version is not None:
            argumentos.extend(["--version", version])
        return argumentos


class CasoBase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="mensorcad-build-")
        self.base = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def fuentes(self, **kwargs) -> FuentesDePrueba:
        return FuentesDePrueba(self.base, **kwargs)

    def ejecutar(self, argumentos, cwd: Path | None = None):
        return subprocess.run(
            [sys.executable, str(CONSTRUCTOR), *argumentos],
            capture_output=True,
            text=True,
            cwd=str(cwd or self.base),
        )

    def construir(self, fuentes: FuentesDePrueba, **kwargs):
        resultado = self.ejecutar(fuentes.argumentos(**kwargs))
        self.assertEqual(
            resultado.returncode,
            0,
            msg="fallo el constructor:\nSTDOUT:\n{}\nSTDERR:\n{}".format(
                resultado.stdout, resultado.stderr
            ),
        )
        return resultado

    def leer_zip(self, ruta: Path) -> zipfile.ZipFile:
        return zipfile.ZipFile(io.BytesIO(ruta.read_bytes()))

    def leer_cuix(self, zf: zipfile.ZipFile) -> zipfile.ZipFile:
        return zipfile.ZipFile(
            io.BytesIO(zf.read(RAIZ_BUNDLE + "Contents/UI/MensorCAD.cuix"))
        )

    def lineas_bundle_sha256(self, zf: zipfile.ZipFile) -> list[tuple[str, str]]:
        texto = zf.read("bundle.sha256").decode("utf-8")
        self.assertTrue(texto.endswith("\n"), msg="bundle.sha256 debe terminar en salto de linea")
        lineas = []
        for linea in texto.splitlines():
            digest, separador, ruta = linea.partition("  ")
            self.assertEqual(separador, "  ", msg="formato inesperado: " + linea)
            lineas.append((digest, ruta))
        return lineas


class InventarioDeSalida(CasoBase):
    def test_zip_contiene_el_inventario_congelado(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        zip_salida = fuentes.salida / ZIP_SALIDA
        self.assertTrue(zip_salida.is_file(), msg="falta " + ZIP_SALIDA)
        with self.leer_zip(zip_salida) as zf:
            nombres = set(zf.namelist())
            esperados = {
                RAIZ_BUNDLE + "PackageContents.xml",
                RAIZ_BUNDLE + "Contents/Lisp/MC-AREA.lsp",
                RAIZ_BUNDLE + "Contents/Lisp/MC-TABLE.lsp",
                RAIZ_BUNDLE + "Contents/UI/MensorCAD.cuix",
                "bundle.sha256",
                "Install-MensorCAD.ps1",
                "Instalar.bat",
                "LICENSE",
            }
            self.assertEqual(nombres, esperados)
            self.assertEqual(len(zf.namelist()), len(nombres), msg="entradas duplicadas")
            self.assertIsNone(zf.testzip(), msg="ZIP de salida corrupto")
            for nombre in nombres:
                self.assertFalse(nombre.endswith("/"), msg="entrada de directorio: " + nombre)
                self.assertNotIn(".git/", nombre)
                self.assertNotIn("__pycache__", nombre)

    def test_manifiesto_lisp_e_instalador_se_copian_byte_a_byte(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        with self.leer_zip(fuentes.salida / ZIP_SALIDA) as zf:
            self.assertEqual(
                zf.read(RAIZ_BUNDLE + "PackageContents.xml"),
                fuentes.package_contents.read_bytes(),
            )
            for nombre in LISP_FIXTURE:
                self.assertEqual(
                    zf.read(RAIZ_BUNDLE + "Contents/Lisp/" + nombre),
                    (fuentes.lisp_dir / nombre).read_bytes(),
                    msg="se altero " + nombre,
                )
            self.assertEqual(zf.read("Install-MensorCAD.ps1"), fuentes.install_script.read_bytes())
            self.assertEqual(zf.read("Instalar.bat"), fuentes.bat_script.read_bytes())
            self.assertEqual(zf.read("LICENSE"), fuentes.license.read_bytes())

    def test_asset_de_checksum_nombra_el_zip(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        zip_salida = fuentes.salida / ZIP_SALIDA
        sidecar = fuentes.salida / SIDECAR
        self.assertTrue(sidecar.is_file(), msg="falta " + SIDECAR)
        contenido = sidecar.read_text(encoding="utf-8")
        self.assertEqual(
            contenido,
            "{}  {}\n".format(sha256_archivo(zip_salida), ZIP_SALIDA),
        )
        generados = sorted(ruta.name for ruta in fuentes.salida.iterdir())
        self.assertEqual(generados, [RUTA_SCRIPT_STANDALONE, ZIP_SALIDA, SIDECAR])

    def test_script_standalone_se_emite_byte_a_byte(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        standalone = fuentes.salida / RUTA_SCRIPT_STANDALONE
        self.assertTrue(standalone.is_file(), msg="falta " + RUTA_SCRIPT_STANDALONE)
        self.assertFalse(standalone.is_symlink())
        self.assertEqual(standalone.read_bytes(), fuentes.install_script.read_bytes())

    def test_acepta_manifiesto_con_solo_version_coincidente(self):
        fuentes = self.fuentes()
        xml = fuentes.package_contents.read_text(encoding="utf-8").replace(
            'AppVersion="0.1.0" ', ""
        )
        fuentes.package_contents.write_text(xml, encoding="utf-8")
        self.construir(fuentes)

        zip_salida = fuentes.salida / ZIP_SALIDA
        with self.leer_zip(zip_salida) as zf:
            self.assertEqual(zf.read(RAIZ_BUNDLE + "PackageContents.xml"), xml.encode("utf-8"))
            self.assertIsNone(zf.testzip(), msg="ZIP de salida corrupto")
        self.assertEqual(
            (fuentes.salida / SIDECAR).read_text(encoding="utf-8"),
            "{}  {}\n".format(sha256_archivo(zip_salida), ZIP_SALIDA),
        )
        self.assertEqual(
            (fuentes.salida / RUTA_SCRIPT_STANDALONE).read_bytes(),
            fuentes.install_script.read_bytes(),
        )

    def test_manifiesto_publico_no_impone_minimo_ni_locale(self):
        raiz = ElementTree.fromstring((RAIZ_REPO / "PackageContents.xml").read_bytes())
        prohibidos = {"seriesmin", "seriesmax", "supportedlocales"}
        for nodo in raiz.iter():
            for atributo in nodo.attrib:
                self.assertNotIn(
                    atributo.lower(),
                    prohibidos,
                    msg="el manifiesto público no debe imponer {} en {}".format(
                        atributo, nodo.tag
                    ),
                )
        requisitos = [nodo for nodo in raiz.iter() if nodo.tag.rsplit("}", 1)[-1] ==
                      "RuntimeRequirements"]
        self.assertTrue(requisitos, msg="falta RuntimeRequirements")
        self.assertTrue(
            any(
                "win64" in (nodo.get("OS") or "").lower()
                and "autocad" in (nodo.get("Platform") or "").lower()
                for nodo in requisitos
            ),
            msg="RuntimeRequirements debe seguir declarando Win64/AutoCAD",
        )

    def test_bundle_sha256_cubre_cada_archivo_del_bundle(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        with self.leer_zip(fuentes.salida / ZIP_SALIDA) as zf:
            lineas = self.lineas_bundle_sha256(zf)
            esperadas = sorted(
                nombre[len(RAIZ_BUNDLE) :]
                for nombre in zf.namelist()
                if nombre.startswith(RAIZ_BUNDLE)
            )
            self.assertEqual([ruta for _, ruta in lineas], esperadas)
            for digest, ruta in lineas:
                self.assertEqual(digest, digest.lower(), msg="hash no minusculo: " + ruta)
                self.assertNotIn("\\", ruta)
                self.assertFalse(ruta.startswith("/"), msg="ruta absoluta: " + ruta)
                self.assertEqual(digest, sha256_bytes(zf.read(RAIZ_BUNDLE + ruta)))

    def test_cuix_preserva_bytes_y_rutas_relativas(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        origen = {
            ruta.relative_to(fuentes.cuix_dir).as_posix(): ruta.read_bytes()
            for ruta in fuentes.cuix_dir.rglob("*")
            if ruta.is_file()
        }
        with self.leer_zip(fuentes.salida / ZIP_SALIDA) as zf:
            with self.leer_cuix(zf) as cuix:
                self.assertEqual(sorted(cuix.namelist()), sorted(origen))
                self.assertIsNone(cuix.testzip(), msg="CUIX corrupto")
                self.assertIn("_rels/.rels", cuix.namelist())
                self.assertIn("[Content_Types].xml", cuix.namelist())
                for relativa, contenido in origen.items():
                    self.assertEqual(
                        cuix.read(relativa), contenido, msg="se altero cuix/" + relativa
                    )

    def test_cuix_acepta_metadatos_sin_archivo_fisico_virtual_mnr(self):
        fuentes = self.fuentes()
        self.assertIn("VirtualMNRRoot", fuentes.cuix_dir.joinpath(
            "Menu_Package_Info.xml").read_text(encoding="utf-8"))
        self.assertFalse((fuentes.cuix_dir / "VirtualMNRRoot").exists())
        self.construir(fuentes)

    def test_construccion_reproducible(self):
        fuentes = self.fuentes()
        destino_a = self.base / "salida-a"
        destino_b = self.base / "salida-b"
        self.construir(fuentes, output_dir=destino_a)
        self.construir(fuentes, output_dir=destino_b)
        self.assertEqual(
            (destino_a / ZIP_SALIDA).read_bytes(), (destino_b / ZIP_SALIDA).read_bytes()
        )
        self.assertEqual(
            (destino_a / SIDECAR).read_text(encoding="utf-8"),
            (destino_b / SIDECAR).read_text(encoding="utf-8"),
        )


class Rechazos(CasoBase):
    def preparar_salida_previa(self, fuentes: FuentesDePrueba) -> dict[str, bytes]:
        fuentes.salida.mkdir(parents=True, exist_ok=True)
        previos = {
            ZIP_SALIDA: b"ZIP-ANTERIOR-QUE-NO-DEBE-CAMBIAR",
            SIDECAR: b"CHECKSUM-ANTERIOR-QUE-NO-DEBE-CAMBIAR\n",
        }
        for nombre, contenido in previos.items():
            (fuentes.salida / nombre).write_bytes(contenido)
        return previos

    def assert_rechazo(self, resultado, salida: Path, previos, aguja: str):
        self.assertNotEqual(resultado.returncode, 0, msg="se esperaba un rechazo")
        self.assertIn(aguja.lower(), (resultado.stderr + resultado.stdout).lower())
        for nombre, contenido in previos.items():
            self.assertEqual(
                (salida / nombre).read_bytes(), contenido, msg="se modifico " + nombre
            )
        self.assertEqual(
            sorted(ruta.name for ruta in salida.iterdir()), sorted(previos)
        )

    def test_rechaza_lisp_del_manifiesto_ausente(self):
        fuentes = self.fuentes()
        fuentes.package_contents.write_bytes(
            manifiesto("0.1.0", (*LISP_FIXTURE, "MC-FANTASMA.lsp"))
        )
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo(resultado, fuentes.salida, previos, "MC-FANTASMA.lsp")

    def test_rechaza_archivo_ajeno_en_lisp(self):
        fuentes = self.fuentes()
        (fuentes.lisp_dir / "notas.txt").write_bytes(b"no debe viajar en el paquete")
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo(resultado, fuentes.salida, previos, "notas.txt")

    def test_rechaza_version_incompatible(self):
        fuentes = self.fuentes()
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos(version="9.9.9"))
        self.assert_rechazo(resultado, fuentes.salida, previos, "versión")

    def test_rechaza_version_con_formato_invalido(self):
        fuentes = self.fuentes()
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos(version="0.1"))
        self.assert_rechazo(resultado, fuentes.salida, previos, "versión")

    def assert_rechazo_exacto(self, resultado, salida: Path, previos, stderr_esperado: str):
        self.assertNotEqual(resultado.returncode, 0, msg="se esperaba un rechazo")
        self.assertEqual(resultado.stdout, "")
        self.assertEqual(resultado.stderr, stderr_esperado)
        for nombre, contenido in previos.items():
            self.assertEqual(
                (salida / nombre).read_bytes(), contenido, msg="se modifico " + nombre
            )
        self.assertEqual(sorted(ruta.name for ruta in salida.iterdir()), sorted(previos))

    def reemplazar_modulo(self, fuentes, anterior: str, nuevo: str) -> None:
        xml = fuentes.package_contents.read_text(encoding="utf-8")
        self.assertIn(anterior, xml)
        fuentes.package_contents.write_text(xml.replace(anterior, nuevo), encoding="utf-8")

    def test_rechaza_manifiesto_sin_atributos_de_version(self):
        fuentes = self.fuentes()
        xml = fuentes.package_contents.read_text(encoding="utf-8")
        fuentes.package_contents.write_text(
            xml.replace('AppVersion="0.1.0" Version="0.1.0" ', ""), encoding="utf-8"
        )
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo_exacto(
            resultado,
            fuentes.salida,
            previos,
            "ERROR: PackageContents.xml debe declarar Version o AppVersion\n",
        )

    def test_rechaza_solo_version_incompatible(self):
        fuentes = self.fuentes()
        xml = fuentes.package_contents.read_text(encoding="utf-8")
        fuentes.package_contents.write_text(
            xml.replace('AppVersion="0.1.0" ', "").replace('Version="0.1.0"', 'Version="0.0.9"'),
            encoding="utf-8",
        )
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo_exacto(
            resultado,
            fuentes.salida,
            previos,
            "ERROR: la versión del manifiesto (0.0.9) no coincide con --version (0.1.0)\n",
        )

    def test_rechaza_module_name_lisp_absoluto(self):
        fuentes = self.fuentes()
        valor = "/Contents/Lisp/MC-AREA.lsp"
        self.reemplazar_modulo(fuentes, './Contents/Lisp/MC-AREA.lsp', valor)
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo_exacto(
            resultado,
            fuentes.salida,
            previos,
            "ERROR: ModuleName absoluto no permitido: {!r}\n".format(valor),
        )

    def test_rechaza_module_name_cuix_absoluto(self):
        fuentes = self.fuentes()
        valor = "/Contents/UI/MensorCAD.cuix"
        self.reemplazar_modulo(fuentes, './Contents/UI/MensorCAD.cuix', valor)
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo_exacto(
            resultado,
            fuentes.salida,
            previos,
            "ERROR: ModuleName absoluto no permitido: {!r}\n".format(valor),
        )

    def test_rechaza_module_name_lisp_anidado(self):
        fuentes = self.fuentes()
        self.reemplazar_modulo(
            fuentes, "./Contents/Lisp/MC-AREA.lsp", "./Contents/Lisp/sub/MC-AREA.lsp"
        )
        previos = self.preparar_salida_previa(fuentes)
        previos[RUTA_SCRIPT_STANDALONE] = b"SCRIPT-PREVIO\n"
        (fuentes.salida / RUTA_SCRIPT_STANDALONE).write_bytes(
            previos[RUTA_SCRIPT_STANDALONE]
        )
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo_exacto(
            resultado,
            fuentes.salida,
            previos,
            "ERROR: el LISP debe declararse como ./Contents/Lisp/MC-AREA.lsp, "
            "no Contents/Lisp/sub/MC-AREA.lsp\n",
        )

    def test_rechaza_module_name_con_unidad_windows_y_unc(self):
        valores = ("C:/Contents/UI/MensorCAD.cuix", "\\\\srv\\cup\\Contents\\UI\\MensorCAD.cuix")
        for indice, valor in enumerate(valores):
            with self.subTest(valor=valor):
                fuentes = FuentesDePrueba(self.base / "caso-{}".format(indice))
                self.reemplazar_modulo(fuentes, './Contents/UI/MensorCAD.cuix', valor)
                previos = self.preparar_salida_previa(fuentes)
                resultado = self.ejecutar(fuentes.argumentos())
                self.assert_rechazo_exacto(
                    resultado,
                    fuentes.salida,
                    previos,
                    "ERROR: ModuleName absoluto no permitido: {!r}\n".format(valor),
                )

    def test_rechaza_enlace_simbolico_en_cuix(self):
        fuentes = self.fuentes()
        enlace = fuentes.cuix_dir / "iconos-enlazados.png"
        enlace.symlink_to(fuentes.license, target_is_directory=False)
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo(resultado, fuentes.salida, previos, "enlace simbólico")

    def test_rechaza_enlace_simbolico_de_directorio_en_cuix(self):
        fuentes = self.fuentes()
        (fuentes.cuix_dir / "carpeta-enlazada").symlink_to(
            fuentes.lisp_dir, target_is_directory=True
        )
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo(resultado, fuentes.salida, previos, "enlace simbólico")

    def test_rechaza_cache_dentro_de_cuix(self):
        fuentes = self.fuentes()
        cache = fuentes.cuix_dir / "__pycache__"
        cache.mkdir()
        (cache / "MenuGroup.cpython-315.pyc").write_bytes(b"cache")
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo(resultado, fuentes.salida, previos, "__pycache__")

    def test_rechaza_archivo_oculto_dentro_de_cuix(self):
        fuentes = self.fuentes()
        (fuentes.cuix_dir / ".DS_Store").write_bytes(b"metadatos ocultos")
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo(resultado, fuentes.salida, previos, "oculto")

    def test_rechaza_cuix_sin_content_types(self):
        fuentes = self.fuentes(
            cuix={clave: valor for clave, valor in CUIX_FIXTURE.items()
                  if clave != "[Content_Types].xml"}
        )
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo(resultado, fuentes.salida, previos, "Content_Types")

    def test_rechaza_salida_dentro_de_fuente_cuix(self):
        fuentes = self.fuentes()
        destino = fuentes.cuix_dir / "dist"
        resultado = self.ejecutar(fuentes.argumentos(output_dir=destino))
        self.assertNotEqual(resultado.returncode, 0, msg="se esperaba un rechazo")
        self.assertIn("salida", (resultado.stderr + resultado.stdout).lower())
        self.assertFalse(destino.exists(), msg="no debe crear la salida dentro de cuix/")

    def test_rechaza_salida_igual_a_fuente_lisp(self):
        fuentes = self.fuentes()
        resultado = self.ejecutar(fuentes.argumentos(output_dir=fuentes.lisp_dir))
        self.assertNotEqual(resultado.returncode, 0, msg="se esperaba un rechazo")
        self.assertFalse((fuentes.lisp_dir / ZIP_SALIDA).exists())

    def test_rechaza_manifiesto_con_loadonautocadstartup_en_lisp(self):
        fuentes = self.fuentes()
        xml = manifiesto("0.1.0", LISP_FIXTURE).decode("utf-8").replace(
            'PerDocument="True"', 'PerDocument="True" LoadOnAutoCADStartup="True"'
        )
        fuentes.package_contents.write_bytes(xml.encode("utf-8"))
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assert_rechazo(
            resultado, fuentes.salida, previos, "LoadOnAutoCADStartup"
        )


class PublicacionSegura(CasoBase):
    """B3/B4: temporales y colisiones no deben seguir enlaces ni mutar la salida."""

    def test_temporal_preexistente_no_se_sigue_ni_se_borra(self):
        fuentes = self.fuentes()
        fuentes.salida.mkdir(parents=True)
        objetivo = fuentes.license
        antes = objetivo.read_bytes()
        temporal_previo = fuentes.salida / TMP_PREVIO
        temporal_previo.symlink_to(objetivo)

        resultado = self.ejecutar(fuentes.argumentos())
        if resultado.returncode == 0:
            zip_salida = fuentes.salida / ZIP_SALIDA
            self.assertTrue(zip_salida.is_file())
            self.assertFalse(zip_salida.is_symlink(), msg="el ZIP publicado es un enlace")
            with zipfile.ZipFile(zip_salida) as zf:
                self.assertIsNone(zf.testzip(), msg="ZIP de salida corrupto")
            self.assertEqual(
                sorted(ruta.name for ruta in fuentes.salida.iterdir()),
                sorted([TMP_PREVIO, RUTA_SCRIPT_STANDALONE, SIDECAR, ZIP_SALIDA]),
            )
        else:
            self.assertEqual(
                sorted(ruta.name for ruta in fuentes.salida.iterdir()), [TMP_PREVIO]
            )
        self.assertEqual(objetivo.read_bytes(), antes, msg="se siguio el temporal enlazado")
        self.assertTrue(temporal_previo.is_symlink(), msg="se borro un temporal ajeno")

    def test_sidecar_como_directorio_no_muta_ninguna_salida_previa(self):
        fuentes = self.fuentes()
        fuentes.salida.mkdir(parents=True)
        zip_previo = b"ZIP-PREVIO-QUE-NO-DEBE-CAMBIAR"
        script_previo = b"SCRIPT-PREVIO-QUE-NO-DEBE-CAMBIAR\n"
        (fuentes.salida / ZIP_SALIDA).write_bytes(zip_previo)
        (fuentes.salida / RUTA_SCRIPT_STANDALONE).write_bytes(script_previo)
        sidecar = fuentes.salida / SIDECAR
        sidecar.mkdir()
        (sidecar / "marca.txt").write_bytes(b"marca")

        resultado = self.ejecutar(fuentes.argumentos())
        self.assertNotEqual(resultado.returncode, 0, msg="se esperaba un rechazo")
        self.assertIn(SIDECAR, resultado.stderr + resultado.stdout)
        self.assertEqual((fuentes.salida / ZIP_SALIDA).read_bytes(), zip_previo)
        self.assertEqual(
            (fuentes.salida / RUTA_SCRIPT_STANDALONE).read_bytes(), script_previo
        )
        self.assertTrue(sidecar.is_dir(), msg="se reemplazo el directorio sidecar")
        self.assertEqual((sidecar / "marca.txt").read_bytes(), b"marca")

    def test_destino_enlazado_no_se_sigue(self):
        fuentes = self.fuentes()
        fuentes.salida.mkdir(parents=True)
        objetivo = fuentes.license
        antes = objetivo.read_bytes()
        (fuentes.salida / ZIP_SALIDA).symlink_to(objetivo)

        resultado = self.ejecutar(fuentes.argumentos())
        self.assertNotEqual(resultado.returncode, 0, msg="se esperaba un rechazo")
        self.assertIn("enlace simbólico", resultado.stderr + resultado.stdout)
        self.assertEqual(objetivo.read_bytes(), antes, msg="se siguio el destino enlazado")
        self.assertTrue((fuentes.salida / ZIP_SALIDA).is_symlink())
        self.assertFalse((fuentes.salida / SIDECAR).exists())
        self.assertFalse((fuentes.salida / RUTA_SCRIPT_STANDALONE).exists())


class RepositorioReal(CasoBase):
    """S3: el CUIX del repositorio se reconstruye sin alterar un solo byte."""

    def test_empaqueta_las_13_lisp_y_preserva_cuix_y_fuentes(self):
        fuentes = self.fuentes()
        lisp_reales = sorted(RAIZ_REPO.joinpath("lisp").glob("MC-*.lsp"))
        self.assertEqual(len(lisp_reales), 13)
        cuix_real = RAIZ_REPO / "cuix"
        origen_cuix = {
            ruta.relative_to(cuix_real).as_posix(): ruta.read_bytes()
            for ruta in cuix_real.rglob("*")
            if ruta.is_file()
        }
        antes = {
            ruta: sha256_archivo(ruta)
            for ruta in [*lisp_reales, *sorted(cuix_real.rglob("*"))]
            if ruta.is_file()
        }

        destino = self.base / "dist-real"
        argumentos = [
            "--output-dir",
            str(destino),
            "--package-contents",
            str(RAIZ_REPO / "PackageContents.xml"),
            "--lisp-dir",
            str(RAIZ_REPO / "lisp"),
            "--cuix-dir",
            str(cuix_real),
            "--install-script",
            str(fuentes.install_script),
            "--bat-script",
            str(fuentes.bat_script),
            "--license",
            str(RAIZ_REPO / "LICENSE"),
        ]
        resultado = self.ejecutar(argumentos)
        self.assertEqual(
            resultado.returncode,
            0,
            msg="STDOUT:\n{}\nSTDERR:\n{}".format(resultado.stdout, resultado.stderr),
        )

        with self.leer_zip(destino / ZIP_SALIDA) as zf:
            nombres = set(zf.namelist())
            lisp_empaquetados = sorted(
                nombre.rsplit("/", 1)[-1]
                for nombre in nombres
                if nombre.startswith(RAIZ_BUNDLE + "Contents/Lisp/")
            )
            self.assertEqual(lisp_empaquetados, [ruta.name for ruta in lisp_reales])
            raices = {nombre.split("/", 1)[0] for nombre in nombres}
            self.assertEqual(
                raices,
                {
                    "MensorCAD.bundle",
                    "bundle.sha256",
                    "Install-MensorCAD.ps1",
                    "Instalar.bat",
                    "LICENSE",
                },
            )
            self.assertFalse(any("odd/" in nombre or "tests/" in nombre for nombre in nombres))
            self.assertFalse(any(nombre.startswith(".git") for nombre in nombres))
            with self.leer_cuix(zf) as cuix:
                self.assertEqual(sorted(cuix.namelist()), sorted(origen_cuix))
                for relativa, contenido in origen_cuix.items():
                    self.assertEqual(cuix.read(relativa), contenido, msg="se altero " + relativa)

        despues = {
            ruta: sha256_archivo(ruta)
            for ruta in [*lisp_reales, *sorted(cuix_real.rglob("*"))]
            if ruta.is_file()
        }
        self.assertEqual(antes, despues, msg="el constructor modifico las fuentes")


if __name__ == "__main__":
    unittest.main()
