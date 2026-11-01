#requires -Version 5.1
<#
    Pruebas funcionales del bootstrap corto install.ps1.

    Solo se ejecutan en Windows con Windows PowerShell 5.1. La red y el
    "servidor" se simulan con costuras locales y el proceso hijo real ejecuta un
    instalador fixture: estas pruebas nunca descargan de GitHub, nunca escriben
    en el destino fijo de la aplicacion, nunca abren AutoCAD y nunca piden UAC.

    El cuerpo ejecutado es el comando publicado, extraido de README.md y de
    docs/remote-installer.md. No hay una copia paralela del comando.

    Limite conocido: PowerShell siempre define $LASTEXITCODE despues de un
    proceso nativo, asi que la rama "estado ausente" no se puede provocar desde
    aqui. Se verifica en tests/test_bootstrap_structure.py; estas pruebas cubren
    hijo con 0, hijo con otro codigo y fallos de descarga o de argumentos.

    Ejecucion manual:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Bootstrap.ps1
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
$script:BootstrapPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'install.ps1'
$script:ReadmePath = Join-Path -Path $script:RepositoryRoot -ChildPath 'README.md'
$script:RemoteDocsPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'docs\remote-installer.md'
# Prefijo corto y GUID completo: deja lugar bajo MAX_PATH para la carpeta
# temporal propia que crea el bootstrap dentro de este arbol.
$script:TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('MCRB-' + [guid]::NewGuid().ToString('N'))
$script:PowerShellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
$script:ProbePath = Join-Path -Path $script:TestRoot -ChildPath 'probe.ps1'
$script:ProbeEnvironmentNames = @('MCRB_TEMP', 'MCRB_COMMAND_FILE', 'MCRB_BOOTSTRAP', 'MCRB_FIXTURE', 'MCRB_CHILD_EXIT', 'MCRB_CHILD_RESULT', 'MCRB_RESULT', 'MCRB_MODE')

if (-not (Test-Path -LiteralPath $script:BootstrapPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro el bootstrap en '$script:BootstrapPath'." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $script:PowerShellPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro Windows PowerShell en '$script:PowerShellPath'." -ForegroundColor Red
    exit 1
}

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

function Write-FixtureFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-DocumentedShortCommand {
    # Extrae el comando corto EXACTO publicado. Asi la prueba ejecuta el mismo
    # texto que copia un usuario y no una copia paralela que puede divergir.
    param([string]$Text, [string]$Kind = 'latest')
    $pattern = '^\s*irm ''https://github\.com/RonGrasz/Mensor-CAD/releases/latest/download/install\.ps1'' -ea Stop \| iex\s*$'
    if ($Kind -eq 'pinned') {
        $pattern = '^\s*&\(\[scriptblock\]::Create\(\(irm ''https://github\.com/RonGrasz/Mensor-CAD/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/install\.ps1'' -ea Stop\)\)\) -Version v[0-9]+\.[0-9]+\.[0-9_]+\s*$'
    }
    $found = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match $pattern) { $found += $line.Trim() }
    }
    if ($found.Count -ne 1) {
        throw ('Se esperaba exactamente un comando corto de tipo ' + $Kind + '; encontrados: ' + $found.Count)
    }
    return $found[0]
}

function New-FixtureInstallerSource {
    # Instalador fixture: registra sus argumentos y escribe en stdout/stderr
    # antes de salir con el codigo pedido. No toca el destino fijo, no pide UAC
    # y no abre AutoCAD; por eso el bootstrap solo puede probarse contra el.
    $template = @'
param(
    [switch]$FromRelease,
    [switch]$NoAnimation,
    [string]$Version
)
$ErrorActionPreference = 'Stop'
$resultRoot = $env:MCRB_CHILD_RESULT
$payload = [pscustomobject]@{
    FromRelease = [bool]$FromRelease
    NoAnimation = [bool]$NoAnimation
    Version = [string]$Version
}
$encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
[System.IO.File]::WriteAllText((Join-Path $resultRoot 'child-args.json'), ($payload | ConvertTo-Json -Compress), $encoding)
[Console]::Out.WriteLine('fixture stdout 1')
[Console]::Error.WriteLine('fixture stderr 1')
[Console]::Out.WriteLine('fixture stdout 2')
exit ([int]$env:MCRB_CHILD_EXIT)
'@
    return $template
}

