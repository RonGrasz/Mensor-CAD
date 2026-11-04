#requires -Version 5.1
<#
    Pruebas funcionales del comando gestor mensorcad (especificaciones S2-S6).

    Solo se ejecutan en Windows con Windows PowerShell 5.1. Toda la evidencia y
    los fixtures viven bajo odd/artifacts/persistent-cli/manager, una carpeta
    ignorada por git. No se descarga nada, no se pide UAC, no se toca el destino
    real de ApplicationPlugins, no se modifica el PATH y no se abre AutoCAD.

    El gestor real se copia a una carpeta de caso y se ejecuta con un motor
    fixture adyacente y, para desinstalar, con un motor fixture protegido dentro
    del bundle. El proceso se lanza de verdad para comprobar codigo de salida,
    stdout, stderr y los argumentos que recibe el motor. CMD se prueba a traves
    de cmd.exe.

    Ejecucion manual:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Manager.ps1
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'SKIP: estas pruebas requieren Windows PowerShell 5.1.' -ForegroundColor Yellow
    exit 2
}

$script:Passed = 0
$script:Failed = 0
$script:FailureMessages = @()
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ManagerPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'mensorcad.ps1'
$script:LauncherPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'mensorcad.cmd'
$script:PowerShellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
# Scratch propio dentro de una ruta ignorada. No se usa TEMP del sistema: la
# ruta puede venir con prefijo de proveedor cuando el repositorio se abre por
# UNC, y nada de esta suite debe escribir fuera del arbol permitido.
$script:ScratchRoot = Join-Path -Path $script:RepositoryRoot -ChildPath 'odd\artifacts\persistent-cli\manager'
$script:TestRoot = Join-Path -Path $script:ScratchRoot -ChildPath ('MCM-' + [guid]::NewGuid().ToString('N'))
# La carpeta temporal que heredan los procesos hijos se fija al scratch del
# repositorio. Asi ningun hijo escribe fuera del arbol ignorado y la suite no
# depende de un TEMP del sistema que puede venir con prefijo de proveedor.
$null = [System.IO.Directory]::CreateDirectory($script:ScratchRoot)
$env:TEMP = $script:ScratchRoot
$env:TMP = $script:ScratchRoot
$script:EnvironmentNames = @(
    'MCM_DEST',
    'MCM_OWNERSHIP',
    'MCM_TAG',
    'MCM_RESOLVE',
    'MCM_CHILD_EXIT',
    'MCM_ENGINE_STDOUT',
    'MCM_ENGINE_STDERR',
    'MCM_ENGINE_REPARSE',
    'MCM_PROTECTED_EXIT',
    'MCM_EVIDENCE',
    'MCM_PF',
    'MCM_LOCAL_EVIDENCE',
    'MCM_LOCAL_EXIT',
    'MCM_LOCAL_STDOUT',
    'MCM_LOCAL_STDERR'
)

if (-not (Test-Path -LiteralPath $script:ManagerPath -PathType Leaf)) {
    Write-Host ("ERROR: no se encontro el gestor en '" + $script:ManagerPath + "'.") -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $script:LauncherPath -PathType Leaf)) {
    Write-Host ("ERROR: no se encontro el lanzador en '" + $script:LauncherPath + "'.") -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $script:PowerShellPath -PathType Leaf)) {
    Write-Host ("ERROR: no se encontro Windows PowerShell en '" + $script:PowerShellPath + "'.") -ForegroundColor Red
    exit 1
}

$null = [System.IO.Directory]::CreateDirectory($script:TestRoot)

# ---------------------------------------------------------------------------
# Utilidades de asercion y ejecucion real
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

function Invoke-ManagerPowerShell {
    param([string]$ManagerScript, [string[]]$Arguments = @())
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-QuotedArgument -Value $ManagerScript))) {
        $parts.Add($part)
    }
    foreach ($argument in @($Arguments)) {
        $parts.Add((ConvertTo-QuotedArgument -Value ([string]$argument)))
    }
    return (Start-CapturedProcess -FileName $script:PowerShellPath -ArgumentString ($parts -join ' ') -WorkingDirectory $env:SystemRoot)
}

function Invoke-Launcher {
    param([string]$Launcher, [string[]]$Arguments = @())
    $inner = '"' + $Launcher + '"'
    foreach ($argument in @($Arguments)) {
        $inner += ' ' + (ConvertTo-QuotedArgument -Value ([string]$argument))
    }
    # cmd.exe necesita el patron /d /c ""script" args" para reenviar sin perder
    # el codigo de salida.
    return (Start-CapturedProcess -FileName 'cmd.exe' -ArgumentString ('/d /c "' + $inner + '"') -WorkingDirectory $env:SystemRoot)
}

# ---------------------------------------------------------------------------
# Fixtures: motor adyacente, motor protegido y bundle
# ---------------------------------------------------------------------------

$script:AdjacentEngineTemplate = @'
param()
function Add-McAdjacentEvidence {
    param([string]$Line)
    if ([string]::IsNullOrEmpty($env:MCM_EVIDENCE)) { return }
    Add-Content -LiteralPath $env:MCM_EVIDENCE -Value ('adjacent|' + $Line) -Encoding UTF8
}
$script:MensorCadMarkerFileName = '.mensorcad-install.json'
function Get-MensorCadDestinationRoot {
    Add-McAdjacentEvidence 'destination'
    return [string]$env:MCM_DEST
}
function Test-MensorCadReparsePoint {
    param([string]$Path)
    Add-McAdjacentEvidence ('reparse|' + [string]$Path)
    if ($env:MCM_ENGINE_REPARSE -eq '1') { return $true }
    return $false
}
function Get-MensorCadDisplayVersion {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    if ($text.Length -eq 0 -or $text.Length -gt 32) { return $null }
    if ($text -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]*$') { return $null }
    if ($text -notmatch '[0-9]') { return $null }
    return $text
}
function Assert-MensorCadOwnedDestination {
    param([string]$DestinationRoot)
    Add-McAdjacentEvidence ('assert|' + [string]$DestinationRoot)
    if ($env:MCM_OWNERSHIP -eq 'invalid') {
        throw 'La instalacion existente esta modificada (fixture).'
    }
    if ($env:MCM_OWNERSHIP -eq 'absent') { return $null }
    return [pscustomobject]@{
        InstalledAtUtc = '2024-01-02T03:04:05Z'
        MarkerPath = (Join-Path $DestinationRoot '.mensorcad-install.json')
    }
}
function Resolve-MensorCadReleaseTag {
    param([string]$Version)
    Add-McAdjacentEvidence ('resolve|' + [string]$Version)
    if ($env:MCM_RESOLVE -eq 'throw') {
        throw 'No se pudo consultar la ultima release (fixture).'
    }
    return [string]$env:MCM_TAG
}
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
    Add-McAdjacentEvidence ('cli|uninstall=' + [bool]$Uninstall + ';fromRelease=' + [bool]$FromRelease + ';version=' + [string]$Version)
    if (-not [string]::IsNullOrEmpty($env:MCM_ENGINE_STDOUT)) {
        [Console]::Out.WriteLine([string]$env:MCM_ENGINE_STDOUT)
    }
    if (-not [string]::IsNullOrEmpty($env:MCM_ENGINE_STDERR)) {
        [Console]::Error.WriteLine([string]$env:MCM_ENGINE_STDERR)
    }
    return [int]$env:MCM_CHILD_EXIT
}
'@

$script:ProtectedEngineTemplate = @'
param([switch]$Uninstall, [switch]$NoAnimation, [switch]$Help, [switch]$FromRelease, [string]$Version)
function Add-McProtectedEvidence {
    param([string]$Line)
    if ([string]::IsNullOrEmpty($env:MCM_EVIDENCE)) { return }
    Add-Content -LiteralPath $env:MCM_EVIDENCE -Value ('protected|' + $Line) -Encoding UTF8
}
Add-McProtectedEvidence ('cli|uninstall=' + [bool]$Uninstall + ';fromRelease=' + [bool]$FromRelease + ';version=' + [string]$Version)
[Console]::Out.WriteLine('PROTECTED-ENGINE-STDOUT')
[Console]::Error.WriteLine('PROTECTED-ENGINE-STDERR')
exit [int]$env:MCM_PROTECTED_EXIT
'@

