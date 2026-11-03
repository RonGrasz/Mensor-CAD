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
ENGINE = ROOT / "Install-MensorCAD.ps1"
MANAGER_TESTS = ROOT / "tests" / "Test-Manager.ps1"
DOCS = ROOT / "docs" / "cli-manager.md"

PLACEHOLDER = "__MENSORCAD_MANAGER_VERSION__"

# La entrada local vive dentro de la seccion de paquetes del motor (entre el
# marcador remoto y la entrega de ventana unica) porque reutiliza la misma
# validacion de ZIP. El gestor solo la invoca: no duplica validaciones.
LOCAL_ENGINE_MARKER = "# Entrada local: paquete construido por el usuario (-LocalZip)"
LOCAL_ENGINE_FUNCTIONS = (
    "Get-MensorCadLocalPackageArchivePath",
    "Get-MensorCadLocalPackageSidecarPath",
    "Copy-MensorCadLocalPackageFile",
    "Open-MensorCadLocalPackage",
    "Install-MensorCadLocalPackage",
    "Remove-MensorCadLocalPackage",
)


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
        cls.installer = read_text(ENGINE)
        # Sin la seccion local, el atributo queda vacio y cada comprobacion falla
        # como asercion propia en lugar de romper toda la clase.
        cls.local_engine = ""
        if LOCAL_ENGINE_MARKER in cls.installer and "function Invoke-MensorCadElevatedSelf" in cls.installer:
            cls.local_engine = cls.installer[
                cls.installer.index(LOCAL_ENGINE_MARKER) : cls.installer.index(
                    "function Invoke-MensorCadElevatedSelf"
                )
            ]

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
    # Entrada local: ZIP propio con .sha256 adjunto
    # ------------------------------------------------------------------

    def test_local_zip_option_se_documenta_y_solo_aplica_a_install_y_update(self) -> None:
        self.assertIn("-LocalZip", self.manager, "falta la opcion local en el gestor")
        self.assertIn("mensorcad install -LocalZip", self.manager, "la ayuda debe mostrar el uso local")
        self.assertIn("mensorcad update -LocalZip", self.manager, "la ayuda debe mostrar la actualizacion local")
        self.assertIn(
            "'-LocalZip'",
            self.manager,
            "la opcion local debe compararse como token literal, no como parametro de PowerShell",
        )
        for fragmento in (
            "no se puede repetir",
            "requiere una ruta",
            "Open-MensorCadLocalPackage",
            "Install-MensorCadLocalPackage",
            "Remove-MensorCadLocalPackage",
        ):
            self.assertIn(fragmento, self.manager, f"falta el contrato local: {fragmento}")
        # La opcion local no puede abrir validaciones ni elevacion propias: la
        # red, el hash, la extraccion y el UAC siguen en el motor.
        for prohibido in (
            "Get-MensorCadReleaseArchiveEntries",
            "Expand-MensorCadReleaseArchive",
            "Assert-MensorCadReleaseArchiveHash",
            "Test-MensorCadSource",
            "Get-MensorCadBundleVersion",
        ):
            self.assertNotIn(
                prohibido,
                self.manager,
                f"el gestor no debe duplicar la validacion del paquete: {prohibido}",
            )
        # El rechazo de opciones locales en los comandos hermanos conserva el
        # mensaje generico existente: no se agrega sintaxis aceptada fuera de
        # install, -i y update.
        self.assertIn(
            "Argumentos adicionales no admitidos",
            self.manager,
            "los comandos hermanos deben seguir rechazando cualquier extra",
        )
        self.assertNotIn(
            "'-LocalZip' -and",
            self.manager,
            "no debe existir una segunda gramatica de la opcion local",
        )

    def test_engine_reutiliza_la_validacion_del_paquete_para_la_entrada_local(self) -> None:
        self.assertTrue(self.local_engine.strip(), "falta la seccion local marcada del motor")
        for nombre in LOCAL_ENGINE_FUNCTIONS:
            self.assertIn(f"function {nombre}", self.local_engine, f"falta la funcion local {nombre}")
        self.assertIn("function Get-MensorCadBundleVersion", self.installer, "falta la lectura de version del manifiesto")
        open_body = self.local_engine[self.local_engine.index("function Open-MensorCadLocalPackage") :]
        orden = [
            "Copy-MensorCadLocalPackageFile",
            "Assert-MensorCadReleaseArchiveHash",
            "Get-MensorCadReleaseArchiveEntries",
            "Expand-MensorCadReleaseArchive",
            "Test-MensorCadSource",
            "Get-MensorCadBundleVersion",
        ]
        posiciones = [open_body.index(token) for token in orden]
        self.assertEqual(
            posiciones,
            sorted(posiciones),
            "el orden copia -> hash -> entradas -> extraccion -> inventario -> version debe respetarse",
        )
        self.assertIn("Get-MensorCadRemoteTempRoot", open_body, "la copia debe ir a una carpeta temporal propia")
        # La ruta relativa se resuelve contra la ubicacion actual de PowerShell,
        # no contra el cwd del proceso: Set-Location solo cambia la primera.
        self.assertIn(
            "GetUnresolvedProviderPathFromPSPath",
            self.local_engine,
            "la ruta relativa debe resolverse contra la ubicacion de PowerShell, no contra el cwd del proceso",
        )
        self.assertNotIn(
            "[System.IO.Path]::GetFullPath($ArchivePath)",
            self.local_engine,
            "GetFullPath resuelve contra el cwd del proceso y rompe una ruta relativa tras Set-Location",
        )
        self.assertIn("FileSystem", open_body + self.local_engine, "solo se aceptan rutas del proveedor de archivos")
        self.assertIn("Assert-MensorCadNoReparseInPath", open_body, "la carpeta propia debe rechazar reparse points")
        self.assertIn("Remove-MensorCadTree", open_body, "un fallo de validacion debe limpiar la carpeta propia")
        self.assertIn(
            "Remove-MensorCadTree",
            self.local_engine[self.local_engine.index("function Remove-MensorCadLocalPackage") :],
            "la limpieza del paquete local debe reutilizar Remove-MensorCadTree",
        )
        self.assertIn(
            "$script:MensorCadReleaseInstallerAssetName",
            self.local_engine,
            "solo se ejecuta el instalador incluido en el paquete extraido",
        )
        self.assertIn("Invoke-MensorCadRemoteChild", self.local_engine, "la transferencia y elevacion se reutilizan")
        self.assertIn("Write-MensorCadRelayedOutput", self.local_engine, "la salida del instalador se retransmite")

    def test_una_sola_cabecera_visible_y_la_presenta_el_proceso_visible(self) -> None:
        # La identidad la dibuja solo el proceso que la persona mira. El hijo
        # reenviado recibe la marca reservada y no repite el encabezado, asi la
        # terminal interactiva y los logs muestran una unica cabecera.
        self.assertIn(
            "$script:MensorCadRelayedChild = ($env:MENSORCAD_RELAYED_CHILD -eq '1')",
            self.installer,
            "el motor debe derivar la marca reservada del entorno",
        )
        banner = self.installer[self.installer.index("function Write-MensorCadBanner") :]
        banner = banner[: banner.index("\nfunction ")]
        self.assertIn(
            "if ($script:MensorCadRelayedChild) {",
            banner,
            "el banner debe apagarse en un hijo reenviado",
        )
        self.assertLess(
            banner.index("if ($script:MensorCadRelayedChild) {"),
            banner.index("if ($script:MensorCadPlainMode) {"),
            "la marca reservada debe evaluarse antes de cualquier encabezado",
        )
        local_install = self.local_engine[self.local_engine.index("function Install-MensorCadLocalPackage") :]
        local_install = local_install[: local_install.index("\nfunction ")]
        self.assertEqual(
            1,
            local_install.count("Write-MensorCadBanner"),
            "la instalacion local debe presentar el encabezado exactamente una vez",
        )
        self.assertLess(
            local_install.index("Write-MensorCadBanner"),
            local_install.index("Write-MensorCadInfo"),
            "el encabezado debe ir antes del primer informe de la ruta local",
        )
        remote_child = self.installer[self.installer.index("function Invoke-MensorCadRemoteChild") :]
        remote_child = remote_child[: remote_child.index("\nfunction ")]
        self.assertIn("$env:MENSORCAD_RELAYED_CHILD = '1'", remote_child, "el hijo debe recibir la marca reservada")
        self.assertIn(
            "[Environment]::SetEnvironmentVariable('MENSORCAD_RELAYED_CHILD', $previousRelayMark)",
            remote_child,
            "la marca reservada debe restaurarse siempre en el proceso visible",
        )
        self.assertIn("MENSORCAD_RELAYED_CHILD=1", self.installer, "la ayuda debe listar la marca reservada")
        self.assertIn("Una sola cabecera visible", self.docs, "la guia del gestor debe documentar la cabecera unica")

    def test_engine_local_no_descarga_no_eleva_ni_abre_parametros_nuevos(self) -> None:
        for prohibido in (
            "Invoke-WebRequest",
            "Invoke-RestMethod",
            "Save-MensorCadRemoteFile",
            "Get-MensorCadRemoteText",
            "Resolve-MensorCadReleaseTag",
            "Start-Process",
            "RunAs",
            "Install-MensorCadBundle",
            "Uninstall-MensorCadBundle",
            "ApplicationPlugins",
        ):
            self.assertNotIn(
                prohibido,
                self.local_engine,
                f"la entrada local no debe incluir {prohibido}",
            )
        param_block = self.installer[
            self.installer.index("param(") : self.installer.index("\n)", self.installer.index("param(")) + 2
        ]
        self.assertNotIn("LocalZip", param_block, "la entrada local no agrega una opcion publica al motor")
        self.assertIn("MensorCadLocalPackagePrefix", self.local_engine, "la carpeta propia debe tener prefijo propio")
        self.assertIn("no autentica", self.local_engine, "el SHA-256 no autentica al publicador")

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
            "-LocalZip",
            "MensorCAD-Windows.zip.sha256",
            "solo se admite",
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
            "-LocalZip",
            "MensorCAD-Windows.zip",
            "local-child|ran",
            "mensorcad-local-",
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
