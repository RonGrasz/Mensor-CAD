"""Contrato de distribucion del gestor ``mensorcad`` y de sus artefactos.

Estas pruebas leen texto y aplican expresiones regulares: NO ejecutan Python,
PowerShell ni GitHub Actions, NO construyen paquetes y NO demuestran que la
instalacion funcione. La ejecucion funcional con artefactos reales vive en
``tests/Test-CliDistribution.ps1`` y requiere Windows PowerShell 5.1. La
construccion en si se prueba en ``tests/test_build_bundle.py``.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DISTRIBUTION_TESTS = ROOT / "tests" / "Test-CliDistribution.ps1"
WORKFLOW = ROOT / ".github" / "workflows" / "build-bundle.yml"
README = ROOT / "README.md"
BUILD_DOCS = ROOT / "docs" / "build-bundle.md"
BUILDER = ROOT / "tools" / "build_bundle.py"

LATEST_COMMAND = (
    "irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/"
    "install.ps1' -ea Stop | iex"
)

NEW_ASSETS = ("MensorCAD-CLI.zip", "MensorCAD-CLI.zip.sha256")
WINDOWS_ASSETS = (
    "MensorCAD-Windows.zip",
    "MensorCAD-Windows.zip.sha256",
    "Install-MensorCAD.ps1",
    "install.ps1",
)
CI_SUITES = (
    "tests/Test-Manager.ps1",
    "tests/Test-CliBootstrap.ps1",
    "tests/Test-CliDistribution.ps1",
)
# Suites que quedan fuera de la gate obligatoria y se ejecutan a mano: siguen
# en el repositorio, pero no bloquean el empaquetado.
OPTIONAL_SUITES = (
    "tests/Test-Installer.ps1",
    "tests/Test-InstallerWindow.ps1",
    "tests/Test-InstallerStyle.ps1",
    "tests/Test-RemoteInstaller.ps1",
    "tests/Test-Bootstrap.ps1",
)
CRITICAL_PYTHON = ("test_build_bundle.py", "test_bootstrap_encoding.py")
MANAGER_COMMANDS = (
    "mensorcad install",
    "mensorcad update",
    "mensorcad uninstall",
    "mensorcad status",
    "mensorcad --help",
    "mensorcad --version",
)

# La suite funcional no puede escribir en el destino fijo, pedir UAC, descargar
# ni cerrar procesos: solo usa fixtures dentro del scratch ignorado.
FORBIDDEN_IN_SUITE = (
    "C:\\Program Files",
    "-Verb RunAs",
    "Start-Process",
    "Stop-Process",
    "api.github.com",
    "Set-ItemProperty",
    "New-ItemProperty",
    "setx",
    "git ",
    "Invoke-WebRequest",
    "Invoke-RestMethod",
)

STEP_START = re.compile(r"(?m)^\s{6}- name:\s*")


def read_text(path: Path) -> str:
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8-sig")


def fin_de_linea_ps51_valido(raw: bytes) -> bool:
    """Acepta LF y CRLF; solo rechaza retornos de carro sueltos."""
    return b"\r" not in raw.replace(b"\r\n", b"")


class DistributionSuiteStructureTests(unittest.TestCase):
    """Forma de la suite funcional; no sustituye a la ejecucion en Windows."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = DISTRIBUTION_TESTS.read_bytes() if DISTRIBUTION_TESTS.is_file() else b""
        cls.suite = read_text(DISTRIBUTION_TESTS)

    def test_la_suite_existe_y_es_ps51(self) -> None:
        self.assertTrue(DISTRIBUTION_TESTS.is_file(), f"falta {DISTRIBUTION_TESTS}")
        self.assertTrue(self.raw.startswith(b"\xef\xbb\xbf"), "falta el BOM UTF-8")
        self.assertTrue(fin_de_linea_ps51_valido(self.raw), "hay CR sueltos")
        self.assertTrue(self.raw.endswith(b"\n"), "falta el salto de linea final")
        self.assertIn("#requires -Version 5.1", self.suite)
        self.assertIn("exit 2", self.suite, "fuera de Windows la suite debe omitirse")

    def test_ejercita_los_artefactos_reales_y_no_copias(self) -> None:
        for fragmento in (
            "tools\\build_bundle.py",
            "MensorCAD-CLI.zip",
            "MensorCAD-Windows.zip",
            "bundle.sha256",
            "System.IO.Compression.ZipFile",
            "Get-FileHash",
            "Test-MensorCadSource",
            "Install-MensorCadBundle",
            "Uninstall-MensorCadBundle",
            "mensorcad.ps1",
            "mensorcad.cmd",
        ):
            self.assertIn(fragmento, self.suite, f"la suite no ejercita {fragmento}")

    def test_la_instalacion_es_aislada_y_no_pide_permisos(self) -> None:
        self.assertIn("odd\\artifacts\\persistent-cli\\distribution", self.suite)
        self.assertIn("$env:TEMP", self.suite)
        self.assertIn("GetFolderPath('ProgramFiles')", self.suite)
        # Un equipo con el complemento instalado no puede sufrir una
        # desinstalacion real (ni un UAC) durante la prueba.
        self.assertIn("OMITIDO", self.suite)
        for prohibido in FORBIDDEN_IN_SUITE:
            self.assertNotIn(
                prohibido,
                self.suite,
                f"la suite no puede usar ni escribir {prohibido}",
            )

    def test_mide_codigos_de_salida_y_salidas_exactas(self) -> None:
        for fragmento in (
            "Assert-Equal 0",
            "Assert-Equal 1",
            "Assert-Equal 2",
            "Assert-Empty",
            "actualizado",
            "sin cambios",
            "No se modific",
            "ENGINE-CLI-CALLED",
        ):
            self.assertIn(fragmento, self.suite, f"la suite no mide {fragmento}")

    def test_cubre_desinstalacion_sin_conexion_y_el_lanzador(self) -> None:
        self.assertIn("sin conexion", self.suite)
        self.assertIn("uninstall sin conexion", self.suite)
        self.assertIn("cmd.exe", self.suite)
        self.assertIn("el lanzador debe reenviar el codigo", self.suite)

    def test_normaliza_el_temp_con_prefijo_de_proveedor(self) -> None:
        # PowerShell devuelve TEMP con prefijo de proveedor cuando el repositorio
        # se abre por UNC; .NET no acepta ese prefijo.
        self.assertIn("Microsoft.PowerShell.Core\\FileSystem::", self.suite)
        self.assertIn("ConvertTo-PlainPath", self.suite)


    def test_la_suite_reutiliza_artefactos_ya_construidos(self) -> None:
        # S7: el CI construye una vez y la suite valida ese mismo dist sin
        # volver a ejecutar el constructor.
        self.assertIn("[string]$BuildDir", self.suite)
        self.assertIn("[string]$Version", self.suite)
        self.assertIn("ReusedArtifacts", self.suite)
        self.assertIn("reutilizan", self.suite)
        self.assertIn("No se reconstruye", self.suite)
        self.assertIn("ManifestVersion", self.suite)

    def test_cubre_la_ruta_local_con_los_artefactos_reales(self) -> None:
        # T2: la ruta -LocalZip del gestor se ejercita con los bytes construidos
        # y solo se sustituyen las costuras de aislamiento.
        for fragmento in (
            "Write-LocalRouteFixture",
            "Write-LocalChildWrapper",
            "Get-LocalRouteFixtureResult",
            "Open-MensorCadLocalPackage",
            "Invoke-MensorCadRemoteChild",
            "$script:LocalDestinationRoot",
            "mensorcad-local-",
            "payload|",
            "child|",
            "Get-ScratchLocalWorkspaces",
            "New-LegacyWindowsArchive",
            "$script:OlderRoot",
        ):
            self.assertIn(fragmento, self.suite, f"la suite no ejercita {fragmento}")

    def test_la_ruta_local_mide_rechazos_y_no_ejecuta_el_paquete(self) -> None:
        for fragmento in (
            "corresponde a",
            "Falta el archivo de verificacion",
            "no coincide con el archivo .sha256",
            "es anterior a la instalada",
            "Ya estás actualizado",
            "Complemento: no instalado",
            "siguen intactas",
            "sigue aceptandose",
        ):
            self.assertIn(fragmento, self.suite, f"la suite no mide {fragmento}")

    def test_la_ruta_local_no_toca_el_destino_real(self) -> None:
        # El aislamiento se demuestra con la raiz simulada, no con una promesa:
        # la suite compara el stdout con la carpeta Program Files real.
        self.assertIn("[Environment]::GetFolderPath('ProgramFiles')", self.suite)
        self.assertIn("$script:LocalDestinationRoot", self.suite)
        self.assertIn("$script:LocalRoot", self.suite)