function Write-Utf8File {
    param([string]$Path, [string]$Content, [switch]$Bom)
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @([bool]$Bom)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function New-ManagerCase {
    param(
        [string]$Version = '',
        [switch]$WithEngine,
        [switch]$WithLauncher
    )
    $root = Join-Path -Path $script:TestRoot -ChildPath ('c-' + [guid]::NewGuid().ToString('N'))
    $managerDir = Join-Path -Path $root -ChildPath 'manager'
    $null = [System.IO.Directory]::CreateDirectory($managerDir)
    $source = [System.IO.File]::ReadAllText($script:ManagerPath)
    if (-not [string]::IsNullOrEmpty($Version)) {
        $source = $source.Replace('__MENSORCAD_MANAGER_VERSION__', $Version)
    }
    Write-Utf8File -Path (Join-Path $managerDir 'mensorcad.ps1') -Content $source -Bom
    if ($WithLauncher) {
        [System.IO.File]::Copy($script:LauncherPath, (Join-Path $managerDir 'mensorcad.cmd'))
    }
    if ($WithEngine) {
        Write-Utf8File -Path (Join-Path $managerDir 'Install-MensorCAD.ps1') -Content $script:AdjacentEngineTemplate
    }
    return [pscustomobject]@{
        Root = $root
        ManagerDir = $managerDir
        ManagerPath = (Join-Path $managerDir 'mensorcad.ps1')
        LauncherPath = (Join-Path $managerDir 'mensorcad.cmd')
        EvidencePath = (Join-Path $root 'evidence.log')
        BundlePath = (Join-Path $root 'MensorCAD.bundle')
    }
}

function New-BundleFixture {
    param(
        [string]$BundlePath,
        [string]$AppVersion = '1.2.3',
        [string]$ManifestVersion = '1.2.3',
        [switch]$NoAppVersion,
        [switch]$NoVersions,
        [switch]$WithProtectedEngine
    )
    $null = [System.IO.Directory]::CreateDirectory($BundlePath)
    $attributes = ''
    if (-not $NoVersions) {
        if (-not $NoAppVersion) { $attributes += ' AppVersion="' + $AppVersion + '"' }
        $attributes += ' Version="' + $ManifestVersion + '"'
    }
    $xml = '<?xml version="1.0" encoding="utf-8"?>' + "`n" + '<ApplicationPackage' + $attributes + ' />' + "`n"
    Write-Utf8File -Path (Join-Path $BundlePath 'PackageContents.xml') -Content $xml
    Write-Utf8File -Path (Join-Path $BundlePath '.mensorcad-install.json') -Content '{"format":"fixture"}'
    if ($WithProtectedEngine) {
        Write-Utf8File -Path (Join-Path $BundlePath 'Install-MensorCAD.ps1') -Content $script:ProtectedEngineTemplate
    }
}

function Set-ManagerEnvironment {
    param([pscustomobject]$Case, [hashtable]$Values = @{})
    foreach ($name in $script:EnvironmentNames) {
        Remove-Item -Path ('Env:' + $name) -ErrorAction SilentlyContinue
    }
    $env:MCM_EVIDENCE = [string]$Case.EvidencePath
    foreach ($key in $Values.Keys) {
        Set-Item -Path ('Env:' + [string]$key) -Value ([string]$Values[$key])
    }
}

function New-InstalledCase {
    param(
        [string]$ManagerVersion = '0.1.0',
        [string]$AppVersion = '1.2.3',
        [string]$ManifestVersion = '1.2.3',
        [string]$Tag = 'v1.2.3',
        [string]$Ownership = 'owned',
        [switch]$NoAppVersion,
        [switch]$NoVersions,
        [switch]$WithProtectedEngine,
        [switch]$WithLauncher
    )
    $case = New-ManagerCase -Version $ManagerVersion -WithEngine -WithLauncher:$WithLauncher
    New-BundleFixture -BundlePath $case.BundlePath -AppVersion $AppVersion -ManifestVersion $ManifestVersion -NoAppVersion:$NoAppVersion -NoVersions:$NoVersions -WithProtectedEngine:$WithProtectedEngine
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = $case.BundlePath
        'MCM_OWNERSHIP' = $Ownership
        'MCM_TAG' = $Tag
        'MCM_CHILD_EXIT' = '0'
    }
    return $case
}

function Get-Evidence {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Path)
}

function Test-EvidenceContains {
    param([string]$Path, [string]$Fragment)
    foreach ($line in (Get-Evidence -Path $Path)) {
        if (([string]$line).IndexOf($Fragment, [StringComparison]::Ordinal) -ge 0) { return $true }
    }
    return $false
}

function Get-TreeSnapshot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return '<ausente>' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object -Property FullName)) {
        $relative = [string]$item.FullName
        if ($relative.StartsWith($Path, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $relative.Substring($Path.Length)
        }
        $hash = ''
        if (-not $item.PSIsContainer) {
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
        $lines.Add($relative + '|' + $hash + '|' + $item.LastWriteTimeUtc.ToString('o'))
    }
    return ($lines -join "`n")
}

function Get-StdOutLines {
    param([string]$Text)
    return @($Text -split "\r?\n" | ForEach-Object { $_.Trim() })
}

# ---------------------------------------------------------------------------
# Casos: version, ayuda, guarda de dot-source y resumen
# ---------------------------------------------------------------------------

Test-Case 'version del gestor no requiere motor ni instalacion' {
    $case = New-ManagerCase -Version '9.9.9'
    Set-ManagerEnvironment -Case $case -Values @{ 'MCM_DEST' = (Join-Path $case.Root 'ausente'); 'MCM_OWNERSHIP' = 'absent' }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('--version')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Equal 'mensorcad 9.9.9' $result.StdOut.Trim() 'version sellada'
    Assert-Empty $result.StdErr 'stderr'
    Assert-True (-not (Test-Path -LiteralPath $case.EvidencePath)) 'no debe cargar el motor'
}

Test-Case 'version sin sellar se informa como desarrollo' {
    $case = New-ManagerCase
    Set-ManagerEnvironment -Case $case -Values @{ 'MCM_DEST' = (Join-Path $case.Root 'ausente'); 'MCM_OWNERSHIP' = 'absent' }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('--version')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Equal 'mensorcad desarrollo' $result.StdOut.Trim() 'version de desarrollo'
}

Test-Case 'ayuda funciona sin motor y describe el flujo completo' {
    $case = New-ManagerCase -Version '0.1.0'
    Set-ManagerEnvironment -Case $case -Values @{ 'MCM_DEST' = (Join-Path $case.Root 'ausente'); 'MCM_OWNERSHIP' = 'absent' }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('--help')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Empty $result.StdErr 'stderr'
    foreach ($fragment in @('mensorcad install', 'mensorcad -i', 'mensorcad update', 'mensorcad uninstall', 'mensorcad status', 'mensorcad --version')) {
        Assert-Contains $result.StdOut $fragment 'la ayuda debe describir el comando'
    }
    $alias = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('help')
    Assert-Equal 2 $alias.ExitCode 'la palabra help no es un comando publico'
    Assert-Contains $alias.StdErr '--help' 'debe sugerir la bandera correcta'
    Assert-True (-not (Test-Path -LiteralPath $case.EvidencePath)) 'la ayuda no debe cargar el motor'
}

Test-Case 'dot-source solo define funciones y no ejecuta la CLI' {
    $case = New-ManagerCase -Version '0.1.0'
    $probe = Join-Path $case.Root 'dotprobe.ps1'
    $content = '. "' + $case.ManagerPath + '"' + "`n" + '[Console]::Out.WriteLine("DOTSOURCE-OK")' + "`n" + 'exit 0' + "`n"
    Write-Utf8File -Path $probe -Content $content -Bom
    $result = Start-CapturedProcess -FileName $script:PowerShellPath -ArgumentString ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-QuotedArgument -Value $probe)) -WorkingDirectory $env:SystemRoot
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'DOTSOURCE-OK' 'la guarda debe devolver el control'
    Assert-NotContains $result.StdOut 'Uso:' 'no debe ejecutar la ayuda'
}

Test-Case 'resumen sin instalacion es de solo lectura y sin red' {
    $case = New-ManagerCase -Version '0.1.0' -WithEngine
    Set-ManagerEnvironment -Case $case -Values @{ 'MCM_DEST' = (Join-Path $case.Root 'ausente'); 'MCM_OWNERSHIP' = 'absent' }
    $before = Get-TreeSnapshot -Path $case.ManagerDir
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Empty $result.StdErr 'stderr'
    Assert-Contains $result.StdOut 'MensorCAD CLI 0.1.0' 'version del gestor'
    Assert-Contains $result.StdOut 'Complemento: no instalado' 'estado ausente'
    Assert-Contains $result.StdOut 'no instala nada' 'el resumen no instala'
    Assert-Contains $result.StdOut 'mensorcad install' 'sugerencia de instalacion'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'resolve|')) 'no debe consultar la release'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe invocar el motor'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.ManagerDir) 'no debe escribir junto al gestor'
}

