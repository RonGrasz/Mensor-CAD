"""Arranque real del asset publicado ``install.ps1`` en Windows PowerShell 5.1.

El comando corto publica el archivo por HTTP y lo ejecuta con
``[scriptblock]::Create``. El cliente HTTP entrega el cuerpo decodificado como
Latin-1 cuando no reconoce el BOM, no como UTF-8: un BOM al inicio de
``install.ps1`` llega al interprete como texto basura delante de ``param`` y el
arranque se rompe con ``CommandNotFoundException``. Estas pruebas reproducen esa
decodificacion y ejecutan el archivo real.

Nada sale de la maquina ni del proyecto: cada corrida usa una carpeta temporal
propia dentro de ``odd/artifacts/persistent-cli/bootstrap`` y apunta TEMP, TMP y
LOCALAPPDATA ahi antes de invocar el script. La API y la descarga del release se
interceptan las dos con centinelas contados, de modo que ninguna peticion real
puede salir aunque el arranque por BOM ejecute el flujo completo. No se tocan
Program Files, no se pide UAC, no se autentica, no se cambia configuracion
global y no se llama a GitHub. La sonda exige Windows PowerShell Desktop 5.1 y
se rechaza en cualquier otro interprete.
"""

from __future__ import annotations

import base64
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parents[1]
BOOTSTRAP = RAIZ_REPO / "install.ps1"
# Scratch ignorado por git: aqui viven las carpetas aisladas de cada corrida.
CARPETA_SCRATCH = RAIZ_REPO / "odd" / "artifacts" / "persistent-cli" / "bootstrap"
POWERSHELL = "powershell.exe"
WSLPATH = "wslpath"
# iso-8859-1: la decodificacion que aplica el cliente HTTP al no ver un BOM.
CODIFICACION_LATIN1 = 28591
SALIDA_POWERSHELL = "utf-8"
TIMEOUT_SONDA = 120
TIMEOUT_RUTA = 60
# Objetivo del release oficial: no debe consultarse la red real.
API_LATEST = "https://api.github.com/repos/RonGrasz/Mensor-CAD/releases/latest"
MARCA_CENTINELA = "CENTINELA-NEW-ITEM"
MARCA_API = "CENTINELA-API"
MARCA_DESCARGA = "CENTINELA-DESCARGA"
TAG_INVALIDO = "v0.1.0/malo"
# Los dos objetivos exactos de CommandNotFoundException que reporto el usuario.
CNF_MOJIBAKE = "00EF,00BB,00BF,0023,"  # '#' con el BOM interpretado como Latin-1
CNF_PARAM = "0070,0061,0072,0061,006D,"  # 'param'
ERROR_TAG_INVALIDO = (
    "ERROR: El tag de -Version no es valido: "
    + TAG_INVALIDO
    + ". Se espera un tag como v1.2.3. No se descargo nada ni se escribio nada.<LF>"
)
# Error exacto del flujo por defecto: la API controlada corta antes de descargar.
ERROR_API_CENTINELA = (
    "ERROR: No se pudo consultar el release oficial de MensorCAD: "
    + MARCA_API
    + " No se instalo nada.<LF>"
)