function New-ProbeScript {
    # Proceso aparte que ejecuta el comando publicado tal cual. Reemplaza la
    # primera descarga (Invoke-RestMethod) y la descarga del instalador real
    # (Invoke-WebRequest) por costuras locales, y despues escribe sentinelas:
    # si el bootstrap hubiera llamado a exit, esas sentinelas no existirian.
    $template = @'
param()
$ErrorActionPreference = 'Continue'
$tempRoot = $env:MCRB_TEMP
$commandFile = $env:MCRB_COMMAND_FILE
$bootstrapPath = $env:MCRB_BOOTSTRAP
$fixturePath = $env:MCRB_FIXTURE
$resultPath = $env:MCRB_RESULT
$mode = $env:MCRB_MODE
$utf8 = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)

# Solo este proceso usa la carpeta temporal del caso, con espacios, apostrofes
# y Unicode en la ruta.
$env:TEMP = $tempRoot
$env:TMP = $tempRoot

$script:WebRequests = New-Object 'System.Collections.Generic.List[string]'
$script:RemoveCalls = New-Object 'System.Collections.Generic.List[string]'
$script:NewItemPath = $null
# Valor previo a proposito: la primera descarga ocurre antes del wrapper, asi
# que el wrapper no puede fijar $LASTEXITCODE y este 0 debe sobrevivir.
$global:LASTEXITCODE = 0

function global:New-Item {
    [CmdletBinding()]
    param([string]$ItemType, [Parameter(Position = 0)][string]$Path)
    $script:NewItemPath = [string]$Path
    if ($mode -eq 'workspace-collision') {
        # Simula una carpeta preexistente con contenido ajeno y hace fallar la
        # creacion exclusiva: el bootstrap no debe borrarla.
        $null = [System.IO.Directory]::CreateDirectory($Path)
        [System.IO.File]::WriteAllText((Join-Path $Path 'sentinel.txt'), 'contenido ajeno intacto', $utf8)
        throw ('New-Item simulado: la ruta ya existe: ' + $Path)
    }
    if ($mode -eq 'workspace-reparse') {
        $null = [System.IO.Directory]::CreateDirectory($Path)
        [System.IO.File]::WriteAllText((Join-Path $Path 'sentinel.txt'), 'contenido ajeno intacto', $utf8)
        return [pscustomobject]@{ FullName = [string]$Path }
    }
    Microsoft.PowerShell.Management\New-Item -ItemType $ItemType -Path $Path
}

function global:Get-Item {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$LiteralPath, [switch]$Force)
    if ($mode -eq 'workspace-reparse') {
        # La carpeta real existe; se informa como punto de reanalisis para
        # ejercitar el rechazo sin seguir ni borrar ningun destino.
        return [pscustomobject]@{
            FullName = [string]$LiteralPath
            Attributes = ([System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint)
        }
    }
    Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force
}

function global:Remove-Item {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$LiteralPath, [switch]$Recurse, [switch]$Force)
    $script:RemoveCalls.Add([string]$LiteralPath)
    if ($mode -eq 'workspace-collision' -or $mode -eq 'workspace-reparse') {
        # No se borra nada: la prueba verifica que el wrapper ni lo intenta.
        return
    }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force
}

function global:Invoke-RestMethod {
    [CmdletBinding()]
    param([switch]$UseBasicParsing, [Parameter(Position = 0)][string]$Uri)
    if ($mode -eq 'first-fetch-nonterminating') {
        Write-Error -Message ('403 simulado en la primera descarga: ' + $Uri)
        return
    }
    if ($mode -eq 'first-fetch-terminating') {
        throw ('404 simulado en la primera descarga: ' + $Uri)
    }
    return [System.IO.File]::ReadAllText($bootstrapPath)
}

function global:Invoke-WebRequest {
    [CmdletBinding()]
    param([switch]$UseBasicParsing, [Parameter(Position = 0)][string]$Uri, [string]$OutFile)
    $script:WebRequests.Add([string]$Uri)
    if ($mode -eq 'installer-nonterminating') {
        Write-Error -Message ('404 simulado al descargar el instalador: ' + $Uri)
        return
    }
    if ($mode -eq 'installer-terminating') {
        throw ('500 simulado al descargar el instalador: ' + $Uri)
    }
    if ($mode -eq 'installer-no-file') { return }
    Copy-Item -LiteralPath $fixturePath -Destination $OutFile -Force
}

