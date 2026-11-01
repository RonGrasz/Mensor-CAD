# Bootstrap corto de la entrada remota de MensorCAD.
#
# Uso previsto, cuando un humano publique los cuatro assets del release
# (todavia no estan publicados):
#
#   irm 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/install.ps1' -ea Stop | iex
#   &([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v0.1.0/install.ps1' -ea Stop))) -Version v0.1.0
#
# Este archivo no instala nada por si mismo. Descarga el Install-MensorCAD.ps1
# real a una carpeta temporal propia y lo lanza en un proceso Windows PowerShell
# aparte con -FromRelease. El motor de instalacion, la verificacion SHA-256, el
# ZIP, el destino fijo y el aviso de UAC son los del instalador real: no hay una
# segunda implementacion ni una version de producto duplicada aqui.
#
# Contrato de salida: no ejecuta exit para no cerrar la sesion del usuario
# cuando el archivo llega por iex, que corre en el ambito del llamador. El
# codigo real del proceso hijo queda en $global:LASTEXITCODE. Para automatizar
# con un codigo de salida del sistema operativo use el comando completo
# documentado en docs/remote-installer.md o, desde PowerShell, el fallback
# `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '& .\install.ps1; exit $LASTEXITCODE'`.
#
# La primera descarga (la de este mismo archivo) queda fuera del wrapper: la
# protege el comando publicado con -ea Stop y usa la configuracion TLS del
# equipo. Este archivo no puede configurar una descarga que ya ocurrio: fija
# TLS 1.2 solo en su proceso, antes de descargar el instalador real.

param(
    [string]$Version,
    [switch]$NoAnimation
)

