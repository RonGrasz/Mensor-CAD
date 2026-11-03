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
    $psi.StandardOutputEncoding = [Console]::OutputEncoding
    $psi.StandardErrorEncoding = [Console]::OutputEncoding
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