$commandText = [System.IO.File]::ReadAllText($commandFile)
$script:CommandError = ''
try {
    & ([scriptblock]::Create($commandText))
}
catch {
    $script:CommandError = $_.Exception.Message
}

$lastExit = 'null'
if ($null -ne $LASTEXITCODE) { $lastExit = [string]$LASTEXITCODE }
$payload = [pscustomobject]@{
    CommandError = $script:CommandError
    LastExitCode = $lastExit
    WebRequests = @($script:WebRequests.ToArray())
    RemoveCalls = @($script:RemoveCalls.ToArray())
    NewItemPath = $script:NewItemPath
}
[System.IO.File]::WriteAllText($resultPath, ($payload | ConvertTo-Json -Compress -Depth 4), $utf8)
[System.IO.File]::WriteAllText((Join-Path $tempRoot 'survived.txt'), 'la sesion del llamador sobrevivio', $utf8)
exit 0
'@
    Write-FixtureFile -Path $script:ProbePath -Content $template
}

function Invoke-BootstrapCase {
    param(
        [string]$CommandText,
        [string]$Mode = 'normal',
        [int]$ChildExit = 0
    )
    $root = New-TestCaseRoot
    # Ruta con espacios, apostrofes y Unicode: el bootstrap debe citar bien el
    # -File del hijo y no romper la carpeta temporal.
    $tempDir = Join-Path -Path $root -ChildPath "temp espacios y apostrofes 'x' n-ñ"
    $null = New-Item -ItemType Directory -Path $tempDir -Force
    $commandFile = Join-Path -Path $root -ChildPath 'command.txt'
    Write-FixtureFile -Path $commandFile -Content $CommandText
    $fixturePath = Join-Path -Path $root -ChildPath 'fixture-installer.ps1'
    Write-FixtureFile -Path $fixturePath -Content (New-FixtureInstallerSource)
    $childResult = Join-Path -Path $root -ChildPath 'child'
    $null = New-Item -ItemType Directory -Path $childResult -Force
    $resultPath = Join-Path -Path $root -ChildPath 'result.json'
    $stdoutPath = Join-Path -Path $root -ChildPath 'probe.stdout.txt'
    $stderrPath = Join-Path -Path $root -ChildPath 'probe.stderr.txt'

    $env:MCRB_TEMP = $tempDir
    $env:MCRB_COMMAND_FILE = $commandFile
    $env:MCRB_BOOTSTRAP = $script:BootstrapPath
    $env:MCRB_FIXTURE = $fixturePath
    $env:MCRB_CHILD_EXIT = [string]$ChildExit
    $env:MCRB_CHILD_RESULT = $childResult
    $env:MCRB_RESULT = $resultPath
    $env:MCRB_MODE = $Mode
    try {
        $process = Start-Process -FilePath $script:PowerShellPath -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $script:ProbePath + '"') -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    }
    finally {
        foreach ($name in $script:ProbeEnvironmentNames) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        }
    }

    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $stdoutPath) { $stdout = [System.IO.File]::ReadAllText($stdoutPath) }
    if (Test-Path -LiteralPath $stderrPath) { $stderr = [System.IO.File]::ReadAllText($stderrPath) }
    $result = $null
    if (Test-Path -LiteralPath $resultPath) {
        $result = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
    }
    $childArgs = $null
    $childArgsPath = Join-Path -Path $childResult -ChildPath 'child-args.json'
    if (Test-Path -LiteralPath $childArgsPath) {
        $childArgs = [System.IO.File]::ReadAllText($childArgsPath) | ConvertFrom-Json
    }
    $workspaces = @(Get-ChildItem -LiteralPath $tempDir -Directory -Filter 'mensorcad-bootstrap-*' -ErrorAction SilentlyContinue)

    # Si ConvertFrom-Json entrega $null para una lista vacia, @($null) crearia
    # un arreglo de un elemento y .Count mentiria sobre los borrados reales.
    $removeCalls = @()
    if ($null -ne $result -and $null -ne $result.RemoveCalls) {
        $removeCalls = @($result.RemoveCalls)
    }

    return [pscustomobject]@{
        Root = $root
        Temp = $tempDir
        ProcessExitCode = [int]$process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
        Result = $result
        ChildArgs = $childArgs
        SurvivedPath = Join-Path -Path $tempDir -ChildPath 'survived.txt'
        Workspaces = $workspaces
        RemoveCalls = $removeCalls
        NewItemPath = $result.NewItemPath
    }
}

