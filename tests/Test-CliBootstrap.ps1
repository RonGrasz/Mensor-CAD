#requires -Version 5.1
<#
    Pruebas funcionales del bootstrap que registra el gestor "mensorcad".

    El cuerpo ejecutado es el comando publicado, extraido de
    docs/cli-bootstrap.md, igual que lo copia un usuario: la descarga inicial de
    install.ps1 se sustituye por una costura local y el texto real del asset se
    ejecuta con iex. Un proceso sonda aparte intercepta:

      - la API de GitHub y las descargas (Invoke-RestMethod / Invoke-WebRequest),
      - la clave HKCU:\Environment mediante un objeto de registro falso que
        implementa GetValueNames / GetValue / GetValueKind / SetValue,
      - las carpetas del usuario (LOCALAPPDATA y TEMP apuntan a una carpeta
        propia dentro de odd/artifacts/persistent-cli/bootstrap).

    No se toca el PATH real del usuario, no se escribe en Program Files, no se
    abre AutoCAD, no se pide UAC y no se llama a GitHub. Los ZIP y sus sidecars
    son fixtures reales creados en el disco para que la validacion SHA-256, el
    recuento exacto de entradas y el rechazo de enlaces sean codigo real. La
    ruta local usa un ZIP fixture con su sidecar adjunto: su mensorcad.ps1 lleva
    una version sellada escrita como texto y, si el bootstrap lo ejecutara para
    averiguarla, dejaria una sentinela que la suite comprueba ausente.

    Limite conocido: la sonda corre en Windows PowerShell 5.1; en cualquier otro
    interprete la suite se rechaza en voz alta.

    Limite conocido del filesystem: el scratch vive en la ruta del proyecto, que
    en este entorno es un recurso de red (WSL). Esa ruta no permite crear
    enlaces de directorio, asi que el caso del destino con punto de reanalisis
    se omite con motivo; el rechazo de enlaces se sigue midiendo con la entrada
    simulada del ZIP. El renombrado transaccional de NTFS local tampoco se
    reproduce ahi: el rollback se prueba forzando un fallo real del PATH, que
    ocurre despues del reemplazo.

    Ejecucion manual:
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/Test-CliBootstrap.ps1
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'SKIP: estas pruebas requieren Windows PowerShell 5.1.' -ForegroundColor Yellow
    exit 2
}
if (($PSVersionTable.PSVersion.Major -ne 5) -or ([string]$PSVersionTable.PSEdition -ne 'Desktop')) {
    Write-Host 'ERROR: estas pruebas requieren Windows PowerShell 5.1 Desktop.' -ForegroundColor Red
    exit 1
}

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:CaseSkipped = $false
$script:FailureMessages = @()
$script:Utf8 = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:BootstrapPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'install.ps1'
$script:DocsPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'docs\cli-bootstrap.md'
$script:ScratchRoot = Join-Path -Path $script:RepositoryRoot -ChildPath 'odd\artifacts\persistent-cli\bootstrap'
$script:RunRoot = Join-Path -Path $script:ScratchRoot -ChildPath ('run-' + [guid]::NewGuid().ToString('N'))
$script:ProbePath = Join-Path -Path $script:RunRoot -ChildPath 'probe.ps1'
$script:PowerShellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
$script:ProbeEnvironmentNames = @(
    'MCB_TEMP', 'MCB_LOCALAPPDATA', 'MCB_COMMAND', 'MCB_BOOTSTRAP', 'MCB_ASSETS',
    'MCB_MODE', 'MCB_REGISTRY', 'MCB_RESULT', 'MCB_TAG', 'MCB_PAYLOAD_SENTINEL',
    'MCB_LOCATION'
)
$script:ManagerFiles = @('mensorcad.ps1', 'mensorcad.cmd', 'Install-MensorCAD.ps1')
$script:MarkerName = '.mensorcad-cli.json'

if (-not (Test-Path -LiteralPath $script:BootstrapPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro el bootstrap en '$script:BootstrapPath'." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $script:DocsPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro la guia en '$script:DocsPath'." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $script:PowerShellPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro Windows PowerShell en '$script:PowerShellPath'." -ForegroundColor Red
    exit 1
}

# La consola que lanza esta suite puede traer TEMP/TMP con el prefijo de
# proveedor que agrega Join-Path cuando el directorio actual esta en una ruta de
# red (por ejemplo al invocar powershell.exe desde WSL). Un TEMP asi rompe el
# arranque de cualquier proceso hijo de Windows PowerShell, asi que esta suite
# fija TEMP y TMP a su propio scratch dentro del proyecto. Cada caso vuelve a
# apuntar la carpeta temporal de la sonda a su carpeta aislada.
$env:TEMP = $script:ScratchRoot
$env:TMP = $script:ScratchRoot
$null = [System.IO.Directory]::CreateDirectory($script:ScratchRoot)
$null = [System.IO.Directory]::CreateDirectory($script:RunRoot)

# ---------------------------------------------------------------------------
# Sonda: proceso aparte con el registro, la red y las carpetas del usuario
# sustituidos. Escribe un JSON con lo observado y una sentinela que solo existe
# si el bootstrap no cerro la sesion del llamador.
# ---------------------------------------------------------------------------
$probeTemplate = @'
param()
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$mode = [string]$env:MCB_MODE
$assets = [string]$env:MCB_ASSETS
$bootstrapPath = [string]$env:MCB_BOOTSTRAP
$commandFile = [string]$env:MCB_COMMAND
$resultPath = [string]$env:MCB_RESULT
$registryFile = [string]$env:MCB_REGISTRY
$tag = [string]$env:MCB_TAG

$env:TEMP = [string]$env:MCB_TEMP
$env:TMP = [string]$env:MCB_TEMP
$env:LOCALAPPDATA = [string]$env:MCB_LOCALAPPDATA

$script:ApiCalls = New-Object 'System.Collections.Generic.List[string]'
$script:FetchCalls = New-Object 'System.Collections.Generic.List[string]'
$script:WebRequests = New-Object 'System.Collections.Generic.List[string]'
$script:KeyRequests = New-Object 'System.Collections.Generic.List[string]'
$script:RegState = [pscustomobject]@{
    Values = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    SetCalls = 0
    ThrowOnSet = $false
    SetKinds = New-Object 'System.Collections.Generic.List[string]'
}

$initial = [System.IO.File]::ReadAllText($registryFile) | ConvertFrom-Json
foreach ($entry in @($initial.values)) {
    if ($null -ne $entry) {
        $script:RegState.Values[[string]$entry.name] = [pscustomobject]@{
            Value = [string]$entry.value
            Kind = [string]$entry.kind
        }
    }
}
$script:RegState.ThrowOnSet = [bool]$initial.throwOnSet

function New-FakeEnvironmentKey {
    $key = [pscustomobject]@{ State = $script:RegState }
    $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value {
        return @($this.State.Values.Keys)
    }
    $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
        param($name, $default, $options)
        if (($null -ne $name) -and $this.State.Values.ContainsKey([string]$name)) {
            return [string]$this.State.Values[[string]$name].Value
        }
        return $default
    }
    $key | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value {
        param($name)
        if (($null -eq $name) -or (-not $this.State.Values.ContainsKey([string]$name))) {
            throw (New-Object System.ArgumentException ('No existe el valor ' + [string]$name))
        }
        return [Microsoft.Win32.RegistryValueKind]([string]$this.State.Values[[string]$name].Kind)
    }
    $key | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
        param($name, $value, $kind)
        if ($this.State.ThrowOnSet) {
            throw 'Acceso denegado simulado al PATH del usuario.'
        }
        $this.State.Values[[string]$name] = [pscustomobject]@{ Value = [string]$value; Kind = [string]$kind }
        $this.State.SetCalls = $this.State.SetCalls + 1
        $this.State.SetKinds.Add([string]$kind)
    }
    $key | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    return $key
}

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
        $script:KeyRequests.Add([string]$target)
        return New-FakeEnvironmentKey
    }
    Microsoft.PowerShell.Management\Get-Item -LiteralPath $target -Force:$Force
}

