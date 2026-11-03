#requires -Version 5.1
<#
    Sonda manual del backend REAL de registro del bootstrap del gestor.

    Comprueba el fallo reportado por el usuario: el proveedor de PowerShell
    entrega HKCU:\Environment en SOLO LECTURA, asi que .SetValue fallaba con
    "No se puede escribir en la clave del Registro" y la instalacion se
    revertia. La sonda exige el comportamiento corregido: el bootstrap abre un
    asa propia con acceso de escritura sobre la clave que entrega el proveedor,
    sin cambiar permisos ni pedir elevacion, y cierra esa asa siempre.

    Esta sonda NO forma parte de la suite por defecto ni de CI: se ejecuta a
    mano y escribe de verdad en el registro, siempre dentro de la unica clave
    privada autorizada por el usuario:

      HKCU:\Software\MensorCAD-Bootstrap-Probe

    Reglas de aislamiento:
      - si la clave ya existe, la sonda se detiene SIN TOCARLA;
      - solo escribe valores ficticios dentro de esa clave privada;
      - no escribe en HKCU\Environment, no toca el PATH real, no toca HKLM, no
        cambia ACLs, no pide UAC, no llama a la red y no abre AutoCAD;
      - TEMP, LOCALAPPDATA y la entrada -LocalZip viven en el scratch ignorado
        odd/artifacts/bootstrap-registry-writable;
      - al terminar, en exito o en fallo, cierra sus asas y elimina unicamente
        la clave que creo esta corrida, y comprueba que quedo ausente.

    La costura Get-Item del proceso hijo redirige SOLO las lecturas de
    HKCU:\Environment a esa clave privada y devuelve el asa REAL del proveedor
    (solo lectura): no hay registro falso, ni permisos simulados, ni escrituras
    fuera de la clave privada.

    Limite conocido: el proceso hijo mide el recuento de asas antes y despues de
    varias corridas. Un asa propia sin cerrar se acumularia una vez por corrida;
    el contrato exacto de cierre se comprueba ademas en la suite con registro
    simulado (tests/Test-CliBootstrap.ps1), donde un asa cerrada rechaza
    cualquier uso posterior.

    Ejecucion manual:
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/Test-CliBootstrapRegistry.ps1
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'SKIP: esta sonda requiere Windows PowerShell 5.1.' -ForegroundColor Yellow
    exit 2
}
if (($PSVersionTable.PSVersion.Major -ne 5) -or ([string]$PSVersionTable.PSEdition -ne 'Desktop')) {
    Write-Host 'ERROR: esta sonda requiere Windows PowerShell 5.1 Desktop.' -ForegroundColor Red
    exit 1
}

$script:Passed = 0
$script:Failed = 0
$script:FailureMessages = @()
$script:Utf8 = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:BootstrapPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'install.ps1'
$script:PowerShellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
$script:ScratchRoot = Join-Path -Path $script:RepositoryRoot -ChildPath 'odd\artifacts\bootstrap-registry-writable'
$script:RunRoot = Join-Path -Path $script:ScratchRoot -ChildPath ('run-' + [guid]::NewGuid().ToString('N'))
# Unica clave de registro autorizada para esta sonda. Nunca se parametriza.
$script:ProbeKeyPath = 'HKCU:\Software\MensorCAD-Bootstrap-Probe'
$script:ProbeKeyOwned = $false
$script:ProbeKeyRemoved = $false
$script:CleanupError = ''
$script:ReadOnlyError = ''
$script:ExpectedReadOnlyError = ''
$script:RealPathBefore = $null
$script:RealPathAfter = $null
$script:RunnerPath = Join-Path -Path $script:RunRoot -ChildPath 'runner.ps1'
$script:LocalAppData = Join-Path -Path $script:RunRoot -ChildPath 'localappdata'
$script:TempDir = Join-Path -Path $script:RunRoot -ChildPath 'temp'
$script:Entrada = Join-Path -Path $script:RunRoot -ChildPath 'entrada'
$script:ZipPath = Join-Path -Path $script:Entrada -ChildPath 'MensorCAD-CLI.zip'
$script:Destination = Join-Path -Path $script:LocalAppData -ChildPath 'MensorCAD\cli'
$script:ChildEnvironmentNames = @(
    'MCBR_BOOTSTRAP', 'MCBR_ZIP', 'MCBR_RESULT', 'MCBR_SCENARIO', 'MCBR_RUNS',
    'MCBR_MODE', 'MCBR_KEY', 'MCBR_TEMP', 'MCBR_LOCALAPPDATA'
)

