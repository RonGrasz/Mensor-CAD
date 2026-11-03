"""Contrato estructural del bootstrap que registra el gestor ``mensorcad``.

El bootstrap publicado (``install.ps1``) ya no instala el complemento: resuelve
un unico release oficial, valida el ZIP del gestor y lo registra en el PATH del
usuario. Estas pruebas leen texto y aplican expresiones regulares: NO ejecutan
PowerShell, NO descargan nada y NO demuestran que la instalacion funcione. La
ejecucion funcional vive en ``tests/Test-CliBootstrap.ps1`` y requiere Windows
PowerShell 5.1.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "install.ps1"
DOCS = ROOT / "docs" / "cli-bootstrap.md"
FUNCTIONAL = ROOT / "tests" / "Test-CliBootstrap.ps1"

LATEST_COMMAND = (
    "irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/"
    "install.ps1' -ea Stop | iex"
)
PINNED_COMMAND = (
    "&([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/"
    "download/v1.2.3/install.ps1' -ea Stop))) -Version v1.2.3"
)
NO_ANIMATION_COMMAND = PINNED_COMMAND + " -NoAnimation"

MANAGER_FILES = ("mensorcad.ps1", "mensorcad.cmd", "Install-MensorCAD.ps1")

# Nada de elevacion, PATH de maquina, politica de ejecucion global ni procesos
# hijos: este bootstrap solo escribe el gestor y el PATH del usuario actual.
FORBIDDEN_FRAGMENTS = (
    "HKLM",
    "HKEY_LOCAL_MACHINE",
    "HKEY_CURRENT_USER",
    "setx",
    "Set-ExecutionPolicy",
    "RunAs",
    "Program Files",
    "$PROFILE",
    "Set-ItemProperty",
    "New-ItemProperty",
    "Remove-ItemProperty",
    "Set-EnvironmentVariable",
    "Start-Process",
    "Stop-Process",
    "powershell.exe",
    "FromRelease",
    "Expand-Archive",
    "Install-MensorCadBundle",
    "Uninstall-MensorCadBundle",
    "bundle.sha256",
    "MensorCAD.bundle",
    "reg add",
    "reg.exe",
)

SIDECAR_PATTERN_FRAGMENT = r"^(?<hash>[0-9a-fA-F]{64})  MensorCAD-CLI\.zip\r?\n\z"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


class CliBootstrapStructureTests(unittest.TestCase):
    """Forma del bootstrap; no sustituye a la suite funcional de Windows."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = BOOTSTRAP.read_bytes() if BOOTSTRAP.is_file() else b""
        cls.bootstrap = (
            cls.raw.decode("ascii") if cls.raw and all(b < 0x80 for b in cls.raw) else cls.raw.decode("utf-8-sig")
        )
        cls.docs = read_text(DOCS) if DOCS.is_file() else ""
        cls.docs_flat = re.sub(r"\s+", " ", cls.docs)
        cls.functional = read_text(FUNCTIONAL) if FUNCTIONAL.is_file() else ""
        cls.lower = cls.bootstrap.lower()

    def test_el_asset_es_ascii_sin_bom_y_con_salto_final(self) -> None:
        # El archivo llega por HTTP y se ejecuta con [scriptblock]::Create: un
        # BOM UTF-8 se interpreta como texto basura delante de param y el
        # arranque falla con CommandNotFoundException. Por eso es ASCII puro.
        self.assertTrue(BOOTSTRAP.is_file(), f"falta {BOOTSTRAP}")
        self.assertFalse(self.raw.startswith(b"\xef\xbb\xbf"), "el bootstrap no debe llevar BOM")
        self.assertTrue(all(byte < 0x80 for byte in self.raw), "el bootstrap debe ser ASCII")
        self.assertTrue(b"\r" not in self.raw.replace(b"\r\n", b""), "hay CR sueltos")
        self.assertTrue(self.raw.endswith(b"\n"), "falta el salto de linea final")

    def test_conserva_las_banderas_publicas_documentadas(self) -> None:
        self.assertIn("param(", self.bootstrap)
        self.assertIn("[string]$Version", self.bootstrap)
        self.assertIn("[switch]$NoAnimation", self.bootstrap)
        self.assertIn("$PSBoundParameters.ContainsKey('Version')", self.bootstrap)
        public_params = self.bootstrap[: self.bootstrap.index("& {")]
        for prohibida in (
            "[switch]$FromRelease",
            "[switch]$Uninstall",
            "[switch]$ElevatedProcess",
            "[string]$Path",
            "[string]$Destination",
            "[string]$Repository",
        ):
            self.assertNotIn(prohibida, public_params, f"el bootstrap no debe aceptar {prohibida}")

    def test_no_cierra_la_sesion_del_llamador(self) -> None:
        self.assertIsNone(
            re.search(r"(?m)^\s*exit\b", self.bootstrap),
            "un exit en el ambito del llamador cerraria la sesion bajo iex",
        )
        self.assertIn("$global:LASTEXITCODE", self.bootstrap, "falta el contrato de salida")
        self.assertIsNone(
            re.search(r"(?m)^\s*\.\s+\$", self.bootstrap),
            "no se debe hacer dot-sourcing de nada descargado",
        )

    def test_resuelve_el_release_oficial_una_sola_vez(self) -> None:
        self.assertIn("'RonGrasz/Mensor-CAD'", self.bootstrap)
        self.assertIn("https://github.com", self.bootstrap)
        self.assertIn("https://api.github.com", self.bootstrap)
        self.assertIn("/releases/latest", self.bootstrap)
        self.assertIn("/releases/download/", self.bootstrap)
        self.assertEqual(
            self.bootstrap.count("/releases/latest"),
            1,
            "el release se resuelve una sola vez; no se debe volver a consultar",
        )
        self.assertNotIn(
            "latest/download",
            self.bootstrap,
            "el ZIP debe salir del tag fijado, no de /latest/download",
        )
        self.assertIn("Invoke-RestMethod", self.bootstrap)
        self.assertIn("Invoke-WebRequest", self.bootstrap)
        self.assertIn("-UseBasicParsing", self.bootstrap)
        self.assertIn("-ErrorAction Stop", self.bootstrap)

    def test_descarga_el_zip_del_gestor_y_su_sidecar(self) -> None:
        self.assertIn("'MensorCAD-CLI.zip'", self.bootstrap)
        self.assertIn("'MensorCAD-CLI.zip.sha256'", self.bootstrap)
        self.assertIn("-OutFile", self.bootstrap)

    def test_valida_el_sha256_y_las_entradas_exactas_del_zip(self) -> None:
        self.assertIn("Get-FileHash", self.bootstrap)
        self.assertIn("-Algorithm SHA256", self.bootstrap)
        self.assertIn(SIDECAR_PATTERN_FRAGMENT, self.bootstrap, "falta el formato estricto del sidecar")
        self.assertIn("ZipFile]::OpenRead", self.bootstrap)
        self.assertIn(
            "$managerFiles = @('mensorcad.ps1', 'mensorcad.cmd', 'Install-MensorCAD.ps1')",
            self.bootstrap,
            "el ZIP debe declarar exactamente los tres archivos del gestor",
        )
        for nombre in MANAGER_FILES:
            self.assertIn(nombre, self.bootstrap, f"falta {nombre}")
        self.assertIn("ReparsePoint", self.bootstrap, "faltan las comprobaciones de enlaces")
        for tope in ("$maxZipBytes", "$maxEntryBytes", "$maxTotalEntryBytes"):
            self.assertIn(tope, self.bootstrap, f"falta el tope {tope}")

    def test_no_ejecuta_ningun_script_descargado(self) -> None:
        self.assertNotIn("FromRelease", self.bootstrap)
        self.assertNotIn("Expand-Archive", self.bootstrap)
        self.assertNotIn("Start-Process", self.bootstrap)
        self.assertNotIn("powershell.exe", self.bootstrap)

    def test_instala_solo_el_gestor_en_la_carpeta_fija_del_usuario(self) -> None:
        self.assertIn("$env:LOCALAPPDATA", self.bootstrap)
        self.assertIn("'MensorCAD'", self.bootstrap)
        self.assertIn("'cli'", self.bootstrap)
        self.assertIn("'.mensorcad-cli.json'", self.bootstrap, "falta el marcador propio")
        self.assertIn("'cli.staging-'", self.bootstrap)
        self.assertIn("'cli.backup-'", self.bootstrap)
        self.assertIn("[guid]::NewGuid().ToString('N')", self.bootstrap)

    def test_registra_solo_el_path_del_usuario_preservando_el_tipo(self) -> None:
        self.assertIn("'HKCU:\\Environment'", self.bootstrap)
        self.assertIn("GetValueKind", self.bootstrap)
        self.assertIn("SetValue", self.bootstrap)
        self.assertIn("DoNotExpandEnvironmentNames", self.bootstrap)
        self.assertIn("RegistryValueKind", self.bootstrap)
        self.assertIn("$env:Path", self.bootstrap, "falta actualizar el PATH del proceso actual")

    def test_no_muta_configuracion_global_ni_pide_elevacion(self) -> None:
        for fragmento in FORBIDDEN_FRAGMENTS:
            self.assertNotIn(
                fragmento.lower(),
                self.lower,
                f"el bootstrap no debe usar {fragmento}",
            )

    def test_requiere_windows_y_reporta_errores_en_stderr(self) -> None:
        self.assertIn("[PlatformID]::Win32NT", self.bootstrap)
        self.assertIn("[Console]::Error.WriteLine", self.bootstrap)
        self.assertIn("ERROR: ", self.bootstrap)
        self.assertIn("No se instalo nada", self.bootstrap)
        self.assertIn("Se restauro la instalacion anterior", self.bootstrap)

    def test_valida_el_tag_antes_de_la_red_y_de_las_escrituras(self) -> None:
        patron = self.bootstrap.index("$releaseTagPattern = ")
        primera_red = self.bootstrap.index("Invoke-WebRequest")
        self.assertLess(patron, primera_red, "el tag debe validarse antes de descargar")
        self.assertIn("-notmatch", self.bootstrap)

    def test_tls12_se_fija_antes_de_la_primera_descarga(self) -> None:
        tls = self.bootstrap.index("SecurityProtocolType]::Tls12")
        primera_descarga = self.bootstrap.index("Save-CliBootstrapAsset -AssetName $cliAssetName")
        self.assertLess(tls, primera_descarga)
        self.assertIn("SecurityProtocol", self.bootstrap)

    def test_la_validacion_del_zip_precede_a_la_escritura_del_gestor(self) -> None:
        hash_pos = self.bootstrap.index("Get-FileHash")
        zip_pos = self.bootstrap.index("ZipFile]::OpenRead")
        staging_pos = self.bootstrap.index("New-CliBootstrapStagingDirectory")
        self.assertLess(hash_pos, staging_pos, "el hash debe validarse antes de preparar el destino")
        self.assertLess(zip_pos, staging_pos, "el ZIP debe validarse antes de preparar el destino")


