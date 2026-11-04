#requires -Version 5.1
<#
    Pruebas funcionales de la entrada remota de MensorCAD.

    Solo se ejecutan en Windows con Windows PowerShell 5.1. Toda la red y el
    proceso hijo estan simulados con costuras locales: estas pruebas nunca
    descargan de GitHub, nunca escriben en Program Files, nunca abren AutoCAD y
    nunca piden UAC real.

    Ejecucion:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-RemoteInstaller.ps1
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'SKIP: estas pruebas requieren Windows PowerShell 5.1.' -ForegroundColor Yellow
    exit 2
}

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:CaseSkipped = $false
$script:FailureMessages = @()
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:InstallerPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'Install-MensorCAD.ps1'
$script:BatPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'Instalar.bat'
# Prefijos cortos dejan espacio para la ruta transaccional del instalador bajo
# MAX_PATH. Se conservan los GUID completos para aislar cada suite y cada caso.
$script:TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('MCRT-' + [guid]::NewGuid().ToString('N'))

if (-not (Test-Path -LiteralPath $script:InstallerPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro el instalador en '$script:InstallerPath'." -ForegroundColor Red
    exit 1
}

# Carga el instalador sin ejecutar su flujo principal (guarda de dot-source).
. $script:InstallerPath

$null = New-Item -ItemType Directory -Path $script:TestRoot -Force

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

function Skip-Case {
    param([string]$Reason)
    $script:CaseSkipped = $true
    Write-Host ('SKIP: ' + $Reason) -ForegroundColor Yellow
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:CaseSkipped = $false
    try {
        & $Body
        if ($script:CaseSkipped) {
            $script:Skipped++
        }
        else {
            $script:Passed++
            Write-Host ('PASS: ' + $Name) -ForegroundColor Green
        }
    }
    catch {
        $script:Failed++
        $message = $_.Exception.Message
        $script:FailureMessages += ($Name + ' -> ' + $message)
        Write-Host ('FAIL: ' + $Name) -ForegroundColor Red
        Write-Host ('      ' + $message) -ForegroundColor Red
    }
}

function New-TestCaseRoot {
    $path = Join-Path -Path $script:TestRoot -ChildPath ('c-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

function Remove-TestCaseRoot {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-FixtureFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function New-FixtureManifest {
    param([string]$SourceRoot)
    $bundleRoot = Join-Path -Path $SourceRoot -ChildPath 'MensorCAD.bundle'
    $bundleFull = [System.IO.Path]::GetFullPath($bundleRoot)
    $lines = @()
    $files = Get-ChildItem -LiteralPath $bundleFull -Recurse -File | Sort-Object -Property FullName
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($bundleFull.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += ($hash + '  ' + $relative)
    }
    $manifestPath = Join-Path -Path $SourceRoot -ChildPath 'bundle.sha256'
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($manifestPath, (($lines -join "`r`n") + "`r`n"), $encoding)
}

function New-FixturePackageSource {
    param([string]$RootPath, [string]$Version = 'v1')
    $sourceRoot = Join-Path -Path $RootPath -ChildPath 'package'
    $bundleRoot = Join-Path -Path $sourceRoot -ChildPath 'MensorCAD.bundle'
    $null = New-Item -ItemType Directory -Path $bundleRoot -Force

    Write-FixtureFile -Path (Join-Path $bundleRoot 'PackageContents.xml') -Content ('<ApplicationPackage Name="MensorCAD" Version="' + $Version + '" />')
    Write-FixtureFile -Path (Join-Path $bundleRoot 'Contents\Lisp\MC-AREA.lsp') -Content ('; MC-AREA fixture ' + $Version + "`r`n")
    Write-FixtureFile -Path (Join-Path $bundleRoot 'Contents\Lisp\MC-TABLE.lsp') -Content ('; MC-TABLE fixture ' + $Version + "`r`n")
    Write-FixtureFile -Path (Join-Path $bundleRoot 'Contents\UI\MensorCAD.cuix') -Content ('CUIX-FIXTURE-' + $Version)

    New-FixtureManifest -SourceRoot $sourceRoot

    Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $sourceRoot 'Install-MensorCAD.ps1') -Force
    Copy-Item -LiteralPath $script:BatPath -Destination (Join-Path $sourceRoot 'Instalar.bat') -Force
    Write-FixtureFile -Path (Join-Path $sourceRoot 'LICENSE') -Content 'LICENCIA DE PRUEBA'
    return $sourceRoot
}

function New-FixtureReleaseZip {
    param([string]$SourceRoot, [string]$ZipPath, [string[]]$ExcludeNames = @())
    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $sourceFull = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $files = Get-ChildItem -LiteralPath $sourceFull -Recurse -File | Sort-Object -Property FullName
    $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $archive = New-Object -TypeName 'System.IO.Compression.ZipArchive' -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($sourceFull.Length + 1).Replace('\', '/')
                if ($ExcludeNames -contains $relative) { continue }
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
    param([string]$ZipPath, [string]$Name, [string]$Content, [switch]$SymbolicLink)
    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
    try {
        $archive = New-Object -TypeName 'System.IO.Compression.ZipArchive' -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Update, $true)
        try {
            $entry = $archive.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
            if ($SymbolicLink) {
                $entry.ExternalAttributes = ([int]0xA1FF) -shl 16
            }
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

function Write-FixtureSidecar {
    param([string]$ZipPath, [string]$SidecarPath, [string]$Hash = '')
    if ([string]::IsNullOrWhiteSpace($Hash)) {
        $Hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Write-FixtureFile -Path $SidecarPath -Content ($Hash + '  MensorCAD-Windows.zip')
}

function New-FixtureRelease {
    param([string]$RootPath, [string]$Version = 'v1', [string[]]$ExcludeNames = @())
    $sourceRoot = New-FixturePackageSource -RootPath $RootPath -Version $Version
    $zipPath = Join-Path -Path $RootPath -ChildPath 'MensorCAD-Windows.zip'
    New-FixtureReleaseZip -SourceRoot $sourceRoot -ZipPath $zipPath -ExcludeNames $ExcludeNames
    $sidecarPath = Join-Path -Path $RootPath -ChildPath 'MensorCAD-Windows.zip.sha256'
    Write-FixtureSidecar -ZipPath $zipPath -SidecarPath $sidecarPath
    return [pscustomobject]@{
        SourceRoot = $sourceRoot
        ZipPath = $zipPath
        SidecarPath = $sidecarPath
    }
}

function Invoke-ChildInstaller {
    param([string]$ScriptPath, [string[]]$Arguments = @())
    $stdoutPath = Join-Path -Path $script:TestRoot -ChildPath ('stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrPath = Join-Path -Path $script:TestRoot -ChildPath ('stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    $argumentString = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    if ($Arguments.Count -gt 0) {
        $argumentString += ' ' + ($Arguments -join ' ')
    }
    $powerShellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        $powerShellPath = 'powershell.exe'
    }
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $argumentString -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $stdoutPath) { $stdout = [System.IO.File]::ReadAllText($stdoutPath) }
    if (Test-Path -LiteralPath $stderrPath) { $stderr = [System.IO.File]::ReadAllText($stderrPath) }
    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Copy-InstallerTo {
    param([string]$RootPath)
    $target = Join-Path -Path $RootPath -ChildPath 'Install-MensorCAD.ps1'
    Copy-Item -LiteralPath $script:InstallerPath -Destination $target -Force
    return $target
}

<#
    Costuras de prueba. Reemplazan red, proceso hijo, carpeta temporal y
    destino fijo para que ningun caso toque GitHub, Program Files ni UAC real.
#>
<#
    Sondas aisladas para la espera activa. Se generan como scripts temporales y
    se ejecutan en un proceso PowerShell separado, de modo que la animacion se
    mide contra un proceso hijo real y por su salida de consola observable.
#>
function New-WaitProbeScript {
    param([string]$RootPath)
    $probePath = Join-Path -Path $RootPath -ChildPath 'wait-probe.ps1'
    $installerLiteral = $script:InstallerPath.Replace("'", "''")
    $template = @'
param([int]$ChildMilliseconds = 600, [int]$IntervalMilliseconds = 100, [switch]$PlainMode)
$ErrorActionPreference = 'Stop'
. '__INSTALLER__'
$script:MensorCadPlainMode = [bool]$PlainMode
$transcript = Join-Path -Path (Split-Path -Parent $PSCommandPath) -ChildPath 'wait-probe.transcript.txt'
$powerShellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) { $powerShellPath = 'powershell.exe' }
$child = $null
$elapsed = 0
Start-Transcript -LiteralPath $transcript -Force | Out-Null
try {
    $child = Start-Process -FilePath $powerShellPath -ArgumentList @('-NoProfile', '-Command', ('Start-Sleep -Milliseconds ' + $ChildMilliseconds)) -NoNewWindow -PassThru
    $started = [DateTime]::UtcNow
    Wait-MensorCadRemoteChild -Process $child -Message 'mensaje-probe' -IntervalMilliseconds $IntervalMilliseconds
    $elapsed = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
}
finally {
    Stop-Transcript | Out-Null
}
Write-Output ('PROBE-FIN exited=' + $child.HasExited + ' elapsed=' + $elapsed)
'@
    $content = $template.Replace('__INSTALLER__', $installerLiteral)
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($probePath, $content, $encoding)
    return $probePath
}

function New-ChildProbeScript {
    param([string]$RootPath, [string]$ChildScriptPath)
    $probePath = Join-Path -Path $RootPath -ChildPath 'child-probe.ps1'
    $installerLiteral = $script:InstallerPath.Replace("'", "''")
    $childLiteral = $ChildScriptPath.Replace("'", "''")
    $template = @'
param([string]$Root)
$ErrorActionPreference = 'Stop'
. '__INSTALLER__'
$script:MensorCadPlainMode = $false
$script:ProbeProcess = $null
# Diagnostico crudo: se inicializa para StrictMode y se llena dentro de la
# espera, mientras el Process sigue vigente (el motor lo libera en su finally).
$script:ProbeRawExitCode = $null
$script:ProbeRawExitIsNull = $true
$script:ProbeRawExitError = ''
$frames = New-Object 'System.Collections.Generic.List[object]'
$originalWait = ${function:Wait-MensorCadRemoteChild}
function script:Wait-MensorCadRemoteChild {
    param($Process, [string]$Message, [int]$IntervalMilliseconds = 200)
    $script:ProbeProcess = $Process
    $null = & $originalWait -Process $Process -Message $Message -IntervalMilliseconds $IntervalMilliseconds
    # Captura del estado crudo justo cuando la espera activa termina y antes de
    # que Invoke-MensorCadRemoteChild libere el Process en su bloque finally.
    try {
        $script:ProbeRawExitCode = $Process.ExitCode
        $script:ProbeRawExitIsNull = ($null -eq $script:ProbeRawExitCode)
        $script:ProbeRawExitError = ''
    }
    catch {
        $script:ProbeRawExitIsNull = $true
        $script:ProbeRawExitError = $_.Exception.Message
    }
}
function script:Write-MensorCadActivity {
    param([string]$Message)
    $running = $false
    if ($null -ne $script:ProbeProcess) { $running = -not $script:ProbeProcess.HasExited }
    $frames.Add([pscustomobject]@{ Message = $Message; Running = $running })
}
$result = Invoke-MensorCadRemoteChild -ScriptPath '__CHILD__' -Arguments @('-Milliseconds', '700') -StdOutPath (Join-Path $Root 'child.stdout.log') -StdErrPath (Join-Path $Root 'child.stderr.log')
# El resumen usa los valores capturados durante la espera: el Process ya fue
# liberado por el motor y no se vuelve a desreferenciar.
$summary = [pscustomobject]@{
    ExitCode = [int]$result.ExitCode
    RawProcessExitCode = $script:ProbeRawExitCode
    ProcessExitCodeIsNull = [bool]$script:ProbeRawExitIsNull
    ProcessExitCodeError = [string]$script:ProbeRawExitError
    StdOut = [string]$result.StdOut
    StdErr = [string]$result.StdErr
    Frames = $frames.Count
    RunningFrames = @($frames | Where-Object { $_.Running }).Count
}
$summary | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Root 'child-probe.json') -Encoding UTF8
exit 0
'@
    $content = $template.Replace('__INSTALLER__', $installerLiteral).Replace('__CHILD__', $childLiteral)
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($probePath, $content, $encoding)
    return $probePath
}

function New-ChildStatusProbeScript {
    param([string]$RootPath)
    $probePath = Join-Path -Path $RootPath -ChildPath 'missing-status-probe.ps1'
    $installerLiteral = $script:InstallerPath.Replace("'", "''")
    # Costura estrecha: se reemplazan el lanzador y la espera para simular un
    # proceso cuyo estado crudo no esta disponible. No se toca produccion ni se
    # agrega un framework de procesos: solo se ejercita el camino de fallo seguro.
    $template = @'
param([string]$Root)
$ErrorActionPreference = 'Stop'
. '__INSTALLER__'
function script:Start-Process {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [switch]$NoNewWindow,
        [switch]$PassThru,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )
    $fake = [pscustomobject]@{ Id = 4242; Handle = [IntPtr]::Zero; ExitCode = $null }
    $null = $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    return $fake
}
function script:Wait-MensorCadRemoteChild {
    param($Process, [string]$Message = '', [int]$IntervalMilliseconds = 200)
    return
}
$summary = [pscustomobject]@{ Threw = $false; Message = ''; ExitCode = $null }
try {
    $result = Invoke-MensorCadRemoteChild -ScriptPath (Join-Path $Root 'Install-MensorCAD.ps1') -Arguments @('-NoAnimation') -StdOutPath (Join-Path $Root 'missing.stdout.log') -StdErrPath (Join-Path $Root 'missing.stderr.log')
    $summary.ExitCode = [int]$result.ExitCode
}
catch {
    $summary.Threw = $true
    $summary.Message = $_.Exception.Message
}
$summary | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Root 'missing-status.json') -Encoding UTF8
exit 0
'@
    $content = $template.Replace('__INSTALLER__', $installerLiteral)
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($probePath, $content, $encoding)
    return $probePath
}

function New-RemoteHttpError {
    # Error con Response/StatusCode como el de Invoke-WebRequest: ejercita la
    # deteccion real de estado HTTP sin tocar la red.
    param([int]$StatusCode, [string]$Message)
    $httpError = New-Object -TypeName 'System.Exception' -ArgumentList @($Message)
    $response = [pscustomobject]@{ StatusCode = $StatusCode }
    $null = $httpError | Add-Member -MemberType NoteProperty -Name Response -Value $response
    return $httpError
}

function Set-MensorCadTestSeams {
    param(
        [string]$TempRoot,
        [string]$ProgramFilesRoot,
        [string]$SourceRoot = '',
        [string]$ZipPath = '',
        [string]$SidecarPath = '',
        [string]$LatestTag = 'v9.9.9',
        [switch]$AllowApi,
        [switch]$FailApi,
        [switch]$FailDownload,
        [int]$ApiHttpStatus = 0,
        [int]$DownloadHttpStatus = 0,
        [int]$ChildExitCode = 0,
        [string]$ChildStdOut = 'salida simulada del instalador extraido',
        [string]$ChildStdErr = ''
    )
    $script:SeamCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:SeamChildCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:SeamErrors = New-Object 'System.Collections.Generic.List[string]'
    $script:SeamSuccessCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:SeamRelayedOut = ''
    $script:SeamRelayedErr = ''
    $script:SeamTempRoot = $TempRoot
    $script:SeamProgramFilesRoot = $ProgramFilesRoot
    $script:SeamLatestTag = $LatestTag
    $script:SeamApiAllowed = $AllowApi.IsPresent
    $script:SeamApiFails = $FailApi.IsPresent
    $script:SeamFailDownload = $FailDownload.IsPresent
    $script:SeamApiHttpStatus = $ApiHttpStatus
    $script:SeamDownloadHttpStatus = $DownloadHttpStatus
    $script:SeamZipPath = $ZipPath
    $script:SeamSidecarPath = $SidecarPath
    $script:SeamChildExitCode = $ChildExitCode
    $script:SeamChildStdOut = $ChildStdOut
    $script:SeamChildStdErr = $ChildStdErr
    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        $script:MensorCadScriptRoot = $SourceRoot
    }

    function script:Get-MensorCadRemoteTempRoot { return $script:SeamTempRoot }
    function script:Get-MensorCadProgramFilesRoot { return $script:SeamProgramFilesRoot }
    function script:Test-MensorCadAdministrator { return $true }
    function script:Test-MensorCadAutoCadRunning { return $false }
    function script:Test-MensorCad64BitOperatingSystem { return $true }
    function script:Test-MensorCad64BitProcess { return $true }
    function script:Write-MensorCadFailure {
        param([string]$Message)
        $script:SeamErrors.Add([string]$Message)
    }
    function script:Write-MensorCadSuccess {
        # El resumen de exito se registra en lugar de pintarse: la prueba mide
        # cuando el padre lo produce, no como se ve en una terminal real.
        param([string]$Message, [string]$Headline, [string]$Detail, [string]$NextAction, [string]$Metadata)
        $script:SeamSuccessCalls.Add([pscustomobject]@{
            Message = [string]$Message
            Headline = [string]$Headline
            Detail = [string]$Detail
            NextAction = [string]$NextAction
            Metadata = [string]$Metadata
        })
    }
    function script:Write-MensorCadRelayedOutput {
        param([string]$Text, [switch]$IsError)
        if ($IsError) { $script:SeamRelayedErr += [string]$Text }
        else { $script:SeamRelayedOut += [string]$Text }
    }
    function script:Get-MensorCadRemoteText {
        param([string]$Uri)
        $script:SeamCalls.Add([pscustomobject]@{ Kind = 'text'; Uri = $Uri })
        if ($script:SeamApiHttpStatus -gt 0) {
            throw (New-RemoteHttpError -StatusCode $script:SeamApiHttpStatus -Message ('respuesta HTTP ' + $script:SeamApiHttpStatus + ' simulada al consultar la API'))
        }
        if ($script:SeamApiFails) { throw 'fallo de red simulado al consultar la API' }
        if (-not $script:SeamApiAllowed) { throw ('llamada de red no simulada: ' + $Uri) }
        $assets = @(
            [pscustomobject]@{ name = 'MensorCAD-Windows.zip' },
            [pscustomobject]@{ name = 'MensorCAD-Windows.zip.sha256' }
        )
        return ([pscustomobject]@{ tag_name = $script:SeamLatestTag; assets = $assets } | ConvertTo-Json -Depth 4)
    }
    function script:Save-MensorCadRemoteFile {
        param([string]$Uri, [string]$DestinationPath)
        $script:SeamCalls.Add([pscustomobject]@{ Kind = 'file'; Uri = $Uri })
        if ($script:SeamDownloadHttpStatus -gt 0) {
            throw (New-RemoteHttpError -StatusCode $script:SeamDownloadHttpStatus -Message ('respuesta HTTP ' + $script:SeamDownloadHttpStatus + ' simulada al descargar el asset'))
        }
        if ($script:SeamFailDownload) { throw 'fallo de red simulado al descargar el paquete' }
        $name = [System.IO.Path]::GetFileName($Uri)
        $source = ''
        if ($name -eq 'MensorCAD-Windows.zip') { $source = $script:SeamZipPath }
        elseif ($name -eq 'MensorCAD-Windows.zip.sha256') { $source = $script:SeamSidecarPath }
        if ([string]::IsNullOrWhiteSpace($source)) { throw ('descarga no simulada: ' + $Uri) }
        [System.IO.File]::Copy($source, $DestinationPath, $true)
        return $DestinationPath
    }
    function script:Invoke-MensorCadRemoteChild {
        param([string]$ScriptPath, [string[]]$Arguments, [string]$StdOutPath, [string]$StdErrPath)
        $parent = Split-Path -Parent $ScriptPath
        $script:SeamChildCalls.Add([pscustomobject]@{
            ScriptPath = $ScriptPath
            Arguments = $Arguments
            InstallerPresent = (Test-Path -LiteralPath $ScriptPath -PathType Leaf)
            UninstallerPresent = (Test-Path -LiteralPath (Join-Path $parent 'Desinstalar.bat') -PathType Leaf)
            ManifestPresent = (Test-Path -LiteralPath (Join-Path $parent 'bundle.sha256') -PathType Leaf)
            BundlePresent = (Test-Path -LiteralPath (Join-Path $parent 'MensorCAD.bundle') -PathType Container)
        })
        if (-not [string]::IsNullOrEmpty($script:SeamChildStdOut)) {
            [System.IO.File]::WriteAllText($StdOutPath, $script:SeamChildStdOut)
        }
        if (-not [string]::IsNullOrEmpty($script:SeamChildStdErr)) {
            [System.IO.File]::WriteAllText($StdErrPath, $script:SeamChildStdErr)
        }
        return [pscustomobject]@{
            ExitCode = [int]$script:SeamChildExitCode
            StdOut = $script:SeamChildStdOut
            StdErr = $script:SeamChildStdErr
        }
    }
}

function New-RemoteCaseRoots {
    param([string]$RootPath)
    $programFiles = Join-Path -Path $RootPath -ChildPath 'pf'
    $tempRoot = Join-Path -Path $RootPath -ChildPath 'RemoteTemp'
    $null = New-Item -ItemType Directory -Path $programFiles -Force
    $null = New-Item -ItemType Directory -Path $tempRoot -Force
    return [pscustomobject]@{ ProgramFiles = $programFiles; TempRoot = $tempRoot }
}

function Assert-NoRemoteLeftovers {
    param([string]$TempRoot)
    $count = @(Get-ChildItem -LiteralPath $TempRoot -Force -ErrorAction SilentlyContinue).Count
    Assert-Equal 0 $count 'La carpeta temporal remota debe quedar limpia.'
}

function Get-SeamCalls {
    param([string]$Kind)
    $calls = @($script:SeamCalls | Where-Object { $_.Kind -eq $Kind })
    # `return @(...)` desenrolla la coleccion: con 0 coincidencias el llamador
    # recibe $null y con 1 recibe el objeto suelto, de modo que .Count falla
    # bajo Set-StrictMode 2.0. La coma devuelve el arreglo como un unico objeto
    # y conserva 0/1/2+ elementos para las comprobaciones de red y limpieza.
    return ,$calls
}

try {
    Test-Case 'La release mas reciente se resuelve una sola vez y fija el tag' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -LatestTag 'v9.9.9' -AllowApi -ChildExitCode 0

            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 0 $exit 'La entrada remota simulada debe salir con codigo 0.'

            $apiCalls = Get-SeamCalls -Kind 'text'
            Assert-Equal 1 $apiCalls.Count 'La API de releases debe consultarse una sola vez.'
            Assert-True ($apiCalls[0].Uri.EndsWith('/repos/RonGrasz/Mensor-CAD/releases/latest')) 'La API debe apuntar al repositorio fijo.'
            $fileCalls = Get-SeamCalls -Kind 'file'
            Assert-Equal 2 $fileCalls.Count 'Deben descargarse el ZIP y su sidecar.'
            Assert-True ($fileCalls[0].Uri -like '*/releases/download/v9.9.9/MensorCAD-Windows.zip') 'El ZIP debe usar el tag resuelto.'
            Assert-True ($fileCalls[1].Uri -like '*/releases/download/v9.9.9/MensorCAD-Windows.zip.sha256') 'El sidecar debe usar el mismo tag resuelto.'

            Assert-Equal 1 $script:SeamChildCalls.Count 'Debe invocarse una sola vez el instalador extraido.'
            $child = $script:SeamChildCalls[0]
            Assert-True $child.InstallerPresent 'El hijo debe recibir Install-MensorCAD.ps1 extraido.'
            Assert-True $child.ManifestPresent 'El hijo debe recibir bundle.sha256 extraido.'
            Assert-True $child.BundlePresent 'El hijo debe recibir MensorCAD.bundle extraido.'
            Assert-True ($child.ScriptPath.EndsWith('Install-MensorCAD.ps1')) 'El hijo debe ser el instalador extraido.'
            Assert-True (-not (@($child.Arguments) -contains '-FromRelease')) 'El hijo no debe recibir -FromRelease.'
            Assert-True (@($child.Arguments) -contains '-NoAnimation') 'El hijo debe conservar -NoAnimation.'
            Assert-Equal $script:SeamChildStdOut $script:SeamRelayedOut 'La salida del hijo debe reenviarse.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $roots.ProgramFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'La entrada remota no debe escribir el destino fijo.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El acceso Desinstalar.bat se admite sin exigirlo en paquetes anteriores' {
        foreach ($includeLauncher in @($false, $true)) {
            $root = New-TestCaseRoot
            try {
                $release = New-FixtureRelease -RootPath $root -Version 'v1'
                if ($includeLauncher) {
                    Add-FixtureZipEntry -ZipPath $release.ZipPath -Name 'Desinstalar.bat' -Content '@echo off'
                    Write-FixtureSidecar -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath
                }
                $roots = New-RemoteCaseRoots -RootPath $root
                Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath
                $exit = Invoke-MensorCadCli -FromRelease -Version 'v1.2.3' -NoAnimation 6>$null
                Assert-Equal 0 $exit 'La entrada remota debe aceptar el paquete con o sin el BAT opcional.'
                Assert-Equal 1 $script:SeamChildCalls.Count 'Debe ejecutar una sola vez el instalador extraido.'
                Assert-Equal $includeLauncher $script:SeamChildCalls[0].UninstallerPresent 'La extraccion debe conservar la presencia del BAT.'
                Assert-Equal 0 @(Get-ChildItem -LiteralPath $roots.ProgramFiles -Force -Recurse).Count 'La inspeccion remota no debe modificar ProgramFiles.'
                Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
            }
            finally {
                Remove-TestCaseRoot -Path $root
            }
        }
    }

    Test-Case 'Una version explicita se fija sin consultar la API' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v2'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath

            $exit = Invoke-MensorCadCli -FromRelease -Version 'v1.2.3' -NoAnimation 6>$null
            Assert-Equal 0 $exit 'Una version explicita valida debe salir con codigo 0.'
            Assert-Equal 0 (Get-SeamCalls -Kind 'text').Count 'La version explicita no debe consultar la API.'
            $fileCalls = Get-SeamCalls -Kind 'file'
            Assert-Equal 2 $fileCalls.Count 'Deben descargarse el ZIP y su sidecar.'
            foreach ($call in $fileCalls) {
                Assert-True ($call.Uri -like '*/releases/download/v1.2.3/*') 'Las descargas deben usar el tag indicado.'
            }
            Assert-Equal 1 $script:SeamChildCalls.Count 'El instalador extraido debe invocarse una vez.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Si la API falla el mensaje es claro y no se descarga nada' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi -FailApi

            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un fallo de la API debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'No se pudo consultar') 'El error debe explicar que fallo la consulta.'
            Assert-Equal 0 (Get-SeamCalls -Kind 'file').Count 'Un fallo de la API no debe descargar assets.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Un fallo de la API no debe invocar el instalador.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un SHA-256 incorrecto no extrae ni instala y limpia la temporada' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $badSidecar = Join-Path -Path $root -ChildPath 'bad.sha256'
            Write-FixtureSidecar -ZipPath $release.ZipPath -SidecarPath $badSidecar -Hash ('0' * 64)
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $badSidecar -AllowApi

            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un SHA-256 incorrecto debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'SHA-256') 'El error debe explicar el problema de integridad.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Un hash incorrecto no debe invocar el instalador.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $roots.ProgramFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'Un hash incorrecto no debe escribir el destino fijo.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un ZIP con salto de directorio se rechaza antes de extraer' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            Add-FixtureZipEntry -ZipPath $release.ZipPath -Name '../escape.txt' -Content 'fuera del paquete'
            Write-FixtureSidecar -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi

            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un salto de directorio en el ZIP debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'segmento|no permitida') 'El error debe identificar la entrada no permitida.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Un ZIP inseguro no debe invocar el instalador.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'escape.txt'))) 'No debe escribirse nada fuera de la temporada.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un ZIP con entradas duplicadas sin distinguir mayusculas se rechaza' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            Add-FixtureZipEntry -ZipPath $release.ZipPath -Name 'mensorcad.bundle/PackageContents.xml' -Content '<otro />'
            Write-FixtureSidecar -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi

            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un ZIP con duplicados debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'duplicad') 'El error debe indicar la entrada duplicada.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Un ZIP duplicado no debe invocar el instalador.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un ZIP con un enlace se rechaza antes de extraer' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1' -ExcludeNames @('LICENSE')
            Add-FixtureZipEntry -ZipPath $release.ZipPath -Name 'LICENSE' -Content 'destino-del-enlace' -SymbolicLink
            Write-FixtureSidecar -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi

            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un enlace dentro del ZIP debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'enlace') 'El error debe indicar el enlace rechazado.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Un enlace no debe invocar el instalador.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un ZIP con flujo alternativo o nombre reservado se rechaza' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            Add-FixtureZipEntry -ZipPath $release.ZipPath -Name 'MensorCAD.bundle/PackageContents.xml:ads' -Content 'flujo'
            Write-FixtureSidecar -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi
            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un flujo alternativo en el ZIP debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'flujo alternativo') 'El error debe indicar el flujo alternativo.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }

        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            Add-FixtureZipEntry -ZipPath $release.ZipPath -Name 'MensorCAD.bundle/Contents/Lisp/CON.lsp' -Content '; reservado'
            Write-FixtureSidecar -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi
            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un nombre reservado de Windows debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'reservado') 'El error debe indicar el nombre reservado.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un ZIP con archivos fuera del paquete distribuido se rechaza' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            Add-FixtureZipEntry -ZipPath $release.ZipPath -Name 'extra.txt' -Content 'no distribuido'
            Write-FixtureSidecar -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi
            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un archivo fuera del inventario congelado debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'fuera del paquete distribuido') 'El error debe indicar el archivo no distribuido.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Un ZIP fuera del contrato no debe invocar el instalador.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Argumentos invalidos fallan sin red ni escrituras' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi

            $exitCombo = Invoke-MensorCadCli -FromRelease -Uninstall -NoAnimation 6>$null
            Assert-Equal 1 $exitCombo '-FromRelease con -Uninstall debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'no se pueden combinar') 'El error debe explicar la combinacion invalida.'

            $exitVersionOnly = Invoke-MensorCadCli -Version 'v1.2.3' -NoAnimation 6>$null
            Assert-Equal 1 $exitVersionOnly '-Version sin -FromRelease debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'solo es valida junto con -FromRelease') 'El error debe exigir -FromRelease.'

            $exitBadTag = Invoke-MensorCadCli -FromRelease -Version 'v1/../../otra' -NoAnimation 6>$null
            Assert-Equal 1 $exitBadTag 'Una version con barras debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'no es valida') 'El error debe indicar que la version no es valida.'

            $exitEmptyVersion = Invoke-MensorCadCli -FromRelease -Version '' -NoAnimation 6>$null
            Assert-Equal 1 $exitEmptyVersion '-Version vacio debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'requiere un valor') 'El error debe indicar que falta el valor.'

            Assert-Equal 0 $script:SeamCalls.Count 'Los argumentos invalidos no deben tocar la red.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Los argumentos invalidos no deben invocar el instalador.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $roots.ProgramFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'Los argumentos invalidos no deben escribir el destino.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Las opciones locales siguen intactas sin -FromRelease' {
        $root = New-TestCaseRoot
        try {
            $scriptCopy = Copy-InstallerTo -RootPath $root
            $help = Invoke-ChildInstaller -ScriptPath $scriptCopy -Arguments @('-Help')
            Assert-Equal 0 $help.ExitCode '-Help debe seguir saliendo con codigo 0.'
            Assert-True ($help.Stdout -match 'Uso:') '-Help debe seguir mostrando Uso:.'
            $plainHelp = Invoke-ChildInstaller -ScriptPath $scriptCopy -Arguments @('-NoAnimation', '-Help')
            Assert-Equal 0 $plainHelp.ExitCode '-NoAnimation -Help debe seguir saliendo con codigo 0.'
            $remoteHelp = Invoke-ChildInstaller -ScriptPath $scriptCopy -Arguments @('-FromRelease', '-Help')
            Assert-Equal 0 $remoteHelp.ExitCode '-FromRelease -Help debe salir con codigo 0.'
            Assert-True ($remoteHelp.Stdout -match '\-FromRelease') 'La ayuda debe documentar -FromRelease.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }

        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -SourceRoot $release.SourceRoot

            $uninstallExit = Invoke-MensorCadCli -Uninstall -NoAnimation 6>$null
            Assert-Equal 1 $uninstallExit 'Desinstalar sin instalacion debe seguir fallando con codigo 1.'
            Assert-True ((($script:SeamErrors -join ' ')) -match 'no esta instalado') 'El error debe seguir indicando que no esta instalado.'

            # Conserva la evidencia previa, pero muestra solo los errores nuevos
            # de esta instalacion, no el rechazo esperado de desinstalar antes.
            $installErrorOffset = $script:SeamErrors.Count
            $installExit = Invoke-MensorCadCli -NoAnimation 6>$null
            $installErrors = @($script:SeamErrors | Select-Object -Skip $installErrorOffset)
            $installDiagnostic = 'Sin mensaje de error capturado.'
            if ($installErrors.Count -gt 0) {
                $installDiagnostic = $installErrors -join ' | '
            }
            Assert-Equal 0 $installExit ('La instalacion local sin opciones debe seguir funcionando. Error del instalador: ' + $installDiagnostic)
            $destination = Join-Path -Path $roots.ProgramFiles -ChildPath 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json') -PathType Leaf) 'La instalacion local debe seguir creando la marca.'

            $removeExit = Invoke-MensorCadCli -Uninstall -NoAnimation 6>$null
            Assert-Equal 0 $removeExit 'La desinstalacion local debe seguir funcionando.'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'La desinstalacion local debe seguir borrando el bundle.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $roots.TempRoot -Force -ErrorAction SilentlyContinue).Count 'La rama local no debe usar la temporada remota.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El codigo de salida del hijo y el estado elevado distinto de cero no se ocultan' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi -ChildExitCode 7 -ChildStdOut 'linea-hijo-out' -ChildStdErr 'No se obtuvo elevacion mediante UAC. La instalacion no se realizo.'

            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 7 $exit 'La entrada remota debe propagar el codigo de salida del hijo inmediato.'
            Assert-True ($script:SeamRelayedOut -match 'linea-hijo-out') 'La salida estandar del hijo debe reenviarse.'
            Assert-True ($script:SeamRelayedErr -match 'UAC') 'El mensaje del hijo inmediato sobre UAC debe reenviarse.'
            Assert-Equal 1 $script:SeamChildCalls.Count 'El hijo debe invocarse una sola vez.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $roots.ProgramFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'Un fallo del hijo no debe dejar escrituras de la entrada remota.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un fallo de descarga no valida, no eleva y no deja restos' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi -FailDownload

            $exit = Invoke-MensorCadCli -FromRelease -Version 'v1.2.3' -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un fallo de descarga debe salir con codigo 1.'
            Assert-True (($script:SeamErrors -join ' ') -match 'No se pudieron descargar') 'El error debe explicar el fallo de descarga.'
            Assert-Equal 1 (Get-SeamCalls -Kind 'file').Count 'La descarga fallida no debe repetirse.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Sin paquete no debe ejecutarse el instalador ni pedir UAC.'
            Assert-Equal 0 $script:SeamSuccessCalls.Count 'Un fallo de descarga no debe pintar exito.'
            Assert-Equal 0 $script:SeamRelayedOut.Length 'Un fallo de descarga no debe reenviar salida de un hijo inexistente.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $roots.ProgramFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'Un fallo de descarga no debe escribir el destino.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un 404 de la API se explica sin afirmar que la release no existe' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi -ApiHttpStatus 404

            $exit = Invoke-MensorCadCli -FromRelease -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un 404 de la API debe salir con codigo 1.'
            $errors = $script:SeamErrors -join ' '
            Assert-True ($errors -match '404') 'El error debe mencionar el estado 404 real.'
            Assert-True ($errors -match 'credenciales') 'El error debe admitir un repositorio sin acceso.'
            Assert-True ($errors -match 'publicad') 'El error debe admitir que la release no este publicada.'
            Assert-True ($errors -notmatch 'no existe') 'Un 404 no debe afirmar que la release no existe.'
            Assert-Equal 0 (Get-SeamCalls -Kind 'file').Count 'Un 404 de la API no debe descargar assets.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Un 404 de la API no debe invocar el instalador.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un 404 al descargar los assets se informa con el tag fijado' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -DownloadHttpStatus 404

            $exit = Invoke-MensorCadCli -FromRelease -Version 'v1.2.3' -NoAnimation 6>$null
            Assert-Equal 1 $exit 'Un 404 al descargar los assets debe salir con codigo 1.'
            $errors = $script:SeamErrors -join ' '
            Assert-True ($errors -match '404') 'El error debe mencionar el estado 404 real.'
            Assert-True ($errors -match 'v1\.2\.3') 'El error debe indicar el tag que se intento descargar.'
            Assert-True ($errors -match 'credenciales') 'El error debe admitir un repositorio sin acceso.'
            Assert-Equal 0 (Get-SeamCalls -Kind 'text').Count 'La version fijada no debe consultar la API.'
            Assert-Equal 0 $script:SeamChildCalls.Count 'Un 404 de descarga no debe invocar el instalador.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El exito remoto se resume en jade solo con el hijo en 0' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi -ChildExitCode 0 -ChildStdOut 'linea-hijo-ok'
            $script:MensorCadPlainMode = $false

            $exit = Invoke-MensorCadRemoteInstall -Version 'v1.2.3' 6>$null
            Assert-Equal 0 $exit 'El hijo con codigo 0 debe conservar el codigo 0.'
            Assert-Equal 1 $script:SeamSuccessCalls.Count 'Debe haber un unico resumen de exito.'
            $summary = $script:SeamSuccessCalls[0]
            Assert-True ($summary.Headline -match 'remota') 'El titular debe referirse a la instalacion remota.'
            Assert-True ($summary.Metadata -match 'v1\.2\.3') 'El resumen debe mostrar la release resuelta.'
            Assert-Equal $script:MensorCadAutoCadNextAction $summary.NextAction 'Debe reutilizar la proxima accion compartida.'
            Assert-True ((($summary.Headline + ' ' + $summary.Detail).ToLower()) -notmatch 'se instal|se actualiz') 'Solo se conoce el codigo 0: no debe afirmar si se instalo o se actualizo.'
            Assert-True ($script:SeamRelayedOut -match 'linea-hijo-ok') 'La salida del hijo debe reenviarse antes del resumen.'
            Assert-Equal 0 $script:SeamErrors.Count 'El exito no debe registrar errores del padre.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            $script:MensorCadPlainMode = $true
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El fallo del hijo no se pinta como exito ni duplica el error' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath -AllowApi -ChildExitCode 1 -ChildStdOut 'linea-hijo' -ChildStdErr 'ERROR: AutoCAD esta en ejecucion. Cierre AutoCAD y vuelva a ejecutar el instalador.'
            $script:MensorCadPlainMode = $false

            $exit = Invoke-MensorCadRemoteInstall -Version 'v1.2.3' 6>$null
            Assert-Equal 1 $exit 'AutoCAD abierto debe conservar el codigo 1 del hijo.'
            Assert-Equal 0 $script:SeamSuccessCalls.Count 'Un hijo fallido no debe pintar exito.'
            Assert-True ($script:SeamRelayedErr -match 'AutoCAD esta en ejecucion') 'El stderr del hijo debe reenviarse intacto.'
            Assert-True ($script:SeamRelayedOut -match 'linea-hijo') 'El stdout del hijo debe reenviarse intacto.'
            Assert-Equal 0 $script:SeamErrors.Count 'El padre no debe inventar un segundo ERROR: en stderr.'
            Assert-NoRemoteLeftovers -TempRoot $roots.TempRoot
        }
        finally {
            $script:MensorCadPlainMode = $true
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'En modo plano el resumen remoto no agrega lineas nuevas' {
        $root = New-TestCaseRoot
        try {
            $release = New-FixtureRelease -RootPath $root -Version 'v1'
            $roots = New-RemoteCaseRoots -RootPath $root
            Set-MensorCadTestSeams -TempRoot $roots.TempRoot -ProgramFilesRoot $roots.ProgramFiles -ZipPath $release.ZipPath -SidecarPath $release.SidecarPath

            $script:MensorCadPlainMode = $true
            $plainRecords = @(Write-MensorCadRemoteResult -ExitCode 0 -Tag 'v1.2.3' 6>&1)
            Assert-Equal 0 $plainRecords.Count 'En modo plano el resumen del padre no debe imprimir nada.'
            Assert-Equal 0 $script:SeamSuccessCalls.Count 'En modo plano el exito no lo pinta el padre.'

            $script:MensorCadPlainMode = $false
            $failedRecords = @(Write-MensorCadRemoteResult -ExitCode 7 -Tag 'v1.2.3' 6>&1)
            $script:MensorCadPlainMode = $true
            Assert-True ($failedRecords.Count -ge 3) 'Con color el fallo debe dibujar su propio resumen.'
            Assert-Equal 0 $script:SeamSuccessCalls.Count 'Un codigo distinto de 0 nunca debe pintar exito.'
        }
        finally {
            $script:MensorCadPlainMode = $true
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'La espera activa pinta consola y se detiene cuando el hijo real termina' {
        $root = New-TestCaseRoot
        try {
            $probe = New-WaitProbeScript -RootPath $root
            $animated = Invoke-ChildInstaller -ScriptPath $probe -Arguments @('-ChildMilliseconds', '600', '-IntervalMilliseconds', '100')
            Assert-Equal 0 $animated.ExitCode ('La sonda de espera debe salir con 0. stderr: ' + $animated.Stderr)
            $transcriptPath = Join-Path -Path $root -ChildPath 'wait-probe.transcript.txt'
            Assert-True (Test-Path -LiteralPath $transcriptPath -PathType Leaf) 'La sonda debe capturar la salida de consola del host.'
            $consoleText = [System.IO.File]::ReadAllText($transcriptPath)
            $frames = ([regex]::Matches($consoleText, [regex]::Escape('mensaje-probe'))).Count
            Assert-True ($frames -ge 2) 'La espera activa debe pintar actividad en consola mientras el hijo real sigue en ejecucion.'
            $match = [regex]::Match($animated.Stdout, 'PROBE-FIN exited=True elapsed=([0-9]+)')
            Assert-True $match.Success ('La espera debe terminar solo cuando el hijo real termino. Salida: ' + $animated.Stdout)
            $elapsed = [int]$match.Groups[1].Value
            Assert-True ($elapsed -ge 500) ('La espera debe cubrir el tiempo real del hijo. elapsed=' + $elapsed)
            Assert-True ($elapsed -le 2600) ('La espera debe detenerse apenas el hijo termina, sin demoras simuladas. elapsed=' + $elapsed)
            $finishIndex = $animated.Stdout.IndexOf('PROBE-FIN')
            Assert-True ($finishIndex -ge 0) 'La sonda debe informar su finalizacion.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Sin animacion la espera activa informa una sola vez' {
        $root = New-TestCaseRoot
        try {
            $probe = New-WaitProbeScript -RootPath $root
            $plain = Invoke-ChildInstaller -ScriptPath $probe -Arguments @('-ChildMilliseconds', '300', '-IntervalMilliseconds', '100', '-PlainMode')
            Assert-Equal 0 $plain.ExitCode ('La sonda sin animacion debe salir con 0. stderr: ' + $plain.Stderr)
            $transcriptPath = Join-Path -Path $root -ChildPath 'wait-probe.transcript.txt'
            Assert-True (Test-Path -LiteralPath $transcriptPath -PathType Leaf) 'La sonda sin animacion debe capturar la salida de consola.'
            $consoleText = [System.IO.File]::ReadAllText($transcriptPath)
            $lines = ([regex]::Matches($consoleText, [regex]::Escape('mensaje-probe'))).Count
            Assert-Equal 1 $lines 'Sin animacion el paso de espera se informa una sola vez, sin frames repetidos.'
            Assert-True ($plain.Stdout -match 'PROBE-FIN exited=True') 'La espera sin animacion debe terminar con el hijo.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El hijo real se ejecuta con espera activa y conserva estado, salida y error' {
        $root = New-TestCaseRoot
        try {
            $childScript = Join-Path -Path $root -ChildPath 'child-fixture.ps1'
            Write-FixtureFile -Path $childScript -Content @'
param([int]$Milliseconds)
Start-Sleep -Milliseconds $Milliseconds
Write-Output 'SALIDA-HIJO-REAL'
[Console]::Error.WriteLine('ERROR-HIJO-REAL')
exit 9
'@
            $probe = New-ChildProbeScript -RootPath $root -ChildScriptPath $childScript
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-ChildInstaller -ScriptPath $probe -Arguments @('-Root', ('"' + $root + '"'))
            $stopwatch.Stop()
            Assert-Equal 0 $result.ExitCode ('La sonda del hijo real debe salir con 0. stderr: ' + $result.Stderr)
            $summaryPath = Join-Path -Path $root -ChildPath 'child-probe.json'
            Assert-True (Test-Path -LiteralPath $summaryPath -PathType Leaf) 'La sonda debe escribir su resumen observable.'
            $summaryJson = [System.IO.File]::ReadAllText($summaryPath)
            $summary = $summaryJson | ConvertFrom-Json
            # El resumen viaja en el mensaje para que un fallo en Windows muestre
            # si el hijo real corrio (stdout/stderr) o si solo se leyo mal el estado.
            Assert-Equal 9 ([int]$summary.ExitCode) ('El estado real distinto de cero no debe ocultarse. Resumen del hijo: ' + $summaryJson)
            Assert-True ([string]$summary.StdOut -match 'SALIDA-HIJO-REAL') 'La salida estandar del hijo real debe capturarse.'
            Assert-True ([string]$summary.StdErr -match 'ERROR-HIJO-REAL') 'La salida de error del hijo real debe capturarse.'
            Assert-True ([int]$summary.Frames -ge 2) 'La espera activa debe pintar mientras el hijo real corre.'
            Assert-True ([int]$summary.RunningFrames -ge 2) 'Los frames deben pintarse con el proceso aun vivo.'
            Assert-True ($stopwatch.Elapsed.TotalMilliseconds -le 8000) ('La espera activa no debe bloquearse tras el hijo. ms=' + [int]$stopwatch.Elapsed.TotalMilliseconds)
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El hijo real con exito conserva el codigo 0 y su salida' {
        $root = New-TestCaseRoot
        try {
            $childScript = Join-Path -Path $root -ChildPath 'child-ok.ps1'
            Write-FixtureFile -Path $childScript -Content @'
param([int]$Milliseconds)
Start-Sleep -Milliseconds $Milliseconds
Write-Output 'SALIDA-HIJO-OK'
exit 0
'@
            $probe = New-ChildProbeScript -RootPath $root -ChildScriptPath $childScript
            $result = Invoke-ChildInstaller -ScriptPath $probe -Arguments @('-Root', ('"' + $root + '"'))
            Assert-Equal 0 $result.ExitCode ('La sonda del hijo exitoso debe salir con 0. stderr: ' + $result.Stderr)
            $summaryPath = Join-Path -Path $root -ChildPath 'child-probe.json'
            Assert-True (Test-Path -LiteralPath $summaryPath -PathType Leaf) 'La sonda exitosa debe escribir su resumen observable.'
            $summaryJson = [System.IO.File]::ReadAllText($summaryPath)
            $summary = $summaryJson | ConvertFrom-Json
            Assert-Equal 0 ([int]$summary.ExitCode) ('El exito real 0 debe conservarse. Resumen del hijo: ' + $summaryJson)
            Assert-True ([string]$summary.StdOut -match 'SALIDA-HIJO-OK') 'La salida estandar del hijo exitoso debe capturarse.'
            Assert-True ([int]$summary.Frames -ge 1) 'La espera activa debe pintar tambien en el caso exitoso.'
            Assert-True ($null -ne $summary.RawProcessExitCode) 'El estado crudo del hijo exitoso debe estar disponible.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El estado de salida ausente del hijo falla sin reportar exito' {
        $root = New-TestCaseRoot
        try {
            $null = Copy-InstallerTo -RootPath $root
            $probe = New-ChildStatusProbeScript -RootPath $root
            $result = Invoke-ChildInstaller -ScriptPath $probe -Arguments @('-Root', ('"' + $root + '"'))
            Assert-Equal 0 $result.ExitCode ('La sonda de estado ausente debe salir con 0. stderr: ' + $result.Stderr)
            $summaryPath = Join-Path -Path $root -ChildPath 'missing-status.json'
            Assert-True (Test-Path -LiteralPath $summaryPath -PathType Leaf) 'La sonda debe escribir su resumen observable.'
            $summary = [System.IO.File]::ReadAllText($summaryPath) | ConvertFrom-Json
            Assert-Equal $true ([bool]$summary.Threw) 'Un estado de salida ausente debe fallar, no devolver 0 como exito.'
            Assert-Equal $null $summary.ExitCode 'El ayudante no debe devolver un codigo de salida inventado.'
            Assert-True ([string]$summary.Message -match 'No se pudo determinar el codigo de salida') 'El error debe explicar que no se pudo determinar el estado del hijo.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }
}
finally {
    for ($index = [Math]::Max(0, $script:FailureMessages.Count - 20); $index -lt $script:FailureMessages.Count; $index++) {
        Write-Host ('  - ' + $script:FailureMessages[$index]) -ForegroundColor Red
    }
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ('Resultado: {0} correctas, {1} fallidas, {2} omitidas.' -f $script:Passed, $script:Failed, $script:Skipped)

if ($script:Failed -gt 0) {
    exit 1
}
exit 0