# Sonda ASCII: lee los bytes reales del asset, los decodifica como Latin-1 y los
# ejecuta con el mismo punto de entrada publico (scriptblock con parametros).
# TEMP, TMP y LOCALAPPDATA se fijan a la carpeta aislada de la corrida ANTES de
# ejecutar el asset, y las dos fronteras de red (API y descarga) se interceptan
# con centinelas contados. Toda la evidencia se emite como lineas ASCII
# ``SONDA-*`` para no depender de la codificacion de la consola ni de los
# mensajes localizados de PowerShell.
SONDA = r"""
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ruta = @@RUTA@@
$modo = '@@MODO@@'
$tempAislado = @@TEMP@@
$localAislado = @@LOCALAPPDATA@@

# Guarda explicita: esta evidencia solo vale en Windows PowerShell Desktop 5.1.
# En cualquier otro interprete la sonda se rechaza en voz alta en vez de medir
# el arranque con un motor distinto.
$versionPs = $PSVersionTable.PSVersion
$edicionPs = [string]$PSVersionTable.PSEdition
if (($versionPs.Major -ne 5) -or ($versionPs.Minor -ne 1) -or ($edicionPs -ne 'Desktop')) {
    [Console]::Out.WriteLine('SONDA-INTERPRETE=rechazado')
    throw [System.InvalidOperationException]::new('SE-REQUIERE-WINDOWS-POWERSHELL-5.1-DESKTOP')
}
[Console]::Out.WriteLine('SONDA-INTERPRETE=' + $edicionPs + '-' + $versionPs.Major + '.' + $versionPs.Minor)
[Console]::Out.WriteLine('SONDA-VERSION=' + $versionPs.ToString())
[Console]::Out.WriteLine('SONDA-ARRANQUE=ok')

# Aislamiento real de las carpetas del usuario: todo queda en el scratch del
# proyecto, nunca en el perfil real ni fuera de la raiz permitida.
$env:TEMP = $tempAislado
$env:TMP = $tempAislado
$env:LOCALAPPDATA = $localAislado

$bytes = [System.IO.File]::ReadAllBytes($ruta)
$texto = [System.Text.Encoding]::GetEncoding(@@LATIN1@@).GetString($bytes)

# Red interceptada por completo: API y descarga cuentan y fallan con centinela.
$global:SondaApi = 0
$global:SondaApiUri = ''
$global:SondaDescargas = 0
$global:SondaUrlDescarga = ''
$global:SondaEscrituras = 0
function Invoke-RestMethod {
    param([switch]$UseBasicParsing, [Parameter(Position = 0)][string]$Uri, [hashtable]$Headers)
    $global:SondaApi = $global:SondaApi + 1
    $global:SondaApiUri = [string]$Uri
    throw [System.InvalidOperationException]::new('@@MARCA_API@@')
}
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [Parameter(Position = 0)][string]$Uri, [string]$OutFile)
    $global:SondaDescargas = $global:SondaDescargas + 1
    $global:SondaUrlDescarga = [string]$Uri
    throw [System.InvalidOperationException]::new('@@MARCA_DESCARGA@@')
}
function New-Item {
    $global:SondaEscrituras = $global:SondaEscrituras + 1
    throw [System.InvalidOperationException]::new('@@CENTINELA@@')
}

$captura = New-Object System.IO.StringWriter
$stderrOriginal = [Console]::Error
[Console]::SetError($captura)
$Error.Clear()
$global:LASTEXITCODE = 4242
$terminante = 'ninguna'
try {
    $bloque = [scriptblock]::Create($texto)
    if ($modo -eq 'invalido') {
        & $bloque -Version '@@TAG@@'
    }
    else {
        & $bloque
    }
}
catch {
    $terminante = $_.Exception.GetType().FullName + ': ' + $_.Exception.Message
}
$codigo = $global:LASTEXITCODE
$cnf = @()
foreach ($registro in $Error) {
    if (([string]$registro.FullyQualifiedErrorId).StartsWith('CommandNotFoundException')) {
        $hex = ''
        foreach ($caracter in ([string]$registro.TargetObject).ToCharArray()) {
            $hex = $hex + ('{0:X4}' -f [int]$caracter) + ','
        }
        $cnf = $cnf + $hex
    }
}
[Console]::SetError($stderrOriginal)

$limpio = ''
# Los finales de linea de Windows (CRLF) se normalizan a <LF>; el resto de los
# caracteres no ASCII se emite como <U+XXXX> para que la evidencia sea ASCII.
foreach ($caracter in $captura.ToString().ToCharArray()) {
    $valor = [int]$caracter
    if ($valor -eq 10) { $limpio = $limpio + '<LF>' }
    elseif ($valor -eq 13) { }
    elseif ($valor -lt 32 -or $valor -gt 126) { $limpio = $limpio + '<U+' + ('{0:X4}' -f $valor) + '>' }
    else { $limpio = $limpio + $caracter }
}
[Console]::Out.WriteLine('SONDA-CODIGO=' + $codigo)
[Console]::Out.WriteLine('SONDA-API=' + $global:SondaApi)
[Console]::Out.WriteLine('SONDA-APIURI=' + $global:SondaApiUri)
[Console]::Out.WriteLine('SONDA-DESCARGAS=' + $global:SondaDescargas)
[Console]::Out.WriteLine('SONDA-URLDESCARGA=' + $global:SondaUrlDescarga)
[Console]::Out.WriteLine('SONDA-ESCRITURAS=' + $global:SondaEscrituras)
[Console]::Out.WriteLine('SONDA-TEMP=' + $env:TEMP)
[Console]::Out.WriteLine('SONDA-LOCALAPPDATA=' + $env:LOCALAPPDATA)
[Console]::Out.WriteLine('SONDA-TERMINANTE=' + $terminante)
[Console]::Out.WriteLine('SONDA-CNF=' + ($cnf -join '|'))
[Console]::Out.WriteLine('SONDA-ERROR=' + $limpio)
"""