Test-Case 'resumen instalado muestra gestor y version del complemento' {
    $case = New-InstalledCase -ManagerVersion '0.1.0' -AppVersion '2.3.4' -ManifestVersion '9.9.9' -Tag 'v9.9.9'
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'MensorCAD CLI 0.1.0' 'version del gestor'
    Assert-Contains $result.StdOut 'Complemento: instalado' 'estado instalado'
    Assert-Contains $result.StdOut 'Versión instalada: 2.3.4' 'version del complemento'
    Assert-NotContains $result.StdOut 'resolve|' 'sin red'
}

# ---------------------------------------------------------------------------
# Casos: status
# ---------------------------------------------------------------------------

Test-Case 'status lee AppVersion del manifiesto y no usa la red' {
    $case = New-InstalledCase -AppVersion '2.3.4' -ManifestVersion '9.9.9' -Tag 'v9.9.9'
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('status')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Empty $result.StdErr 'stderr'
    Assert-Contains $result.StdOut 'Complemento: instalado' 'estado'
    Assert-Contains $result.StdOut 'Versión instalada: 2.3.4' 'AppVersion tiene prioridad'
    Assert-Contains $result.StdOut $case.BundlePath 'ubicacion'
    Assert-NotContains $result.StdOut '9.9.9' 'no debe usar Version si existe AppVersion'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'resolve|')) 'sin red'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'sin motor'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin escrituras'
}

Test-Case 'status usa Version cuando falta AppVersion' {
    $case = New-InstalledCase -AppVersion '0.0.0' -ManifestVersion '3.4.5' -NoAppVersion
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('status')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'Versión instalada: 3.4.5' 'fallback a Version'
}

Test-Case 'status no muestra una version con caracteres no imprimibles' {
    $case = New-InstalledCase -AppVersion '1.2.3 4' -ManifestVersion '9.9.9'
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('status')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'Versión instalada: desconocida' 'version saneada'
    Assert-NotContains $result.StdOut '1.2.3 4' 'no debe repetir el valor invalido'
}

Test-Case 'status informa version desconocida sin inventarla' {
    $case = New-InstalledCase -NoVersions
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('status')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'Versión instalada: desconocida' 'version ausente'
}

Test-Case 'status no verificable falla sin tocar la instalacion' {
    $case = New-InstalledCase -Ownership 'invalid'
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('status')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'modificada (fixture)' 'error de propiedad'
    Assert-Contains $result.StdOut 'MensorCAD CLI' 'debe informar el gestor'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'resolve|')) 'sin red'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'sin motor'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin escrituras'
}

# ---------------------------------------------------------------------------
# Casos: update
# ---------------------------------------------------------------------------

Test-Case 'update sin complemento sugiere install y no consulta la red' {
    $case = New-ManagerCase -Version '0.1.0' -WithEngine
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = (Join-Path $case.Root 'ausente')
        'MCM_OWNERSHIP' = 'absent'
        'MCM_TAG' = 'v9.9.9'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('update')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'mensorcad install' 'debe sugerir install'
    Assert-Empty $result.StdOut 'stdout'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'resolve|')) 'no debe consultar la release'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe invocar el motor'
}

Test-Case 'update con la misma version no reinstala y avisa exacto' {
    $case = New-InstalledCase -AppVersion '1.2.3' -ManifestVersion '1.2.3' -Tag 'v1.2.3'
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('update')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Empty $result.StdErr 'stderr'
    Assert-True ((Get-StdOutLines -Text $result.StdOut) -contains 'Ya estás actualizado') 'mensaje exacto'
    Assert-True (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'resolve|') 'debe consultar la release'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe reinstalar'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin cambios'
}

Test-Case 'update normaliza 1.2 y v1.2.0 como la misma version' {
    $case = New-InstalledCase -AppVersion '1.2' -ManifestVersion '1.2' -Tag 'v1.2.0'
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('update')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-True ((Get-StdOutLines -Text $result.StdOut) -contains 'Ya estás actualizado') 'mensaje exacto'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe reinstalar'
}

Test-Case 'update no baja de version' {
    $case = New-InstalledCase -AppVersion '2.0.0' -ManifestVersion '2.0.0' -Tag 'v1.9.9'
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('update')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'No se baja de' 'debe rechazar el downgrade'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe invocar el motor'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin cambios'
}

Test-Case 'update rechaza una comparacion ambigua' {
    $case = New-InstalledCase -AppVersion '1.2.3-beta' -ManifestVersion '1.2.3-beta' -Tag 'v1.2.4'
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('update')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'No se pudo comparar' 'debe rechazar la ambiguedad'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe invocar el motor'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin cambios'
}

Test-Case 'update rechaza una version instalada desconocida' {
    $case = New-InstalledCase -NoVersions -Tag 'v1.2.4'
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('update')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'desconocida' 'debe explicar la version ausente'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe invocar el motor'
}

Test-Case 'update con release nueva delega, fija el tag y conserva salida y codigo' {
    $case = New-InstalledCase -AppVersion '1.0.0' -ManifestVersion '1.0.0' -Tag 'v2.0.0'
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = $case.BundlePath
        'MCM_OWNERSHIP' = 'owned'
        'MCM_TAG' = 'v2.0.0'
        'MCM_CHILD_EXIT' = '7'
        'MCM_ENGINE_STDOUT' = 'ENGINE-UPDATE-OUT'
        'MCM_ENGINE_STDERR' = 'ENGINE-UPDATE-ERR'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('update')
    Assert-Equal 7 $result.ExitCode 'el codigo del motor se propaga exacto'
    Assert-Contains $result.StdOut 'ENGINE-UPDATE-OUT' 'stdout del motor'
    Assert-Contains $result.StdErr 'ENGINE-UPDATE-ERR' 'stderr del motor'
    Assert-True (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'adjacent|cli|uninstall=False;fromRelease=True;version=v2.0.0') 'argumentos fijados'
}

Test-Case 'update falla limpio si no puede resolver la release' {
    $case = New-InstalledCase -AppVersion '1.0.0' -ManifestVersion '1.0.0' -Tag 'v2.0.0'
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = $case.BundlePath
        'MCM_OWNERSHIP' = 'owned'
        'MCM_TAG' = 'v2.0.0'
        'MCM_RESOLVE' = 'throw'
    }
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('update')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'No se pudo consultar la ultima release' 'error de red'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe invocar el motor'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin cambios'
}

# ---------------------------------------------------------------------------
# Casos: install
# ---------------------------------------------------------------------------

Test-Case 'install sin complemento instala la release fijada' {
    $case = New-ManagerCase -Version '0.1.0' -WithEngine
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = (Join-Path $case.Root 'ausente')
        'MCM_OWNERSHIP' = 'absent'
        'MCM_TAG' = 'v3.1.4'
        'MCM_CHILD_EXIT' = '0'
        'MCM_ENGINE_STDOUT' = 'ENGINE-INSTALL-OUT'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('install')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'ENGINE-INSTALL-OUT' 'stdout del motor'
    Assert-True (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'adjacent|resolve|') 'debe resolver'
    Assert-True (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'adjacent|cli|uninstall=False;fromRelease=True;version=v3.1.4') 'install remoto fijado'
}

Test-Case 'el alias -i tambien instala' {
    $case = New-ManagerCase -Version '0.1.0' -WithEngine
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = (Join-Path $case.Root 'ausente')
        'MCM_OWNERSHIP' = 'absent'
        'MCM_TAG' = 'v4.5.6'
        'MCM_CHILD_EXIT' = '0'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('-i')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-True (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'adjacent|cli|uninstall=False;fromRelease=True;version=v4.5.6') 'alias de install'
}

Test-Case 'install no baja de version un complemento existente' {
    $case = New-InstalledCase -AppVersion '2.0.0' -ManifestVersion '2.0.0' -Tag 'v1.0.0'
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('install')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'No se baja de' 'debe rechazar el downgrade'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe invocar el motor'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin cambios'
}

Test-Case 'install con la misma version no reinstala' {
    $case = New-InstalledCase -AppVersion '1.2.3' -ManifestVersion '1.2.3' -Tag 'v1.2.3'
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('install')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-True ((Get-StdOutLines -Text $result.StdOut) -contains 'Ya estás actualizado') 'mensaje exacto'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe reinstalar'
}