# Cualquier intento de escribir el PATH con cmdlets del proveedor se rechaza en
# voz alta: solo se admite la escritura por .NET, que conserva REG_SZ frente a
# REG_EXPAND_SZ.
function global:Set-ItemProperty {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    throw 'Set-ItemProperty no debe usarse: el PATH del usuario se escribe por .NET para preservar el tipo.'
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
function global:Get-ItemProperty {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    throw 'Get-ItemProperty no debe usarse: el tipo del PATH se lee con RegistryKey.'
}

function global:Invoke-RestMethod {
    [CmdletBinding()]
    param(
        [switch]$UseBasicParsing,
        [Parameter(Position = 0)][string]$Uri,
        [hashtable]$Headers,
        [string]$Method
    )
    if ($Uri -like '*install.ps1') {
        $script:FetchCalls.Add([string]$Uri)
        return [System.IO.File]::ReadAllText($bootstrapPath)
    }
    $script:ApiCalls.Add([string]$Uri)
    if ($mode -eq 'api-throw') { throw ('403 simulado al consultar el release: ' + $Uri) }
    if ($mode -eq 'api-empty') { return $null }
    if ($mode -eq 'api-bad-tag') { return [pscustomobject]@{ tag_name = 'malo' } }
    return [pscustomobject]@{ tag_name = $tag }
}

function global:Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [switch]$UseBasicParsing,
        [Parameter(Position = 0)][string]$Uri,
        [string]$OutFile
    )
    $script:WebRequests.Add([string]$Uri)
    $asset = @($Uri -split '/')[-1]
    if (($mode -eq 'zip-throw') -and ($asset -eq 'MensorCAD-CLI.zip')) {
        throw ('404 simulado en el ZIP: ' + $Uri)
    }
    if (($mode -eq 'zip-writeerror') -and ($asset -eq 'MensorCAD-CLI.zip')) {
        Write-Error ('404 no terminante simulado en el ZIP: ' + $Uri)
        return
    }
    if (($mode -eq 'zip-nofile') -and ($asset -eq 'MensorCAD-CLI.zip')) { return }
    if (($mode -eq 'sha-throw') -and ($asset -eq 'MensorCAD-CLI.zip.sha256')) {
        throw ('404 simulado en el sidecar: ' + $Uri)
    }
    if (($mode -eq 'sha-writeerror') -and ($asset -eq 'MensorCAD-CLI.zip.sha256')) {
        Write-Error ('404 no terminante simulado en el sidecar: ' + $Uri)
        return
    }
    if (($mode -eq 'sha-nofile') -and ($asset -eq 'MensorCAD-CLI.zip.sha256')) { return }
    $source = Join-Path $assets $asset
    if (-not [System.IO.File]::Exists($source)) { throw ('404 simulado: ' + $Uri) }
    [System.IO.File]::Copy($source, $OutFile, $true)
}

# La sonda arranca en la carpeta de Windows (directorio del proceso) y la
# sesion se mueve a la carpeta del usuario antes de invocar el bootstrap, como
# una terminal donde se hizo Set-Location. Set-Location NO cambia el directorio
# del proceso, asi que una ruta relativa resuelta con [IO.Path]::GetFullPath
# caeria en la carpeta equivocada.
$sessionLocation = [string]$env:MCB_LOCATION
if (-not [string]::IsNullOrWhiteSpace($sessionLocation)) {
    Set-Location -LiteralPath $sessionLocation
}

$commandText = [System.IO.File]::ReadAllText($commandFile)
$global:LASTEXITCODE = 0
$script:CommandError = ''
try {
    & ([scriptblock]::Create($commandText))
}
catch {
    $script:CommandError = $_.Exception.Message
}

$lastExit = 'null'
if ($null -ne $global:LASTEXITCODE) { $lastExit = [string]$global:LASTEXITCODE }

$values = [ordered]@{}
foreach ($name in @($script:RegState.Values.Keys)) {
    $entry = $script:RegState.Values[$name]
    $values[[string]$name] = [pscustomobject]@{ value = [string]$entry.Value; kind = [string]$entry.Kind }
}
$payload = [pscustomobject]@{
    CommandError = $script:CommandError
    LastExitCode = $lastExit
    ApiCalls = @($script:ApiCalls.ToArray())
    FetchCalls = @($script:FetchCalls.ToArray())
    WebRequests = @($script:WebRequests.ToArray())
    Registry = [pscustomobject]@{
        Values = [pscustomobject]$values
        SetCalls = [int]$script:RegState.SetCalls
        SetKinds = @($script:RegState.SetKinds.ToArray())
        KeyRequests = @($script:KeyRequests.ToArray())
    }
    ProcessPath = [string]$env:Path
}
[System.IO.File]::WriteAllText($resultPath, ($payload | ConvertTo-Json -Compress -Depth 6), $utf8)
[System.IO.File]::WriteAllText((Join-Path $env:TEMP 'survived.txt'), 'la sesion del llamador sobrevivio', $utf8)
exit 0
'@

# ---------------------------------------------------------------------------
# Utilidades de la suite
# ---------------------------------------------------------------------------

function Write-FixtureFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not [System.IO.Directory]::Exists($parent)) { $null = [System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}

Write-FixtureFile -Path $script:ProbePath -Content $probeTemplate

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

function Get-DocumentedCommands {
    param([string]$Text)
    $patterns = [ordered]@{
        Latest = '^\s*irm ''https://github\.com/RonGrasz/Mensor-CAD/releases/latest/download/install\.ps1'' -ea Stop \| iex\s*$'
        Pinned = '^\s*&\(\[scriptblock\]::Create\(\(irm ''https://github\.com/RonGrasz/Mensor-CAD/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/install\.ps1'' -ea Stop\)\)\) -Version v[0-9]+\.[0-9]+\.[0-9]+\s*$'
        NoAnimation = '^\s*&\(\[scriptblock\]::Create\(\(irm ''https://github\.com/RonGrasz/Mensor-CAD/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/install\.ps1'' -ea Stop\)\)\) -Version v[0-9]+\.[0-9]+\.[0-9]+ -NoAnimation\s*$'
    }
    $result = [ordered]@{}
    foreach ($kind in $patterns.Keys) {
        $found = @()
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line -match $patterns[$kind]) { $found += $line.Trim() }
        }
        if ($found.Count -ne 1) {
            throw ('Se esperaba exactamente un comando documentado de tipo ' + $kind + '; encontrados: ' + $found.Count)
        }
        $result[$kind] = $found[0]
    }
    return [pscustomobject]$result
}

function New-PinnedCommand {
    param([string]$Tag, [switch]$NoAnimation)
    $text = '&([scriptblock]::Create((irm ''https://github.com/RonGrasz/Mensor-CAD/releases/download/' + $Tag + '/install.ps1'' -ea Stop))) -Version ' + $Tag
    if ($NoAnimation) { $text += ' -NoAnimation' }
    return $text
}

