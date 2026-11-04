"""Contrato estructural del bootstrap que registra el gestor ``mensorcad``.

El bootstrap publicado (``install.ps1``) ya no instala el complemento: resuelve
un unico release oficial, valida el ZIP del gestor y lo registra en el PATH del
usuario. Estas pruebas leen texto y aplican expresiones regulares: NO ejecutan
PowerShell, NO descargan nada y NO demuestran que la instalacion funcione. La
ejecucion funcional vive en ``tests/Test-CliBootstrap.ps1`` y requiere Windows
PowerShell 5.1.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "install.ps1"
DOCS = ROOT / "docs" / "cli-bootstrap.md"
FUNCTIONAL = ROOT / "tests" / "Test-CliBootstrap.ps1"
REGISTRY_PROBE = ROOT / "tests" / "Test-CliBootstrapRegistry.ps1"

LATEST_COMMAND = (
    "irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/"
    "install.ps1' -ea Stop | iex"
)
PINNED_COMMAND = (
    "&([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/"
    "download/v1.2.3/install.ps1' -ea Stop))) -Version v1.2.3"
)
NO_ANIMATION_COMMAND = PINNED_COMMAND + " -NoAnimation"

MANAGER_FILES = ("mensorcad.ps1", "mensorcad.cmd", "Install-MensorCAD.ps1")

# Nada de elevacion, PATH de maquina, politica de ejecucion global ni procesos
# hijos: este bootstrap solo escribe el gestor y el PATH del usuario actual.
FORBIDDEN_FRAGMENTS = (
    "HKLM",
    "HKEY_LOCAL_MACHINE",
    "HKEY_CURRENT_USER",
    "setx",
    "Set-ExecutionPolicy",
    "RunAs",
    "Program Files",
    "$PROFILE",
    "Set-ItemProperty",
    "New-ItemProperty",
    "Remove-ItemProperty",
    "Set-EnvironmentVariable",
    "Start-Process",
    "Stop-Process",
    "powershell.exe",
    "FromRelease",
    "Expand-Archive",
    "Install-MensorCadBundle",
    "Uninstall-MensorCadBundle",
    "bundle.sha256",
    "MensorCAD.bundle",
    "reg add",
    "reg.exe",
)

SIDECAR_PATTERN_FRAGMENT = r"^(?<hash>[0-9a-fA-F]{64})  MensorCAD-CLI\.zip\r?\n\z"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


class CliBootstrapStructureTests(unittest.TestCase):
    """Forma del bootstrap; no sustituye a la suite funcional de Windows."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = BOOTSTRAP.read_bytes() if BOOTSTRAP.is_file() else b""
        cls.bootstrap = (
            cls.raw.decode("ascii") if cls.raw and all(b < 0x80 for b in cls.raw) else cls.raw.decode("utf-8-sig")
        )
        cls.docs = read_text(DOCS) if DOCS.is_file() else ""
        cls.docs_flat = re.sub(r"\s+", " ", cls.docs)
        cls.functional = read_text(FUNCTIONAL) if FUNCTIONAL.is_file() else ""
        cls.lower = cls.bootstrap.lower()

    def test_el_asset_es_ascii_sin_bom_y_con_salto_final(self) -> None:
        # El archivo llega por HTTP y se ejecuta con [scriptblock]::Create: un
        # BOM UTF-8 se interpreta como texto basura delante de param y el
        # arranque falla con CommandNotFoundException. Por eso es ASCII puro.
        self.assertTrue(BOOTSTRAP.is_file(), f"falta {BOOTSTRAP}")
        self.assertFalse(self.raw.startswith(b"\xef\xbb\xbf"), "el bootstrap no debe llevar BOM")
        self.assertTrue(all(byte < 0x80 for byte in self.raw), "el bootstrap debe ser ASCII")
        self.assertTrue(b"\r" not in self.raw.replace(b"\r\n", b""), "hay CR sueltos")
        self.assertTrue(self.raw.endswith(b"\n"), "falta el salto de linea final")

    def test_conserva_las_banderas_publicas_documentadas(self) -> None:
        self.assertIn("param(", self.bootstrap)
        self.assertIn("[string]$Version", self.bootstrap)
        self.assertIn("[switch]$NoAnimation", self.bootstrap)
        self.assertIn("$PSBoundParameters.ContainsKey('Version')", self.bootstrap)
        public_params = self.bootstrap[: self.bootstrap.index("& {")]
        for prohibida in (
            "[switch]$FromRelease",
            "[switch]$Uninstall",
            "[switch]$ElevatedProcess",
            "[string]$Path",
            "[string]$Destination",
            "[string]$Repository",
        ):
            self.assertNotIn(prohibida, public_params, f"el bootstrap no debe aceptar {prohibida}")

    def test_no_cierra_la_sesion_del_llamador(self) -> None:
        self.assertIsNone(
            re.search(r"(?m)^\s*exit\b", self.bootstrap),
            "un exit en el ambito del llamador cerraria la sesion bajo iex",
        )
        self.assertIn("$global:LASTEXITCODE", self.bootstrap, "falta el contrato de salida")
        self.assertIsNone(
            re.search(r"(?m)^\s*\.\s+\$", self.bootstrap),
            "no se debe hacer dot-sourcing de nada descargado",
        )

    def test_resuelve_el_release_oficial_una_sola_vez(self) -> None:
        self.assertIn("'RonGrasz/Mensor-CAD'", self.bootstrap)
        self.assertIn("https://github.com", self.bootstrap)
        self.assertIn("https://api.github.com", self.bootstrap)
        self.assertIn("/releases/latest", self.bootstrap)
        self.assertIn("/releases/download/", self.bootstrap)
        self.assertEqual(
            self.bootstrap.count("/releases/latest"),
            1,
            "el release se resuelve una sola vez; no se debe volver a consultar",
        )
        self.assertNotIn(
            "latest/download",
            self.bootstrap,
            "el ZIP debe salir del tag fijado, no de /latest/download",
        )
        self.assertIn("Invoke-RestMethod", self.bootstrap)
        self.assertIn("Invoke-WebRequest", self.bootstrap)
        self.assertIn("-UseBasicParsing", self.bootstrap)
        self.assertIn("-ErrorAction Stop", self.bootstrap)

    def test_descarga_el_zip_del_gestor_y_su_sidecar(self) -> None:
        self.assertIn("'MensorCAD-CLI.zip'", self.bootstrap)
        self.assertIn("'MensorCAD-CLI.zip.sha256'", self.bootstrap)
        self.assertIn("-OutFile", self.bootstrap)

    def test_valida_el_sha256_y_las_entradas_exactas_del_zip(self) -> None:
        self.assertIn("Get-FileHash", self.bootstrap)
        self.assertIn("-Algorithm SHA256", self.bootstrap)
        self.assertIn(SIDECAR_PATTERN_FRAGMENT, self.bootstrap, "falta el formato estricto del sidecar")
        self.assertIn("ZipFile]::OpenRead", self.bootstrap)
        self.assertIn(
            "$managerFiles = @('mensorcad.ps1', 'mensorcad.cmd', 'Install-MensorCAD.ps1')",
            self.bootstrap,
            "el ZIP debe declarar exactamente los tres archivos del gestor",
        )
        for nombre in MANAGER_FILES:
            self.assertIn(nombre, self.bootstrap, f"falta {nombre}")
        self.assertIn("ReparsePoint", self.bootstrap, "faltan las comprobaciones de enlaces")
        for tope in ("$maxZipBytes", "$maxEntryBytes", "$maxTotalEntryBytes"):
            self.assertIn(tope, self.bootstrap, f"falta el tope {tope}")

    def test_no_ejecuta_ningun_script_descargado(self) -> None:
        self.assertNotIn("FromRelease", self.bootstrap)
        self.assertNotIn("Expand-Archive", self.bootstrap)
        self.assertNotIn("Start-Process", self.bootstrap)
        self.assertNotIn("powershell.exe", self.bootstrap)

    def test_instala_solo_el_gestor_en_la_carpeta_fija_del_usuario(self) -> None:
        self.assertIn("$env:LOCALAPPDATA", self.bootstrap)
        self.assertIn("'MensorCAD'", self.bootstrap)
        self.assertIn("'cli'", self.bootstrap)
        self.assertIn("'.mensorcad-cli.json'", self.bootstrap, "falta el marcador propio")
        self.assertIn("'cli.staging-'", self.bootstrap)
        self.assertIn("'cli.backup-'", self.bootstrap)
        self.assertIn("[guid]::NewGuid().ToString('N')", self.bootstrap)

    def test_registra_solo_el_path_del_usuario_preservando_el_tipo(self) -> None:
        self.assertIn("'HKCU:\\Environment'", self.bootstrap)
        self.assertIn("GetValueKind", self.bootstrap)
        self.assertIn("SetValue", self.bootstrap)
        self.assertIn("DoNotExpandEnvironmentNames", self.bootstrap)
        self.assertIn("RegistryValueKind", self.bootstrap)
        self.assertIn("$env:Path", self.bootstrap, "falta actualizar el PATH del proceso actual")

    def test_abre_acceso_de_escritura_propio_y_cierra_las_asas(self) -> None:
        # El proveedor entrega la clave en solo lectura: el bootstrap abre un
        # acceso propio con escritura y lo cierra siempre. No cambia permisos.
        abrir = self.bootstrap[self.bootstrap.index("function Get-CliBootstrapEnvironmentKey") :]
        abrir = abrir[: abrir.index("function Get-CliBootstrapPathEntryKey")]
        self.assertIn("Get-Item -LiteralPath $userEnvironmentKeyPath -Force", abrir)
        self.assertIn("OpenSubKey('', $true)", abrir, "falta abrir el acceso propio con escritura")
        self.assertIn("$providerKey.Close()", abrir, "falta cerrar el acceso del proveedor")
        self.assertIn("finally", abrir, "el cierre debe ocurrir aunque falle la apertura")
        escribir = self.bootstrap[self.bootstrap.index("function Set-CliBootstrapUserPath") :]
        escribir = escribir[: escribir.index("function Add-CliBootstrapProcessPath")]
        self.assertIn("$key.Close()", escribir, "falta cerrar el acceso propio")
        self.assertIn("finally", escribir, "el acceso propio debe cerrarse en exito, no-op y fallo")
        for fragmento in ("SetAccessControl", "RegistrySecurity", "TakeOwnership"):
            self.assertNotIn(fragmento, self.bootstrap, "el bootstrap no debe cambiar permisos ni ACLs")

    def test_no_muta_configuracion_global_ni_pide_elevacion(self) -> None:
        for fragmento in FORBIDDEN_FRAGMENTS:
            self.assertNotIn(
                fragmento.lower(),
                self.lower,
                f"el bootstrap no debe usar {fragmento}",
            )

    def test_requiere_windows_y_reporta_errores_en_stderr(self) -> None:
        self.assertIn("[PlatformID]::Win32NT", self.bootstrap)
        self.assertIn("[Console]::Error.WriteLine", self.bootstrap)
        self.assertIn("ERROR: ", self.bootstrap)
        self.assertIn("No se instalo nada", self.bootstrap)
        self.assertIn("Se restauro la instalacion anterior", self.bootstrap)

    def test_valida_el_tag_antes_de_la_red_y_de_las_escrituras(self) -> None:
        patron = self.bootstrap.index("$releaseTagPattern = ")
        primera_red = self.bootstrap.index("Invoke-WebRequest")
        self.assertLess(patron, primera_red, "el tag debe validarse antes de descargar")
        self.assertIn("-notmatch", self.bootstrap)

    def test_tls12_se_fija_antes_de_la_primera_descarga(self) -> None:
        tls = self.bootstrap.index("SecurityProtocolType]::Tls12")
        primera_descarga = self.bootstrap.index("Save-CliBootstrapAsset -AssetName $cliAssetName")
        self.assertLess(tls, primera_descarga)
        self.assertIn("SecurityProtocol", self.bootstrap)

    def test_la_validacion_del_zip_precede_a_la_escritura_del_gestor(self) -> None:
        hash_pos = self.bootstrap.index("Get-FileHash")
        zip_pos = self.bootstrap.index("ZipFile]::OpenRead")
        staging_pos = self.bootstrap.index("New-CliBootstrapStagingDirectory")
        self.assertLess(hash_pos, staging_pos, "el hash debe validarse antes de preparar el destino")
        self.assertLess(zip_pos, staging_pos, "el ZIP debe validarse antes de preparar el destino")

    def test_acepta_el_zip_local_ademas_de_la_ruta_remota(self) -> None:
        self.assertIn("[string]$LocalZip", self.bootstrap)
        self.assertIn("$LocalZipSpecified", self.bootstrap)
        self.assertIn("$localZipSpecified", self.bootstrap)
        self.assertIn("LocalZipSpecified", self.bootstrap)

    def test_la_ruta_local_copia_la_entrada_antes_de_validarla(self) -> None:
        # El archivo elegido por el usuario es mutable: se copia a la carpeta
        # temporal propia y desde ahi se valida y se instala.
        self.assertIn("[System.IO.File]::Copy", self.bootstrap)
        copia = self.bootstrap.index("Copy-CliBootstrapLocalAsset -SourcePath $localZipPath")
        sidecar = self.bootstrap.index("$expectedHash = Read-CliBootstrapSidecarHash")
        staging = self.bootstrap.index("New-CliBootstrapStagingDirectory -ManagedRootPath $managedRoot")
        self.assertLess(copia, sidecar, "la copia propia debe existir antes del SHA-256")
        self.assertLess(sidecar, staging, "el SHA-256 debe validarse antes del staging")

    def test_la_ruta_local_rechaza_entradas_incompatibles_antes_de_la_red(self) -> None:
        for fragmento in (
            "Las opciones -LocalZip y -Version no se pueden combinar",
            "La opcion -LocalZip necesita la ruta de un ZIP local",
            "No se encontro el ZIP local indicado",
            "Falta el sidecar SHA256 junto al ZIP local",
        ):
            self.assertIn(fragmento, self.bootstrap, f"falta el rechazo local: {fragmento}")
        conflicto = self.bootstrap.index("$localZipSpecified -and $versionSpecified")
        entrada = self.bootstrap.index("Assert-CliBootstrapLocalInput -ZipPath $localZipPath")
        primera_descarga = self.bootstrap.index("Save-CliBootstrapAsset -AssetName $cliAssetName")
        staging = self.bootstrap.index("New-CliBootstrapStagingDirectory -ManagedRootPath $managedRoot")
        self.assertLess(conflicto, entrada, "el choque de opciones se rechaza antes de leer la entrada")
        self.assertLess(entrada, primera_descarga, "la entrada local se valida antes de la red")
        self.assertLess(entrada, staging, "la entrada local se valida antes de escribir el destino")

    def test_la_ruta_local_relativa_se_resuelve_en_la_sesion(self) -> None:
        # Set-Location no cambia el directorio del proceso, asi que una ruta
        # relativa se resuelve con el proveedor de archivos de PowerShell y no
        # con [IO.Path]::GetFullPath.
        self.assertIn("GetUnresolvedProviderPathFromPSPath", self.bootstrap)
        self.assertNotIn("[System.IO.Path]::GetFullPath($Value)", self.bootstrap)
        resolucion = self.bootstrap.index("GetUnresolvedProviderPathFromPSPath")
        entrada = self.bootstrap.index("Assert-CliBootstrapLocalInput -ZipPath $localZipPath")
        self.assertLess(resolucion, entrada, "la ruta se resuelve antes de comprobar la entrada")
        self.assertIn("'FileSystem'", self.bootstrap, "falta exigir el proveedor de archivos")

    def test_la_version_local_sale_del_gestor_leido_como_texto(self) -> None:
        self.assertIn("MensorCadManagerVersion", self.bootstrap)
        self.assertIn("Read-CliBootstrapLocalManagerVersion", self.bootstrap)
        self.assertIn("[0-9]+\\.[0-9]+\\.[0-9]+", self.bootstrap, "falta el patron de version estable")
        # El texto del gestor se lee y se compara con una expresion regular; no
        # hay ninguna ejecucion del archivo extraido.
        self.assertIn("ReadAllText", self.bootstrap)
        self.assertNotIn("Invoke-Expression", self.bootstrap)
        self.assertIn("Regex]::Match", self.bootstrap)


