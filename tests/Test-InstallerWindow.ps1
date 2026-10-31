#requires -Version 5.1
<#
    Pruebas funcionales de la entrega de ventana unica del instalador de MensorCAD.

    Solo se ejecutan en Windows con Windows PowerShell 5.1. Todas las costuras son
    locales: estas pruebas NUNCA piden UAC real, NUNCA ocultan ni manipulalan
    ventanas reales, NUNCA escriben en Program Files y NUNCA abren AutoCAD. Los
    fixtures se crean solo dentro de la carpeta temporal del proceso (la carpeta
    autorizada para estas pruebas).

    Que cubre: el lanzador del BAT entrega el resultado a la ventana elevada
    (sentinel privado + espera no bloqueante + marca de espera) solo cuando la consola
    es interactiva y dedicada a este Instalar.bat; cualquier otra entrada
    (PowerShell directo, terminal existente, remoto, redirigido o automatizado)
    conserva el comportamiento sincrono y sus codigos de salida originales.

    Lo que estas pruebas NO demuestran: que la ventana final se vea como se
    espera. Eso exige prueba visual humana (doble clic, aceptar y cancelar UAC).

    Ejecucion:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-InstallerWindow.ps1
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
# Nombres cortos: el motor usa una carpeta de transaccion hermana dentro del
# destino y Windows limita las rutas a MAX_PATH.
$script:TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('MCW-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

if (-not (Test-Path -LiteralPath $script:InstallerPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro el instalador en '$script:InstallerPath'." -ForegroundColor Red
    exit 1
}

# Carga el instalador sin ejecutar su flujo principal (guarda de dot-source).
. $script:InstallerPath

$null = New-Item -ItemType Directory -Path $script:TestRoot -Force

# S2: todos los fixtures viven bajo la carpeta temporal del proceso.
$script:TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
if (-not [System.IO.Path]::GetFullPath($script:TestRoot).StartsWith($script:TempBase, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host 'ERROR: la carpeta de fixtures debe estar dentro de la carpeta temporal.' -ForegroundColor Red
    exit 1
}

# Originales de las funciones del instalador que cada caso reemplaza. Las que no
# existan se omiten y la restauracion las elimina: una costura nunca debe
# filtrarse al caso siguiente.
$script:SeamFunctionNames = @(
    'Get-MensorCadProgramFilesRoot',
    'Test-MensorCadAdministrator',
    'Test-MensorCadAutoCadRunning',
    'Test-MensorCad64BitOperatingSystem',
    'Test-MensorCad64BitProcess',
    'Test-MensorCadConsoleStreamsInteractive',
    'Get-MensorCadDedicatedConsole',
    'Get-MensorCadConsoleClients',
    'Get-MensorCadProcessParentId',
    'Get-MensorCadProcessName',
    'Get-MensorCadProcessCommandLine',
    'Test-MensorCadHandoffEligible'
)
$script:OriginalFunctions = @{}
foreach ($name in $script:SeamFunctionNames) {
    $item = Get-Item -LiteralPath ('Function:\' + $name) -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        $script:OriginalFunctions[$name] = $item.ScriptBlock
    }
}

# Costura unica de Start-Process: activa simula UAC y el proceso hijo; inactiva
# delega en el cmdlet real. Se define una sola vez porque una funcion de scope de
# script no se puede eliminar de forma fiable desde el scope de un caso.
$script:RealStartProcess = Get-Command -Name 'Start-Process' -CommandType Cmdlet
$script:UseStartProcessStub = $false
function script:Start-Process {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [string]$Verb,
        [switch]$Wait,
        [switch]$PassThru,
        [switch]$NoNewWindow,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )
    if (-not $script:UseStartProcessStub) {
        $arguments = @{ FilePath = $FilePath }
        if ($PassThru) { $arguments['PassThru'] = $true }
        if (-not [string]::IsNullOrEmpty($ArgumentList)) { $arguments['ArgumentList'] = $ArgumentList }
        if (-not [string]::IsNullOrEmpty($Verb)) { $arguments['Verb'] = $Verb }
        if ($Wait) { $arguments['Wait'] = $true }
        if ($NoNewWindow) { $arguments['NoNewWindow'] = $true }
        if (-not [string]::IsNullOrEmpty($RedirectStandardOutput)) { $arguments['RedirectStandardOutput'] = $RedirectStandardOutput }
        if (-not [string]::IsNullOrEmpty($RedirectStandardError)) { $arguments['RedirectStandardError'] = $RedirectStandardError }
        return & $script:RealStartProcess @arguments
    }
    if ($Verb -eq 'RunAs') {
        $script:Events.Add('lanzar')
        $script:LaunchCount++
        $script:LaunchWaited = $Wait.IsPresent
        $script:LaunchArguments = $ArgumentList
        $script:LaunchHoldMarker = ([string]$ArgumentList) -match '\bHoldResult\b'
        if ($script:WindowTestElevation -eq 'cancel') { throw 'cancelado por el usuario' }
        if ($script:WindowTestElevation -eq 'missing') { return $null }
        return [pscustomobject]@{ ExitCode = [int]$script:WindowTestElevatedExitCode }
    }
    $script:Events.Add('lanzar-hijo')
    return New-FakeChildProcess -ExitCode $script:WindowTestChildExitCode
}

# Costura unica de Read-Host para la espera final del hijo elevado. Inactiva
# delega en el cmdlet real.
$script:RealReadHost = Get-Command -Name 'Read-Host' -CommandType Cmdlet
$script:UseReadHostStub = $false
function script:Read-Host {
    param([string]$Prompt)
    if (-not $script:UseReadHostStub) {
        return & $script:RealReadHost -Prompt $Prompt
    }
    $script:HoldCalls++
    if ($script:HoldMode -eq 'throw') { throw 'entrada no disponible' }
    return 'enter'
}

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
    $path = Join-Path -Path $script:TestRoot -ChildPath ('c' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

function Write-FixtureManifest {
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

function New-FixtureSource {
    param([string]$RootPath)
    $sourceRoot = Join-Path -Path $RootPath -ChildPath 'dist'
    $bundleRoot = Join-Path -Path $sourceRoot -ChildPath 'MensorCAD.bundle'
    $null = New-Item -ItemType Directory -Path $bundleRoot -Force
    Write-FixtureFile -Path (Join-Path $bundleRoot 'PackageContents.xml') -Content '<ApplicationPackage Name="MensorCAD" Version="v1" />'
    Write-FixtureFile -Path (Join-Path $bundleRoot 'Contents\Lisp\MC-AREA.lsp') -Content ("; MC-AREA fixture`r`n")
    Write-FixtureFile -Path (Join-Path $bundleRoot 'Contents\UI\MensorCAD.cuix') -Content 'CUIX-FIXTURE'
    Write-FixtureManifest -SourceRoot $sourceRoot
    return $sourceRoot
}

function New-FakeChildProcess {
    param([int]$ExitCode = 0)
    $process = [pscustomobject]@{
        Id = 4242
        Handle = [System.IntPtr]::Zero
        HasExited = $true
        ExitCode = $ExitCode
    }
    $null = $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    # Sin salida: el motor llama a WaitForExit() sin capturar el retorno.
    $null = $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) }
    return $process
}

function Invoke-ChildInstaller {
    param([string]$ScriptPath, [string[]]$Arguments = @())
    $stdoutPath = Join-Path -Path $script:TestRoot -ChildPath ('so-' + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrPath = Join-Path -Path $script:TestRoot -ChildPath ('se-' + [guid]::NewGuid().ToString('N') + '.txt')
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

function Invoke-BatCommand {
    param([string]$BatPath, [string[]]$Arguments = @())
    # Windows PowerShell 5.1 con $ErrorActionPreference = 'Stop' convierte el
    # stderr de un comando nativo en error terminante cuando los flujos se
    # fusionan: cada flujo se captura en su propio archivo.
    $commandShell = $env:ComSpec
    if ([string]::IsNullOrWhiteSpace($commandShell)) { $commandShell = 'cmd.exe' }
    $commandLine = '/c ""' + $BatPath + '"'
    if ($Arguments.Count -gt 0) { $commandLine += ' ' + ($Arguments -join ' ') }
    $commandLine += '"'
    $stdoutPath = Join-Path -Path $script:TestRoot -ChildPath ('bo-' + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrPath = Join-Path -Path $script:TestRoot -ChildPath ('be-' + [guid]::NewGuid().ToString('N') + '.txt')
    $process = Start-Process -FilePath $commandShell -ArgumentList $commandLine -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $stdoutPath) { $stdout = [System.IO.File]::ReadAllText($stdoutPath) }
    if (Test-Path -LiteralPath $stderrPath) { $stderr = [System.IO.File]::ReadAllText($stderrPath) }
    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-CliCapturingError {
    param([scriptblock]$Action)
    $originalError = [Console]::Error
    $writer = New-Object -TypeName 'System.IO.StringWriter'
    try {
        [Console]::SetError($writer)
        $code = & $Action
    }
    finally {
        [Console]::SetError($originalError)
    }
    return [pscustomobject]@{ ExitCode = [int]$code; StdErr = $writer.ToString() }
}

function Set-WindowTestSeams {
    param(
        [string]$SourceRoot,
        [string]$ProgramFilesRoot,
        [string]$Elevation = 'success',
        [int]$ElevatedExitCode = 7,
        [int]$ChildExitCode = 3,
        [ValidateSet('none', 'modeled')][string]$ConsoleTopology = 'none',
        [string]$CommandLine = '',
        [string]$CommandLineError = '',
        [switch]$StreamsRedirected,
        [switch]$Administrator,
        [switch]$RealDiscovery
    )
    $script:Events = New-Object 'System.Collections.Generic.List[string]'
    $script:LaunchCount = 0
    $script:LaunchWaited = $false
    $script:LaunchArguments = ''
    $script:LaunchHoldMarker = $false
    $script:WindowTestProgramFiles = $ProgramFilesRoot
    $script:WindowTestAdministrator = $Administrator.IsPresent
    $script:WindowTestElevation = $Elevation
    $script:WindowTestElevatedExitCode = $ElevatedExitCode
    $script:WindowTestChildExitCode = $ChildExitCode
    $script:WindowTestCommandLine = $CommandLine
    $script:WindowTestCommandLineError = $CommandLineError
    $script:WindowTestStreamsRedirected = $StreamsRedirected.IsPresent

    # Cada caso parte de la prueba real de consola dedicada; solo la topologia
    # 'none' la sustituye por un resultado negativo fijo.
    if ($script:OriginalFunctions.ContainsKey('Get-MensorCadDedicatedConsole')) {
        Set-Item -Path ('Function:\script:Get-MensorCadDedicatedConsole') -Value $script:OriginalFunctions['Get-MensorCadDedicatedConsole'] -Force
    }
    function script:Get-MensorCadProgramFilesRoot { return $script:WindowTestProgramFiles }
    function script:Test-MensorCadAdministrator { return $script:WindowTestAdministrator }
    function script:Test-MensorCadAutoCadRunning { return $false }
    function script:Test-MensorCad64BitOperatingSystem { return $true }
    function script:Test-MensorCad64BitProcess { return $true }
    if ($RealDiscovery) {
        # Cadena real de guardas: la consola de la prueba esta redirigida, asi que
        # la interactividad se resuelve como no disponible.
        function script:Test-MensorCadConsoleStreamsInteractive { return $false }
    }
    else {
        function script:Test-MensorCadConsoleStreamsInteractive { return (-not $script:WindowTestStreamsRedirected) }
    }
    if ($ConsoleTopology -eq 'modeled') {
        # Topologia modelada: exactamente dos clientes (este proceso y un cmd.exe
        # cuyo padre directo es este proceso) y una linea de comandos controlada.
        function script:Get-MensorCadConsoleClients {
            return [pscustomobject]@{ ProcessIds = @($PID, 5150) }
        }
        function script:Get-MensorCadProcessParentId {
            param([int]$ProcessId)
            if ($ProcessId -eq $PID) { return 5150 }
            throw ('proceso no modelado: ' + $ProcessId)
        }
        function script:Get-MensorCadProcessName {
            param([int]$ProcessId)
            if ($ProcessId -eq 5150) { return 'cmd' }
            return 'desconocido'
        }
        function script:Get-MensorCadProcessCommandLine {
            param([int]$ProcessId)
            if (-not [string]::IsNullOrEmpty($script:WindowTestCommandLineError)) { throw $script:WindowTestCommandLineError }
            return $script:WindowTestCommandLine
        }
    }
    elseif (-not $RealDiscovery) {
        function script:Get-MensorCadDedicatedConsole { return $false }
    }
    $script:UseStartProcessStub = $true
    $script:MensorCadScriptRoot = $SourceRoot
}

function Get-WindowEvents {
    return ($script:Events -join ',')
}

function Restore-WindowTestSeams {
    foreach ($name in $script:SeamFunctionNames) {
        if ($script:OriginalFunctions.ContainsKey($name)) {
            Set-Item -Path ('Function:\script:' + $name) -Value $script:OriginalFunctions[$name] -Force
        }
        else {
            Remove-Item -Path ('Function:\script:' + $name) -ErrorAction SilentlyContinue
        }
    }
    $script:UseStartProcessStub = $false
}

function Write-StubInstaller {
    # Stub inofensivo del instalador para ejercer el BAT real sin UAC ni
    # instalacion: registra los argumentos recibidos y sale con el codigo pedido.
    param([string]$RootPath)
    $path = Join-Path -Path $RootPath -ChildPath 'Install-MensorCAD.ps1'
    $content = @'
param(
    [switch]$ElevatedProcess,
    [switch]$Uninstall,
    [switch]$NoAnimation,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]$Remaining
)
$record = [pscustomobject]@{
    LauncherMarker = [string]$env:MENSORCAD_BAT_LAUNCHER
    ElevatedProcess = [bool]$ElevatedProcess
    Uninstall = [bool]$Uninstall
    NoAnimation = [bool]$NoAnimation
    Remaining = @($Remaining)
}
$record | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'stub-args.json') -Encoding UTF8
Write-Output 'STUB-INSTALADOR'
exit ([int]$env:MENSORCAD_STUB_EXIT)
'@
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($path, $content, $encoding)
    return $path
}

function New-WindowProbeScript {
    param([string]$RootPath, [string]$Mode = 'handoff')
    # Sonda en proceso hijo: unica forma honesta de comparar el stdout exacto,
    # porque Write-Host escribe en el host. Solo costuras locales.
    $probePath = Join-Path -Path $RootPath -ChildPath 'window-probe.ps1'
    $template = @'
param([string]$Root, [string]$Mode)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'Install-MensorCAD.ps1')
$script:Events = New-Object 'System.Collections.Generic.List[string]'
$script:LaunchCount = 0
$script:LaunchWaited = $false
$script:LaunchArguments = ''
function script:Get-MensorCadProgramFilesRoot { return (Join-Path $here 'PF') }
function script:Test-MensorCadAdministrator { return $false }
function script:Test-MensorCadAutoCadRunning { return $false }
function script:Test-MensorCad64BitOperatingSystem { return $true }
function script:Test-MensorCad64BitProcess { return $true }
function script:Test-MensorCadConsoleStreamsInteractive { return $true }
function script:Get-MensorCadConsoleClients { return [pscustomobject]@{ ProcessIds = @($PID, 5150) } }
function script:Get-MensorCadProcessParentId { param([int]$ProcessId) if ($ProcessId -eq $PID) { return 5150 } throw 'proceso no modelado' }
function script:Get-MensorCadProcessName { param([int]$ProcessId) return 'cmd' }
function script:Get-MensorCadProcessCommandLine {
    param([int]$ProcessId)
    return ('C:\Windows\system32\cmd.exe /c ""' + (Join-Path $here 'dist\Instalar.bat') + '" "')
}
function script:Start-Process {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [string]$Verb,
        [switch]$Wait,
        [switch]$PassThru,
        [switch]$NoNewWindow,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )
    $script:Events.Add('lanzar')
    $script:LaunchCount++
    $script:LaunchWaited = $Wait.IsPresent
    $script:LaunchArguments = $ArgumentList
    $script:LaunchHoldMarker = ([string]$ArgumentList) -match '\bHoldResult\b'
    return [pscustomobject]@{ ExitCode = 7 }
}
$script:MensorCadScriptRoot = Join-Path $here 'dist'
$arguments = @{ NoAnimation = $true }
if ($Mode -eq 'handoff') { $arguments['BatLauncher'] = $true }
$code = Invoke-MensorCadCli @arguments
$summary = [pscustomobject]@{
    ExitCode = [int]$code
    LaunchCount = $script:LaunchCount
    Wait = [bool]$script:LaunchWaited
    Arguments = [string]$script:LaunchArguments
    HoldMarker = [bool]$script:LaunchHoldMarker
    Events = ($script:Events -join ',')
}
$summary | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Root 'window-probe.json') -Encoding UTF8
exit 0
'@
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($probePath, $template, $encoding)
    return $probePath
}