if (-not (Test-Path -LiteralPath $script:BootstrapPath -PathType Leaf)) {
    Write-Host ("ERROR: no se encontro el bootstrap en '" + $script:BootstrapPath + "'.") -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $script:PowerShellPath -PathType Leaf)) {
    Write-Host ("ERROR: no se encontro Windows PowerShell en '" + $script:PowerShellPath + "'.") -ForegroundColor Red
    exit 1
}

# Guarda de aislamiento: la clave privada no puede existir antes de la sonda.
# Si existe, es de otra persona o de otra corrida y NO se toca.
if (Test-Path -LiteralPath $script:ProbeKeyPath) {
    Write-Host ('ERROR: la clave privada ' + $script:ProbeKeyPath + ' ya existe.') -ForegroundColor Red
    Write-Host 'La sonda se detiene sin tocarla: solo crea y elimina su propia clave.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Proceso hijo: costura Get-Item hacia la clave privada, red cerrada y
# captura de resultados. Se ejecuta con PowerShell 5.1 aparte para que el
# bootstrap no cierre esta sesion y para medir asas del proceso real.
# ---------------------------------------------------------------------------
$runnerTemplate = @'
param()
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$bootstrapPath = [string]$env:MCBR_BOOTSTRAP
$zipPath = [string]$env:MCBR_ZIP
$resultPath = [string]$env:MCBR_RESULT
$scenario = [string]$env:MCBR_SCENARIO
$runs = [int]$env:MCBR_RUNS
$mode = [string]$env:MCBR_MODE
$probeKeyPath = [string]$env:MCBR_KEY

$env:TEMP = [string]$env:MCBR_TEMP
$env:TMP = [string]$env:MCBR_TEMP
$env:LOCALAPPDATA = [string]$env:MCBR_LOCALAPPDATA

# Estado de la costura en ambito global: el bootstrap activa StrictMode en su
# propio ambito y $script: apuntaria a ese otro archivo.
$global:McbrKeyRequests = New-Object 'System.Collections.Generic.List[string]'
$global:McbrApiCalls = New-Object 'System.Collections.Generic.List[string]'
$global:McbrWebRequests = New-Object 'System.Collections.Generic.List[string]'

function global:Get-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$LiteralPath,
        [Parameter(Position = 1)][string]$Path,
        [switch]$Force
    )
    $target = $LiteralPath
    if ([string]::IsNullOrEmpty($target)) { $target = $Path }
    if (($target -eq 'HKCU:\Environment') -or ($target -eq 'HKCU:\Environment\')) {
        # Unica redireccion de la costura: la clave privada autorizada. El asa
        # que se devuelve es la REAL del proveedor, en solo lectura, igual que
        # con HKCU:\Environment.
        $global:McbrKeyRequests.Add([string]$target)
        return Microsoft.PowerShell.Management\Get-Item -LiteralPath $probeKeyPath -Force
    }
    Microsoft.PowerShell.Management\Get-Item -LiteralPath $target -Force:$Force
}

function global:Invoke-RestMethod {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    throw 'RED PROHIBIDA: la sonda de registro no debe consultar la API.'
}
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    throw 'RED PROHIBIDA: la sonda de registro no debe descargar ningun asset.'
}
# Los cmdlets del proveedor no se usan en el bootstrap; si aparecieran, la
# sonda lo informa en voz alta en lugar de escribir en silencio.
function global:Set-ItemProperty {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    throw 'Set-ItemProperty no debe usarse en el bootstrap.'
}
function global:New-ItemProperty {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    throw 'New-ItemProperty no debe usarse en el bootstrap.'
}
function global:Remove-ItemProperty {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    throw 'Remove-ItemProperty no debe usarse en el bootstrap.'
}

