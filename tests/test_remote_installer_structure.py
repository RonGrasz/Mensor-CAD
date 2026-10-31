"""Comprobaciones estructurales de la entrada remota de MensorCAD.

Estas pruebas NO validan comportamiento funcional ni descargan nada. Verifican
que la entrada remota existe, reutiliza el motor local, mantiene el destino
fijo, no acepta rutas ni URLs arbitrarias y que la verificacion del SHA-256 y
la inspeccion del ZIP ocurren antes de extraer.

La validacion funcional real vive en tests/Test-RemoteInstaller.ps1 y requiere
Windows PowerShell 5.1. Estas comprobaciones nunca cuentan como prueba funcional.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "Install-MensorCAD.ps1"
REMOTE_TESTS = ROOT / "tests" / "Test-RemoteInstaller.ps1"
REMOTE_DOCS = ROOT / "docs" / "remote-installer.md"
LOCAL_DOCS = ROOT / "docs" / "local-installer.md"

REMOTE_MARKER = "# Entrada remota: descarga y verificacion de releases de GitHub"

DOWNLOAD_VERBS = (
    "Invoke-WebRequest",
    "Start-BitsTransfer",
    "Net.WebClient",
    "DownloadFile",
    "DownloadString",
    "Expand-Archive",
    "curl ",
    "wget ",
)

GLOBAL_MUTATORS = (
    "Set-ExecutionPolicy",
    "Set-MpPreference",
    "SECURELOAD",
    "TRUSTEDPATHS",
    "APPAUTOLOAD",
    "Set-ItemProperty",
    "New-ItemProperty",
    "reg add",
)

REMOTE_FUNCTIONS = (
    "Get-MensorCadRemoteTempRoot",
    "Get-MensorCadRemoteText",
    "Save-MensorCadRemoteFile",
    "Resolve-MensorCadReleaseTag",
    "Assert-MensorCadReleaseTag",
    "Get-MensorCadReleaseAssetUri",
    "Read-MensorCadReleaseChecksum",
    "Assert-MensorCadReleaseArchiveHash",
    "Assert-MensorCadArchiveEntryName",
    "Get-MensorCadReleaseArchiveEntries",
    "Expand-MensorCadReleaseArchive",
    "Invoke-MensorCadRemoteChild",
    "Write-MensorCadRelayedOutput",
    "Invoke-MensorCadRemoteInstall",
    "Get-MensorCadArgumentError",
)

FROZEN_ZIP_ROOTS = (
    "MensorCAD.bundle/PackageContents.xml",
    "MensorCAD.bundle/Contents/UI/MensorCAD.cuix",
    "Install-MensorCAD.ps1",
    "Instalar.bat",
    "LICENSE",
    "bundle.sha256",
)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def function_body(text: str, name: str) -> str:
    start = text.index("function " + name)
    following = text.find("\nfunction ", start + 1)
    if following == -1:
        return text[start:]
    return text[start:following]


def fin_de_linea_ps51_valido(raw: bytes) -> bool:
    """Acepta LF y CRLF; solo rechaza retornos de carro sueltos.

    Un checkout Windows (core.autocrlf=true) entrega los .ps1 con CRLF, y
    Windows PowerShell 5.1 acepta ambos fines de linea. Exigir LF forzaria a
    normalizar el arbol de trabajo en Windows, que no es responsabilidad de la
    prueba: alcanza con que no haya CR sin LF.
    """
    return b"\r" not in raw.replace(b"\r\n", b"")


class RemoteInstallerStructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.installer = read_text(INSTALLER)
        marker = cls.installer.index(REMOTE_MARKER)
        local_end = cls.installer.index("function Invoke-MensorCadElevatedSelf")
        cls.local_branch = cls.installer[:marker]
        cls.remote_branch = cls.installer[marker:local_end]
        cls.cli_branch = cls.installer[local_end:]
        cls.remote_tests = read_text(REMOTE_TESTS)
        cls.remote_docs = read_text(REMOTE_DOCS)
        cls.local_docs = read_text(LOCAL_DOCS)
        cls.top_param_block = cls._top_param_block(cls.installer)

    @staticmethod
    def _top_param_block(text: str) -> str:
        start = text.index("param(")
        end = text.index("\n)", start)
        return text[start : end + 2]

    def test_remote_files_exist(self) -> None:
        for path in (INSTALLER, REMOTE_TESTS, REMOTE_DOCS, LOCAL_DOCS):
            self.assertTrue(path.is_file(), f"falta {path}")

    def test_public_interface_adds_only_fromrelease_and_version(self) -> None:
        block = self.top_param_block
        self.assertIn("[switch]$FromRelease", block)
        self.assertIn("[string]$Version", block)
        declared = set(re.findall(r"\$(\w+)", block))
        self.assertEqual(
            declared,
            {"Uninstall", "NoAnimation", "Help", "Version", "FromRelease", "ElevatedProcess"},
            "la entrada remota no debe abrir parametros nuevos fuera de -FromRelease y -Version",
        )
        for forbidden in ("$Destination", "$SourceRoot", "$Url", "$Uri", "$Path", "$Repository", "$Token"):
            self.assertNotIn(forbidden, block, f"no debe existir un parametro publico {forbidden}")

    def test_remote_section_has_a_stable_marker_and_follows_the_local_engine(self) -> None:
        self.assertTrue(self.remote_branch.strip(), "falta la seccion remota marcada")
        for required in ("function Install-MensorCadBundle", "function Uninstall-MensorCadBundle"):
            self.assertIn(required, self.local_branch, "la seccion remota debe ir despues del motor local")
        self.assertLess(self.installer.index(REMOTE_MARKER), self.installer.index("function Invoke-MensorCadCli"))

    def test_local_branch_stays_offline(self) -> None:
        for forbidden in DOWNLOAD_VERBS:
            self.assertNotIn(forbidden, self.local_branch, f"la rama local no debe descargar nada: {forbidden}")
            self.assertNotIn(forbidden, self.cli_branch, f"la CLI local no debe descargar nada: {forbidden}")
        self.assertNotIn("Get-MensorCadRemote", self.local_branch, "la rama local no debe invocar la entrada remota")

    def test_remote_branch_owns_the_only_download_code(self) -> None:
        self.assertIn("Invoke-WebRequest", self.remote_branch)
        for name in REMOTE_FUNCTIONS:
            self.assertIn(f"function {name}", self.remote_branch, f"falta la funcion remota {name}")

    def test_release_source_is_fixed_and_not_user_supplied(self) -> None:
        self.assertIn("$script:MensorCadReleaseRepository = 'RonGrasz/Mensor-CAD'", self.remote_branch)
        self.assertIn("$script:MensorCadReleaseZipAssetName = 'MensorCAD-Windows.zip'", self.remote_branch)
        self.assertIn(
            "$script:MensorCadReleaseChecksumAssetName = 'MensorCAD-Windows.zip.sha256'",
            self.remote_branch,
        )
        hosts = set(re.findall(r"https?://([A-Za-z0-9.-]+)", self.remote_branch))
        self.assertEqual(hosts, {"github.com", "api.github.com"}, "la fuente remota debe ser GitHub y nada mas")
        self.assertNotIn("$script:MensorCadReleaseRepository = $", self.remote_branch)
        self.assertNotIn("releases/download/' + $Version", self.remote_branch)

    def test_latest_release_is_resolved_once_to_a_concrete_tag(self) -> None:
        resolver = function_body(self.remote_branch, "Resolve-MensorCadReleaseTag")
        self.assertIn("releases/latest", resolver)
        self.assertIn("Get-MensorCadRemoteText", resolver)
        self.assertIn("tag_name", resolver)
        self.assertIn("Assert-MensorCadReleaseTag", resolver)
        self.assertLessEqual(resolver.count("Get-MensorCadRemoteText"), 1, "la API se consulta una sola vez")
        self.assertIn("MensorCadReleaseChecksumAssetName", resolver, "la release debe publicar el sidecar esperado")
        asset_uri = function_body(self.remote_branch, "Get-MensorCadReleaseAssetUri")
        self.assertIn("releases/download/", asset_uri)
        self.assertIn("$Tag", asset_uri)

    def test_checksum_is_verified_before_any_extraction(self) -> None:
        install = function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall")
        order = [
            "Save-MensorCadRemoteFile",
            "Assert-MensorCadReleaseArchiveHash",
            "Get-MensorCadReleaseArchiveEntries",
            "Expand-MensorCadReleaseArchive",
            "Test-MensorCadSource",
            "Invoke-MensorCadRemoteChild",
        ]
        positions = [install.index(token) for token in order]
        self.assertEqual(positions, sorted(positions), "el orden descarga -> hash -> ZIP -> extraccion -> motor debe respetarse")
        checksum = function_body(self.remote_branch, "Read-MensorCadReleaseChecksum")
        self.assertIn("Get-MensorCadFileHash", function_body(self.remote_branch, "Assert-MensorCadReleaseArchiveHash"))
        self.assertIn("no coincide", function_body(self.remote_branch, "Assert-MensorCadReleaseArchiveHash"))
        self.assertIn("MensorCadReleaseZipAssetName", checksum)

    def test_unsafe_zip_entries_are_rejected_before_extraction(self) -> None:
        validator = function_body(self.remote_branch, "Get-MensorCadReleaseArchiveEntries")
        self.assertNotIn("ExtractToFile", validator, "la validacion del ZIP no debe extraer nada")
        self.assertIn("0xA000", self.remote_branch, "debe rechazar enlaces del ZIP")
        self.assertIn("enlace", self.remote_branch)
        self.assertIn("duplicada", validator)
        self.assertIn("reservado", self.remote_branch)
        self.assertIn("flujo alternativo", self.remote_branch)
        self.assertIn("unidad de disco", self.remote_branch)
        self.assertIn("ruta absoluta", self.remote_branch)
        self.assertIn("'..'", self.remote_branch)
        self.assertIn("UNC", self.remote_branch)
        for root in FROZEN_ZIP_ROOTS:
            self.assertIn(root, self.remote_branch, f"la lista congelada del ZIP debe incluir {root}")
        self.assertIn(r"Contents/Lisp/[^/]+\.lsp", self.remote_branch)
        self.assertIn("fuera del paquete distribuido", self.remote_branch)

    def test_extraction_stays_inside_the_owned_workspace(self) -> None:
        extraction = function_body(self.remote_branch, "Expand-MensorCadReleaseArchive")
        self.assertIn("GetFullPath", extraction)
        self.assertIn("StartsWith", extraction)
        self.assertIn("Get-MensorCadDirectoryTree", self.remote_branch)
        self.assertIn("Remove-MensorCadTree", function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall"))

    def test_remote_entry_reuses_the_local_engine_instead_of_duplicating_it(self) -> None:
        install = function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall")
        for reused in (
            "Get-MensorCadProgramFilesRoot",
            "Get-MensorCadDestinationRoot",
            "Test-MensorCadSource",
            "Assert-MensorCadNoReparseInPath",
        ):
            self.assertIn(reused, install, f"la entrada remota debe reutilizar {reused}")
        self.assertNotIn("ApplicationPlugins", self.remote_branch, "el destino fijo lo resuelve el motor local")
        self.assertNotIn("Install-MensorCadBundle", self.remote_branch, "la instalacion la ejecuta el script extraido")
        self.assertNotIn("Uninstall-MensorCadBundle", self.remote_branch)

    def test_elevation_and_recursion_are_not_bypassed(self) -> None:
        self.assertNotIn("-Verb RunAs", self.remote_branch, "la elevacion sigue en Invoke-MensorCadElevatedSelf")
        install = function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall")
        self.assertNotIn("FromRelease", install, "el hijo extraido no debe recibir -FromRelease")
        self.assertNotIn("FromRelease", function_body(self.remote_branch, "Invoke-MensorCadRemoteChild"))
        child = function_body(self.remote_branch, "Invoke-MensorCadRemoteChild")
        self.assertIn("ExecutionPolicy Bypass", child)
        self.assertIn("-File", child)
        self.assertIn("ExitCode", child)
        self.assertIn("Write-MensorCadRelayedOutput", function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall"))

    def test_cli_dispatches_remote_only_for_fromrelease(self) -> None:
        cli = self.installer[self.installer.index("function Invoke-MensorCadCli") :]
        self.assertIn("if ($FromRelease)", cli)
        dispatch = cli[cli.index("if ($FromRelease)") :]
        self.assertIn("Invoke-MensorCadRemoteInstall", dispatch)
        self.assertIn("Get-MensorCadArgumentError", cli)
        self.assertLess(
            cli.index("Get-MensorCadArgumentError"),
            cli.index("if (-not (Test-MensorCadWindows))"),
            "las combinaciones invalidas deben fallar antes de tocar la plataforma o la red",
        )
        self.assertLess(cli.index("Assert-MensorCad64BitHost"), cli.index("if ($FromRelease)"))
        self.assertIn("function Get-MensorCadArgumentError", self.remote_branch)
        argument_error = function_body(self.remote_branch, "Get-MensorCadArgumentError")
        for fragment in ("-FromRelease y -Uninstall", "-Version solo es valida junto con -FromRelease", "requiere un valor"):
            self.assertIn(fragment, argument_error)

    def test_no_global_configuration_changes_in_the_remote_branch(self) -> None:
        for forbidden in GLOBAL_MUTATORS:
            self.assertNotIn(forbidden, self.remote_branch)
        self.assertIn("ServicePointManager", self.remote_branch, "solo se ajusta TLS del proceso actual")
        self.assertNotIn("ServicePointManager", self.local_branch, "la rama local no debe tocar TLS")
        self.assertIn("Tls12", self.remote_branch)
        for forbidden in ("Install-Module", "Install-Package", "NuGet", "Import-Module"):
            self.assertNotIn(forbidden, self.installer, f"sin dependencias nuevas: {forbidden}")

    def test_help_documents_the_remote_entry_and_pending_release(self) -> None:
        usage = function_body(self.installer, "Write-MensorCadUsage")
        self.assertIn("-FromRelease", usage)
        self.assertIn("-Version", usage)
        self.assertIn("release publicado", usage)
        self.assertNotIn("FromRelease", self.top_param_block.replace("[switch]$FromRelease", ""), "no se permiten alias extra")

    def test_remote_documentation_covers_command_trust_and_limits(self) -> None:
        docs = self.remote_docs
        for fragment in (
            "-FromRelease",
            "-Version",
            "RonGrasz/Mensor-CAD",
            "MensorCAD-Windows.zip",
            "MensorCAD-Windows.zip.sha256",
            "no disponible",
            "publicar",
            "offline",
            "SHA-256",
            "no autentica",
            "PowerShell 5.1",
            "Test-RemoteInstaller.ps1",
            "UAC",
            "Program Files",
            "-Uninstall",
            "en memoria",
            "instalación",
        ):
            self.assertIn(fragment, docs, f"la documentacion remota no menciona {fragment}")
        one_line = [line for line in docs.splitlines() if line.strip().startswith("powershell.exe")]
        self.assertTrue(one_line, "debe existir el comando de una linea")
        self.assertIn("Install-MensorCAD.ps1", "\n".join(one_line))
        self.assertIn("-FromRelease", "\n".join(one_line))

    def test_local_documentation_points_to_the_remote_unit(self) -> None:
        self.assertIn("FromRelease", self.local_docs)
        self.assertIn("remote-installer.md", self.local_docs)
        self.assertNotIn("se integra en una unidad posterior", self.local_docs)
        self.assertIn("no descarga", self.local_docs)

    def test_remote_windows_tests_are_executable_and_isolated(self) -> None:
        text = self.remote_tests
        for scenario in (
            "release mas reciente",
            "version explicita",
            "SHA-256 incorrecto",
            "salto de directorio",
            "duplicad",
            "enlace",
            "flujo alternativo",
            "nombre reservado",
            "Argumentos invalidos",
            "opciones locales",
            "codigo de salida del hijo",
            "espera activa",
            "sin animacion",
            "estado elevado",
        ):
            self.assertIn(scenario, text, f"faltan pruebas remotas para: {scenario}")
        for seam in (
            "function script:Get-MensorCadRemoteText",
            "function script:Save-MensorCadRemoteFile",
            "function script:Invoke-MensorCadRemoteChild",
            "function script:Get-MensorCadRemoteTempRoot",
            "function script:Write-MensorCadRelayedOutput",
            "function script:Write-MensorCadFailure",
        ):
            self.assertIn(seam, text, f"la prueba remota debe simular la costura: {seam}")
        self.assertIn("GetTempPath", text)
        self.assertIn(". $script:InstallerPath", text)
        self.assertNotIn("C:\\Program Files", text)
        self.assertNotIn("-Verb RunAs", text)
        self.assertIn("exit 2", text, "las pruebas deben omitirse fuera de Windows")

    def test_new_tests_do_not_read_git_history_or_live_network(self) -> None:
        for path, text in (
            (REMOTE_TESTS, self.remote_tests),
            (Path(__file__), Path(__file__).read_text(encoding="utf-8")),
        ):
            self.assertIsNone(re.search(r"\bgit\s+(log|show|diff|rev-parse)", text), f"{path.name} no debe leer historial")
        self.assertNotIn("api.github.com/repos/RonGrasz", self.remote_tests.split("function script:Get-MensorCadRemoteText")[0])
        self.assertIn("RonGrasz/Mensor-CAD", self.remote_tests)

    def test_remote_windows_test_file_is_ps51_ready(self) -> None:
        raw = REMOTE_TESTS.read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), "el archivo debe ser UTF-8 con BOM")
        texto = raw.decode("utf-8-sig")
        self.assertIn(
            "$ErrorActionPreference",
            texto,
            "el contenido debe seguir siendo UTF-8 legible por PowerShell 5.1",
        )
        self.assertTrue(
            fin_de_linea_ps51_valido(raw),
            "el archivo solo puede usar fin de linea LF o CRLF, sin CR sueltos",
        )
        self.assertTrue(raw.endswith(b"\n"), "el archivo debe terminar con un salto de linea")

    def test_remote_windows_test_file_acepta_lf_y_crlf(self) -> None:
        # El checkout de Windows llega con BOM y CRLF: ambas formas son validas
        # y la comprobacion no debe alterar el contenido de la prueba.
        bom = b"\xef\xbb\xbf"
        contenido = "param([switch]$PlainMode)\nWrite-Host 'prueba remota'\nexit 2\n"
        lf = bom + contenido.encode("utf-8")
        crlf = bom + contenido.replace("\n", "\r\n").encode("utf-8")
        for muestra in (lf, crlf):
            self.assertTrue(muestra.startswith(bom), "el BOM UTF-8 debe conservarse")
            self.assertTrue(
                fin_de_linea_ps51_valido(muestra),
                "fin de linea rechazado: {!r}".format(muestra),
            )
            self.assertTrue(muestra.endswith(b"\n"), "debe terminar con salto de linea")
            self.assertEqual(
                muestra.decode("utf-8-sig").replace("\r\n", "\n"),
                contenido,
                "aceptar CRLF no debe alterar el contenido de la prueba",
            )
        self.assertNotIn(b"\r", lf, "la variante LF no debe introducir CR")
        self.assertFalse(
            fin_de_linea_ps51_valido(bom + b"param()\rWrite-Host 'prueba'\n"),
            "un CR suelto no es un fin de linea valido",
        )

    def test_active_wait_reuses_the_existing_renderer(self) -> None:
        self.assertIn("function Write-MensorCadActivity", self.local_branch, "el renderizador debe ser el local")
        wait_function = function_body(self.remote_branch, "Wait-MensorCadRemoteChild")
        for fragment in (
            "while (-not $Process.HasExited)",
            "Write-MensorCadActivity",
            "$Process.WaitForExit($IntervalMilliseconds)",
            "$Process.WaitForExit()",
            "Complete-MensorCadActivity",
            "$script:MensorCadPlainMode",
            "Write-MensorCadInfo",
        ):
            self.assertIn(fragment, wait_function, f"la espera activa debe incluir {fragment}")
        self.assertNotIn("Start-Sleep", self.installer, "la espera no debe simularse con demoras")
        self.assertLess(
            wait_function.index("while (-not $Process.HasExited)"),
            wait_function.index("$Process.WaitForExit($IntervalMilliseconds)"),
            "la espera con timeout solo ocurre mientras el proceso real sigue vivo",
        )
        self.assertLess(
            wait_function.index("$Process.WaitForExit($IntervalMilliseconds)"),
            wait_function.index("$Process.WaitForExit()"),
            "no debe haber esperas despues de que el hijo termina",
        )
        install = function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall")
        self.assertNotIn("Start-Sleep", install, "la instalacion remota no debe simular demoras")
        self.assertIn("Write-MensorCadRelayedOutput", install, "la salida capturada del hijo debe reenviarse despues")
        self.assertNotIn("Write-Output", wait_function, "la espera no debe emitir objetos a la tuberia")
        self.assertNotIn(
            "Write-Output",
            function_body(self.remote_branch, "Invoke-MensorCadRemoteChild"),
            "el hijo no debe duplicar objetos en la tuberia",
        )

    def test_active_wait_regression_observes_a_real_process(self) -> None:
        text = self.remote_tests
        for fragment in (
            "Start-Transcript",
            "wait-probe.transcript.txt",
            "PROBE-FIN exited=True",
            "RunningFrames",
            "elapsed=",
            "Wait-MensorCadRemoteChild",
            "Invoke-MensorCadRemoteChild",
        ):
            self.assertIn(fragment, text, f"la regresion de espera activa debe observar: {fragment}")
        self.assertIn("Start-Process", text, "la espera se mide contra un proceso real, no contra una cadena")
        self.assertNotIn("formato esperado de la animacion", text)

    def test_child_runs_with_active_wait_before_captured_output_is_read(self) -> None:
        child = function_body(self.remote_branch, "Invoke-MensorCadRemoteChild")
        self.assertNotIn("-Wait ", child, "el hijo no debe bloquear con -Wait sin pintar actividad")
        self.assertIn("Wait-MensorCadRemoteChild", child)
        self.assertLess(
            child.index("Start-Process"),
            child.index("Wait-MensorCadRemoteChild"),
            "la espera activa debe empezar cuando el proceso real ya existe",
        )
        self.assertLess(
            child.index("Wait-MensorCadRemoteChild"),
            child.index("ReadAllText"),
            "la salida capturada se lee solo despues de que el hijo termina",
        )
        self.assertIn("$script:MensorCadRemoteChildActivityMessage", child)
        self.assertIn("$script:MensorCadRemoteChildActivityMessage", function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall"))

    def test_uac_diagnostics_claims_are_truthful(self) -> None:
        docs = self.remote_docs
        for fragment in (
            "ventana propia",
            "no se captura",
            "estado de salida final",
            "UAC",
        ):
            self.assertIn(fragment, docs, f"la documentacion debe describir con precision: {fragment}")
        self.assertIn("ventana de diagnostico", self.remote_branch)
        self.assertNotIn("salida elevada se reenvia", docs)

    def test_download_redirections_are_documented_and_not_gated(self) -> None:
        docs = self.remote_docs
        for fragment in ("CDN", "objects.githubusercontent.com", "github-releases.githubusercontent.com", "redirig"):
            self.assertIn(fragment, docs, f"la documentacion debe explicar las redirecciones: {fragment}")
        self.assertNotIn("Solo `github.com` y `api.github.com`", docs, "GitHub redirige las descargas a su CDN")
        for forbidden in ("ResponseUri", "BaseResponse", "github-releases.githubusercontent.com"):
            self.assertNotIn(forbidden, self.remote_branch, f"no se debe imponer un control de host final: {forbidden}")
        self.assertIn("$script:MensorCadReleaseHost = 'https://github.com'", self.remote_branch)
        self.assertIn("$script:MensorCadReleaseApiHost = 'https://api.github.com'", self.remote_branch)

    def test_workspace_cleanup_is_attempted_not_guaranteed(self) -> None:
        install = function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall")
        self.assertIn("Remove-MensorCadTree", install)
        self.assertIn("Aviso: no se pudo limpiar la carpeta temporal", install)
        self.assertIn("se conserva en disco", install)
        docs = self.remote_docs
        self.assertIn("se intenta eliminar", docs)
        self.assertIn("aviso", docs)
        self.assertNotIn("se elimina siempre", docs)
        self.assertNotIn("se limpia siempre", docs)
        self.assertIn("no se garantiza", docs)


if __name__ == "__main__":
    unittest.main()