Test-Case 'install rechaza una comparacion ambigua' {
    $case = New-InstalledCase -AppVersion 'desarrollo' -ManifestVersion 'desarrollo' -Tag 'v1.2.3'
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('install')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'No se pudo comparar' 'debe rechazar la ambiguedad'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'no debe invocar el motor'
}

Test-Case 'install falla limpio si falta el motor adyacente' {
    $case = New-ManagerCase -Version '0.1.0'
    Set-ManagerEnvironment -Case $case -Values @{ 'MCM_DEST' = (Join-Path $case.Root 'ausente'); 'MCM_OWNERSHIP' = 'absent' }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('install')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'Install-MensorCAD.ps1' 'debe nombrar el motor faltante'
    Assert-True (-not (Test-Path -LiteralPath $case.EvidencePath)) 'no debe cargar nada'
}

# ---------------------------------------------------------------------------
# Casos: uninstall
# ---------------------------------------------------------------------------

Test-Case 'uninstall sin complemento no hace nada' {
    $case = New-ManagerCase -Version '0.1.0' -WithEngine
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = (Join-Path $case.Root 'ausente')
        'MCM_OWNERSHIP' = 'absent'
        'MCM_TAG' = 'v9.9.9'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('uninstall')
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'no está instalado' 'estado ausente'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'resolve|')) 'sin red'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'sin motor'
}

Test-Case 'uninstall usa el motor protegido, no el adyacente' {
    $case = New-InstalledCase -WithProtectedEngine -AppVersion '1.2.3' -ManifestVersion '1.2.3' -Tag 'v1.2.3'
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = $case.BundlePath
        'MCM_OWNERSHIP' = 'owned'
        'MCM_TAG' = 'v1.2.3'
        'MCM_PROTECTED_EXIT' = '42'
    }
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('uninstall')
    Assert-Equal 42 $result.ExitCode 'el codigo del motor protegido se propaga exacto'
    Assert-Contains $result.StdOut 'PROTECTED-ENGINE-STDOUT' 'stdout del motor protegido'
    Assert-Contains $result.StdErr 'PROTECTED-ENGINE-STDERR' 'stderr del motor protegido'
    Assert-True (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'protected|cli|uninstall=True;fromRelease=False;version=') 'desinstalacion en el motor protegido'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'adjacent|cli|')) 'no debe usar el motor adyacente'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'resolve|')) 'sin red'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin escrituras'
}

Test-Case 'uninstall de un bundle legado da el mensaje ZIP sin descargar' {
    $case = New-ManagerCase -Version '0.1.0' -WithEngine
    New-BundleFixture -BundlePath $case.BundlePath -AppVersion '1.0.0' -ManifestVersion '1.0.0'
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = $case.BundlePath
        'MCM_OWNERSHIP' = 'owned'
        'MCM_TAG' = 'v9.9.9'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('uninstall')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'ZIP' 'debe ofrecer el ZIP'
    Assert-Contains $result.StdErr 'Desinstalar.bat' 'debe indicar el lanzador manual'
    Assert-Contains $result.StdErr 'no descarga nada' 'no debe descargar'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'resolve|')) 'sin red'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'cli|')) 'sin motor'
}

Test-Case 'uninstall rechaza un motor protegido con punto de reanalisis' {
    $case = New-InstalledCase -WithProtectedEngine -AppVersion '1.2.3' -ManifestVersion '1.2.3' -Tag 'v1.2.3'
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = $case.BundlePath
        'MCM_OWNERSHIP' = 'owned'
        'MCM_TAG' = 'v1.2.3'
        'MCM_ENGINE_REPARSE' = '1'
    }
    $before = Get-TreeSnapshot -Path $case.BundlePath
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('uninstall')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'punto de reanálisis' 'debe rechazar el reparse'
    Assert-True (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'reparse|') 'debe validar el reparse'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'protected|cli|')) 'no debe ejecutar el motor'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.BundlePath) 'sin cambios'
}

Test-Case 'uninstall valida la propiedad antes de invocar cualquier motor' {
    $case = New-InstalledCase -WithProtectedEngine -Ownership 'invalid'
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('uninstall')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'modificada (fixture)' 'error de propiedad'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'reparse|')) 'no debe llegar al motor'
    Assert-True (-not (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'protected|cli|')) 'no debe ejecutar el motor'
}

# ---------------------------------------------------------------------------
# Casos: entrada invalida antes de red, elevacion o escrituras
# ---------------------------------------------------------------------------

$script:InvalidCases = @(
    @{ Name = '--force'; Fragment = 'no reconocida' },
    @{ Name = '-x'; Fragment = 'no reconocida' },
    @{ Name = 'install extra'; Fragment = 'Argumentos adicionales' },
    @{ Name = '--version extra'; Fragment = 'Argumentos adicionales' },
    @{ Name = 'unistall'; Fragment = 'uninstall' },
    @{ Name = 'unknown'; Fragment = 'Comando no reconocido' }
)

foreach ($spec in $script:InvalidCases) {
    Test-Case ('entrada invalida rechazada sin tocar nada: ' + $spec.Name) {
        $case = New-InstalledCase -WithProtectedEngine
        $beforeManager = Get-TreeSnapshot -Path $case.ManagerDir
        $beforeBundle = Get-TreeSnapshot -Path $case.BundlePath
        $arguments = @($spec.Name -split ' ')
        $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments $arguments
        Assert-Equal 2 $result.ExitCode 'codigo de uso'
        Assert-Empty $result.StdOut 'stdout vacio'
        Assert-Contains $result.StdErr $spec.Fragment 'mensaje de rechazo'
        Assert-Contains $result.StdErr 'No se modific' 'debe aclarar que no hubo cambios'
        Assert-True (-not (Test-Path -LiteralPath $case.EvidencePath)) 'el motor no debe cargarse'
        Assert-Equal $beforeManager (Get-TreeSnapshot -Path $case.ManagerDir) 'sin escrituras junto al gestor'
        Assert-Equal $beforeBundle (Get-TreeSnapshot -Path $case.BundlePath) 'sin escrituras en el bundle'
    }
}

# ---------------------------------------------------------------------------
# Integracion de solo lectura con el motor real
# ---------------------------------------------------------------------------

Test-Case 'el motor real se carga con dot-source y la guarda devuelve el control' {
    # Esta prueba no simula el motor: carga el Install-MensorCAD.ps1 real en un
    # proceso aparte y comprueba la guarda de dot-source, las funciones que el
    # gestor reutiliza y una validacion de destino ausente que no toca Program
    # Files ni pide elevacion.
    $case = New-ManagerCase -Version '0.1.0'
    $realEngine = Join-Path -Path $script:RepositoryRoot -ChildPath 'Install-MensorCAD.ps1'
    $probe = Join-Path $case.Root 'realengineprobe.ps1'
    $lines = @(
        'Set-StrictMode -Version 2.0',
        '$ErrorActionPreference = ''Stop''',
        ('. "' + $realEngine + '"'),
        '[Console]::Out.WriteLine(''ENGINE-DOTSOURCE-OK'')',
        'foreach ($name in @(''Get-MensorCadDestinationRoot'', ''Assert-MensorCadOwnedDestination'', ''Resolve-MensorCadReleaseTag'', ''Invoke-MensorCadCli'', ''Test-MensorCadReparsePoint'', ''Get-MensorCadDisplayVersion'')) {',
        '    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { exit 3 }',
        '}',
        '$missing = Join-Path $env:TEMP (''missing-'' + [guid]::NewGuid().ToString(''N''))',
        '$state = Assert-MensorCadOwnedDestination -DestinationRoot $missing',
        'if ($null -ne $state) { exit 5 }',
        '[Console]::Out.WriteLine(''READONLY-STATE-OK'')',
        'exit 0'
    )
    Write-Utf8File -Path $probe -Content (($lines -join "`n") + "`n") -Bom
    $result = Start-CapturedProcess -FileName $script:PowerShellPath -ArgumentString ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-QuotedArgument -Value $probe)) -WorkingDirectory $env:SystemRoot
    Assert-Equal 0 $result.ExitCode 'la guarda del motor real debe devolver el control'
    Assert-Contains $result.StdOut 'ENGINE-DOTSOURCE-OK' 'el motor real debe cargarse'
    Assert-Contains $result.StdOut 'READONLY-STATE-OK' 'la validacion de un destino ausente es de solo lectura'
    Assert-Empty $result.StdErr 'stderr del motor real'
}

# ---------------------------------------------------------------------------
# Casos: lanzador CMD
# ---------------------------------------------------------------------------