# stdout y stderr redirigidos se escriben en UTF-8 para comparar el mensaje
# exacto del error real, que lleva acentos.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$handleCounts = @()
$exitCodes = @()
$errors = @()
$lastExit = 'null'
$handleCounts += [int](Get-Process -Id $PID).HandleCount
for ($iteration = 1; $iteration -le $runs; $iteration++) {
    $global:LASTEXITCODE = 0
    try {
        if ($mode -eq 'invalid-tag') {
            # Linea base de asas: falla antes de tocar el registro.
            & $bootstrapPath -Version 'v1.2.3/malo'
        }
        else {
            & $bootstrapPath -LocalZip $zipPath
        }
    }
    catch {
        $errors += [string]$_.Exception.Message
    }
    if ($null -ne $global:LASTEXITCODE) { $lastExit = [string]$global:LASTEXITCODE }
    $exitCodes += [string]$lastExit
    $handleCounts += [int](Get-Process -Id $PID).HandleCount
}

# Lectura del estado final con un asa NUEVA del proveedor (solo lectura).
$afterKey = Microsoft.PowerShell.Management\Get-Item -LiteralPath $probeKeyPath -Force
$valueNames = @($afterKey.GetValueNames())
$pathName = ''
foreach ($name in $valueNames) { if ([string]$name -ieq 'Path') { $pathName = [string]$name } }
$pathValue = ''
$pathKind = ''
if (-not [string]::IsNullOrEmpty($pathName)) {
    $raw = $afterKey.GetValue($pathName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -ne $raw) { $pathValue = [string]$raw }
    $pathKind = [string]$afterKey.GetValueKind($pathName)
}
$otherValue = ''
$otherKind = ''
if (@($valueNames).Count -gt 0) {
    foreach ($name in $valueNames) {
        if ([string]$name -ieq 'SondaMensorCAD') {
            $otherValue = [string]$afterKey.GetValue($name)
            $otherKind = [string]$afterKey.GetValueKind($name)
        }
    }
}
$afterKey.Close()

$payload = [pscustomobject]@{
    Scenario = $scenario
    CommandError = ($errors -join ' | ')
    LastExitCode = $lastExit
    ExitCodes = @($exitCodes)
    KeyRequests = @($global:McbrKeyRequests.ToArray())
    ApiCalls = @($global:McbrApiCalls.ToArray())
    WebRequests = @($global:McbrWebRequests.ToArray())
    HandleCounts = @($handleCounts)
    PathName = $pathName
    PathValue = $pathValue
    PathKind = $pathKind
    OtherValue = $otherValue
    OtherKind = $otherKind
    ValueNames = @($valueNames)
}
[System.IO.File]::WriteAllText($resultPath, ($payload | ConvertTo-Json -Compress -Depth 6), $utf8)
exit 0
'@

# ---------------------------------------------------------------------------
# Utilidades de la sonda
# ---------------------------------------------------------------------------

function Write-FixtureFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw ('ASSERT: ' + $Message) }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw ('ASSERT: ' + $Message + ' (esperado: [' + [string]$Expected + '], actual: [' + [string]$Actual + '])')
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

function New-ProbeZip {
    # ZIP fixture real del gestor en la entrada local, con su sidecar adjunto.
    # El mensorcad.ps1 lleva una version sellada como texto: el bootstrap debe
    # leerla sin ejecutar el archivo.
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $managerText = "param()`r`n`$script:MensorCadManagerVersion = '1.2.3'`r`n"
    $entries = @(
        @{ Name = 'mensorcad.ps1'; Content = $managerText },
        @{ Name = 'mensorcad.cmd'; Content = "@echo off`r`nexit /b 0`r`n" },
        @{ Name = 'Install-MensorCAD.ps1'; Content = $managerText }
    )
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($definition in $entries) {
                $zipEntry = $archive.CreateEntry([string]$definition.Name, [System.IO.Compression.CompressionLevel]::Optimal)
                $bytes = $script:Utf8.GetBytes([string]$definition.Content)
                $target = $zipEntry.Open()
                try { $target.Write($bytes, 0, $bytes.Length) }
                finally { $target.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureFile -Path ($Path + '.sha256') -Content ($hash + '  MensorCAD-CLI.zip' + "`n")
}

function Get-RealUserPath {
    # Lectura del PATH real del usuario: solo lectura, con el asa del proveedor
    # nueva y cerrada al terminar. Esta sonda nunca escribe ahi.
    $key = Microsoft.PowerShell.Management\Get-Item -LiteralPath 'HKCU:\Environment' -Force
    try {
        $names = @($key.GetValueNames())
        $pathName = ''
        foreach ($name in $names) { if ([string]$name -ieq 'Path') { $pathName = [string]$name } }
        if ([string]::IsNullOrEmpty($pathName)) {
            return [pscustomobject]@{ Name = ''; Value = ''; Kind = 'missing' }
        }
        $raw = $key.GetValue($pathName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject]@{
            Name = $pathName
            Value = [string]$raw
            Kind = [string]$key.GetValueKind($pathName)
        }
    }
    finally {
        $key.Close()
    }
}

function Set-ProbePathValue {
    # Escritura ficticia dentro de la clave privada: la sonda abre su propia asa
    # de escritura y la cierra. El bootstrap lee y escribe la misma clave.
    param([string]$Value, [string]$Kind)
    $provider = Get-Item -LiteralPath $script:ProbeKeyPath -Force
    $owned = $null
    try {
        $owned = $provider.OpenSubKey('', $true)
        $owned.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]([string]$Kind))
    }
    finally {
        if ($null -ne $owned) { $owned.Close() }
        $provider.Close()
    }
}

