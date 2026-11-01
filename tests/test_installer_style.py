"""Contrato estructural de la presentacion de consola del instalador.

Estas pruebas NO validan como se ve una terminal real. Fijan el contrato de la
capa de presentacion jade (artboard design/cli-installer/01-jade-banner.html):
banner de bloques, encabezado compacto, colores con respaldo, fases con pistas,
resultados distintos por estado y texto plano intacto byte a byte.

La verificacion funcional vive en tests/Test-InstallerStyle.ps1 y requiere
Windows PowerShell 5.1; la prueba visual humana en Windows sigue pendiente.
"""

from __future__ import annotations

import json
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "Install-MensorCAD.ps1"
STYLE_TESTS = ROOT / "tests" / "Test-InstallerStyle.ps1"
DOCS = ROOT / "docs" / "local-installer.md"
ARTBOARD = ROOT / "design" / "cli-installer" / "01-jade-banner.html"
DESIGN_MANIFEST = ROOT / "design" / "cli-installer" / "design.json"

# Banner de 5 filas: MENSOR (37 columnas, con separadores) y CAD (17).
BANNER_ROWS = [
    ("█   █ █████ █   █  ████  ███  ████   ", " ████  ███  ████ "),
    ("██ ██ █     ██  █ █     █   █ █   █  ", "█     █   █ █   █"),
    ("█ █ █ ████  █ █ █  ███  █   █ ████   ", "█     █████ █   █"),
    ("█   █ █     █  ██     █ █   █ █  █   ", "█     █   █ █   █"),
    ("█   █ █████ █   █ ████   ███  █   █  ", " ████ █   █ ████ "),
]
BANNER_VISIBLE_WIDTH = 2 + 37 + 17
BANNER_MINIMUM_WIDTH = 58
FINAL_ACTION = "Todo listo. Abrí AutoCAD para empezar."


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def fin_de_linea_ps51_valido(raw: bytes) -> bool:
    """Acepta LF y CRLF; solo rechaza retornos de carro sueltos.

    Un checkout Windows (core.autocrlf=true) entrega los .ps1 con CRLF, y
    Windows PowerShell 5.1 acepta ambos fines de linea. Exigir LF forzaria a
    normalizar el arbol de trabajo en Windows, que no es responsabilidad de la
    prueba: alcanza con que no haya CR sin LF.
    """
    return b"\r" not in raw.replace(b"\r\n", b"")


class InstallerStyleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.installer = read_text(INSTALLER)
        cls.docs = read_text(DOCS)
        cls.artboard = read_text(ARTBOARD)
        cls.cli = cls.installer[cls.installer.index("function Invoke-MensorCadCli") :]

    def body(self, name: str) -> str:
        start = self.installer.index(f"function {name} {{")
        end = self.installer.index("\nfunction ", start + 1)
        return self.installer[start:end]

    @staticmethod
    def plain_branch(body: str) -> str:
        start = body.index("if ($script:MensorCadPlainMode) {")
        end = body.index("}", start)
        return body[start:end]

    def presentation_branch(self, body: str) -> str:
        plain = self.plain_branch(body)
        return body[body.index(plain) + len(plain) :]

    def test_banner_uses_five_spaced_rows_and_jade_mint_palette(self) -> None:
        banner = self.body("Write-MensorCadBanner")
        self.assertIn("$script:MensorCadBannerMinimumWidth", banner)
        for helper in (
            "Get-MensorCadConsoleWidth",
            "Get-MensorCadBannerGlyph",
            "Write-MensorCadCompactBanner",
            "Write-MensorCadToneLine",
            "Write-MensorCadReleaseVersionBadge",
        ):
            self.assertIn(helper, banner, f"el banner debe usar {helper}")

        self.assertEqual(5, self.installer.count("Jade = '█"), "el banner debe tener cinco filas de bloques")
        for jade, mint in BANNER_ROWS:
            self.assertIn(jade, self.installer, "falta una fila jade del banner")
            self.assertIn(mint, self.installer, "falta una fila mint del banner")
            self.assertEqual(37, len(jade), "MENSOR debe conservar un separador entre cada letra")
            self.assertEqual(17, len(mint))
        self.assertIn("param([switch]$ShowVersion)", banner)
        self.assertIn(f"$script:MensorCadBannerMinimumWidth = {BANNER_MINIMUM_WIDTH}", self.installer)
        self.assertEqual(56, BANNER_VISIBLE_WIDTH)

        ansi = self.body("Get-MensorCadAnsiSequence")
        for sequence in ("38;2;50;214;160", "38;2;150;234;211", "38;2;171;189;182"):
            self.assertIn(sequence, ansi, f"falta el color verdadero {sequence}")
        self.assertIn("$script:MensorCadAnsiReset", self.body("Format-MensorCadAnsiText"))
        self.assertIn("[0m", self.installer)

        colors = self.body("Get-MensorCadConsoleColor")
        for color in ("Green", "Cyan", "DarkGray", "Yellow", "Red"):
            self.assertIn(color, colors, f"falta el respaldo ConsoleColor {color}")

    def test_compact_banner_covers_narrow_and_unknown_width(self) -> None:
        width = self.body("Get-MensorCadConsoleWidth")
        self.assertIn("RawUI", width, "el ancho debe salir de RawUI")
        self.assertIn("return 0", width, "sin RawUI el ancho debe caer a un valor defensivo")

        banner = self.body("Write-MensorCadBanner")
        self.assertRegex(banner, r"-lt \$script:MensorCadBannerMinimumWidth")
        compact = self.body("Write-MensorCadCompactBanner")
        for fragment in ("'  MENSOR'", "'CAD'", "'  Instalador para AutoCAD'"):
            self.assertIn(fragment, compact, f"el encabezado compacto debe incluir {fragment}")
        self.assertIn(".Jade", compact + banner, "el compacto debe separar MENSOR y CAD por tono")
        self.assertNotIn("Tu proximo plano", self.installer, "la consigna debe eliminarse del instalador")
        self.assertIn("Vamos a preparar tus herramientas para AutoCAD.", banner)
        self.assertGreaterEqual(banner.count("Write-Host ''"), 4, "el banner debe tener filas en blanco reales")
        self.assertIn(
            "Write-MensorCadToneLine -Text '  INSTALADOR' -Tone 'muted'\n        Write-Host ''",
            banner,
            "debe haber una fila vacia entre el encabezado y los bloques",
        )
        self.assertIn(
            "}\n        Write-Host ''\n        Write-MensorCadToneLine -Text '  Vamos a preparar",
            banner,
            "debe haber una fila vacia entre los bloques y la introduccion",
        )

    def test_vt_probe_is_read_only_and_has_consolecolor_fallback(self) -> None:
        probe = self.body("Test-MensorCadVirtualTerminal")
        for fragment in ("IsOutputRedirected", "SupportsVirtualTerminal", "0x0004", "Get-MensorCadConsoleModeFlags"):
            self.assertIn(fragment, probe, f"la sonda VT debe considerar {fragment}")
        mode = self.body("Get-MensorCadConsoleModeFlags")
        self.assertIn("GetStdHandle", mode)
        self.assertIn("GetConsoleMode", mode)
        self.assertNotIn("SetConsoleMode", mode, "la sonda no debe habilitar VT")

        # Nunca se habilitan modos ni se tocan preferencias o la codificacion.
        for forbidden in (
            "SetConsoleMode",
            "SetConsoleTextAttribute",
            "VirtualTerminalLevel",
            "WT_SESSION",
            "[Console]::OutputEncoding =",
            "$Host.UI.RawUI.ForegroundColor",
            "chcp ",
        ):
            self.assertNotIn(forbidden, self.installer, f"la presentacion no debe tocar {forbidden}")

        glyph = self.body("Get-MensorCadBannerGlyph")
        self.assertIn("0x2588", glyph)
        self.assertIn("return '#'", glyph, "sin VT el banner debe caer a un glifo ASCII")

    def test_plain_mode_stays_byte_for_byte(self) -> None:
        self.assertIn("Write-Host 'MensorCAD - Instalador local para AutoCAD'", self.plain_branch(self.body("Write-MensorCadBanner")))
        self.assertIn("Write-Host $line", self.plain_branch(self.body("Write-MensorCadStep")))
        self.assertIn("Write-Host ('  ' + $Message)", self.plain_branch(self.body("Write-MensorCadInfo")))
        self.assertIn("Write-Host $Message", self.plain_branch(self.body("Write-MensorCadSuccess")))
        self.assertIn("Write-Host ('  ' + $Message)", self.plain_branch(self.body("Write-MensorCadActivity")))
        self.assertIn("Write-Host 'MensorCAD - Instalador local para AutoCAD'", self.body("Write-MensorCadUsage"))

        # Las pistas y la copia amigable solo existen en modo con color.
        self.assertNotIn("Hint", self.plain_branch(self.body("Write-MensorCadStep")))
        self.assertNotIn("Headline", self.plain_branch(self.body("Write-MensorCadSuccess")))
        self.assertNotIn("Guidance", self.plain_branch(self.body("Write-MensorCadFailure")))

    def test_success_outcomes_distinguish_install_update_unchanged_and_uninstall(self) -> None:
        success = self.body("Write-MensorCadSuccess")
        for parameter in ("Headline", "Detail", "NextAction", "Metadata"):
            self.assertIn(parameter, success, f"el exito debe aceptar {parameter}")
        presentation = self.presentation_branch(success)
        self.assertIn("Write-MensorCadResultRule", presentation)
        self.assertLess(
            presentation.index("Write-MensorCadResultRule"),
            presentation.index("Write-MensorCadToneLine -Text ('  ' + $headlineText)"),
            "la regla debe ir antes del titulo del resultado",
        )
        self.assertLess(
            presentation.index("$Metadata"),
            presentation.index("$NextAction"),
            "la accion final debe quedar despues del metadato tecnico",
        )
        self.assertGreaterEqual(presentation.count("Write-Host ''"), 5, "el resultado necesita padding real")
        self.assertIn("Write-MensorCadToneLine -Text ('  ' + $Metadata) -Tone 'muted'", presentation)
        self.assertNotIn(
            "$Message",
            presentation,
            "el modo con color no debe repetir la frase tecnica completa del exito",
        )

        for headline in (
            "-Headline 'MensorCAD se desinstaló.'",
            "-Headline 'MensorCAD ya estaba actualizado.'",
            "-Headline 'MensorCAD se actualizó.'",
            "-Headline 'MensorCAD está instalado.'",
        ):
            self.assertIn(headline, self.cli, f"falta el resultado {headline}")

        self.assertGreaterEqual(
            self.cli.count("-Metadata ("),
            4,
            "cada resultado debe aportar ubicacion o conteo como metadato separado",
        )
        for metadata in (
            "-Metadata ('Ubicación: {0} - Archivos: {1}' -f $result.DestinationRoot, $result.FileCount)",
            "-Metadata ('Ubicación: {0}' -f $result.DestinationRoot)",
            "-Metadata ('Archivos eliminados: {0}' -f $result.RemovedFiles)",
        ):
            self.assertIn(metadata, self.cli, f"falta el metadato {metadata}")

        uninstall = self.cli[
            self.cli.index("Write-MensorCadSuccess -Message ('MensorCAD se desinstalo correctamente") :
            self.cli.index("return 0", self.cli.index("Write-MensorCadSuccess -Message ('MensorCAD se desinstalo correctamente"))
        ]
        self.assertIn("desinstaló", uninstall)
        self.assertNotIn("se instalo", uninstall, "la desinstalacion no debe sugerir una instalacion")
        self.assertNotIn("instalado correctamente", uninstall)
        self.assertNotIn("Abre AutoCAD", uninstall, "desinstalar no debe pedir abrir AutoCAD")
        self.assertIn("Puedes volver a instalar cuando quieras.", uninstall)

    def test_result_rule_is_bounded_and_has_ascii_fallback(self) -> None:
        rule = self.body("Write-MensorCadResultRule")
        plain = self.plain_branch(rule)
        self.assertIn("return", plain, "el modo plano no debe dibujar la regla")
        self.assertIn("Get-MensorCadConsoleWidth", rule)
        self.assertIn("$width -lt 5", rule)
        self.assertIn("$length = $width - 3", rule)
        self.assertIn("$length -gt 48", rule)
        self.assertIn("0x2500", rule)
        self.assertIn("('-' * $length)", rule)
        self.assertIn("-ForegroundColor DarkGray", rule)
        self.assertNotIn("Clear-Host", rule)
        self.assertNotIn("`r", rule)
        self.assertNotIn("Start-Sleep", self.installer)

    def test_phases_are_numbered_with_hints_and_real_per_phase_progress(self) -> None:
        progress = self.body("Write-MensorCadProgress")
        for fragment in ("$Current", "$Total", "$Path", "'{0} {1}/{2}: {3}'"):
            self.assertIn(fragment, progress)
        self.assertNotIn("%", progress, "no debe inventarse un porcentaje global")

        for hint in (
            "Comprobamos que los archivos estén completos.",
            "Volvemos a revisar el paquete después del permiso.",
            "Preparamos tus herramientas para AutoCAD.",
            "Eliminamos solo los archivos registrados por MensorCAD.",
            "elige Sí para continuar.",
        ):
            self.assertIn(hint, self.installer, f"falta la pista {hint}")
        self.assertGreaterEqual(
            self.cli.count("Write-MensorCadStep -Number"),
            7,
            "las fases de instalacion y desinstalacion deben conservar su numeracion",
        )
        step = self.body("Write-MensorCadStep")
        self.assertIn("[{0}/{1}]", step)
        self.assertIn("$Hint", step)
        self.assertIn("$Title", step)
        self.assertIn("$titleText", step)
        self.assertNotIn("Title", self.plain_branch(step), "el titulo amigable no debe verse en modo plano")
        for title in (
            "-Title 'Revisando el paquete'",
            "-Title 'Permiso de Windows'",
            "-Title 'Última comprobación'",
            "-Title 'Instalando MensorCAD'",
        ):
            self.assertIn(title, self.cli, f"falta el titulo interactivo {title}")
        for message in (
            "-Message 'Validando el paquete local antes de pedir permisos'",
            "-Message 'Comprobando permisos de administrador'",
            "-Message 'Revalidando el paquete despues de la elevacion'",
            "-Message 'Instalando en Program Files'",
        ):
            self.assertIn(message, self.cli, f"el texto plano debe conservar {message}")

    def test_autocad_open_failure_keeps_stderr_and_exit_and_adds_guidance(self) -> None:
        failure = self.body("Write-MensorCadFailure")
        self.assertEqual(
            1,
            failure.count("[Console]::Error.WriteLine('ERROR: ' + $Message)"),
            "stderr conserva un unico prefijo ERROR:",
        )
        self.assertNotIn("Write-Error", failure, "el error no debe duplicarse en otro flujo")
        stderr_at = failure.index("[Console]::Error.WriteLine")
        plain_at = failure.index("if ($script:MensorCadPlainMode)")
        self.assertLess(stderr_at, plain_at, "el error va a stderr antes de cualquier pista")

        catch = self.cli[self.cli.index("    catch {"):]
        self.assertIn("$_.Exception.Message -match 'AutoCAD esta en ejecucion'", catch)
        self.assertIn("Cierra AutoCAD para continuar.", catch)
        self.assertIn("Desinstalar.bat", catch)
        self.assertIn("Instalar.bat", catch)
        self.assertIn("return 1", catch)

    def test_activity_bounds_text_and_clearing_to_known_width(self) -> None:
        activity = self.body("Write-MensorCadActivity")
        after_plain = activity[activity.index("$frames = @('|', '/', '-', '\\')") :]
        self.assertIn("Get-MensorCadConsoleWidth", after_plain)
        self.assertIn("'...'", after_plain, "el texto largo debe recortarse con puntos suspensivos")
        self.assertIn("$maxVisible = $width - 1", after_plain)
        # La linea literal que fija la suite estructural existente se conserva.
        self.assertIn(
            "$padding = [Math]::Max(0, [int]$script:MensorCadActivityLength - $line.Length)",
            after_plain,
        )
        self.assertIn(
            "$padding = [Math]::Min($padding, [Math]::Max(0, $maxVisible - $line.Length))",
            after_plain,
            "el relleno de limpieza tambien debe caber en el ancho conocido",
        )
        self.assertIn("(' ' * $padding)", after_plain)
        self.assertIn("`r", after_plain)
        self.assertLess(
            after_plain.index("$padding = [Math]::Min"),
            after_plain.index("Format-MensorCadAnsiText"),
            "los escapes ANSI se agregan despues de calcular las celdas visibles",
        )
        self.assertNotIn("Start-Sleep", self.installer)

    def test_activity_uses_static_line_for_tiny_or_unknown_width(self) -> None:
        activity = self.body("Write-MensorCadActivity")
        self.assertIn("if ($width -lt 5) {", activity, "los anchos 0-4 deben tener un camino defensivo")
        self.assertIn("$script:MensorCadActivityStatic", activity)
        static_branch = activity[
            activity.index("if ($width -lt 5) {") : activity.index("$maxVisible = $width - 1")
        ]
        self.assertIn("$script:MensorCadActivityStatic = $true", static_branch)
        self.assertNotIn("`r", static_branch, "la actividad estatica no debe redibujar con retorno de carro")
        self.assertIn("Write-MensorCadToneLine -Text $line -Tone 'mint'", static_branch)
        self.assertIn("Write-Host $line -ForegroundColor DarkCyan", static_branch)
        self.assertIn(
            "no se puede garantizar",
            activity,
            "sin ancho conocido no debe prometerse que no habra wrap",
        )
        complete = self.body("Complete-MensorCadActivity")
        self.assertIn("$script:MensorCadActivityStatic = $false", complete, "completar debe rearmar la actividad")

    def test_embedded_release_version_has_no_runtime_reads(self) -> None:
        marker = "__MENSORCAD_RELEASE_VERSION__"
        self.assertEqual(1, self.installer.count(marker), "debe existir un solo marcador de version")
        self.assertIn(
            "$script:MensorCadReleaseVersion = '" + marker + "'",
            self.installer,
            "la plantilla debe declarar el marcador en una asignacion unica",
        )
        self.assertNotIn("function Get-MensorCadSourceVersion", self.installer)
        self.assertNotIn("Write-MensorCadSourceVersionBadge", self.installer)
        self.assertNotIn("MensorCadVersionFileName", self.installer)
        self.assertNotIn("MensorCadVersionMaxBytes", self.installer)
        self.assertNotIn("0.1.0", self.installer, "la version de produccion no debe quedar hardcodeada")

        region = self.installer[
            self.installer.index("function Get-MensorCadDisplayVersion") :
            self.installer.index("function Write-MensorCadCompactBanner")
        ]
        for forbidden in (
            "PackageContents",
            "XmlReader",
            "Get-Item",
            "Get-Content",
            "SourceRoot",
            "MensorCadBundleFolderName",
            "File]::Open",
            "Assert-MensorCadNoReparseInPath",
            "Invoke-WebRequest",
        ):
            self.assertNotIn(forbidden, region, f"la version no debe consultar {forbidden}")

        embedded = self.body("Get-MensorCadEmbeddedVersion")
        self.assertIn("$script:MensorCadReleaseVersion", embedded)
        self.assertIn("notmatch", embedded)
        self.assertIn("[0-9]", embedded)

        release_badge = self.body("Write-MensorCadReleaseVersionBadge")
        plain = self.plain_branch(release_badge)
        self.assertIn("return", plain, "el modo plano no debe dibujar el badge")
        self.assertIn("Get-MensorCadEmbeddedVersion", release_badge)
        self.assertIn("Write-MensorCadVersionBadge -Development", release_badge)

        badge = self.body("Write-MensorCadVersionBadge")
        for fragment in (
            "[switch]$Development",
            "desarrollo",
            "48;2;50;214;160",
            "38;2;9;14;13",
            "$script:MensorCadAnsiReset",
            "-BackgroundColor Green",
            "-ForegroundColor Black",
            "Get-MensorCadConsoleWidth",
            "versión no disponible",
            "MensorCAD",
        ):
            self.assertIn(fragment, badge, f"el badge debe incluir {fragment}")
        self.assertIn("$script:MensorCadPlainMode", badge)

    def test_completion_marks_only_real_success(self) -> None:
        complete = self.body("Complete-MensorCadActivity")
        self.assertIn("[switch]$Success", complete)
        self.assertIn("[string]$Text", complete)
        self.assertIn("if (-not $Success) {", complete)
        self.assertIn("Write-Host ''", complete, "el completado neutral conserva el salto de linea")
        self.assertIn("$width -lt 5", complete, "el completado debe tener un camino diminuto/desconocido")
        self.assertIn("$maxVisible = $width - 1", complete)
        self.assertIn(
            "$padding = [Math]::Min($padding, [Math]::Max(0, $maxVisible - $line.Length))",
            complete,
            "el texto de cierre y el relleno deben caber en el ancho",
        )
        self.assertIn("$script:MensorCadActivityLength = 0", complete)
        self.assertIn("$script:MensorCadActivityStatic = $false", complete)

        glyph = self.body("Get-MensorCadCompletionGlyph")
        self.assertIn("0x2713", glyph)
        self.assertIn("[OK]", glyph)

        wait = self.body("Wait-MensorCadRemoteChild")
        self.assertNotIn("-Success", wait, "la espera no conoce el estado final y no debe pintar exito")
        catch = self.cli[self.cli.index("    catch {") :]
        self.assertNotIn("-Success", catch, "el catch nunca debe pintar exito")

        permissions = self.cli[
            self.cli.index("Write-MensorCadStep -Number 2 -Total 4") :
            self.cli.index("Write-MensorCadStep -Number 3 -Total 4")
        ]
        self.assertLess(
            permissions.index("return (Invoke-MensorCadElevatedSelf"),
            permissions.index("Complete-MensorCadActivity -Success -Text 'Permisos listos'"),
            "el permiso solo se completa cuando ya es administrador, no al lanzar UAC",
        )

        remote = self.body("Invoke-MensorCadRemoteInstall")
        self.assertIn("if ($child.ExitCode -eq 0) {", remote)
        self.assertLess(
            remote.index("if ($child.ExitCode -eq 0) {"),
            remote.index("Complete-MensorCadActivity -Success -Text 'Instalación remota completada'"),
            "el hijo remoto solo puede completar con exito si su codigo es 0",
        )
        self.assertIn("Complete-MensorCadActivity -Success -Text 'Paquete validado'", self.cli)
        self.assertIn("Complete-MensorCadActivity -Success -Text 'Paquete revalidado'", self.cli)
        self.assertIn("Complete-MensorCadActivity -Success -Text 'MensorCAD instalado'", self.cli)
        self.assertIn("Complete-MensorCadActivity -Success -Text 'MensorCAD desinstalado'", self.cli)

    def test_final_action_accents_and_single_interactive_instruction(self) -> None:
        self.assertEqual(1, self.installer.count(FINAL_ACTION), "la accion final debe definirse una sola vez")
        self.assertIn("$script:MensorCadAutoCadNextAction = '" + FINAL_ACTION + "'", self.installer)
        self.assertEqual(
            3,
            self.cli.count("-NextAction $script:MensorCadAutoCadNextAction"),
            "instalar, actualizar y sin cambios cierran con la misma accion final",
        )
        self.assertIn("-NextAction 'Puedes volver a instalar cuando quieras.'", self.cli)

        presentation = self.presentation_branch(self.body("Write-MensorCadSuccess"))
        self.assertLess(
            presentation.index("$Metadata"),
            presentation.index("$NextAction"),
            "la accion final debe ser la ultima linea del exito",
        )

        for instruction in (
            "Abra AutoCAD para cargar el bundle instalado.",
            "Recuerde abrir AutoCAD para cargar el bundle instalado.",
        ):
            index = self.installer.index(instruction)
            preceding = self.installer[max(0, index - 400) : index]
            self.assertIn(
                "if ($script:MensorCadPlainMode)",
                preceding,
                f"la instruccion duplicada debe quedar solo en modo plano: {instruction}",
            )

        for fragment in (
            "versión",
            "Ubicación",
            "después",
            "Sí",
            "operación",
            "estén",
            "ciérralo",
            "instalación",
            "se actualizó",
            "está instalado",
        ):
            self.assertIn(fragment, self.installer, f"la copia nueva debe corregir la tilde: {fragment}")

        # Los mensajes tecnicos antiguos siguen sin tildes y sin cambios.
        for legacy in (
            "-Message 'Validando el paquete local antes de pedir permisos'",
            "-Message 'Comprobando permisos de administrador'",
            "-Message 'Revalidando el paquete despues de la elevacion'",
            "-Message 'Instalando en Program Files'",
            "AutoCAD esta en ejecucion",
        ):
            self.assertIn(legacy, self.installer, f"el texto plano no debe cambiar: {legacy}")

    def test_remote_and_uninstall_version_scopes(self) -> None:
        self.assertIn("if ($FromRelease -or $Uninstall) {\n                Write-MensorCadBanner", self.cli)
        self.assertIn("Write-MensorCadBanner -ShowVersion", self.cli)
        self.assertNotIn("Write-MensorCadBanner -SourceRoot", self.cli)

        remote = self.body("Invoke-MensorCadRemoteInstall")
        self.assertIn("Write-MensorCadVersionBadge -Label 'MensorCAD release' -Version $tag", remote)
        self.assertLess(
            remote.index("= Resolve-MensorCadReleaseTag"),
            remote.index("Write-MensorCadVersionBadge -Label 'MensorCAD release' -Version $tag"),
            "el badge remoto debe esperar al tag resuelto",
        )
        self.assertNotIn("Write-MensorCadReleaseVersionBadge", remote, "el bootstrap remoto no debe mostrar su version local")

        uninstall = self.cli[
            self.cli.index("if ($Uninstall) {") : self.cli.index("$progressCallback =")
        ]
        self.assertNotIn("VersionBadge", uninstall, "la desinstalacion no debe mostrar version de instalacion")

    def test_artboard_polish_is_synced_with_the_installer(self) -> None:
        artboard = self.artboard
        self.assertNotIn("Tu próximo plano", artboard, "la consigna debe desaparecer del artboard")
        self.assertNotIn("Tu proximo plano", artboard)
        for jade, mint in BANNER_ROWS:
            self.assertIn(jade.rstrip(), artboard, "falta una fila jade del artboard")
            self.assertIn(mint, artboard, "falta una fila mint del artboard")
        for fragment in (
            "version-badge",
            "Versión de ejemplo",
            "0.1.0",
            "MensorCAD",
            FINAL_ACTION,
            "✓",
            "result-rule",
            "Sin color",
            "Reproducir progreso",
            "prefers-reduced-motion",
        ):
            self.assertIn(fragment, artboard, f"el artboard debe conservar {fragment}")
        self.assertNotIn("http://", artboard)
        self.assertNotIn("https://", artboard)
        self.assertIn("#32d6a0", artboard)
        self.assertIn("#0a1010", artboard)

        self.assertEqual(2, artboard.count('class="logo-gap"'), "el artboard debe tener padding arriba y abajo de los bloques")

        parser = HTMLParser()
        parser.feed(artboard)
        parser.close()
        self.assertEqual(1, artboard.count("<style>"), "el artboard debe seguir autocontenido")
        self.assertEqual(1, artboard.count("<script>"), "el artboard debe seguir autocontenido")

        manifest = json.loads(DESIGN_MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual("01-jade-banner.html", manifest["artboards"][0]["file"])
        self.assertEqual(3, len(manifest["artboards"]), "las otras alternativas deben conservarse")
        self.assertIn("compacto", manifest["artboards"][0]["tradeoff"])


    def test_style_suite_checks_the_original_vt_probe_functionally(self) -> None:
        style_tests = read_text(STYLE_TESTS)
        for fragment in (
            "$script:OriginalFunctions['Test-MensorCadVirtualTerminal']",
            "-RedirectProbe",
            "-HostProbe",
            "-ModeProbe",
            "$script:VtProbeResult",
            "SupportsVirtualTerminal",
            "[uint32]4",
        ):
            self.assertIn(fragment, style_tests, f"la suite funcional debe probar la sonda VT real: {fragment}")

    def test_style_suite_defines_cli_capture_helper_with_console_error_restore(self) -> None:
        style_tests = read_text(STYLE_TESTS)
        self.assertIn(
            "function Invoke-CliCaptureAll",
            style_tests,
            "la suite funcional debe definir el helper de captura CLI",
        )
        helper_start = style_tests.index("function Invoke-CliCaptureAll")
        next_function = style_tests.find("\nfunction ", helper_start + 1)
        if next_function == -1:
            next_function = len(style_tests)
        helper_body = style_tests[helper_start:next_function]
        self.assertIn(
            "[Console]::SetError",
            helper_body,
            "el helper debe redirigir el escritor de error de consola",
        )
        self.assertIn("finally", helper_body, "el helper debe tener un bloque de restauracion")
        finally_at = helper_body.index("finally")
        self.assertIn(
            "[Console]::SetError",
            helper_body[finally_at:],
            "finally debe restaurar el escritor de error original",
        )
        # El bloque que ejecuta la accion no puede llamar a `$Action`: ese es el
        # nombre del parametro de Get-HostRecords, asi que por alcance dinamico
        # la referencia se resuelve al propio bloque y se invoca a si misma hasta
        # desbordar la pila. La accion se guarda con un nombre distinto.
        self.assertNotIn(
            "& $Action",
            helper_body,
            "el bloque capturado no debe llamar a $Action, que es el parametro de Get-HostRecords",
        )
        self.assertGreaterEqual(
            style_tests.count("Invoke-CliCaptureAll"),
            3,
            "el helper debe definirse y usarse en los casos de captura CLI",
        )

    def test_style_record_capture_preserves_single_elements_under_strict_mode(self) -> None:
        style_tests = read_text(STYLE_TESTS)
        start = style_tests.index("function Get-HostRecords")
        next_function = style_tests.find("\nfunction ", start + 1)
        if next_function == -1:
            next_function = len(style_tests)
        body = style_tests[start:next_function]
        self.assertIn(
            "return ,$records",
            body,
            "Get-HostRecords debe usar el operador coma para evitar desenrollado escalar",
        )
        for helper in ("Invoke-OriginalVtProbe", "Invoke-CliCaptureAll"):
            helper_start = style_tests.index("function " + helper)
            helper_next = style_tests.find("\nfunction ", helper_start + 1)
            if helper_next == -1:
                helper_next = len(style_tests)
            helper_body = style_tests[helper_start:helper_next]
            self.assertIn(
                "Get-HostRecords",
                helper_body,
                f"{helper} debe reutilizar el helper de captura para no desenrollar",
            )

    def test_docs_explain_presentation_and_its_fallbacks(self) -> None:
        for fragment in (
            "jade",
            "banner",
            "bloques",
            "compacto",
            "VT",
            "ANSI",
            "ConsoleColor",
            "58",
            "stderr",
            "estática",
            "títulos",
            "metadato",
            "versión",
            "badge",
            "manifiesto",
            "estamp",
            "plantilla",
            "desarrollo",
            "regla",
            "padding",
            "✓",
            "Todo listo",
            "compleción",
            "Test-InstallerStyle.ps1",
        ):
            self.assertIn(fragment, self.docs, f"la documentacion no describe {fragment}")
        self.assertIn("prueba visual", self.docs)
        self.assertIn("no demuestra el resultado visual", self.docs)

    def test_style_suite_and_installer_keep_windows_encoding(self) -> None:
        self.assertTrue(STYLE_TESTS.is_file(), "falta tests/Test-InstallerStyle.ps1")
        raw = STYLE_TESTS.read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), "las pruebas Windows deben usar UTF-8 con BOM")
        self.assertTrue(
            fin_de_linea_ps51_valido(raw),
            "el fin de linea debe ser LF o CRLF, sin CR sueltos",
        )
        installer_raw = INSTALLER.read_bytes()
        self.assertTrue(installer_raw.startswith(b"\xef\xbb\xbf"))
        self.assertTrue(
            fin_de_linea_ps51_valido(installer_raw),
            "el fin de linea del instalador debe ser LF o CRLF, sin CR sueltos",
        )

    def test_el_contrato_de_fin_de_linea_acepta_lf_y_crlf_y_rechaza_cr_suelto(self) -> None:
        # Windows PowerShell 5.1 acepta LF y CRLF, y un checkout Windows
        # (core.autocrlf=true) entrega los .ps1 con CRLF. La prueba solo debe
        # rechazar un CR suelto y seguir exigiendo el BOM UTF-8.
        bom = b"\xef\xbb\xbf"
        contenido = "#requires -Version 5.1\nWrite-Host 'estilo'\nexit 2\n"
        lf = bom + contenido.encode("utf-8")
        crlf = bom + contenido.replace("\n", "\r\n").encode("utf-8")
        for muestra in (lf, crlf):
            self.assertTrue(muestra.startswith(bom), "el BOM UTF-8 debe conservarse")
            self.assertTrue(
                fin_de_linea_ps51_valido(muestra),
                "fin de linea rechazado: {!r}".format(muestra[:40]),
            )
            self.assertTrue(muestra.endswith(b"\n"), "debe terminar con salto de linea")
            self.assertEqual(
                muestra.decode("utf-8-sig").replace("\r\n", "\n"),
                contenido,
                "aceptar CRLF no debe alterar el contenido de la prueba",
            )
        self.assertNotIn(b"\r", lf, "la variante LF no debe introducir CR")
        self.assertFalse(
            fin_de_linea_ps51_valido(bom + b"param()\rWrite-Host 'estilo'\n"),
            "un CR suelto no es un fin de linea valido",
        )

    def test_un_checkout_crlf_de_los_archivos_reales_sigue_siendo_valido(self) -> None:
        # Prueba determinista: convierte el contenido real a CRLF en memoria, sin
        # tocar los archivos del producto ni imponer gitattributes.
        bom = b"\xef\xbb\xbf"
        for path in (STYLE_TESTS, INSTALLER):
            raw = path.read_bytes()
            self.assertTrue(raw.startswith(bom), f"{path.name} debe usar UTF-8 con BOM")
            self.assertTrue(fin_de_linea_ps51_valido(raw), f"{path.name} debe usar LF o CRLF")
            crlf = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            self.assertTrue(crlf.startswith(bom), f"{path.name} conserva el BOM al pasar a CRLF")
            self.assertTrue(
                fin_de_linea_ps51_valido(crlf),
                f"{path.name} con CRLF debe ser valido: Windows PowerShell 5.1 lo acepta",
            )
            self.assertEqual(
                crlf.decode("utf-8-sig").replace("\r\n", "\n"),
                raw.decode("utf-8-sig").replace("\r\n", "\n"),
                f"el cambio de fin de linea no debe alterar {path.name}",
            )
            with self.subTest(archivo=path.name):
                self.assertFalse(
                    fin_de_linea_ps51_valido(crlf.replace(b"\r\n", b"\r", 1)),
                    f"{path.name} con CR suelto debe rechazarse",
                )


if __name__ == "__main__":
    unittest.main()