function Get-HandoffState {
    return [pscustomobject]@{
        Sentinel = [int]$script:MensorCadBatHandoffSentinel
        LaunchCount = [int]$script:LaunchCount
        Waited = [bool]$script:LaunchWaited
        Arguments = [string]$script:LaunchArguments
        Events = (Get-WindowEvents)
        HoldMarker = [bool]$script:LaunchHoldMarker
        HoldMarkerCleared = [string]::IsNullOrEmpty($env:MENSORCAD_RESULT_HOLD)
    }
}

try {
    Test-Case 'La consola dedicada con WT_SESSION entrega el resultado (no excluye Windows Terminal)' {
        $root = New-TestCaseRoot
        $previousSession = $env:WT_SESSION
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            $env:WT_SESSION = 'modeled-windows-terminal'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLine ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "')
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null }
            $state = Get-HandoffState
            Assert-Equal $state.Sentinel $result.ExitCode 'El lanzador debe devolver el sentinel privado de entrega.'
            Assert-True ($state.Sentinel -ne 0 -and $state.Sentinel -ne 1) 'El sentinel no puede confundirse con un estado real del instalador.'
            Assert-Equal 1 $state.LaunchCount 'Debe lanzarse una sola vez el proceso elevado.'
            Assert-Equal $false $state.Waited 'La entrega no debe esperar al proceso elevado.'
            Assert-True $state.HoldMarker 'El hijo elevado debe heredar la marca de espera final.'
            Assert-Equal '' $result.StdErr 'La entrega correcta no debe escribir en stderr.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'La entrega no debe escribir en el destino.'
        }
        finally {
            if ($null -eq $previousSession) { Remove-Item Env:WT_SESSION -ErrorAction SilentlyContinue }
            else { $env:WT_SESSION = $previousSession }
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Sin la marca del BAT el lanzamiento sigue siendo sincrono (PowerShell directo)' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLine ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "')
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation 6>$null }
            $state = Get-HandoffState
            Assert-Equal 7 $result.ExitCode 'Sin opt-in debe conservarse el codigo del proceso elevado.'
            Assert-Equal $true $state.Waited 'Sin opt-in la espera debe ser bloqueante.'
            Assert-Equal $false $state.HoldMarker 'Sin opt-in el hijo no debe heredar la marca de espera.'
            Assert-Equal '' $result.StdErr 'El camino sincrono no debe escribir en stderr.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'La automatizacion MENSORCAD_NO_PAUSE mantiene el lanzamiento sincrono' {
        $root = New-TestCaseRoot
        $previousNoPause = $env:MENSORCAD_NO_PAUSE
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            $env:MENSORCAD_NO_PAUSE = '1'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLine ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "')
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null }
            $state = Get-HandoffState
            Assert-Equal 7 $result.ExitCode 'En automatizacion debe conservarse el codigo del proceso elevado.'
            Assert-Equal $true $state.Waited 'En automatizacion la espera debe ser bloqueante.'
            Assert-Equal $false $state.HoldMarker 'En automatizacion el hijo no debe heredar la marca de espera.'
        }
        finally {
            if ($null -eq $previousNoPause) { Remove-Item Env:MENSORCAD_NO_PAUSE -ErrorAction SilentlyContinue }
            else { $env:MENSORCAD_NO_PAUSE = $previousNoPause }
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Los flujos redirigidos mantienen el lanzamiento sincrono' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -StreamsRedirected -CommandLine ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "')
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null }
            $state = Get-HandoffState
            Assert-Equal 7 $result.ExitCode 'Con flujos redirigidos debe conservarse el codigo del proceso elevado.'
            Assert-Equal $true $state.Waited 'Con flujos redirigidos la espera debe ser bloqueante.'
            Assert-Equal $false $state.HoldMarker 'Con flujos redirigidos el hijo no debe heredar la marca de espera.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'La cadena real de guardas no entrega cuando la consola de la prueba esta redirigida' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -RealDiscovery
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null }
            $state = Get-HandoffState
            Assert-Equal 7 $result.ExitCode 'La cadena real de guardas debe caer al camino sincrono.'
            Assert-Equal $true $state.Waited 'La cadena real de guardas debe esperar (fail-open).'
            Assert-Equal $false $state.HoldMarker 'La cadena real de guardas no debe heredar la marca de espera.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Una terminal existente, /k, consola compartida o linea ilegible no habilitan la entrega' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            $variants = @(
                @{ Name = 'cmd por defecto'; CommandLine = 'C:\Windows\system32\cmd.exe'; CommandLineError = '' },
                @{ Name = 'cmd /k'; CommandLine = ('C:\Windows\system32\cmd.exe /k "' + $batch + '"'); CommandLineError = '' },
                @{ Name = 'otro /c'; CommandLine = 'C:\Windows\system32\cmd.exe /c other.cmd'; CommandLineError = '' },
                @{ Name = 'linea ilegible'; CommandLine = ''; CommandLineError = 'acceso denegado' }
            )
            foreach ($variant in $variants) {
                Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLine $variant.CommandLine -CommandLineError $variant.CommandLineError
                $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null }
                $state = Get-HandoffState
                Assert-Equal 7 $result.ExitCode ('Debe conservarse el codigo sincrono: ' + $variant.Name)
                Assert-Equal $true $state.Waited ('Debe esperar de forma sincrona: ' + $variant.Name)
                Assert-Equal $false $state.HoldMarker ('No debe heredar la marca de espera: ' + $variant.Name)
                Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count ('No debe escribir en el destino: ' + $variant.Name)
                Restore-WindowTestSeams
            }
            # Consola compartida: tres clientes, nunca es una consola dedicada.
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLine ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "')
            function script:Get-MensorCadConsoleClients {
                return [pscustomobject]@{ ProcessIds = @($PID, 5150, 5250) }
            }
            $shared = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null }
            Assert-Equal 7 $shared.ExitCode 'Una consola compartida debe conservar el camino sincrono.'
            Assert-Equal $true (Get-HandoffState).Waited 'Una consola compartida debe esperar de forma sincrona.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'La desinstalacion con opt-in reenvia los argumentos y devuelve el sentinel' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -Administrator
            Assert-Equal 0 (Invoke-MensorCadCli -NoAnimation 6>$null) 'La instalacion de preparacion debe salir con codigo 0.'
            $destination = Join-Path $programFiles 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json') -PathType Leaf) 'La preparacion debe crear la marca.'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLine ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "')
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -Uninstall -BatLauncher 6>$null }
            $state = Get-HandoffState
            Assert-Equal $state.Sentinel $result.ExitCode 'La desinstalacion entregada debe devolver el sentinel.'
            Assert-Equal $false $state.Waited 'La desinstalacion entregada no debe esperar.'
            Assert-True ($state.Arguments -match '-ElevatedProcess -Uninstall -NoAnimation') 'La relanzada debe conservar -Uninstall y -NoAnimation.'
            Assert-True $state.HoldMarker 'La relanzada debe recibir el argumento reservado HoldResult.'
            Assert-True ($state.HoldMarkerCleared) 'La marca de espera no debe quedarse en el lanzador.'
            Assert-True (Test-Path -LiteralPath $destination -PathType Container) 'La relanzada simulada no debe borrar el destino.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Cancelar UAC y un lanzamiento sin proceso conservan los errores exactos sin sentinel' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            $expectedCancel = 'ERROR: No se obtuvo elevacion mediante UAC. La instalacion no se realizo. Detalle: cancelado por el usuario' + [Environment]::NewLine
            $expectedMissing = 'ERROR: No se pudo iniciar el proceso elevado. La instalacion no se realizo.' + [Environment]::NewLine
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -Elevation 'cancel' -CommandLine ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "')
            $cancel = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null }
            Assert-Equal 1 $cancel.ExitCode 'Cancelar UAC debe salir con codigo 1, nunca con el sentinel.'
            Assert-Equal $expectedCancel $cancel.StdErr 'El error de cancelacion debe ser el mismo de antes.'
            Assert-Equal 1 (Get-HandoffState).LaunchCount 'Debe lanzarse una sola vez.'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -Elevation 'missing' -CommandLine ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "')
            $missing = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null }
            Assert-Equal 1 $missing.ExitCode 'Un lanzamiento sin proceso debe salir con codigo 1, nunca con el sentinel.'
            Assert-Equal $expectedMissing $missing.StdErr 'El error de lanzamiento debe ser el mismo de antes.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'Los fallos de UAC no deben escribir en el destino.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Ya administrador, ayuda y -NoAnimation no abren ninguna entrega' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -Administrator
            $installExit = Invoke-MensorCadCli -NoAnimation -BatLauncher 6>$null
            Assert-Equal 0 $installExit 'Con permisos de administrador debe seguir saliendo con codigo 0.'
            Assert-Equal 0 $script:LaunchCount 'Ya administrador no debe lanzar ningun proceso elevado.'
            $destination = Join-Path $programFiles 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json') -PathType Leaf) 'La instalacion debe seguir escribiendo la marca.'
            $uninstallExit = Invoke-MensorCadCli -NoAnimation -Uninstall -BatLauncher 6>$null
            Assert-Equal 0 $uninstallExit 'La desinstalacion con permisos debe seguir saliendo con codigo 0.'
            Assert-Equal 0 $script:LaunchCount 'La desinstalacion con permisos no debe lanzar ningun proceso elevado.'
            $helpExit = Invoke-MensorCadCli -Help -NoAnimation -BatLauncher 6>$null
            Assert-Equal 0 $helpExit 'La ayuda debe seguir saliendo con codigo 0.'
            Assert-Equal 0 $script:LaunchCount 'La ayuda no debe lanzar ningun proceso elevado.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'La espera final del hijo elevado solo aplica a consolas interactivas y no altera el codigo' {
        $previousNoPause = $env:MENSORCAD_NO_PAUSE
        try {
            Remove-Item Env:MENSORCAD_NO_PAUSE -ErrorAction SilentlyContinue
            $script:UseReadHostStub = $true
            $script:HoldCalls = 0
            $script:HoldMode = 'enter'
            Wait-MensorCadResultHold -HoldResult -StreamsInteractive $true
            Assert-Equal 1 $script:HoldCalls 'Con HoldResult y consola interactiva se debe esperar una lectura.'
            $script:HoldCalls = 0
            Wait-MensorCadResultHold -StreamsInteractive $true
            Assert-Equal 0 $script:HoldCalls 'Sin HoldResult no se debe esperar.'
            Wait-MensorCadResultHold -HoldResult -StreamsInteractive $false
            Assert-Equal 0 $script:HoldCalls 'Con flujos redirigidos no se debe esperar.'
            $env:MENSORCAD_NO_PAUSE = '1'
            Wait-MensorCadResultHold -HoldResult -StreamsInteractive $true
            Assert-Equal 0 $script:HoldCalls 'En automatizacion no se debe esperar.'
            Remove-Item Env:MENSORCAD_NO_PAUSE -ErrorAction SilentlyContinue
            $script:HoldMode = 'throw'
            Wait-MensorCadResultHold -HoldResult -StreamsInteractive $true
            Assert-Equal 1 $script:HoldCalls 'La lectura se intenta una sola vez.'
        }
        finally {
            $script:UseReadHostStub = $false
            if ($null -eq $previousNoPause) { Remove-Item Env:MENSORCAD_NO_PAUSE -ErrorAction SilentlyContinue }
            else { $env:MENSORCAD_NO_PAUSE = $previousNoPause }
        }
    }

    Test-Case 'La sonda nativa de consola compila y solo lee la lista de clientes' {
        $native = Get-MensorCadConsoleNativeType
        Assert-True ($null -ne $native) 'La declaracion Win32 debe compilar con Add-Type.'
        $first = Get-MensorCadConsoleClients
        $second = Get-MensorCadConsoleClients
        if ($null -ne $first) {
            Assert-True (@($first.ProcessIds) -contains $PID) 'La sonda debe incluir el proceso actual entre los clientes.'
            Assert-Equal (@($first.ProcessIds) -join ',') (@($second.ProcessIds) -join ',') 'La sonda es de solo lectura y debe ser estable.'
        }
        $dedicated = Get-MensorCadDedicatedConsole -ConsoleProbe { return $null }
        Assert-Equal $false $dedicated 'Sin clientes legibles no se debe confirmar una consola dedicada.'
    }

    Test-Case 'El reconocedor de linea de comandos exige /c y este Instalar.bat' {
        $batch = 'C:\paquete\Instalar.bat'
        $quoted = 'C:\Windows\system32\cmd.exe /c ""' + $batch + '" "'
        Assert-Equal $batch (Get-MensorCadBatchCommandTarget -CommandLine $quoted -BatchPath $batch) 'La forma exacta del doble clic debe reconocerse.'
        Assert-Equal $batch (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /c ' + $batch) -BatchPath $batch) 'La forma sin comillas extra debe reconocerse.'
        Assert-Equal $batch (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /d /c "' + $batch + '" -NoAnimation') -BatchPath $batch) 'Los argumentos del BAT no cambian el objetivo.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine 'C:\Windows\system32\cmd.exe' -BatchPath $batch)) 'Un cmd interactivo sin /c no se debe aceptar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /k "' + $batch + '"') -BatchPath $batch)) 'cmd /k no se debe aceptar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine 'C:\Windows\system32\cmd.exe /c other.cmd' -BatchPath $batch)) 'Un /c de otro programa no se debe aceptar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine 'C:\Windows\system32\cmd.exe /c "C:\otro\Instalar.bat"' -BatchPath $batch)) 'Un Instalar.bat de otra carpeta no se debe aceptar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /c "' + $batch + '" & calc.exe') -BatchPath $batch)) 'Un comando compuesto no se debe aceptar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine 'C:\Windows\system32\cmd.exe "C:/c/work"' -BatchPath $batch)) 'Un /c dentro de una ruta entre comillas no es un interruptor.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine '' -BatchPath $batch)) 'Sin linea de comandos no se debe aceptar.'
    }

    Test-Case 'La consola dedicada se entrega con stdout neutral y sin resumen de exito' {
        $root = New-TestCaseRoot
        try {
            $null = Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root 'Install-MensorCAD.ps1') -Force
            $source = New-FixtureSource -RootPath $root
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'PF') -Force
            Write-FixtureFile -Path (Join-Path $source 'Instalar.bat') -Content '@echo off'
            $probe = New-WindowProbeScript -RootPath $root -Mode 'handoff'
            $result = Invoke-ChildInstaller -ScriptPath $probe -Arguments @('-Root', ('"' + $root + '"'), '-Mode', 'handoff')
            Assert-Equal 0 $result.ExitCode ('La sonda de entrega debe salir con 0. stderr: ' + $result.Stderr)
            $summary = [System.IO.File]::ReadAllText((Join-Path $root 'window-probe.json')) | ConvertFrom-Json
            $sentinel = [int]$script:MensorCadBatHandoffSentinel
            Assert-Equal $sentinel ([int]$summary.ExitCode) 'La sonda debe devolver el sentinel.'
            Assert-Equal 1 ([int]$summary.LaunchCount) 'La sonda debe lanzar una sola vez.'
            Assert-Equal $false ([bool]$summary.Wait) 'La sonda no debe esperar al proceso elevado.'
            Assert-True (([string]$summary.Arguments) -match '-ElevatedProcess -NoAnimation') 'La relanzada debe conservar sus argumentos.'
            Assert-Equal $true ([bool]$summary.HoldMarker) 'La relanzada debe heredar la marca de espera.'
            Assert-Equal '' ($result.Stderr.Trim()) 'La entrega no debe escribir en stderr.'
            $expectedLines = @(
                'MensorCAD - Instalador local para AutoCAD'
                '  [1/4] Validando el paquete local antes de pedir permisos'
                '  Verificando 1/3: Contents/Lisp/MC-AREA.lsp'
                '  Verificando 2/3: Contents/UI/MensorCAD.cuix'
                '  Verificando 3/3: PackageContents.xml'
                '  [2/4] Comprobando permisos de administrador'
                '  Se abrira la ventana de UAC. Acepte para continuar.'
            ) -join "`n"
            $actualLines = $result.Stdout.Replace("`r`n", "`n").Trim()
            Assert-Equal $expectedLines $actualLines 'La entrega debe dejar el mismo stdout y ningun resumen de exito.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El BAT marca el lanzamiento, conserva estados y no imprime exito al entregar' {
        $root = New-TestCaseRoot
        $previousNoPause = $env:MENSORCAD_NO_PAUSE
        $previousStubExit = $env:MENSORCAD_STUB_EXIT
        try {
            $null = Copy-Item -LiteralPath $script:BatPath -Destination (Join-Path $root 'Instalar.bat') -Force
            $null = Write-StubInstaller -RootPath $root
            $bat = Join-Path $root 'Instalar.bat'
            $sentinel = [int]$script:MensorCadBatHandoffSentinel

            # Ejecucion correcta: resumen original, codigo original, sin mensaje neutral.
            $env:MENSORCAD_NO_PAUSE = '1'
            $env:MENSORCAD_STUB_EXIT = '0'
            $success = Invoke-BatCommand -BatPath $bat -Arguments @('-NoAnimation')
            Assert-Equal 0 $success.ExitCode 'El BAT debe conservar el codigo 0.'
            Assert-True ($success.Stdout -match 'Operacion finalizada correctamente') 'El BAT debe conservar su resumen de exito.'
            Assert-True ($success.Stdout -notmatch 'continua en la ventana elevada') 'Sin entrega el BAT no debe imprimir el mensaje neutral.'
            $stub = [System.IO.File]::ReadAllText((Join-Path $root 'stub-args.json')) | ConvertFrom-Json
            Assert-Equal '1' ([string]$stub.LauncherMarker) 'El BAT debe marcar el lanzamiento con MENSORCAD_BAT_LAUNCHER=1.'
            Assert-Equal $true ([bool]$stub.NoAnimation) 'El BAT debe reenviar %*.'
            Assert-True ($success.Stdout -notmatch '(?i)tecla|any key') 'Con MENSORCAD_NO_PAUSE no debe haber pausa.'

            # Fallo controlado: resumen de error original y mismo codigo.
            $env:MENSORCAD_STUB_EXIT = '1'
            $failure = Invoke-BatCommand -BatPath $bat -Arguments @('-Uninstall')
            Assert-Equal 1 $failure.ExitCode 'El BAT debe conservar el codigo 1.'
            Assert-True ($failure.Stdout -match 'ERROR: La operacion fallo con codigo 1') 'El BAT debe conservar su resumen de error.'
            Assert-True ($failure.Stdout -notmatch 'continua en la ventana elevada') 'Un fallo no debe imprimir el mensaje neutral.'
            $stub = [System.IO.File]::ReadAllText((Join-Path $root 'stub-args.json')) | ConvertFrom-Json
            Assert-Equal $true ([bool]$stub.Uninstall) 'El BAT debe reenviar -Uninstall.'

            # Entrega: mensaje neutral, sin exito, sin error y sin pausa.
            Remove-Item Env:MENSORCAD_NO_PAUSE -ErrorAction SilentlyContinue
            $env:MENSORCAD_STUB_EXIT = [string]$sentinel
            $handoff = Invoke-BatCommand -BatPath $bat -Arguments @()
            Assert-Equal 0 $handoff.ExitCode 'La entrega debe terminar con codigo 0 en el BAT.'
            Assert-True ($handoff.Stdout -match 'continua en la ventana elevada') 'La entrega debe informar el traspaso.'
            Assert-True ($handoff.Stdout -notmatch 'Operacion finalizada correctamente') 'La entrega no debe imprimir exito.'
            Assert-True ($handoff.Stdout -notmatch 'ERROR:') 'La entrega no debe imprimir error.'
            Assert-True ($handoff.Stdout -notmatch '(?i)tecla|any key') 'La entrega debe omitir la pausa original.'
            Assert-Equal '' $handoff.Stderr.Trim() 'La entrega no debe escribir en stderr.'
        }
        finally {
            if ($null -eq $previousNoPause) { Remove-Item Env:MENSORCAD_NO_PAUSE -ErrorAction SilentlyContinue }
            else { $env:MENSORCAD_NO_PAUSE = $previousNoPause }
            if ($null -eq $previousStubExit) { Remove-Item Env:MENSORCAD_STUB_EXIT -ErrorAction SilentlyContinue }
            else { $env:MENSORCAD_STUB_EXIT = $previousStubExit }
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El instalador elevado real no retiene la salida cuando los flujos estan redirigidos' {
        $root = New-TestCaseRoot
        try {
            $scriptCopy = Join-Path $root 'Install-MensorCAD.ps1'
            Copy-Item -LiteralPath $script:InstallerPath -Destination $scriptCopy -Force
            # El interruptor -HoldResult es el unico que autoriza la espera final;
            # con flujos redirigidos no debe retener nada.
            $result = Invoke-ChildInstaller -ScriptPath $scriptCopy -Arguments @('-ElevatedProcess', '-Help', '-HoldResult')
            Assert-Equal 0 $result.ExitCode 'La ayuda elevada con -HoldResult no debe colgarse ni fallar.'
            Assert-True ($result.Stdout -match 'Uso:') 'La ayuda debe seguir mostrando el uso.'
            # Sin el interruptor la relanzada no debe esperar (aqui los flujos
            # redirigidos ya lo impedirian, pero la ausencia del switch debe ser
            # la senal principal).
            $plain = Invoke-ChildInstaller -ScriptPath $scriptCopy -Arguments @('-ElevatedProcess', '-Help')
            Assert-Equal 0 $plain.ExitCode 'La ayuda elevada sin -HoldResult no debe colgarse ni fallar.'
            Assert-True ($plain.Stdout -match 'Uso:') 'La ayuda debe seguir mostrando el uso sin -HoldResult.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El hijo remoto mantiene su camino sincrono y su codigo' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ChildExitCode 3
            $result = Invoke-MensorCadRemoteChild -ScriptPath $script:InstallerPath -Arguments @('-NoAnimation') -StdOutPath (Join-Path $root 'c.out') -StdErrPath (Join-Path $root 'c.err')
            Assert-Equal 3 ([int]$result.ExitCode) 'El hijo remoto debe conservar su codigo de salida.'
            Assert-True ((Get-WindowEvents) -notmatch 'RunAs') 'El hijo remoto no debe pedir elevacion.'
            Assert-Equal '' ([string]$result.StdErr) 'El hijo remoto sin salida propia no debe inventar stderr.'
        }
        finally {
            Restore-WindowTestSeams
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
