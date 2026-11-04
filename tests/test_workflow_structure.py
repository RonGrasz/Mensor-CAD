"""Comprobaciones estructurales del CI y de la documentacion de instalacion.

Estas pruebas leen texto y aplican expresiones regulares: NO validan el esquema
YAML completo, NO ejecutan GitHub Actions ni PowerShell y NO demuestran que el
paquete se instale en Windows. La ejecucion funcional vive en las suites de
Windows y en una verificacion manual con AutoCAD.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LISP_DIR = ROOT / "lisp"
WORKFLOW = ROOT / ".github" / "workflows" / "build-bundle.yml"
README = ROOT / "README.md"

CHECKOUT_SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"
SETUP_PYTHON_SHA = "6d4fd22b20465ccc0f7354476588e8df7c9ca0e0"
UPLOAD_ARTIFACT_SHA = "cf430e030ddbb5b0abf93d22962f4752f3646cd9"

# Assets del complemento: el workflow sube los seis archivos congelados.
ARTIFACT_PATHS = (
    "dist/MensorCAD-Windows.zip",
    "dist/MensorCAD-Windows.zip.sha256",
    "dist/Install-MensorCAD.ps1",
    "dist/install.ps1",
)

# Assets propios del comando gestor: viajan junto al paquete del complemento y
# se publican como artifact, no como release.
CLI_ARTIFACT_PATHS = (
    "dist/MensorCAD-CLI.zip",
    "dist/MensorCAD-CLI.zip.sha256",
)

STEP_START = re.compile(r"(?m)^\s{6}- name:\s*")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class WorkflowStructureTests(unittest.TestCase):
    """Forma publica del workflow; no es una validacion de esquema ni de CI."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = read_text(WORKFLOW) if WORKFLOW.is_file() else ""
        cls.readme = read_text(README)

    def step_block(self, marker: str) -> str:
        start = self.workflow.find(marker)
        self.assertNotEqual(start, -1, f"falta el paso del workflow: {marker}")
        following = STEP_START.search(self.workflow, start + len(marker))
        end = following.start() if following else len(self.workflow)
        return self.workflow[start:end]

    def test_workflow_exists(self) -> None:
        self.assertTrue(WORKFLOW.is_file(), f"falta {WORKFLOW}")

    def test_public_triggers_are_push_pull_request_and_manual(self) -> None:
        self.assertIn("\non:\n", self.workflow)
        for trigger in ("push:", "pull_request:", "workflow_dispatch:"):
            self.assertIn(f"\n  {trigger}", self.workflow)
        self.assertNotIn("pull_request_target", self.workflow)
        self.assertNotIn("schedule:", self.workflow)

    def test_permissions_are_read_only_and_there_are_no_secrets(self) -> None:
        self.assertRegex(self.workflow, r"(?m)^permissions:\n  contents: read$")
        self.assertNotIn("contents: write", self.workflow)
        self.assertNotIn("permissions: write-all", self.workflow)
        self.assertNotIn("secrets.", self.workflow)

    def test_one_windows_job_runs_powershell_51_explicitly(self) -> None:
        self.assertEqual(self.workflow.count("runs-on: windows-latest"), 1)
        self.assertEqual(self.workflow.count("runs-on:"), 1)
        self.assertNotIn("pwsh", self.workflow.lower())
        self.assertEqual(
            self.workflow.count("shell: powershell"),
            self.workflow.count("run:"),
            "cada paso run debe declarar shell: powershell (Windows PowerShell 5.1)",
        )

    def test_actions_are_pinned_with_verified_v7_commits(self) -> None:
        uses = re.findall(r"(?m)^\s*uses:\s*(\S+)", self.workflow)
        expected = {
            f"actions/checkout@{CHECKOUT_SHA}",
            f"actions/setup-python@{SETUP_PYTHON_SHA}",
            f"actions/upload-artifact@{UPLOAD_ARTIFACT_SHA}",
        }
        self.assertEqual(set(uses), expected)
        self.assertEqual(len(uses), 3)
        for sha in (CHECKOUT_SHA, SETUP_PYTHON_SHA, UPLOAD_ARTIFACT_SHA):
            self.assertRegex(self.workflow, f"@{sha}\\s+# v7")
        self.assertNotRegex(self.workflow, r"uses:\s*[^\s@]+@v\d")

    def test_checkout_does_not_persist_credentials(self) -> None:
        block = self.step_block("actions/checkout@")
        self.assertIn("persist-credentials: false", block)

    def test_setup_python_uses_python_313(self) -> None:
        block = self.step_block("actions/setup-python@")
        self.assertRegex(block, r'python-version:\s*"3\.13"')

    def test_python_suite_runs_without_bytecode(self) -> None:
        # S7: el CI solo ejecuta las suites criticas de empaquetado y arranque.
        block = self.step_block("Pruebas criticas de Python")
        self.assertIn('PYTHONDONTWRITEBYTECODE: "1"', block)
        for suite in ("test_build_bundle.py", "test_bootstrap_encoding.py"):
            self.assertIn(
                f'python -B -m unittest discover -s tests -p "{suite}" -v', block
            )
        self.assertNotIn('-p "test_*.py"', block, "el CI no debe ejecutar el descubrimiento completo")
        self.assertIn("if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }", block)

    def test_the_three_windows_suites_are_isolated_and_gate_failures(self) -> None:
        # S7: solo las tres suites criticas del gestor pasan por el CI. Las
        # suites opcionales siguen disponibles para ejecutarse a mano.
        suites = (
            ("Pruebas criticas del bootstrap del gestor", "Test-CliBootstrap.ps1"),
            ("Pruebas criticas del comando gestor", "Test-Manager.ps1"),
            ("Pruebas de distribucion con artefactos reales", "Test-CliDistribution.ps1"),
        )
        self.assertEqual(len(suites), 3, "el CI debe agendar exactamente tres suites")
        for _, suite in suites:
            self.assertTrue(
                (ROOT / "tests" / suite).is_file(),
                f"la suite agendada en el CI debe existir: tests/{suite}",
            )
        for label, suite in suites:
            block = self.step_block(label)
            self.assertIn("powershell.exe", block)
            self.assertIn(f"-ExecutionPolicy Bypass -File tests/{suite}", block)
            self.assertIn("shell: powershell", block)
            self.assertIn("if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }", block)
            self.assertNotIn("continue-on-error", block)
        for opcional in (
            "Test-Installer.ps1",
            "Test-InstallerWindow.ps1",
            "Test-InstallerStyle.ps1",
            "Test-RemoteInstaller.ps1",
        ):
            self.assertTrue(
                (ROOT / "tests" / opcional).is_file(),
                f"la suite opcional debe seguir disponible: tests/{opcional}",
            )
            self.assertNotIn(
                f"tests/{opcional}",
                self.workflow,
                f"la suite opcional no debe gatear el CI: tests/{opcional}",
            )

    def test_build_reads_version_from_manifest_without_tag_rewrite(self) -> None:
        block = self.step_block("Construir el paquete")
        self.assertIn("Get-Content -LiteralPath PackageContents.xml -Raw", block)
        self.assertIn("$manifest.ApplicationPackage", block)
        self.assertIn("$package.AppVersion", block)
        self.assertIn("if (-not $version) { $version = $package.Version }", block)
        self.assertIn("python tools/build_bundle.py --output-dir dist --version $version", block)
        self.assertIn("if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }", block)
        for forbidden in (
            "github.ref_name",
            "github.event.release",
            "git tag",
            "SeriesMin",
            "SeriesMax",
        ):
            self.assertNotIn(forbidden, self.workflow)

    def test_checks_run_before_the_artifact_upload(self) -> None:
        # S7: se construye una sola vez y la validacion de distribucion reutiliza
        # ese mismo dist antes de publicar.
        marks = [
            self.workflow.index("test_build_bundle.py"),
            self.workflow.index("tests/Test-CliBootstrap.ps1"),
            self.workflow.index("tests/Test-Manager.ps1"),
            self.workflow.index("tools/build_bundle.py"),
            self.workflow.index("tests/Test-CliDistribution.ps1"),
            self.workflow.index("actions/upload-artifact@"),
        ]
        self.assertEqual(marks, sorted(marks))
        self.assertEqual(
            self.workflow.count("python tools/build_bundle.py"),
            1,
            "el CI debe construir los artefactos una sola vez",
        )
        distribucion = self.step_block("Pruebas de distribucion con artefactos reales")
        self.assertIn("-BuildDir dist", distribucion)
        self.assertNotIn("tools/build_bundle.py", distribucion)
        upload_block = self.step_block("actions/upload-artifact@")
        self.assertNotRegex(upload_block, r"(?m)^\s+if:")
        self.assertNotIn("always()", self.workflow)
        self.assertNotIn("continue-on-error", self.workflow)

    def test_upload_contains_only_the_six_frozen_assets(self) -> None:
        block = self.step_block("actions/upload-artifact@")
        self.assertIn("if-no-files-found: error", block)
        self.assertIn("path: |", block)
        path_lines = [
            line.strip() for line in block.splitlines() if line.strip().startswith("dist/")
        ]
        self.assertEqual(
            sorted(path_lines), sorted(ARTIFACT_PATHS + CLI_ARTIFACT_PATHS)
        )
        self.assertEqual(
            len(path_lines), len(set(path_lines)), "rutas duplicadas en la subida"
        )

    def test_workflow_never_publishes_releases_tags_or_pushes(self) -> None:
        for forbidden in (
            "softprops/action-gh-release",
            "actions/create-release",
            "upload-release-asset",
            "gh release",
            "git push",
            "git tag",
            "gh auth",
            "git config",
            "id-token: write",
            "pip install",
            "requirements.txt",
        ):
            self.assertNotIn(forbidden, self.workflow)


    def test_readme_keeps_appload_as_a_documented_fallback(self) -> None:
        section = self.readme_section("## Instalación")
        self.assertIn("APPLOAD", section)
        self.assertIn("MC-AREA.lsp", section)
        self.assertIn("MCAREA", section)




    def test_readme_documents_the_precise_uninstall_commands(self) -> None:
        section = self.readme_section("## Desinstalar")
        for fragmento in (
            "mensorcad uninstall",
            "Desinstalar.bat",
            "conserva el comando gestor",
            "permanecen en tus dibujos",
        ):
            self.assertIn(fragmento, section, f"la desinstalacion no menciona {fragmento}")


    def test_readme_requirements_cover_installer_prerequisites(self) -> None:
        section = self.readme_section("## Antes de instalar")
        for fragmento in (
            "Windows de 64 bits",
            "Windows PowerShell 5.1",
            "administrador",
            "cierra AutoCAD",
        ):
            self.assertIn(fragmento, section, f"los requisitos no mencionan {fragmento}")

    def test_readme_preserves_every_command_and_screenshot(self) -> None:
        # Toda herramienta de lisp/ debe seguir documentada, y cada imagen que
        # el README referencia debe existir: las dos listas se derivan del
        # repositorio para no envejecer con cada reescritura del README.
        for script in sorted(LISP_DIR.glob("MC-*.lsp")):
            comando = "MC" + script.stem.split("-", 1)[1]
            self.assertIn(comando, self.readme, f"el README no documenta {comando}")
        imagenes = set(re.findall(r"docs/images/[^\s\"')]+", self.readme))
        self.assertTrue(imagenes, "el README debe mostrar las herramientas con imagenes")
        for imagen in sorted(imagenes):
            self.assertTrue((ROOT / imagen).is_file(), f"falta la imagen referenciada {imagen}")

    def readme_section(self, heading: str) -> str:
        self.assertIn(heading, self.readme)
        start = self.readme.index(heading) + len(heading)
        following = re.search(r"(?m)^## ", self.readme[start:])
        end = start + following.start() if following else len(self.readme)
        return self.readme[start:end]


if __name__ == "__main__":
    unittest.main()