function Get-ProbeState {
    # Estado observado de la clave privada con un asa nueva del proveedor.
    $key = Get-Item -LiteralPath $script:ProbeKeyPath -Force
    try {
        $names = @($key.GetValueNames())
        $pathName = ''
        foreach ($name in $names) { if ([string]$name -ieq 'Path') { $pathName = [string]$name } }
        $pathValue = ''
        $pathKind = ''
        if (-not [string]::IsNullOrEmpty($pathName)) {
            $raw = $key.GetValue($pathName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $raw) { $pathValue = [string]$raw }
            $pathKind = [string]$key.GetValueKind($pathName)
        }
        return [pscustomobject]@{
            ValueNames = @($names)
            PathName = $pathName
            PathValue = $pathValue
            PathKind = $pathKind
        }
    }
    finally {
        $key.Close()
    }
}

function Invoke-ProbeRun {
    # Ejecuta el bootstrap publico en un proceso hijo con la costura Get-Item
    # apuntando solo a la clave privada. La red queda cerrada en la costura.
    param([string]$Scenario, [int]$Runs = 1, [string]$Mode = 'local')
    $resultPath = Join-Path -Path $script:RunRoot -ChildPath ('result-' + $Scenario + '.json')
    $stdoutPath = Join-Path -Path $script:RunRoot -ChildPath ('stdout-' + $Scenario + '.txt')
    $stderrPath = Join-Path -Path $script:RunRoot -ChildPath ('stderr-' + $Scenario + '.txt')
    $env:MCBR_BOOTSTRAP = $script:BootstrapPath
    $env:MCBR_ZIP = $script:ZipPath
    $env:MCBR_RESULT = $resultPath
    $env:MCBR_SCENARIO = $Scenario
    $env:MCBR_RUNS = [string]$Runs
    $env:MCBR_MODE = $Mode
    $env:MCBR_KEY = $script:ProbeKeyPath
    $env:MCBR_TEMP = $script:TempDir
    $env:MCBR_LOCALAPPDATA = $script:LocalAppData
    try {
        $process = Start-Process -FilePath $script:PowerShellPath `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:RunnerPath)) `
            -WorkingDirectory $env:SystemRoot -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    }
    finally {
        foreach ($name in $script:ChildEnvironmentNames) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        }
    }
    $stdout = ''
    $stderr = ''
    if ([System.IO.File]::Exists($stdoutPath)) { $stdout = [System.IO.File]::ReadAllText($stdoutPath).Replace("`r`n", "`n") }
    if ([System.IO.File]::Exists($stderrPath)) { $stderr = [System.IO.File]::ReadAllText($stderrPath).Replace("`r`n", "`n") }
    $result = $null
    if ([System.IO.File]::Exists($resultPath)) { $result = ([System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json) }
    return [pscustomobject]@{
        Scenario = $Scenario
        ProcessExitCode = [int]$process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
        Result = $result
    }
}

function Get-SuccessStdout {
    param([string]$State, [switch]$PathAlreadyRegistered)
    $lines = @('MensorCAD: gestor ' + $State + ' en ' + $script:Destination)
    if ($PathAlreadyRegistered) {
        $lines += 'El PATH de usuario ya incluia la carpeta del gestor; no se agrego de nuevo.'
    }
    else {
        $lines += 'PATH de usuario actualizado: abra una terminal nueva y ejecute "mensorcad --help". Otras terminales abiertas necesitan reiniciarse.'
    }
    $lines += 'Siguiente paso: "mensorcad install" instala el complemento para AutoCAD.'
    return (($lines -join "`n") + "`n")
}

