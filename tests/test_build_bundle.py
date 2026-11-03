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
ZIP_CLI = "MensorCAD-CLI.zip"
SIDECAR_CLI = "MensorCAD-CLI.zip.sha256"
RUTA_SCRIPT_STANDALONE = "Install-MensorCAD.ps1"
RUTA_BOOTSTRAP = "install.ps1"
RUTA_GESTOR = "mensorcad.ps1"
RUTA_LANZADOR = "mensorcad.cmd"
MARCADOR_VERSION = b"__MENSORCAD_RELEASE_VERSION__"
MARCADOR_GESTOR = b"__MENSORCAD_MANAGER_VERSION__"
ENTRADAS_CLI = ("Install-MensorCAD.ps1", "mensorcad.cmd", "mensorcad.ps1")
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
        self.bootstrap_script = self.raiz / RUTA_BOOTSTRAP
        self.manager_script = self.raiz / RUTA_GESTOR
        self.launcher_script = self.raiz / RUTA_LANZADOR
        self.bat_script = self.raiz / "Instalar.bat"
        self.uninstall_bat_script = self.raiz / "Desinstalar.bat"
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
            b"param([switch]$Uninstall)\n"
            b"$script:MensorCadReleaseVersion = '" + MARCADOR_VERSION + b"'\n"
            b"Write-Host 'instalador de prueba'\n"
        )
        self.bootstrap_script.write_bytes(
            b"\xef\xbb\xbfparam([string]$Version, [switch]$NoAnimation)\r\n"
            b"Write-Host 'bootstrap de prueba'\r\n"
        )
        self.manager_script.write_bytes(
            b"#requires -Version 5.1\r\n"
            b"$script:MensorCadManagerVersion = '" + MARCADOR_GESTOR + b"'\r\n"
            b"Write-Output 'gestor de prueba'\r\n"
        )
        self.launcher_script.write_bytes(
            b"@echo off\r\n"
            b"set \"MENSORCAD_MANAGER_SCRIPT=%~dp0mensorcad.ps1\"\r\n"
            b"exit /b %ERRORLEVEL%\r\n"
        )
        self.bat_script.write_bytes(b"@echo off\r\npowershell -File Install-MensorCAD.ps1\r\n")
        self.uninstall_bat_script.write_bytes(b'@echo off\r\n"%~dp0Instalar.bat" -Uninstall\r\n')
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
            "--bootstrap-script",
            str(self.bootstrap_script),
            "--manager-script",
            str(self.manager_script),
            "--launcher-script",
            str(self.launcher_script),
            "--bat-script",
            str(self.bat_script),
            "--uninstall-bat-script",
            str(self.uninstall_bat_script),
            "--license",
            str(self.license),
        ]
        if version is not None:
            argumentos.extend(["--version", version])
        return argumentos

    def argumentos_con_script(self, output_dir: Path, install_script: Path):
        argumentos = self.argumentos(output_dir=output_dir)
        indice = argumentos.index("--install-script") + 1
        argumentos[indice] = str(install_script)
        return argumentos

    def argumentos_con_bootstrap(self, output_dir: Path, bootstrap_script: Path):
        argumentos = self.argumentos(output_dir=output_dir)
        indice = argumentos.index("--bootstrap-script") + 1
        argumentos[indice] = str(bootstrap_script)
        return argumentos

    def argumentos_con_gestor(self, output_dir: Path, manager_script: Path):
        argumentos = self.argumentos(output_dir=output_dir)
        indice = argumentos.index("--manager-script") + 1
        argumentos[indice] = str(manager_script)
        return argumentos

    def argumentos_con_lanzador(self, output_dir: Path, launcher_script: Path):
        argumentos = self.argumentos(output_dir=output_dir)
        indice = argumentos.index("--launcher-script") + 1
        argumentos[indice] = str(launcher_script)
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

    def script_esperado(self, fuentes: FuentesDePrueba, version: str = "0.1.0") -> bytes:
        return fuentes.install_script.read_bytes().replace(
            MARCADOR_VERSION, version.encode("ascii")
        )

    def bootstrap_esperado(self, fuentes: FuentesDePrueba) -> bytes:
        # El bootstrap no se estampa: la cuarta salida es una copia byte a byte.
        return fuentes.bootstrap_script.read_bytes()

    def gestor_esperado(self, fuentes: FuentesDePrueba, version: str = "0.1.0") -> bytes:
        return fuentes.manager_script.read_bytes().replace(
            MARCADOR_GESTOR, version.encode("ascii")
        )

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
                RAIZ_BUNDLE + "Install-MensorCAD.ps1",
                "bundle.sha256",
                "Install-MensorCAD.ps1",
                "Instalar.bat",
                "Desinstalar.bat",
                "LICENSE",
            }
            self.assertEqual(nombres, esperados)
            self.assertEqual(len(zf.namelist()), len(nombres), msg="entradas duplicadas")
            self.assertIsNone(zf.testzip(), msg="ZIP de salida corrupto")
            for nombre in nombres:
                self.assertFalse(nombre.endswith("/"), msg="entrada de directorio: " + nombre)
                self.assertNotIn(".git/", nombre)
                self.assertNotIn("__pycache__", nombre)

    def test_manifiesto_lisp_y_auxiliares_se_copian_y_script_se_estampa(self):
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
            self.assertEqual(zf.read("Install-MensorCAD.ps1"), self.script_esperado(fuentes))
            self.assertEqual(zf.read("Instalar.bat"), fuentes.bat_script.read_bytes())
            self.assertEqual(zf.read("Desinstalar.bat"), fuentes.uninstall_bat_script.read_bytes())
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
        self.assertEqual(
            generados,
            sorted(
                [
                    RUTA_SCRIPT_STANDALONE,
                    RUTA_BOOTSTRAP,
                    ZIP_SALIDA,
                    SIDECAR,
                    ZIP_CLI,
                    SIDECAR_CLI,
                ]
            ),
        )

    def test_script_standalone_se_emite_estampado_e_identico_al_zip(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        standalone = fuentes.salida / RUTA_SCRIPT_STANDALONE
        self.assertTrue(standalone.is_file(), msg="falta " + RUTA_SCRIPT_STANDALONE)
        self.assertFalse(standalone.is_symlink())
        self.assertEqual(standalone.read_bytes(), self.script_esperado(fuentes))
        with self.leer_zip(fuentes.salida / ZIP_SALIDA) as zf:
            self.assertEqual(zf.read("Install-MensorCAD.ps1"), standalone.read_bytes())

    def test_estampa_version_real_sin_tocar_la_plantilla(self):
        fuentes = self.fuentes(version="1.2.3")
        plantilla = fuentes.install_script.read_bytes()
        self.assertIn(MARCADOR_VERSION, plantilla)

        self.construir(fuentes, version="1.2.3")
        estampado = self.script_esperado(fuentes, "1.2.3")
        standalone = (fuentes.salida / RUTA_SCRIPT_STANDALONE).read_bytes()
        self.assertEqual(standalone, estampado)
        self.assertIn(b"1.2.3", standalone)
        self.assertNotIn(MARCADOR_VERSION, standalone)
        with self.leer_zip(fuentes.salida / ZIP_SALIDA) as zf:
            self.assertEqual(zf.read("Install-MensorCAD.ps1"), estampado)
        self.assertEqual(fuentes.install_script.read_bytes(), plantilla, msg="se mutó la plantilla")

    def test_estampa_otra_release_sin_editar_la_plantilla(self):
        fuentes = self.fuentes(version="0.1.0")
        plantilla = fuentes.install_script.read_bytes()
        destino_a = self.base / "release-a"
        destino_b = self.base / "release-b"
        self.construir(fuentes, output_dir=destino_a)
        fuentes.package_contents.write_bytes(manifiesto("2.0.0", LISP_FIXTURE))
        self.construir(fuentes, output_dir=destino_b, version="2.0.0")

        script_a = (destino_a / RUTA_SCRIPT_STANDALONE).read_bytes()
        script_b = (destino_b / RUTA_SCRIPT_STANDALONE).read_bytes()
        self.assertIn(b"0.1.0", script_a)
        self.assertIn(b"2.0.0", script_b)
        self.assertNotIn(MARCADOR_VERSION, script_a)
        self.assertNotIn(MARCADOR_VERSION, script_b)
        self.assertEqual(fuentes.install_script.read_bytes(), plantilla, msg="se editó la plantilla")

    def test_estampar_preserva_bom_y_fin_de_linea(self):
        fuentes = self.fuentes()
        original = (
            b"\xef\xbb\xbfWrite-Host 'plantilla'\r\n"
            b"$script:MensorCadReleaseVersion = '" + MARCADOR_VERSION + b"'\r\n"
        )
        fuentes.install_script.write_bytes(original)
        self.construir(fuentes)

        estampado = (fuentes.salida / RUTA_SCRIPT_STANDALONE).read_bytes()
        self.assertTrue(estampado.startswith(b"\xef\xbb\xbf"), msg="se perdió el BOM")
        self.assertEqual(estampado.count(b"\r\n"), original.count(b"\r\n"))
        self.assertIn(b"0.1.0", estampado)
        self.assertNotIn(MARCADOR_VERSION, estampado)
        self.assertEqual(fuentes.install_script.read_bytes(), original, msg="se mutó la plantilla")

    def test_acepta_manifiesto_con_solo_version_coincidente(self):
        fuentes = self.fuentes()
        # Se trabaja en bytes a proposito: Path.write_text traduce "\n" al fin de
        # linea de la plataforma y el constructor solo debe copiar bytes.
        xml = fuentes.package_contents.read_bytes().replace(b'AppVersion="0.1.0" ', b"")
        fuentes.package_contents.write_bytes(xml)
        self.construir(fuentes)

        zip_salida = fuentes.salida / ZIP_SALIDA
        with self.leer_zip(zip_salida) as zf:
            self.assertEqual(zf.read(RAIZ_BUNDLE + "PackageContents.xml"), xml)
            self.assertIsNone(zf.testzip(), msg="ZIP de salida corrupto")
        self.assertEqual(
            (fuentes.salida / SIDECAR).read_text(encoding="utf-8"),
            "{}  {}\n".format(sha256_archivo(zip_salida), ZIP_SALIDA),
        )
        self.assertEqual(
            (fuentes.salida / RUTA_SCRIPT_STANDALONE).read_bytes(),
            self.script_esperado(fuentes),
        )

    def test_preserva_el_manifiesto_con_fin_de_linea_crlf(self):
        # Un checkout Windows (core.autocrlf=true) entrega CRLF: el constructor
        # no debe normalizar ni rechazar el manifiesto por su fin de linea.
        fuentes = self.fuentes()
        xml = manifiesto("0.1.0", LISP_FIXTURE).replace(b"\n", b"\r\n")
        fuentes.package_contents.write_bytes(xml)
        self.construir(fuentes)

        with self.leer_zip(fuentes.salida / ZIP_SALIDA) as zf:
            self.assertEqual(
                zf.read(RAIZ_BUNDLE + "PackageContents.xml"),
                xml,
                msg="el manifiesto CRLF debe conservarse byte a byte",
            )
            self.assertIsNone(zf.testzip(), msg="ZIP de salida corrupto")

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


class BootstrapDeSalida(CasoBase):
    """B4: la cuarta salida es una copia del bootstrap, fuera del ZIP."""

    def test_bootstrap_se_copia_byte_a_byte_y_no_se_estampa(self):
        fuentes = self.fuentes()
        original = fuentes.bootstrap_script.read_bytes()
        self.construir(fuentes)

        bootstrap = fuentes.salida / RUTA_BOOTSTRAP
        self.assertTrue(bootstrap.is_file(), msg="falta " + RUTA_BOOTSTRAP)
        self.assertFalse(bootstrap.is_symlink())
        self.assertEqual(bootstrap.read_bytes(), original)
        self.assertTrue(
            bootstrap.read_bytes().startswith(b"\xef\xbb\xbf"), msg="se perdió el BOM"
        )
        self.assertEqual(
            fuentes.bootstrap_script.read_bytes(), original, msg="se mutó el bootstrap fuente"
        )
        # El bootstrap no duplica la version del producto ni el marcador de la plantilla.
        self.assertNotIn(MARCADOR_VERSION, bootstrap.read_bytes())
        self.assertNotIn(b"0.1.0", bootstrap.read_bytes())

    def test_bootstrap_no_agrega_entradas_al_zip(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        with self.leer_zip(fuentes.salida / ZIP_SALIDA) as zf:
            nombres = zf.namelist()
            self.assertNotIn(RUTA_BOOTSTRAP, nombres)
            self.assertFalse(
                any(nombre.casefold() == RUTA_BOOTSTRAP for nombre in nombres),
                msg="el bootstrap no viaja dentro del ZIP",
            )
            self.assertEqual(len(nombres), 10, msg="se agrego una entrada al inventario")
            self.assertEqual(len(nombres), len(set(nombres)), msg="entradas duplicadas")
            self.assertIsNone(zf.testzip(), msg="ZIP de salida corrupto")

    def test_bootstrap_reproducible_entre_construcciones(self):
        fuentes = self.fuentes()
        destino_a = self.base / "bootstrap-a"
        destino_b = self.base / "bootstrap-b"
        self.construir(fuentes, output_dir=destino_a)
        self.construir(fuentes, output_dir=destino_b)

        self.assertEqual(
            (destino_a / RUTA_BOOTSTRAP).read_bytes(),
            (destino_b / RUTA_BOOTSTRAP).read_bytes(),
        )
        self.assertEqual(
            (destino_a / ZIP_SALIDA).read_bytes(), (destino_b / ZIP_SALIDA).read_bytes()
        )

    def test_bootstrap_por_defecto_es_el_del_repositorio(self):
        # Sin --bootstrap-script, la cuarta salida es la copia de install.ps1
        # de la raiz del repositorio, no una ruta adivinada en dist/.
        fuentes = self.fuentes()
        argumentos = fuentes.argumentos()
        indice = argumentos.index("--bootstrap-script")
        del argumentos[indice : indice + 2]

        resultado = self.ejecutar(argumentos)
        self.assertEqual(
            resultado.returncode,
            0,
            msg="STDOUT:\n{}\nSTDERR:\n{}".format(resultado.stdout, resultado.stderr),
        )
        self.assertEqual(
            (fuentes.salida / RUTA_BOOTSTRAP).read_bytes(),
            (RAIZ_REPO / RUTA_BOOTSTRAP).read_bytes(),
        )


class CliDeSalida(CasoBase):
    """El ZIP del gestor y el motor protegido dentro del bundle."""

    def test_zip_cli_contiene_tres_entradas_planas_exactas(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        cli_zip = fuentes.salida / ZIP_CLI
        self.assertTrue(cli_zip.is_file(), msg="falta " + ZIP_CLI)
        self.assertFalse(cli_zip.is_symlink())
        with self.leer_zip(cli_zip) as zf:
            self.assertEqual(sorted(zf.namelist()), sorted(ENTRADAS_CLI))
            self.assertEqual(len(zf.namelist()), len(set(zf.namelist())), msg="duplicados")
            self.assertIsNone(zf.testzip(), msg="ZIP del gestor corrupto")
            for nombre in zf.namelist():
                self.assertNotIn("/", nombre, msg="ruta no plana: " + nombre)
                self.assertNotIn("\\", nombre, msg="ruta no plana: " + nombre)
                self.assertGreater(zf.getinfo(nombre).file_size, 0, msg="entrada vacia: " + nombre)

    def test_sidecar_cli_nombra_el_zip(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        cli_zip = fuentes.salida / ZIP_CLI
        sidecar = fuentes.salida / SIDECAR_CLI
        self.assertTrue(sidecar.is_file(), msg="falta " + SIDECAR_CLI)
        contenido = sidecar.read_text(encoding="utf-8")
        self.assertEqual(contenido, "{}  {}\n".format(sha256_archivo(cli_zip), ZIP_CLI))
        self.assertNotIn("\r", contenido, msg="el sidecar no lleva CR")

    def test_gestor_se_estampa_y_lanzador_se_copia_byte_a_byte(self):
        fuentes = self.fuentes()
        gestor_fuente = fuentes.manager_script.read_bytes()
        lanzador_fuente = fuentes.launcher_script.read_bytes()
        self.construir(fuentes)

        with self.leer_zip(fuentes.salida / ZIP_CLI) as zf:
            gestor = zf.read(RUTA_GESTOR)
            self.assertEqual(gestor, self.gestor_esperado(fuentes))
            self.assertIn(b"0.1.0", gestor)
            self.assertNotIn(MARCADOR_GESTOR, gestor)
            self.assertNotIn(MARCADOR_VERSION, gestor)
            self.assertEqual(zf.read(RUTA_LANZADOR), lanzador_fuente)
            self.assertEqual(zf.read(RUTA_SCRIPT_STANDALONE), self.script_esperado(fuentes))
        self.assertEqual(
            fuentes.manager_script.read_bytes(), gestor_fuente, msg="se muto el gestor fuente"
        )
        self.assertEqual(
            fuentes.launcher_script.read_bytes(),
            lanzador_fuente,
            msg="se muto el lanzador fuente",
        )

    def test_el_motor_protegido_entra_en_el_inventario_del_bundle(self):
        fuentes = self.fuentes()
        self.construir(fuentes)

        estampado = self.script_esperado(fuentes)
        with self.leer_zip(fuentes.salida / ZIP_SALIDA) as zf:
            motor_bundle = zf.read(RAIZ_BUNDLE + RUTA_SCRIPT_STANDALONE)
            self.assertEqual(motor_bundle, estampado, msg="el motor del bundle debe ir estampado")
            self.assertEqual(zf.read(RUTA_SCRIPT_STANDALONE), motor_bundle)
            lineas = self.lineas_bundle_sha256(zf)
            rutas = [ruta for _, ruta in lineas]
            self.assertIn(RUTA_SCRIPT_STANDALONE, rutas)
            hashes = {ruta: digest for digest, ruta in lineas}
            self.assertEqual(hashes[RUTA_SCRIPT_STANDALONE], sha256_bytes(motor_bundle))
            esperadas = sorted(
                nombre[len(RAIZ_BUNDLE) :]
                for nombre in zf.namelist()
                if nombre.startswith(RAIZ_BUNDLE)
            )
            self.assertEqual(rutas, esperadas, msg="el inventario debe cubrir el bundle completo")

    def test_cli_reproducible_y_no_muta_las_fuentes(self):
        fuentes = self.fuentes()
        antes = {
            ruta: sha256_archivo(ruta)
            for ruta in (fuentes.manager_script, fuentes.launcher_script, fuentes.install_script)
        }
        destino_a = self.base / "cli-a"
        destino_b = self.base / "cli-b"
        self.construir(fuentes, output_dir=destino_a)
        self.construir(fuentes, output_dir=destino_b)

        self.assertEqual(
            (destino_a / ZIP_CLI).read_bytes(), (destino_b / ZIP_CLI).read_bytes()
        )
        self.assertEqual(
            (destino_a / SIDECAR_CLI).read_text(encoding="utf-8"),
            (destino_b / SIDECAR_CLI).read_text(encoding="utf-8"),
        )
        despues = {ruta: sha256_archivo(ruta) for ruta in antes}
        self.assertEqual(antes, despues, msg="el constructor muto una fuente")

    def test_help_lista_las_salidas_del_gestor(self):
        resultado = self.ejecutar(["--help"])
        self.assertEqual(resultado.returncode, 0)
        for fragmento in (
            ZIP_CLI,
            RUTA_GESTOR,
            RUTA_LANZADOR,
            "--manager-script",
            "--launcher-script",
            MARCADOR_GESTOR.decode("ascii"),
        ):
            self.assertIn(fragmento, resultado.stdout, msg="la ayuda no menciona " + fragmento)


class Rechazos(CasoBase):
    def preparar_salida_previa(self, fuentes: FuentesDePrueba) -> dict[str, bytes]:
        fuentes.salida.mkdir(parents=True, exist_ok=True)
        previos = {
            ZIP_SALIDA: b"ZIP-ANTERIOR-QUE-NO-DEBE-CAMBIAR",
            SIDECAR: b"CHECKSUM-ANTERIOR-QUE-NO-DEBE-CAMBIAR\n",
            RUTA_BOOTSTRAP: b"BOOTSTRAP-ANTERIOR-QUE-NO-DEBE-CAMBIAR\n",
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

    def preparar_salida_estampado(self, fuentes: FuentesDePrueba) -> dict[str, bytes]:
        previos = self.preparar_salida_previa(fuentes)
        previos[RUTA_SCRIPT_STANDALONE] = b"SCRIPT-ANTERIOR-QUE-NO-DEBE-CAMBIAR\n"
        (fuentes.salida / RUTA_SCRIPT_STANDALONE).write_bytes(
            previos[RUTA_SCRIPT_STANDALONE]
        )
        return previos

    def test_rechaza_marcador_ausente_sin_mutar_salidas(self):
        fuentes = self.fuentes()
        fuente_sin_marcador = b"param([switch]$Uninstall)\nWrite-Host 'sin marcador'\n"
        fuentes.install_script.write_bytes(fuente_sin_marcador)
        previos = self.preparar_salida_estampado(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertIn("marcador", resultado.stderr.lower())
        self.assert_rechazo(resultado, fuentes.salida, previos, "marcador")
        self.assertEqual(fuentes.install_script.read_bytes(), fuente_sin_marcador)

    def test_rechaza_marcador_duplicado_sin_mutar_salidas(self):
        fuentes = self.fuentes()
        fuente_duplicada = (
            b"$script:MensorCadReleaseVersion = '" + MARCADOR_VERSION + b"'\n"
            b"$script:OtraCopia = '" + MARCADOR_VERSION + b"'\n"
        )
        fuentes.install_script.write_bytes(fuente_duplicada)
        previos = self.preparar_salida_estampado(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertIn("marcador", resultado.stderr.lower())
        self.assert_rechazo(resultado, fuentes.salida, previos, "marcador")
        self.assertEqual(fuentes.install_script.read_bytes(), fuente_duplicada)

    def preparar_colision_plantilla(self, fuentes: FuentesDePrueba, nombre_destino: str):
        """Coloca la plantilla en una salida y deja sentinelas en las otras tres."""
        fuentes.salida.mkdir(parents=True, exist_ok=True)
        plantilla = fuentes.install_script.read_bytes()
        previos: dict[str, bytes] = {}
        for nombre in (ZIP_SALIDA, SIDECAR, RUTA_SCRIPT_STANDALONE, RUTA_BOOTSTRAP):
            contenido = plantilla if nombre == nombre_destino else (
                "SENTINELA-{}".format(nombre).encode("utf-8")
            )
            (fuentes.salida / nombre).write_bytes(contenido)
            previos[nombre] = contenido
        return fuentes.salida / nombre_destino, previos

    def assert_colision_plantilla(self, nombre_destino: str):
        fuentes = self.fuentes()
        destino, previos = self.preparar_colision_plantilla(fuentes, nombre_destino)
        resultado = self.ejecutar(
            fuentes.argumentos_con_script(fuentes.salida, destino)
        )
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertEqual(
            resultado.stderr,
            "ERROR: la salida {} no puede ser el mismo archivo que la plantilla fuente: {}\n".format(
                nombre_destino, destino
            ),
        )
        self.assert_rechazo(resultado, fuentes.salida, previos, "mismo archivo")
        self.assertEqual(
            destino.read_bytes(), previos[nombre_destino], msg="se mutó la plantilla fuente"
        )

    def test_rechaza_plantilla_colisionada_con_el_zip(self):
        self.assert_colision_plantilla(ZIP_SALIDA)

    def test_rechaza_plantilla_colisionada_con_el_sidecar(self):
        self.assert_colision_plantilla(SIDECAR)

    def test_rechaza_plantilla_colisionada_con_el_standalone(self):
        self.assert_colision_plantilla(RUTA_SCRIPT_STANDALONE)

    def test_rechaza_plantilla_colisionada_con_el_bootstrap(self):
        self.assert_colision_plantilla(RUTA_BOOTSTRAP)

    def preparar_colision_bootstrap(self, fuentes: FuentesDePrueba, nombre_destino: str):
        """Coloca el bootstrap en una salida y deja sentinelas en las otras tres."""
        fuentes.salida.mkdir(parents=True, exist_ok=True)
        bootstrap = fuentes.bootstrap_script.read_bytes()
        previos: dict[str, bytes] = {}
        for nombre in (ZIP_SALIDA, SIDECAR, RUTA_SCRIPT_STANDALONE, RUTA_BOOTSTRAP):
            contenido = bootstrap if nombre == nombre_destino else (
                "SENTINELA-{}".format(nombre).encode("utf-8")
            )
            (fuentes.salida / nombre).write_bytes(contenido)
            previos[nombre] = contenido
        return fuentes.salida / nombre_destino, previos

    def assert_colision_bootstrap(self, nombre_destino: str):
        fuentes = self.fuentes()
        destino, previos = self.preparar_colision_bootstrap(fuentes, nombre_destino)
        resultado = self.ejecutar(
            fuentes.argumentos_con_bootstrap(fuentes.salida, destino)
        )
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertEqual(
            resultado.stderr,
            "ERROR: la salida {} no puede ser el mismo archivo que el bootstrap fuente: {}\n".format(
                nombre_destino, destino
            ),
        )
        self.assert_rechazo(resultado, fuentes.salida, previos, "bootstrap")
        self.assertEqual(
            destino.read_bytes(), previos[nombre_destino], msg="se mutó el bootstrap fuente"
        )

    def test_rechaza_bootstrap_colisionado_con_el_zip(self):
        self.assert_colision_bootstrap(ZIP_SALIDA)

    def test_rechaza_bootstrap_colisionado_con_el_sidecar(self):
        self.assert_colision_bootstrap(SIDECAR)

    def test_rechaza_bootstrap_colisionado_con_el_standalone(self):
        self.assert_colision_bootstrap(RUTA_SCRIPT_STANDALONE)

    def test_rechaza_bootstrap_colisionado_con_su_propia_salida(self):
        self.assert_colision_bootstrap(RUTA_BOOTSTRAP)

    def test_rechaza_bootstrap_ausente_sin_mutar_salidas(self):
        fuentes = self.fuentes()
        fuentes.bootstrap_script.unlink()
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertEqual(
            resultado.stderr,
            "ERROR: falta install.ps1: {}\n".format(fuentes.bootstrap_script),
        )
        self.assert_rechazo(resultado, fuentes.salida, previos, "install.ps1")

    def test_rechaza_bootstrap_con_marcador_de_version_sin_mutar_salidas(self):
        fuentes = self.fuentes()
        fuente = (
            b"param([string]$Version)\n"
            b"$script:MensorCadReleaseVersion = '" + MARCADOR_VERSION + b"'\n"
        )
        fuentes.bootstrap_script.write_bytes(fuente)
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertIn("marcador", resultado.stderr.lower())
        self.assertIn("install.ps1", resultado.stderr)
        self.assert_rechazo(resultado, fuentes.salida, previos, "marcador")
        self.assertEqual(fuentes.bootstrap_script.read_bytes(), fuente)

    def test_rechaza_gestor_sin_marcador_sin_mutar_salidas(self):
        fuentes = self.fuentes()
        fuente = b"#requires -Version 5.1\nWrite-Output 'gestor sin marcador'\n"
        fuentes.manager_script.write_bytes(fuente)
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertIn("marcador", resultado.stderr.lower())
        self.assertIn(RUTA_GESTOR, resultado.stderr)
        self.assert_rechazo(resultado, fuentes.salida, previos, "marcador")
        self.assertEqual(fuentes.manager_script.read_bytes(), fuente)

    def test_rechaza_gestor_con_marcador_duplicado_sin_mutar_salidas(self):
        fuentes = self.fuentes()
        fuente = (
            b"$script:MensorCadManagerVersion = '" + MARCADOR_GESTOR + b"'\n"
            b"$script:OtraCopia = '" + MARCADOR_GESTOR + b"'\n"
        )
        fuentes.manager_script.write_bytes(fuente)
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertIn("marcador", resultado.stderr.lower())
        self.assert_rechazo(resultado, fuentes.salida, previos, "marcador")
        self.assertEqual(fuentes.manager_script.read_bytes(), fuente)

    def test_rechaza_lanzador_no_ascii_sin_mutar_salidas(self):
        fuentes = self.fuentes()
        fuente = b"\xef\xbb\xbf@echo off\r\nexit /b 0\r\n"
        fuentes.launcher_script.write_bytes(fuente)
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertIn(RUTA_LANZADOR, resultado.stderr)
        self.assertIn("ascii", resultado.stderr.lower())
        self.assert_rechazo(resultado, fuentes.salida, previos, "ascii")
        self.assertEqual(fuentes.launcher_script.read_bytes(), fuente)

    def preparar_colision_fuente(
        self, fuentes: FuentesDePrueba, nombre_destino: str, contenido: bytes
    ):
        fuentes.salida.mkdir(parents=True, exist_ok=True)
        previos: dict[str, bytes] = {}
        for nombre in (
            ZIP_SALIDA,
            SIDECAR,
            RUTA_SCRIPT_STANDALONE,
            RUTA_BOOTSTRAP,
            ZIP_CLI,
            SIDECAR_CLI,
        ):
            valor = (
                contenido
                if nombre == nombre_destino
                else "SENTINELA-{}".format(nombre).encode("utf-8")
            )
            (fuentes.salida / nombre).write_bytes(valor)
            previos[nombre] = valor
        return fuentes.salida / nombre_destino, previos

    def test_rechaza_gestor_colisionado_con_su_salida(self):
        fuentes = self.fuentes()
        destino, previos = self.preparar_colision_fuente(
            fuentes, ZIP_CLI, fuentes.manager_script.read_bytes()
        )
        resultado = self.ejecutar(fuentes.argumentos_con_gestor(fuentes.salida, destino))
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertEqual(
            resultado.stderr,
            "ERROR: la salida {} no puede ser el mismo archivo que el comando gestor "
            "fuente: {}\n".format(ZIP_CLI, destino),
        )
        self.assert_rechazo(resultado, fuentes.salida, previos, "mismo archivo")
        self.assertEqual(
            destino.read_bytes(), previos[ZIP_CLI], msg="se muto el gestor fuente"
        )

    def test_rechaza_lanzador_colisionado_con_su_salida(self):
        fuentes = self.fuentes()
        destino, previos = self.preparar_colision_fuente(
            fuentes, SIDECAR_CLI, fuentes.launcher_script.read_bytes()
        )
        resultado = self.ejecutar(fuentes.argumentos_con_lanzador(fuentes.salida, destino))
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertEqual(
            resultado.stderr,
            "ERROR: la salida {} no puede ser el mismo archivo que el lanzador "
            "fuente: {}\n".format(SIDECAR_CLI, destino),
        )
        self.assert_rechazo(resultado, fuentes.salida, previos, "mismo archivo")
        self.assertEqual(
            destino.read_bytes(), previos[SIDECAR_CLI], msg="se muto el lanzador fuente"
        )

    def test_help_documenta_la_cuarta_salida_y_su_bandera(self):
        resultado = self.ejecutar(["--help"])
        self.assertEqual(resultado.returncode, 0)
        self.assertIn("--bootstrap-script", resultado.stdout)
        self.assertIn("install.ps1", resultado.stdout)
        self.assertIn("cuarta salida", resultado.stdout)
        self.assertIn("byte", resultado.stdout.lower())

    def test_help_describe_el_marcador_de_la_plantilla(self):
        resultado = self.ejecutar(["--help"])
        self.assertEqual(resultado.returncode, 0)
        self.assertIn(MARCADOR_VERSION.decode("ascii"), resultado.stdout)
        self.assertIn("plantilla", resultado.stdout.lower())

    def test_rechaza_desinstalador_ausente_sin_modificar_salida(self):
        fuentes = self.fuentes()
        fuentes.uninstall_bat_script.unlink()
        previos = self.preparar_salida_previa(fuentes)
        resultado = self.ejecutar(fuentes.argumentos())
        self.assertEqual(resultado.returncode, 1)
        self.assertEqual(resultado.stdout, "")
        self.assertEqual(
            resultado.stderr,
            "ERROR: falta Desinstalar.bat: {}\n".format(fuentes.uninstall_bat_script),
        )
        self.assert_rechazo(resultado, fuentes.salida, previos, "Desinstalar.bat")

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
                sorted(
                    [
                        TMP_PREVIO,
                        RUTA_SCRIPT_STANDALONE,
                        RUTA_BOOTSTRAP,
                        SIDECAR,
                        ZIP_SALIDA,
                        ZIP_CLI,
                        SIDECAR_CLI,
                    ]
                ),
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
        self.assertFalse(
            (fuentes.salida / RUTA_BOOTSTRAP).exists(),
            msg="un rechazo no debe publicar el bootstrap",
        )

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
        bootstrap_real = RAIZ_REPO / RUTA_BOOTSTRAP
        self.assertTrue(bootstrap_real.is_file(), msg="falta " + RUTA_BOOTSTRAP)
        antes_bootstrap = sha256_archivo(bootstrap_real)
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
            "--bootstrap-script",
            str(bootstrap_real),
            "--bat-script",
            str(fuentes.bat_script),
            "--uninstall-bat-script",
            str(fuentes.uninstall_bat_script),
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
                    "Desinstalar.bat",
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
        self.assertEqual(
            sha256_archivo(bootstrap_real),
            antes_bootstrap,
            msg="el constructor modifico el bootstrap fuente",
        )
        self.assertEqual(
            (destino / RUTA_BOOTSTRAP).read_bytes(),
            bootstrap_real.read_bytes(),
            msg="el bootstrap publicado debe ser la copia byte a byte",
        )


if __name__ == "__main__":
    unittest.main()