class WorkflowDistributionTests(unittest.TestCase):
    """El CI debe ejecutar las suites nuevas y publicar los seis artefactos."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = read_text(WORKFLOW)

    def step_block(self, marker: str) -> str:
        start = self.workflow.find(marker)
        self.assertNotEqual(start, -1, f"falta el paso del workflow: {marker}")
        following = STEP_START.search(self.workflow, start + len(marker))
        end = following.start() if following else len(self.workflow)
        return self.workflow[start:end]

    def test_el_ci_ejecuta_solo_las_tres_suites_criticas(self) -> None:
        for suite in CI_SUITES:
            self.assertTrue((ROOT / suite).is_file(), f"falta {suite}")
            self.assertIn(suite, self.workflow, f"el CI no ejecuta {suite}")
        for label in (
            "Pruebas criticas del bootstrap del gestor",
            "Pruebas criticas del comando gestor",
            "Pruebas de distribucion con artefactos reales",
        ):
            block = self.step_block(label)
            self.assertIn("shell: powershell", block)
            self.assertIn("-NoProfile -NonInteractive -ExecutionPolicy Bypass", block)
            self.assertIn("if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }", block)
            self.assertNotIn("continue-on-error", block)
        for suite in OPTIONAL_SUITES:
            self.assertTrue((ROOT / suite).is_file(), f"falta la suite local {suite}")
            self.assertNotIn(
                suite, self.workflow, f"la suite opcional no debe gatear el CI: {suite}"
            )

    def test_el_ci_ejecuta_solo_las_suites_python_criticas(self) -> None:
        block = self.step_block("Pruebas criticas de Python")
        for suite in CRITICAL_PYTHON:
            self.assertIn(
                f'python -B -m unittest discover -s tests -p "{suite}" -v',
                block,
                f"el CI no ejecuta la suite critica {suite}",
            )
        self.assertNotIn(
            '-p "test_*.py"', block, "el CI no debe ejecutar el descubrimiento completo"
        )

    def test_el_ci_construye_una_vez_y_reutiliza_el_dist(self) -> None:
        self.assertEqual(
            self.workflow.count("python tools/build_bundle.py"),
            1,
            "el CI debe construir los artefactos una sola vez",
        )
        build = self.workflow.index("python tools/build_bundle.py")
        distribucion = self.workflow.index("tests/Test-CliDistribution.ps1")
        upload = self.workflow.index("actions/upload-artifact@")
        self.assertLess(build, distribucion, "la distribucion debe validar el dist construido")
        self.assertLess(distribucion, upload, "la validacion debe preceder a la subida")
        block = self.step_block("Pruebas de distribucion con artefactos reales")
        self.assertIn("-BuildDir dist", block)
        self.assertIn("-Version $version", block)
        self.assertNotIn("tools/build_bundle.py", block)

    def test_el_ci_publica_los_artefactos_del_gestor(self) -> None:
        block = self.step_block("actions/upload-artifact@")
        self.assertIn("if-no-files-found: error", block)
        rutas = [
            linea.strip()
            for linea in block.splitlines()
            if linea.strip().startswith("dist/")
        ]
        self.assertEqual(sorted(rutas), sorted([f"dist/{name}" for name in (*WINDOWS_ASSETS, *NEW_ASSETS)]))
        for asset in NEW_ASSETS:
            self.assertIn(asset, block, f"el CI no publica {asset}")

    def test_el_ci_sigue_sin_publicar_releases(self) -> None:
        for prohibido in (
            "gh release",
            "git push",
            "git tag",
            "upload-release-asset",
            "contents: write",
            "id-token: write",
        ):
            self.assertNotIn(prohibido, self.workflow)


class ReadmeDistributionTests(unittest.TestCase):
    """El README presenta el flujo de dos pasos como unica via de instalacion."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.readme = read_text(README)

    def section(self, heading: str) -> str:
        self.assertIn(heading, self.readme)
        start = self.readme.index(heading) + len(heading)
        following = re.search(r"(?m)^## ", self.readme[start:])
        end = start + following.start() if following else len(self.readme)
        return self.readme[start:end]

    def test_documenta_los_dos_pasos_y_los_comandos_del_gestor(self) -> None:
        section = self.section("## Instalación")
        for fragmento in ("Paso 1", "Paso 2", *MANAGER_COMMANDS):
            self.assertIn(fragmento, section, f"falta {fragmento}")
        self.assertIn("No instala nada automáticamente", section)
        self.assertLess(section.index("Paso 1"), section.index("Paso 2"), "el orden de los pasos debe respetarse")

    def test_el_paso_uno_publica_el_bootstrap_oficial(self) -> None:
        section = self.section("## Instalación")
        self.assertIn(LATEST_COMMAND, section, "el README debe publicar el comando del bootstrap")
        self.assertIn("repositorio oficial", section, "el README debe pedir verificar la URL")
        paso_uno = section[section.index("Paso 1") : section.index("Paso 2")]
        self.assertIn(LATEST_COMMAND, paso_uno, "el comando del bootstrap pertenece al paso 1")

    def test_el_paso_dos_instala_el_complemento_con_el_gestor(self) -> None:
        section = self.section("## Instalación")
        paso_dos = section[section.index("Paso 2") :]
        for fragmento in (
            "mensorcad install",
            "cerrá AutoCAD",
            "terminal nueva",
            "administrador",
            "%ProgramFiles%",
            "MCHELP",
        ):
            self.assertIn(fragmento, paso_dos, f"el paso 2 no documenta {fragmento}")

    def test_distingue_el_alcance_por_usuario_y_por_equipo(self) -> None:
        section = self.section("## Instalación")
        self.assertIn("por usuario", section)
        self.assertIn("por equipo", section)
        self.assertIn("PATH", section)
        self.assertIn("%LOCALAPPDATA%", section)
        self.assertIn("%ProgramFiles%", section)

    def test_no_recomienda_el_metodo_de_un_solo_paso(self) -> None:
        section = self.section("## Instalación")
        self.assertNotIn("La opción recomendada: descargar", self.readme, "el ZIP ya no es la via recomendada")
        self.assertNotIn("doble clic en **`Instalar.bat`**", self.readme, "el README no debe instruir la instalacion por ZIP")
        self.assertIn("Histórico", section, "el metodo anterior queda mencionado como historico")
        self.assertLess(
            section.index("Paso 1"),
            section.index("Histórico"),
            "el flujo de dos pasos debe preceder al historico",
        )

    def test_deriva_la_prueba_local_a_la_guia_del_gestor(self) -> None:
        # El README no documenta la ruta local: solo la nombra y enlaza la guia.
        section = self.section("## Instalación")
        self.assertEqual(1, self.readme.count("-LocalZip"), "la ruta local se menciona una sola vez")
        self.assertIn("-LocalZip", section)
        self.assertIn("docs/cli-bootstrap.md", section)
        self.assertIn("docs/cli-manager.md", section)
        for comando in ("dist\\MensorCAD-CLI.zip", "dist\\MensorCAD-Windows.zip"):
            self.assertNotIn(comando, self.readme, f"el README no debe documentar {comando}")

    def test_la_desinstalacion_conserva_el_gestor_y_tiene_respaldo_zip(self) -> None:
        section = self.section("## Desinstalar")
        self.assertIn("mensorcad uninstall", section)
        self.assertIn("sin conexión", section)
        self.assertIn("conserva el comando gestor", section)
        self.assertIn("Desinstalar.bat", section)
        self.assertIn("instalaciones viejas", section)

    def test_la_actualizacion_no_baja_de_version(self) -> None:
        section = self.section("## Actualizar")
        self.assertIn("mensorcad update", section)
        self.assertIn("Ya estás actualizado", section)
        self.assertIn("nunca baja de versión", section.lower())