class CliBootstrapDocsTests(unittest.TestCase):
    """La documentacion publica debe describir el flujo real de dos pasos."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.docs = read_text(DOCS) if DOCS.is_file() else ""
        cls.docs_flat = re.sub(r"\s+", " ", cls.docs)

    def test_existe_la_guia_del_bootstrap(self) -> None:
        self.assertTrue(DOCS.is_file(), f"falta {DOCS}")

    def test_documenta_los_comandos_publicados_exactos(self) -> None:
        for comando in (LATEST_COMMAND, PINNED_COMMAND, NO_ANIMATION_COMMAND):
            self.assertIn(comando, self.docs, f"falta el comando documentado: {comando}")

    def test_documenta_el_destino_y_el_flujo_de_dos_pasos(self) -> None:
        self.assertIn("%LOCALAPPDATA%\\MensorCAD\\cli", self.docs_flat)
        self.assertIn("mensorcad install", self.docs_flat)
        self.assertIn("---", self.docs, "la guia debe separar el paso 1 del paso 2")
        for fragmento in (".mensorcad-cli.json", "MensorCAD-CLI.zip", "MensorCAD-CLI.zip.sha256"):
            self.assertIn(fragmento, self.docs_flat)

    def test_documenta_parametros_y_contrato_de_salida(self) -> None:
        self.assertIn("-Version", self.docs_flat)
        self.assertIn("-NoAnimation", self.docs_flat)
        self.assertIn("LASTEXITCODE", self.docs_flat)
        self.assertIn("Windows PowerShell 5.1", self.docs_flat)
        self.assertIn("terminal nueva", self.docs_flat)

    def test_documenta_el_path_de_usuario_sin_tocar_el_de_maquina(self) -> None:
        self.assertIn("PATH", self.docs_flat)
        self.assertIn("REG_EXPAND_SZ", self.docs_flat)
        self.assertIn("REG_SZ", self.docs_flat)
        self.assertIn("PATH de maquina", self.docs_flat)
        self.assertIn("una sola vez", self.docs_flat)

    def test_describe_la_publicacion_y_no_autentica_al_editor(self) -> None:
        # La release oficial publica los seis artefactos; la guia lo dice y a la
        # vez conserva el limite de confianza del SHA-256.
        self.assertTrue(
            re.search(r"publica los seis artefactos", self.docs_flat, re.IGNORECASE),
            "la guia debe describir el release que publica los seis artefactos",
        )
        self.assertTrue(
            re.search(r"no autentica al publicador|no autentica el origen", self.docs_flat, re.IGNORECASE),
            "la guia debe aclarar que el SHA256 no autentica al publicador",
        )
        self.assertIn("se restaura la instalacion anterior", self.docs_flat.lower())

    def test_no_documenta_ejecutar_los_scripts_descargados(self) -> None:
        self.assertTrue(
            re.search(r"no se ejecuta", self.docs_flat, re.IGNORECASE),
            "la guia debe aclarar que los scripts descargados no se ejecutan",
        )

    def test_documenta_la_instalacion_local_sin_publicar(self) -> None:
        self.assertIn("-LocalZip .\\dist\\MensorCAD-CLI.zip", self.docs)
        self.assertIn("tools/build_bundle.py --output-dir dist", self.docs_flat)
        self.assertIn("MensorCAD-CLI.zip.sha256", self.docs_flat)
        self.assertIn("adjunto", self.docs_flat)
        self.assertIn("mutuamente excluyentes", self.docs_flat)

    def test_documenta_las_rutas_relativas_de_la_entrada_local(self) -> None:
        self.assertIn("Ruta relativa", self.docs_flat)
        self.assertIn("carpeta actual de su sesion de PowerShell", self.docs_flat)

    def test_documenta_el_acceso_de_escritura_sin_permisos_nuevos(self) -> None:
        self.assertIn("Acceso de escritura sin permisos nuevos", self.docs)
        self.assertIn("solo lectura", self.docs_flat)
        self.assertIn("No se puede escribir en la clave del Registro", self.docs_flat)
        self.assertIn("no se tocan ACLs", self.docs_flat)
        self.assertIn("no se eleva el proceso", self.docs_flat)
        self.assertIn("cierra siempre los accesos que abre", self.docs_flat)

    def test_documenta_la_sonda_manual_del_registro_real(self) -> None:
        self.assertIn("Test-CliBootstrapRegistry.ps1", self.docs_flat)
        self.assertIn("HKCU:\\Software\\MensorCAD-Bootstrap-Probe", self.docs_flat)
        self.assertIn("sin tocarla", self.docs_flat)
        self.assertIn("opt-in", self.docs_flat)
        self.assertIn("no forma parte de la suite por defecto", self.docs_flat.lower())

    def test_la_confianza_local_queda_declarada(self) -> None:
        # El hash solo prueba integridad; la confianza la aporta la persona que
        # eligio la compilacion. La guia tiene que decirlo sin ambiguedad.
        self.assertIn("integridad, no confianza", self.docs_flat)
        self.assertIn("confiar en la compilacion", self.docs_flat)
        self.assertIn("no autentica al autor", self.docs_flat)


class CliBootstrapFunctionalHarnessTests(unittest.TestCase):
    """La suite funcional debe existir y aislarse de red y registro reales."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.functional = read_text(FUNCTIONAL) if FUNCTIONAL.is_file() else ""

    def test_existe_la_suite_funcional_de_windows(self) -> None:
        self.assertTrue(FUNCTIONAL.is_file(), f"falta {FUNCTIONAL}")

    def test_aisla_registro_red_y_carpetas_del_usuario(self) -> None:
        for fragmento in (
            "HKCU:\\Environment",
            "Invoke-RestMethod",
            "Invoke-WebRequest",
            "MCB_LOCALAPPDATA",
            "MCB_REGISTRY",
            "GetValueKind",
        ):
            self.assertIn(fragmento, self.functional, f"la suite funcional debe aislar {fragmento}")
        self.assertIn("PayloadSentinel", self.functional, "falta comprobar que el payload no se ejecuta")

    def test_cubre_la_ruta_local_sin_red(self) -> None:
        self.assertIn("-LocalZip", self.functional, "la suite funcional debe cubrir la ruta local")
        self.assertIn("Assert-SinRed", self.functional, "falta contar cero consultas y cero descargas")
        self.assertIn("New-LocalCliInput", self.functional, "falta la fixture del ZIP local")

    def test_modela_el_acceso_de_solo_lectura_y_el_cierre_de_asas(self) -> None:
        for fragmento in (
            "OpenSubKey",
            "No se puede escribir en la clave del Registro.",
            "WritableOpens",
            "WritableClosed",
            "Assert-RegistryHandlesReleased",
        ):
            self.assertIn(fragmento, self.functional, f"la suite simulada debe modelar {fragmento}")

    def test_la_sonda_de_registro_real_es_manual_y_esta_aislada(self) -> None:
        # Sonda dedicada y opt-in: no la descubre ni la ejecuta la suite por
        # defecto, y solo escribe en la clave privada autorizada.
        self.assertTrue(REGISTRY_PROBE.is_file(), f"falta {REGISTRY_PROBE}")
        probe = read_text(REGISTRY_PROBE)
        self.assertIn("HKCU:\\Software\\MensorCAD-Bootstrap-Probe", probe)
        self.assertIn("si la clave ya existe, la sonda se detiene SIN TOCARLA", probe)
        self.assertIn("Remove-Item -LiteralPath $script:ProbeKeyPath -Recurse -Force", probe)
        self.assertIn("Get-RealUserPath", probe, "falta comprobar que el PATH real no cambia")
        self.assertIn("throw 'RED PROHIBIDA", probe, "la sonda real debe cerrar la red")
        self.assertIn("odd\\artifacts\\bootstrap-registry-writable", probe)
        self.assertNotIn("Test-CliBootstrapRegistry", self.functional, "la suite por defecto no debe ejecutar la sonda real")


if __name__ == "__main__":
    unittest.main()