Test-Case 'lanzador CMD reenvia version, ayuda y codigo de uso' {
    $case = New-ManagerCase -Version '9.9.9' -WithLauncher
    Set-ManagerEnvironment -Case $case -Values @{ 'MCM_DEST' = (Join-Path $case.Root 'ausente'); 'MCM_OWNERSHIP' = 'absent' }
    $version = Invoke-Launcher -Launcher $case.LauncherPath -Arguments @('--version')
    Assert-Equal 0 $version.ExitCode 'codigo de version'
    Assert-Equal 'mensorcad 9.9.9' $version.StdOut.Trim() 'stdout de version'
    Assert-Empty $version.StdErr 'stderr de version'
    $help = Invoke-Launcher -Launcher $case.LauncherPath -Arguments @('--help')
    Assert-Equal 0 $help.ExitCode 'codigo de ayuda'
    Assert-Contains $help.StdOut 'mensorcad install' 'ayuda por CMD'
    Assert-Empty $help.StdErr 'stderr de ayuda'
    $bad = Invoke-Launcher -Launcher $case.LauncherPath -Arguments @('--desconocido')
    Assert-Equal 2 $bad.ExitCode 'codigo de uso por CMD'
    Assert-Contains $bad.StdErr 'no reconocida' 'error por CMD'
}

Test-Case 'lanzador CMD propaga argumentos y el codigo real del motor' {
    $case = New-ManagerCase -Version '0.1.0' -WithEngine -WithLauncher
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = (Join-Path $case.Root 'ausente')
        'MCM_OWNERSHIP' = 'absent'
        'MCM_TAG' = 'v7.8.9'
        'MCM_CHILD_EXIT' = '7'
        'MCM_ENGINE_STDOUT' = 'CMD-ENGINE-OUT'
    }
    $result = Invoke-Launcher -Launcher $case.LauncherPath -Arguments @('install')
    Assert-Equal 7 $result.ExitCode 'cmd debe devolver el codigo del motor'
    Assert-Contains $result.StdOut 'CMD-ENGINE-OUT' 'salida del motor por CMD'
    Assert-True (Test-EvidenceContains -Path $case.EvidencePath -Fragment 'adjacent|cli|uninstall=False;fromRelease=True;version=v7.8.9') 'argumentos por CMD'
}

# ---------------------------------------------------------------------------
# Casos: paquete local (-LocalZip)
# ---------------------------------------------------------------------------
# El motor adyacente de estos casos es el motor REAL con tres costuras de
# fixture: destino/Program Files falsos, estado de propiedad falso y red
# prohibida. Asi la validacion del ZIP, la extraccion y la revalidacion del
# paquete son las de produccion, pero nada sale del scratch ignorado y el
# instalador que se ejecuta es el stub incluido en el ZIP fixture (nunca pide
# UAC ni escribe en Program Files).

$script:HybridEngineOverrides = @'
function Add-McHybridEvidence {
    param([string]$Line)
    if ([string]::IsNullOrEmpty($env:MCM_EVIDENCE)) { return }
    Add-Content -LiteralPath $env:MCM_EVIDENCE -Value ('hybrid|' + $Line) -Encoding UTF8
}
function Get-MensorCadProgramFilesRoot {
    Add-McHybridEvidence ('programfiles|' + [string]$env:MCM_PF)
    return [string]$env:MCM_PF
}
function Get-MensorCadDestinationRoot {
    Add-McHybridEvidence 'destination'
    return [string]$env:MCM_DEST
}
function Assert-MensorCadOwnedDestination {
    param([string]$DestinationRoot)
    Add-McHybridEvidence ('assert|' + [string]$DestinationRoot)
    if ($env:MCM_OWNERSHIP -eq 'invalid') {
        throw 'La instalacion existente esta modificada (fixture).'
    }
    if ($env:MCM_OWNERSHIP -eq 'absent') { return $null }
    return [pscustomobject]@{
        InstalledAtUtc = '2024-01-02T03:04:05Z'
        MarkerPath = (Join-Path $DestinationRoot '.mensorcad-install.json')
    }
}
function Get-MensorCadRemoteText {
    param([string]$Uri)
    Add-McHybridEvidence 'network|text'
    throw 'La red no esta permitida en esta prueba (fixture).'
}
function Save-MensorCadRemoteFile {
    param([string]$Uri, [string]$DestinationPath)
    Add-McHybridEvidence 'network|file'
    throw 'La red no esta permitida en esta prueba (fixture).'
}
'@

$script:LocalChildTemplate = @'
param([switch]$Uninstall, [switch]$NoAnimation)
$evidence = [string]$env:MCM_LOCAL_EVIDENCE
if (-not [string]::IsNullOrEmpty($evidence)) {
    $version = ''
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath 'MensorCAD.bundle\PackageContents.xml'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        $document = New-Object -TypeName 'System.Xml.XmlDocument'
        $document.XmlResolver = $null
        $document.Load($manifest)
        $version = [string]$document.DocumentElement.GetAttribute('AppVersion')
    }
    Add-Content -LiteralPath $evidence -Value ('local-child|ran|version=' + $version) -Encoding UTF8
}
$out = [string]$env:MCM_LOCAL_STDOUT
if (-not [string]::IsNullOrEmpty($out)) { [Console]::Out.WriteLine($out) }
$err = [string]$env:MCM_LOCAL_STDERR
if (-not [string]::IsNullOrEmpty($err)) { [Console]::Error.WriteLine($err) }
$code = 0
if (-not [string]::IsNullOrEmpty($env:MCM_LOCAL_EXIT)) { $code = [int]$env:MCM_LOCAL_EXIT }
exit $code
'@

# Envoltura minima para separar de forma explicita la ubicacion de PowerShell
# del directorio de trabajo del proceso: Set-Location cambia solo la primera.
# Si el motor resolviera la ruta relativa con el cwd del proceso fallaria aunque
# la ruta sea correcta para la persona que la escribio.
$script:RelativeWrapperTemplate = @'
param([string]$ManagerPath, [string]$Directory, [string]$RelativeZip)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $Directory
[Console]::Out.WriteLine('PSLOC=' + (Get-Location).ProviderPath)
[Console]::Out.WriteLine('CWDLOC=' + [Environment]::CurrentDirectory)
& $ManagerPath install -LocalZip $RelativeZip
$code = $LASTEXITCODE
if ($null -eq $code) { exit 9 }
exit [int]$code
'@

