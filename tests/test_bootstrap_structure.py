"""Comprobaciones estructurales del bootstrap corto ``install.ps1``.

Estas pruebas leen texto y aplican expresiones regulares: NO ejecutan
PowerShell, NO descargan nada y NO demuestran que la instalacion funcione. La
ejecucion funcional vive en ``tests/Test-Bootstrap.ps1`` y requiere Windows
PowerShell 5.1 y una persona que la lance a mano.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "install.ps1"
BOOTSTRAP_TESTS = ROOT / "tests" / "Test-Bootstrap.ps1"
README = ROOT / "README.md"
REMOTE_DOCS = ROOT / "docs" / "remote-installer.md"
BUILD_DOCS = ROOT / "docs" / "build-bundle.md"
TESTING_DOCS = ROOT / "docs" / "installation-testing.md"

LATEST_COMMAND = (
    "irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/"
    "install.ps1' -ea Stop | iex"
)
PINNED_COMMAND = (
    "&([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/"
    "download/v0.1.0/install.ps1' -ea Stop))) -Version v0.1.0"
)
AUTOMATION_FALLBACK = "& .\\install.ps1; exit $LASTEXITCODE"

ENGINE_FRAGMENTS = (
    "bundle.sha256",
    "MensorCAD.bundle",
    "Expand-Archive",
    "Install-MensorCadBundle",
    "Uninstall-MensorCadBundle",
    "Get-MensorCadDestinationRoot",
    "Test-MensorCadSource",
    "__MENSORCAD_RELEASE_VERSION__",
)

GLOBAL_MUTATORS = (
    "Set-ExecutionPolicy",
    "Set-ItemProperty",
    "New-ItemProperty",
    "reg add",
    "-Verb RunAs",
    "$PROFILE",
    "Set-Location",
    "Start-Process",
)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def fin_de_linea_ps51_valido(raw: bytes) -> bool:
    """Acepta LF y CRLF; solo rechaza retornos de carro sueltos."""
    return b"\r" not in raw.replace(b"\r\n", b"")


class BootstrapStructureTests(unittest.TestCase):
    """Forma del wrapper; no sustituye a la suite de Windows."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = BOOTSTRAP.read_bytes() if BOOTSTRAP.is_file() else b""
        cls.bootstrap = cls.raw.decode("utf-8-sig")
        cls.readme = read_text(README)
        cls.remote_docs = read_text(REMOTE_DOCS)
        cls.build_docs = read_text(BUILD_DOCS)
        cls.testing_docs = read_text(TESTING_DOCS)

    def test_bootstrap_existe_sin_bom_y_con_salto_de_linea_final(self) -> None:
        # El asset se entrega por HTTP y se ejecuta con [scriptblock]::Create: un
        # BOM UTF-8 no se reconoce ahi, llega como texto mojibake delante de
        # param y el arranque se rompe. Por eso el archivo es ASCII puro y no
        # lleva BOM; el instalador real conserva el suyo porque tiene Unicode.
        self.assertTrue(BOOTSTRAP.is_file(), f"falta {BOOTSTRAP}")
        self.assertEqual(BOOTSTRAP.name, "install.ps1", "el asset debe ser minusculo")
        self.assertFalse(self.raw.startswith(b"\xef\xbb\xbf"), "el bootstrap no debe llevar BOM")
        self.assertTrue(all(byte < 0x80 for byte in self.raw), "el bootstrap debe ser ASCII")
        self.assertTrue(fin_de_linea_ps51_valido(self.raw), "hay CR sueltos")
        self.assertTrue(self.raw.endswith(b"\n"), "falta el salto de linea final")

    def test_es_un_wrapper_sin_banderas_publicas_nuevas(self) -> None:
        self.assertIn("param(", self.bootstrap)
        self.assertIn("[string]$Version", self.bootstrap)
        self.assertIn("[switch]$NoAnimation", self.bootstrap)
        for prohibida in ("[switch]$FromRelease", "[switch]$Uninstall", "[switch]$ElevatedProcess"):
            self.assertNotIn(
                prohibida,
                self.bootstrap,
                f"el wrapper no debe aceptar {prohibida}: eso lo decide el instalador real",
            )

    def test_nunca_ejecuta_exit_en_el_llamador(self) -> None:
        self.assertIsNone(
            re.search(r"(?m)^\s*exit\b", self.bootstrap),
            "un exit en el ambito del llamador cerraria la sesion bajo iex",
        )
        self.assertNotIn("Stop-Process", self.bootstrap)
        self.assertIn("$global:LASTEXITCODE", self.bootstrap, "falta el contrato de salida")

    def test_descarga_solo_el_instalador_real_en_una_carpeta_propia(self) -> None:
        for fragmento in (
            "https://github.com",
            "'RonGrasz/Mensor-CAD'",
            "releases/latest/download/",
            "releases/download/",
            "Install-MensorCAD.ps1",
            "Invoke-WebRequest",
            "-OutFile",
            "[guid]::NewGuid().ToString('N')",
            "New-Item -ItemType Directory",
            "Remove-Item",
        ):
            self.assertIn(fragmento, self.bootstrap, f"falta {fragmento}")

    def test_version_se_valida_antes_de_la_red_y_de_las_escrituras(self) -> None:
        patron = self.bootstrap.index("^v?\\d+\\.\\d+")
        primera_red = self.bootstrap.index("Invoke-WebRequest")
        primera_escritura = self.bootstrap.index("New-Item -ItemType Directory")
        self.assertLess(patron, primera_red, "el tag debe validarse antes de descargar")
        self.assertLess(patron, primera_escritura, "el tag debe validarse antes de escribir")
        self.assertIn("-notmatch", self.bootstrap)

    def test_tls12_se_fija_antes_de_la_primera_descarga(self) -> None:
        tls = self.bootstrap.index("SecurityProtocolType]::Tls12")
        self.assertLess(tls, self.bootstrap.index("Invoke-WebRequest"))
        self.assertIn("SecurityProtocol", self.bootstrap)

    def test_la_primera_descarga_es_terminante(self) -> None:
        descarga = self.bootstrap[self.bootstrap.index("Invoke-WebRequest") :]
        self.assertIn("-UseBasicParsing", descarga)
        self.assertIn("-ErrorAction Stop", descarga)

    def test_lanza_un_proceso_windows_powershell_aparte(self) -> None:
        for fragmento in (
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "-FromRelease",
            "powershell.exe",
        ):
            self.assertIn(fragmento, self.bootstrap, f"falta {fragmento}")

    def test_no_duplica_el_motor_ni_la_version_del_producto(self) -> None:
        for fragmento in ENGINE_FRAGMENTS:
            self.assertNotIn(
                fragmento,
                self.bootstrap,
                f"el bootstrap no debe duplicar el motor ni la version: {fragmento}",
            )
        self.assertNotIn("Program Files", self.bootstrap)

    def test_no_muta_configuracion_global(self) -> None:
        for fragmento in GLOBAL_MUTATORS:
            self.assertNotIn(
                fragmento,
                self.bootstrap,
                f"el bootstrap no debe cambiar configuracion global: {fragmento}",
            )

    def test_requiere_windows_y_reporta_errores_en_stderr(self) -> None:
        self.assertIn("[PlatformID]::Win32NT", self.bootstrap)
        self.assertIn("[Console]::Error.WriteLine", self.bootstrap)
        self.assertIn("ERROR: ", self.bootstrap)

    def test_un_estado_ausente_nunca_se_informa_como_exito(self) -> None:
        # PowerShell siempre define $LASTEXITCODE despues de un proceso nativo,
        # asi que la suite de Windows no puede provocar este caso. La guarda
        # defensiva se verifica aqui y siempre termina en codigo distinto de 0.
        self.assertRegex(self.bootstrap, r"\$null -eq \$childExitCode")
        self.assertIn("$childExitCode = 1", self.bootstrap)
        self.assertIn("No se da la instalacion por hecha", self.bootstrap)
        for afirmacion in ("instalado correctamente", "actualizado correctamente", "actualizacion completada"):
            self.assertNotIn(
                afirmacion,
                self.bootstrap,
                "el wrapper no puede afirmar el resultado de la instalacion",
            )

    def test_la_presencia_de_version_se_deriva_de_los_parametros_ligados(self) -> None:
        # Un [string] con default $null se coacciona a '': inferir la presencia
        # desde el valor tipado convierte la ultima version (sin -Version) en un
        # tag vacio invalido. La presencia solo puede venir de los parametros
        # realmente ligados en el ambito exterior.
        self.assertIn(
            "$PSBoundParameters.ContainsKey('Version')",
            self.bootstrap,
            "la presencia de -Version debe leerse de los parametros ligados",
        )
        self.assertNotIn(
            "[string]$Version = $null",
            self.bootstrap,
            "un default $null en [string] se coacciona a cadena vacia",
        )
        self.assertNotIn(
            "$null -ne $Version",
            self.bootstrap,
            "no se puede inferir la presencia desde el valor del parametro",
        )
        self.assertIn("[bool]$VersionSpecified", self.bootstrap)
        self.assertIn("$versionSpecified = $VersionSpecified", self.bootstrap)

    def test_la_carpeta_temporal_solo_se_borra_si_fue_creada_por_este_proceso(self) -> None:
        # La propiedad de la carpeta no puede existir antes de crearla: si
        # New-Item falla porque la ruta ya existia, el finally borraria una
        # carpeta ajena. La ruta candidata y la carpeta propia son distintas.
        self.assertIn("$candidate = Join-Path", self.bootstrap)
        self.assertNotIn(
            "$workspace = Join-Path",
            self.bootstrap,
            "la carpeta propia no puede asignarse antes de crearla",
        )
        self.assertIn("$workspace = $null", self.bootstrap)
        self.assertIn("[System.IO.Directory]::Exists($candidate)", self.bootstrap)
        creacion = self.bootstrap.index("New-Item -ItemType Directory")
        reparse = self.bootstrap.index("ReparsePoint")
        propiedad = self.bootstrap.index("$workspace = $candidate")
        self.assertLess(creacion, propiedad, "la propiedad debe marcarse despues de crear")
        self.assertLess(reparse, propiedad, "una ruta rechazada no puede marcarse como propia")
        self.assertIn(
            "se conserva en disco",
            self.bootstrap.lower(),
            "una ruta rechazada se deja en disco con un aviso honesto",
        )

    def test_el_stderr_del_hijo_no_se_convierte_en_error_terminante(self) -> None:
        # En Windows PowerShell 5.1 una linea de stderr de un comando nativo se
        # promueve a NativeCommandError cuando la preferencia es Stop, y eso
        # taparia el codigo real del instalador hijo.
        self.assertIn("$ErrorActionPreference = 'Continue'", self.bootstrap)
        self.assertIn("$ErrorActionPreference = $previousPreference", self.bootstrap)
        continue_ = self.bootstrap.index("$ErrorActionPreference = 'Continue'")
        hijo = self.bootstrap.index("& $childHost")
        restaurar = self.bootstrap.index("$ErrorActionPreference = $previousPreference")
        self.assertLess(continue_, hijo, "la preferencia debe relajarse antes del hijo")
        self.assertGreater(restaurar, hijo, "la preferencia debe restaurarse despues del hijo")