CLAVES_SONDA = (
    "SONDA-INTERPRETE",
    "SONDA-VERSION",
    "SONDA-ARRANQUE",
    "SONDA-CODIGO",
    "SONDA-API",
    "SONDA-APIURI",
    "SONDA-DESCARGAS",
    "SONDA-URLDESCARGA",
    "SONDA-ESCRITURAS",
    "SONDA-TEMP",
    "SONDA-LOCALAPPDATA",
    "SONDA-TERMINANTE",
    "SONDA-CNF",
    "SONDA-ERROR",
)


def ruta_para_windows(ruta: Path) -> str:
    """Devuelve la ruta tal como la ve Windows (WSL) sin copiar el archivo."""
    convertidor = shutil.which(WSLPATH)
    if convertidor is None:
        return str(ruta)
    completado = subprocess.run(
        [convertidor, "-w", str(ruta)],
        capture_output=True,
        text=True,
        encoding=SALIDA_POWERSHELL,
        errors="replace",
        timeout=TIMEOUT_RUTA,
        check=False,
    )
    if completado.returncode != 0 or not completado.stdout.strip():
        raise AssertionError(
            f"{WSLPATH} no pudo convertir {ruta}: {completado.stderr.strip()}"
        )
    return completado.stdout.strip()


def literal_ps(texto: str) -> str:
    """Devuelve un literal de cadena de PowerShell 5.1 seguro."""
    return "'" + texto.replace("'", "''") + "'"


def construir_sonda(modo: str, rutas: dict) -> str:
    return (
        SONDA.replace("@@RUTA@@", literal_ps(rutas["ruta"]))
        .replace("@@MODO@@", modo)
        .replace("@@TAG@@", TAG_INVALIDO)
        .replace("@@CENTINELA@@", MARCA_CENTINELA)
        .replace("@@MARCA_API@@", MARCA_API)
        .replace("@@MARCA_DESCARGA@@", MARCA_DESCARGA)
        .replace("@@TEMP@@", literal_ps(rutas["temp"]))
        .replace("@@LOCALAPPDATA@@", literal_ps(rutas["localappdata"]))
        .replace("@@LATIN1@@", str(CODIFICACION_LATIN1))
    )


def leer_sonda(salida: str) -> dict:
    valores = {}
    for linea in salida.splitlines():
        if not linea.strip():
            continue
        clave, separador, valor = linea.partition("=")
        if not separador or clave not in CLAVES_SONDA:
            raise AssertionError(f"linea inesperada en la salida de la sonda: {linea!r}")
        if clave in valores:
            raise AssertionError(f"la sonda repitio {clave}")
        valores[clave] = valor
    if tuple(valores) != CLAVES_SONDA:
        raise AssertionError(f"la sonda no emitio todas sus claves: {tuple(valores)}")
    return valores