function New-FixtureZipArchive {
    param([string]$SourceRoot, [string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $sourceFull = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $archive = New-Object -TypeName 'System.IO.Compression.ZipArchive' -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $sourceFull -Recurse -File | Sort-Object -Property FullName)) {
                $relative = $file.FullName.Substring($sourceFull.Length + 1).Replace('\', '/')
                $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                try {
                    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                    $entryStream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Add-FixtureZipEntry {
    param([string]$ZipPath, [string]$Name, [string]$Content)
    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
    try {
        $archive = New-Object -TypeName 'System.IO.Compression.ZipArchive' -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Update, $true)
        try {
            $entry = $archive.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
                $entryStream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $entryStream.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function New-LocalZipFixture {
    param(
        [string]$RootPath,
        [string]$BundleVersion = '2.0.0',
        [string]$ManifestVersion = '2.0.0',
        [switch]$WithoutSidecar,
        [string]$ChecksumOverride = '',
        [switch]$BreakInventory,
        [switch]$WithoutManifestVersion,
        [string[]]$ExtraEntries = @(),
        [string]$SidecarName = 'MensorCAD-Windows.zip'
    )
    $packageRoot = Join-Path -Path $RootPath -ChildPath ('paquete-fuente-' + [guid]::NewGuid().ToString('N'))
    $bundleRoot = Join-Path -Path $packageRoot -ChildPath 'MensorCAD.bundle'
    $null = [System.IO.Directory]::CreateDirectory((Join-Path -Path $bundleRoot -ChildPath 'Contents\Lisp'))
    $null = [System.IO.Directory]::CreateDirectory((Join-Path -Path $bundleRoot -ChildPath 'Contents\UI'))
    $xml = '<?xml version="1.0" encoding="utf-8"?>' + "`n"
    if ($WithoutManifestVersion) {
        $xml += '<ApplicationPackage />' + "`n"
    }
    else {
        $xml += '<ApplicationPackage AppVersion="' + $BundleVersion + '" Version="' + $ManifestVersion + '" />' + "`n"
    }
    Write-Utf8File -Path (Join-Path -Path $bundleRoot -ChildPath 'PackageContents.xml') -Content $xml
    Write-Utf8File -Path (Join-Path -Path $bundleRoot -ChildPath 'Contents\Lisp\MC-TEST.lsp') -Content ('; fixture ' + $BundleVersion + "`n")
    Write-Utf8File -Path (Join-Path -Path $bundleRoot -ChildPath 'Contents\UI\MensorCAD.cuix') -Content ('CUIX-' + $BundleVersion)
    $lines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $bundleRoot -Recurse -File | Sort-Object -Property FullName)) {
        $relative = $file.FullName.Substring($bundleRoot.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += ($hash + '  ' + $relative)
    }
    if ($BreakInventory -and $lines.Count -gt 0) {
        $lines[0] = (('0' * 64) + '  ' + $lines[0].Substring(66))
    }
    Write-Utf8File -Path (Join-Path -Path $packageRoot -ChildPath 'bundle.sha256') -Content (($lines -join "`n") + "`n")
    Write-Utf8File -Path (Join-Path -Path $packageRoot -ChildPath 'Install-MensorCAD.ps1') -Content $script:LocalChildTemplate
    Write-Utf8File -Path (Join-Path -Path $packageRoot -ChildPath 'Instalar.bat') -Content "@echo off`r`necho fixture`r`n"
    Write-Utf8File -Path (Join-Path -Path $packageRoot -ChildPath 'LICENSE') -Content 'LICENCIA DE PRUEBA'
    # Carpeta con espacios a proposito: el paquete local debe aceptar rutas con
    # espacios sin reinterpretar la linea de comandos.
    $zipDir = Join-Path -Path $RootPath -ChildPath 'paquete local'
    $null = [System.IO.Directory]::CreateDirectory($zipDir)
    $zipPath = Join-Path -Path $zipDir -ChildPath 'MensorCAD-Windows.zip'
    New-FixtureZipArchive -SourceRoot $packageRoot -ZipPath $zipPath
    foreach ($extraEntry in @($ExtraEntries)) {
        if ([string]::IsNullOrWhiteSpace($extraEntry)) { continue }
        Add-FixtureZipEntry -ZipPath $zipPath -Name $extraEntry -Content 'entrada agregada por la prueba'
    }
    $sidecarPath = $zipPath + '.sha256'
    if (-not $WithoutSidecar) {
        $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($ChecksumOverride)) { $hash = $ChecksumOverride }
        Write-Utf8File -Path $sidecarPath -Content ($hash + '  ' + $SidecarName + "`n")
    }
    return [pscustomobject]@{
        ZipPath = $zipPath
        SidecarPath = $sidecarPath
        PackageRoot = $packageRoot
    }
}

function New-LocalZipCase {
    param(
        [string]$ManagerVersion = '0.1.0',
        [string]$PackageVersion = '2.0.0',
        [string]$InstalledVersion = '',
        [string]$ManifestVersion = '2.0.0',
        [switch]$WithoutSidecar,
        [string]$ChecksumOverride = '',
        [switch]$BreakInventory,
        [switch]$WithoutManifestVersion,
        [string[]]$ExtraEntries = @(),
        [string]$SidecarName = 'MensorCAD-Windows.zip',
        [switch]$WithProtectedEngine,
        [switch]$WithLauncher
    )
    $case = New-ManagerCase -Version $ManagerVersion -WithLauncher:$WithLauncher
    $engineSource = [System.IO.File]::ReadAllText((Join-Path -Path $script:RepositoryRoot -ChildPath 'Install-MensorCAD.ps1'))
    $guardIndex = $engineSource.IndexOf('if ($script:MensorCadDotSourced) {')
    if ($guardIndex -lt 0) { throw 'ASSERT: falta la guarda de dot-source del motor real' }
    $hybridSource = $engineSource.Substring(0, $guardIndex) + $script:HybridEngineOverrides + $engineSource.Substring($guardIndex)
    Write-Utf8File -Path (Join-Path -Path $case.ManagerDir -ChildPath 'Install-MensorCAD.ps1') -Content $hybridSource -Bom
    $installRoot = Join-Path -Path $case.Root -ChildPath 'ProgramFiles'
    $null = [System.IO.Directory]::CreateDirectory($installRoot)
    $destination = Join-Path -Path $installRoot -ChildPath 'MensorCAD.bundle'
    $ownership = 'absent'
    if (-not [string]::IsNullOrWhiteSpace($InstalledVersion)) {
        New-BundleFixture -BundlePath $destination -AppVersion $InstalledVersion -ManifestVersion $InstalledVersion -WithProtectedEngine:$WithProtectedEngine
        $ownership = 'owned'
    }
    $fixture = New-LocalZipFixture -RootPath $case.Root -BundleVersion $PackageVersion -ManifestVersion $ManifestVersion -WithoutSidecar:$WithoutSidecar -ChecksumOverride $ChecksumOverride -BreakInventory:$BreakInventory -WithoutManifestVersion:$WithoutManifestVersion -ExtraEntries $ExtraEntries -SidecarName $SidecarName
    $localLog = Join-Path -Path $case.Root -ChildPath 'local-child.log'
    Set-ManagerEnvironment -Case $case -Values @{
        'MCM_DEST' = $destination
        'MCM_PF' = $installRoot
        'MCM_OWNERSHIP' = $ownership
        'MCM_LOCAL_EVIDENCE' = $localLog
        'MCM_LOCAL_EXIT' = '0'
    }
    return [pscustomobject]@{
        Case = $case
        ZipPath = $fixture.ZipPath
        SidecarPath = $fixture.SidecarPath
        Destination = $destination
        LocalChildLog = $localLog
        ManagerPath = $case.ManagerPath
        LauncherPath = $case.LauncherPath
        EvidencePath = $case.EvidencePath
        ManagerDir = $case.ManagerDir
    }
}

function Get-LocalChildLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Path)
}

function Get-LocalWorkspaceLeftovers {
    $root = [string]$env:TEMP
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory -Filter 'mensorcad-local-*' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.FullName })
}

function Assert-NoLocalEvidence {
    param([pscustomobject]$CaseFixture, [string]$Message)
    Assert-True (-not (Test-EvidenceContains -Path $CaseFixture.EvidencePath -Fragment 'network|')) ($Message + ': sin red')
    Assert-True (-not (Test-EvidenceContains -Path $CaseFixture.EvidencePath -Fragment 'resolve|')) ($Message + ': sin resolver release')
    Assert-Equal 0 (@(Get-LocalChildLog -Path $CaseFixture.LocalChildLog)).Count ($Message + ': el instalador incluido no debe ejecutarse')
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count ($Message + ': la carpeta temporal propia debe limpiarse')
}