function Get-WebRequestUris {
    # PowerShell desenrolla la salida de una funcion: con `return @()` el
    # llamador recibe $null y con un solo elemento recibe el objeto suelto, de
    # modo que .Count falla bajo Set-StrictMode 2.0 antes de medir nada. La coma
    # devuelve el arreglo como un unico objeto y conserva 0/1/2+ descargas.
    param($Result)
    $uris = @()
    if ($null -ne $Result -and $null -ne $Result.WebRequests) {
        $uris = @($Result.WebRequests)
    }
    return ,$uris
}

New-ProbeScript
$script:ReadmeText = [System.IO.File]::ReadAllText($script:ReadmePath)
$script:RemoteDocsText = [System.IO.File]::ReadAllText($script:RemoteDocsPath)
$script:LatestCommand = Get-DocumentedShortCommand -Text $script:ReadmeText -Kind 'latest'
$script:PinnedCommand = Get-DocumentedShortCommand -Text $script:ReadmeText -Kind 'pinned'
$script:DocsPinnedCommand = Get-DocumentedShortCommand -Text $script:RemoteDocsText -Kind 'pinned'

try {
    Test-Case 'La lectura de descargas conserva arreglos de 0, 1 y 2 elementos' {
        # Bajo StrictMode 2.0 ni $null ni un escalar exponen .Count: el helper
        # debe devolver siempre un arreglo real, tambien con 0 y con 1 elemento.
        $empty = Get-WebRequestUris ([pscustomobject]@{ WebRequests = @() })
        Assert-True ($empty -is [array]) 'con 0 descargas debe devolver un arreglo'
        Assert-Equal 0 $empty.Count 'con 0 descargas el conteo debe ser 0'
        $single = Get-WebRequestUris ([pscustomobject]@{ WebRequests = @('https://uno') })
        Assert-True ($single -is [array]) 'con 1 descarga debe devolver un arreglo'
        Assert-Equal 1 $single.Count 'con 1 descarga el conteo debe ser 1'
        Assert-Equal 'https://uno' $single[0] 'con 1 descarga el elemento debe conservarse'
        $pair = Get-WebRequestUris ([pscustomobject]@{ WebRequests = @('https://uno', 'https://dos') })
        Assert-True ($pair -is [array]) 'con 2 descargas debe devolver un arreglo'
        Assert-Equal 2 $pair.Count 'con 2 descargas el conteo debe ser 2'
        Assert-Equal 'https://dos' $pair[1] 'con 2 descargas el orden debe conservarse'
        $missing = Get-WebRequestUris $null
        Assert-True ($missing -is [array]) 'un resultado ausente debe devolver un arreglo vacio'
        Assert-Equal 0 $missing.Count 'sin resultado el conteo debe ser 0'
    }

    Test-Case 'La ultima version ejecuta el instalador y devuelve codigo 0 al llamador' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand
        Assert-Equal 0 $case.ProcessExitCode 'el probe debe llegar al final'
        Assert-True (Test-Path -LiteralPath $case.SurvivedPath) 'el llamador no debe ser cerrado por un exit'
        Assert-True ($null -ne $case.Result) 'falta el resultado del probe'
        Assert-Equal '' $case.Result.CommandError 'el comando publicado no debe lanzar'
        Assert-Equal '0' $case.Result.LastExitCode 'el hijo 0 debe quedar en $LASTEXITCODE'
        Assert-True ($null -ne $case.ChildArgs) 'el instalador fixture no se ejecuto'
        Assert-True $case.ChildArgs.FromRelease 'falta -FromRelease'
        Assert-Equal '' $case.ChildArgs.Version 'la ultima version no debe fijar -Version'
        Assert-True (-not $case.ChildArgs.NoAnimation) '-NoAnimation no se pidio'
        $uris = Get-WebRequestUris $case.Result
        Assert-Equal 1 $uris.Count 'debe haber una sola descarga del instalador real'
        Assert-Equal 'https://github.com/RonGrasz/Mensor-CAD/releases/latest/download/Install-MensorCAD.ps1' $uris[0] 'URL del instalador incorrecta'
        Assert-Equal 0 $case.Workspaces.Count 'la carpeta temporal propia debe limpiarse'
    }

    Test-Case 'El comando fijado publicado propaga el tag y no usa la ultima version' {
        $case = Invoke-BootstrapCase -CommandText $script:PinnedCommand
        Assert-Equal 0 $case.ProcessExitCode 'el probe debe llegar al final'
        Assert-True (Test-Path -LiteralPath $case.SurvivedPath) 'el llamador no debe ser cerrado'
        Assert-Equal '0' $case.Result.LastExitCode 'el hijo 0 debe quedar en $LASTEXITCODE'
        Assert-Equal 'v0.1.0' $case.ChildArgs.Version 'el tag del comando debe llegar intacto'
        $uris = Get-WebRequestUris $case.Result
        Assert-Equal 1 $uris.Count 'debe haber una sola descarga'
        Assert-Equal 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v0.1.0/Install-MensorCAD.ps1' $uris[0] 'la URL debe ser la del tag'
        Assert-True ($uris[0].Contains('/releases/download/v0.1.0/')) 'la URL no debe usar latest'
        Assert-Equal 0 $case.Workspaces.Count 'la carpeta temporal propia debe limpiarse'
    }

    Test-Case 'La documentacion remota publica el mismo comando fijado que el README' {
        Assert-Equal $script:PinnedCommand $script:DocsPinnedCommand 'los comandos fijados publicados deben coincidir'
        $case = Invoke-BootstrapCase -CommandText $script:DocsPinnedCommand
        Assert-Equal '0' $case.Result.LastExitCode 'el comando documentado debe instalar'
        Assert-Equal 'v0.1.0' $case.ChildArgs.Version 'el tag documentado debe llegar intacto'
    }

    Test-Case 'El wrapper refleja -NoAnimation sin cambiar de motor' {
        $command = $script:PinnedCommand + ' -NoAnimation'
        $case = Invoke-BootstrapCase -CommandText $command
        Assert-Equal '0' $case.Result.LastExitCode 'el wrapper debe terminar con el codigo del hijo'
        Assert-True $case.ChildArgs.NoAnimation 'falta -NoAnimation en el hijo'
        Assert-Equal 'v0.1.0' $case.ChildArgs.Version 'el tag debe conservarse'
    }

    Test-Case 'Un hijo con codigo distinto de cero se propaga y no se informa como exito' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand -ChildExit 7
        Assert-True (Test-Path -LiteralPath $case.SurvivedPath) 'el llamador no debe ser cerrado'
        Assert-Equal '7' $case.Result.LastExitCode 'el codigo real del hijo debe propagarse'
        Assert-True ($case.Stdout.Contains('fixture stdout 1')) 'se perdio el stdout del hijo'
        Assert-True (-not $case.Stdout.Contains('fixture stderr 1')) 'el stderr del hijo no puede aparecer en stdout'
        Assert-True ($case.Stderr.Contains('fixture stderr 1')) 'el stderr del hijo debe reenviarse por stderr'
    }

    Test-Case 'El stdout del hijo se reenvia en orden y sin capturarse como valor' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand
        $first = $case.Stdout.IndexOf('fixture stdout 1')
        $second = $case.Stdout.IndexOf('fixture stdout 2')
        Assert-True ($first -ge 0) 'falta la primera linea del hijo'
        Assert-True ($second -gt $first) 'se altero el orden del stdout del hijo'
        Assert-True ($case.Stdout.Trim().EndsWith('fixture stdout 2')) 'el wrapper no debe agregar un resumen de exito'
        Assert-True (-not $case.Stdout.Contains('ERROR:')) 'un exito no debe escribir ERROR en stdout'
        Assert-True (-not $case.Stdout.Contains('fixture stderr 1')) 'el stderr del hijo no se mezcla con stdout'
        Assert-True ($case.Stderr.Contains('fixture stderr 1')) 'el stderr del hijo se conserva en su canal'
        Assert-Equal 1 $case.RemoveCalls.Count 'solo debe borrarse la carpeta propia'
        Assert-True ($case.RemoveCalls[0].StartsWith($case.Temp)) 'no se debe borrar nada fuera de la raiz temporal'
        Assert-True ($case.RemoveCalls[0].Contains('mensorcad-bootstrap-')) 'solo se borra la carpeta propia'
    }

    Test-Case 'Un error no terminante de la descarga del instalador se promueve sin ejecutar el hijo' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand -Mode 'installer-nonterminating'
        Assert-True (Test-Path -LiteralPath $case.SurvivedPath) 'el llamador no debe ser cerrado'
        Assert-Equal '1' $case.Result.LastExitCode 'un 404 simulado debe terminar en 1'
        Assert-True ($case.Stderr.Contains('ERROR:')) 'falta el ERROR del wrapper'
        Assert-True ($case.Stderr.Contains('404 simulado')) 'falta el detalle del fallo de descarga'
        Assert-True ($null -eq $case.ChildArgs) 'no se debe ejecutar el instalador si la descarga falla'
        Assert-Equal 0 $case.Workspaces.Count 'la carpeta temporal propia debe limpiarse'
    }

    Test-Case 'Un error terminante de la descarga del instalador tampoco llega al hijo' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand -Mode 'installer-terminating'
        Assert-Equal '1' $case.Result.LastExitCode 'un fallo terminante debe terminar en 1'
        Assert-True ($case.Stderr.Contains('ERROR:')) 'falta el ERROR del wrapper'
        Assert-True ($null -eq $case.ChildArgs) 'no se debe ejecutar el instalador'
    }

    Test-Case 'Una descarga sin archivo no se da por hecha' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand -Mode 'installer-no-file'
        Assert-Equal '1' $case.Result.LastExitCode 'falta de archivo debe terminar en 1'
        Assert-True ($case.Stderr.Contains('ERROR:')) 'falta el ERROR del wrapper'
        Assert-True ($null -eq $case.ChildArgs) 'no se debe ejecutar el instalador'
    }

    Test-Case 'La primera descarga con error no terminante la corta el -ea Stop publicado' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand -Mode 'first-fetch-nonterminating'
        Assert-True (Test-Path -LiteralPath $case.SurvivedPath) 'el llamador no debe ser cerrado'
        Assert-True ($case.Result.CommandError.Contains('403 simulado')) 'el -ea Stop no corto la primera descarga'
        Assert-Equal '0' $case.Result.LastExitCode 'la primera descarga no la fija el wrapper: sobrevive el valor previo'
        Assert-True ($null -eq $case.NewItemPath) 'el wrapper no debe ejecutarse tras un fallo de la primera descarga'
        Assert-Equal 0 (Get-WebRequestUris $case.Result).Count 'el instalador no debe descargarse'
    }

    Test-Case 'La primera descarga con 404 terminante se informa y no ejecuta nada' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand -Mode 'first-fetch-terminating'
        Assert-True ($case.Result.CommandError.Contains('404 simulado')) 'falta el detalle del 404'
        Assert-Equal '0' $case.Result.LastExitCode 'un 404 antes del wrapper no fija $LASTEXITCODE'
        Assert-True ($null -eq $case.NewItemPath) 'el wrapper no debe ejecutarse tras un 404 de la primera descarga'
        Assert-True ($null -eq $case.ChildArgs) 'no se debe ejecutar el instalador'
    }

    Test-Case 'Un tag invalido falla antes de la red y de las escrituras' {
        $command = '& "' + $script:BootstrapPath + '" -Version "tag con espacios"'
        $case = Invoke-BootstrapCase -CommandText $command
        Assert-Equal '1' $case.Result.LastExitCode 'un tag invalido debe terminar en 1'
        Assert-True ($case.Stderr.Contains('ERROR:')) 'falta el ERROR del wrapper'
        Assert-True ($case.Stderr.Contains('tag')) 'el mensaje debe nombrar el tag'
        Assert-Equal 0 (Get-WebRequestUris $case.Result).Count 'no debe haber ninguna descarga'
        Assert-True ($null -eq $case.ChildArgs) 'no se debe ejecutar el instalador'
        Assert-Equal 0 $case.Workspaces.Count 'no se debe crear una carpeta temporal'
    }

    Test-Case 'Un tag vacio falla antes de la red y de las escrituras' {
        $command = '& "' + $script:BootstrapPath + '" -Version ""'
        $case = Invoke-BootstrapCase -CommandText $command
        Assert-Equal '1' $case.Result.LastExitCode 'un tag vacio debe terminar en 1'
        Assert-Equal 0 (Get-WebRequestUris $case.Result).Count 'no debe haber ninguna descarga'
        Assert-Equal 0 $case.Workspaces.Count 'no se debe crear una carpeta temporal'
    }

    Test-Case 'Una carpeta preexistente con contenido ajeno sobrevive si la creacion falla' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand -Mode 'workspace-collision'
        Assert-Equal '1' $case.Result.LastExitCode 'un fallo de creacion debe terminar en 1'
        Assert-True ($case.Stderr.Contains('ERROR:')) 'falta el ERROR del wrapper'
        Assert-True ($case.Stderr.Contains('ya existe')) 'el mensaje debe conservar el fallo real'
        Assert-Equal 0 (Get-WebRequestUris $case.Result).Count 'no debe haber descarga'
        Assert-True ($null -eq $case.ChildArgs) 'no se debe ejecutar el instalador'
        Assert-True ($null -ne $case.NewItemPath) 'debe intentarse crear la carpeta candidata'
        Assert-True ($case.NewItemPath.Contains('mensorcad-bootstrap-')) 'la candidata debe ser la carpeta propia'
        Assert-Equal 0 $case.RemoveCalls.Count 'no se debe intentar borrar una ruta no creada'
        $sentinel = Join-Path -Path $case.NewItemPath -ChildPath 'sentinel.txt'
        Assert-True (Test-Path -LiteralPath $sentinel) 'se borro o movio el contenido ajeno'
        Assert-Equal 'contenido ajeno intacto' ([System.IO.File]::ReadAllText($sentinel)) 'se altero el contenido ajeno'
    }

    Test-Case 'Una ruta rechazada por punto de reanalisis no se atraviesa ni se borra' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand -Mode 'workspace-reparse'
        Assert-Equal '1' $case.Result.LastExitCode 'un rechazo de reanalisis debe terminar en 1'
        Assert-True ($case.Stderr.Contains('ERROR:')) 'falta el ERROR del wrapper'
        Assert-True ($case.Stderr.Contains('reanalisis')) 'el mensaje debe nombrar el rechazo'
        Assert-True ($case.Stderr.Contains('se conserva en disco')) 'falta el aviso honesto de la carpeta conservada'
        Assert-Equal 0 (Get-WebRequestUris $case.Result).Count 'no debe haber descarga'
        Assert-True ($null -eq $case.ChildArgs) 'no se debe ejecutar el instalador'
        Assert-Equal 0 $case.RemoveCalls.Count 'no se debe borrar una ruta rechazada'
        $sentinel = Join-Path -Path $case.NewItemPath -ChildPath 'sentinel.txt'
        Assert-True (Test-Path -LiteralPath $sentinel) 'se atraveso o borro la ruta rechazada'
        Assert-Equal 'contenido ajeno intacto' ([System.IO.File]::ReadAllText($sentinel)) 'se altero el destino rechazado'
    }

    Test-Case 'Una ruta temporal con espacios, apostrofes y Unicode no rompe la limpieza' {
        $case = Invoke-BootstrapCase -CommandText $script:LatestCommand
        Assert-True ($case.Temp.Contains(' ')) 'la ruta del caso debe tener espacios'
        Assert-True ($case.Temp.Contains("'")) 'la ruta del caso debe tener apostrofes'
        Assert-Equal '0' $case.Result.LastExitCode 'la ruta no debe romper la ejecucion'
        Assert-True (Test-Path -LiteralPath $case.SurvivedPath) 'el llamador no debe ser cerrado'
        Assert-Equal 0 $case.Workspaces.Count 'la carpeta propia debe borrarse tambien en rutas con espacios'
    }
}
finally {
    foreach ($name in $script:ProbeEnvironmentNames) {
        Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ('Resultado: ' + $script:Passed + ' superadas, ' + $script:Failed + ' fallidas, ' + $script:Skipped + ' omitidas.')
if ($script:Failed -gt 0) {
    foreach ($message in $script:FailureMessages) {
        Write-Host (' - ' + $message) -ForegroundColor Red
    }
    exit 1
}
exit 0