function New-CliZip {
    param([string]$Path, [object[]]$Entries)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($definition in $Entries) {
                $zipEntry = $archive.CreateEntry([string]$definition.Name, [System.IO.Compression.CompressionLevel]::Optimal)
                if ($definition.ContainsKey('ExternalAttributes')) {
                    $zipEntry.ExternalAttributes = [int]$definition.ExternalAttributes
                }
                if ($definition.ContainsKey('Bytes')) {
                    $bytes = [byte[]]$definition.Bytes
                }
                else {
                    $bytes = $script:Utf8.GetBytes([string]$definition.Content)
                }
                $target = $zipEntry.Open()
                try { $target.Write($bytes, 0, $bytes.Length) }
                finally { $target.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function New-CliAssets {
    param([string]$Root, [string]$Mode = 'valid', [string]$Tag = 'v1.2.3')
    $payloadPs = @'
param()
# Fixture: si el bootstrap ejecutara este archivo, dejaria una sentinela.
if ($env:MCB_PAYLOAD_SENTINEL) {
    [System.IO.File]::WriteAllText($env:MCB_PAYLOAD_SENTINEL, 'el payload descargado se ejecuto')
}
exit 99
'@
    $payloadCmd = "@echo off`r`nexit /b 0`r`n"
    $payloadInstall = $payloadPs
    $base = @(
        @{ Name = 'mensorcad.ps1'; Content = $payloadPs },
        @{ Name = 'mensorcad.cmd'; Content = $payloadCmd },
        @{ Name = 'Install-MensorCAD.ps1'; Content = $payloadInstall }
    )
    $entries = $base
    switch ($Mode) {
        'zip-extra' {
            $entries = $base + @(@{ Name = 'notas.txt'; Content = 'entrada extra' })
        }
        'zip-missing-entry' {
            $entries = @($base[0], $base[1])
        }
        'zip-duplicate' {
            $entries = @(
                @{ Name = 'mensorcad.ps1'; Content = $payloadPs },
                @{ Name = 'MENSORCAD.PS1'; Content = $payloadPs },
                @{ Name = 'mensorcad.cmd'; Content = $payloadCmd }
            )
        }
        'zip-traversal' {
            $entries = @(
                @{ Name = '../mensorcad.ps1'; Content = $payloadPs },
                @{ Name = 'mensorcad.cmd'; Content = $payloadCmd },
                @{ Name = 'Install-MensorCAD.ps1'; Content = $payloadInstall }
            )
        }
        'zip-symlink' {
            $entries = @(
                @{ Name = 'mensorcad.ps1'; Content = $payloadPs; ExternalAttributes = [int](0xA1FF -shl 16) },
                @{ Name = 'mensorcad.cmd'; Content = $payloadCmd },
                @{ Name = 'Install-MensorCAD.ps1'; Content = $payloadInstall }
            )
        }
        'zip-oversize' {
            $entries = @(
                @{ Name = 'mensorcad.ps1'; Bytes = (New-Object byte[] 5242880) },
                @{ Name = 'mensorcad.cmd'; Content = $payloadCmd },
                @{ Name = 'Install-MensorCAD.ps1'; Content = $payloadInstall }
            )
        }
    }
    $zipPath = Join-Path -Path $Root -ChildPath 'MensorCAD-CLI.zip'
    New-CliZip -Path $zipPath -Entries $entries
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecar = switch ($Mode) {
        'hash-mismatch' { ('0' * 64 -join '') + '  MensorCAD-CLI.zip' + "`n" }
        'sidecar-malformed' { 'esto no es un sidecar sha256' + "`n" }
        'sidecar-nonewline' { $hash + '  MensorCAD-CLI.zip' }
        'sidecar-onespace' { $hash + ' MensorCAD-CLI.zip' + "`n" }
        'sidecar-wrong-name' { $hash + '  Otro.zip' + "`n" }
        default { $hash + '  MensorCAD-CLI.zip' + "`n" }
    }
    Write-FixtureFile -Path (Join-Path -Path $Root -ChildPath 'MensorCAD-CLI.zip.sha256') -Content $sidecar
}

function Get-LocalManagerText {
    # Fixture del gestor local: la version va escrita como texto sellado. El
    # cuerpo solo deja una sentinela si alguien lo EJECUTA, de modo que la suite
    # puede probar que el bootstrap nunca corre el archivo para averiguar su
    # version.
    param([string]$Version = '1.2.3')
    $template = @'
param()
$script:MensorCadManagerVersion = '@@VERSION@@'
if ($env:MCB_PAYLOAD_SENTINEL) {
    [System.IO.File]::WriteAllText($env:MCB_PAYLOAD_SENTINEL, 'el gestor local se ejecuto')
}
exit 99
'@
    return $template.Replace('@@VERSION@@', $Version)
}

function New-LocalCliInput {
    # ZIP local fixture con su sidecar .sha256 adjunto, igual que los genera
    # tools/build_bundle.py en dist/. Cada modo rompe una regla distinta.
    param([string]$Root, [string]$Mode = 'valid')
    $managerText = Get-LocalManagerText -Version '1.2.3'
    if ($Mode -eq 'unversioned') {
        $managerText = "param()`r`n`$script:MensorCadManagerVersion = '__MENSORCAD_MANAGER_VERSION__'`r`n"
    }
    if ($Mode -eq 'ambiguous') {
        $managerText = "param()`r`n`$script:MensorCadManagerVersion = '1.2.3'`r`n`$script:MensorCadManagerVersion = '1.2.4'`r`n"
    }
    $entries = @(
        @{ Name = 'mensorcad.ps1'; Content = $managerText },
        @{ Name = 'mensorcad.cmd'; Content = "@echo off`r`nexit /b 0`r`n" },
        @{ Name = 'Install-MensorCAD.ps1'; Content = $managerText }
    )
    if ($Mode -eq 'zip-extra') {
        $entries = @($entries) + @(@{ Name = 'notas.txt'; Content = 'entrada extra' })
    }
    $zipPath = Join-Path -Path $Root -ChildPath 'MensorCAD-CLI.zip'
    if ($Mode -eq 'zip-directory') {
        $null = [System.IO.Directory]::CreateDirectory($zipPath)
    }
    elseif ($Mode -ne 'zip-missing') {
        New-CliZip -Path $zipPath -Entries $entries
    }
    $hash = ''
    if ([System.IO.File]::Exists($zipPath)) {
        $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($Mode -ne 'sidecar-missing') {
        $sidecar = switch ($Mode) {
            'hash-mismatch' { ('0' * 64) + '  MensorCAD-CLI.zip' + "`n" }
            'sidecar-malformed' { 'esto no es un sidecar sha256' + "`n" }
            'zip-windows' { $hash + '  MensorCAD-Windows.zip' + "`n" }
            default { $hash + '  MensorCAD-CLI.zip' + "`n" }
        }
        Write-FixtureFile -Path ($zipPath + '.sha256') -Content $sidecar
    }
}

function New-LocalCommandTemplate {
    # Entrada publicada con el parametro nuevo: el texto real de install.ps1 se
    # carga por la misma costura y despues se le pasan los argumentos del caso.
    param([string]$Arguments)
    return "&([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v1.2.3/install.ps1' -ea Stop))) " + $Arguments
}

function Get-ChildNames {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { return @() }
    $names = @()
    foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($Path)) {
        $names += [System.IO.Path]::GetFileName($entry)
    }
    return @($names | Sort-Object)
}

function Get-RegistryEntry {
    param($Result, [string]$Name)
    if ($null -eq $Result) { return $null }
    $wrapper = $Result.Registry
    if ($null -eq $wrapper) { return $null }
    $values = $wrapper.Values
    if ($null -eq $values) { return $null }
    $property = $values.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-Marker {
    param([string]$Destination)
    $path = Join-Path -Path $Destination -ChildPath $script:MarkerName
    if (-not [System.IO.File]::Exists($path)) { return $null }
    return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
}

function Invoke-CliCase {
    param(
        [Parameter(Mandatory = $false)][string]$CommandText = '',
        [string]$CommandTemplate = '',
        [string]$Mode = 'ok',
        [string]$AssetMode = 'valid',
        [string]$LocalAssetMode = '',
        [string]$Tag = 'v1.2.3',
        [switch]$NoPathValue,
        [string]$PathValue = '',
        [scriptblock]$PathValueFactory = $null,
        [string]$PathKind = 'ExpandString',
        [switch]$ThrowOnSet,
        [switch]$SessionInLocalInput,
        [scriptblock]$Seed
    )
    $caseRoot = Join-Path -Path $script:RunRoot -ChildPath ('c-' + [guid]::NewGuid().ToString('N'))
    $null = [System.IO.Directory]::CreateDirectory($caseRoot)
    # Ruta del usuario con espacios a proposito: el PATH y las rutas se citan
    # y se escriben sin romperse.
    $localAppData = Join-Path -Path $caseRoot -ChildPath 'local appdata'
    $tempDir = Join-Path -Path $caseRoot -ChildPath 'temp'
    $assets = Join-Path -Path $caseRoot -ChildPath 'assets'
    foreach ($directory in @($localAppData, $tempDir, $assets)) {
        $null = [System.IO.Directory]::CreateDirectory($directory)
    }
    if ($null -ne $PathValueFactory) { $PathValue = [string](& $PathValueFactory $localAppData) }
    $localInput = Join-Path -Path $caseRoot -ChildPath 'entrada local'
    $localZip = Join-Path -Path $localInput -ChildPath 'MensorCAD-CLI.zip'
    if (-not [string]::IsNullOrEmpty($LocalAssetMode)) {
        $null = [System.IO.Directory]::CreateDirectory($localInput)
        New-LocalCliInput -Root $localInput -Mode $LocalAssetMode
    }
    if ($CommandText.Contains('@@LOCALZIP@@')) {
        $CommandText = $CommandText.Replace('@@LOCALZIP@@', $localZip)
    }
    $effectiveCommand = $CommandText
    if (-not [string]::IsNullOrEmpty($CommandTemplate)) {
        $effectiveCommand = $CommandTemplate.Replace('@@LOCALZIP@@', $localZip)
    }
    $commandPath = Join-Path -Path $caseRoot -ChildPath 'command.txt'
    Write-FixtureFile -Path $commandPath -Content $effectiveCommand
    New-CliAssets -Root $assets -Mode $AssetMode -Tag $Tag
    if ($null -ne $Seed) { & $Seed $localAppData }

    $registryPath = Join-Path -Path $caseRoot -ChildPath 'registry.json'
    $values = @()
    if (-not $NoPathValue) {
        $values = @([pscustomobject]@{ name = 'Path'; value = $PathValue; kind = $PathKind })
    }
    Write-FixtureFile -Path $registryPath -Content ([pscustomobject]@{ values = $values; throwOnSet = [bool]$ThrowOnSet } | ConvertTo-Json -Compress -Depth 4)

    $resultPath = Join-Path -Path $caseRoot -ChildPath 'result.json'
    $stdoutPath = Join-Path -Path $caseRoot -ChildPath 'probe.stdout.txt'
    $stderrPath = Join-Path -Path $caseRoot -ChildPath 'probe.stderr.txt'
    $sentinelPath = Join-Path -Path $caseRoot -ChildPath 'payload-ejecutado.txt'

    $env:MCB_TEMP = $tempDir
    $env:MCB_LOCALAPPDATA = $localAppData
    $env:MCB_COMMAND = $commandPath
    $env:MCB_BOOTSTRAP = $script:BootstrapPath
    $env:MCB_ASSETS = $assets
    $env:MCB_MODE = $Mode
    $env:MCB_REGISTRY = $registryPath
    $env:MCB_RESULT = $resultPath
    $env:MCB_TAG = $Tag
    $env:MCB_PAYLOAD_SENTINEL = $sentinelPath
    # Ubicacion de la sesion dentro de la sonda: vacia por omision, o la carpeta
    # que contiene el ZIP local para probar rutas relativas.
    $env:MCB_LOCATION = ''
    if ($SessionInLocalInput) { $env:MCB_LOCATION = $localInput }
    try {
        $process = Start-Process -FilePath $script:PowerShellPath `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:ProbePath)) `
            -WorkingDirectory $env:SystemRoot -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    }
    finally {
        foreach ($name in $script:ProbeEnvironmentNames) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        }
    }

    $stdout = ''
    $stderr = ''
    if ([System.IO.File]::Exists($stdoutPath)) { $stdout = [System.IO.File]::ReadAllText($stdoutPath).Replace("`r`n", "`n") }
    if ([System.IO.File]::Exists($stderrPath)) { $stderr = [System.IO.File]::ReadAllText($stderrPath).Replace("`r`n", "`n") }
    $result = $null
    if ([System.IO.File]::Exists($resultPath)) { $result = ([System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json) }

    $managerRoot = Join-Path -Path $localAppData -ChildPath 'MensorCAD'
    return [pscustomobject]@{
        CaseRoot = $caseRoot
        LocalAppData = $localAppData
        Temp = $tempDir
        LocalInput = $localInput
        LocalZip = $localZip
        ManagerRoot = $managerRoot
        Destination = (Join-Path -Path $managerRoot -ChildPath 'cli')
        ProcessExitCode = [int]$process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
        Result = $result
        PayloadSentinel = [System.IO.File]::Exists($sentinelPath)
        Survived = [System.IO.File]::Exists((Join-Path -Path $tempDir -ChildPath 'survived.txt'))
    }
}

function Get-InstalledNames {
    param($Case)
    return @(Get-ChildNames -Path $Case.Destination)
}

function Get-ManagedRootNames {
    param($Case)
    return @(Get-ChildNames -Path $Case.ManagerRoot)
}

function Get-ApiCalls {
    param($Case)
    if (($null -eq $Case.Result) -or ($null -eq $Case.Result.ApiCalls)) { return @() }
    return @($Case.Result.ApiCalls)
}

function Assert-SinRed {
    # La ruta local no puede tocar ninguna frontera de red: cero consultas a la
    # API y cero descargas de assets.
    param($Case)
    Assert-Equal 0 (@(Get-ApiCalls -Case $Case).Count) 'la ruta local no consulta la API de GitHub'
    Assert-Equal 0 (@(Get-WebRequests -Case $Case).Count) 'la ruta local no descarga ningun asset'
}

function Get-WebRequests {
    param($Case)
    if (($null -eq $Case.Result) -or ($null -eq $Case.Result.WebRequests)) { return @() }
    return @($Case.Result.WebRequests)
}

function Assert-CallerSurvived {
    param($Case)
    Assert-Equal 0 $Case.ProcessExitCode 'el proceso sonda debe terminar con 0'
    Assert-True $Case.Survived 'el bootstrap cerro la sesion del llamador (falta la sentinela)'
    Assert-True ($null -ne $Case.Result) 'la sonda no dejo resultado'
    Assert-Equal '' ([string]$Case.Result.CommandError) 'el comando no debe lanzar una excepcion sin capturar'
}

function Get-SuccessStdout {
    param([string]$Destination, [string]$State, [switch]$PathAlreadyRegistered)
    $lines = @()
    $lines += 'MensorCAD: gestor ' + $State + ' en ' + $Destination
    if ($PathAlreadyRegistered) {
        $lines += 'El PATH de usuario ya incluia la carpeta del gestor; no se agrego de nuevo.'
    }
    else {
        $lines += 'PATH de usuario actualizado: abra una terminal nueva y ejecute "mensorcad --help". Otras terminales abiertas necesitan reiniciarse.'
    }
    $lines += 'Siguiente paso: "mensorcad install" instala el complemento para AutoCAD.'
    return (($lines -join "`n") + "`n")
}

function Assert-NoLeftovers {
    param($Case)
    foreach ($name in (Get-ManagedRootNames -Case $Case)) {
        Assert-False ($name -like 'cli.staging-*') ('quedo una carpeta de staging: ' + $name)
        Assert-False ($name -like 'cli.backup-*') ('quedo una carpeta de respaldo: ' + $name)
    }
}

function Assert-FailureNoWrites {
    param(
        $Case,
        [string]$ErrorMessage,
        [string]$PathValue = '',
        [string]$PathKind = 'ExpandString',
        [int]$ExpectedApiCalls = 1,
        [int]$ExpectedWebRequests = 2,
        [switch]$SkipDestinationAbsent
    )
    Assert-CallerSurvived -Case $Case
    Assert-Equal '1' ([string]$Case.Result.LastExitCode) 'LASTEXITCODE debe informar el fallo'
    Assert-Equal ('ERROR: ' + $ErrorMessage + "`n") $Case.Stderr 'stderr exacto del fallo'
    Assert-Equal '' $Case.Stdout 'un fallo no debe escribir stdout'
    if (-not $SkipDestinationAbsent) {
        Assert-False ([System.IO.Directory]::Exists($Case.Destination)) 'el destino no debe existir'
    }
    Assert-Equal 0 ([int]$Case.Result.Registry.SetCalls) 'no se debe escribir el PATH'
    $entry = Get-RegistryEntry -Result $Case.Result -Name 'Path'
    if ($null -eq $entry) {
        throw 'ASSERT: la prueba perdio el valor Path inicial'
    }
    Assert-Equal $PathValue $entry.value 'el PATH del usuario no debe cambiar'
    Assert-Equal $PathKind $entry.kind 'el tipo del PATH no debe cambiar'
    Assert-Equal $ExpectedApiCalls (@(Get-ApiCalls -Case $Case).Count) 'recuento de consultas al release'
    Assert-Equal $ExpectedWebRequests (@(Get-WebRequests -Case $Case).Count) 'recuento de descargas'
    Assert-False $Case.PayloadSentinel 'el payload descargado nunca se debe ejecutar'
    Assert-NoLeftovers -Case $Case
}

$documented = Get-DocumentedCommands -Text ([System.IO.File]::ReadAllText($script:DocsPath))
$latestCommand = [string]$documented.Latest
$pinnedCommand = [string]$documented.Pinned
$noAnimationCommand = [string]$documented.NoAnimation

$seedPreviousInstall = {
    param([string]$LocalAppData)
    $managerRoot = Join-Path -Path $LocalAppData -ChildPath 'MensorCAD'
    $destination = Join-Path -Path $managerRoot -ChildPath 'cli'
    $null = [System.IO.Directory]::CreateDirectory($destination)
    $marker = [pscustomobject]@{
        schema = 1
        owner = 'MensorCAD-CLI'
        source = 'RonGrasz/Mensor-CAD'
        version = 'v0.9.0'
        installed = '2024-01-01T00:00:00Z'
        files = @('mensorcad.ps1', 'mensorcad.cmd', 'Install-MensorCAD.ps1')
    }
    [System.IO.File]::WriteAllText((Join-Path -Path $destination -ChildPath '.mensorcad-cli.json'), ($marker | ConvertTo-Json -Compress), $script:Utf8)
    foreach ($name in @('mensorcad.ps1', 'mensorcad.cmd', 'Install-MensorCAD.ps1')) {
        [System.IO.File]::WriteAllText((Join-Path -Path $destination -ChildPath $name), ('anterior ' + $name), $script:Utf8)
    }
}

$seedForeignDestination = {
    param([string]$LocalAppData)
    $managerRoot = Join-Path -Path $LocalAppData -ChildPath 'MensorCAD'
    $destination = Join-Path -Path $managerRoot -ChildPath 'cli'
    $null = [System.IO.Directory]::CreateDirectory($destination)
    [System.IO.File]::WriteAllText((Join-Path -Path $destination -ChildPath 'notas.txt'), 'contenido ajeno intacto', $script:Utf8)
}

$seedManagedDestinationWithForeignFile = {
    param([string]$LocalAppData)
    & $seedPreviousInstall $LocalAppData
    $destination = Join-Path -Path (Join-Path -Path $LocalAppData -ChildPath 'MensorCAD') -ChildPath 'cli'
    [System.IO.File]::WriteAllText((Join-Path -Path $destination -ChildPath 'ajeno.txt'), 'archivo ajeno dentro del gestor', $script:Utf8)
}

$seedDestinationFile = {
    param([string]$LocalAppData)
    $managerRoot = Join-Path -Path $LocalAppData -ChildPath 'MensorCAD'
    $null = [System.IO.Directory]::CreateDirectory($managerRoot)
    [System.IO.File]::WriteAllText((Join-Path -Path $managerRoot -ChildPath 'cli'), 'esto es un archivo, no una carpeta', $script:Utf8)
}

$script:LinkCreated = $false
$seedDestinationLink = {
    param([string]$LocalAppData)
    $managerRoot = Join-Path -Path $LocalAppData -ChildPath 'MensorCAD'
    $outside = Join-Path -Path $LocalAppData -ChildPath 'fuera-del-gestor'
    $null = [System.IO.Directory]::CreateDirectory($managerRoot)
    $null = [System.IO.Directory]::CreateDirectory($outside)
    [System.IO.File]::WriteAllText((Join-Path -Path $outside -ChildPath 'intacto.txt'), 'no se debe seguir el enlace', $script:Utf8)
    try {
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path -Path $managerRoot -ChildPath 'cli') -Target $outside -ErrorAction Stop
        $script:LinkCreated = $true
    }
    catch {
        $script:LinkCreated = $false
    }
}

# ---------------------------------------------------------------------------
# Casos
# ---------------------------------------------------------------------------

Test-Case 'instala el gestor y registra el PATH de usuario una sola vez' {
    $initialPath = 'C:\Windows;C:\Herramientas;%USERPROFILE%\bin'
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue $initialPath -PathKind 'ExpandString'
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal (Get-SuccessStdout -Destination $case.Destination -State 'instalado') $case.Stdout 'stdout exacto del exito'
    Assert-Equal '' $case.Stderr 'el exito no debe escribir stderr'
    $expectedNames = @((@($script:ManagerFiles) + @($script:MarkerName)) | Sort-Object)
    Assert-Equal ($expectedNames -join ',') ((Get-InstalledNames -Case $case) -join ',') 'archivos instalados'
    $marker = Get-Marker -Destination $case.Destination
    Assert-Equal 'v1.2.3' ([string]$marker.version) 'el marcador debe guardar el tag resuelto'
    Assert-Equal 'MensorCAD-CLI' ([string]$marker.owner) 'el marcador identifica al gestor'
    Assert-Equal 3 (@($marker.files).Count) 'el marcador declara los tres archivos del gestor'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'mensorcad.cmd'))).StartsWith('@echo off') 'el contenido del ZIP se copia tal cual'
    Assert-Equal 1 ([int]$case.Result.Registry.SetCalls) 'una sola escritura de PATH'
    $entry = Get-RegistryEntry -Result $case.Result -Name 'Path'
    Assert-Equal ($initialPath + ';' + $case.Destination) $entry.value 'PATH con la carpeta nueva al final'
    Assert-Equal 'ExpandString' $entry.kind 'se conserva REG_EXPAND_SZ'
    Assert-Equal 1 (@(Get-ApiCalls -Case $case).Count) 'una sola resolucion del release'
    Assert-Equal 'https://api.github.com/repos/RonGrasz/Mensor-CAD/releases/latest' ([string](@(Get-ApiCalls -Case $case)[0])) 'URI de la API'
    $requests = @(Get-WebRequests -Case $case)
    Assert-Equal 2 $requests.Count 'ZIP y sidecar'
    Assert-Equal 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v1.2.3/MensorCAD-CLI.zip' ([string]$requests[0]) 'ZIP del tag fijado'
    Assert-Equal 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v1.2.3/MensorCAD-CLI.zip.sha256' ([string]$requests[1]) 'sidecar del tag fijado'
    Assert-True ([string]$case.Result.ProcessPath).Contains($case.Destination) 'el PATH del proceso actual debe incluir el gestor'
    Assert-False $case.PayloadSentinel 'el payload descargado nunca se debe ejecutar'
    Assert-Equal 'cli' ((Get-ManagedRootNames -Case $case) -join ',') 'la carpeta del gestor no deja staging ni respaldos'
}

