"""Arranque real del asset publicado ``install.ps1`` en Windows PowerShell 5.1.

El comando corto publica el archivo por HTTP y lo ejecuta con
``[scriptblock]::Create``. El cliente HTTP entrega el cuerpo decodificado como
Latin-1 cuando no reconoce el BOM, no como UTF-8: un BOM al inicio de
``install.ps1`` llega al interprete como texto basura delante de ``param`` y el
arranque se rompe con ``CommandNotFoundException``. Estas pruebas reproducen esa
decodificacion y ejecutan el archivo real.

Nada sale de la maquina: la descarga y la creacion de la carpeta temporal se
sustituyen por centinelas ANTES de invocar el script, de modo que incluso una
ejecucion rota por el BOM queda contenida. No se tocan Program Files, no se pide
UAC, no se autentica, no se cambia configuracion global y no se llama a GitHub.
La sonda exige Windows PowerShell Desktop 5.1 y se rechaza en cualquier otro
interprete.
"""

from __future__ import annotations

import base64
import shutil
import subprocess
import unittest
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parents[1]
BOOTSTRAP = RAIZ_REPO / "install.ps1"
POWERSHELL = "powershell.exe"
WSLPATH = "wslpath"
# iso-8859-1: la decodificacion que aplica el cliente HTTP al no ver un BOM.
CODIFICACION_LATIN1 = 28591
SALIDA_POWERSHELL = "utf-8"
TIMEOUT_SONDA = 120
TIMEOUT_RUTA = 60
MARCA_CENTINELA = "CENTINELA-NEW-ITEM"
TAG_INVALIDO = "v0.1.0/malo"
# Los dos objetivos exactos de CommandNotFoundException que reporto el usuario.
CNF_MOJIBAKE = "00EF,00BB,00BF,0023,"  # '#' con el BOM interpretado como Latin-1
CNF_PARAM = "0070,0061,0072,0061,006D,"  # 'param'
ERROR_TAG_INVALIDO = (
    "ERROR: El tag de -Version no es valido: "
    + TAG_INVALIDO
    + ". Se espera un tag como v1.2.3. No se descargo nada ni se escribio nada.<LF>"
)
ERROR_CENTINELA = (
    "ERROR: No se pudo descargar o ejecutar el instalador de MensorCAD: "
    + MARCA_CENTINELA
    + " No se da la instalacion por hecha.<LF>"
)

# Sonda ASCII: lee los bytes reales del asset, los decodifica como Latin-1 y los
# ejecuta con el mismo punto de entrada publico (scriptblock con parametros).
# Las fronteras de red y de escritura se interceptan con centinelas. Toda la
# evidencia se emite como lineas ASCII ``SONDA-*`` para no depender de la
# codificacion de la consola ni de los mensajes localizados de PowerShell.
SONDA = r"""
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ruta = @@RUTA@@
$modo = '@@MODO@@'

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

$bytes = [System.IO.File]::ReadAllBytes($ruta)
$texto = [System.Text.Encoding]::GetEncoding(@@LATIN1@@).GetString($bytes)

# Fronteras sustituidas: ninguna descarga y ninguna escritura real.
$global:SondaDescargas = 0
$global:SondaEscrituras = 0
function Invoke-WebRequest {
    $global:SondaDescargas = $global:SondaDescargas + 1
    throw [System.InvalidOperationException]::new('DESCARGA-INESPERADA')
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
[Console]::Out.WriteLine('SONDA-DESCARGAS=' + $global:SondaDescargas)
[Console]::Out.WriteLine('SONDA-ESCRITURAS=' + $global:SondaEscrituras)
[Console]::Out.WriteLine('SONDA-TERMINANTE=' + $terminante)
[Console]::Out.WriteLine('SONDA-CNF=' + ($cnf -join '|'))
[Console]::Out.WriteLine('SONDA-ERROR=' + $limpio)
"""

CLAVES_SONDA = (
    "SONDA-INTERPRETE",
    "SONDA-VERSION",
    "SONDA-ARRANQUE",
    "SONDA-CODIGO",
    "SONDA-DESCARGAS",
    "SONDA-ESCRITURAS",
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


def construir_sonda(modo: str, ruta: str) -> str:
    literal = "'" + ruta.replace("'", "''") + "'"
    return (
        SONDA.replace("@@RUTA@@", literal)
        .replace("@@MODO@@", modo)
        .replace("@@TAG@@", TAG_INVALIDO)
        .replace("@@CENTINELA@@", MARCA_CENTINELA)
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
        """Lanza una sonda aislada de punta a punta con tiempo acotado."""
        sonda = construir_sonda(modo, ruta_para_windows(BOOTSTRAP))
        codificada = base64.b64encode(sonda.encode("utf-16-le")).decode("ascii")
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
        )
        return completado, leer_sonda(completado.stdout)

    def test_la_sonda_corre_en_windows_powershell_desktop_51(self) -> None:
        # La evidencia solo es valida en el motor que documenta el producto: la
        # sonda rechaza cualquier otro interprete antes de medir el arranque.
        _, valores = self.sonda_entrada
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
        completado, valores = self.sonda_entrada
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

    def test_la_entrada_por_defecto_termina_en_el_centinela_sin_descargar(self) -> None:
        completado, valores = self.sonda_entrada
        self.assertEqual(completado.returncode, 0, completado.stderr.strip())
        self.assertEqual(
            completado.stderr,
            "",
            "el stderr del proceso debe quedar vacio: solo la sonda escribe en stdout",
        )
        self.assertEqual(valores["SONDA-CODIGO"], "1", "el codigo de salida debe ser 1")
        self.assertEqual(valores["SONDA-DESCARGAS"], "0", "no debe descargarse nada")
        self.assertEqual(valores["SONDA-ESCRITURAS"], "1", "solo se crea la carpeta propia")
        self.assertEqual(valores["SONDA-TERMINANTE"], "ninguna", "no debe haber error terminante")
        self.assertEqual(
            valores["SONDA-ERROR"],
            ERROR_CENTINELA,
            "el error controlado del centinela es el unico que puede escribirse en stderr",
        )

    def test_el_tag_invalido_se_rechaza_antes_de_la_red_y_de_escrituras(self) -> None:
        completado, valores = self.sonda_tag
        self.assertEqual(completado.returncode, 0, completado.stderr.strip())
        self.assertEqual(
            completado.stderr,
            "",
            "el stderr del proceso debe quedar vacio: solo la sonda escribe en stdout",
        )
        self.assertEqual(valores["SONDA-CODIGO"], "1", "el tag invalido debe salir con 1")
        self.assertEqual(valores["SONDA-DESCARGAS"], "0", "el tag invalido no puede descargar")
        self.assertEqual(valores["SONDA-ESCRITURAS"], "0", "el tag invalido no puede escribir")
        self.assertEqual(valores["SONDA-TERMINANTE"], "ninguna", "no debe haber error terminante")
        self.assertEqual(valores["SONDA-CNF"], "", "el arranque no puede reportar comandos rotos")
        self.assertEqual(valores["SONDA-ERROR"], ERROR_TAG_INVALIDO)


if __name__ == "__main__":
    unittest.main()
