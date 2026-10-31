#requires -Version 5.1
<#
    Pruebas funcionales de la ventana unica del instalador de MensorCAD.

    Solo se ejecutan en Windows con Windows PowerShell 5.1. Todas las costuras
    son locales: estas pruebas NUNCA piden UAC real, NUNCA ocultan ni muestran
    la consola real del usuario, NUNCA escriben en Program Files y NUNCA abren
    AutoCAD. Los fixtures se crean solo dentro de la carpeta temporal del
    proceso (la carpeta autorizada para estas pruebas).

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
# Nombres cortos: el motor usa una carpeta de transaccion hermana dentro del
# destino y Windows limita las rutas a MAX_PATH. Con nombres largos la copia de
# la etapa falla por longitud de ruta, no por el comportamiento bajo prueba.
$script:TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('MCW-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

if (-not (Test-Path -LiteralPath $script:InstallerPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro el instalador en '$script:InstallerPath'." -ForegroundColor Red
    exit 1
}

# Carga el instalador sin ejecutar su flujo principal (guarda de dot-source).
. $script:InstallerPath

$null = New-Item -ItemType Directory -Path $script:TestRoot -Force

# S2: todos los fixtures viven bajo la carpeta temporal del proceso. Si el
# entorno apunta a otro sitio, la prueba se detiene sin escribir nada.
$script:TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
if (-not [System.IO.Path]::GetFullPath($script:TestRoot).StartsWith($script:TempBase, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host 'ERROR: la carpeta de fixtures debe estar dentro de la carpeta temporal.' -ForegroundColor Red
    exit 1
}

# Originales de las funciones del instalador que cada caso reemplaza. Se
# guardan para restaurarlas al terminar el caso: una costura nunca debe
# filtrarse al caso siguiente. Las funciones que aun no existen (por ejemplo en
# una version anterior del instalador) se omiten: la restauracion las elimina.
$script:SeamFunctionNames = @(
    'Get-MensorCadProgramFilesRoot',
    'Test-MensorCadAdministrator',
    'Test-MensorCadAutoCadRunning',
    'Test-MensorCad64BitOperatingSystem',
    'Test-MensorCad64BitProcess',
    'Test-MensorCadConsoleHandoffBlocked',
    'Get-MensorCadDedicatedConsole',
    'Get-MensorCadConsoleProbe',
    'Get-MensorCadProcessParentId',
    'Get-MensorCadProcessName',
    'Get-MensorCadProcessCommandLine',
    'Set-MensorCadConsoleWindowVisible'
)
$script:OriginalFunctions = @{}
foreach ($name in $script:SeamFunctionNames) {
    $item = Get-Item -LiteralPath ('Function:\' + $name) -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        $script:OriginalFunctions[$name] = $item.ScriptBlock
    }
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

# Costura unica de Start-Process. Activa simula UAC y el proceso hijo; inactiva
# delega en el cmdlet real. Se define una sola vez porque una funcion de scope
# de script no se puede eliminar de forma fiable desde el scope de un caso: el
# flag desactivable evita que una costura quede activa por accidente.
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
        $script:LaunchArguments = $ArgumentList
        if ($script:WindowTestElevation -eq 'cancel') { throw 'cancelado por el usuario' }
        if ($script:WindowTestElevation -eq 'missing') { return $null }
        return [pscustomobject]@{ ExitCode = [int]$script:WindowTestElevatedExitCode }
    }
    $script:Events.Add('lanzar-hijo')
    return New-FakeChildProcess -ExitCode $script:WindowTestChildExitCode
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

function Invoke-CliCapturingError {
    # Captura exacta del flujo de error: Write-MensorCadFailure usa
    # [Console]::Error, asi que se compara el texto real, no una costura.
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
        [object]$ConsoleWindow = $null,
        [switch]$Administrator,
        [switch]$RealDiscovery,
        [ValidateSet('none', 'modeled')][string]$ConsoleTopology = 'none',
        [string]$CommandLine = '',
        [string]$CommandLineError = ''
    )
    $script:Events = New-Object 'System.Collections.Generic.List[string]'
    $script:WindowTestProgramFiles = $ProgramFilesRoot
    $script:WindowTestAdministrator = $Administrator.IsPresent
    $script:WindowTestElevation = $Elevation
    $script:WindowTestElevatedExitCode = $ElevatedExitCode
    $script:WindowTestChildExitCode = $ChildExitCode
    $script:WindowTestConsoleWindow = $ConsoleWindow
    $script:WindowTestRealDiscovery = $RealDiscovery.IsPresent
    $script:WindowTestCommandLine = $CommandLine
    $script:WindowTestCommandLineError = $CommandLineError
    $script:LaunchArguments = ''

    function script:Get-MensorCadProgramFilesRoot { return $script:WindowTestProgramFiles }
    function script:Test-MensorCadAdministrator { return $script:WindowTestAdministrator }
    function script:Test-MensorCadAutoCadRunning { return $false }
    function script:Test-MensorCad64BitOperatingSystem { return $true }
    function script:Test-MensorCad64BitProcess { return $true }
    if ($RealDiscovery) {
        # Se ejerce la cadena real de guardas: solo se fija la compuerta de
        # redireccion para que el resultado no dependa de como se lanzo la
        # prueba. Nada puede llegar a ocultar la consola real.
        function script:Test-MensorCadConsoleHandoffBlocked { return $true }
    }
    elseif ($ConsoleTopology -eq 'modeled') {
        # Topologia modelada: dos clientes (este proceso y un cmd.exe hijo de
        # explorer.exe) y una linea de comandos controlada. La decision real la
        # toma Get-MensorCadDedicatedConsole; la visibilidad sigue siendo una
        # costura para no tocar la consola real.
        function script:Test-MensorCadConsoleHandoffBlocked { return $false }
        function script:Get-MensorCadConsoleProbe {
            return [pscustomobject]@{
                WindowHandle = [System.IntPtr]::new(4242)
                ProcessIds = @($PID, 5150)
                WindowVisible = $true
            }
        }
        function script:Get-MensorCadProcessParentId {
            param([int]$ProcessId)
            if ($ProcessId -eq $PID) { return 5150 }
            if ($ProcessId -eq 5150) { return 6200 }
            throw ('proceso no modelado: ' + $ProcessId)
        }
        function script:Get-MensorCadProcessName {
            param([int]$ProcessId)
            if ($ProcessId -eq 5150) { return 'cmd' }
            if ($ProcessId -eq 6200) { return 'explorer' }
            return 'desconocido'
        }
        function script:Get-MensorCadProcessCommandLine {
            param([int]$ProcessId)
            if (-not [string]::IsNullOrEmpty($script:WindowTestCommandLineError)) { throw $script:WindowTestCommandLineError }
            return $script:WindowTestCommandLine
        }
    }
    else {
        function script:Get-MensorCadDedicatedConsole {
            $script:Events.Add('descubrir')
            return $script:WindowTestConsoleWindow
        }
    }
    function script:Set-MensorCadConsoleWindowVisible {
        param([IntPtr]$WindowHandle, [bool]$Visible)
        if ($Visible) { $script:Events.Add('restaurar') } else { $script:Events.Add('ocultar') }
        return $true
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

function New-WindowProbeScript {
    param([string]$RootPath)
    # Sonda en proceso hijo: unica forma honesta de comparar el stdout exacto,
    # porque Write-Host escribe en el host y no en [Console]::Out. La sonda solo
    # usa costuras locales: no hay UAC real, no se oculta la consola real y no
    # se instala nada.
    $probePath = Join-Path -Path $RootPath -ChildPath 'window-probe.ps1'
    $template = @'
param([string]$Root)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'Install-MensorCAD.ps1')
$script:Events = New-Object 'System.Collections.Generic.List[string]'
function script:Get-MensorCadProgramFilesRoot { return (Join-Path $here 'PF') }
function script:Test-MensorCadAdministrator { return $false }
function script:Test-MensorCadAutoCadRunning { return $false }
function script:Test-MensorCad64BitOperatingSystem { return $true }
function script:Test-MensorCad64BitProcess { return $true }
function script:Get-MensorCadDedicatedConsole {
    $script:Events.Add('descubrir')
    return [pscustomobject]@{ WindowHandle = [System.IntPtr]::new(4242) }
}
function script:Set-MensorCadConsoleWindowVisible {
    param([IntPtr]$WindowHandle, [bool]$Visible)
    if ($Visible) { $script:Events.Add('restaurar') } else { $script:Events.Add('ocultar') }
    return $true
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
    return [pscustomobject]@{ ExitCode = 7 }
}
$script:MensorCadScriptRoot = Join-Path $here 'dist'
$code = Invoke-MensorCadCli -NoAnimation
$summary = [pscustomobject]@{ ExitCode = [int]$code; Events = ($script:Events -join ',') }
$summary | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Root 'window-probe.json') -Encoding UTF8
exit 0
'@
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($probePath, $template, $encoding)
    return $probePath
}

try {
    Test-Case 'La deteccion rechaza ventana redirigida, pseudoconsola y ventana no visible' {
        $provenProbe = {
            return [pscustomobject]@{
                WindowHandle = [System.IntPtr]::new(4242)
                ProcessIds = @(100, 200)
                WindowVisible = $true
            }
        }
        $parentProbe = { param($ProcessId) if ($ProcessId -eq 100) { return 200 } return 900 }
        $nameProbe = {
            param($ProcessId)
            if ($ProcessId -eq 200) { return 'cmd' }
            if ($ProcessId -eq 900) { return 'explorer' }
            return 'powershell'
        }
        $batch = 'C:\paquete\Instalar.bat'
        $commandProbe = { param($ProcessId) return ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "') }.GetNewClosure()
        $base = @{
            ConsoleProbe = $provenProbe
            ParentIdProbe = $parentProbe
            ProcessNameProbe = $nameProbe
            CommandLineProbe = $commandProbe
            BatchPath = $batch
            OutputRedirected = $false
            TerminalSession = ''
            CurrentProcessId = 100
        }
        $dedicated = Get-MensorCadDedicatedConsole @base
        Assert-True ($null -ne $dedicated) 'Una consola dedicada comprobada debe detectarse.'
        Assert-Equal 4242 $dedicated.WindowHandle.ToInt64() 'La ventana detectada debe ser la de la consola dedicada.'

        $redirected = $base.Clone()
        $redirected.OutputRedirected = $true
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @redirected)) 'Con salida redirigida no se debe detectar consola propia.'
        $terminal = $base.Clone()
        $terminal.TerminalSession = 'wt-session'
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @terminal)) 'En Windows Terminal (WT_SESSION) no se debe ocultar nada.'

        $invisible = $base.Clone()
        $invisible.ConsoleProbe = { return [pscustomobject]@{ WindowHandle = [System.IntPtr]::new(4242); ProcessIds = @(100, 200); WindowVisible = $false } }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @invisible)) 'Una ventana no visible no se debe ocultar.'
        $noWindow = $base.Clone()
        $noWindow.ConsoleProbe = { return [pscustomobject]@{ WindowHandle = [System.IntPtr]::Zero; ProcessIds = @(100, 200); WindowVisible = $true } }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @noWindow)) 'Sin ventana de consola no se debe ocultar nada.'
        $broken = $base.Clone()
        $broken.ConsoleProbe = { throw 'sonda rota' }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @broken)) 'Una sonda con error debe resolverse sin ocultar (fail-open).'
        $inconclusive = $base.Clone()
        $inconclusive.ConsoleProbe = { return $null }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @inconclusive)) 'Una sonda no concluyente debe resolverse sin ocultar (fail-open).'
    }

    Test-Case 'La deteccion exige exactamente cmd como padre y explorer como abuelo' {
        $provenProbe = {
            return [pscustomobject]@{
                WindowHandle = [System.IntPtr]::new(4242)
                ProcessIds = @(100, 200)
                WindowVisible = $true
            }
        }
        $batch = 'C:\paquete\Instalar.bat'
        $parentProbe = { param($ProcessId) if ($ProcessId -eq 100) { return 200 } return 900 }
        $commandProbe = { param($ProcessId) return ('C:\Windows\system32\cmd.exe /c ""' + $batch + '" "') }.GetNewClosure()
        $explorerNameProbe = {
            param($ProcessId)
            if ($ProcessId -eq 200) { return 'cmd' }
            if ($ProcessId -eq 900) { return 'explorer' }
            return 'powershell'
        }
        $base = @{
            ConsoleProbe = $provenProbe
            ParentIdProbe = $parentProbe
            ProcessNameProbe = $explorerNameProbe
            CommandLineProbe = $commandProbe
            BatchPath = $batch
            OutputRedirected = $false
            TerminalSession = ''
            CurrentProcessId = 100
        }
        Assert-True ($null -ne (Get-MensorCadDedicatedConsole @base)) 'La topologia completa debe detectarse.'

        $shared = $base.Clone()
        $shared.ConsoleProbe = { return [pscustomobject]@{ WindowHandle = [System.IntPtr]::new(4242); ProcessIds = @(100, 200, 300); WindowVisible = $true } }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @shared)) 'Una consola compartida con otros procesos no se debe ocultar.'
        $noSelf = $base.Clone()
        $noSelf.ConsoleProbe = { return [pscustomobject]@{ WindowHandle = [System.IntPtr]::new(4242); ProcessIds = @(200, 300); WindowVisible = $true } }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @noSelf)) 'La lista de procesos debe incluir el proceso actual.'
        $notParent = $base.Clone()
        $notParent.ParentIdProbe = { param($ProcessId) if ($ProcessId -eq 100) { return 901 } return 900 }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @notParent)) 'El otro proceso de la consola debe ser el padre real.'
        $notCmd = $base.Clone()
        $notCmd.ProcessNameProbe = { param($ProcessId) if ($ProcessId -eq 200) { return 'powershell' } return 'explorer' }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @notCmd)) 'El padre debe ser cmd.exe.'
        $notExplorer = $base.Clone()
        $notExplorer.ProcessNameProbe = { param($ProcessId) if ($ProcessId -eq 200) { return 'cmd' } return 'bash' }
        Assert-True ($null -eq (Get-MensorCadDedicatedConsole @notExplorer)) 'El padre de cmd.exe debe ser explorer.exe.'
    }

    Test-Case 'La linea de comandos distingue el doble clic de una terminal existente' {
        $batch = 'C:\paquete\Instalar.bat'
        $quoted = 'C:\Windows\system32\cmd.exe /c ""' + $batch + '" "'
        Assert-Equal $batch (Get-MensorCadBatchCommandTarget -CommandLine $quoted -BatchPath $batch) 'La forma exacta del doble clic de Explorer debe reconocerse.'
        Assert-Equal $batch (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /c ' + $batch) -BatchPath $batch) 'La forma sin comillas extra debe reconocerse.'
        Assert-Equal $batch (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /d /c "' + $batch + '" -NoAnimation') -BatchPath $batch) 'Los argumentos del BAT no cambian el objetivo.'

        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine 'C:\Windows\system32\cmd.exe' -BatchPath $batch)) 'Un cmd interactivo sin /c no se debe ocultar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /k "' + $batch + '"') -BatchPath $batch)) 'cmd /k es una terminal existente y no se debe ocultar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine 'C:\Windows\system32\cmd.exe /c other.cmd' -BatchPath $batch)) 'Un /c de otro programa no se debe ocultar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine 'C:\Windows\system32\cmd.exe /c "C:\otro\Instalar.bat"' -BatchPath $batch)) 'Un Instalar.bat de otra carpeta no se debe ocultar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /c "' + $batch + '" & calc.exe') -BatchPath $batch)) 'Un comando compuesto no se debe ocultar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine 'C:\Windows\system32\cmd.exe "C:/c/work"' -BatchPath $batch)) 'Un /c dentro de una ruta entre comillas no es un interruptor.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine ('C:\Windows\system32\cmd.exe /cfoo "' + $batch + '"') -BatchPath $batch)) 'Un interruptor /cfoo no es /c.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine '' -BatchPath $batch)) 'Sin linea de comandos no se debe ocultar.'
        Assert-True ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine $quoted -BatchPath 'C:\otro\Instalar.bat')) 'La comparacion debe ser con el BAT de la raiz del script.'
    }

    Test-Case 'Una terminal cmd abierta por Explorer no se oculta (B1)' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            $expectedArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:InstallerPath + '" -ElevatedProcess -NoAnimation'
            # Misma topologia que el doble clic (dos clientes, cmd hijo de
            # explorer) pero una terminal ya abierta por el usuario.
            $interactiveLines = @(
                'C:\Windows\system32\cmd.exe',
                'C:\Windows\system32\cmd.exe /k',
                'C:\Windows\system32\cmd.exe /c other.cmd',
                ('C:\Windows\system32\cmd.exe /k "' + $batch + '"')
            )
            foreach ($line in $interactiveLines) {
                Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLine $line
                $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation 6>$null }
                Assert-Equal 7 $result.ExitCode ('La terminal existente debe conservar el codigo de salida: ' + $line)
                Assert-Equal 'lanzar' (Get-WindowEvents) ('Una terminal existente no se debe ocultar ni restaurar: ' + $line)
                Assert-Equal '' $result.StdErr ('Una terminal existente no debe cambiar stderr: ' + $line)
                Assert-Equal $expectedArguments $script:LaunchArguments ('El lanzamiento debe ser el mismo de antes: ' + $line)
                Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'La terminal existente no debe permitir escrituras.'
                Restore-WindowTestSeams
            }
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLineError 'acceso denegado'
            $unreadable = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation 6>$null }
            Assert-Equal 7 $unreadable.ExitCode 'Una linea de comandos ilegible debe conservar el codigo de salida.'
            Assert-Equal 'lanzar' (Get-WindowEvents) 'Una linea de comandos ilegible debe resolverse sin ocultar (fail-open).'
            Assert-Equal '' $unreadable.StdErr 'Una linea de comandos ilegible no debe cambiar stderr.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El doble clic cmd /c de este BAT si oculta y restaura' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $batch = Join-Path $source 'Instalar.bat'
            $line = 'C:\Windows\system32\cmd.exe /c ""' + $batch + '" "'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleTopology 'modeled' -CommandLine $line
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation 6>$null }
            Assert-Equal 7 $result.ExitCode 'El doble clic reconocido debe conservar el codigo de salida del proceso elevado.'
            Assert-Equal 'ocultar,lanzar,restaurar' (Get-WindowEvents) 'El doble clic reconocido debe ocultar antes de UAC y restaurar despues.'
            Assert-Equal '' $result.StdErr 'El doble clic reconocido no debe escribir en stderr.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'La elevacion no debe escribir en el destino.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'La sonda nativa Win32 compila y solo lee el estado de la consola' {
        $native = Get-MensorCadConsoleNativeType
        Assert-True ($null -ne $native) 'La declaracion Win32 debe compilar con Add-Type.'
        $first = Get-MensorCadConsoleProbe
        $second = Get-MensorCadConsoleProbe
        if ($null -ne $first) {
            Assert-True ($first.WindowHandle -ne [System.IntPtr]::Zero) 'La sonda debe informar un handle real cuando existe consola.'
            Assert-True (@($first.ProcessIds) -contains $PID) 'La sonda debe incluir el proceso actual entre los clientes de la consola.'
            Assert-True ($first.WindowHandle -eq $second.WindowHandle) 'La sonda es de solo lectura y no debe cambiar la ventana.'
            Assert-True ($first.WindowVisible -eq $second.WindowVisible) 'La sonda no debe alterar la visibilidad de la consola.'
        }
        # Sin handle valido el envoltorio de visibilidad no llama a ShowWindow y
        # nunca puede ocultar la consola real: solo informa que no pudo actuar.
        Assert-Equal $false (Set-MensorCadConsoleWindowVisible -WindowHandle ([System.IntPtr]::Zero) -Visible $false) 'Sin handle no se debe intentar ocultar nada.'
        Assert-Equal $false (Set-MensorCadConsoleWindowVisible -WindowHandle ([System.IntPtr]::Zero) -Visible $true) 'Sin handle no se debe intentar restaurar nada.'
    }

    Test-Case 'Consola dedicada: oculta, lanza UAC, restaura y conserva el codigo de salida' {
        $root = New-TestCaseRoot
        try {
            $null = Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root 'Install-MensorCAD.ps1') -Force
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $probe = New-WindowProbeScript -RootPath $root
            $result = Invoke-ChildInstaller -ScriptPath $probe -Arguments @('-Root', ('"' + $root + '"'))
            Assert-Equal 0 $result.ExitCode ('La sonda de ventana debe salir con 0. stderr: ' + $result.Stderr)
            $summaryPath = Join-Path $root 'window-probe.json'
            Assert-True (Test-Path -LiteralPath $summaryPath -PathType Leaf) 'La sonda debe escribir su resumen observable.'
            $summary = [System.IO.File]::ReadAllText($summaryPath) | ConvertFrom-Json
            Assert-Equal 7 ([int]$summary.ExitCode) 'La entrada publica debe conservar el codigo de salida del proceso elevado.'
            Assert-Equal 'descubrir,ocultar,lanzar,restaurar' ([string]$summary.Events) 'El orden debe ser descubrir, ocultar, lanzar UAC y restaurar.'
            Assert-Equal '' ($result.Stderr.Trim()) 'El camino de elevacion correcto no debe escribir en stderr.'
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
            Assert-Equal $expectedLines $actualLines 'El stdout del camino de elevacion debe ser el mismo de antes.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'La elevacion no debe escribir en el destino.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Cancelar UAC restaura la consola y falla con el mensaje exacto' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -Elevation 'cancel' -ConsoleWindow ([pscustomobject]@{ WindowHandle = [System.IntPtr]::new(4242) })
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation 6>$null }
            Assert-Equal 1 $result.ExitCode 'Cancelar UAC debe salir con codigo 1.'
            Assert-Equal 'descubrir,ocultar,lanzar,restaurar' (Get-WindowEvents) 'Cancelar UAC tambien debe restaurar la consola original.'
            $expectedError = 'ERROR: No se obtuvo elevacion mediante UAC. La instalacion no se realizo. Detalle: cancelado por el usuario' + [Environment]::NewLine
            Assert-Equal $expectedError $result.StdErr 'El error de cancelacion debe ser el mismo de antes.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'Cancelar UAC no debe escribir en el destino.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Un lanzamiento sin proceso restaura la consola y falla sin instalar' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -Elevation 'missing' -ConsoleWindow ([pscustomobject]@{ WindowHandle = [System.IntPtr]::new(4242) })
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation 6>$null }
            Assert-Equal 1 $result.ExitCode 'Un lanzamiento sin proceso debe salir con codigo 1.'
            Assert-Equal 'descubrir,ocultar,lanzar,restaurar' (Get-WindowEvents) 'Un lanzamiento fallido tambien debe restaurar la consola original.'
            $expectedError = 'ERROR: No se pudo iniciar el proceso elevado. La instalacion no se realizo.' + [Environment]::NewLine
            Assert-Equal $expectedError $result.StdErr 'El error de lanzamiento debe ser el mismo de antes.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'Un lanzamiento fallido no debe escribir en el destino.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Consola compartida: no oculta nada y conserva el codigo de salida' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ConsoleWindow $null
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation 6>$null }
            Assert-Equal 7 $result.ExitCode 'Sin consola dedicada el codigo de salida debe conservarse.'
            Assert-Equal 'descubrir,lanzar' (Get-WindowEvents) 'Sin consola dedicada se debe sondear y lanzar, en ese orden.'
            Assert-True ((Get-WindowEvents) -notmatch 'ocultar|restaurar') 'Una consola compartida nunca se debe ocultar.'
            Assert-Equal '' $result.StdErr 'El camino sin consola dedicada no debe escribir en stderr.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force -Recurse -ErrorAction SilentlyContinue).Count 'El camino sin consola dedicada no debe escribir en el destino.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Salida redirigida: la deteccion real no oculta nada' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            # Sin costura de deteccion: se ejercita la cadena real de guardas.
            # Esta prueba corre con la salida redirigida, asi que la deteccion
            # debe resolverse como no concluyente y no ocultar nada.
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -RealDiscovery
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation 6>$null }
            Assert-Equal 7 $result.ExitCode 'Con salida redirigida el codigo de salida debe conservarse.'
            Assert-Equal 'lanzar' (Get-WindowEvents) 'Con salida redirigida no se debe ocultar ni restaurar la consola.'
            $expectedArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:InstallerPath + '" -ElevatedProcess -NoAnimation'
            Assert-Equal $expectedArguments $script:LaunchArguments 'El lanzamiento debe conservar los mismos argumentos.'
            Assert-Equal '' $result.StdErr 'La salida redirigida no debe escribir en stderr.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Camino ya elevado y ayuda no tocan la consola' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -Administrator
            $installExit = Invoke-MensorCadCli -NoAnimation 6>$null
            Assert-Equal 0 $installExit 'La instalacion sin UAC debe seguir saliendo con codigo 0.'
            $destination = Join-Path $programFiles 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json') -PathType Leaf) 'La instalacion sin UAC debe seguir escribiendo la marca.'
            Assert-Equal '' (Get-WindowEvents) 'El camino ya elevado no debe sondear ni tocar la ventana.'

            $uninstallResult = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -Uninstall 6>$null }
            Assert-Equal 0 $uninstallResult.ExitCode 'La desinstalacion sin UAC debe seguir saliendo con codigo 0.'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'La desinstalacion sin UAC debe seguir eliminando el bundle.'
            Assert-Equal '' (Get-WindowEvents) 'La desinstalacion sin UAC no debe sondear ni tocar la ventana.'

            $helpExit = Invoke-MensorCadCli -Help -NoAnimation 6>$null
            Assert-Equal 0 $helpExit 'La ayuda debe seguir saliendo con codigo 0.'
            Assert-Equal '' (Get-WindowEvents) 'La ayuda no debe sondear ni tocar la ventana.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Desinstalacion con UAC comparte el ayudante y conserva el codigo' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $destination = Join-Path $programFiles 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -Administrator
            Assert-Equal 0 (Invoke-MensorCadCli -NoAnimation 6>$null) 'La instalacion de preparacion debe salir con codigo 0.'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json') -PathType Leaf) 'La preparacion debe crear la marca.'
            Assert-Equal '' (Get-WindowEvents) 'La preparacion no debe tocar la ventana.'

            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ElevatedExitCode 7 -ConsoleWindow ([pscustomobject]@{ WindowHandle = [System.IntPtr]::new(4242) })
            $result = Invoke-CliCapturingError -Action { Invoke-MensorCadCli -NoAnimation -Uninstall 6>$null }
            Assert-Equal 7 $result.ExitCode 'La desinstalacion elevada debe conservar el codigo del proceso elevado.'
            Assert-Equal 'descubrir,ocultar,lanzar,restaurar' (Get-WindowEvents) 'La desinstalacion elevada debe ocultar y restaurar en el mismo orden.'
            Assert-True ($script:LaunchArguments -match '-ElevatedProcess -Uninstall -NoAnimation') 'La relanzada debe conservar los argumentos de desinstalacion.'
            Assert-Equal '' $result.StdErr 'La relanzada de desinstalacion no debe escribir en stderr.'
            Assert-True (Test-Path -LiteralPath $destination -PathType Container) 'La relanzada simulada no debe borrar el destino.'
        }
        finally {
            Restore-WindowTestSeams
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El hijo remoto no oculta la consola ni cambia su codigo de salida' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root
            $programFiles = Join-Path $root 'PF'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            Set-WindowTestSeams -SourceRoot $source -ProgramFilesRoot $programFiles -ChildExitCode 3
            $result = Invoke-MensorCadRemoteChild -ScriptPath $script:InstallerPath -Arguments @('-NoAnimation') -StdOutPath (Join-Path $root 'child.stdout.log') -StdErrPath (Join-Path $root 'child.stderr.log')
            Assert-Equal 3 ([int]$result.ExitCode) 'El hijo remoto debe conservar su codigo de salida.'
            $events = Get-WindowEvents
            Assert-True ($events -notmatch 'descubrir|ocultar|restaurar') 'El hijo remoto no debe sondear ni ocultar ninguna consola.'
            Assert-Equal 'lanzar-hijo' $events 'El hijo remoto debe seguir lanzandose con Start-Process.'
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