class CliBootstrapDocsTests(unittest.TestCase):
    """La documentacion publica debe describir el flujo real de dos pasos."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.docs = read_text(DOCS) if DOCS.is_file() else ""
        cls.docs_flat = re.sub(r"\s+", " ", cls.docs)

    def test_existe_la_guia_del_bootstrap(self) -> None:
        self.assertTrue(DOCS.is_file(), f"falta {DOCS}")

    def test_documenta_los_comandos_publicados_exactos(self) -> None:
        for comando in (LATEST_COMMAND, PINNED_COMMAND, NO_ANIMATION_COMMAND):
            self.assertIn(comando, self.docs, f"falta el comando documentado: {comando}")

    def test_documenta_el_destino_y_el_flujo_de_dos_pasos(self) -> None:
        self.assertIn("%LOCALAPPDATA%\\MensorCAD\\cli", self.docs_flat)
        self.assertIn("mensorcad install", self.docs_flat)
        self.assertIn("---", self.docs, "la guia debe separar el paso 1 del paso 2")
        for fragmento in (".mensorcad-cli.json", "MensorCAD-CLI.zip", "MensorCAD-CLI.zip.sha256"):
            self.assertIn(fragmento, self.docs_flat)

    def test_documenta_parametros_y_contrato_de_salida(self) -> None:
        self.assertIn("-Version", self.docs_flat)
        self.assertIn("-NoAnimation", self.docs_flat)
        self.assertIn("LASTEXITCODE", self.docs_flat)
        self.assertIn("Windows PowerShell 5.1", self.docs_flat)
        self.assertIn("terminal nueva", self.docs_flat)

    def test_documenta_el_path_de_usuario_sin_tocar_el_de_maquina(self) -> None:
        self.assertIn("PATH", self.docs_flat)
        self.assertIn("REG_EXPAND_SZ", self.docs_flat)
        self.assertIn("REG_SZ", self.docs_flat)
        self.assertIn("PATH de maquina", self.docs_flat)
        self.assertIn("una sola vez", self.docs_flat)

    def test_no_promete_assets_publicados_ni_autenticacion_de_editor(self) -> None:
        self.assertTrue(
            re.search(r"no est\wn publicad|todavia no|todav\wa no", self.docs_flat, re.IGNORECASE),
            "la guia no debe afirmar que los assets ya estan publicados",
        )
        self.assertTrue(
            re.search(r"no autentica al publicador|no autentica el origen", self.docs_flat, re.IGNORECASE),
            "la guia debe aclarar que el SHA256 no autentica al publicador",
        )
        self.assertIn("se restaura la instalacion anterior", self.docs_flat.lower())

    def test_no_documenta_ejecutar_los_scripts_descargados(self) -> None:
        self.assertTrue(
            re.search(r"no se ejecuta", self.docs_flat, re.IGNORECASE),
            "la guia debe aclarar que los scripts descargados no se ejecutan",
        )


class CliBootstrapFunctionalHarnessTests(unittest.TestCase):
    """La suite funcional debe existir y aislarse de red y registro reales."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.functional = read_text(FUNCTIONAL) if FUNCTIONAL.is_file() else ""

    def test_existe_la_suite_funcional_de_windows(self) -> None:
        self.assertTrue(FUNCTIONAL.is_file(), f"falta {FUNCTIONAL}")

    def test_aisla_registro_red_y_carpetas_del_usuario(self) -> None:
        for fragmento in (
            "HKCU:\\Environment",
            "Invoke-RestMethod",
            "Invoke-WebRequest",
            "MCB_LOCALAPPDATA",
            "MCB_REGISTRY",
            "GetValueKind",
        ):
            self.assertIn(fragmento, self.functional, f"la suite funcional debe aislar {fragmento}")
        self.assertIn("PayloadSentinel", self.functional, "falta comprobar que el payload no se ejecuta")


if __name__ == "__main__":
    unittest.main()