function Assert-RunFinished {
    param($Run)
    Assert-Equal 0 $Run.ProcessExitCode 'el proceso hijo de la sonda debe terminar con 0'
    Assert-True ($null -ne $Run.Result) 'el proceso hijo de la sonda no dejo resultado'
    Assert-Equal '' ([string]$Run.Result.CommandError) 'el comando no debe lanzar una excepcion sin capturar'
    Assert-Equal 0 (@($Run.Result.ApiCalls).Count) 'la sonda de registro no consulta la API'
    Assert-Equal 0 (@($Run.Result.WebRequests).Count) 'la sonda de registro no descarga nada'
}

function Assert-BootstrapSucceeded {
    # Si el bootstrap falla, distingue el ROJO buscado (el asa real del
    # proveedor rechaza la escritura) de cualquier otro fallo.
    param($Run)
    Assert-RunFinished -Run $Run
    if ([string]$Run.Result.LastExitCode -ne '0') {
        $stderr = $Run.Stderr.TrimEnd()
        if ($stderr -eq $script:ExpectedReadOnlyError) {
            throw ('ROJO: el PATH real no se puede escribir con el asa de solo lectura del proveedor -> ' + $stderr)
        }
        throw ('el bootstrap publico fallo en el escenario ' + $Run.Scenario + ' -> ' + $stderr)
    }
    Assert-Equal '' $Run.Stderr ('el exito no debe escribir stderr (' + $Run.Scenario + ')')
}

function Assert-NoTempLeftovers {
    Assert-True ([System.IO.Directory]::Exists($script:TempDir)) 'la carpeta temporal de la sonda debe existir'
    foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($script:TempDir)) {
        $name = [System.IO.Path]::GetFileName($entry)
        Assert-False ($name -like 'mensorcad-cli-*') ('quedo la carpeta temporal propia: ' + $name)
    }
}

function Assert-NoStagingLeftovers {
    $managedRoot = Join-Path -Path $script:LocalAppData -ChildPath 'MensorCAD'
    foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($managedRoot)) {
        $name = [System.IO.Path]::GetFileName($entry)
        Assert-False ($name -like 'cli.staging-*') ('quedo una carpeta de staging: ' + $name)
        Assert-False ($name -like 'cli.backup-*') ('quedo una carpeta de respaldo: ' + $name)
    }
}

# ---------------------------------------------------------------------------
# Preparacion del aislamiento: scratch propio, fixtures locales y clave privada
# ---------------------------------------------------------------------------
$null = [System.IO.Directory]::CreateDirectory($script:ScratchRoot)
$null = [System.IO.Directory]::CreateDirectory($script:RunRoot)
Write-FixtureFile -Path $script:RunnerPath -Content $runnerTemplate
foreach ($directory in @($script:LocalAppData, $script:TempDir, $script:Entrada)) {
    $null = [System.IO.Directory]::CreateDirectory($directory)
}
New-ProbeZip -Path $script:ZipPath

Write-Host ''
Write-Host 'Sonda REAL de registro (manual). Clave privada autorizada:' -ForegroundColor Cyan
Write-Host ('  ' + $script:ProbeKeyPath)
Write-Host '  no se escribe en HKCU\Environment, no se toca HKLM y no hay red.'

