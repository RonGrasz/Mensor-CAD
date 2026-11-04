#requires -Version 5.1
<#
    Pruebas de distribucion del gestor mensorcad con artefactos REALES (S2, S4, S6).

    Solo se ejecutan en Windows con Windows PowerShell 5.1. La suite construye
    los seis artefactos con tools/build_bundle.py dentro de una carpeta propia en
    odd/artifacts/persistent-cli/distribution (ignorada por git) y trabaja con
    esos bytes, no con copias de conveniencia:

      1. inspecciona el indice y el sidecar de MensorCAD-CLI.zip;
      2. extrae el ZIP del gestor y comprueba que mensorcad.ps1 viaja estampado,
         que el motor tambien esta estampado y que mensorcad.cmd no cambio;
      3. extrae MensorCAD-Windows.zip, valida su inventario con el motor real
         (Test-MensorCadSource) y comprueba que Install-MensorCAD.ps1 figura en
         bundle.sha256 con su propio hash;
      4. instala en un destino aislado y explicito con el helper no elevador
         Install-MensorCadBundle, nunca en Program Files;
      5. ejecuta el gestor real para --version, --help y un comando invalido, y
         el lanzador CMD real, midiendo stdout, stderr y codigo de salida;
      6. ejecuta status/update/install/uninstall del gestor con el estado
         instalado aislado por fixture (Program Files y tag resueltos a la
         carpeta de la corrida) y comprueba los codigos exactos;
      7. desinstala sin conexion con Uninstall-MensorCadBundle sobre el mismo
         fixture y verifica que solo se eliminan los archivos registrados.

    No se descarga nada, no se pide UAC, no se abre AutoCAD, no se toca el PATH,
    no se escribe en el destino fijo de ApplicationPlugins y no se cierra ningun
    proceso. La instalacion real con elevacion, AutoCAD y el PATH de usuario
    siguen siendo verificacion manual.

    Ejecucion manual o en CI:
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File tests\Test-CliDistribution.ps1

    La suite acepta -BuildDir <ruta> para reutilizar artefactos ya construidos:
    si los seis archivos existen, valida esos bytes y no vuelve a ejecutar el
    constructor. -Version fija la version esperada y debe coincidir con
    PackageContents.xml; sin -Version se usa la del manifiesto. Asi el CI
    construye una sola vez y valida exactamente el dist que publica.
#>

param(
    [string]$BuildDir = '',
    [string]$Version = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'SKIP: estas pruebas requieren Windows PowerShell 5.1.' -ForegroundColor Yellow
    exit 2
}

$script:Passed = 0
$script:Failed = 0
$script:FailureMessages = @()
$script:ProviderPrefix = 'Microsoft.PowerShell.Core\FileSystem::'

function ConvertTo-PlainPath {
    # PowerShell devuelve rutas con prefijo de proveedor cuando el repositorio se
    # abre por UNC (\\wsl.localhost\...). .NET no acepta ese prefijo, asi que se
    # quita antes de crear carpetas o lanzar procesos.
    param([string]$Path)
    $value = [string]$Path
    if ($value.StartsWith($script:ProviderPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $value.Substring($script:ProviderPrefix.Length)
    }
    return $value
}

$script:RepositoryRoot = ConvertTo-PlainPath -Path (Split-Path -Parent $PSScriptRoot)
$script:ScratchRoot = Join-Path -Path $script:RepositoryRoot -ChildPath 'odd\artifacts\persistent-cli\distribution'
$null = [System.IO.Directory]::CreateDirectory($script:ScratchRoot)
# Nombres cortos a proposito: el motor crea una carpeta de transaccion con GUID
# y una etapa temporal dentro del destino. Con el prefijo UNC de un repositorio
# abierto por WSL una ruta larga supera MAX_PATH y la copia falla en Windows
# PowerShell 5.1, que no admite rutas extendidas de forma transparente.
$script:TestRoot = Join-Path -Path $script:ScratchRoot -ChildPath ('d-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = [System.IO.Directory]::CreateDirectory($script:TestRoot)
# La carpeta temporal de los hijos queda dentro del scratch de la corrida: ningun
# proceso escribe fuera del arbol ignorado y no se depende de un TEMP del
# sistema que puede venir con prefijo de proveedor.
$env:TEMP = $script:TestRoot
$env:TMP = $script:TestRoot

$script:PowerShellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
$script:BuildScript = Join-Path -Path $script:RepositoryRoot -ChildPath 'tools\build_bundle.py'
$script:ManifestPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'PackageContents.xml'
$script:RepoLauncher = Join-Path -Path $script:RepositoryRoot -ChildPath 'mensorcad.cmd'
$script:WindowsZipName = 'MensorCAD-Windows.zip'
$script:CliZipName = 'MensorCAD-CLI.zip'
$script:WindowsSidecarName = 'MensorCAD-Windows.zip.sha256'
$script:CliSidecarName = 'MensorCAD-CLI.zip.sha256'
$script:EngineName = 'Install-MensorCAD.ps1'
$script:BundleFolderName = 'MensorCAD.bundle'
$script:MarkerName = '.mensorcad-install.json'
$script:BuildOutputNames = @(
    $script:WindowsZipName,
    $script:WindowsSidecarName,
    $script:CliZipName,
    $script:CliSidecarName,
    $script:EngineName,
    'install.ps1'
)

# ---------------------------------------------------------------------------
# Utilidades de asercion, hashes, ZIP y procesos reales
# ---------------------------------------------------------------------------

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw ('ASSERT: ' + $Message + ' (esperado: ' + [string]$Expected + ', actual: ' + [string]$Actual + ')')
    }
}

function Assert-Contains {
    param([string]$Text, [string]$Fragment, [string]$Message)
    if ($Text.IndexOf($Fragment, [StringComparison]::Ordinal) -lt 0) {
        throw ('ASSERT: ' + $Message + ' (no contiene: ' + $Fragment + ')')
    }
}

function Assert-NotContains {
    param([string]$Text, [string]$Fragment, [string]$Message)
    if ($Text.IndexOf($Fragment, [StringComparison]::Ordinal) -ge 0) {
        throw ('ASSERT: ' + $Message + ' (no deberia contener: ' + $Fragment + ')')
    }
}

function Assert-Empty {
    param([string]$Text, [string]$Message)
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        throw ('ASSERT: ' + $Message + ' (salida inesperada: ' + $Text + ')')
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Fragment, [string]$Message)
    $threw = $false
    try {
        & $Body
    }
    catch {
        $threw = $true
        Assert-Contains ([string]$_.Exception.Message) $Fragment $Message
    }
    Assert-True $threw ($Message + ' (no se rechazo nada)')
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host ('PASS: ' + $Name) -ForegroundColor Green
    }
    catch {
        $script:Failed++
        $message = $_.Exception.Message
        $script:FailureMessages += ($Name + ' -> ' + $message)
        Write-Host ('FAIL: ' + $Name) -ForegroundColor Red
        Write-Host ('      ' + $message) -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
            Write-Host ('      ' + [string]$_.ScriptStackTrace) -ForegroundColor DarkRed
        }
    }
}

function ConvertTo-QuotedArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Start-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$ArgumentString = '',
        [string]$WorkingDirectory = ''
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $ArgumentString
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # Un proceso nativo no puede arrancar con un directorio de trabajo UNC.
    $psi.WorkingDirectory = $env:SystemRoot
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    # La salida del gestor redirigida es UTF-8: se decodifica con la
    # misma codificacion explicita para no depender de la pagina de codigos del host.
    $capturedEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $psi.StandardOutputEncoding = $capturedEncoding
    $psi.StandardErrorEncoding = $capturedEncoding
    $process = [System.Diagnostics.Process]::Start($psi)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $result = [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        StdOut = [string]$outTask.Result
        StdErr = [string]$errTask.Result
    }
    $process.Dispose()
    return $result
}

function Invoke-PowerShellFile {
    param([string]$Script, [string[]]$Arguments = @())
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-QuotedArgument -Value $Script))) {
        $parts.Add($part)
    }
    foreach ($argument in @($Arguments)) {
        $parts.Add((ConvertTo-QuotedArgument -Value ([string]$argument)))
    }
    return (Start-CapturedProcess -FileName $script:PowerShellPath -ArgumentString ($parts -join ' '))
}

