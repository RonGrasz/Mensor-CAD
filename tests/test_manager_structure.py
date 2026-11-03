"""Comprobaciones estructurales del comando gestor ``mensorcad``.

Estas pruebas leen texto y aplican expresiones regulares: NO ejecutan
PowerShell, NO descargan nada, NO piden UAC y NO escriben en el destino real del
complemento ni en el ``PATH``. La ejecucion funcional vive en
``tests/Test-Manager.ps1`` y corre con Windows PowerShell 5.1 usando motores y
rutas fixture dentro de ``odd/artifacts/persistent-cli/manager``.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANAGER = ROOT / "mensorcad.ps1"
LAUNCHER = ROOT / "mensorcad.cmd"
MANAGER_TESTS = ROOT / "tests" / "Test-Manager.ps1"
DOCS = ROOT / "docs" / "cli-manager.md"

PLACEHOLDER = "__MENSORCAD_MANAGER_VERSION__"


def read_text(path: Path) -> str:
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8-sig")


def read_bytes(path: Path) -> bytes:
    if not path.is_file():
        return b""
    return path.read_bytes()


class ManagerStructureTests(unittest.TestCase):
    """Forma del gestor; no sustituye a la suite funcional de Windows."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = read_bytes(MANAGER)
        cls.manager = cls.raw.decode("utf-8-sig") if cls.raw else ""
        cls.launcher_raw = read_bytes(LAUNCHER)
        cls.launcher = cls.launcher_raw.decode("ascii", errors="replace")
        cls.tests_raw = read_bytes(MANAGER_TESTS)
        cls.tests = read_text(MANAGER_TESTS)
        cls.docs = read_text(DOCS)

    # ------------------------------------------------------------------
    # Codificacion y sellado
    # ------------------------------------------------------------------

    def test_manager_existe_con_bom_utf8_y_sin_retornos_sueltos(self) -> None:
        self.assertTrue(MANAGER.is_file(), f"falta {MANAGER}")
        self.assertTrue(
            self.raw.startswith(b"\xef\xbb\xbf"),
            "mensorcad.ps1 debe llevar BOM UTF-8 para PowerShell 5.1",
        )
        self.assertTrue(self.raw.endswith(b"\n"), "falta el salto de linea final")
        self.assertNotIn(
            b"\r",
            self.raw.replace(b"\r\n", b""),
            "hay retornos de carro sueltos",
        )

    def test_version_del_gestor_es_un_unico_marcador(self) -> None:
        self.assertEqual(
            self.manager.count(PLACEHOLDER),
            1,
            "el marcador de version del gestor debe aparecer exactamente una vez",
        )
        self.assertIn(
            "$script:MensorCadManagerVersion = '__MENSORCAD_MANAGER_VERSION__'",
            self.manager,
            "falta el marcador de version del gestor",
        )
        self.assertNotIn(
            "__MENSORCAD_RELEASE_VERSION__",
            self.manager,
            "el gestor no debe apropiarse de la version del complemento",
        )
        self.assertIn(
            "'desarrollo'",
            self.manager,
            "sin sellar, la version debe mostrarse como desarrollo",
        )

    # ------------------------------------------------------------------
    # Entrada, guarda y superficie publica
    # ------------------------------------------------------------------

    def test_guarda_de_dot_source_y_un_solo_exit(self) -> None:
        self.assertIn(
            "$MyInvocation.InvocationName -eq '.'",
            self.manager,
            "falta la deteccion de dot-source",
        )
        self.assertIn(
            "if ($script:MensorCadManagerDotSourced) { return }",
            self.manager,
            "cargar el archivo para pruebas no debe ejecutar la CLI",
        )
        exits = re.findall(r"(?m)^\s*exit\b", self.manager)
        self.assertEqual(
            len(exits),
            1,
            "debe existir un unico exit de nivel superior",
        )
        self.assertIn("exit $managerExitCode", self.manager)

    def test_acepta_argv_crudo_y_rechaza_antes_del_motor(self) -> None:
        self.assertIn(
            "Get-MensorCadManagerCommand -Arguments $args",
            self.manager,
            "la entrada debe tomar el argv crudo sin motor de parametros que falle antes",
        )
        for fragmento in (
            "'install'",
            "'-i'",
            "'update'",
            "'uninstall'",
            "'status'",
            "'--help'",
            "'--version'",
            "Argumentos adicionales no admitidos",
            "Comando no reconocido",
            "no reconocida",
            "'unistall' = 'uninstall'",
            "No se modificó nada",
        ):
            self.assertIn(fragmento, self.manager, f"falta el contrato de despacho: {fragmento}")
        self.assertLess(
            self.manager.index("$managerCommand.Error"),
            self.manager.index(". $enginePath"),
            "la entrada invalida debe rechazarse antes de cargar el motor",
        )

    def test_ayuda_y_version_no_cargan_el_motor(self) -> None:
        self.assertIn(
            "$engineRoutes = @('summary', 'status', 'install', 'update', 'uninstall')",
            self.manager,
            "las rutas que usan el motor deben estar enumeradas",
        )
        self.assertIn("if ($engineRoutes -contains $managerCommand.Name)", self.manager)
        self.assertNotIn(
            "'help'",
            self.manager.split("$engineRoutes = @(", 1)[1].split(")", 1)[0],
            "help no puede depender del motor",
        )
        self.assertNotIn(
            "'version'",
            self.manager.split("$engineRoutes = @(", 1)[1].split(")", 1)[0],
            "version no puede depender del motor",
        )
        self.assertIn(". $enginePath", self.manager, "el motor adyacente debe cargarse con dot-source")

    def test_prohibe_red_elevacion_y_escrituras_propias(self) -> None:
        prohibidos = (
            "Invoke-WebRequest",
            "Invoke-RestMethod",
            "DownloadString",
            "Expand-Archive",
            "Start-Process",
            "RunAs",
            "Set-ExecutionPolicy",
            "Set-ItemProperty",
            "New-ItemProperty",
            "SetEnvironmentVariable",
            "New-Item",
            "Set-Content",
            "Add-Content",
            "Out-File",
            "Remove-Item",
            "Get-FileHash",
            "ConvertFrom-Json",
            "Uninstall-MensorCadBundle",
            "Install-MensorCadBundle",
            "Tls12",
            "WindowsPrincipal",
            "$PROFILE",
            "Program Files",
            "ApplicationPlugins",
            "$env:",
            "MCM_",
        )
        for fragmento in prohibidos:
            self.assertNotIn(
                fragmento,
                self.manager,
                f"el gestor no debe incluir {fragmento}: la red, la elevacion y la"
                " mutacion pertenecen al motor",
            )

    # ------------------------------------------------------------------
    # Reutilizacion del motor y lectura de estado
    # ------------------------------------------------------------------

    def test_reutiliza_el_motor_en_lugar_de_duplicarlo(self) -> None:
        for fragmento in (
            "Install-MensorCAD.ps1",
            "Resolve-MensorCadReleaseTag",
            "-FromRelease -Version $tag",
            "& $protectedEnginePath -Uninstall",
            "Get-MensorCadDestinationRoot",
            "Assert-MensorCadOwnedDestination",
            "Test-MensorCadReparsePoint",
            "Get-MensorCadDisplayVersion",
        ):
            self.assertIn(fragmento, self.manager, f"falta la reutilizacion: {fragmento}")
        self.assertIn(
            "Join-Path -Path $state.DestinationRoot -ChildPath $script:MensorCadManagerEngineFileName",
            self.manager,
            "la desinstalacion debe apuntar al motor protegido del complemento",
        )

    def test_status_lee_la_version_del_manifiesto_no_de_la_marca(self) -> None:
        for fragmento in ("PackageContents.xml", "AppVersion", "GetAttribute"):
            self.assertIn(fragmento, self.manager, f"falta la lectura de version: {fragmento}")
        self.assertNotIn(
            "sourceManifestSha256",
            self.manager,
            "la marca no tiene version y no debe reparsearse aqui",
        )

    def test_mensajes_contractuales(self) -> None:
        for fragmento in (
            "Ya estás actualizado",
            "No se baja de versión",
            "No se pudo comparar la versión instalada",
            'mensorcad install',
            "Desinstalar.bat",
            "ZIP",
            "El gestor no descarga nada por su cuenta",
            "punto de reanálisis",
        ):
            self.assertIn(fragmento, self.manager, f"falta el mensaje: {fragmento}")
        self.assertIn("$script:MensorCadManagerExitFailure = 1", self.manager)
        self.assertIn("$script:MensorCadManagerExitUsage = 2", self.manager)

    # ------------------------------------------------------------------
    # Lanzador CMD
    # ------------------------------------------------------------------

    def test_lanzador_cmd_es_ascii_crlf_y_propaga_el_codigo(self) -> None:
        self.assertTrue(LAUNCHER.is_file(), f"falta {LAUNCHER}")
        self.assertFalse(
            self.launcher_raw.startswith(b"\xef\xbb\xbf"),
            "un .cmd no debe llevar BOM",
        )
        self.assertTrue(
            all(byte < 0x80 for byte in self.launcher_raw),
            "el lanzador debe ser ASCII puro",
        )
        self.assertEqual(
            self.launcher_raw.count(b"\n"),
            self.launcher_raw.count(b"\r\n"),
            "el lanzador debe usar CRLF en todas sus lineas",
        )
        self.assertTrue(self.launcher_raw.endswith(b"\r\n"), "falta el CRLF final")
        for fragmento in (
            "@echo off",
            "%~dp0mensorcad.ps1",
            "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy Bypass",
            "-File",
            "%*",
            "exit /b %ERRORLEVEL%",
        ):
            self.assertIn(fragmento, self.launcher, f"falta en el lanzador: {fragmento}")
        for prohibido in ("pause", "setx ", "reg add"):
            self.assertNotIn(prohibido, self.launcher, f"el lanzador no debe incluir {prohibido}")

    # ------------------------------------------------------------------
    # Documentacion y suite funcional
    # ------------------------------------------------------------------

    def test_documentacion_cubre_comandos_limites_y_fronteras(self) -> None:
        self.assertTrue(DOCS.is_file(), f"falta {DOCS}")
        self.assertGreater(len(self.docs), 1500, "la documentacion es demasiado corta")
        for fragmento in (
            "mensorcad install",
            "mensorcad -i",
            "mensorcad update",
            "mensorcad uninstall",
            "mensorcad status",
            "mensorcad --help",
            "mensorcad --version",
            "Ya estás actualizado",
            "ZIP",
            "Desinstalar.bat",
            "SHA-256",
            "no autentica",
            "por usuario",
            "por equipo",
            "UAC",
            "sin conexión",
            "%LOCALAPPDATA%\\MensorCAD\\cli",
            "ApplicationPlugins\\MensorCAD.bundle",
            "segunda etapa",
            "afirma que los assets",
            "Limitaciones",
        ):
            self.assertIn(fragmento, self.docs, f"falta en la documentacion: {fragmento}")

    def test_suite_funcional_aislada_y_sin_red_ni_uac(self) -> None:
        self.assertTrue(MANAGER_TESTS.is_file(), f"falta {MANAGER_TESTS}")
        self.assertTrue(
            self.tests_raw.startswith(b"\xef\xbb\xbf"),
            "Test-Manager.ps1 debe llevar BOM UTF-8 para PowerShell 5.1",
        )
        for fragmento in (
            "odd\\artifacts\\persistent-cli\\manager",
            "MCM_EVIDENCE",
            "Install-MensorCAD.ps1",
            "PROTECTED-ENGINE-STDOUT",
            "Ya estás actualizado",
            "cmd.exe",
        ):
            self.assertIn(fragmento, self.tests, f"falta en la suite: {fragmento}")
        for prohibido in (
            "-Verb RunAs",
            "Invoke-WebRequest",
            "Invoke-RestMethod",
            "DownloadString",
            "github.com",
            "[Environment]::SetEnvironmentVariable",
            "GetTempPath",
        ):
            self.assertNotIn(
                prohibido,
                self.tests,
                f"la suite no debe incluir {prohibido}: no toca red, UAC ni TEMP del sistema",
            )


if __name__ == "__main__":
    unittest.main()
