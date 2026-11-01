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
WORKFLOW = ROOT / ".github" / "workflows" / "build-bundle.yml"
README = ROOT / "README.md"
TESTING_DOC = ROOT / "docs" / "installation-testing.md"

CHECKOUT_SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"
SETUP_PYTHON_SHA = "6d4fd22b20465ccc0f7354476588e8df7c9ca0e0"
UPLOAD_ARTIFACT_SHA = "cf430e030ddbb5b0abf93d22962f4752f3646cd9"

ARTIFACT_PATHS = (
    "dist/MensorCAD-Windows.zip",
    "dist/MensorCAD-Windows.zip.sha256",
    "dist/Install-MensorCAD.ps1",
    "dist/install.ps1",
)

COMMAND_HEADINGS = (
    "### MCAREA —",
    "### MCTABLE —",
    "### MCVECTOR —",
    "### MCCOORD —",
    "### MCVERTEX —",
    "### MCSUBDIV —",
    "### MCTRANSFORM —",
    "### MCIMPORT —",
    "### MCEXPORTEX —",
    "### MCFIX —",
    "### MCCOLIND —",
    "### MCELEMENTS —",
    "### MCHELP —",
)

SCREENSHOTS = (
    "docs/images/mensor-cad-title.png",
    "docs/images/Area.png",
    "docs/images/Tabla-de-coordenadas.png",
    "docs/images/Rumbo-y-distancia.png",
    "docs/images/Etiqueta-de-vertice.png",
    "docs/images/Subdividir.png",
    "docs/images/Importar-puntos.png",
    "docs/images/Exportar-puntos.png",
    "docs/images/Estilo-de-colindancia.png",
    "docs/images/Estructuras.png",
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
        block = self.step_block("Pruebas de Python")
        self.assertIn('PYTHONDONTWRITEBYTECODE: "1"', block)
        self.assertIn(
            'python -B -m unittest discover -s tests -p "test_*.py" -v', block
        )
        self.assertIn("if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }", block)

    def test_the_five_windows_suites_are_isolated_and_gate_failures(self) -> None:
        # Las cinco suites funcionales del repositorio deben pasar por el CI:
        # una suite escrita pero no agendada es cobertura que no existe.
        suites = (
            ("Pruebas del instalador local", "Test-Installer.ps1"),
            ("Pruebas de la ventana del instalador", "Test-InstallerWindow.ps1"),
            ("Pruebas del estilo del instalador", "Test-InstallerStyle.ps1"),
            ("Pruebas del instalador remoto", "Test-RemoteInstaller.ps1"),
            ("Pruebas del bootstrap remoto", "Test-Bootstrap.ps1"),
        )
        for _, suite in suites:
            self.assertTrue(
                (ROOT / "tests" / suite).is_file(),
                f"la suite agendada en el CI debe existir: tests/{suite}",
            )
        for label, suite in suites:
            block = self.step_block(label)
            self.assertIn(
                f"powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/{suite}",
                block,
            )
            self.assertIn("shell: powershell", block)
            self.assertIn("if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }", block)
            self.assertNotIn("continue-on-error", block)

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
        python_suite = self.workflow.index("test_*.py")
        local_suite = self.workflow.index("tests/Test-Installer.ps1")
        window_suite = self.workflow.index("tests/Test-InstallerWindow.ps1")
        style_suite = self.workflow.index("tests/Test-InstallerStyle.ps1")
        remote_suite = self.workflow.index("tests/Test-RemoteInstaller.ps1")
        bootstrap_suite = self.workflow.index("tests/Test-Bootstrap.ps1")
        build = self.workflow.index("tools/build_bundle.py")
        upload = self.workflow.index("actions/upload-artifact@")
        marks = [
            python_suite,
            local_suite,
            window_suite,
            style_suite,
            remote_suite,
            bootstrap_suite,
            build,
            upload,
        ]
        self.assertEqual(marks, sorted(marks))
        upload_block = self.step_block("actions/upload-artifact@")
        self.assertNotRegex(upload_block, r"(?m)^\s+if:")
        self.assertNotIn("always()", self.workflow)
        self.assertNotIn("continue-on-error", self.workflow)

    def test_upload_contains_only_the_four_frozen_assets(self) -> None:
        block = self.step_block("actions/upload-artifact@")
        self.assertIn("if-no-files-found: error", block)
        self.assertIn("path: |", block)
        path_lines = [
            line.strip() for line in block.splitlines() if line.strip().startswith("dist/")
        ]
        self.assertEqual(sorted(path_lines), sorted(ARTIFACT_PATHS))

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

    def test_readme_installation_leads_with_the_offline_bundle(self) -> None:
        section = self.readme_section("## Instalación")
        self.assertIn("MensorCAD-Windows.zip", section)
        self.assertIn("Instalar.bat", section)
        self.assertIn("doble clic", section)
        self.assertIn("administrador", section.lower())
        self.assertIn("Cierra AutoCAD", section)
        self.assertLess(
            section.index("### Ruta rápida con el ZIP"),
            section.index("### Instalación manual con APPLOAD"),
            "la ruta offline del ZIP debe aparecer antes que la alternativa APPLOAD",
        )

    def test_readme_keeps_appload_as_a_documented_fallback(self) -> None:
        section = self.readme_section("## Instalación")
        self.assertIn("APPLOAD", section)
        self.assertIn("MC-AREA.lsp", section)
        self.assertIn("MCAREA", section)

    def test_readme_labels_release_and_remote_as_unavailable(self) -> None:
        section = self.readme_section("## Instalación")
        self.assertIn("todavía no están publicados", section)
        self.assertIn("El comando remoto no funciona todavía", section)
        self.assertIn("docs/remote-installer.md", section)

    def test_readme_distinguishes_the_actions_artifact_from_release_assets(self) -> None:
        section = self.readme_section("## Instalación")
        self.assertIn("artifact de GitHub Actions", section)
        self.assertIn("no es un release", section)
        for asset in ARTIFACT_PATHS:
            self.assertIn(asset.rsplit("/", 1)[-1], section)

    def test_readme_documents_installer_behavior_without_global_changes(self) -> None:
        section = self.readme_section("## Instalación")
        self.assertIn("ventana de diagnóstico", section)
        self.assertIn("animación", section)
        self.assertIn("ExecutionPolicy Bypass", section)
        self.assertIn("solo para el proceso", section)
        self.assertIn("SECURELOAD", section)
        self.assertIn("TRUSTEDPATHS", section)
        self.assertIn("APPAUTOLOAD", section)

    def test_readme_documents_the_precise_uninstall_commands(self) -> None:
        section = self.readme_section("## Desinstalación")
        self.assertIn("Instalar.bat -Uninstall", section)
        self.assertIn(
            "powershell.exe -NoProfile -ExecutionPolicy Bypass "
            "-File .\\Install-MensorCAD.ps1 -Uninstall",
            section,
        )
        self.assertIn("solo los archivos registrados", section)
        self.assertIn("No borra las tablas", section)

    def test_readme_links_the_installation_testing_guide(self) -> None:
        self.assertIn("docs/installation-testing.md", self.readme)

    def test_readme_requirements_cover_installer_prerequisites(self) -> None:
        section = self.readme_section("## Plataformas y requisitos")
        self.assertIn("Windows 64", section)
        self.assertIn("Windows PowerShell 5.1", section)
        self.assertIn("Administrador", section)
        self.assertIn("versión mínima", section)

    def test_readme_preserves_every_command_section_and_screenshot(self) -> None:
        for heading in COMMAND_HEADINGS:
            self.assertIn(heading, self.readme)
        for screenshot in SCREENSHOTS:
            self.assertIn(f"]({screenshot})", self.readme)

    def test_testing_guide_exists(self) -> None:
        self.assertTrue(TESTING_DOC.is_file(), f"falta {TESTING_DOC}")

    def readme_section(self, heading: str) -> str:
        self.assertIn(heading, self.readme)
        start = self.readme.index(heading) + len(heading)
        following = re.search(r"(?m)^## ", self.readme[start:])
        end = start + following.start() if following else len(self.readme)
        return self.readme[start:end]


class InstallationTestingDocTests(unittest.TestCase):
    """Contenido del documento de mantenedores; no ejecuta nada."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.doc = read_text(TESTING_DOC) if TESTING_DOC.is_file() else ""

    def test_document_states_what_was_not_executed(self) -> None:
        self.assertIn("no se ejecutó", self.doc)
        self.assertIn("GitHub Actions", self.doc)
        self.assertIn("Windows PowerShell 5.1", self.doc)

    def test_document_has_the_exact_windows_suite_commands(self) -> None:
        # La guia debe listar las cinco suites que el CI agenda, en el mismo orden.
        commands = [
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Installer.ps1",
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-InstallerWindow.ps1",
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-InstallerStyle.ps1",
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-RemoteInstaller.ps1",
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Bootstrap.ps1",
        ]
        positions = []
        for command in commands:
            self.assertIn(command, self.doc)
            positions.append(self.doc.index(command))
        self.assertEqual(positions, sorted(positions), "el orden de la guia debe seguir al del CI")

    def test_the_guide_lists_the_five_ci_steps_in_order(self) -> None:
        markers = [
            "La suite completa de Python",
            "tests/Test-Installer.ps1",
            "tests/Test-InstallerWindow.ps1",
            "tests/Test-InstallerStyle.ps1",
            "tests/Test-RemoteInstaller.ps1",
            "tests/Test-Bootstrap.ps1",
            "tools/build_bundle.py",
            "La subida de cuatro archivos como artifact",
        ]
        bloque = self.doc[self.doc.index("## CI: qué hace y qué no hace") :]
        positions = []
        for marker in markers:
            self.assertIn(marker, bloque, f"la guia no describe el paso del CI: {marker}")
            positions.append(bloque.index(marker))
        self.assertEqual(positions, sorted(positions), "la guia debe respetar el orden real del CI")

    def test_document_has_the_local_python_and_build_commands(self) -> None:
        self.assertIn(
            "PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s tests -p 'test_*.py' -v",
            self.doc,
        )
        self.assertIn("python tools/build_bundle.py --output-dir dist", self.doc)
        self.assertIn("AppVersion", self.doc)
        self.assertIn("Version", self.doc)

    def test_document_explains_ci_artifact_versus_release_assets(self) -> None:
        self.assertIn("artifact", self.doc.lower())
        self.assertIn("release", self.doc.lower())
        for asset in ARTIFACT_PATHS:
            self.assertIn(asset.rsplit("/", 1)[-1], self.doc)
        self.assertIn("publicación", self.doc.lower())

    def test_document_covers_the_manual_safety_checklist(self) -> None:
        for topic in ("dibujo nuevo", "reiniciar", "actualizar", "desinstalar", "Cierra AutoCAD"):
            self.assertIn(topic, self.doc.lower() if topic.islower() else self.doc)
        for variable in ("SECURELOAD", "TRUSTEDPATHS", "APPAUTOLOAD"):
            self.assertIn(variable, self.doc)
        self.assertIn("copia", self.doc.lower())

    def test_document_requests_reproducible_evidence(self) -> None:
        for field in ("código de salida", "versión de AutoCAD", "SHA-256", "captura"):
            self.assertIn(field, self.doc)

    def test_document_keeps_the_cli_differential_pending(self) -> None:
        self.assertIn("diferencial", self.doc.lower())
        self.assertIn("pendiente", self.doc.lower())
        self.assertIn("aislado", self.doc.lower())


if __name__ == "__main__":
    unittest.main()