class BootstrapEncodingTests(unittest.TestCase):
    """El asset publicado debe arrancar limpio al decodificarse como Latin-1."""

    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which(POWERSHELL) is None:
            raise AssertionError(
                f"falta {POWERSHELL} en PATH: estas pruebas miden el arranque real"
            )
        if not BOOTSTRAP.is_file():
            raise AssertionError(f"falta {BOOTSTRAP}")
        cls.sonda_entrada = cls.ejecutar("normal")
        cls.sonda_tag = cls.ejecutar("invalido")

    @classmethod
    def ejecutar(cls, modo: str):
        """Lanza una sonda aislada de punta a punta con tiempo acotado.

        La carpeta temporal de Python se crea dentro del scratch ignorado del
        proyecto y se entrega a Windows ya convertida. TEMP, TMP y
        LOCALAPPDATA del proceso hijo apuntan ahi: ni el perfil real ni rutas
        fuera de la raiz permitida se tocan, incluso si el asset arranca mal.
        """
        CARPETA_SCRATCH.mkdir(parents=True, exist_ok=True)
        raiz = tempfile.TemporaryDirectory(
            prefix="bootstrap-encoding-", dir=str(CARPETA_SCRATCH)
        )
        cls.addClassCleanup(raiz.cleanup)
        temp = Path(raiz.name) / "temp"
        localappdata = Path(raiz.name) / "localappdata"
        temp.mkdir()
        localappdata.mkdir()
        rutas = {
            "ruta": ruta_para_windows(BOOTSTRAP),
            "temp": ruta_para_windows(temp),
            "localappdata": ruta_para_windows(localappdata),
        }
        sonda = construir_sonda(modo, rutas)
        codificada = base64.b64encode(sonda.encode("utf-16-le")).decode("ascii")
        entorno = dict(os.environ)
        entorno["TEMP"] = rutas["temp"]
        entorno["TMP"] = rutas["temp"]
        entorno["LOCALAPPDATA"] = rutas["localappdata"]
        completado = subprocess.run(
            [
                POWERSHELL,
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-EncodedCommand",
                codificada,
            ],
            capture_output=True,
            text=True,
            encoding=SALIDA_POWERSHELL,
            errors="replace",
            timeout=TIMEOUT_SONDA,
            check=False,
            cwd=str(RAIZ_REPO),
            env=entorno,
        )
        return completado, leer_sonda(completado.stdout), rutas, temp, localappdata

    def test_la_sonda_corre_en_windows_powershell_desktop_51(self) -> None:
        # La evidencia solo es valida en el motor que documenta el producto: la
        # sonda rechaza cualquier otro interprete antes de medir el arranque.
        _, valores, _, _, _ = self.sonda_entrada
        self.assertEqual(
            valores["SONDA-INTERPRETE"],
            "Desktop-5.1",
            "la sonda debe correr en Windows PowerShell Desktop 5.1",
        )
        self.assertTrue(
            valores["SONDA-VERSION"].startswith("5.1."),
            f"version medida inesperada: {valores['SONDA-VERSION']}",
        )

    def test_el_arranque_no_reporta_comandos_inexistentes(self) -> None:
        completado, valores, _, _, _ = self.sonda_entrada
        self.assertEqual(
            valores["SONDA-ARRANQUE"],
            "ok",
            "la sonda no llego a ejecutarse; revisar la salida de PowerShell",
        )
        self.assertEqual(
            valores["SONDA-CNF"],
            "",
            "el arranque reporto CommandNotFoundException (objetivos en hexadecimal): "
            + valores["SONDA-CNF"],
        )
        for objetivo in (CNF_MOJIBAKE, CNF_PARAM):
            self.assertNotIn(
                objetivo,
                valores["SONDA-CNF"],
                f"el arranque no debe intentar ejecutar {objetivo} como comando",
            )
        self.assertNotIn(
            "CommandNotFoundException",
            completado.stdout + completado.stderr,
            f"PowerShell reporto comandos inexistentes al arrancar: {completado.stderr.strip()}",
        )

    def test_la_entrada_por_defecto_usa_la_api_oficial_sin_descargar(self) -> None:
        # El flujo por defecto resuelve el release UNA vez. La sonda intercepta
        # Invoke-RestMethod y lo corta con un centinela: la evidencia demuestra
        # que la unica frontera que se toca es la API oficial, sin red real.
        completado, valores, _, _, _ = self.sonda_entrada
        self.assertEqual(completado.returncode, 0, completado.stderr.strip())
        self.assertEqual(
            completado.stderr,
            "",
            "el stderr del proceso debe quedar vacio: solo la sonda escribe en stdout",
        )
        self.assertEqual(valores["SONDA-CODIGO"], "1", "el codigo de salida debe ser 1")
        self.assertEqual(valores["SONDA-API"], "1", "se resuelve el release una sola vez")
        self.assertEqual(
            valores["SONDA-APIURI"],
            API_LATEST,
            "la consulta debe ir a la API del repositorio oficial",
        )
        self.assertEqual(valores["SONDA-DESCARGAS"], "0", "no debe descargarse nada")
        self.assertEqual(
            valores["SONDA-URLDESCARGA"], "", "no debe existir URL de descarga"
        )
        self.assertEqual(
            valores["SONDA-ESCRITURAS"],
            "0",
            "el bootstrap no debe usar cmdlets de escritura (usa .NET dentro de la carpeta aislada)",
        )
        self.assertEqual(valores["SONDA-TERMINANTE"], "ninguna", "no debe haber error terminante")
        self.assertEqual(valores["SONDA-CNF"], "", "el arranque no puede reportar comandos rotos")
        self.assertEqual(
            valores["SONDA-ERROR"],
            ERROR_API_CENTINELA,
            "el error controlado de la API es el unico que puede escribirse en stderr",
        )

    def test_la_entrada_por_defecto_aisla_carpetas_y_no_persiste_archivos(self) -> None:
        completado, valores, rutas, temp, localappdata = self.sonda_entrada
        self.assertEqual(completado.returncode, 0, completado.stderr.strip())
        self.assertEqual(
            valores["SONDA-TEMP"],
            rutas["temp"],
            "el proceso hijo debe ver TEMP aislado en el scratch del proyecto",
        )
        self.assertEqual(
            valores["SONDA-LOCALAPPDATA"],
            rutas["localappdata"],
            "el proceso hijo debe ver LOCALAPPDATA aislado en el scratch del proyecto",
        )
        self.assertEqual(
            [ruta.name for ruta in temp.iterdir()],
            [],
            "la carpeta temporal aislada debe quedar vacia (sin carpetas propias colgadas)",
        )
        self.assertEqual(
            [ruta.name for ruta in localappdata.iterdir()],
            [],
            "la carpeta LOCALAPPDATA aislada debe quedar vacia",
        )
        self.assertFalse(
            (localappdata / "MensorCAD").exists(),
            "no debe crearse la carpeta del gestor antes de validar el release",
        )

    def test_el_tag_invalido_se_rechaza_antes_de_la_red_y_de_escrituras(self) -> None:
        completado, valores, rutas, temp, localappdata = self.sonda_tag
        self.assertEqual(completado.returncode, 0, completado.stderr.strip())
        self.assertEqual(
            completado.stderr,
            "",
            "el stderr del proceso debe quedar vacio: solo la sonda escribe en stdout",
        )
        self.assertEqual(valores["SONDA-CODIGO"], "1", "el tag invalido debe salir con 1")
        self.assertEqual(valores["SONDA-API"], "0", "el tag invalido no puede consultar la API")
        self.assertEqual(valores["SONDA-APIURI"], "", "no debe existir URI de API")
        self.assertEqual(valores["SONDA-DESCARGAS"], "0", "el tag invalido no puede descargar")
        self.assertEqual(
            valores["SONDA-URLDESCARGA"], "", "no debe existir URL de descarga"
        )
        self.assertEqual(valores["SONDA-ESCRITURAS"], "0", "el tag invalido no puede escribir")
        self.assertEqual(valores["SONDA-TERMINANTE"], "ninguna", "no debe haber error terminante")
        self.assertEqual(valores["SONDA-CNF"], "", "el arranque no puede reportar comandos rotos")
        self.assertEqual(valores["SONDA-ERROR"], ERROR_TAG_INVALIDO)
        self.assertEqual(valores["SONDA-TEMP"], rutas["temp"], "TEMP aislado en el scratch")
        self.assertEqual(
            valores["SONDA-LOCALAPPDATA"], rutas["localappdata"], "LOCALAPPDATA aislado en el scratch"
        )
        self.assertEqual([ruta.name for ruta in temp.iterdir()], [], "sin escrituras temporales")
        self.assertEqual(
            [ruta.name for ruta in localappdata.iterdir()], [], "sin escrituras en el perfil aislado"
        )

if __name__ == "__main__":
    unittest.main()