Test-Case 'repetir la instalacion actualiza el gestor sin duplicar el PATH' {
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue 'C:\Windows;%LOCALAPPDATA%\MensorCAD\cli' -PathKind 'ExpandString' -Seed $seedPreviousInstall
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal (Get-SuccessStdout -Destination $case.Destination -State 'actualizado' -PathAlreadyRegistered) $case.Stdout 'stdout exacto'
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'no debe reescribir el PATH ya registrado'
    $entry = Get-RegistryEntry -Result $case.Result -Name 'Path'
    Assert-Equal 'C:\Windows;%LOCALAPPDATA%\MensorCAD\cli' $entry.value 'el PATH original queda intacto'
    $marker = Get-Marker -Destination $case.Destination
    Assert-Equal 'v1.2.3' ([string]$marker.version) 'el marcador se actualiza'
    $content = [System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'mensorcad.ps1'))
    Assert-False ($content -like 'anterior*') 'los archivos del gestor se reemplazan'
    Assert-Equal 'cli' ((Get-ManagedRootNames -Case $case) -join ',') 'sin respaldos ni staging'
}

Test-Case 'crea el PATH cuando el usuario no tenia el valor' {
    $case = Invoke-CliCase -CommandText $latestCommand -NoPathValue
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal (Get-SuccessStdout -Destination $case.Destination -State 'instalado') $case.Stdout 'stdout exacto'
    Assert-Equal 1 ([int]$case.Result.Registry.SetCalls) 'una escritura para crear el PATH'
    $entry = Get-RegistryEntry -Result $case.Result -Name 'Path'
    Assert-Equal $case.Destination $entry.value 'el PATH nuevo contiene solo el gestor'
    Assert-Equal 'ExpandString' $entry.kind 'PATH nuevo como REG_EXPAND_SZ'
}