& {
    param(
        $Version,
        [switch]$NoAnimation,
        [bool]$VersionSpecified
    )
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'

    # Fuente fija: no hay parametro publico de URL, repositorio, destino ni UAC.
    $repository = 'RonGrasz/Mensor-CAD'
    $releaseHost = 'https://github.com'
    $installerAssetName = 'Install-MensorCAD.ps1'
    # El mismo patron de tag que usa el instalador real: si no coincide, no hay
    # red ni escrituras.
    $releaseTagPattern = '^v?\d+\.\d+(\.\d+)*([-+][0-9A-Za-z][0-9A-Za-z.-]*)?$'
    $workspacePrefix = 'mensorcad-bootstrap-'
    # La presencia de -Version se decide en el ambito que realmente ligo los
    # parametros: un [string] omitido no es una cadena vacia explicita y nunca
    # se infiere desde el valor.
    $versionSpecified = $VersionSpecified
    $versionTag = ''
    if ($versionSpecified) { $versionTag = [string]$Version }
    $childExitCode = $null
    $tempRoot = $null
    $candidate = $null
    # $workspace es la carpeta PROPIEDAD de este proceso. Solo se asigna
    # despues de crearla en exclusiva y validarla; null significa "no borrar".
    $workspace = $null

    function Write-BootstrapError {
        param([string]$Message)
        [Console]::Error.WriteLine('ERROR: ' + $Message)
    }

    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            Write-BootstrapError 'Este instalador solo funciona en Windows con Windows PowerShell 5.1. No se descargo nada.'
            $childExitCode = 1
            return
        }
        if ($versionSpecified -and [string]::IsNullOrWhiteSpace($versionTag)) {
            Write-BootstrapError 'La opcion -Version necesita un tag, por ejemplo v1.2.3. No se descargo nada ni se escribio nada.'
            $childExitCode = 1
            return
        }
        if ($versionSpecified -and ($versionTag -notmatch $releaseTagPattern)) {
            Write-BootstrapError ('El tag de -Version no es valido: ' + $versionTag + '. Se espera un tag como v1.2.3. No se descargo nada ni se escribio nada.')
            $childExitCode = 1
            return
        }

        # TLS 1.2 solo para este proceso; no se cambia ninguna politica global.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        catch {
            [Console]::Error.WriteLine('AVISO: no se pudo habilitar TLS 1.2 en este proceso; la descarga podria fallar.')
        }

        $tempRoot = [System.IO.Path]::GetTempPath()
        if ([string]::IsNullOrWhiteSpace($tempRoot) -or -not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
            Write-BootstrapError 'No existe una carpeta temporal valida para descargar el instalador. No se modifico el destino.'
            $childExitCode = 1
            return
        }
        # Ruta candidata con GUID completo: New-Item falla si la ruta existe, asi
        # que nunca se reutiliza una carpeta ajena. La propiedad se marca solo
        # despues de crear en exclusiva y validar; una ruta rechazada se deja en
        # disco en lugar de borrarse a ciegas.
        $candidate = Join-Path -Path $tempRoot -ChildPath ($workspacePrefix + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $candidate -ErrorAction Stop
        if (-not [System.IO.Directory]::Exists($candidate)) {
            Write-BootstrapError 'No se pudo crear la carpeta temporal propia en la que descargar el instalador. No se modifico el destino.'
            $childExitCode = 1
            return
        }
        $candidateItem = Get-Item -LiteralPath $candidate -Force
        if (($candidateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-BootstrapError ('La carpeta temporal recien creada es un punto de reanalisis. Se cancela sin instalar y sin tocar el destino; la carpeta se conserva en disco: ' + $candidate)
            $childExitCode = 1
            return
        }
        # Recien aqui la carpeta pasa a ser propiedad de este proceso.
        $workspace = $candidate

        if ($versionSpecified) {
            $installerUri = $releaseHost + '/' + $repository + '/releases/download/' + $versionTag + '/' + $installerAssetName
        }
        else {
            $installerUri = $releaseHost + '/' + $repository + '/releases/latest/download/' + $installerAssetName
        }
        $installerPath = Join-Path -Path $workspace -ChildPath $installerAssetName

        # Descarga del instalador real. -ErrorAction Stop garantiza que un 404 o
        # un error no terminante del cliente HTTP corte aqui y no siga adelante.
        $null = Invoke-WebRequest -UseBasicParsing -Uri $installerUri -OutFile $installerPath -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
            Write-BootstrapError 'GitHub no entrego el instalador de MensorCAD. No se da la instalacion por hecha.'
            $childExitCode = 1
            return
        }

        # Proceso Windows PowerShell aparte, preferentemente el nativo de 64 bits.
        $childHost = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $childHost -PathType Leaf)) {
            $childHost = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
        }
        if (-not (Test-Path -LiteralPath $childHost -PathType Leaf)) {
            $childHost = 'powershell.exe'
        }

        $childArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath, '-FromRelease')
        if ($versionSpecified) { $childArguments += @('-Version', $versionTag) }
        if ($NoAnimation) { $childArguments += '-NoAnimation' }

        # El hijo hereda la consola: su stdout y su stderr se reenvian sin
        # capturarse ni convertirse en el valor de retorno del wrapper. En
        # Windows PowerShell 5.1 una linea de stderr de un comando nativo se
        # promueve a NativeCommandError con ErrorActionPreference Stop y taparia
        # el codigo real; por eso la preferencia se relaja solo durante el hijo.
        $global:LASTEXITCODE = $null
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $childHost @childArguments
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $childExitCode = $LASTEXITCODE
        if ($null -eq $childExitCode) {
            Write-BootstrapError 'Windows PowerShell no informo el estado de salida del instalador. No se da la instalacion por hecha.'
            $childExitCode = 1
        }
    }
    catch {
        Write-BootstrapError ('No se pudo descargar o ejecutar el instalador de MensorCAD: ' + $_.Exception.Message + ' No se da la instalacion por hecha.')
        $childExitCode = 1
    }
    finally {
        # Solo se borra la carpeta propia que este proceso creo directamente bajo
        # la raiz temporal. GetTempPath devuelve una barra final, asi que la
        # comparacion se hace sobre rutas normalizadas sin separador final. Un
        # fallo de limpieza se avisa y no cambia el codigo real del instalador.
        if (-not [string]::IsNullOrWhiteSpace($workspace)) {
            try {
                $separator = @([System.IO.Path]::DirectorySeparatorChar)
                $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $workspace)).TrimEnd([char[]]$separator)
                $root = [System.IO.Path]::GetFullPath($tempRoot).TrimEnd([char[]]$separator)
                $leaf = Split-Path -Leaf $workspace
                if (($parent -eq $root) -and $leaf.StartsWith($workspacePrefix) -and (Test-Path -LiteralPath $workspace)) {
                    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction Stop
                }
            }
            catch {
                [Console]::Error.WriteLine('AVISO: no se pudo limpiar la carpeta temporal ' + $workspace + '; se conserva en disco: ' + $_.Exception.Message)
            }
        }
        if ($null -eq $childExitCode) { $childExitCode = 1 }
        $global:LASTEXITCODE = [int]$childExitCode
    }
} -Version $Version -NoAnimation:$NoAnimation -VersionSpecified (($null -ne $PSBoundParameters) -and $PSBoundParameters.ContainsKey('Version'))