Test-Case 'install -LocalZip valida el paquete propio y ejecuta el instalador incluido' {
    $fixture = New-LocalZipCase -PackageVersion '2.0.0'
    Set-ManagerEnvironment -Case $fixture.Case -Values @{
        'MCM_DEST' = $fixture.Destination
        'MCM_PF' = (Split-Path -Parent $fixture.Destination)
        'MCM_OWNERSHIP' = 'absent'
        'MCM_LOCAL_EVIDENCE' = $fixture.LocalChildLog
        'MCM_LOCAL_EXIT' = '0'
        'MCM_LOCAL_STDOUT' = 'LOCAL-CHILD-OUT'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'LOCAL-CHILD-OUT' 'stdout del instalador incluido'
    Assert-True ((Get-LocalChildLog -Path $fixture.LocalChildLog) -contains 'local-child|ran|version=2.0.0') 'el hijo debe ejecutarse desde el paquete extraido'
    Assert-True (-not (Test-EvidenceContains -Path $fixture.EvidencePath -Fragment 'network|')) 'sin red'
    Assert-True (-not (Test-EvidenceContains -Path $fixture.EvidencePath -Fragment 'resolve|')) 'sin release remota'
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count 'la carpeta temporal propia debe limpiarse'
}

Test-Case 'el alias -i acepta -LocalZip y propaga el codigo del instalador incluido' {
    $fixture = New-LocalZipCase -PackageVersion '4.5.6'
    Set-ManagerEnvironment -Case $fixture.Case -Values @{
        'MCM_DEST' = $fixture.Destination
        'MCM_PF' = (Split-Path -Parent $fixture.Destination)
        'MCM_OWNERSHIP' = 'absent'
        'MCM_LOCAL_EVIDENCE' = $fixture.LocalChildLog
        'MCM_LOCAL_EXIT' = '7'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('-i', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 7 $result.ExitCode 'el codigo del instalador incluido se propaga exacto'
    Assert-True ((Get-LocalChildLog -Path $fixture.LocalChildLog) -contains 'local-child|ran|version=4.5.6') 'el alias debe instalar el paquete local'
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count 'sin restos temporales'
}

Test-Case 'install -LocalZip no baja de version un complemento existente' {
    $fixture = New-LocalZipCase -PackageVersion '1.0.0' -InstalledVersion '3.0.0'
    $before = Get-TreeSnapshot -Path $fixture.Destination
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'No se baja de' 'debe rechazar el downgrade local'
    Assert-Equal $before (Get-TreeSnapshot -Path $fixture.Destination) 'sin cambios en el complemento'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'downgrade local'
}

Test-Case 'install -LocalZip con la version del manifiesto no reinstala' {
    $fixture = New-LocalZipCase -PackageVersion '1.2.3' -InstalledVersion '1.2.3'
    $before = Get-TreeSnapshot -Path $fixture.Destination
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-True ((Get-StdOutLines -Text $result.StdOut) -contains 'Ya estás actualizado') 'mensaje exacto'
    Assert-Equal $before (Get-TreeSnapshot -Path $fixture.Destination) 'sin cambios'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'misma version local'
}

Test-Case 'install -LocalZip rechaza una comparacion ambigua sin ejecutar el paquete' {
    $fixture = New-LocalZipCase -PackageVersion '1.2.3-beta' -InstalledVersion '1.0.0'
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'No se pudo comparar' 'debe rechazar la ambiguedad'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'ambiguedad local'
}

Test-Case 'update -LocalZip con version nueva delega y conserva salida y codigo' {
    $fixture = New-LocalZipCase -PackageVersion '2.0.0' -InstalledVersion '1.0.0'
    Set-ManagerEnvironment -Case $fixture.Case -Values @{
        'MCM_DEST' = $fixture.Destination
        'MCM_PF' = (Split-Path -Parent $fixture.Destination)
        'MCM_OWNERSHIP' = 'owned'
        'MCM_LOCAL_EVIDENCE' = $fixture.LocalChildLog
        'MCM_LOCAL_EXIT' = '5'
        'MCM_LOCAL_STDOUT' = 'LOCAL-UPDATE-OUT'
        'MCM_LOCAL_STDERR' = 'LOCAL-UPDATE-ERR'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('update', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 5 $result.ExitCode 'el codigo del instalador incluido se propaga exacto'
    Assert-Contains $result.StdOut 'LOCAL-UPDATE-OUT' 'stdout del instalador incluido'
    Assert-Contains $result.StdErr 'LOCAL-UPDATE-ERR' 'stderr del instalador incluido'
    Assert-True ((Get-LocalChildLog -Path $fixture.LocalChildLog) -contains 'local-child|ran|version=2.0.0') 'el hijo se ejecuta una vez'
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count 'sin restos temporales'
}

Test-Case 'update -LocalZip sin complemento falla antes de leer el paquete' {
    $fixture = New-LocalZipCase
    $missingZip = Join-Path -Path $fixture.Case.Root -ChildPath 'no-existe\MensorCAD-Windows.zip'
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('update', '-LocalZip', $missingZip)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Empty $result.StdOut 'stdout'
    Assert-Contains $result.StdErr 'mensorcad install' 'debe sugerir install'
    Assert-NotContains $result.StdErr 'No se encontró el paquete local' 'no debe llegar a leer el ZIP'
    Assert-True (-not (Test-EvidenceContains -Path $fixture.EvidencePath -Fragment 'network|')) 'sin red'
    Assert-Equal 0 (@(Get-LocalChildLog -Path $fixture.LocalChildLog)).Count 'sin ejecutar el instalador'
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count 'sin carpetas temporales'
}

Test-Case 'install -LocalZip con SHA-256 incorrecto no ejecuta el instalador' {
    $fixture = New-LocalZipCase -ChecksumOverride ('0' * 64)
    $before = Get-TreeSnapshot -Path $fixture.Destination
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'SHA-256' 'debe rechazar el hash'
    Assert-Equal $before (Get-TreeSnapshot -Path $fixture.Destination) 'sin escrituras en el destino'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'hash incorrecto'
}

Test-Case 'install -LocalZip rechaza un paquete con entradas fuera del paquete distribuido' {
    $fixture = New-LocalZipCase -ExtraEntries @('payload-ajeno.txt')
    $before = Get-TreeSnapshot -Path $fixture.Destination
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'fuera del paquete distribuido' 'debe rechazar la entrada ajena'
    Assert-Equal $before (Get-TreeSnapshot -Path $fixture.Destination) 'sin escrituras en el destino'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'entrada ajena'
}

Test-Case 'install -LocalZip rechaza un sidecar que nombra otro archivo' {
    $fixture = New-LocalZipCase -SidecarName 'otro-paquete.zip'
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr '.sha256 corresponde a' 'debe atar el sidecar al ZIP esperado'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'sidecar de otro archivo'
}

Test-Case 'install -LocalZip rechaza un manifiesto sin version utilizable' {
    $fixture = New-LocalZipCase -WithoutManifestVersion
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'no declara una version utilizable' 'no debe inventar la version'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'version ausente en el paquete local'
}

Test-Case 'install -LocalZip con version nueva instala una sola vez' {
    $fixture = New-LocalZipCase -PackageVersion '3.1.0' -InstalledVersion '3.0.0'
    Set-ManagerEnvironment -Case $fixture.Case -Values @{
        'MCM_DEST' = $fixture.Destination
        'MCM_PF' = (Split-Path -Parent $fixture.Destination)
        'MCM_OWNERSHIP' = 'owned'
        'MCM_LOCAL_EVIDENCE' = $fixture.LocalChildLog
        'MCM_LOCAL_EXIT' = '0'
    }
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Equal 1 (@(Get-LocalChildLog -Path $fixture.LocalChildLog)).Count 'el instalador incluido se ejecuta una sola vez'
    Assert-True ((Get-LocalChildLog -Path $fixture.LocalChildLog) -contains 'local-child|ran|version=3.1.0') 'version del paquete ejecutado'
    Assert-True (-not (Test-EvidenceContains -Path $fixture.EvidencePath -Fragment 'network|')) 'sin red'
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count 'sin restos temporales'
}

Test-Case 'install -LocalZip con inventario alterado no ejecuta el instalador' {
    $fixture = New-LocalZipCase -BreakInventory
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'bundle.sha256' 'debe rechazar el inventario'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'inventario alterado'
}

Test-Case 'install -LocalZip exige el .sha256 junto al ZIP' {
    $fixture = New-LocalZipCase -WithoutSidecar
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr '.sha256' 'debe exigir el archivo de verificacion'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'sidecar ausente'
}

Test-Case 'install rechaza -LocalZip duplicado sin cargar el motor' {
    $fixture = New-LocalZipCase
    $before = Get-TreeSnapshot -Path $fixture.ManagerDir
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath, '-LocalZip', $fixture.ZipPath)
    Assert-Equal 2 $result.ExitCode 'codigo de uso'
    Assert-Empty $result.StdOut 'stdout'
    Assert-Contains $result.StdErr 'no se puede repetir' 'debe rechazar la repeticion'
    Assert-True (-not (Test-Path -LiteralPath $fixture.EvidencePath)) 'el motor no debe cargarse'
    Assert-Equal $before (Get-TreeSnapshot -Path $fixture.ManagerDir) 'sin escrituras'
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count 'sin carpetas temporales'
}

Test-Case 'install rechaza -LocalZip sin ruta' {
    $fixture = New-LocalZipCase
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip')
    Assert-Equal 2 $result.ExitCode 'codigo de uso'
    Assert-Empty $result.StdOut 'stdout'
    Assert-Contains $result.StdErr 'requiere una ruta' 'debe pedir la ruta'
    Assert-True (-not (Test-Path -LiteralPath $fixture.EvidencePath)) 'el motor no debe cargarse'
}

Test-Case 'install rechaza un argumento extra junto a -LocalZip' {
    $fixture = New-LocalZipCase
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', $fixture.ZipPath, 'extra')
    Assert-Equal 2 $result.ExitCode 'codigo de uso'
    Assert-Contains $result.StdErr 'Argumentos adicionales' 'mensaje exacto de argumentos'
    Assert-True (-not (Test-Path -LiteralPath $fixture.EvidencePath)) 'el motor no debe cargarse'
}

Test-Case 'los comandos hermanos rechazan -LocalZip antes de cargar el motor' {
    foreach ($command in @('status', 'uninstall', '--help', '--version')) {
        $fixture = New-LocalZipCase -WithProtectedEngine -InstalledVersion '1.0.0'
        $beforeManager = Get-TreeSnapshot -Path $fixture.ManagerDir
        $beforeBundle = Get-TreeSnapshot -Path $fixture.Destination
        $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @($command, '-LocalZip', $fixture.ZipPath)
        Assert-Equal 2 $result.ExitCode ('codigo de uso para ' + $command)
        Assert-Empty $result.StdOut ('stdout vacio para ' + $command)
        Assert-Contains $result.StdErr 'Argumentos adicionales' ('rechazo de argumentos para ' + $command)
        Assert-Contains $result.StdErr 'No se modific' ('debe aclarar que no hubo cambios para ' + $command)
        Assert-True (-not (Test-Path -LiteralPath $fixture.EvidencePath)) ('el motor no debe cargarse para ' + $command)
        Assert-Equal $beforeManager (Get-TreeSnapshot -Path $fixture.ManagerDir) ('sin escrituras junto al gestor para ' + $command)
        Assert-Equal $beforeBundle (Get-TreeSnapshot -Path $fixture.Destination) ('sin escrituras en el complemento para ' + $command)
    }
    $orphan = New-LocalZipCase
    $result = Invoke-ManagerPowerShell -ManagerScript $orphan.ManagerPath -Arguments @('-LocalZip', $orphan.ZipPath)
    Assert-Equal 2 $result.ExitCode 'la opcion sola no es un comando'
    Assert-Contains $result.StdErr 'no reconocida' 'debe rechazar la opcion sin comando'
}

Test-Case 'el motor sin soporte local falla limpio y no toca nada' {
    $case = New-ManagerCase -Version '0.1.0' -WithEngine
    Set-ManagerEnvironment -Case $case -Values @{ 'MCM_DEST' = (Join-Path $case.Root 'ausente'); 'MCM_OWNERSHIP' = 'absent' }
    $before = Get-TreeSnapshot -Path $case.ManagerDir
    $result = Invoke-ManagerPowerShell -ManagerScript $case.ManagerPath -Arguments @('install', '-LocalZip', (Join-Path $case.Root 'paquete.zip'))
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Empty $result.StdOut 'stdout'
    Assert-Contains $result.StdErr 'no admite -LocalZip' 'debe explicar la falta de soporte local'
    Assert-Contains $result.StdErr 'No se modific' 'debe aclarar que no hubo cambios'
    Assert-Equal $before (Get-TreeSnapshot -Path $case.ManagerDir) 'sin escrituras'
}

Test-Case 'sin -LocalZip la ruta remota sigue usando la red y no el paquete local' {
    $fixture = New-LocalZipCase
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdErr 'La red no esta permitida en esta prueba' 'debe intentar la ruta remota'
    Assert-True (Test-EvidenceContains -Path $fixture.EvidencePath -Fragment 'network|') 'la ruta remota debe llegar a la red'
    Assert-Equal 0 (@(Get-LocalChildLog -Path $fixture.LocalChildLog)).Count 'no debe ejecutar el instalador local'
}

Test-Case 'el lanzador CMD reenvia -LocalZip con una ruta que tiene espacios' {
    $fixture = New-LocalZipCase -PackageVersion '6.0.0' -WithLauncher
    Set-ManagerEnvironment -Case $fixture.Case -Values @{
        'MCM_DEST' = $fixture.Destination
        'MCM_PF' = (Split-Path -Parent $fixture.Destination)
        'MCM_OWNERSHIP' = 'absent'
        'MCM_LOCAL_EVIDENCE' = $fixture.LocalChildLog
        'MCM_LOCAL_EXIT' = '3'
        'MCM_LOCAL_STDOUT' = 'CMD-LOCAL-OUT'
    }
    $result = Invoke-Launcher -Launcher $fixture.LauncherPath -Arguments @('install', '-LocalZip', $fixture.ZipPath)
    Assert-Equal 3 $result.ExitCode 'cmd debe devolver el codigo del instalador incluido'
    Assert-Contains $result.StdOut 'CMD-LOCAL-OUT' 'salida del instalador incluido por CMD'
    Assert-True ((Get-LocalChildLog -Path $fixture.LocalChildLog) -contains 'local-child|ran|version=6.0.0') 'la ruta con espacios debe llegar intacta al motor'
    Assert-True (-not (Test-EvidenceContains -Path $fixture.EvidencePath -Fragment 'network|')) 'sin red'
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count 'sin restos temporales'
}

Test-Case 'install -LocalZip resuelve la ruta relativa contra la ubicacion de PowerShell' {
    $fixture = New-LocalZipCase -PackageVersion '5.0.0'
    Set-ManagerEnvironment -Case $fixture.Case -Values @{
        'MCM_DEST' = $fixture.Destination
        'MCM_PF' = (Split-Path -Parent $fixture.Destination)
        'MCM_OWNERSHIP' = 'absent'
        'MCM_LOCAL_EVIDENCE' = $fixture.LocalChildLog
        'MCM_LOCAL_EXIT' = '0'
        'MCM_LOCAL_STDOUT' = 'REL-LOCAL-OUT'
    }
    $wrapperPath = Join-Path -Path $fixture.Case.Root -ChildPath 'relativo.ps1'
    Write-Utf8File -Path $wrapperPath -Content $script:RelativeWrapperTemplate -Bom
    $zipDirectory = Split-Path -Parent $fixture.ZipPath
    $relativeZip = '.\' + (Split-Path -Leaf $fixture.ZipPath)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-QuotedArgument -Value $wrapperPath))) {
        $parts.Add($part)
    }
    foreach ($argument in @($fixture.ManagerPath, $zipDirectory, $relativeZip)) {
        $parts.Add((ConvertTo-QuotedArgument -Value ([string]$argument)))
    }
    # El proceso arranca en otra carpeta: solo la ubicacion de PowerShell apunta
    # al paquete, igual que cuando alguien hace Set-Location y escribe una ruta
    # relativa con espacios.
    $result = Start-CapturedProcess -FileName $script:PowerShellPath -ArgumentString ($parts -join ' ') -WorkingDirectory $env:SystemRoot
    Assert-Equal 0 $result.ExitCode 'codigo de salida'
    Assert-Contains $result.StdOut 'REL-LOCAL-OUT' 'salida del instalador incluido'
    Assert-Contains $result.StdOut ('PSLOC=' + $zipDirectory) 'la ubicacion de PowerShell debe apuntar al paquete'
    Assert-NotContains $result.StdOut ('CWDLOC=' + $zipDirectory) 'el cwd del proceso debe ser otro directorio'
    Assert-True ((Get-LocalChildLog -Path $fixture.LocalChildLog) -contains 'local-child|ran|version=5.0.0') 'la ruta relativa con espacios debe llegar intacta al motor'
    Assert-True (-not (Test-EvidenceContains -Path $fixture.EvidencePath -Fragment 'network|')) 'sin red'
    Assert-Equal 0 (@(Get-LocalWorkspaceLeftovers)).Count 'sin restos temporales'
}

Test-Case 'install -LocalZip rechaza una ruta que no es del sistema de archivos' {
    $fixture = New-LocalZipCase
    $result = Invoke-ManagerPowerShell -ManagerScript $fixture.ManagerPath -Arguments @('install', '-LocalZip', 'HKLM:\Software\MensorCAD-Windows.zip')
    Assert-Equal 1 $result.ExitCode 'codigo de salida'
    Assert-Empty $result.StdOut 'stdout'
    Assert-Contains $result.StdErr 'ruta de archivos' 'debe rechazar rutas de otros proveedores'
    Assert-Contains $result.StdErr 'No se modific' 'debe aclarar que no hubo cambios'
    Assert-NoLocalEvidence -CaseFixture $fixture -Message 'ruta de otro proveedor'
}

# ---------------------------------------------------------------------------
# Resultado
# ---------------------------------------------------------------------------

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host ('FALLARON ' + $script:Failed + ' de ' + ($script:Passed + $script:Failed) + ' pruebas del gestor.') -ForegroundColor Red
    foreach ($message in $script:FailureMessages) {
        Write-Host (' - ' + $message) -ForegroundColor Red
    }
    Write-Host ('Scratch conservado para diagnostico: ' + $script:TestRoot) -ForegroundColor Yellow
    exit 1
}

Write-Host ('OK: ' + $script:Passed + ' pruebas funcionales del gestor.') -ForegroundColor Green
try {
    [System.IO.Directory]::Delete($script:TestRoot, $true)
}
catch {
    Write-Host ('Aviso: no se pudo limpiar el scratch ' + $script:TestRoot + ': ' + $_.Exception.Message) -ForegroundColor Yellow
}
exit 0