# ---------------------------------------------------------------------------
# Casos
# ---------------------------------------------------------------------------
try {
    $null = New-Item -Path $script:ProbeKeyPath -Force
    $script:ProbeKeyOwned = $true
    Set-ProbePathValue -Value 'C:\Windows;%LOCALAPPDATA%\WindowsPowerShell' -Kind 'ExpandString'
    $probeProvider = Get-Item -LiteralPath $script:ProbeKeyPath -Force
    $probeOwned = $probeProvider.OpenSubKey('', $true)
    try {
        $probeOwned.SetValue('SondaMensorCAD', 'valor ficticio', [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $probeOwned.Close()
        $probeProvider.Close()
    }
    $script:RealPathBefore = Get-RealUserPath

    Test-Case 'premisa: el asa que entrega el proveedor es de solo lectura' {
        $provider = Get-Item -LiteralPath $script:ProbeKeyPath -Force
        try {
            $thrown = ''
            try {
                $provider.SetValue('Path', 'no debe escribirse', [Microsoft.Win32.RegistryValueKind]::ExpandString)
            }
            catch {
                $thrown = [string]$_.Exception.Message
            }
            Assert-True ($thrown.Length -gt 0) 'el asa del proveedor debe rechazar la escritura directa'
            Assert-True ($thrown.Contains('No se puede escribir en la clave del Registro')) ('el error real del asa de solo lectura debe ser el reportado por el usuario; se obtuvo: ' + $thrown)
            $script:ReadOnlyError = $thrown
            $script:ExpectedReadOnlyError = 'ERROR: No se pudo registrar la carpeta del gestor en el PATH del usuario: ' + $thrown + ' Se restauro la instalacion anterior.'
        }
        finally {
            $provider.Close()
        }
        $state = Get-ProbeState
        Assert-Equal 'C:\Windows;%LOCALAPPDATA%\WindowsPowerShell' $state.PathValue 'el intento fallido no debe cambiar el PATH de la sonda'
        Assert-Equal 'ExpandString' $state.PathKind 'el tipo del PATH de la sonda no debe cambiar'
    }

    Test-Case 'el bootstrap publico escribe el PATH con un asa propia de escritura' {
        $run = Invoke-ProbeRun -Scenario 'write'
        Assert-BootstrapSucceeded -Run $run
        Assert-Equal (Get-SuccessStdout -State 'instalado') $run.Stdout 'stdout exacto del exito real'
        Assert-Equal 1 (@($run.Result.KeyRequests).Count) 'el bootstrap debe pedir la clave del usuario una vez'
        Assert-Equal 'HKCU:\Environment' ([string](@($run.Result.KeyRequests)[0])) 'la costura solo redirige HKCU:\Environment'
        $expectedPath = 'C:\Windows;%LOCALAPPDATA%\WindowsPowerShell;' + $script:Destination
        $state = Get-ProbeState
        Assert-Equal 'Path' $state.PathName 'el nombre del valor no debe cambiar'
        Assert-Equal $expectedPath $state.PathValue 'el PATH real de la sonda conserva el contenido literal sin expandir'
        Assert-Equal 'ExpandString' $state.PathKind 'se conserva REG_EXPAND_SZ en el registro real'
        Assert-True ($state.PathValue.Contains('%LOCALAPPDATA%')) 'la variable literal %LOCALAPPDATA% sigue sin expandirse'
        Assert-Equal 'valor ficticio' ([string]$run.Result.OtherValue) 'el bootstrap no debe tocar otros valores de la clave'
        Assert-Equal 'String' ([string]$run.Result.OtherKind) 'el otro valor conserva su tipo'
        Assert-Equal 4 (@([System.IO.Directory]::GetFileSystemEntries($script:Destination)).Count) 'el gestor instalado tiene tres archivos y el marcador'
        $marker = ([System.IO.File]::ReadAllText((Join-Path -Path $script:Destination -ChildPath '.mensorcad-cli.json')) | ConvertFrom-Json)
        Assert-Equal '1.2.3' ([string]$marker.version) 'el marcador guarda la version del ZIP local'
        Assert-NoTempLeftovers
        Assert-NoStagingLeftovers
    }

    Test-Case 'repetir el bootstrap no duplica el PATH real' {
        Set-ProbePathValue -Value 'C:\Windows;%LOCALAPPDATA%\MensorCAD\cli' -Kind 'ExpandString'
        $run = Invoke-ProbeRun -Scenario 'noop'
        Assert-BootstrapSucceeded -Run $run
        Assert-Equal (Get-SuccessStdout -State 'actualizado' -PathAlreadyRegistered) $run.Stdout 'stdout exacto del no-op'
        $state = Get-ProbeState
        Assert-Equal 'C:\Windows;%LOCALAPPDATA%\MensorCAD\cli' $state.PathValue 'una entrada equivalente con %LOCALAPPDATA% no se duplica ni se expande'
        Assert-Equal 'ExpandString' $state.PathKind 'el no-op conserva el tipo'
        Assert-NoTempLeftovers
        Assert-NoStagingLeftovers
    }

    Test-Case 'el bootstrap conserva REG_SZ en el registro real' {
        Set-ProbePathValue -Value 'C:\Windows;%USERPROFILE%\bin' -Kind 'String'
        $run = Invoke-ProbeRun -Scenario 'regsz'
        Assert-BootstrapSucceeded -Run $run
        Assert-Equal (Get-SuccessStdout -State 'actualizado') $run.Stdout 'stdout exacto del exito con REG_SZ'
        $state = Get-ProbeState
        Assert-Equal ('C:\Windows;%USERPROFILE%\bin;' + $script:Destination) $state.PathValue 'el PATH con REG_SZ recibe la carpeta al final'
        Assert-Equal 'String' $state.PathKind 'REG_SZ sigue siendo REG_SZ'
        Assert-True ($state.PathValue.Contains('%USERPROFILE%')) 'las variables del usuario no se expanden'
        Assert-NoTempLeftovers
        Assert-NoStagingLeftovers
    }

    Test-Case 'un tipo de PATH no soportado se rechaza y se revierte' {
        $multiValue = [string[]]@('C:\Windows', 'C:\Herramientas')
        $provider = Get-Item -LiteralPath $script:ProbeKeyPath -Force
        $owned = $null
        try {
            $owned = $provider.OpenSubKey('', $true)
            $owned.SetValue('Path', $multiValue, [Microsoft.Win32.RegistryValueKind]::MultiString)
        }
        finally {
            if ($null -ne $owned) { $owned.Close() }
            $provider.Close()
        }
        $before = Get-ProbeState
        Assert-Equal 'MultiString' $before.PathKind 'la fixture debe quedar como REG_MULTI_SZ'
        $run = Invoke-ProbeRun -Scenario 'unsupported'
        Assert-RunFinished -Run $run
        Assert-Equal '1' ([string]$run.Result.LastExitCode) 'un tipo no soportado debe fallar'
        Assert-Equal ('ERROR: El PATH del usuario tiene un tipo no soportado: MultiString. Se restauro la instalacion anterior.' + "`n") $run.Stderr 'stderr exacto del rechazo'
        Assert-Equal '' $run.Stdout 'un fallo no debe escribir stdout'
        $after = Get-ProbeState
        Assert-Equal 'MultiString' $after.PathKind 'el tipo del PATH no cambia'
        Assert-Equal $before.PathValue $after.PathValue 'el contenido del PATH no cambia'
        $marker = ([System.IO.File]::ReadAllText((Join-Path -Path $script:Destination -ChildPath '.mensorcad-cli.json')) | ConvertFrom-Json)
        Assert-Equal '1.2.3' ([string]$marker.version) 'la instalacion anterior vuelve intacta'
        Assert-NoTempLeftovers
        Assert-NoStagingLeftovers
    }

    Test-Case 'la ruta del PATH no acumula asas por corrida' {
        # El recuento de asas del proceso tiene ruido propio de PowerShell, asi
        # que se compara contra una linea base que falla antes de tocar el
        # registro: si el bootstrap dejara un asa abierta por corrida, la ruta
        # del PATH creceria al menos una asa por corrida MAS que la base.
        Set-ProbePathValue -Value 'C:\Windows;%LOCALAPPDATA%\MensorCAD\cli' -Kind 'ExpandString'
        $runs = 3
        $pathRun = Invoke-ProbeRun -Scenario 'handles' -Runs $runs
        Assert-RunFinished -Run $pathRun
        Assert-Equal '0' ([string]$pathRun.Result.LastExitCode) 'las tres corridas del no-op deben terminar bien'
        Assert-Equal 0 $pathRun.Stderr.Length 'las tres corridas del no-op no deben escribir stderr'
        $baselineRun = Invoke-ProbeRun -Scenario 'handles-base' -Runs $runs -Mode 'invalid-tag'
        Assert-RunFinished -Run $baselineRun
        Assert-Equal '1' ([string]$baselineRun.Result.LastExitCode) 'la linea base debe fallar antes del registro'
        Assert-Equal 0 (@($baselineRun.Result.KeyRequests).Count) 'la linea base no debe leer la clave del usuario'
        $pathCounts = @($pathRun.Result.HandleCounts)
        $baseCounts = @($baselineRun.Result.HandleCounts)
        Assert-Equal ($runs + 1) $pathCounts.Count 'la sonda debe medir asas antes y despues de cada corrida'
        Assert-Equal ($runs + 1) $baseCounts.Count 'la linea base debe medir asas antes y despues de cada corrida'
        $pathGrowth = [int]$pathCounts[$runs] - [int]$pathCounts[1]
        $baseGrowth = [int]$baseCounts[$runs] - [int]$baseCounts[1]
        Write-Host ('      asas con PATH: [' + ($pathCounts -join ', ') + '] crecimiento: ' + $pathGrowth)
        Write-Host ('      asas linea base: [' + ($baseCounts -join ', ') + '] crecimiento: ' + $baseGrowth)
        # La ventana mide dos corridas extra: un asa sin cerrar por corrida
        # sumaria dos asas sobre la linea base.
        Assert-True (($pathGrowth - $baseGrowth) -lt 2) ('la ruta del PATH no debe acumular un asa por corrida sobre la linea base; PATH: ' + $pathGrowth + ', base: ' + $baseGrowth)
        $state = Get-ProbeState
        Assert-Equal 'C:\Windows;%LOCALAPPDATA%\MensorCAD\cli' $state.PathValue 'el no-op repetido no cambia el PATH'
    }
}
catch {
    $script:Failed++
    $script:FailureMessages += ('sonda: ' + $_.Exception.Message)
    Write-Host ('FAIL: sonda -> ' + $_.Exception.Message) -ForegroundColor Red
}
finally {
    $script:RealPathAfter = $null
    try {
        $script:RealPathAfter = Get-RealUserPath
    }
    catch {
        $script:CleanupError += ('no se pudo leer el PATH real: ' + $_.Exception.Message + ' ')
    }
    if ($script:ProbeKeyOwned) {
        try {
            Remove-Item -LiteralPath $script:ProbeKeyPath -Recurse -Force
            $script:ProbeKeyOwned = $false
        }
        catch {
            $script:CleanupError += ('no se pudo eliminar la clave privada: ' + $_.Exception.Message)
        }
        $script:ProbeKeyRemoved = -not (Test-Path -LiteralPath $script:ProbeKeyPath)
    }
}

Test-Case 'la clave privada de la sonda no existe al terminar' {
    Assert-Equal '' $script:CleanupError 'la limpieza de la sonda no debe fallar'
    Assert-True $script:ProbeKeyRemoved 'la clave privada creada por esta corrida debe quedar eliminada'
    Assert-False (Test-Path -LiteralPath $script:ProbeKeyPath) 'la clave privada debe quedar ausente'
}

Test-Case 'la sonda no cambio el PATH real del usuario' {
    Assert-True ($null -ne $script:RealPathBefore) 'la sonda debe leer el PATH real antes de empezar'
    Assert-True ($null -ne $script:RealPathAfter) 'la sonda debe leer el PATH real al terminar'
    Assert-Equal ([string]$script:RealPathBefore.Name) ([string]$script:RealPathAfter.Name) 'el nombre del valor PATH real no cambia'
    Assert-Equal ([string]$script:RealPathBefore.Value) ([string]$script:RealPathAfter.Value) 'el contenido del PATH real del usuario no cambia'
    Assert-Equal ([string]$script:RealPathBefore.Kind) ([string]$script:RealPathAfter.Kind) 'el tipo del PATH real del usuario no cambia'
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('RESULTADO: ' + $script:Passed + ' correctas, ' + $script:Failed + ' fallidas.')
Write-Host ('Clave autorizada: ' + $script:ProbeKeyPath + ' (creada y eliminada por esta corrida: ' + $script:ProbeKeyRemoved + ')')
if ($script:ReadOnlyError.Length -gt 0) {
    Write-Host ('Error real del asa de solo lectura: ' + $script:ReadOnlyError)
}
if ($script:Failed -gt 0) {
    foreach ($message in $script:FailureMessages) { Write-Host ('FALLO: ' + $message) -ForegroundColor Red }
    Write-Host ('La carpeta de evidencias se conserva en ' + $script:RunRoot) -ForegroundColor Yellow
    exit 1
}

try {
    [System.IO.Directory]::Delete($script:RunRoot, $true)
}
catch {
    Write-Host ('AVISO: no se pudo limpiar ' + $script:RunRoot + ': ' + $_.Exception.Message) -ForegroundColor Yellow
}
exit 0
