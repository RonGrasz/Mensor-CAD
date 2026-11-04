"""Comprobaciones estructurales del instalador local de MensorCAD.

Estas pruebas NO validan el comportamiento funcional en Windows. Verifican que
los archivos del instalador existen, conservan la interfaz acordada y no
introducen cambios globales peligrosos. La validacion funcional real vive en
tests/Test-Installer.ps1 y requiere Windows PowerShell 5.1.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path, PureWindowsPath

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "Install-MensorCAD.ps1"
BAT = ROOT / "Instalar.bat"
WINDOWS_TESTS = ROOT / "tests" / "Test-Installer.ps1"
WINDOW_TESTS = ROOT / "tests" / "Test-InstallerWindow.ps1"

REMOTE_SECTION_MARKER = "# Entrada remota: descarga y verificacion de releases de GitHub"

# Base temporal de Windows con la misma forma que la ruta real donde se observo
# el fallo local, pero con un usuario generico y dos caracteres mas largo: el
# presupuesto queda conservador y la prueba no depende de una maquina concreta.
WINDOWS_TEMP_BASE = PureWindowsPath("C:/Users/Example/AppData/Local/Temp")
WINDOWS_MAX_PATH = 260
FIXTURE_GUID = "0" * 32


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def between(text: str, start_marker: str, end_marker: str) -> str:
    """Devuelve el fragmento entre dos marcadores ya presentes en el archivo."""
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


def single_match(pattern: str, text: str, description: str) -> str:
    match = re.search(pattern, text, flags=re.DOTALL)
    if match is None:
        raise AssertionError(f"no se pudo derivar {description} de las fuentes")
    return match.group(1)


class InstallerStructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.installer = read_text(INSTALLER)
        cls.bat = read_text(BAT)
        cls.windows_tests = read_text(WINDOWS_TESTS)
        cls.window_tests = read_text(WINDOW_TESTS)
        cls.top_param_block = cls._top_param_block(cls.installer)
        cls.local_branch, _, cls.remote_branch = cls.installer.partition(REMOTE_SECTION_MARKER)

    @staticmethod
    def _top_param_block(text: str) -> str:
        start = text.index("param(")
        end = text.index("\n)", start)
        return text[start : end + 2]

    def test_expected_files_exist(self) -> None:
        for path in (INSTALLER, BAT, WINDOWS_TESTS, WINDOW_TESTS):
            self.assertTrue(path.is_file(), f"falta {path}")

    def test_public_switches_are_limited_to_documented_interface(self) -> None:
        block = self.top_param_block
        for switch in ("$Uninstall", "$NoAnimation", "$Help", "$FromRelease", "$Version", "$ElevatedProcess", "$HoldResult"):
            self.assertIn(switch, block)
        self.assertNotIn("Destination", block)
        self.assertNotIn("SourceRoot", block)
        self.assertNotIn("Url", block)
        # -HoldResult es un interruptor reservado; no aparece como opcion publica
        # usable desde la entrada remota, solo como senal interna de la relanzada.

    def test_destination_is_fixed_program_files_bundle(self) -> None:
        text = self.installer
        self.assertIn("[Environment]::GetFolderPath('ProgramFiles')", text)
        self.assertIn("'Autodesk'", text)
        self.assertIn("'ApplicationPlugins'", text)
        self.assertIn("$script:MensorCadBundleFolderName", text)
        self.assertIn("function Get-MensorCadDestinationRoot", text)

    def test_dot_source_guard_has_no_side_effects(self) -> None:
        guard = re.search(
            r"if \(\$script:MensorCadDotSourced\)\s*\{\s*return\s*\}",
            self.installer,
        )
        self.assertIsNotNone(guard, "el instalador debe retornar sin efectos al cargarse con dot-source")
        self.assertLess(guard.start(), self.installer.index("exit $mensorCadExitCode"))

    def test_engine_functions_exist_and_are_reusable(self) -> None:
        for name in (
            "Test-MensorCadSource",
            "Read-MensorCadManifest",
            "Install-MensorCadBundle",
            "Uninstall-MensorCadBundle",
            "Assert-MensorCadOwnedDestination",
            "Read-MensorCadMarker",
            "Write-MensorCadMarker",
            "Get-MensorCadDestinationRoot",
            "Test-MensorCadAutoCadRunning",
        ):
            self.assertIn(f"function {name}", self.installer, f"falta la funcion interna {name}")

    def test_elevation_is_confined_to_the_cli_helper(self) -> None:
        installer = self.installer
        self.assertEqual(installer.count("-Verb RunAs"), 1)
        run_as = installer.index("-Verb RunAs")
        self.assertGreater(run_as, installer.index("function Invoke-MensorCadElevatedSelf"))
        engine = installer[
            installer.index("function Install-MensorCadBundle") : installer.index(
                "function Uninstall-MensorCadBundle"
            )
        ]
        uninstall_engine = installer[
            installer.index("function Uninstall-MensorCadBundle") : installer.index(
                "function Write-MensorCadBanner"
            )
        ]
        for body in (engine, uninstall_engine):
            self.assertNotIn("Start-Process", body)
            self.assertNotIn("-Verb RunAs", body)
            self.assertNotIn("Test-MensorCadAdministrator", body)

    def test_generic_list_collection_patterns_are_safe(self) -> None:
        for forbidden in (
            "@($Marker.Files)",
            "@($SourceInfo.Entries)",
            "@($tree.Directories)",
        ):
            self.assertNotIn(forbidden, self.installer, f"patron fragil de conversion de List<T>: {forbidden}")
        self.assertIn("$tree.Directories.ToArray() | Sort-Object", self.installer)
        comparison = self.installer[
            self.installer.index("function Test-MensorCadInventoryMatches") : self.installer.index(
                "function Assert-MensorCadOwnedDestination"
            )
        ]
        self.assertIn("$installed = $Marker.Files", comparison)
        self.assertIn("$source = $SourceInfo.Entries", comparison)
        self.assertIn("$installed.Count", comparison)
        self.assertIn("$source.Count", comparison)

    def test_staged_source_is_pinned_and_self_consistent_drift_is_rejected(self) -> None:
        self.assertIn("function Test-MensorCadSourceEntriesMatch", self.installer)
        self.assertIn("$revalidatedSource = Test-MensorCadSource", self.installer)
        self.assertIn("$revalidatedSource.ManifestSha256 -ne $sourceInfo.ManifestSha256", self.installer)
        self.assertIn("Test-MensorCadSourceEntriesMatch", self.installer)
        self.assertIn("cambio durante la instalacion", self.installer)
        self.assertIn("Write-MensorCadMarker -DestinationRoot $stagingBundle -SourceInfo $sourceInfo", self.installer)
        self.assertNotIn("Write-MensorCadMarker -DestinationRoot $stagingBundle -SourceInfo $revalidatedSource", self.installer)
        engine = self.installer[
            self.installer.index("function Install-MensorCadBundle") : self.installer.index(
                "function Uninstall-MensorCadBundle"
            )
        ]
        self.assertLess(
            engine.index("Test-MensorCadSourceEntriesMatch"),
            engine.index("[System.IO.Directory]::Move($destination, $backupBundle)"),
            "la comparacion contra el inventario original debe ocurrir antes de tocar el destino",
        )

    def test_architecture_rejection_precedes_destination_and_uac(self) -> None:
        for name in (
            "Test-MensorCad64BitOperatingSystem",
            "Test-MensorCad64BitProcess",
            "Assert-MensorCad64BitHost",
        ):
            self.assertIn(f"function {name}", self.installer)
        cli = self.installer[self.installer.index("function Invoke-MensorCadCli") :]
        architecture_check = cli.index("Assert-MensorCad64BitHost")
        self.assertLess(architecture_check, cli.index("Get-MensorCadProgramFilesRoot"))
        self.assertLess(architecture_check, cli.index("Invoke-MensorCadElevatedSelf"))
        self.assertIn("MensorCAD requiere Windows de 64 bits y PowerShell de 64 bits", self.installer)

    def test_source_is_validated_before_uac_and_revalidated_after(self) -> None:
        cli = self.installer[self.installer.index("function Invoke-MensorCadCli") :]
        install_branch = cli[cli.index("$progressCallback =") :]
        self.assertLess(
            install_branch.index("Test-MensorCadSource -SourceRoot $sourceRoot"),
            install_branch.index("Invoke-MensorCadElevatedSelf"),
            "la validacion local debe ejecutarse antes de pedir UAC",
        )
        validations = re.findall(
            r"Test-MensorCadSource -SourceRoot \$sourceRoot",
            self.installer,
            flags=re.IGNORECASE,
        )
        self.assertGreaterEqual(
            len(validations),
            4,
            "el origen debe revalidarse antes de UAC, despues de UAC y despues de la etapa",
        )
        self.assertIn("AfterStage", self.installer)

    def test_help_is_handled_before_platform_check(self) -> None:
        cli = self.installer[self.installer.index("function Invoke-MensorCadCli") :]
        self.assertLess(
            cli.index("if ($Help)"),
            cli.index("if (-not (Test-MensorCadWindows))"),
            "la ayuda debe responder incluso fuera de Windows",
        )

    def test_non_windows_rejection_exists_before_writes(self) -> None:
        self.assertIn("function Test-MensorCadWindows", self.installer)
        self.assertIn("[PlatformID]::Win32NT", self.installer)
        cli = self.installer[self.installer.index("function Invoke-MensorCadCli") :]
        windows_check = cli.index("if (-not (Test-MensorCadWindows))")
        for mutation in ("Install-MensorCadBundle", "Uninstall-MensorCadBundle"):
            self.assertLess(windows_check, cli.index(mutation), f"{mutation} no debe preceder al control de plataforma")

    def test_source_hardening_checks_exist(self) -> None:
        for fragment in (
            "ReparsePoint",
            "'..'",
            "duplicada",
            "no declarado",
            "no reconocidos",
            "bundle.sha256",
        ):
            self.assertIn(fragment, self.installer)
        self.assertIn("function Assert-MensorCadNoReparseInPath", self.installer)

    def test_ownership_marker_is_explicit(self) -> None:
        for fragment in (
            ".mensorcad-install.json",
            "mensorcad-bundle-marker",
            "formatVersion",
            "sourceManifestSha256",
            "installedAtUtc",
            "files",
        ):
            self.assertIn(fragment, self.installer)
        self.assertIn("falta .mensorcad-install.json", self.installer)

    def test_install_is_staged_with_backup_and_rollback(self) -> None:
        for fragment in (
            "staging",
            "backup",
            "[System.IO.Directory]::Move($destination, $backupBundle)",
            "[System.IO.Directory]::Move($stagingBundle, $destination)",
            "[System.IO.Directory]::Move($backupBundle, $destination)",
            "restauracion automatica",
        ):
            self.assertIn(fragment, self.installer)

    def test_autocad_is_checked_but_never_force_closed(self) -> None:
        self.assertIn("function Test-MensorCadAutoCadRunning", self.installer)
        self.assertGreaterEqual(self.installer.count("& $AutoCadProbe"), 3)
        engine = self.installer[
            self.installer.index("function Install-MensorCadBundle") : self.installer.index(
                "function Uninstall-MensorCadBundle"
            )
        ]
        self.assertLess(
            engine.index("if (& $AutoCadProbe)"),
            engine.index("Status = 'unchanged'"),
            "la comprobacion de AutoCAD debe preceder al camino sin cambios",
        )
        for forbidden in ("Stop-Process", "taskkill", "CloseMainWindow", "TerminateProcess"):
            self.assertNotIn(forbidden, self.installer)

    def test_no_global_security_profile_or_execution_policy_changes(self) -> None:
        for forbidden in (
            "Set-ExecutionPolicy",
            "Set-MpPreference",
            "SECURELOAD",
            "TRUSTEDPATHS",
            "APPAUTOLOAD",
            "Set-ItemProperty",
            "New-ItemProperty",
            "reg add",
        ):
            self.assertNotIn(forbidden, self.installer)
            self.assertNotIn(forbidden, self.bat)

    def test_local_branch_stays_offline_while_remote_branch_is_explicit(self) -> None:
        self.assertTrue(self.remote_branch.strip(), "debe existir la seccion remota marcada")
        for forbidden in (
            "Invoke-WebRequest",
            "Start-BitsTransfer",
            "Net.WebClient",
            "DownloadFile",
            "DownloadString",
            "curl ",
            "wget ",
        ):
            self.assertNotIn(forbidden, self.local_branch, f"la rama local no debe descargar: {forbidden}")
        self.assertIn("Invoke-WebRequest", self.remote_branch, "la descarga debe vivir en la rama remota explícita")
        cli = self.installer[self.installer.index("function Invoke-MensorCadCli") :]
        self.assertIn("if ($FromRelease)", cli, "la rama remota solo se activa con -FromRelease")

    def test_animation_is_real_and_has_fallbacks(self) -> None:
        for fragment in (
            "Write-MensorCadActivity",
            "IsOutputRedirected",
            "NoAnimation",
            "Write-MensorCadProgress",
        ):
            self.assertIn(fragment, self.installer)
        # La animacion no se simula con esperas falsas: no existe Start-Sleep y
        # la unica espera remota es una espera del sistema sobre un proceso real.
        self.assertNotIn("Start-Sleep", self.installer, "la espera no debe usar demoras artificiales")
        wait_body = self.installer[self.installer.index("function Wait-MensorCadRemoteChild") :]
        wait_body = wait_body[: wait_body.index("\nfunction ")]
        self.assertLess(
            wait_body.index("while (-not $Process.HasExited)"),
            wait_body.index("$Process.WaitForExit($IntervalMilliseconds)"),
            "la espera con timeout solo ocurre dentro del bucle del proceso vivo",
        )
        self.assertLess(
            wait_body.index("$Process.WaitForExit($IntervalMilliseconds)"),
            wait_body.index("$Process.WaitForExit()"),
            "no debe haber esperas despues de que el hijo termina",
        )
        self.assertNotIn("Start-Sleep", wait_body)

    def test_errors_go_to_stderr_and_exit_codes_are_clean(self) -> None:
        self.assertIn("[Console]::Error.WriteLine", self.installer)
        self.assertIn("return 0", self.installer)
        self.assertIn("return 1", self.installer)
        # La espera final del hijo elevado nunca puede cambiar el estado real:
        # el codigo se calcula antes y se conserva aunque Read-Host falle.
        entry = self.installer[self.installer.index("$mensorCadExitCode = Invoke-MensorCadCli") :]
        self.assertLess(
            entry.index("$mensorCadExitCode = Invoke-MensorCadCli"),
            entry.index("Wait-MensorCadResultHold -HoldResult:$HoldResult"),
            "la espera final debe ejecutarse despues de conocer el codigo real",
        )
        self.assertLess(
            entry.index("Wait-MensorCadResultHold -HoldResult:$HoldResult"),
            entry.index("exit $mensorCadExitCode"),
            "el codigo real debe salir despues de la espera final",
        )

    def test_bat_prefers_native_64bit_powershell_and_preserves_exit_code(self) -> None:
        self.assertIn("%~dp0Install-MensorCAD.ps1", self.bat)
        self.assertIn("MENSORCAD_POWERSHELL", self.bat)
        self.assertIn("PROCESSOR_ARCHITEW6432", self.bat)
        self.assertIn("Sysnative", self.bat)
        self.assertIn("System32\\WindowsPowerShell\\v1.0\\powershell.exe", self.bat)
        self.assertIn('"%MENSORCAD_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%MENSORCAD_SCRIPT%" %*', self.bat)
        self.assertIn('set "MENSORCAD_BAT_LAUNCHER=1"', self.bat, "el BAT debe marcar el lanzamiento del doble clic")
        self.assertIn("%ERRORLEVEL%", self.bat)
        self.assertIn("exit /b %MENSORCAD_EXIT%", self.bat)
        self.assertIn("MENSORCAD_NO_PAUSE", self.bat)
        self.assertNotIn("Set-ExecutionPolicy", self.bat)
        self.bat.encode("ascii")  # cmd.exe seguro sin BOM ni caracteres ambiguos
        self.assertNotIn(b"\n", BAT.read_bytes().replace(b"\r\n", b""), "el BAT debe usar CRLF")

    def test_windows_tests_cover_required_scenarios_with_isolated_fixtures(self) -> None:
        text = self.windows_tests
        for scenario in (
            "Instalacion inicial",
            "Actualizacion",
            "Desinstalacion",
            "Rollback",
            "no declarados",
            "duplicado",
            "reanalisis",
            "AutoCAD",
            "Ayuda",
            "NoAnimation",
            "destino existente no propio",
            "padre con punto de reanalisis",
            "entrada publica",
            "deriva autoconsistente",
            "host de 32 bits",
            "updateExit",
        ):
            self.assertIn(scenario, text, f"las pruebas Windows no cubren: {scenario}")
        self.assertIn("GetTempPath", text)
        self.assertIn("Install-MensorCadBundle", text)
        self.assertIn("Uninstall-MensorCadBundle", text)
        self.assertIn(". $script:InstallerPath", text)
        self.assertNotIn("GetFolderPath", text)
        self.assertNotIn("C:\\Program Files", text)
        self.assertNotIn("-Verb RunAs", text)

    def test_windows_tests_capture_bat_streams_without_promoting_native_stderr(self) -> None:
        # Windows PowerShell 5.1 con $ErrorActionPreference = 'Stop' convierte el
        # stderr de un comando nativo en un error terminante (NativeCommandError)
        # cuando la salida se fusiona con 2>&1. La prueba del BAT debe capturar
        # cada flujo en su propio archivo, igual que Invoke-ChildInstaller.
        text = self.windows_tests
        self.assertTrue(
            "function Invoke-BatCommand" in text, "falta el capturador del BAT"
        )
        self.assertTrue("RedirectStandardError" in text, "falta el stderr redirigido")
        fusionadas = [linea.strip() for linea in text.splitlines() if "2>&1" in linea]
        self.assertEqual(
            [], fusionadas, "no se debe fusionar el stderr nativo en la tuberia"
        )
        inicio = text.index("Test-Case 'El BAT reenvia opciones")
        fin = text.index("Test-Case 'La entrada publica instala", inicio)
        caso = text[inicio:fin]
        self.assertIn("Invoke-BatCommand -BatPath $batCopy -Arguments @('-Help')", caso)
        self.assertIn(
            "Invoke-BatCommand -BatPath $batCopy -Arguments @('-NoAnimation')", caso
        )
        self.assertIn("Assert-Equal 0 $help.ExitCode", caso)
        self.assertIn("$help.Stdout -match 'Uso:'", caso)
        self.assertIn("Assert-Equal '' ($help.Stderr.Trim())", caso)
        self.assertIn("Assert-Equal 1 $failure.ExitCode", caso)
        self.assertIn("$failure.Stderr -match", caso)
        self.assertIn("MensorCAD.bundle", caso)

    def test_ps1_files_are_utf8_with_bom_for_windows_powershell_51(self) -> None:
        for path in (INSTALLER, WINDOWS_TESTS, WINDOW_TESTS):
            self.assertTrue(
                path.read_bytes().startswith(b"\xef\xbb\xbf"),
                f"{path.name} debe guardarse como UTF-8 con BOM para Windows PowerShell 5.1",
            )

    def test_single_window_handoff_replaces_window_hiding(self) -> None:
        installer = self.installer
        for name in (
            "Get-MensorCadConsoleNativeType",
            "Get-MensorCadConsoleClients",
            "Get-MensorCadProcessParentId",
            "Get-MensorCadProcessName",
            "Get-MensorCadProcessCommandLine",
            "Get-MensorCadBatchCommandTarget",
            "Test-MensorCadConsoleStreamsInteractive",
            "Get-MensorCadDedicatedConsole",
            "Test-MensorCadHandoffEligible",
            "Wait-MensorCadResultHold",
        ):
            self.assertIn(f"function {name}", installer, f"falta el ayudante {name}")

        # La ruta obsoleta de ocultar ventanas debe estar retirada por completo.
        for retired in (
            "ShowWindow",
            "user32.dll",
            "IsWindowVisible",
            "GetConsoleWindow",
            "WT_SESSION",
            "SW_HIDE",
            "Set-MensorCadConsoleWindowVisible",
            "Get-MensorCadConsoleProbe",
            "Test-MensorCadConsoleHandoffBlocked",
        ):
            self.assertNotIn(retired, installer, f"la ruta obsoleta sigue presente: {retired}")

        # Solo se conserva la sonda de clientes de consola, perezosa y de lectura.
        compilations = [m.start() for m in re.finditer(r"Add-Type -TypeDefinition", installer)]
        self.assertEqual(1, len(compilations), "la declaracion Win32 debe compilarse en un solo lugar")
        self.assertGreater(
            compilations[0],
            installer.index("function Get-MensorCadConsoleNativeType"),
            "la sonda nativa no debe compilarse al cargar el archivo",
        )
        native_block = installer[
            installer.index("function Get-MensorCadConsoleNativeType") : installer.index(
                "function Get-MensorCadConsoleClients"
            )
        ]
        self.assertIn("kernel32.dll", native_block)
        self.assertIn("GetConsoleProcessList", native_block)

        # Prueba de consola dedicada: exactamente dos clientes, cmd padre directo
        # y /c exacto de este BAT. Sin antecesor de cmd y sin WT_SESSION.
        proof = installer[
            installer.index("function Get-MensorCadDedicatedConsole") : installer.index(
                "function Test-MensorCadHandoffEligible"
            )
        ]
        self.assertIn("$consoleProcessIds.Count -ne 2", proof)
        self.assertIn("$ParentIdProbe $CurrentProcessId", proof)
        self.assertIn("'^cmd$'", proof)
        self.assertNotIn("explorer", proof)
        self.assertIn("Get-MensorCadBatchCommandTarget -CommandLine $commandLine", proof)
        self.assertIn("$token -ieq '/c'", installer)
        self.assertIn("$token -ieq '/k'", installer)

        # Regla unica de elegibilidad: opt-in del BAT, consola interactiva, sin
        # automatizacion y prueba de consola dedicada.
        eligible = installer[
            installer.index("function Test-MensorCadHandoffEligible") : installer.index(
                "function Wait-MensorCadResultHold"
            )
        ]
        for fragment in (
            "if (-not $BatLauncher) { return $false }",
            "if (-not $StreamsInteractive) { return $false }",
            "if (-not [string]::IsNullOrEmpty($NoPause)) { return $false }",
            "& $DedicatedConsoleProbe",
        ):
            self.assertIn(fragment, eligible)

        # Un unico sitio de elevacion, con espera condicional y sentinel privado.
        elevation = installer[
            installer.index("function Invoke-MensorCadElevatedSelf") : installer.index(
                "function Invoke-MensorCadCli"
            )
        ]
        self.assertEqual(1, installer.count("-Verb RunAs"))
        self.assertEqual(1, elevation.count("-Verb RunAs"))
        self.assertIn("-Verb RunAs -Wait:(-not $handoff) -PassThru", elevation)
        self.assertIn("Test-MensorCadHandoffEligible -BatLauncher:$BatLauncher", elevation)
        self.assertIn("$argumentString += ' -HoldResult'", elevation)
        self.assertIn("return [int]$script:MensorCadBatHandoffSentinel", elevation)
        self.assertIn("return [int]$process.ExitCode", elevation)
        self.assertIn("No se obtuvo elevacion mediante UAC. La instalacion no se realizo. Detalle: ", elevation)
        self.assertIn("No se pudo iniciar el proceso elevado. La instalacion no se realizo.", elevation)
        self.assertNotIn("Stop-Process", elevation)

        # El opt-in del BAT viaja como marca de entorno reservada; la espera
        # final viaja como interruptor reservado -HoldResult porque la herencia
        # de entorno no esta probada tras UAC.
        block = self.top_param_block
        self.assertIn("[switch]$HoldResult", block, "-HoldResult debe ser un parametro reservado del script")
        self.assertNotIn("[switch]$BatLauncher", block, "-BatLauncher no debe ser un parametro publico")
        self.assertIn("$env:MENSORCAD_BAT_LAUNCHER -eq '1'", installer)
        self.assertIn("Wait-MensorCadResultHold -HoldResult:$HoldResult", installer)
        self.assertNotIn("MENSORCAD_RESULT_HOLD", installer, "no debe depender de la herencia de entorno")
        self.assertIn("MENSORCAD_BAT_LAUNCHER", self.bat)
        entry = installer[installer.index("$mensorCadCliArguments = @{}") :]
        self.assertLess(
            entry.index("$env:MENSORCAD_BAT_LAUNCHER -eq '1'"),
            entry.index("$mensorCadExitCode = Invoke-MensorCadCli"),
            "la marca del BAT debe decidir antes de ejecutar el flujo",
        )

        # Sentinel privado, coherente con el BAT y ajeno a los codigos reales.
        sentinel_match = re.search(r"\$script:MensorCadBatHandoffSentinel = (\d+)", installer)
        self.assertIsNotNone(sentinel_match, "falta el sentinel privado del lanzador")
        sentinel = sentinel_match.group(1)
        self.assertNotIn(sentinel, ("0", "1"), "el sentinel no puede confundirse con un estado real")
        bat_sentinel = re.search(r'if "%MENSORCAD_EXIT%"=="(\d+)" goto :handoff', self.bat)
        self.assertIsNotNone(bat_sentinel, "el BAT debe reconocer el sentinel del lanzador")
        self.assertEqual(sentinel, bat_sentinel.group(1), "BAT y PS deben compartir el mismo sentinel")

        # La espera final del hijo elevado es visible pero nunca en automatizacion
        # ni con flujos redirigidos, y no debe hacer polling de teclado.
        hold = installer[
            installer.index("function Wait-MensorCadResultHold") : installer.index(
                "function Invoke-MensorCadElevatedSelf"
            )
        ]
        for fragment in (
            "if (-not $HoldResult) { return }",
            "if (-not $StreamsInteractive) { return }",
            "if (-not [string]::IsNullOrEmpty($NoPause)) { return }",
            "Read-Host",
        ):
            self.assertIn(fragment, hold)
        self.assertNotIn("ReadKey", installer)
        self.assertNotIn("Wait-Key", installer)

    def test_bat_launcher_handoff_is_neutral_and_skips_pause(self) -> None:
        bat = self.bat
        self.assertIn('set "MENSORCAD_BAT_LAUNCHER=1"', bat, "el BAT debe marcar el lanzamiento")
        self.assertIn('"%MENSORCAD_SCRIPT%" %*', bat, "el BAT debe reenviar los argumentos sin cambios")
        self.assertIn("goto :handoff", bat)
        self.assertIn("\n:handoff", bat.replace("\r\n", "\n"))
        handoff = bat.replace("\r\n", "\n")
        handoff = handoff[handoff.index("\n:handoff") :]
        self.assertIn("continua en la ventana elevada", handoff)
        self.assertIn("exit /b 0", handoff)
        self.assertNotIn("pause", handoff, "la entrega no debe hacer pausa")
        self.assertNotIn("correctamente", handoff, "la entrega no debe imprimir exito")
        neutral_line = [line for line in handoff.splitlines() if "continua en la ventana elevada" in line][0]
        self.assertNotIn("ERROR", neutral_line)
        self.assertIn("if not defined MENSORCAD_NO_PAUSE pause", bat, "el camino normal conserva la pausa")
        self.assertIn("exit /b %MENSORCAD_EXIT%", bat, "el camino normal conserva el codigo original")

    def test_window_tests_exercise_handoff_with_local_seams_only(self) -> None:
        text = self.window_tests
        for fragment in (
            "Get-MensorCadDedicatedConsole",
            "Test-MensorCadConsoleStreamsInteractive",
            "Wait-MensorCadResultHold",
            "$Verb -eq 'RunAs'",
            "GetTempPath",
            ". $script:InstallerPath",
            "Restore-WindowTestSeams",
            "MENSORCAD_NO_PAUSE",
            "MENSORCAD_STUB_EXIT",
            "MENSORCAD_BAT_LAUNCHER",
            "Get-MensorCadWindowsTerminalPath",
            "New-MensorCadHandoffPayload",
            "-EncodedCommand",
        ):
            self.assertIn(fragment, text, f"las pruebas de ventana no cubren: {fragment}")
        self.assertNotIn("-Verb RunAs", text, "las pruebas de ventana no deben pedir UAC real")
        self.assertNotIn("ShowWindow", text, "las pruebas de ventana no deben manipular ventanas")
        for scenario in (
            "WT_SESSION",
            "Sin la marca del BAT",
            "MENSORCAD_NO_PAUSE",
            "flujos redirigidos",
            "terminal existente",
            "sentinel",
            "HoldResult",
            "Cancelar UAC",
            "Ya administrador",
            "El BAT marca el lanzamiento",
            "hijo remoto",
            "wt.exe",
            "ventana nueva",
            "banner",
            "indicador",
        ):
            self.assertIn(scenario, text, f"las pruebas de ventana no cubren: {scenario}")

    def test_handoff_prefers_windows_terminal_with_clean_banner_and_spinner(self) -> None:
        installer = self.installer
        for name in (
            "Get-MensorCadWindowsTerminalPath",
            "New-MensorCadHandoffPayload",
            "New-MensorCadWindowsTerminalArguments",
        ):
            self.assertIn(f"function {name}", installer, f"falta el ayudante {name}")

        # Descubrimiento perezoso de wt.exe y solo dentro de la entrega: el
        # camino sincrono nunca consulta Windows Terminal.
        self.assertIn("Get-Command -Name 'wt.exe' -CommandType Application", installer)
        elevation = installer[
            installer.index("function Invoke-MensorCadElevatedSelf") : installer.index("function Invoke-MensorCadCli")
        ]
        self.assertEqual(1, installer.count("-Verb RunAs"), "debe seguir habiendo un unico sitio de elevacion")
        self.assertEqual(1, elevation.count("Get-MensorCadWindowsTerminalPath"))
        handoff_index = elevation.index("$handoff = Test-MensorCadHandoffEligible -BatLauncher:$BatLauncher")
        lookup_index = elevation.index("$windowsTerminalPath = Get-MensorCadWindowsTerminalPath")
        self.assertLess(handoff_index, lookup_index, "la consulta de wt.exe debe ocurrir despues de decidir la entrega")
        self.assertIn(
            "if ($handoff) {",
            elevation[max(0, lookup_index - 200) : lookup_index],
            "la consulta de wt.exe debe vivir dentro del camino de entrega",
        )
        self.assertLess(elevation.index("$startFilePath = $powerShellPath"), lookup_index)
        self.assertIn("$startArguments = $argumentString", elevation, "el camino original debe conservarse intacto")
        self.assertIn(
            "-FilePath $startFilePath -ArgumentList $startArguments -Verb RunAs -Wait:(-not $handoff) -PassThru",
            elevation,
            "el unico sitio de elevacion debe elegir entre wt.exe y PowerShell",
        )

        # Invocacion fija de wt.exe: ventana nueva, perfil predeterminado y el
        # mismo Windows PowerShell 5.1 con los interruptores de siempre.
        terminal = installer[
            installer.index("function New-MensorCadWindowsTerminalArguments") : installer.index(
                "function Invoke-MensorCadElevatedSelf"
            )
        ]
        self.assertIn("'-w new new-tab -- ", terminal)
        self.assertIn("-NoProfile -ExecutionPolicy Bypass -EncodedCommand", terminal)
        self.assertNotIn("-NonInteractive", installer, "la relanzada nunca debe ser no interactiva")
        self.assertNotIn("--profile", installer, "no debe elegirse un perfil de Windows Terminal")
        self.assertNotIn("-p ", terminal, "no debe elegirse un perfil de Windows Terminal")

        # Payload unico y seguro: ruta escapada, interruptores constantes, sin
        # script temporal ni IPC, y salida con el codigo real del hijo.
        payload = installer[
            installer.index("function New-MensorCadHandoffPayload") : installer.index(
                "function New-MensorCadWindowsTerminalArguments"
            )
        ]
        self.assertIn("$ScriptPath -replace \"'\", \"''\"", payload)
        self.assertIn("'; exit $LASTEXITCODE'", payload)
        self.assertIn("[System.Text.Encoding]::Unicode.GetBytes", payload)
        self.assertIn("[Convert]::ToBase64String", payload)
        for forbidden in ("Set-Content", "Out-File", "New-TemporaryFile", "Start-Process"):
            self.assertNotIn(forbidden, payload, f"el payload no debe crear nada: {forbidden}")

        # La relanzada entregada conserva el banner; las comprobaciones de
        # administrador y antirrecursion siguen en pie.
        self.assertIn("if ((-not $ElevatedProcess) -or $HoldResult) {", installer)
        cli = installer[installer.index("function Invoke-MensorCadCli") : installer.index("# Guarda de dot-source")]
        self.assertIn("[switch]$HoldResult", cli, "la CLI debe recibir la marca de espera entregada")
        self.assertGreaterEqual(cli.count("if ($ElevatedProcess) {"), 2, "las comprobaciones antirrecursion deben seguir")
        self.assertIn("La sesion elevada no tiene permisos de administrador. La instalacion no se realizo.", cli)
        self.assertIn("La sesion elevada no tiene permisos de administrador. La desinstalacion no se realizo.", cli)
        entry = installer[installer.index("$mensorCadCliArguments = @{}") :]
        self.assertIn("if ($HoldResult) { $mensorCadCliArguments['HoldResult'] = $true }", entry)
        self.assertLess(
            entry.index("if ($HoldResult) { $mensorCadCliArguments['HoldResult'] = $true }"),
            entry.index("$mensorCadExitCode = Invoke-MensorCadCli"),
            "la marca de espera debe decidirse antes de ejecutar el flujo",
        )

        # Redibujado del indicador: un unico escalar con la longitud anterior y
        # relleno de espacios; nada de secuencias de limpieza ni otro motor.
        activity = installer[
            installer.index("function Write-MensorCadActivity") : installer.index("function Write-MensorCadProgress")
        ]
        self.assertIn("$padding = [Math]::Max(0, [int]$script:MensorCadActivityLength - $line.Length)", activity)
        self.assertIn("(' ' * $padding)", activity)
        self.assertIn("$script:MensorCadActivityLength = $line.Length", activity)
        self.assertIn("$script:MensorCadActivityLength = 0", activity)
        self.assertIn("Write-Host ('  ' + $Message)", activity, "el texto plano debe seguir igual")
        for forbidden in ("Clear-Host", "[Console]::Clear"):
            self.assertNotIn(forbidden, installer, f"el indicador no debe usar {forbidden}")

    def test_local_suite_fixture_paths_fit_in_windows_max_path(self) -> None:
        # La ejecucion local fallo con File.Copy y "No se puede encontrar una
        # parte de la ruta de acceso": la ruta transitoria del motor superaba
        # MAX_PATH. Las rutas se derivan de las fuentes reales (prefijos del
        # harness, sufijo de transaccion del instalador y archivos del fixture)
        # para que el presupuesto no dependa de valores escritos a mano.
        harness = self.windows_tests
        test_root_prefix = single_match(
            r"GetTempPath\(\)\) -ChildPath \('([^']+)' \+ \[guid\]::NewGuid\(\)",
            harness,
            "el prefijo de la raiz de pruebas",
        )
        case_root_prefix = single_match(
            r"function New-TestCaseRoot \{.*?ChildPath \('([^']+)' \+ \[guid\]::NewGuid\(\)",
            harness,
            "el prefijo de la raiz de cada caso",
        )
        fixture_destination = PureWindowsPath(
            single_match(
                r"function Get-FixtureDestination \{.*?ChildPath '([^']+)'",
                harness,
                "el destino simulado del fixture",
            ).replace("\\", "/")
        )
        fixture_files = re.findall(
            r"Join-Path \$bundleRoot '([^']+)'",
            between(harness, "function New-FixtureSource", "function Get-PayloadInventory"),
        )
        self.assertTrue(fixture_files, "el fixture debe declarar archivos reales")

        transaction_prefix = single_match(
            r"ChildPath \('(\.mensorcad-tx-)' \+ \[guid\]::NewGuid\(\)",
            self.installer,
            "el prefijo de la transaccion del motor",
        )
        staging_folder = single_match(
            r"\$stagingRoot = Join-Path -Path \$transactionRoot -ChildPath '([^']+)'",
            self.installer,
            "la carpeta de etapa del motor",
        )
        bundle_folder = single_match(
            r"\$script:MensorCadBundleFolderName = '([^']+)'",
            self.installer,
            "el nombre de la carpeta del paquete",
        )

        test_root = WINDOWS_TEMP_BASE / (test_root_prefix + FIXTURE_GUID)
        case_root = test_root / (case_root_prefix + FIXTURE_GUID)
        staged_root = (
            case_root
            / fixture_destination.parent
            / (transaction_prefix + FIXTURE_GUID)
            / staging_folder
            / bundle_folder
        )
        for relative in fixture_files:
            staged_path = staged_root / PureWindowsPath(relative.replace("\\", "/"))
            measured = len(str(staged_path))
            self.assertLess(
                measured,
                WINDOWS_MAX_PATH,
                (
                    "la ruta transitoria del fixture supera el limite de Windows "
                    f"({measured} >= {WINDOWS_MAX_PATH}): {staged_path}"
                ),
            )

        # Los nombres compactos deben usarse en todos los puntos del fixture,
        # incluida la ruta del junction del caso de reanalisis del padre.
        self.assertEqual(
            [],
            [nombre for nombre in ("ProgramFilesLike", "MensorCadInstallerTests-") if nombre in harness],
            "quedan prefijos de fixture largos en las pruebas locales",
        )

    def test_local_suite_bat_runner_uses_owned_local_working_directory(self) -> None:
        # CMD no acepta una ruta UNC como directorio actual: al lanzar el BAT
        # copiado desde una ruta UNC, cmd.exe escribe un aviso en stderr y la
        # asercion de stderr vacio falla. El lanzador debe fijar como directorio
        # de trabajo la carpeta local del propio BAT copiado, sin cambiar el CWD
        # del usuario ni filtrar el aviso.
        harness = self.windows_tests
        runner = between(harness, "function Invoke-BatCommand", "function Copy-InstallerTo")
        self.assertIn("-WorkingDirectory", runner, "el lanzador del BAT debe fijar el directorio de trabajo")
        self.assertIn(
            "Split-Path -Parent $BatPath",
            runner,
            "el directorio de trabajo debe derivarse del BAT copiado, no heredarse del invocador",
        )
        self.assertIn("-WorkingDirectory $workingDirectory", runner)
        self.assertLess(
            runner.index("Split-Path -Parent $BatPath"),
            runner.index("Start-Process"),
            "el directorio local debe conocerse antes de lanzar cmd.exe",
        )
        self.assertIn("RedirectStandardOutput", runner)
        self.assertIn("RedirectStandardError", runner)
        for forbidden in ("Set-Location", "Push-Location", "chdir", "SystemRoot"):
            self.assertNotIn(
                forbidden,
                runner,
                f"el lanzador no debe inventar un CWD alternativo para cmd.exe: {forbidden}",
            )
        # Tampoco puede filtrar ni silenciar el aviso real de cmd.exe.
        for forbidden in ("Where-Object", "Select-String", "2>&1", "2>$null"):
            self.assertNotIn(
                forbidden,
                runner,
                f"el lanzador no debe filtrar los flujos del BAT: {forbidden}",
            )

        caso = between(
            harness,
            "Test-Case 'El BAT reenvia opciones",
            "Test-Case 'La entrada publica instala",
        )
        self.assertIn("Assert-Equal '' ($help.Stderr.Trim())", caso)
        self.assertIn("Assert-Equal 0 $help.ExitCode", caso)
        self.assertIn("Assert-Equal 1 $failure.ExitCode", caso)

    def test_local_suite_link_cleanup_is_link_only_and_never_prompts(self) -> None:
        # Remove-Item sin -Recurse sobre un junction con elementos secundarios
        # pide confirmacion interactiva y puede recorrer el destino. La limpieza
        # debe borrar solo la entrada del enlace con primitivas de .NET y dejar
        # intacto el fixture externo.
        harness = self.windows_tests
        self.assertIn("function Remove-FixtureLink", harness, "falta el eliminador seguro de enlaces")
        helper = between(harness, "function Remove-FixtureLink", "function Write-FixtureFile")
        self.assertIn("ReparsePoint", helper, "la limpieza debe verificar que sea un punto de reanalisis")
        self.assertIn("[System.IO.Directory]::Delete(", helper)
        self.assertIn("$false)", helper, "el borrado de un junction debe ser no recursivo")
        self.assertIn("[System.IO.File]::Delete(", helper)
        self.assertIn("Test-Path -LiteralPath $Path", helper, "un enlace ausente debe ser un no-op")
        self.assertIn(
            "DirectorySeparatorChar",
            helper,
            "el limite del fixture debe compararse como directorio, no como prefijo de texto",
        )
        for forbidden in ("Remove-Item", "Get-ChildItem", "-Recurse", "RemoveDirectory", "rd /s", "del /f"):
            self.assertNotIn(forbidden, helper, f"la limpieza del enlace no debe recorrer ni borrar de mas: {forbidden}")

        self.assertNotIn(
            "Remove-Item -LiteralPath $linkPath",
            harness,
            "la limpieza de enlaces no debe usar Remove-Item",
        )
        self.assertGreaterEqual(
            harness.count("Remove-FixtureLink -Path"),
            3,
            "ambos casos de enlace deben limpiar con el eliminador seguro",
        )

        origen = between(
            harness,
            "Test-Case 'Rechaza puntos de reanalisis",
            "Test-Case 'Rechaza un host de 32 bits",
        )
        self.assertIn("Remove-FixtureLink -Path $linkPath", origen)
        self.assertIn("debe eliminar solo la entrada del enlace", origen)
        self.assertIn("no debe recorrer el destino del enlace", origen)

        padre = between(
            harness,
            "Test-Case 'Rechaza un destino bajo un padre con punto de reanalisis",
            "Test-Case 'Rechaza un destino existente no propio",
        )
        self.assertIn("Remove-FixtureLink -Path $linkPath", padre)
        self.assertIn("centinela fuera del enlace", padre)
        self.assertIn("no debe recorrer el destino del enlace", padre)

    def test_window_suite_bat_runner_uses_owned_local_working_directory(self) -> None:
        # El caso "El BAT marca el lanzamiento..." fallo en una ruta UNC porque
        # cmd.exe heredo el directorio actual del invocador. El lanzador de la
        # suite Window debe fijar -WorkingDirectory a la carpeta del propio BAT
        # copiado, sin cambiar el CWD del usuario ni filtrar el stderr.
        harness = self.window_tests
        runner = between(harness, "function Invoke-BatCommand", "function Invoke-CliCapturingError")
        self.assertIn("-WorkingDirectory", runner, "el lanzador del BAT debe fijar el directorio de trabajo")
        self.assertIn(
            "Split-Path -Parent $BatPath",
            runner,
            "el directorio de trabajo debe derivarse del BAT copiado, no heredarse del invocador",
        )
        self.assertIn("-WorkingDirectory $workingDirectory", runner)
        self.assertLess(
            runner.index("Split-Path -Parent $BatPath"),
            runner.index("Start-Process"),
            "el directorio local debe conocerse antes de lanzar cmd.exe",
        )
        for forbidden in ("Set-Location", "Push-Location", "chdir", "SystemRoot"):
            self.assertNotIn(
                forbidden,
                runner,
                f"el lanzador no debe cambiar el CWD del invocador: {forbidden}",
            )
        for forbidden in ("Where-Object", "Select-String", "2>&1", "2>$null"):
            self.assertNotIn(
                forbidden,
                runner,
                f"el lanzador no debe filtrar los flujos del BAT: {forbidden}",
            )

        caso = between(
            harness,
            "Test-Case 'El BAT marca el lanzamiento",
            "Test-Case 'El instalador elevado real no retiene",
        )
        self.assertIn("Assert-Equal '' $handoff.Stderr.Trim()", caso)



if __name__ == "__main__":
    unittest.main()
