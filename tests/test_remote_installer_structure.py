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
from pathlib import Path, PureWindowsPath

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "Install-MensorCAD.ps1"
REMOTE_TESTS = ROOT / "tests" / "Test-RemoteInstaller.ps1"
REMOTE_DOCS = ROOT / "docs" / "remote-installer.md"
LOCAL_DOCS = ROOT / "docs" / "local-installer.md"

REMOTE_MARKER = "# Entrada remota: descarga y verificacion de releases de GitHub"

# URL publica del bootstrap: la ultima version usa el alias latest y una version
# fijada usa la ruta del tag. Ambas se documentan como comandos de una linea.
LATEST_BOOTSTRAP = "releases/latest/download/Install-MensorCAD.ps1"
PINNED_BOOTSTRAP = re.compile(r"/releases/download/v\d+\.\d+\.\d+/Install-MensorCAD\.ps1")

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

    def test_fixture_staging_paths_fit_classic_windows_limits(self) -> None:
        # Presupuesto de los fixtures: no ejecuta File.Copy ni accede a Windows.
        # Deriva los nombres reales y exige conservar los GUID completos.
        def guid_component(text: str, variable: str) -> str:
            pattern = (
                re.escape(variable)
                + r" = [^\r\n]*-ChildPath \('([^']+)' \+ \[guid\]::NewGuid\(\)\.ToString\('N'\)\)"
            )
            match = re.search(pattern, text)
            self.assertIsNotNone(match, f"falta el GUID completo de {variable}")
            return match.group(1) + ("a" * 32)

        suite = guid_component(self.remote_tests, "$script:TestRoot")
        case = guid_component(function_body(self.remote_tests, "New-TestCaseRoot"), "$path")
        transaction = guid_component(self.installer, "$transactionRoot")
        roots = function_body(self.remote_tests, "New-RemoteCaseRoots")
        program_files = re.search(r"\$programFiles = [^\r\n]*-ChildPath '([^']+)'", roots)
        self.assertIsNotNone(program_files)
        fixture = function_body(self.remote_tests, "New-FixturePackageSource")
        relative_files = re.findall(r"Join-Path \$bundleRoot '([^']+)'", fixture)
        self.assertTrue(relative_files, "faltan archivos reales del fixture")
        for temp in (
            r"C:\Users\TestUser\AppData\Local\Temp",
            r"C:\Users\LongProfileName\AppData\Local\Temp",
        ):
            for relative in relative_files:
                staging = PureWindowsPath(
                    temp, suite, case, program_files.group(1),
                    "Autodesk", "ApplicationPlugins", transaction,
                    "staging", "MensorCAD.bundle", relative,
                )
                with self.subTest(temp=temp, relative=relative):
                    self.assertLess(len(str(staging)), 260, str(staging))
                    self.assertLess(len(str(staging.parent)), 248, str(staging.parent))

    def test_local_compatibility_failure_reports_only_new_install_errors(self) -> None:
        start = self.remote_tests.index("    Test-Case 'Las opciones locales siguen intactas sin -FromRelease'")
        end = self.remote_tests.index("    Test-Case 'El codigo de salida del hijo", start)
        case = self.remote_tests[start:end]
        offset = "$installErrorOffset = $script:SeamErrors.Count"
        self.assertIn(offset, case, "falta separar los errores de la instalacion de los rechazos previos")
        self.assertLess(case.index(offset), case.index("$installExit = Invoke-MensorCadCli"))
        self.assertIn("@($script:SeamErrors | Select-Object -Skip $installErrorOffset)", case)
        self.assertIn("Error del instalador: ", case, "la asercion debe mostrar el error real")
        self.assertIn("Sin mensaje de error capturado.", case)
        self.assertIn("+ $installDiagnostic)", case, "el diagnostico debe formar parte de la asercion")
        self.assertNotIn("$script:SeamErrors.Clear()", case, "no se debe borrar evidencia de otros pasos")

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
            {"Uninstall", "NoAnimation", "Help", "Version", "FromRelease", "ElevatedProcess", "HoldResult"},
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

    def test_uninstall_launcher_is_allowed_but_not_required_in_old_archives(self) -> None:
        optional = re.search(
            r"\$script:MensorCadReleaseOptionalFiles = @\((.*?)\)",
            self.remote_branch, re.DOTALL,
        )
        self.assertIsNotNone(optional)
        self.assertEqual(re.findall(r"'([^']+)'", optional.group(1)), ["Desinstalar.bat"])
        validator = function_body(self.remote_branch, "Get-MensorCadReleaseArchiveEntries")
        self.assertIn("$script:MensorCadReleaseOptionalFiles -ccontains $validated.RelativePath", validator)
        self.assertIn("foreach ($required in $script:MensorCadReleaseFixedFiles)", validator)

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

    def test_remote_test_helpers_preserve_collection_cardinality(self) -> None:
        # Windows PowerShell 5.1 desenrolla `return @(...)`: el llamador recibe
        # $null con 0 coincidencias y el objeto suelto con 1, asi que .Count
        # falla bajo Set-StrictMode 2.0. El ayudante debe devolver el arreglo
        # como un unico objeto para conservar 0/1/2+ elementos.
        text = self.remote_tests
        inicio = text.index("function Get-SeamCalls")
        fin = text.index("\ntry {", inicio)
        cuerpo = text[inicio:fin]
        self.assertTrue(
            "return ,$calls" in cuerpo,
            "Get-SeamCalls debe devolver el arreglo sin desenrollarlo",
        )
        self.assertTrue(
            "return @($script:SeamCalls" not in cuerpo,
            "return @(...) desenrolla la coleccion y rompe .Count",
        )
        for fragmento in (
            "Assert-Equal 1 $apiCalls.Count",
            "Assert-Equal 0 (Get-SeamCalls -Kind 'text').Count",
            "Assert-Equal 0 (Get-SeamCalls -Kind 'file').Count",
            "Assert-Equal 2 $fileCalls.Count",
        ):
            self.assertTrue(fragmento in text, "falta la comprobacion: " + fragmento)

    def test_child_probe_failure_message_includes_child_summary(self) -> None:
        # El codigo de salida real del hijo no se puede reproducir en Linux: el
        # resumen del hijo debe acompanar al fallo para que el proximo log de
        # Windows distinga un hijo que no corrio de un estado mal leido.
        self.assertTrue(
            "Resumen del hijo: " in self.remote_tests,
            "el fallo del codigo de salida debe incluir el resumen del hijo",
        )
        self.assertTrue(
            "Assert-Equal 9 ([int]$summary.ExitCode)" in self.remote_tests,
            "la expectativa estricta del codigo 9 debe seguir vigente",
        )
        for campo in ("RawProcessExitCode", "ProcessExitCodeIsNull", "ProcessExitCodeError"):
            self.assertTrue(
                campo in self.remote_tests,
                "falta el diagnostico sin conversion a entero: " + campo,
            )

    def test_remote_child_pins_process_state_and_rejects_missing_exit_status(self) -> None:
        # Windows PowerShell 5.1 puede dejar el estado crudo del Process hijo sin
        # disponible: ExitCode se lee como $null sin excepcion y [int]$null
        # convertiria un fallo real en un falso exito 0. La correccion fija el
        # handle antes de la espera activa, lee el estado crudo una sola vez y lo
        # rechaza antes de convertirlo.
        body = function_body(self.installer, "Invoke-MensorCadRemoteChild")
        # Los comentarios del codigo no cuentan como ejecucion.
        code = "\n".join(
            linea for linea in body.splitlines() if not linea.strip().startswith("#")
        )
        self.assertTrue(
            "$null = $process.Handle" in code, "falta fijar el handle del proceso hijo"
        )
        self.assertLess(
            code.index("$null = $process.Handle"),
            code.index("Wait-MensorCadRemoteChild -Process $process"),
            "el handle debe fijarse antes de la espera activa",
        )
        self.assertTrue(
            "$rawExitCode = $process.ExitCode" in code,
            "falta leer el estado crudo del hijo una sola vez",
        )
        self.assertIn("if ($null -eq $rawExitCode)", code)
        self.assertLess(
            code.index("if ($null -eq $rawExitCode)"),
            code.index("[int]$rawExitCode"),
            "el estado ausente debe rechazarse antes de convertir a entero",
        )
        self.assertIn("finally {", code)
        self.assertIn("$process.Dispose()", code)
        self.assertLess(
            code.index("return [pscustomobject]"),
            code.index("finally {"),
            "el proceso se libera en el bloque finally despues de capturar el resultado",
        )
        self.assertEqual(1, code.count("Start-Process"), "no se debe lanzar el hijo dos veces")
        self.assertNotIn("-Wait ", code, "la espera debe seguir siendo activa, no bloqueante")
        self.assertNotIn("Stop-Process", code, "no se debe terminar el hijo a la fuerza")

    def test_remote_windows_tests_cover_missing_child_status(self) -> None:
        text = self.remote_tests
        for fragment in (
            "New-ChildStatusProbeScript",
            "missing-status.json",
            "function script:Start-Process",
            "ExitCode = $null",
            "No se pudo determinar el codigo de salida",
            "child-ok.ps1",
            "SALIDA-HIJO-OK",
        ):
            self.assertTrue(fragment in text, "faltan pruebas Windows para: " + fragment)

    def test_remote_docs_document_missing_child_status(self) -> None:
        docs = self.remote_docs
        self.assertTrue(
            "estado de salida" in docs.lower(), "la documentacion debe explicar el estado de salida"
        )
        self.assertTrue(
            "no se puede determinar" in docs.lower(),
            "la documentacion debe explicar el fallo seguro sin estado",
        )

    def test_child_probe_captures_raw_status_before_helper_disposes_process(self) -> None:
        # Invoke-MensorCadRemoteChild libera el Process en su bloque finally antes
        # de devolver, asi que leer ExitCode despues del return observa un objeto
        # ya liberado. La sonda debe capturar el estado crudo dentro de la espera,
        # antes de que el ayudante devuelva, y resumir esos valores guardados.
        text = self.remote_tests
        inicio = text.index("function New-ChildProbeScript")
        fin = text.index("function New-ChildStatusProbeScript", inicio)
        probe = text[inicio:fin]
        self.assertTrue(
            "$script:ProbeRawExitCode = $null" in probe,
            "la sonda debe inicializar el diagnostico crudo para StrictMode",
        )
        self.assertTrue(
            "$script:ProbeRawExitCode = $Process.ExitCode" in probe,
            "la sonda debe capturar el estado crudo dentro de la espera",
        )
        self.assertLess(
            probe.index("$script:ProbeRawExitCode = $Process.ExitCode"),
            probe.index("$result = Invoke-MensorCadRemoteChild"),
            "la captura cruda debe ocurrir antes de que el ayudante devuelva",
        )
        self.assertLess(
            probe.index("$script:ProbeRawExitCode = $Process.ExitCode"),
            probe.index("$summary = [pscustomobject]"),
            "el resumen debe construirse con los valores ya capturados",
        )
        self.assertTrue(
            "RawProcessExitCode = $script:ProbeRawExitCode" in probe,
            "el resumen debe usar el valor capturado antes de la liberacion",
        )
        self.assertTrue(
            "$script:ProbeProcess.ExitCode" not in probe,
            "no se debe desreferenciar el Process despues de que el ayudante lo libere",
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

    def test_documented_remote_commands_are_guarded_one_liners(self) -> None:
        # El comando de una linea deja la PRIMERA descarga fuera del instalador:
        # sin try/catch propio, un 404 o un fallo de red del bootstrap saldria
        # como error crudo, sin el prefijo ERROR: ni codigo distinto de cero.
        for origen, text in (
            ("docs/remote-installer.md", self.remote_docs),
            ("README.md", read_text(ROOT / "README.md")),
        ):
            lines = [line.strip() for line in text.splitlines() if line.strip().startswith("powershell.exe")]
            latest = [line for line in lines if LATEST_BOOTSTRAP in line]
            pinned = [line for line in lines if PINNED_BOOTSTRAP.search(line)]
            self.assertTrue(latest, f"{origen} debe publicar el comando de la ultima version")
            self.assertTrue(pinned, f"{origen} debe publicar el comando de una version fijada")
            for line in latest + pinned:
                for fragment in (
                    "try {",
                    "catch {",
                    "-ErrorAction Stop",
                    "[Net.SecurityProtocolType]::Tls12",
                    "[scriptblock]::Create(",
                    "[Console]::Error.WriteLine(",
                    "ERROR: ",
                    "exit 1",
                ):
                    self.assertIn(fragment, line, f"{origen}: falta {fragment} en el comando")
                self.assertNotIn(
                    "$",
                    line,
                    f"{origen}: el comando no debe contener variables que el shell exterior expanda",
                )
                self.assertLess(
                    line.index("[Net.SecurityProtocolType]::Tls12"),
                    line.index("Invoke-RestMethod"),
                    f"{origen}: TLS 1.2 debe fijarse antes de la primera descarga",
                )
                self.assertLess(
                    line.index("try {"),
                    line.index("Invoke-RestMethod"),
                    f"{origen}: la primera descarga debe ocurrir dentro del try",
                )
            for line in pinned:
                tag = re.search(r"/releases/download/(v\d+\.\d+\.\d+)/Install-MensorCAD\.ps1", line)
                self.assertIsNotNone(tag, f"{origen}: el comando fijado debe usar la URL del tag")
                self.assertIn("-Version " + tag.group(1), line, f"{origen}: el tag de la URL debe pasarse al instalador")
                self.assertNotIn("releases/latest", line, f"{origen}: un tag fijado no debe usar el bootstrap de la ultima version")
            for line in latest:
                self.assertNotIn("-Version ", line, f"{origen}: la ultima version no debe fijar -Version")

    def test_documented_pinned_example_is_labelled_as_not_published(self) -> None:
        # El ejemplo fijado usa v0.1.0, que no esta publicado: la documentacion
        # no puede presentarlo como una descarga que ya funciona.
        docs = self.remote_docs
        self.assertIn("v0.1.0", docs)
        self.assertIn(LATEST_BOOTSTRAP, docs)
        self.assertTrue(
            re.search(r"v0\.1\.0[^\n]*(no publicado|no esta publicado|no está publicado|ejemplo|ilustrativ)", docs)
            or re.search(r"(ejemplo|ilustrativ)[^\n]*v0\.1\.0", docs),
            "el ejemplo v0.1.0 debe marcarse como ilustrativo y no publicado",
        )
        self.assertIn("credenciales", docs, "la documentacion debe explicar el 404 por acceso")
        self.assertIn("primera descarga", docs, "la documentacion debe explicar el limite del bootstrap")
        self.assertIn("ya ejecuta", docs, "la documentacion debe explicar que el bootstrap ya ejecuta codigo remoto")

    def test_remote_404_guidance_is_defensive_and_does_not_overstate(self) -> None:
        status = function_body(self.remote_branch, "Get-MensorCadRemoteHttpStatus")
        self.assertIn("StatusCode", status, "la deteccion debe leer el estado HTTP real")
        self.assertIn("Response", status)
        self.assertIn("catch {", status, "la deteccion no puede lanzar mientras maneja otro error")
        self.assertIn("return 0", status, "sin estado legible se conserva la guia generica")
        hint = function_body(self.remote_branch, "Get-MensorCadRemoteStatusHint")
        self.assertIn("404", hint)
        self.assertIn("credenciales", hint, "un 404 tambien puede ser un repositorio sin acceso")
        self.assertIn("publicad", hint, "un 404 tambien puede ser una release sin publicar")
        self.assertNotIn("no existe", hint, "un 404 no demuestra que la release no exista")
        resolver = function_body(self.remote_branch, "Resolve-MensorCadReleaseTag")
        self.assertIn("Get-MensorCadRemoteHttpStatus", resolver)
        self.assertIn(
            "No se pudo consultar la ultima release en GitHub",
            resolver,
            "la guia generica debe conservarse para el resto de errores",
        )
        install = function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall")
        self.assertIn("Get-MensorCadRemoteHttpStatus", install, "la descarga tambien debe distinguir un 404")
        self.assertIn("No se pudieron descargar los assets de la release", install)

    def test_parent_result_is_plain_safe_and_success_only_on_zero(self) -> None:
        result = function_body(self.remote_branch, "Write-MensorCadRemoteResult")
        self.assertIn("if ($script:MensorCadPlainMode)", result, "el resumen debe callarse en modo plano")
        self.assertLess(
            result.index("if ($script:MensorCadPlainMode)"),
            result.index("Write-MensorCadSuccess"),
            "en modo plano no se debe llegar al bloque de exito",
        )
        self.assertLess(
            result.index("if ($ExitCode -eq 0)"),
            result.index("Write-MensorCadSuccess"),
            "el exito solo puede pintarse con un codigo 0 real",
        )
        self.assertNotIn("Console]::Error", result, "el resumen del padre no debe duplicar el ERROR: del hijo")
        self.assertNotIn("Write-MensorCadFailure", result, "el fallo del hijo conserva su propio stderr")
        for claim in ("se instalo", "se instala", "se actualizo", "se actualiza"):
            self.assertNotIn(
                claim,
                result.lower(),
                "el padre solo conoce el codigo 0, no si se instalo o se actualizo",
            )
        install = function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall")
        self.assertIn("Write-MensorCadRemoteResult", install)
        self.assertLess(
            install.index("Write-MensorCadRelayedOutput -Text $child.StdOut"),
            install.index("Write-MensorCadRemoteResult"),
            "la salida del hijo se reenvia antes del resumen del padre",
        )
        self.assertLess(
            install.index("Write-MensorCadRelayedOutput -Text $child.StdErr -IsError"),
            install.index("Write-MensorCadRemoteResult"),
            "el error del hijo se conserva antes del resumen del padre",
        )

    def test_remote_phases_add_friendly_titles_without_changing_technical_text(self) -> None:
        install = function_body(self.remote_branch, "Invoke-MensorCadRemoteInstall")
        self.assertEqual(5, install.count("-Number "), "la entrada remota debe conservar sus cinco fases")
        self.assertEqual(5, len(re.findall(r"-Title '[^']+'", install)), "cada fase debe tener titulo amigable")
        self.assertEqual(5, len(re.findall(r"-Hint '[^']+'", install)), "cada fase debe tener una pista")
        for message in (
            "Resolviendo la release de GitHub",
            "Descargando el paquete y su SHA-256 sin permisos de administrador",
            "Verificando el SHA-256 y las entradas del ZIP",
            "Extrayendo el paquete verificado en una carpeta temporal propia",
        ):
            self.assertIn(message, install, f"el texto tecnico del modo plano debe conservarse: {message}")
        self.assertIn("$script:MensorCadRemoteChildActivityMessage -Title", install)

    def test_remote_windows_tests_cover_public_bootstrap_and_download_failures(self) -> None:
        text = self.remote_tests
        for fragment in (
            "New-BootstrapProbeScript",
            "Get-DocumentedBootstrapBody",
            "bootstrap-body",
            "FailFirstFetch",
            "New-RemoteHttpError",
            "FailDownload",
            "ApiHttpStatus",
            "DownloadHttpStatus",
            "SeamSuccessCalls",
            "Write-MensorCadRemoteResult",
            "la primera descarga",
            "assets de la release",
            "no debe afirmar",
        ):
            self.assertIn(fragment, text, f"faltan pruebas remotas de Windows para: {fragment}")
        self.assertNotIn("Invoke-RestMethod -UseBasicParsing 'https://github.com", text, "la prueba no debe descargar de verdad")

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