Test-Case 'conserva REG_SZ y el contenido sin expandir del PATH existente' {
    $initialPath = 'C:\Windows;%USERPROFILE%\bin'
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue $initialPath -PathKind 'String'
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    $entry = Get-RegistryEntry -Result $case.Result -Name 'Path'
    Assert-Equal ($initialPath + ';' + $case.Destination) $entry.value 'PATH con la carpeta nueva al final'
    Assert-Equal 'String' $entry.kind 'se conserva REG_SZ'
}

Test-Case 'no duplica una entrada ya presente con mayusculas distintas' {
    $factory = {
        param([string]$LocalAppData)
        return 'C:\Windows;' + (Join-Path -Path $LocalAppData -ChildPath 'MensorCAD\cli').ToUpperInvariant()
    }
    $case = Invoke-CliCase -CommandText $latestCommand -PathValueFactory $factory -PathKind 'ExpandString'
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal (Get-SuccessStdout -Destination $case.Destination -State 'instalado' -PathAlreadyRegistered) $case.Stdout 'stdout exacto'
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'una entrada equivalente en mayusculas no se duplica'
    $entry = Get-RegistryEntry -Result $case.Result -Name 'Path'
    Assert-False ($entry.value.EndsWith($case.Destination)) 'el PATH no debe recibir una segunda entrada'
}

Test-Case 'una version fijada no consulta el release' {
    $case = Invoke-CliCase -CommandText $pinnedCommand
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal 0 (@(Get-ApiCalls -Case $case).Count) 'no se consulta la API con -Version'
    $requests = @(Get-WebRequests -Case $case)
    Assert-Equal 2 $requests.Count 'ZIP y sidecar'
    Assert-True ([string]$requests[0]).Contains('/releases/download/v1.2.3/') 'descarga del tag fijado'
}

