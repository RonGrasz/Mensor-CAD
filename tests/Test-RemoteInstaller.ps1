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
$script:TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('MensorCadRemoteTests-' + [guid]::NewGuid().ToString('N'))

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
    $path = Join-Path -Path $script:TestRoot -ChildPath ('case-' + [guid]::NewGuid().ToString('N'))
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
$frames = New-Object 'System.Collections.Generic.List[object]'
$originalWait = ${function:Wait-MensorCadRemoteChild}
function script:Wait-MensorCadRemoteChild {
    param($Process, [string]$Message, [int]$IntervalMilliseconds = 200)
    $script:ProbeProcess = $Process
    $null = & $originalWait -Process $Process -Message $Message -IntervalMilliseconds $IntervalMilliseconds
}
function script:Write-MensorCadActivity {
    param([string]$Message)
    $running = $false
    if ($null -ne $script:ProbeProcess) { $running = -not $script:ProbeProcess.HasExited }
    $frames.Add([pscustomobject]@{ Message = $Message; Running = $running })
}
$result = Invoke-MensorCadRemoteChild -ScriptPath '__CHILD__' -Arguments @('-Milliseconds', '700') -StdOutPath (Join-Path $Root 'child.stdout.log') -StdErrPath (Join-Path $Root 'child.stderr.log')
$summary = [pscustomobject]@{
    ExitCode = [int]$result.ExitCode
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
        [int]$ChildExitCode = 0,
        [string]$ChildStdOut = 'salida simulada del instalador extraido',
        [string]$ChildStdErr = ''
    )
    $script:SeamCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:SeamChildCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:SeamErrors = New-Object 'System.Collections.Generic.List[string]'
    $script:SeamRelayedOut = ''
    $script:SeamRelayedErr = ''
    $script:SeamTempRoot = $TempRoot
    $script:SeamProgramFilesRoot = $ProgramFilesRoot
    $script:SeamLatestTag = $LatestTag
    $script:SeamApiAllowed = $AllowApi.IsPresent
    $script:SeamApiFails = $FailApi.IsPresent
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
    function script:Write-MensorCadRelayedOutput {
        param([string]$Text, [switch]$IsError)
        if ($IsError) { $script:SeamRelayedErr += [string]$Text }
        else { $script:SeamRelayedOut += [string]$Text }
    }
    function script:Get-MensorCadRemoteText {
        param([string]$Uri)
        $script:SeamCalls.Add([pscustomobject]@{ Kind = 'text'; Uri = $Uri })
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
    $programFiles = Join-Path -Path $RootPath -ChildPath 'ProgramFilesLike'
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
    return @($script:SeamCalls | Where-Object { $_.Kind -eq $Kind })
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

            $installExit = Invoke-MensorCadCli -NoAnimation 6>$null
            Assert-Equal 0 $installExit 'La instalacion local sin opciones debe seguir funcionando.'
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
            $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
            Assert-Equal 9 ([int]$summary.ExitCode) 'El estado real distinto de cero no debe ocultarse.'
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