function Invoke-CmdLauncher {
    param([string]$Launcher, [string[]]$Arguments = @())
    $inner = '"' + $Launcher + '"'
    foreach ($argument in @($Arguments)) {
        $inner += ' ' + (ConvertTo-QuotedArgument -Value ([string]$argument))
    }
    return (Start-CapturedProcess -FileName 'cmd.exe' -ArgumentString ('/d /c "' + $inner + '"'))
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        $builder = New-Object System.Text.StringBuilder
        foreach ($byte in $hash) { $null = $builder.Append($byte.ToString('x2')) }
        return $builder.ToString()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ZipEntryNames {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $names = New-Object 'System.Collections.Generic.List[string]'
        foreach ($entry in @($archive.Entries)) { $names.Add([string]$entry.FullName) }
        return $names.ToArray()
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ZipEntryBytes {
    param([string]$ZipPath, [string]$EntryName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in @($archive.Entries)) {
            if ([string]$entry.FullName -ceq $EntryName) {
                $stream = $entry.Open()
                try {
                    $memory = New-Object System.IO.MemoryStream
                    try {
                        $stream.CopyTo($memory)
                        return ,$memory.ToArray()
                    }
                    finally {
                        $memory.Dispose()
                    }
                }
                finally {
                    $stream.Dispose()
                }
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    throw ('No existe la entrada "' + $EntryName + '" en ' + $ZipPath + '.')
}

function Expand-ZipTo {
    param([string]$ZipPath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function New-LegacyWindowsArchive {
    # Paquete anterior al motor protegido: mismos bytes del dist menos
    # MensorCAD.bundle/Install-MensorCAD.ps1, con bundle.sha256 recalculado sin
    # esa entrada y sidecar adjunto. Sirve para comprobar que la entrada nueva
    # del whitelist es OPCIONAL y que los ZIP viejos siguen aceptandose.
    param([string]$SourceZip, [string]$DestinationZip)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $protectedEntry = $script:BundleFolderName + '/' + $script:EngineName
    $source = [System.IO.Compression.ZipFile]::OpenRead($SourceZip)
    try {
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $DestinationZip)) | Out-Null
        $stream = [System.IO.File]::Open($DestinationZip, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            $destination = New-Object System.IO.Compression.ZipArchive -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($entry in @($source.Entries)) {
                    if ($entry.FullName -ceq $protectedEntry) { continue }
                    $target = $destination.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                    $input = $entry.Open()
                    $output = $target.Open()
                    try {
                        if ($entry.FullName -ceq 'bundle.sha256') {
                            $reader = New-Object System.IO.StreamReader -ArgumentList @($input)
                            try { $text = $reader.ReadToEnd() }
                            finally { $reader.Dispose() }
                            $lines = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 -and $_.Trim() -notmatch '  Install-MensorCAD\.ps1$' })
                            $payload = [System.Text.Encoding]::UTF8.GetBytes((($lines -join "`n") + "`n"))
                            $output.Write($payload, 0, $payload.Length)
                        }
                        else {
                            $input.CopyTo($output)
                        }
                    }
                    finally {
                        $input.Dispose()
                        $output.Dispose()
                    }
                }
            }
            finally {
                $destination.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $source.Dispose()
    }
    $sidecarText = (Get-FileSha256 -Path $DestinationZip) + '  ' + $script:WindowsZipName + "`n"
    [System.IO.File]::WriteAllText(($DestinationZip + '.sha256'), $sidecarText, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
    return $DestinationZip
}

function Get-ManifestVersion {
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $document.Load($script:ManifestPath)
    $root = $document.DocumentElement
    foreach ($attributeName in @('AppVersion', 'Version')) {
        $value = [string]$root.GetAttribute($attributeName)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    throw 'PackageContents.xml no declara AppVersion ni Version.'
}

function Invoke-DistributionBuild {
    $python = $null
    foreach ($name in @('python', 'python3')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { $python = [string]$command.Source; break }
    }
    if ($null -eq $python) {
        throw 'No se encontro python ni python3 en PATH para construir los artefactos.'
    }
    $arguments = @(
        '-B',
        (ConvertTo-QuotedArgument -Value $script:BuildScript),
        '--output-dir',
        (ConvertTo-QuotedArgument -Value $script:BuildDir),
        '--version',
        $script:DistributionVersion
    )
    $result = Start-CapturedProcess -FileName $python -ArgumentString ($arguments -join ' ')
    Assert-Equal 0 $result.ExitCode ('el constructor debe terminar bien: ' + $result.StdErr)
    Assert-Contains $result.StdOut $script:WindowsZipName 'el constructor debe informar el ZIP del complemento'
    Assert-Contains $result.StdOut $script:CliZipName 'el constructor debe informar el ZIP del gestor'
    return $result
}

function Write-ManagerFixture {
    # Fixture de estado: el gestor real y el motor real se cargan con dot-source
    # y solo se sustituyen las dos fronteras que no se pueden aislar desde una
    # prueba: la carpeta Program Files y la resolucion del tag de release.
    $content = @'
param([string]$Action, [string]$Manager, [string]$Engine, [string]$IsolatedRoot, [string]$Version)
# El fixture escribe la salida del gestor: la emite en UTF-8, igual que el
# punto de entrada real, para no depender de la pagina de codigos del host.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$ErrorActionPreference = 'Stop'
# El motor tiene su propio -Version en el bloque param: al hacer dot-source lo
# deja vacio en este ambito. La version fixture se captura antes y con otro
# nombre para que la resolucion del tag no dependa de ese parametro.
$fixtureVersion = [string]$Version
. $Manager
. $Engine
function Get-MensorCadProgramFilesRoot { return $IsolatedRoot }
function Resolve-MensorCadReleaseTag { return ('v' + $fixtureVersion) }
function Invoke-MensorCadCli {
    param(
        [switch]$Uninstall,
        [switch]$NoAnimation,
        [switch]$Help,
        [switch]$FromRelease,
        [string]$Version,
        [switch]$ElevatedProcess,
        [switch]$HoldResult,
        [switch]$BatLauncher
    )
    [Console]::Out.WriteLine('ENGINE-CLI-CALLED')
    return 77
}
switch ($Action) {
    'status' { $null = Write-MensorCadManagerState; exit 0 }
    'update' { exit (Invoke-MensorCadManagerUpdate) }
    'install' { exit (Invoke-MensorCadManagerInstall) }
    'uninstall' { exit (Invoke-MensorCadManagerUninstall) }
    default { exit 9 }
}
'@
    [System.IO.File]::WriteAllText($script:HarnessScript, $content, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
}

function Get-ManagerFixtureResult {
    param([string]$Action)
    return (Invoke-PowerShellFile -Script $script:HarnessScript -Arguments @(
        '-Action', $Action,
        '-Manager', $script:ManagerScript,
        '-Engine', $script:CliEngine,
        '-IsolatedRoot', $script:IsolatedRoot,
        '-Version', $script:DistributionVersion
    ))
}

# ---------------------------------------------------------------------------
# Ruta local (-LocalZip) con los ZIP reales del dist
# ---------------------------------------------------------------------------
# El gestor y el motor son los archivos REALES del ZIP del gestor. En el fixture
# solo se sustituyen tres costuras: la raiz Program Files aislada, la red
# prohibida y el lanzamiento del instalador extraido (Invoke-MensorCadRemoteChild),
# que aqui es un proceso hijo sin elevacion sobre esa misma raiz. La validacion
# del ZIP, del sidecar y de la version de PackageContents.xml es la de
# produccion, igual que la limpieza de la carpeta temporal propia.

function Write-LocalChildWrapper {
    # Hijo no elevado: carga el motor EXTRAIDO del paquete real y lo ejecuta
    # contra la raiz aislada. Es el unico punto donde se evita la elevacion; el
    # paquete que se ejecuta viaja dentro del ZIP construido, sin copias.
    $content = @'
param([string]$Mode, [string]$EnginePath, [string]$IsolatedRoot, [string]$Evidence)
# El fixture escribe la salida del gestor: la emite en UTF-8, igual que el
# punto de entrada real, para no depender de la pagina de codigos del host.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$ErrorActionPreference = 'Stop'
function Add-LocalChildEvidence {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Evidence)) { return }
    [System.IO.File]::AppendAllText($Evidence, $Line + "`n")
}
Add-LocalChildEvidence ('payload|start|' + $Mode + '|' + [System.IO.Path]::GetFileName($EnginePath))
. $EnginePath
function Get-MensorCadProgramFilesRoot { return $IsolatedRoot }
function Test-MensorCadAdministrator { return $true }
function Test-MensorCadAutoCadRunning { return $false }
if ($Mode -eq 'uninstall') {
    $code = [int](Invoke-MensorCadCli -Uninstall -NoAnimation)
}
else {
    $code = [int](Invoke-MensorCadCli -NoAnimation)
}
Add-LocalChildEvidence ('payload|end|' + $Mode + '|' + $code)
exit $code
'@
    [System.IO.File]::WriteAllText($script:LocalChildWrapper, $content, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
}

function Write-LocalRouteFixture {
    # Las tres costuras del fixture dejan evidencia escrita y prohiben la red:
    # si la ruta local llamara al release o descargara algo, la prueba falla.
    $content = @'
param(
    [string]$Action,
    [string]$Manager,
    [string]$Engine,
    [string]$IsolatedRoot,
    [string]$LocalZip,
    [string]$Evidence,
    [string]$ChildWrapper
)
# El fixture escribe la salida del gestor: la emite en UTF-8, igual que el
# punto de entrada real, para no depender de la pagina de codigos del host.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$ErrorActionPreference = 'Stop'
. $Manager
. $Engine
# La ruta local de produccion valida el paquete con Open-MensorCadLocalPackage y
# lo instala con Install-MensorCadLocalPackage; aqui no se reimplementa nada de
# eso, solo se sustituye el lanzamiento del instalador extraido.
function Add-LocalEvidence {
    param([string]$Line)
    [System.IO.File]::AppendAllText($Evidence, $Line + "`n")
}
function Get-MensorCadProgramFilesRoot { return $IsolatedRoot }
function Resolve-MensorCadReleaseTag {
    Add-LocalEvidence 'resolve|release-tag'
    return 'v0.0.0'
}
function Get-MensorCadRemoteText {
    param([string]$Uri)
    Add-LocalEvidence 'network|text'
    throw 'La red no esta permitida en esta prueba local (fixture).'
}
function Save-MensorCadRemoteFile {
    param([string]$Uri, [string]$DestinationPath)
    Add-LocalEvidence 'network|file'
    throw 'La red no esta permitida en esta prueba local (fixture).'
}
function Invoke-LocalChildProcess {
    param([string]$Mode, [string]$EnginePath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $env:SystemRoot
    if (Test-Path -LiteralPath $IsolatedRoot -PathType Container) {
        $psi.WorkingDirectory = $IsolatedRoot
    }
    # La salida del gestor redirigida es UTF-8: se decodifica con la
    # misma codificacion explicita para no depender de la pagina de codigos del host.
    $capturedEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $psi.StandardOutputEncoding = $capturedEncoding
    $psi.StandardErrorEncoding = $capturedEncoding
    $psi.Arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        ('"' + $ChildWrapper + '"'),
        '-Mode',
        $Mode,
        '-EnginePath',
        ('"' + $EnginePath + '"'),
        '-IsolatedRoot',
        ('"' + $IsolatedRoot + '"'),
        '-Evidence',
        ('"' + $Evidence + '"')
    ) -join ' '
    $process = [System.Diagnostics.Process]::Start($psi)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $result = [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        StdOut = [string]$outTask.Result
        StdErr = [string]$errTask.Result
    }
    $process.Dispose()
    return $result
}
function Invoke-MensorCadRemoteChild {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$StdOutPath,
        [Parameter(Mandatory = $true)][string]$StdErrPath
    )
    Add-LocalEvidence ('child|' + $ScriptPath)
    $result = Invoke-LocalChildProcess -Mode 'install' -EnginePath $ScriptPath
    [System.IO.File]::WriteAllText($StdOutPath, [string]$result.StdOut)
    [System.IO.File]::WriteAllText($StdErrPath, [string]$result.StdErr)
    return [pscustomobject]@{ ExitCode = [int]$result.ExitCode; StdOut = [string]$result.StdOut; StdErr = [string]$result.StdErr }
}
switch ($Action) {
    'status' { $null = Write-MensorCadManagerState; exit 0 }
    'install' { exit (Invoke-MensorCadManagerInstall -LocalZip $LocalZip) }
    'update' { exit (Invoke-MensorCadManagerUpdate -LocalZip $LocalZip) }
    default { exit 9 }
}
'@
    [System.IO.File]::WriteAllText($script:LocalHarness, $content, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
}

function Get-LocalRouteFixtureResult {
    param([string]$Action, [string]$LocalZip = '', [string]$IsolatedRoot = '')
    if ([string]::IsNullOrWhiteSpace($IsolatedRoot)) { $IsolatedRoot = $script:LocalRoot }
    return (Invoke-PowerShellFile -Script $script:LocalHarness -Arguments @(
        '-Action', $Action,
        '-Manager', $script:ManagerScript,
        '-Engine', $script:CliEngine,
        '-IsolatedRoot', $IsolatedRoot,
        '-LocalZip', $LocalZip,
        '-Evidence', $script:LocalEvidence,
        '-ChildWrapper', $script:LocalChildWrapper
    ))
}

function Get-LocalEvidenceText {
    if (-not (Test-Path -LiteralPath $script:LocalEvidence -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($script:LocalEvidence)
}

function Reset-LocalEvidence {
    if (Test-Path -LiteralPath $script:LocalEvidence -PathType Leaf) {
        [System.IO.File]::Delete($script:LocalEvidence)
    }
}

function Get-LocalChildCount {
    return @((Get-LocalEvidenceText) -split "`n" | Where-Object { $_.StartsWith('child|') }).Count
}

function Get-LocalPayloadCount {
    return @((Get-LocalEvidenceText) -split "`n" | Where-Object { $_.StartsWith('payload|') }).Count
}

function Get-ScratchLocalWorkspaces {
    # La carpeta temporal propia del gestor se crea bajo TEMP (el scratch de la
    # corrida); si sobrevive una, la limpieza de la ruta local fallo.
    return @(Get-ChildItem -LiteralPath $script:TestRoot -Directory -Filter 'mensorcad-local-*' -ErrorAction SilentlyContinue)
}

function Assert-LocalEvidenceClean {
    param([string]$Message)
    $text = Get-LocalEvidenceText
    Assert-NotContains $text 'network|' ($Message + ': la ruta local no puede descargar')
    Assert-NotContains $text 'resolve|' ($Message + ': la ruta local no puede resolver un release')
    Assert-Equal 0 (@(Get-ScratchLocalWorkspaces)).Count ($Message + ': la carpeta temporal propia debe limpiarse')
}

# ---------------------------------------------------------------------------
# Preparacion: version, rutas y construccion real
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $script:PowerShellPath -PathType Leaf)) {
    Write-Host ("ERROR: no se encontro Windows PowerShell en '" + $script:PowerShellPath + "'.") -ForegroundColor Red
    exit 1
}
foreach ($required in @($script:BuildScript, $script:ManifestPath, $script:RepoLauncher)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host ("ERROR: falta un archivo necesario para la suite: '" + $required + "'.") -ForegroundColor Red
        exit 1
    }
}

$script:ManifestVersion = ''
$script:DistributionVersion = ''
$script:BuildDirExplicit = -not [string]::IsNullOrWhiteSpace($BuildDir)
if (-not $script:BuildDirExplicit) {
    $script:BuildDir = Join-Path -Path $script:TestRoot -ChildPath 'b'
}
else {
    $script:BuildDir = ConvertTo-PlainPath -Path $BuildDir
    $resolved = Resolve-Path -LiteralPath $script:BuildDir -ErrorAction SilentlyContinue
    if ($null -ne $resolved) {
        $script:BuildDir = ConvertTo-PlainPath -Path ([string]$resolved.Path)
    }
}
$script:SourceRoot = Join-Path -Path $script:TestRoot -ChildPath 's'
$script:CliRoot = Join-Path -Path $script:TestRoot -ChildPath 'c'
# Program Files simulado: el gestor resuelve el destino como
# <raiz>\Autodesk\ApplicationPlugins\MensorCAD.bundle, igual que en el equipo
# real, pero siempre dentro del scratch de la corrida.
$script:IsolatedRoot = $script:TestRoot
$script:DestinationRoot = Join-Path -Path $script:IsolatedRoot -ChildPath 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
$script:ManagerScript = Join-Path -Path $script:CliRoot -ChildPath 'mensorcad.ps1'
$script:CliEngine = Join-Path -Path $script:CliRoot -ChildPath $script:EngineName
$script:CliLauncher = Join-Path -Path $script:CliRoot -ChildPath 'mensorcad.cmd'
$script:HarnessScript = Join-Path -Path $script:TestRoot -ChildPath 'h.ps1'
$script:Inventory = @()
$script:InventoryCount = 0
$script:BuildResult = $null
$script:ReusedArtifacts = $false

try {
    $script:ManifestVersion = Get-ManifestVersion
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $script:DistributionVersion = $script:ManifestVersion
    }
    else {
        $script:DistributionVersion = ([string]$Version).Trim()
        if ($script:DistributionVersion -ne $script:ManifestVersion) {
            throw ('-Version "' + $script:DistributionVersion + '" no coincide con PackageContents.xml (' + $script:ManifestVersion + '). Los artefactos deben ser los de la version del manifiesto.')
        }
    }
    # Reutilizacion: si los seis artefactos ya existen se validan tal cual. Un
    # -BuildDir explicito incompleto se rechaza en vez de reconstruir otros
    # bytes, para que el CI valide exactamente el dist que va a publicar.
    $missingArtifacts = @($script:BuildOutputNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:BuildDir $_) -PathType Leaf) })
    if ($missingArtifacts.Count -eq 0) {
        $script:ReusedArtifacts = $true
    }
    elseif ($script:BuildDirExplicit) {
        throw ('-BuildDir no contiene los seis artefactos construidos; falta: ' + ($missingArtifacts -join ', ') + '. No se reconstruye para no validar otros bytes.')
    }
    else {
        $script:BuildResult = Invoke-DistributionBuild
    }
    $null = [System.IO.Directory]::CreateDirectory($script:SourceRoot)
    $null = [System.IO.Directory]::CreateDirectory($script:CliRoot)
    Expand-ZipTo -ZipPath (Join-Path $script:BuildDir $script:WindowsZipName) -Destination $script:SourceRoot
    Expand-ZipTo -ZipPath (Join-Path $script:BuildDir $script:CliZipName) -Destination $script:CliRoot
    # El motor real se carga en el ambito del script: los casos lo reutilizan sin
    # duplicar validaciones ni rutas.
    . $script:CliEngine
    $script:Info = Test-MensorCadSource -SourceRoot $script:SourceRoot
    # @(<List[object]>) lanza ArgumentException en PowerShell 5.1; el cast
    # a object[] conserva el inventario sin desenrollar nada.
    $script:Inventory = [object[]]$script:Info.Entries
    $script:InventoryCount = [int]$script:Info.FileCount
    Write-ManagerFixture
    # Ruta local: raiz aislada propia, evidencia propia y envoltorio del hijo no
    # elevado. Todo queda dentro del scratch ignorado de la corrida.
    $script:LocalRoot = Join-Path -Path $script:TestRoot -ChildPath 'l'
    $script:OlderRoot = Join-Path -Path $script:TestRoot -ChildPath 'o'
    $script:LocalInputRoot = Join-Path -Path $script:TestRoot -ChildPath 'i'
    $null = [System.IO.Directory]::CreateDirectory($script:LocalInputRoot)
    # Las raices simuladas existen antes de lanzar hijos: el proceso no puede
    # arrancar con un directorio de trabajo inexistente y el motor valida la
    # frontera de confianza contra una raiz real.
    $null = [System.IO.Directory]::CreateDirectory($script:LocalRoot)
    $null = [System.IO.Directory]::CreateDirectory($script:OlderRoot)
    $script:LocalDestinationRoot = Join-Path -Path $script:LocalRoot -ChildPath 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
    $script:OlderDestinationRoot = Join-Path -Path $script:OlderRoot -ChildPath 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
    $script:LocalEvidence = Join-Path -Path $script:TestRoot -ChildPath 'le.log'
    $script:LocalHarness = Join-Path -Path $script:TestRoot -ChildPath 'lr.ps1'
    $script:LocalChildWrapper = Join-Path -Path $script:TestRoot -ChildPath 'lc.ps1'
    Write-LocalChildWrapper
    Write-LocalRouteFixture
    $script:ArtifactHashes = @{}
    foreach ($name in $script:BuildOutputNames) {
        $script:ArtifactHashes[$name] = Get-FileSha256 -Path (Join-Path $script:BuildDir $name)
    }
}
catch {
    Write-Host ('ERROR: no se pudo preparar la distribucion real: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ([string]$_.ScriptStackTrace) -ForegroundColor Red
    Write-Host ('Fixtures conservados en ' + $script:TestRoot) -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Casos
# ---------------------------------------------------------------------------

Test-Case 'los seis artefactos reales estan completos y corresponden a la version' {
    foreach ($name in $script:BuildOutputNames) {
        Assert-True (Test-Path -LiteralPath (Join-Path $script:BuildDir $name) -PathType Leaf) ('falta ' + $name)
    }
    $sidecar = [System.IO.File]::ReadAllText((Join-Path $script:BuildDir $script:CliSidecarName))
    Assert-True $sidecar.EndsWith('  ' + $script:CliZipName + "`n", [StringComparison]::Ordinal) 'el sidecar del gestor debe terminar en dos espacios, nombre y LF'
    if ($script:ReusedArtifacts) {
        # El CI construye una sola vez y esta suite valida ese mismo dist.
        Write-Host ('INFO: se reutilizan los artefactos ya construidos en ' + $script:BuildDir) -ForegroundColor DarkCyan
        Assert-True ($null -eq $script:BuildResult) 'la reutilizacion no debe volver a ejecutar el constructor'
    }
    else {
        Assert-True ($null -ne $script:BuildResult) 'falta el resultado del constructor'
        Assert-Contains $script:BuildResult.StdOut 'SHA-256 del gestor:' 'la salida del constructor debe informar el hash del gestor'
    }
}

Test-Case 'el ZIP del gestor tiene tres entradas planas exactas y su sidecar' {
    $cliZip = Join-Path $script:BuildDir $script:CliZipName
    $names = @(Get-ZipEntryNames -ZipPath $cliZip)
    Assert-Equal 3 $names.Count 'el ZIP del gestor debe tener tres entradas'
    $expected = @('Install-MensorCAD.ps1', 'mensorcad.cmd', 'mensorcad.ps1')
    for ($index = 0; $index -lt $expected.Count; $index++) {
        Assert-Equal $expected[$index] $names[$index] 'entrada del ZIP del gestor fuera de orden'
    }
    foreach ($name in $names) {
        Assert-True (-not $name.Contains('/')) ('ruta no plana: ' + $name)
        Assert-True (-not $name.Contains('\')) ('ruta no plana: ' + $name)
        $bytes = Get-ZipEntryBytes -ZipPath $cliZip -EntryName $name
        Assert-True ($bytes.Length -gt 0) ('entrada vacia: ' + $name)
    }
    $sidecarPath = Join-Path $script:BuildDir $script:CliSidecarName
    $sidecarBytes = [System.IO.File]::ReadAllBytes($sidecarPath)
    $expectedText = (Get-FileSha256 -Path $cliZip) + '  ' + $script:CliZipName + "`n"
    $expectedBytes = [System.Text.Encoding]::UTF8.GetBytes($expectedText)
    Assert-Equal $expectedBytes.Length $sidecarBytes.Length 'el sidecar del gestor debe tener el formato exacto'
    for ($index = 0; $index -lt $expectedBytes.Length; $index++) {
        Assert-Equal $expectedBytes[$index] $sidecarBytes[$index] 'el sidecar debe ser 64 hex, dos espacios, MensorCAD-CLI.zip y LF'
    }
}

Test-Case 'el gestor viaja estampado, el motor estampado y el lanzador intacto' {
    $cliZip = Join-Path $script:BuildDir $script:CliZipName
    $managerText = [System.Text.Encoding]::UTF8.GetString((Get-ZipEntryBytes -ZipPath $cliZip -EntryName 'mensorcad.ps1'))
    Assert-Contains $managerText $script:DistributionVersion 'el gestor debe llevar la version estampada'
    Assert-NotContains $managerText '__MENSORCAD_MANAGER_VERSION__' 'el gestor no puede conservar el marcador'
    Assert-NotContains $managerText '__MENSORCAD_RELEASE_VERSION__' 'el gestor no lleva la version del producto'
    $engineText = [System.Text.Encoding]::UTF8.GetString((Get-ZipEntryBytes -ZipPath $cliZip -EntryName $script:EngineName))
    Assert-Contains $engineText $script:DistributionVersion 'el motor del gestor debe llevar la version estampada'
    Assert-NotContains $engineText '__MENSORCAD_RELEASE_VERSION__' 'el motor no puede conservar el marcador'
    $launcherBytes = Get-ZipEntryBytes -ZipPath $cliZip -EntryName 'mensorcad.cmd'
    $repoLauncherBytes = [System.IO.File]::ReadAllBytes($script:RepoLauncher)
    Assert-Equal $repoLauncherBytes.Length $launcherBytes.Length 'el lanzador del ZIP debe ser la copia byte a byte'
    for ($index = 0; $index -lt $repoLauncherBytes.Length; $index++) {
        Assert-Equal $repoLauncherBytes[$index] $launcherBytes[$index] 'el lanzador del ZIP cambio de bytes'
    }
    foreach ($byte in $launcherBytes) {
        Assert-True ($byte -lt 0x80) 'el lanzador debe ser ASCII'
    }
}

Test-Case 'el motor protegido figura en el inventario del bundle' {
    $windowsZip = Join-Path $script:BuildDir $script:WindowsZipName
    $entryName = $script:BundleFolderName + '/' + $script:EngineName
    $names = @(Get-ZipEntryNames -ZipPath $windowsZip)
    Assert-True ($names -contains $entryName) ('el bundle debe contener ' + $entryName)
    $bundleEngine = Get-ZipEntryBytes -ZipPath $windowsZip -EntryName $entryName
    $rootEngine = Get-ZipEntryBytes -ZipPath $windowsZip -EntryName $script:EngineName
    Assert-Equal $rootEngine.Length $bundleEngine.Length 'el motor standalone y el protegido deben ser iguales'
    for ($index = 0; $index -lt $rootEngine.Length; $index++) {
        Assert-Equal $rootEngine[$index] $bundleEngine[$index] 'el motor protegido debe ser el mismo archivo estampado'
    }
    $manifestText = [System.Text.Encoding]::UTF8.GetString((Get-ZipEntryBytes -ZipPath $windowsZip -EntryName 'bundle.sha256'))
    $expectedLine = (Get-Sha256Bytes -Bytes $bundleEngine) + '  ' + $script:EngineName
    Assert-Contains $manifestText $expectedLine 'bundle.sha256 debe declarar el motor con su propio hash'
    $bundleFiles = @($names | Where-Object { $_.StartsWith($script:BundleFolderName + '/') })
    $declared = @(($manifestText -split "`n") | Where-Object { $_.Trim().Length -gt 0 })
    Assert-Equal $bundleFiles.Count $declared.Count 'bundle.sha256 debe cubrir cada archivo del bundle'
}

Test-Case 'Test-MensorCadSource acepta el paquete real y su inventario' {
    Assert-True ($script:InventoryCount -gt 0) 'el inventario real no puede estar vacio'
    $paths = @($script:Inventory | ForEach-Object { $_.RelativePath })
    Assert-True ($paths -contains $script:EngineName) 'el inventario debe incluir el motor protegido'
    Assert-True ($paths -contains 'PackageContents.xml') 'el inventario debe incluir el manifiesto'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:SourceRoot ($script:BundleFolderName + '\' + $script:EngineName)) -PathType Leaf) 'falta el motor en el paquete extraido'
}

Test-Case 'Test-MensorCadSource rechaza un inventario manipulado o incompleto' {
    $tamper = Join-Path $script:TestRoot 't'
    Copy-Item -LiteralPath $script:SourceRoot -Destination $tamper -Recurse -Force
    $tamperEngine = Join-Path $tamper ($script:BundleFolderName + '\' + $script:EngineName)
    [System.IO.File]::AppendAllText($tamperEngine, "`n# alterado por la prueba de distribucion`n")
    Assert-Throws -Body { Test-MensorCadSource -SourceRoot $tamper } -Fragment 'no coincide con bundle.sha256' -Message 'un motor alterado debe rechazarse'
    $missing = Join-Path $script:TestRoot 'm'
    Copy-Item -LiteralPath $script:SourceRoot -Destination $missing -Recurse -Force
    [System.IO.File]::Delete((Join-Path $missing ($script:BundleFolderName + '\' + $script:EngineName)))
    Assert-Throws -Body { Test-MensorCadSource -SourceRoot $missing } -Fragment "Falta el archivo declarado '$($script:EngineName)'" -Message 'un motor ausente debe rechazarse'
    $null = Test-MensorCadSource -SourceRoot $script:SourceRoot
}

Test-Case 'la instalacion aislada usa el helper no elevador y el destino explicito' {
    Assert-True ($script:DestinationRoot.StartsWith($script:TestRoot, [StringComparison]::OrdinalIgnoreCase)) 'el destino aislado debe quedar dentro del scratch de la corrida'
    $result = Install-MensorCadBundle -SourceRoot $script:SourceRoot -DestinationRoot $script:DestinationRoot -TrustedBoundary $script:IsolatedRoot -AutoCadProbe { $false }
    Assert-Equal 'installed' $result.Status 'la primera instalacion aislada debe quedar instalada'
    Assert-Equal $script:InventoryCount ([int]$result.FileCount) 'la instalacion debe copiar todo el inventario'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:DestinationRoot $script:MarkerName) -PathType Leaf) 'falta la marca de instalacion'
    $installedEngine = Join-Path $script:DestinationRoot $script:EngineName
    Assert-True (Test-Path -LiteralPath $installedEngine -PathType Leaf) 'falta el motor protegido instalado'
    $declared = @($script:Inventory | Where-Object { $_.RelativePath -eq $script:EngineName })[0]
    Assert-Equal ([string]$declared.Sha256) (Get-FileSha256 -Path $installedEngine) 'el motor instalado debe coincidir con bundle.sha256'
    $marker = Assert-MensorCadOwnedDestination -DestinationRoot $script:DestinationRoot
    Assert-True ($null -ne $marker) 'el destino aislado debe pertenecer a MensorCAD'
}

Test-Case 'el gestor real responde --version, --help y rechaza unistall' {
    $version = Invoke-PowerShellFile -Script $script:ManagerScript -Arguments @('--version')
    Assert-Equal 0 $version.ExitCode 'mensorcad --version debe terminar bien'
    Assert-Equal ('mensorcad ' + $script:DistributionVersion) $version.StdOut.Trim() 'mensorcad --version debe imprimir solo su version'
    Assert-Empty $version.StdErr 'mensorcad --version no debe escribir en stderr'
    $help = Invoke-PowerShellFile -Script $script:ManagerScript -Arguments @('--help')
    Assert-Equal 0 $help.ExitCode 'mensorcad --help debe terminar bien'
    Assert-Contains $help.StdOut 'mensorcad install' 'la ayuda debe documentar install'
    Assert-Contains $help.StdOut 'mensorcad uninstall' 'la ayuda debe documentar uninstall'
    Assert-Contains $help.StdOut 'conserva este comando' 'la ayuda debe explicar que uninstall conserva el gestor'
    Assert-Contains $help.StdOut 'no instala nada' 'la ayuda debe aclarar que el resumen no instala'
    $invalid = Invoke-PowerShellFile -Script $script:ManagerScript -Arguments @('unistall')
    Assert-Equal 2 $invalid.ExitCode 'un comando invalido debe salir con codigo 2'
    Assert-Empty $invalid.StdOut 'un comando invalido no debe escribir en stdout'
    Assert-Contains $invalid.StdErr 'Comando no reconocido' 'el error debe explicar el comando invalido'
    Assert-Contains $invalid.StdErr 'uninstall' 'el error debe sugerir uninstall'
    Assert-Contains $invalid.StdErr 'No se modific' 'el error debe aclarar que no se modifico nada'
}

Test-Case 'el lanzador CMD reenvia el codigo de salida del gestor real' {
    $version = Invoke-CmdLauncher -Launcher $script:CliLauncher -Arguments @('--version')
    Assert-Equal 0 $version.ExitCode 'el lanzador debe reenviar el codigo 0'
    Assert-Equal ('mensorcad ' + $script:DistributionVersion) $version.StdOut.Trim() 'el lanzador debe reenviar la salida del gestor'
    $invalid = Invoke-CmdLauncher -Launcher $script:CliLauncher -Arguments @('unistall')
    Assert-Equal 2 $invalid.ExitCode 'el lanzador debe reenviar el codigo 2'
    Assert-Contains $invalid.StdErr 'Comando no reconocido' 'el lanzador debe conservar stderr'
}

Test-Case 'el gestor informa el estado instalado y no reinstala si ya esta actualizado' {
    $markerPath = Join-Path $script:DestinationRoot $script:MarkerName
    $markerBefore = Get-FileSha256 -Path $markerPath
    $status = Get-ManagerFixtureResult -Action 'status'
    Assert-Equal 0 $status.ExitCode 'mensorcad status debe terminar bien'
    Assert-Contains $status.StdOut ('MensorCAD CLI ' + $script:DistributionVersion) 'status debe informar la version del gestor'
    Assert-Contains $status.StdOut 'Complemento: instalado' 'status debe informar el complemento instalado'
    Assert-Contains $status.StdOut ('instalada: ' + $script:DistributionVersion) 'status debe informar la version instalada'
    Assert-Contains $status.StdOut $script:DestinationRoot 'status debe informar la ubicacion instalada'
    $update = Get-ManagerFixtureResult -Action 'update'
    Assert-Equal 0 $update.ExitCode 'update con la misma version debe terminar bien'
    Assert-Contains $update.StdOut 'actualizado' 'update debe informar que ya esta actualizado'
    Assert-Contains $update.StdOut 'sin cambios' 'update no debe reinstalar nada'
    Assert-NotContains $update.StdOut 'ENGINE-CLI-CALLED' 'update igual no debe invocar al motor'
    $install = Get-ManagerFixtureResult -Action 'install'
    Assert-Equal 0 $install.ExitCode 'install con la misma version debe terminar bien'
    Assert-Contains $install.StdOut 'actualizado' 'install igual no debe reinstalar'
    Assert-NotContains $install.StdOut 'ENGINE-CLI-CALLED' 'install igual no debe invocar al motor'
    Assert-Equal $markerBefore (Get-FileSha256 -Path $markerPath) 'ni update ni install pueden reescribir la instalacion'
}

Test-Case 'uninstall sin conexion invoca el motor protegido y propaga su codigo exacto' {
    # El motor protegido resuelve la carpeta Program Files real, que esta prueba
    # nunca escribe. El fixture solo aisla la carpeta del estado: el gestor
    # valida la instalacion fixture y despues ejecuta el motor protegido real,
    # que se niega a desinstalar un destino que no existe. Se mide el reenvio
    # exacto del codigo y del stderr; la desinstalacion correcta del fixture se
    # comprueba en el caso siguiente con el mismo motor real.
    $fixedDestination = Join-Path -Path ([Environment]::GetFolderPath('ProgramFiles')) -ChildPath 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
    if (Test-Path -LiteralPath $fixedDestination) {
        # En un equipo con MensorCAD instalado de verdad, el motor protegido
        # podria pedir UAC y desinstalar esa instalacion. Esta prueba no toca
        # instalaciones reales: se omite el reenvio y se informa.
        Write-Host ('OMITIDO: hay una instalacion real en ' + $fixedDestination + '; no se ejecuta el reenvio de uninstall.') -ForegroundColor Yellow
        return
    }
    $markerPath = Join-Path $script:DestinationRoot $script:MarkerName
    $markerBefore = Get-FileSha256 -Path $markerPath
    $result = Get-ManagerFixtureResult -Action 'uninstall'
    Assert-Equal 1 $result.ExitCode 'el gestor debe propagar el codigo del motor protegido'
    Assert-Contains $result.StdErr 'ERROR: MensorCAD no esta instalado en' 'el stderr del motor protegido debe llegar intacto'
    Assert-Contains $result.StdErr ([Environment]::GetFolderPath('ProgramFiles')) 'el motor protegido debe resolver la carpeta Program Files real'
    Assert-NotContains $result.StdOut 'ENGINE-CLI-CALLED' 'uninstall nunca debe usar el motor adyacente cacheado'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:DestinationRoot $script:EngineName) -PathType Leaf) 'un uninstall rechazado no puede tocar la instalacion'
    Assert-Equal $markerBefore (Get-FileSha256 -Path $markerPath) 'un uninstall rechazado no puede reescribir la marca'
}

Test-Case 'el motor real desinstala sin conexion solo los archivos registrados' {
    $result = Uninstall-MensorCadBundle -DestinationRoot $script:DestinationRoot -TrustedBoundary $script:IsolatedRoot -AutoCadProbe { $false }
    Assert-Equal 'uninstalled' $result.Status 'la desinstalacion aislada debe completarse'
    Assert-Equal ($script:InventoryCount + 1) ([int]$result.RemovedFiles) 'se deben eliminar el inventario y la marca'
    Assert-True (-not (Test-Path -LiteralPath $script:DestinationRoot)) 'el bundle desinstalado no debe existir'
    Assert-True (Test-Path -LiteralPath $script:IsolatedRoot) 'la carpeta aislada contenedora no se debe borrar'
    $marker = Assert-MensorCadOwnedDestination -DestinationRoot $script:DestinationRoot
    Assert-True ($null -eq $marker) 'sin instalacion no debe haber marca propia'
}

# ---------------------------------------------------------------------------
# Casos de la ruta local con los ZIP REALES construidos (-LocalZip)
# ---------------------------------------------------------------------------
# Los seis artefactos son los del dist construido: la suite no fabrica bytes de
# archivo. Solo se sustituyen las costuras de aislamiento del gestor (raiz
# Program Files, red prohibida y lanzamiento del instalador extraido) para que
# nada salga del scratch de la corrida ni pida UAC.

Test-Case 'el ZIP real del complemento se instala por la ruta local publica y sin red' {
    Reset-LocalEvidence
    $zipPath = Join-Path $script:BuildDir $script:WindowsZipName
    $sidecarPath = Join-Path $script:BuildDir $script:WindowsSidecarName
    $zipBefore = Get-FileSha256 -Path $zipPath
    $sidecarBefore = Get-FileSha256 -Path $sidecarPath
    $result = Get-LocalRouteFixtureResult -Action 'install' -LocalZip $zipPath
    Assert-Equal 0 $result.ExitCode ('una instalacion local real debe terminar bien: ' + $result.StdErr)
    Assert-Contains $result.StdOut ('Paquete local validado: version ' + $script:DistributionVersion) 'el gestor debe validar el paquete real y su version'
    Assert-Contains $result.StdOut 'MensorCAD se instalo correctamente en' 'el motor extraido debe informar la instalacion real'
    Assert-Contains $result.StdOut $script:LocalDestinationRoot 'la instalacion debe quedar en la raiz aislada'
    Assert-NotContains $result.StdOut ([Environment]::GetFolderPath('ProgramFiles')) 'la salida no puede apuntar al destino real de Program Files'
    Assert-Empty $result.StdErr 'una instalacion correcta no debe escribir en stderr'
    Assert-True ($script:LocalDestinationRoot.StartsWith($script:TestRoot, [StringComparison]::OrdinalIgnoreCase)) 'el destino aislado debe quedar dentro del scratch de la corrida'
    $marker = Assert-MensorCadOwnedDestination -DestinationRoot $script:LocalDestinationRoot
    Assert-True ($null -ne $marker) 'el destino aislado debe quedar con marca propia del motor real'
    $installedEngine = Join-Path $script:LocalDestinationRoot $script:EngineName
    $sourceEngine = Join-Path $script:SourceRoot ($script:BundleFolderName + '\' + $script:EngineName)
    Assert-Equal (Get-FileSha256 -Path $sourceEngine) (Get-FileSha256 -Path $installedEngine) 'el motor instalado debe ser el del ZIP real construido'
    # Evidencia del hijo: exactamente uno, desde la copia temporal propia del
    # paquete y con la raiz aislada como unico destino.
    $evidence = Get-LocalEvidenceText
    Assert-Equal 1 (Get-LocalChildCount) 'la ruta local debe ejecutar el instalador incluido una sola vez'
    Assert-Equal 2 (Get-LocalPayloadCount) 'el paquete se ejecuta una vez y termina (inicio y fin)'
    Assert-Contains $evidence ($script:TestRoot + '\mensorcad-local-') 'el instalador debe ejecutarse desde la copia temporal propia'
    Assert-Contains $evidence ('payload|start|install|' + $script:EngineName) 'el hijo debe cargar el motor del paquete real'
    Assert-Contains $evidence 'payload|end|install|0' 'el paquete real debe completar la instalacion aislada'
    Assert-LocalEvidenceClean 'instalacion local'
    Assert-Equal $zipBefore (Get-FileSha256 -Path $zipPath) 'el ZIP real no se puede modificar'
    Assert-Equal $sidecarBefore (Get-FileSha256 -Path $sidecarPath) 'el sidecar real no se puede modificar'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:CliRoot 'mensorcad.ps1') -PathType Leaf) 'el gestor registrado debe seguir disponible'
}

Test-Case 'la misma version no reinstala ni ejecuta el paquete en install ni en update' {
    Reset-LocalEvidence
    $zipPath = Join-Path $script:BuildDir $script:WindowsZipName
    $markerPath = Join-Path $script:LocalDestinationRoot $script:MarkerName
    $markerBefore = Get-FileSha256 -Path $markerPath
    $install = Get-LocalRouteFixtureResult -Action 'install' -LocalZip $zipPath
    Assert-Equal 0 $install.ExitCode 'install con la misma version debe terminar bien'
    Assert-Contains $install.StdOut 'Ya estás actualizado' 'install igual debe informar el texto exacto de no-op'
    Assert-Contains $install.StdOut 'actualizado' 'install igual debe informar que ya esta actualizado'
    Assert-Contains $install.StdOut 'sin cambios' 'install igual no debe reinstalar nada'
    $update = Get-LocalRouteFixtureResult -Action 'update' -LocalZip $zipPath
    Assert-Equal 0 $update.ExitCode 'update con la misma version debe terminar bien'
    Assert-Contains $update.StdOut 'Ya estás actualizado' 'update igual debe informar el texto exacto de no-op'
    Assert-Contains $update.StdOut 'actualizado' 'update igual debe informar que ya esta actualizado'
    Assert-Contains $update.StdOut 'sin cambios' 'update igual no debe reinstalar nada'
    Assert-Equal 0 (Get-LocalChildCount) 'ni install ni update iguales pueden ejecutar el paquete'
    Assert-Equal 0 (Get-LocalPayloadCount) 'el paquete no se puede ejecutar en un no-op'
    Assert-LocalEvidenceClean 'no-op local'
    Assert-Equal $markerBefore (Get-FileSha256 -Path $markerPath) 'un no-op no puede reescribir la instalacion'
}

Test-Case 'el gestor rechaza el ZIP del gestor como paquete del complemento' {
    Reset-LocalEvidence
    $cliZip = Join-Path $script:BuildDir $script:CliZipName
    $cliSidecar = Join-Path $script:BuildDir $script:CliSidecarName
    $zipBefore = Get-FileSha256 -Path $cliZip
    $sidecarBefore = Get-FileSha256 -Path $cliSidecar
    $markerPath = Join-Path $script:LocalDestinationRoot $script:MarkerName
    $markerBefore = Get-FileSha256 -Path $markerPath
    $result = Get-LocalRouteFixtureResult -Action 'install' -LocalZip $cliZip
    Assert-Equal 1 $result.ExitCode 'un ZIP que no es el complemento debe rechazarse'
    Assert-Empty $result.StdOut 'un rechazo no debe escribir en stdout'
    Assert-Contains $result.StdErr "corresponde a 'MensorCAD-CLI.zip'" 'el error debe nombrar el artefacto equivocado'
    Assert-Contains $result.StdErr "y no a 'MensorCAD-Windows.zip'" 'el error debe explicar cual era el paquete esperado'
    Assert-Equal 0 (Get-LocalChildCount) 'un rechazo no puede ejecutar el instalador incluido'
    Assert-Equal 0 (Get-LocalPayloadCount) 'un rechazo no puede ejecutar el paquete'
    Assert-LocalEvidenceClean 'artefacto equivocado'
    Assert-Equal $zipBefore (Get-FileSha256 -Path $cliZip) 'el ZIP del gestor no puede cambiar'
    Assert-Equal $sidecarBefore (Get-FileSha256 -Path $cliSidecar) 'el sidecar del gestor no puede cambiar'
    Assert-Equal $markerBefore (Get-FileSha256 -Path $markerPath) 'el rechazo no puede tocar la instalacion aislada'
}

Test-Case 'el gestor exige el sidecar correcto y deja las entradas intactas' {
    $zipPath = Join-Path $script:BuildDir $script:WindowsZipName
    $zipHash = Get-FileSha256 -Path $zipPath
    $cases = @(
        @{ Name = 'sin sidecar'; Fragment = 'Falta el archivo de verificacion'; Prepare = 'missing' },
        @{ Name = 'hash alterado'; Fragment = 'no coincide con el archivo .sha256'; Prepare = 'wrong-hash' },
        @{ Name = 'sidecar de otro artefacto'; Fragment = "corresponde a 'MensorCAD-CLI.zip'"; Prepare = 'wrong-name' }
    )
    foreach ($case in $cases) {
        Reset-LocalEvidence
        $inputRoot = Join-Path $script:LocalInputRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = [System.IO.Directory]::CreateDirectory($inputRoot)
        $inputZip = Join-Path $inputRoot $script:WindowsZipName
        [System.IO.File]::Copy($zipPath, $inputZip, $false)
        $inputSidecar = $inputZip + '.sha256'
        if ($case.Prepare -eq 'wrong-hash') {
            $sidecarText = (('0' * 64) + '  ' + $script:WindowsZipName + "`n")
            [System.IO.File]::WriteAllText($inputSidecar, $sidecarText, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
        }
        elseif ($case.Prepare -eq 'wrong-name') {
            [System.IO.File]::Copy((Join-Path $script:BuildDir $script:CliSidecarName), $inputSidecar, $false)
        }
        $inputHash = Get-FileSha256 -Path $inputZip
        $sidecarHash = ''
        if (Test-Path -LiteralPath $inputSidecar -PathType Leaf) { $sidecarHash = Get-FileSha256 -Path $inputSidecar }
        $markerPath = Join-Path $script:LocalDestinationRoot $script:MarkerName
        $markerBefore = Get-FileSha256 -Path $markerPath
        $result = Get-LocalRouteFixtureResult -Action 'install' -LocalZip $inputZip
        Assert-Equal 1 $result.ExitCode ('el caso ' + $case.Name + ' debe rechazarse')
        Assert-Empty $result.StdOut ('el caso ' + $case.Name + ' no debe escribir en stdout')
        Assert-Contains $result.StdErr $case.Fragment ('el caso ' + $case.Name + ' debe explicar el rechazo')
        Assert-Equal 0 (Get-LocalChildCount) ('el caso ' + $case.Name + ' no puede ejecutar el instalador incluido')
        Assert-Equal 0 (Get-LocalPayloadCount) ('el caso ' + $case.Name + ' no puede ejecutar el paquete')
        Assert-LocalEvidenceClean ('rechazo de ' + $case.Name)
        Assert-Equal $inputHash (Get-FileSha256 -Path $inputZip) ('el caso ' + $case.Name + ' no puede modificar el ZIP de entrada')
        if (-not [string]::IsNullOrEmpty($sidecarHash)) {
            Assert-Equal $sidecarHash (Get-FileSha256 -Path $inputSidecar) ('el caso ' + $case.Name + ' no puede modificar el sidecar')
        }
        Assert-Equal $markerBefore (Get-FileSha256 -Path $markerPath) ('el caso ' + $case.Name + ' no puede tocar la instalacion')
    }
    Assert-Equal $zipHash (Get-FileSha256 -Path $zipPath) 'el ZIP real del complemento no puede cambiar'
}

Test-Case 'un ZIP anterior sin el motor protegido sigue aceptandose en la ruta local' {
    # Regresion del whitelist: la entrada nueva es OPCIONAL. Un paquete anterior
    # al motor protegido conserva su bundle.sha256 y se instala en su propia
    # raiz aislada, sin relajar el inventario ni los hashes.
    Reset-LocalEvidence
    $legacyDir = Join-Path $script:LocalInputRoot 'legacy'
    $legacyZip = New-LegacyWindowsArchive -SourceZip (Join-Path $script:BuildDir $script:WindowsZipName) -DestinationZip (Join-Path $legacyDir $script:WindowsZipName)
    $legacySidecar = $legacyZip + '.sha256'
    $protectedEntry = $script:BundleFolderName + '/' + $script:EngineName
    $names = @(Get-ZipEntryNames -ZipPath $legacyZip)
    Assert-True (-not ($names -contains $protectedEntry)) 'el ZIP anterior no puede contener el motor protegido'
    Assert-True ($names -contains $script:EngineName) 'el ZIP anterior conserva el motor en la raiz'
    $inventoryText = [System.Text.Encoding]::UTF8.GetString((Get-ZipEntryBytes -ZipPath $legacyZip -EntryName 'bundle.sha256'))
    Assert-NotContains $inventoryText ('  ' + $script:EngineName) 'bundle.sha256 del ZIP anterior no declara el motor protegido'
    Assert-Equal ($script:InventoryCount - 1) (@(($inventoryText -split "`n") | Where-Object { $_.Trim().Length -gt 0 }).Count) 'el inventario anterior debe tener una entrada menos'
    $zipBefore = Get-FileSha256 -Path $legacyZip
    $sidecarBefore = Get-FileSha256 -Path $legacySidecar
    $result = Get-LocalRouteFixtureResult -Action 'install' -LocalZip $legacyZip -IsolatedRoot $script:OlderRoot
    Assert-Equal 0 $result.ExitCode ('un ZIP anterior valido debe seguir aceptandose: ' + $result.StdErr)
    Assert-Contains $result.StdOut ('Paquete local validado: version ' + $script:DistributionVersion) 'el ZIP anterior debe validarse con su propio inventario'
    Assert-Contains $result.StdOut $script:OlderDestinationRoot 'el ZIP anterior debe instalarse en su raiz aislada'
    Assert-Empty $result.StdErr 'la instalacion anterior valida no debe escribir en stderr'
    $marker = Assert-MensorCadOwnedDestination -DestinationRoot $script:OlderDestinationRoot
    Assert-True ($null -ne $marker) 'el destino aislado debe quedar con marca propia'
    # PowerShell 5.1 falla con @(<List[object]>).Count; la lista ya expone Count.
    Assert-Equal ($script:InventoryCount - 1) ([int]$marker.Files.Count) 'la marca debe registrar solo el inventario del ZIP anterior'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:OlderDestinationRoot $script:EngineName) -PathType Leaf)) 'el ZIP anterior no instala motor protegido'
    Assert-Equal 1 (Get-LocalChildCount) 'el ZIP anterior debe ejecutar su instalador incluido una vez'
    Assert-Contains (Get-LocalEvidenceText) 'payload|end|install|0' 'el ZIP anterior debe completar la instalacion aislada'
    Assert-LocalEvidenceClean 'ZIP anterior'
    Assert-Equal $zipBefore (Get-FileSha256 -Path $legacyZip) 'el ZIP anterior no se puede modificar'
    Assert-Equal $sidecarBefore (Get-FileSha256 -Path $legacySidecar) 'el sidecar del ZIP anterior no se puede modificar'
}

Test-Case 'una instalacion posterior rechaza el paquete real sin bajar de version' {
    Reset-LocalEvidence
    $manifestPath = Join-Path $script:LocalDestinationRoot 'PackageContents.xml'
    $markerPath = Join-Path $script:LocalDestinationRoot $script:MarkerName
    $manifestText = [System.IO.File]::ReadAllText($manifestPath)
    $installedAttribute = 'AppVersion="' + $script:DistributionVersion + '"'
    Assert-Contains $manifestText $installedAttribute 'el manifiesto instalado debe declarar la version del build'
    $mutated = $manifestText.Replace($installedAttribute, 'AppVersion="9.9.9"')
    [System.IO.File]::WriteAllText($manifestPath, $mutated, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
    # La marca real se reescribe con el hash nuevo: el estado fixture sigue
    # siendo propiedad valida del motor y el rechazo se decide solo por version.
    $manifestHash = Get-FileSha256 -Path $manifestPath
    $markerJson = [System.IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
    foreach ($entry in @($markerJson.files)) {
        if ([string]$entry.path -eq 'PackageContents.xml') { $entry.sha256 = $manifestHash }
    }
    $markerJson.installedAtUtc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    [System.IO.File]::WriteAllText($markerPath, (($markerJson | ConvertTo-Json -Depth 6) + "`r`n"), (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
    $null = Assert-MensorCadOwnedDestination -DestinationRoot $script:LocalDestinationRoot
    $manifestBefore = Get-FileSha256 -Path $manifestPath
    $markerBefore = Get-FileSha256 -Path $markerPath
    $result = Get-LocalRouteFixtureResult -Action 'install' -LocalZip (Join-Path $script:BuildDir $script:WindowsZipName)
    Assert-Equal 1 $result.ExitCode 'un paquete anterior a la version instalada debe rechazarse'
    Assert-Empty $result.StdOut 'el rechazo por version no debe escribir en stdout'
    Assert-Contains $result.StdErr 'es anterior a la instalada' 'el error debe comparar las versiones'
    Assert-Contains $result.StdErr 'No se baja de versi' 'el error debe aclarar que no se baja de version'
    Assert-Equal 0 (Get-LocalChildCount) 'un rechazo por version no puede ejecutar el instalador incluido'
    Assert-Equal 0 (Get-LocalPayloadCount) 'un rechazo por version no puede ejecutar el paquete'
    Assert-LocalEvidenceClean 'rechazo por version'
    Assert-Equal $manifestBefore (Get-FileSha256 -Path $manifestPath) 'el rechazo no puede reescribir el manifiesto instalado'
    Assert-Equal $markerBefore (Get-FileSha256 -Path $markerPath) 'el rechazo no puede reescribir la marca instalada'
}

Test-Case 'el motor protegido del paquete local real desinstala sin conexion y conserva el gestor' {
    Reset-LocalEvidence
    $protectedEngine = Join-Path $script:LocalDestinationRoot $script:EngineName
    Assert-True (Test-Path -LiteralPath $protectedEngine -PathType Leaf) 'la instalacion local debe incluir el motor protegido'
    $installedMarker = Assert-MensorCadOwnedDestination -DestinationRoot $script:LocalDestinationRoot
    $declared = @($installedMarker.Files | Where-Object { $_.Path -eq $script:EngineName })[0]
    Assert-Equal ([string]$declared.Sha256) (Get-FileSha256 -Path $protectedEngine) 'el motor protegido debe coincidir con su inventario'
    $cliFiles = @(Get-ChildItem -LiteralPath $script:CliRoot -File | ForEach-Object { $_.Name })
    Assert-True ($cliFiles -contains 'mensorcad.ps1') 'el gestor registrado debe existir antes de desinstalar'
    $installedInventory = @(Get-ChildItem -LiteralPath $script:LocalDestinationRoot -Recurse -File)
    $result = Invoke-PowerShellFile -Script $script:LocalChildWrapper -Arguments @(
        '-Mode', 'uninstall',
        '-EnginePath', $protectedEngine,
        '-IsolatedRoot', $script:LocalRoot,
        '-Evidence', $script:LocalEvidence
    )
    Assert-Equal 0 $result.ExitCode ('la desinstalacion sin conexion debe terminar bien: ' + $result.StdErr)
    Assert-Contains $result.StdOut 'MensorCAD se desinstalo correctamente' 'el motor protegido debe informar la desinstalacion'
    Assert-Empty $result.StdErr 'una desinstalacion correcta no debe escribir en stderr'
    Assert-True (-not (Test-Path -LiteralPath $script:LocalDestinationRoot)) 'el bundle desinstalado no debe existir'
    Assert-True (Test-Path -LiteralPath $script:LocalRoot) 'la raiz aislada contenedora no se debe borrar'
    Assert-True ($installedInventory.Count -gt 0) 'la desinstalacion debe tener un inventario previo real'
    foreach ($name in $cliFiles) {
        Assert-True (Test-Path -LiteralPath (Join-Path $script:CliRoot $name) -PathType Leaf) ('el gestor debe conservarse: ' + $name)
    }
    Assert-Contains (Get-LocalEvidenceText) 'payload|end|uninstall|0' 'el motor protegido real debe completar la desinstalacion'
    Assert-LocalEvidenceClean 'desinstalacion local'
    $status = Get-LocalRouteFixtureResult -Action 'status'
    Assert-Equal 0 $status.ExitCode 'status posterior a la desinstalacion debe terminar bien'
    Assert-Contains $status.StdOut 'Complemento: no instalado' 'el complemento desinstalado no debe figurar instalado'
    Assert-Contains $status.StdOut ('MensorCAD CLI ' + $script:DistributionVersion) 'el gestor debe seguir respondiendo tras desinstalar'
}

Test-Case 'las seis salidas construidas siguen intactas despues de la distribucion' {
    Assert-Equal $script:BuildOutputNames.Count $script:ArtifactHashes.Count 'se deben recordar los seis hashes del dist'
    foreach ($name in $script:BuildOutputNames) {
        $current = Get-FileSha256 -Path (Join-Path $script:BuildDir $name)
        Assert-Equal $script:ArtifactHashes[$name] $current ('el artefacto cambio durante la suite: ' + $name)
    }
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------

Write-Host ''
if ($script:Failed -eq 0) {
    try { [System.IO.Directory]::Delete($script:TestRoot, $true) } catch { }
    Write-Host ('OK: ' + $script:Passed + ' casos de distribucion en Windows PowerShell 5.1.') -ForegroundColor Green
    exit 0
}
Write-Host ('FALLARON ' + $script:Failed + ' de ' + ($script:Passed + $script:Failed) + ' casos.') -ForegroundColor Red
foreach ($message in $script:FailureMessages) {
    Write-Host ('  - ' + $message) -ForegroundColor Red
}
Write-Host ('Fixtures conservados en ' + $script:TestRoot) -ForegroundColor Yellow
exit 1