Test-Case 'acepta tags de dos partes y preestrenos validos' {
    $case = Invoke-CliCase -CommandText (New-PinnedCommand -Tag 'v1.2')
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'v1.2 debe aceptarse'
    Assert-True ([string](@(Get-WebRequests -Case $case)[0])).Contains('/releases/download/v1.2/') 'descarga del tag v1.2'
    $case2 = Invoke-CliCase -CommandText (New-PinnedCommand -Tag 'v1.2.3-rc.1')
    Assert-CallerSurvived -Case $case2
    Assert-Equal '0' ([string]$case2.Result.LastExitCode) 'un preestreno valido debe aceptarse'
}

Test-Case 'un tag invalido falla antes de la red y de las escrituras' {
    $case = Invoke-CliCase -CommandText (New-PinnedCommand -Tag 'v1.2.3/malo') -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El tag de -Version no es valido: v1.2.3/malo. Se espera un tag como v1.2.3. No se descargo nada ni se escribio nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
    Assert-Equal 0 (@(Get-ApiCalls -Case $case).Count) 'sin consultas al release'
}

Test-Case 'un -Version vacio falla sin descargar nada' {
    $case = Invoke-CliCase -CommandText "&([scriptblock]::Create((irm 'https://github.com/RonGrasz/Mensor-CAD/releases/download/v1.2.3/install.ps1' -ea Stop))) -Version ''" -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'La opcion -Version necesita un tag, por ejemplo v1.2.3. No se descargo nada ni se escribio nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case '-NoAnimation se conserva y no rompe el flujo nuevo' {
    $case = Invoke-CliCase -CommandText $noAnimationCommand
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal (Get-SuccessStdout -Destination $case.Destination -State 'instalado') $case.Stdout 'stdout exacto'
    Assert-True ([System.IO.Directory]::Exists($case.Destination)) 'el gestor queda instalado'
}

Test-Case 'falla la consulta del release sin escribir nada' {
    $case = Invoke-CliCase -CommandText $latestCommand -Mode 'api-throw' -PathValue 'C:\Windows'
    Assert-CallerSurvived -Case $case
    Assert-Equal '1' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe informar el fallo'
    Assert-True $case.Stderr.StartsWith('ERROR: No se pudo consultar el release oficial de MensorCAD: ') 'mensaje de la API'
    Assert-True $case.Stderr.TrimEnd().EndsWith('No se instalo nada.') 'el mensaje debe negar la instalacion'
    Assert-Equal '' $case.Stdout 'sin stdout'
    Assert-False ([System.IO.Directory]::Exists($case.Destination)) 'sin escrituras en el destino'
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'sin escrituras de PATH'
    Assert-Equal 0 (@(Get-WebRequests -Case $case).Count) 'no se descarga nada'
}

Test-Case 'un release sin tag valido no instala nada' {
    $case = Invoke-CliCase -CommandText $latestCommand -Mode 'api-bad-tag' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El release oficial no informo un tag valido: malo. No se instalo nada.' -PathValue 'C:\Windows' -ExpectedWebRequests 0
    $case2 = Invoke-CliCase -CommandText $latestCommand -Mode 'api-empty' -PathValue 'C:\Windows'
    Assert-True $case2.Stderr.Contains('sin tag') 'un release vacio debe informar la ausencia de tag'
    Assert-False ([System.IO.Directory]::Exists($case2.Destination)) 'sin escrituras en el destino'
}

Test-Case 'una descarga fallida del ZIP no escribe nada' {
    $case = Invoke-CliCase -CommandText $latestCommand -Mode 'zip-throw' -PathValue 'C:\Windows'
    Assert-True $case.Stderr.StartsWith('ERROR: No se pudo descargar MensorCAD-CLI.zip del release v1.2.3: ') 'mensaje de descarga'
    Assert-Equal '1' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe informar el fallo'
    Assert-False ([System.IO.Directory]::Exists($case.Destination)) 'sin destino'
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'sin PATH'
    $case2 = Invoke-CliCase -CommandText $latestCommand -Mode 'zip-writeerror' -PathValue 'C:\Windows'
    Assert-Equal '1' ([string]$case2.Result.LastExitCode) 'un error no terminante de descarga tambien debe abortar'
    Assert-False ([System.IO.Directory]::Exists($case2.Destination)) 'sin destino'
}

Test-Case 'un sidecar ausente o vacio no escribe nada' {
    $case = Invoke-CliCase -CommandText $latestCommand -Mode 'sha-nofile' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El archivo descargado no existe o supera el limite permitido: MensorCAD-CLI.zip.sha256. No se instalo nada.' -PathValue 'C:\Windows'
    $case2 = Invoke-CliCase -CommandText $latestCommand -Mode 'sha-writeerror' -PathValue 'C:\Windows'
    Assert-Equal '1' ([string]$case2.Result.LastExitCode) 'un error no terminante del sidecar debe abortar'
}

Test-Case 'un SHA256 que no coincide deja el destino intacto' {
    $case = Invoke-CliCase -CommandText $latestCommand -AssetMode 'hash-mismatch' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El SHA256 del ZIP no coincide con el sidecar publicado. No se instalo nada.' -PathValue 'C:\Windows'
}

Test-Case 'un sidecar con formato invalido no escribe nada' {
    foreach ($mode in @('sidecar-malformed', 'sidecar-nonewline', 'sidecar-onespace', 'sidecar-wrong-name')) {
        $case = Invoke-CliCase -CommandText $latestCommand -AssetMode $mode -PathValue 'C:\Windows'
        Assert-FailureNoWrites -Case $case -ErrorMessage 'El sidecar SHA256 no tiene el formato esperado (64 hex, dos espacios, MensorCAD-CLI.zip y salto de linea). No se instalo nada.' -PathValue 'C:\Windows'
    }
}

Test-Case 'un ZIP con entradas que no son las tres exactas no escribe nada' {
    foreach ($mode in @('zip-extra', 'zip-missing-entry')) {
        $case = Invoke-CliCase -CommandText $latestCommand -AssetMode $mode -PathValue 'C:\Windows'
        Assert-FailureNoWrites -Case $case -ErrorMessage 'El ZIP no contiene exactamente mensorcad.ps1, mensorcad.cmd e Install-MensorCAD.ps1. No se instalo nada.' -PathValue 'C:\Windows'
    }
}

Test-Case 'un ZIP con duplicados o traversal no escribe nada' {
    foreach ($mode in @('zip-duplicate', 'zip-traversal')) {
        $case = Invoke-CliCase -CommandText $latestCommand -AssetMode $mode -PathValue 'C:\Windows'
        Assert-FailureNoWrites -Case $case -ErrorMessage 'El ZIP tiene entradas duplicadas, rutas no planas o nombres no permitidos. No se instalo nada.' -PathValue 'C:\Windows'
    }
}

Test-Case 'un ZIP con enlaces no escribe nada' {
    $case = Invoke-CliCase -CommandText $latestCommand -AssetMode 'zip-symlink' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El ZIP contiene una entrada que no es un archivo regular. No se instalo nada.' -PathValue 'C:\Windows'
}

Test-Case 'un ZIP sobredimensionado no escribe nada' {
    $case = Invoke-CliCase -CommandText $latestCommand -AssetMode 'zip-oversize' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El ZIP supera los limites de tamano permitidos. No se instalo nada.' -PathValue 'C:\Windows'
}

Test-Case 'un destino ajeno no se toca' {
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue 'C:\Windows' -Seed $seedForeignDestination
    Assert-FailureNoWrites -Case $case -ErrorMessage ('El destino no es una instalacion del gestor de MensorCAD: ' + $case.Destination + '. Se cancela sin tocar archivos ajenos.') -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0 -SkipDestinationAbsent
    Assert-Equal 'contenido ajeno intacto' ([System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'notas.txt'))) 'el archivo ajeno queda intacto'
}

Test-Case 'un archivo ajeno dentro del gestor instalado no se borra' {
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue 'C:\Windows' -Seed $seedManagedDestinationWithForeignFile
    Assert-FailureNoWrites -Case $case -ErrorMessage ('El destino no es una instalacion del gestor de MensorCAD: ' + $case.Destination + '. Se cancela sin tocar archivos ajenos.') -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0 -SkipDestinationAbsent
    Assert-Equal 'archivo ajeno dentro del gestor' ([System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'ajeno.txt'))) 'el archivo ajeno sigue ahi'
    Assert-Equal 'anterior mensorcad.ps1' ([System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'mensorcad.ps1'))) 'la instalacion anterior no se reemplaza'
}

Test-Case 'un destino que es un archivo no se toca' {
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue 'C:\Windows' -Seed $seedDestinationFile
    Assert-FailureNoWrites -Case $case -ErrorMessage ('El destino existe y no es una carpeta: ' + $case.Destination + '. Se cancela sin tocar archivos ajenos.') -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0 -SkipDestinationAbsent
    Assert-Equal 'esto es un archivo, no una carpeta' ([System.IO.File]::ReadAllText($case.Destination)) 'el archivo sigue ahi'
}