class BuildDocsDistributionTests(unittest.TestCase):
    """La guia del constructor debe describir las salidas nuevas."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.docs = read_text(BUILD_DOCS)
        cls.docs_flat = re.sub(r"\s+", " ", cls.docs)
        cls.builder = read_text(BUILDER)

    def test_la_guia_existe_y_documenta_las_salidas(self) -> None:
        self.assertTrue(BUILD_DOCS.is_file(), f"falta {BUILD_DOCS}")
        for asset in (*NEW_ASSETS, *WINDOWS_ASSETS):
            self.assertIn(asset, self.docs, f"la guia no menciona {asset}")

    def test_la_guia_documenta_el_motor_protegido_y_sus_banderas(self) -> None:
        for fragmento in (
            "MensorCAD.bundle/Install-MensorCAD.ps1",
            "bundle.sha256",
            "--manager-script",
            "--launcher-script",
            "__MENSORCAD_MANAGER_VERSION__",
            "__MENSORCAD_RELEASE_VERSION__",
        ):
            self.assertIn(fragmento, self.docs, f"la guia no explica {fragmento}")

    def test_la_guia_documenta_la_verificacion_real(self) -> None:
        self.assertIn("Test-CliDistribution.ps1", self.docs)
        self.assertIn("test_build_bundle.py", self.docs)
        self.assertIn("test_bootstrap_encoding.py", self.docs)
        self.assertIn("test_cli_distribution.py", self.docs)
        self.assertIn("reproducible", self.docs.lower())

    def test_la_guia_distingue_lo_critico_de_lo_opcional(self) -> None:
        # S7: el CI solo corre lo critico y construye una vez.
        self.assertIn("una sola vez", self.docs)
        self.assertIn("-BuildDir dist", self.docs)
        self.assertIn("a mano", self.docs)

    def test_la_guia_no_promete_una_publicacion_inexistente(self) -> None:
        self.assertIn("pendiente", self.docs)
        self.assertNotIn("gh release", self.docs)
        self.assertNotIn("git tag", self.docs)

    def test_documenta_la_prueba_local_sin_publicar(self) -> None:
        for fragmento in (
            "-LocalZip .\\dist\\MensorCAD-CLI.zip",
            "mensorcad install -LocalZip .\\dist\\MensorCAD-Windows.zip",
            "mensorcad update",
            "mensorcad uninstall",
            "Get-Command mensorcad",
            "MCHELP",
            "no autentica al publicador",
            "UNC",
            "terminal nueva",
            "no se ejecutan en este repositorio",
        ):
            self.assertIn(fragmento, self.docs, f"la guia no documenta {fragmento}")

    def test_las_salidas_documentadas_son_las_del_constructor(self) -> None:
        for nombre in (*NEW_ASSETS, *WINDOWS_ASSETS):
            self.assertIn(
                nombre,
                self.builder,
                f"la guia documenta {nombre} pero el constructor no lo produce",
            )


if __name__ == "__main__":
    unittest.main()
