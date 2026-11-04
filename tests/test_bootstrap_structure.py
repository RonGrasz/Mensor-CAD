"""Comprobaciones estructurales del bootstrap corto ``install.ps1``.

Estas pruebas leen texto y aplican expresiones regulares: NO ejecutan
PowerShell, NO descargan nada y NO demuestran que la instalacion funcione. La
ejecucion funcional vive en ``tests/Test-CliBootstrap.ps1`` y requiere Windows
PowerShell 5.1 y una persona que la lance a mano.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "install.ps1"
README = ROOT / "README.md"
BUILD_DOCS = ROOT / "docs" / "build-bundle.md"

ENGINE_FRAGMENTS = (
    "bundle.sha256",
    "MensorCAD.bundle",
    "Expand-Archive",
    "Install-MensorCadBundle",
    "Uninstall-MensorCadBundle",
    "Get-MensorCadDestinationRoot",
    "Test-MensorCadSource",
    "__MENSORCAD_RELEASE_VERSION__",
)

GLOBAL_MUTATORS = (
    "Set-ExecutionPolicy",
    "Set-ItemProperty",
    "New-ItemProperty",
    "reg add",
    "-Verb RunAs",
    "$PROFILE",
    "Set-Location",
    "Start-Process",
)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def fin_de_linea_ps51_valido(raw: bytes) -> bool:
    """Acepta LF y CRLF; solo rechaza retornos de carro sueltos."""
    return b"\r" not in raw.replace(b"\r\n", b"")


class BootstrapStructureTests(unittest.TestCase):
    """Forma del wrapper; no sustituye a la suite de Windows."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = BOOTSTRAP.read_bytes() if BOOTSTRAP.is_file() else b""
        cls.bootstrap = cls.raw.decode("utf-8-sig")
        cls.readme = read_text(README)
        cls.build_docs = read_text(BUILD_DOCS)

    def test_bootstrap_existe_sin_bom_y_con_salto_de_linea_final(self) -> None:
        # El asset se entrega por HTTP y se ejecuta con [scriptblock]::Create: un
        # BOM UTF-8 no se reconoce ahi, llega como texto mojibake delante de
        # param y el arranque se rompe. Por eso el archivo es ASCII puro y no
        # lleva BOM; el instalador real conserva el suyo porque tiene Unicode.
        self.assertTrue(BOOTSTRAP.is_file(), f"falta {BOOTSTRAP}")
        self.assertEqual(BOOTSTRAP.name, "install.ps1", "el asset debe ser minusculo")
        self.assertFalse(self.raw.startswith(b"\xef\xbb\xbf"), "el bootstrap no debe llevar BOM")
        self.assertTrue(all(byte < 0x80 for byte in self.raw), "el bootstrap debe ser ASCII")
        self.assertTrue(fin_de_linea_ps51_valido(self.raw), "hay CR sueltos")
        self.assertTrue(self.raw.endswith(b"\n"), "falta el salto de linea final")

    def test_es_un_wrapper_sin_banderas_publicas_nuevas(self) -> None:
        self.assertIn("param(", self.bootstrap)
        self.assertIn("[string]$Version", self.bootstrap)
        self.assertIn("[switch]$NoAnimation", self.bootstrap)
        for prohibida in ("[switch]$FromRelease", "[switch]$Uninstall", "[switch]$ElevatedProcess"):
            self.assertNotIn(
                prohibida,
                self.bootstrap,
                f"el wrapper no debe aceptar {prohibida}: eso lo decide el instalador real",
            )

    def test_nunca_ejecuta_exit_en_el_llamador(self) -> None:
        self.assertIsNone(
            re.search(r"(?m)^\s*exit\b", self.bootstrap),
            "un exit en el ambito del llamador cerraria la sesion bajo iex",
        )
        self.assertNotIn("Stop-Process", self.bootstrap)
        self.assertIn("$global:LASTEXITCODE", self.bootstrap, "falta el contrato de salida")


    def test_la_primera_descarga_es_terminante(self) -> None:
        descarga = self.bootstrap[self.bootstrap.index("Invoke-WebRequest") :]
        self.assertIn("-UseBasicParsing", descarga)
        self.assertIn("-ErrorAction Stop", descarga)


    def test_no_duplica_el_motor_ni_la_version_del_producto(self) -> None:
        for fragmento in ENGINE_FRAGMENTS:
            self.assertNotIn(
                fragmento,
                self.bootstrap,
                f"el bootstrap no debe duplicar el motor ni la version: {fragmento}",
            )
        self.assertNotIn("Program Files", self.bootstrap)


    def test_requiere_windows_y_reporta_errores_en_stderr(self) -> None:
        self.assertIn("[PlatformID]::Win32NT", self.bootstrap)
        self.assertIn("[Console]::Error.WriteLine", self.bootstrap)
        self.assertIn("ERROR: ", self.bootstrap)


    def test_la_presencia_de_version_se_deriva_de_los_parametros_ligados(self) -> None:
        # Un [string] con default $null se coacciona a '': inferir la presencia
        # desde el valor tipado convierte la ultima version (sin -Version) en un
        # tag vacio invalido. La presencia solo puede venir de los parametros
        # realmente ligados en el ambito exterior.
        self.assertIn(
            "$PSBoundParameters.ContainsKey('Version')",
            self.bootstrap,
            "la presencia de -Version debe leerse de los parametros ligados",
        )
        self.assertNotIn(
            "[string]$Version = $null",
            self.bootstrap,
            "un default $null en [string] se coacciona a cadena vacia",
        )
        self.assertNotIn(
            "$null -ne $Version",
            self.bootstrap,
            "no se puede inferir la presencia desde el valor del parametro",
        )
        self.assertIn("[bool]$VersionSpecified", self.bootstrap)
        self.assertIn("$versionSpecified = $VersionSpecified", self.bootstrap)


if __name__ == "__main__":
    unittest.main()