Test-Case 'un destino que es un punto de reanalisis no se sigue' {
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue 'C:\Windows' -Seed $seedDestinationLink
    if (-not $script:LinkCreated) {
        Skip-Case 'esta ruta no permite crear enlaces de directorio (privilegio o ruta de red); el rechazo de enlaces se cubre con la entrada simulado del ZIP'
        return
    }
    Assert-FailureNoWrites -Case $case -ErrorMessage ('El destino o su carpeta padre es un punto de reanalisis: ' + $case.Destination + '. Se cancela sin tocar archivos ajenos.') -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0 -SkipDestinationAbsent
    $outside = Join-Path -Path $case.LocalAppData -ChildPath 'fuera-del-gestor'
    Assert-Equal 'no se debe seguir el enlace' ([System.IO.File]::ReadAllText((Join-Path -Path $outside -ChildPath 'intacto.txt'))) 'el destino del enlace queda intacto'
}

Test-Case 'si falla el PATH se restaura el estado anterior' {
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue 'C:\Windows' -ThrowOnSet
    Assert-CallerSurvived -Case $case
    Assert-Equal '1' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe informar el fallo'
    Assert-True $case.Stderr.StartsWith('ERROR: No se pudo registrar la carpeta del gestor en el PATH del usuario: ') 'prefijo del fallo de PATH'
    Assert-True $case.Stderr.Contains('Acceso denegado simulado al PATH del usuario.') 'conserva la causa simulada'
    Assert-True $case.Stderr.TrimEnd().EndsWith('Se restauro la instalacion anterior.') 'el mensaje debe informar el rollback'
    Assert-Equal '' $case.Stdout 'un fallo no debe escribir stdout'
    Assert-False ([System.IO.Directory]::Exists($case.Destination)) 'la instalacion nueva se revierte'
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'el PATH no se escribe'
    $entry = Get-RegistryEntry -Result $case.Result -Name 'Path'
    Assert-Equal 'C:\Windows' $entry.value 'el PATH original queda intacto'
    Assert-NoLeftovers -Case $case
}

Test-Case 'el rollback devuelve la version anterior del gestor' {
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue 'C:\Windows' -Seed $seedPreviousInstall -ThrowOnSet
    Assert-Equal '1' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe informar el fallo'
    Assert-True $case.Stderr.Contains('Se restauro la instalacion anterior.') 'el mensaje debe informar el rollback'
    $marker = Get-Marker -Destination $case.Destination
    Assert-Equal 'v0.9.0' ([string]$marker.version) 'vuelve el marcador anterior'
    Assert-Equal 'anterior mensorcad.ps1' ([System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'mensorcad.ps1'))) 'vuelven los archivos anteriores'
    Assert-Equal 'cli' ((Get-ManagedRootNames -Case $case) -join ',') 'sin respaldos ni staging'
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'el PATH no se escribe'
}

Test-Case 'instala el gestor desde un ZIP local sin red y sin ejecutarlo' {
    $initialPath = 'C:\Windows;%USERPROFILE%\bin'
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'valid' -PathValue $initialPath -PathKind 'ExpandString'
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal (Get-SuccessStdout -Destination $case.Destination -State 'instalado') $case.Stdout 'stdout exacto del exito'
    Assert-Equal '' $case.Stderr 'el exito no debe escribir stderr'
    Assert-Equal 1 (@($case.Result.FetchCalls).Count) 'solo se carga install.ps1 una vez'
    Assert-SinRed -Case $case
    $expectedNames = @((@($script:ManagerFiles) + @($script:MarkerName)) | Sort-Object)
    Assert-Equal ($expectedNames -join ',') ((Get-InstalledNames -Case $case) -join ',') 'archivos instalados'
    $marker = Get-Marker -Destination $case.Destination
    Assert-Equal '1.2.3' ([string]$marker.version) 'el marcador guarda la version derivada del gestor local, no un tag inventado'
    Assert-Equal 'MensorCAD-CLI' ([string]$marker.owner) 'el marcador identifica al gestor'
    Assert-Equal 3 (@($marker.files).Count) 'el marcador declara los tres archivos del gestor'
    $installed = [System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'mensorcad.ps1'))
    Assert-Equal (Get-LocalManagerText -Version '1.2.3') $installed 'se instala el texto del ZIP local tal cual'
    Assert-Equal 1 ([int]$case.Result.Registry.SetCalls) 'una sola escritura de PATH'
    $entry = Get-RegistryEntry -Result $case.Result -Name 'Path'
    Assert-Equal ($initialPath + ';' + $case.Destination) $entry.value 'PATH con la carpeta nueva al final'
    Assert-Equal 'ExpandString' $entry.kind 'se conserva REG_EXPAND_SZ'
    Assert-True ([string]$case.Result.ProcessPath).Contains($case.Destination) 'el PATH del proceso actual debe incluir el gestor'
    Assert-False $case.PayloadSentinel 'el gestor del ZIP local nunca se debe ejecutar'
    Assert-NoLeftovers -Case $case
    foreach ($name in [System.IO.Directory]::GetFileSystemEntries($case.Temp)) {
        Assert-False ([System.IO.Path]::GetFileName($name) -like 'mensorcad-cli-*') ('quedo la carpeta temporal propia: ' + $name)
    }
    # La entrada elegida se copia: el ZIP local y su sidecar no se consumen ni
    # se reescriben durante la instalacion.
    Assert-True ([System.IO.File]::Exists($case.LocalZip)) 'el ZIP local sigue en su lugar'
    $sidecar = [System.IO.File]::ReadAllText($case.LocalZip + '.sha256')
    Assert-Equal ($sidecar -split ' ')[0] (Get-FileHash -LiteralPath $case.LocalZip -Algorithm SHA256).Hash.ToLowerInvariant() 'el ZIP local no cambio durante la instalacion'
}

Test-Case 'un -LocalZip relativo se resuelve en la sesion y no en el directorio del proceso' {
    # El proceso sonda arranca en la carpeta de Windows y la sesion se mueve a
    # la carpeta que tiene el ZIP y su sidecar: es el caso documentado de una
    # terminal donde se hizo Set-Location antes de ejecutar el comando. La ruta
    # relativa debe resolverse contra la ubicacion de la sesion.
    $initialPath = 'C:\Windows'
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '.\MensorCAD-CLI.zip'") -LocalAssetMode 'valid' -PathValue $initialPath -SessionInLocalInput
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal (Get-SuccessStdout -Destination $case.Destination -State 'instalado') $case.Stdout 'stdout exacto del exito'
    Assert-Equal '' $case.Stderr 'el exito no debe escribir stderr'
    Assert-SinRed -Case $case
    $expectedNames = @((@($script:ManagerFiles) + @($script:MarkerName)) | Sort-Object)
    Assert-Equal ($expectedNames -join ',') ((Get-InstalledNames -Case $case) -join ',') 'archivos instalados'
    $marker = Get-Marker -Destination $case.Destination
    Assert-Equal '1.2.3' ([string]$marker.version) 'el marcador guarda la version del ZIP elegido'
    Assert-Equal 1 ([int]$case.Result.Registry.SetCalls) 'una sola escritura de PATH'
    $entry = Get-RegistryEntry -Result $case.Result -Name 'Path'
    Assert-Equal ($initialPath + ';' + $case.Destination) $entry.value 'PATH con la carpeta nueva al final'
    Assert-False $case.PayloadSentinel 'el gestor del ZIP local nunca se debe ejecutar'
    Assert-NoLeftovers -Case $case
    Assert-True ([System.IO.File]::Exists($case.LocalZip)) 'el ZIP local sigue en su lugar'
}

Test-Case 'un -LocalZip relativo inexistente se rechaza con la ruta de la sesion' {
    # Ruta relativa que no existe en la carpeta de la sesion: el rechazo debe
    # nombrar la ruta de la sesion, no la del directorio del proceso, y no
    # puede haber red, escrituras ni destino.
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '.\no-existe.zip'") -LocalAssetMode 'zip-missing' -PathValue 'C:\Windows' -SessionInLocalInput
    Assert-CallerSurvived -Case $case
    Assert-Equal '1' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe informar el fallo'
    Assert-True $case.Stderr.StartsWith('ERROR: No se encontro el ZIP local indicado: ') 'prefijo del rechazo local'
    Assert-True $case.Stderr.Contains('\no-existe.zip. No se descargo nada ni se escribio nada.') 'el mensaje nombra el ZIP pedido'
    Assert-False $case.Stderr.Contains($env:SystemRoot) 'la ruta relativa no se resuelve contra el directorio del proceso'
    Assert-Equal '' $case.Stdout 'un fallo no debe escribir stdout'
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'no se debe escribir el PATH'
    Assert-SinRed -Case $case
    Assert-False ([System.IO.Directory]::Exists($case.ManagerRoot)) 'no se crea la carpeta del gestor'
    Assert-NoLeftovers -Case $case
}