class ShortCommandDocumentationTests(unittest.TestCase):
    """El comando corto publicado debe ser el cuerpo exacto que se prueba."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.readme = read_text(README)
        cls.remote_docs = read_text(REMOTE_DOCS)
        cls.build_docs = read_text(BUILD_DOCS)
        cls.testing_docs = read_text(TESTING_DOCS)

    def test_readme_publica_los_dos_comandos_cortos_exactos(self) -> None:
        self.assertIn(LATEST_COMMAND, self.readme)
        self.assertIn(PINNED_COMMAND, self.readme)

    def test_remote_docs_publican_los_dos_comandos_cortos_exactos(self) -> None:
        self.assertIn(LATEST_COMMAND, self.remote_docs)
        self.assertIn(PINNED_COMMAND, self.remote_docs)

    def test_los_comandos_cortos_no_inventan_dominio_ni_variables(self) -> None:
        for origen, text in (
            ("README.md", self.readme),
            ("docs/remote-installer.md", self.remote_docs),
        ):
            for comando in (LATEST_COMMAND, PINNED_COMMAND):
                self.assertNotIn("$", comando, f"{origen}: el comando no debe tener variables")
                self.assertIn("github.com/RonGrasz/Mensor-CAD/releases", comando)
                self.assertNotIn("mensorcad.", comando, f"{origen}: sin dominio propio")
            self.assertNotIn("mensorcad.com", text)
            self.assertNotIn("mensorcad.net", text)

    def test_el_ejemplo_fijado_es_ilustrativo_y_no_publicado(self) -> None:
        for origen, text in (
            ("README.md", self.readme),
            ("docs/remote-installer.md", self.remote_docs),
        ):
            self.assertIn("v0.1.0", text)
            self.assertTrue(
                re.search(
                    r"(no publicado|no está publicado|no esta publicado|ilustrativ|ejemplo)",
                    text,
                    re.IGNORECASE,
                ),
                f"{origen}: el tag de ejemplo debe estar marcado como no publicado",
            )

    def test_los_comandos_cortos_quedan_marcados_como_no_operativos(self) -> None:
        for origen, text in (
            ("README.md", self.readme),
            ("docs/remote-installer.md", self.remote_docs),
        ):
            self.assertIn("install.ps1", text)
            self.assertTrue(
                re.search(r"no (está|esta) publicado|no funciona|no disponible|todavía no", text),
                f"{origen}: el comando corto no puede presentarse como disponible",
            )

    def test_la_documentacion_explica_el_contrato_de_salida(self) -> None:
        for origen, text in (
            ("README.md", self.readme),
            ("docs/remote-installer.md", self.remote_docs),
        ):
            self.assertIn("LASTEXITCODE", text, f"{origen}: falta el contrato de salida")
            self.assertIn("iex", text, f"{origen}: falta la advertencia sobre iex")
            self.assertIn(
                AUTOMATION_FALLBACK,
                text,
                f"{origen}: falta el fallback de automatizacion con el operador de llamada",
            )
            self.assertNotIn(
                "-File .\\install.ps1; exit",
                text,
                f"{origen}: -File no propaga LASTEXITCODE por si solo",
            )
            self.assertIn("exit $LASTEXITCODE", text)
            self.assertIn("-ea Stop", text)
            self.assertIn("cuatro", text.lower(), f"{origen}: deben listarse los cuatro assets")

    def test_la_documentacion_conserva_el_bootstrap_completo(self) -> None:
        # El comando completo anterior sigue siendo el fallback compatible.
        for origen, text in (
            ("README.md", self.readme),
            ("docs/remote-installer.md", self.remote_docs),
        ):
            lineas = [
                linea.strip()
                for linea in text.splitlines()
                if linea.strip().startswith("powershell.exe") and '-Command "' in linea
            ]
            completos = [linea for linea in lineas if "Install-MensorCAD.ps1" in linea]
            self.assertGreaterEqual(len(completos), 2, f"{origen}: faltan los dos comandos completos")
            for linea in completos:
                self.assertIn("-FromRelease", linea)
                self.assertIn("[scriptblock]::Create(", linea)

    def test_la_documentacion_distingue_la_primera_descarga_del_wrapper(self) -> None:
        # La primera descarga ocurre ANTES del wrapper: -ea Stop corta la
        # invocacion, pero el wrapper nunca se ejecuta y no puede fijar
        # $LASTEXITCODE. Un valor previo (incluso 0) puede quedar visible.
        for origen, text in (
            ("README.md", self.readme),
            ("docs/remote-installer.md", self.remote_docs),
        ):
            self.assertIn("antes del wrapper", text, f"{origen}: falta distinguir el primer salto")
            self.assertIn(
                "puede conservar",
                text,
                f"{origen}: la primera descarga no garantiza $LASTEXITCODE",
            )
            self.assertIn(
                "no fija",
                text,
                f"{origen}: la primera descarga no puede fijar el codigo de salida",
            )
        self.assertIn(
            "antes del wrapper",
            self.remote_docs,
            "la tabla de salida debe separar el primer salto del estado del wrapper",
        )

    def test_la_documentacion_no_afirma_que_el_ci_siga_sin_cambios(self) -> None:
        # El workflow ahora ejecuta la suite del bootstrap: la documentacion no
        # puede decir que la unidad no toca CI, pero tampoco puede sugerir
        # publicacion, tags o cambios de disparadores.
        self.assertNotIn("ni cambia CI", self.remote_docs)
        self.assertIn("disparadores", self.remote_docs)
        self.assertIn("Test-Bootstrap.ps1", self.remote_docs)

    def test_build_y_testing_docs_cubren_el_bootstrap(self) -> None:
        self.assertIn("install.ps1", self.build_docs)
        self.assertIn("--bootstrap-script", self.build_docs)
        self.assertIn("install.ps1", self.testing_docs)
        self.assertIn("Test-Bootstrap.ps1", self.testing_docs)


class BootstrapWindowsSuiteTests(unittest.TestCase):
    """La suite funcional se entrega escrita y se ejecuta a mano en Windows."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = BOOTSTRAP_TESTS.read_bytes() if BOOTSTRAP_TESTS.is_file() else b""
        cls.text = cls.raw.decode("utf-8-sig")

    def test_la_suite_existe_y_es_ps51(self) -> None:
        self.assertTrue(BOOTSTRAP_TESTS.is_file(), f"falta {BOOTSTRAP_TESTS}")
        self.assertTrue(self.raw.startswith(b"\xef\xbb\xbf"), "falta el BOM UTF-8")
        self.assertTrue(fin_de_linea_ps51_valido(self.raw), "hay CR sueltos")
        self.assertTrue(self.raw.endswith(b"\n"), "falta el salto de linea final")
        self.assertIn("#requires -Version 5.1", self.text)
        self.assertIn("exit 2", self.text, "fuera de Windows la suite debe omitirse")

    def test_la_suite_usa_el_comando_publicado_y_el_archivo_real(self) -> None:
        self.assertIn("install.ps1", self.text)
        self.assertIn("README.md", self.text)
        self.assertIn("remote-installer.md", self.text)
        self.assertIn("LASTEXITCODE", self.text)
        self.assertIn("Invoke-RestMethod", self.text)
        self.assertIn("Invoke-WebRequest", self.text)

    def test_la_suite_cubre_la_propiedad_de_la_carpeta_temporal(self) -> None:
        for fragmento in (
            "workspace-collision",
            "workspace-reparse",
            "sentinel",
            "RemoveCalls",
            "NewItemPath",
        ):
            self.assertIn(
                fragmento,
                self.text,
                f"la suite debe cubrir la propiedad de la carpeta: {fragmento}",
            )
        self.assertIn("mensorcad-bootstrap-", self.text)

    def test_la_suite_separa_los_canales_del_hijo(self) -> None:
        # El stdout y el stderr del hijo se miden en su canal real; el stderr no
        # puede buscarse en stdout.
        needle = "Stdout.Contains('fixture stderr 1')"
        positions = [match.start() for match in re.finditer(re.escape(needle), self.text)]
        self.assertTrue(positions, "la suite debe afirmar que el stderr no va por stdout")
        for position in positions:
            self.assertIn(
                "-not ",
                self.text[max(0, position - 16) : position],
                "el stderr del hijo solo puede afirmarse sobre stdout de forma negativa",
            )
        self.assertIn("$case.Stderr.Contains('fixture stderr 1')", self.text)
        self.assertIn("$case.Stdout.Contains('fixture stdout 1')", self.text)

    def test_los_arreglos_de_resultado_no_se_desenrollan_bajo_strict_mode(self) -> None:
        # StrictMode 2.0 no expone .Count en $null ni en un escalar, y PowerShell
        # desenrolla la salida de una funcion: `return @()` entrega $null y un
        # unico elemento entrega el objeto suelto. Por eso las aserciones de
        # cardinalidad fallaban antes de medir nada. El contrato es el mismo que
        # Get-SeamCalls documenta en tests/Test-RemoteInstaller.ps1: la coma
        # devuelve el arreglo como un unico objeto y conserva 0/1/2+ elementos.
        helper = re.search(r"function Get-WebRequestUris \{.*?\n\}", self.text, re.DOTALL)
        self.assertIsNotNone(helper, "falta el helper Get-WebRequestUris")
        self.assertRegex(
            helper.group(0),
            r"(?m)^\s*return\s+,",
            "el helper debe devolver el arreglo con la coma para no desenrollarse",
        )
        self.assertIn(
            "$removeCalls = @()",
            self.text,
            "RemoveCalls debe materializarse como arreglo real antes de exponerse",
        )
        self.assertRegex(
            self.text,
            r"if \(\$null -ne \$result -and \$null -ne \$result\.RemoveCalls\)",
            "una lista vacia del JSON no puede convertirse en un arreglo con $null",
        )
        # Las aserciones de cardinalidad siguen siendo las que prueban el
        # comportamiento: no se relajan, no se omiten y no se vuelven genericas.
        self.assertIn("Assert-Equal 1 $uris.Count", self.text)
        self.assertIn("Assert-Equal 0 (Get-WebRequestUris $case.Result).Count", self.text)
        self.assertIn("Assert-Equal 0 $case.RemoveCalls.Count", self.text)
        self.assertIn("Assert-Equal 0 $case.Workspaces.Count", self.text)

    def test_la_suite_arranca_con_un_last_exit_code_previo(self) -> None:
        # Un $LASTEXITCODE previo (0) demuestra que un fallo de la primera
        # descarga no lo fija el wrapper, porque el wrapper no llega a correr.
        self.assertIn("$global:LASTEXITCODE = 0", self.text)

    def test_la_suite_es_aislada_y_no_pide_permisos(self) -> None:
        self.assertIn("GetTempPath", self.text)
        for prohibido in ("C:\\Program Files", "-Verb RunAs", "api.github.com", "git log"):
            self.assertNotIn(prohibido, self.text)
        self.assertNotIn("realnetwork", self.text.lower())


if __name__ == "__main__":
    unittest.main()
