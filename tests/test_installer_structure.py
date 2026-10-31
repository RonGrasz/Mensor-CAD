"""Comprobaciones estructurales del instalador local de MensorCAD.

Estas pruebas NO validan el comportamiento funcional en Windows. Verifican que
los archivos del instalador existen, conservan la interfaz acordada y no
introducen cambios globales peligrosos. La validacion funcional real vive en
tests/Test-Installer.ps1 y requiere Windows PowerShell 5.1.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "Install-MensorCAD.ps1"
BAT = ROOT / "Instalar.bat"
WINDOWS_TESTS = ROOT / "tests" / "Test-Installer.ps1"
WINDOW_TESTS = ROOT / "tests" / "Test-InstallerWindow.ps1"
DOCS = ROOT / "docs" / "local-installer.md"

REMOTE_SECTION_MARKER = "# Entrada remota: descarga y verificacion de releases de GitHub"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


class InstallerStructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.installer = read_text(INSTALLER)
        cls.bat = read_text(BAT)
        cls.windows_tests = read_text(WINDOWS_TESTS)
        cls.window_tests = read_text(WINDOW_TESTS)
        cls.docs = read_text(DOCS)
        cls.top_param_block = cls._top_param_block(cls.installer)
        cls.local_branch, _, cls.remote_branch = cls.installer.partition(REMOTE_SECTION_MARKER)

    @staticmethod
    def _top_param_block(text: str) -> str:
        start = text.index("param(")
        end = text.index("\n)", start)
        return text[start : end + 2]

    def test_expected_files_exist(self) -> None:
        for path in (INSTALLER, BAT, WINDOWS_TESTS, WINDOW_TESTS, DOCS):
            self.assertTrue(path.is_file(), f"falta {path}")

    def test_public_switches_are_limited_to_documented_interface(self) -> None:
        block = self.top_param_block
        for switch in ("$Uninstall", "$NoAnimation", "$Help", "$FromRelease", "$Version", "$ElevatedProcess", "$HoldResult"):
            self.assertIn(switch, block)
        self.assertNotIn("Destination", block)
        self.assertNotIn("SourceRoot", block)
        self.assertNotIn("Url", block)
        self.assertIn("-HoldResult", self.docs, "la documentacion local debe mencionar -HoldResult")
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

    def test_docs_document_interface_marker_and_limits(self) -> None:
        for fragment in (
            "-Uninstall",
            "-NoAnimation",
            "-Help",
            "Program Files",
            "MensorCAD.bundle",
            "bundle.sha256",
            ".mensorcad-install.json",
            "mensorcad-bundle-marker",
            "sourceManifestSha256",
            "UAC",
            "ExecutionPolicy Bypass",
            "Windows PowerShell 5.1",
            "Test-Installer.ps1",
            "FromRelease",
            "64 bits",
            "Sysnative",
            "no autentica",
        ):
            self.assertIn(fragment, self.docs, f"la documentacion no menciona {fragment}")
        self.assertIn("instalación", self.docs)  # documento en espanol

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
        ):
            self.assertIn(scenario, text, f"las pruebas de ventana no cubren: {scenario}")

    def test_docs_document_single_window_limits_and_manual_proof(self) -> None:
        for fragment in (
            "Ventana única",
            "UAC",
            "Windows Terminal",
            "closeOnExit",
            "fail-open",
            "prueba visual",
            "Test-InstallerWindow.ps1",
            "MENSORCAD_BAT_LAUNCHER",
            "HoldResult",
            "continua en la ventana elevada",
            "sentinel privado",
            "75",
        ):
            self.assertIn(fragment, self.docs, f"la documentacion no menciona {fragment}")
        self.assertNotIn("oculta la consola", self.docs, "la documentacion no debe describir la ruta obsoleta")


if __name__ == "__main__":
    unittest.main()