Test-Case 'un -LocalZip que no es del sistema de archivos se rechaza sin red' {
    # Un proveedor que no es el de archivos (registro, entorno, variables) no
    # puede convertirse en una ruta del ZIP: se rechaza con el mismo mensaje de
    # ruta invalida y sin red, sin escrituras y sin tocar el destino.
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip 'HKLM:\SOFTWARE\MensorCAD-CLI.zip'") -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'La ruta de -LocalZip no es valida: HKLM:\SOFTWARE\MensorCAD-CLI.zip. No se descargo nada ni se escribio nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case 'la ruta local reutiliza el PATH ya registrado sin duplicarlo' {
    $factory = { param([string]$LocalAppData) return 'C:\Windows;' + $LocalAppData + '\MensorCAD\cli' }
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'valid' -PathValueFactory $factory -Seed $seedPreviousInstall
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal (Get-SuccessStdout -Destination $case.Destination -State 'actualizado' -PathAlreadyRegistered) $case.Stdout 'stdout exacto'
    Assert-SinRed -Case $case
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'no debe reescribir un PATH ya registrado'
    $marker = Get-Marker -Destination $case.Destination
    Assert-Equal '1.2.3' ([string]$marker.version) 'el marcador guarda la version local'
    $content = [System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'mensorcad.ps1'))
    Assert-False ($content -like 'anterior*') 'los archivos del gestor se reemplazan'
    Assert-NoLeftovers -Case $case
}

Test-Case 'si falla el PATH en la ruta local se revierte la instalacion' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'valid' -PathValue 'C:\Windows' -ThrowOnSet
    Assert-CallerSurvived -Case $case
    Assert-Equal '1' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe informar el fallo'
    Assert-True $case.Stderr.StartsWith('ERROR: No se pudo registrar la carpeta del gestor en el PATH del usuario: ') 'prefijo del fallo de PATH'
    Assert-True $case.Stderr.TrimEnd().EndsWith('Se restauro la instalacion anterior.') 'el mensaje debe informar el rollback'
    Assert-Equal '' $case.Stdout 'un fallo no debe escribir stdout'
    Assert-False ([System.IO.Directory]::Exists($case.Destination)) 'la instalacion nueva se revierte'
    Assert-Equal 0 ([int]$case.Result.Registry.SetCalls) 'el PATH no se escribe'
    Assert-SinRed -Case $case
    Assert-NoLeftovers -Case $case
}

Test-Case 'el rollback de la ruta local devuelve la version anterior' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'valid' -PathValue 'C:\Windows' -Seed $seedPreviousInstall -ThrowOnSet
    Assert-Equal '1' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe informar el fallo'
    Assert-True $case.Stderr.Contains('Se restauro la instalacion anterior.') 'el mensaje debe informar el rollback'
    $marker = Get-Marker -Destination $case.Destination
    Assert-Equal 'v0.9.0' ([string]$marker.version) 'vuelve el marcador anterior'
    Assert-Equal 'anterior mensorcad.ps1' ([System.IO.File]::ReadAllText((Join-Path -Path $case.Destination -ChildPath 'mensorcad.ps1'))) 'vuelven los archivos anteriores'
    Assert-Equal 'cli' ((Get-ManagedRootNames -Case $case) -join ',') 'sin respaldos ni staging'
    Assert-SinRed -Case $case
}

Test-Case 'un ZIP local sin sidecar adjunto no escribe nada' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'sidecar-missing' -PathValue 'C:\Windows'
    $expected = 'Falta el sidecar SHA256 junto al ZIP local: ' + $case.LocalZip + '.sha256. No se instalo nada.'
    Assert-FailureNoWrites -Case $case -ErrorMessage $expected -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
    Assert-True ([System.IO.File]::Exists($case.LocalZip)) 'el ZIP local no se toca'
}

Test-Case 'un SHA256 local que no coincide deja el destino intacto' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'hash-mismatch' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El SHA256 del ZIP no coincide con el sidecar publicado. No se instalo nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case 'un sidecar local con formato invalido no escribe nada' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'sidecar-malformed' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El sidecar SHA256 no tiene el formato esperado (64 hex, dos espacios, MensorCAD-CLI.zip y salto de linea). No se instalo nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case 'el sidecar del ZIP del complemento no sirve como sidecar del gestor' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'zip-windows' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El sidecar SHA256 no tiene el formato esperado (64 hex, dos espacios, MensorCAD-CLI.zip y salto de linea). No se instalo nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case 'un ZIP local con entradas que no son las tres exactas no escribe nada' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'zip-extra' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El ZIP no contiene exactamente mensorcad.ps1, mensorcad.cmd e Install-MensorCAD.ps1. No se instalo nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case 'un mensorcad.ps1 local sin version sellada no escribe nada' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'unversioned' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El mensorcad.ps1 del ZIP local no declara una version estable sellada, por ejemplo 1.2.3. No se instalo nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
    Assert-False $case.PayloadSentinel 'la version se lee como texto; el gestor no se ejecuta'
}

Test-Case 'un mensorcad.ps1 local con dos versiones no escribe nada' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'ambiguous' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'El mensorcad.ps1 del ZIP local declara mas de una version. No se instalo nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case 'la ruta local rechaza -Version antes de la red y de las escrituras' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@' -Version v1.2.3") -LocalAssetMode 'valid' -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'Las opciones -LocalZip y -Version no se pueden combinar: -Version fija un release publicado y -LocalZip instala un ZIP local. No se descargo nada ni se escribio nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
    Assert-True ([System.IO.File]::Exists($case.LocalZip)) 'el ZIP local no se toca'
}

Test-Case 'un -LocalZip vacio falla sin descargar nada' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip ''") -PathValue 'C:\Windows'
    Assert-FailureNoWrites -Case $case -ErrorMessage 'La opcion -LocalZip necesita la ruta de un ZIP local, por ejemplo MensorCAD-CLI.zip. No se descargo nada ni se escribio nada.' -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case 'un -LocalZip inexistente falla antes de la red y del destino' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'zip-missing' -PathValue 'C:\Windows'
    $expected = 'No se encontro el ZIP local indicado: ' + $case.LocalZip + '. No se descargo nada ni se escribio nada.'
    Assert-FailureNoWrites -Case $case -ErrorMessage $expected -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
    Assert-False ([System.IO.Directory]::Exists($case.ManagerRoot)) 'no se crea la carpeta del gestor'
}

Test-Case 'un -LocalZip que es una carpeta falla sin tocar el destino' {
    $case = Invoke-CliCase -CommandTemplate (New-LocalCommandTemplate "-LocalZip '@@LOCALZIP@@'") -LocalAssetMode 'zip-directory' -PathValue 'C:\Windows'
    Assert-True ([System.IO.Directory]::Exists($case.LocalZip)) 'la fixture debe ser una carpeta con el nombre del ZIP'
    Assert-FailureNoWrites -Case $case -ErrorMessage ('No se encontro el ZIP local indicado: ' + $case.LocalZip + '. No se descargo nada ni se escribio nada.') -PathValue 'C:\Windows' -ExpectedApiCalls 0 -ExpectedWebRequests 0
}

Test-Case 'la ruta remota sigue intacta junto a la ruta local' {
    $case = Invoke-CliCase -CommandText $latestCommand -PathValue 'C:\Windows'
    Assert-CallerSurvived -Case $case
    Assert-Equal '0' ([string]$case.Result.LastExitCode) 'LASTEXITCODE debe ser 0'
    Assert-Equal 1 (@(Get-ApiCalls -Case $case).Count) 'la ruta remota resuelve el release una sola vez'
    Assert-Equal 2 (@(Get-WebRequests -Case $case).Count) 'la ruta remota descarga ZIP y sidecar'
    $marker = Get-Marker -Destination $case.Destination
    Assert-Equal 'v1.2.3' ([string]$marker.version) 'la ruta remota sigue guardando el tag resuelto'
    Assert-NoLeftovers -Case $case
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ('RESULTADO: ' + $script:Passed + ' correctas, ' + $script:Failed + ' fallidas, ' + $script:Skipped + ' omitidas.')
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
