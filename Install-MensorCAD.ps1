<#
.SYNOPSIS
    Instalador local de MensorCAD para AutoCAD.

.DESCRIPTION
    Instala, actualiza o desinstala el bundle MensorCAD.bundle en el destino
    fijo de Program Files. El paquete local se valida con bundle.sha256 antes
    de pedir elevacion UAC y se vuelve a validar despues de elevar y despues
    de preparar la etapa temporal.

    El motor interno (Install-MensorCadBundle / Uninstall-MensorCadBundle) no
    eleva permisos ni escribe en Program Files por si mismo. La entrada remota
    puede reutilizar ese motor sobre una carpeta extraida y verificada.

.PARAMETER Uninstall
    Desinstala la copia propia de MensorCAD del destino fijo.

.PARAMETER NoAnimation
    Desactiva colores y animaciones. Tambien se activa solo cuando la salida
    esta redirigida.

.PARAMETER Help
    Muestra la ayuda y sale con codigo 0.

.PARAMETER Version
    Fija un tag concreto de la release de GitHub. Requiere -FromRelease. Si se
    omite se resuelve la ultima release publicada una sola vez.

.PARAMETER FromRelease
    Descarga el paquete MensorCAD-Windows.zip desde el repositorio fijo
    RonGrasz/Mensor-CAD, verifica su SHA-256, inspecciona el ZIP y ejecuta el
    instalador incluido en el paquete extraido. Reutiliza el motor local, el
    destino fijo y la elevacion UAC.

.PARAMETER ElevatedProcess
    Reservado. Lo usa la relanzada elevada para no repetir el banner. No evita
    ninguna comprobacion de administrador.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoAnimation,
    [switch]$Help,
    [string]$Version,
    [switch]$FromRelease,
    [switch]$ElevatedProcess
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:MensorCadProductName = 'MensorCAD'
$script:MensorCadBundleFolderName = 'MensorCAD.bundle'
$script:MensorCadManifestFileName = 'bundle.sha256'
$script:MensorCadMarkerFileName = '.mensorcad-install.json'
$script:MensorCadMarkerFormat = 'mensorcad-bundle-marker'
$script:MensorCadMarkerVersion = 1
$script:MensorCadScriptRoot = $PSScriptRoot
$script:MensorCadScriptPath = $PSCommandPath
$script:MensorCadDotSourced = ($MyInvocation.InvocationName -eq '.')
$script:MensorCadPlainMode = $false
$script:MensorCadSpinnerIndex = 0
# Tipo nativo de la sonda de consola. Se resuelve de forma perezosa: cargar el
# archivo con dot-source no registra tipos ni toca ninguna ventana.
$script:MensorCadConsoleNativeType = $null

# ---------------------------------------------------------------------------
# Utilidades de rutas, hashes y salida
# ---------------------------------------------------------------------------

function Test-MensorCadWindows {
    return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

function Test-MensorCad64BitOperatingSystem {
    return [Environment]::Is64BitOperatingSystem
}

function Test-MensorCad64BitProcess {
    return [Environment]::Is64BitProcess
}

function Assert-MensorCad64BitHost {
    if (-not (Test-MensorCad64BitOperatingSystem) -or -not (Test-MensorCad64BitProcess)) {
        throw 'MensorCAD requiere Windows de 64 bits y PowerShell de 64 bits. Ejecute Instalar.bat o el powershell.exe nativo de 64 bits. No se escribio ningun archivo.'
    }
}

function Test-MensorCadOutputRedirected {
    try {
        return [Console]::IsOutputRedirected
    }
    catch {
        return $true
    }
}

function Get-MensorCadPowerShellPath {
    $powerShellPath = 'powershell.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $candidatePath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $powerShellPath = $candidatePath
        }
    }
    return $powerShellPath
}

function Test-MensorCadAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName 'Security.Principal.WindowsPrincipal' -ArgumentList $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MensorCadProgramFilesRoot {
    $root = [Environment]::GetFolderPath('ProgramFiles')
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'No se pudo resolver la carpeta especial Program Files.'
    }
    return $root
}

function Get-MensorCadDestinationRoot {
    $root = Get-MensorCadProgramFilesRoot
    return [System.IO.Path]::Combine($root, 'Autodesk', 'ApplicationPlugins', $script:MensorCadBundleFolderName)
}

function Get-MensorCadFileHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-MensorCadReparsePoint {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        throw "No se pudo inspeccionar '$Path' para detectar puntos de reanalisis."
    }
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-MensorCadNoReparseInPath {
    param([string]$Path, [string]$Boundary)
    $full = [System.IO.Path]::GetFullPath($Path)
    $limit = [System.IO.Path]::GetFullPath($Boundary)
    $separators = [char[]]@('\', '/')
    $fullTrim = $full.TrimEnd($separators)
    $limitTrim = $limit.TrimEnd($separators)
    while ($true) {
        if (Test-Path -LiteralPath $full) {
            if (Test-MensorCadReparsePoint -Path $full) {
                throw "La ruta '$full' atraviesa un punto de reanalisis (junction o enlace) no permitido."
            }
        }
        if ($fullTrim -ieq $limitTrim) { break }
        $parent = [System.IO.Path]::GetDirectoryName($full)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $full) { break }
        if ($parent.Length -lt $limit.Length) { break }
        $full = $parent
        $fullTrim = $full.TrimEnd($separators)
    }
}

function Get-MensorCadRelativePath {
    param([string]$BasePath, [string]$Path)
    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [string][System.IO.Path]::DirectorySeparatorChar
    }
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "La ruta '$pathFull' no esta dentro de '$baseFull'."
    }
    return $pathFull.Substring($baseFull.Length).Replace('\', '/')
}

function Assert-MensorCadRelativePath {
    param([string]$RelativePath, [string]$Context)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "${Context}: la ruta relativa esta vacia."
    }
    if ($RelativePath.Contains('\')) {
        throw "${Context}: la ruta '$RelativePath' debe usar barras '/'."
    }
    if ($RelativePath.StartsWith('/')) {
        throw "${Context}: la ruta '$RelativePath' no puede ser absoluta."
    }
    if ($RelativePath -match '^[A-Za-z]:') {
        throw "${Context}: la ruta '$RelativePath' no puede incluir una unidad."
    }
    $segments = $RelativePath.Split('/')
    foreach ($segment in $segments) {
        if ($segment.Length -eq 0) {
            throw "${Context}: la ruta '$RelativePath' contiene un segmento vacio."
        }
        if ($segment -eq '.' -or $segment -eq '..') {
            throw "${Context}: la ruta '$RelativePath' contiene un segmento no permitido ('$segment')."
        }
        if ($segment.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "${Context}: la ruta '$RelativePath' contiene caracteres no validos."
        }
    }
    if ($RelativePath -ieq $script:MensorCadMarkerFileName) {
        throw "${Context}: la ruta '$RelativePath' esta reservada para la marca de instalacion."
    }
}

function Assert-MensorCadPathSegments {
    param([string]$BundleRoot, [string]$RelativePath)
    $segments = $RelativePath.Split('/')
    $current = $BundleRoot
    for ($index = 0; $index -lt ($segments.Length - 1); $index++) {
        $current = Join-Path -Path $current -ChildPath $segments[$index]
        if (Test-Path -LiteralPath $current) {
            if (-not (Test-Path -LiteralPath $current -PathType Container)) {
                throw "La ruta '$RelativePath' no apunta a un archivo dentro de un directorio valido."
            }
            if (Test-MensorCadReparsePoint -Path $current) {
                throw "La ruta '$RelativePath' atraviesa un punto de reanalisis en '$current'."
            }
        }
    }
}

function Get-MensorCadDirectoryTree {
    param([string]$RootPath)
    $files = New-Object 'System.Collections.Generic.List[string]'
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object System.Collections.Stack
    $pending.Push($RootPath)
    while ($pending.Count -gt 0) {
        $current = [string]$pending.Pop()
        $entries = [System.IO.Directory]::GetFileSystemEntries($current)
        foreach ($entry in $entries) {
            $attributes = [System.IO.File]::GetAttributes($entry)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Se rechazo un punto de reanalisis (enlace o junction) en la ruta: $entry"
            }
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $directories.Add($entry)
                $pending.Push($entry)
            }
            else {
                $files.Add($entry)
            }
        }
    }
    return [pscustomobject]@{ Files = $files; Directories = $directories }
}

function Remove-MensorCadTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Se esperaba un directorio para eliminar: '$Path'."
    }
    if (Test-MensorCadReparsePoint -Path $Path) {
        throw "Se rechazo eliminar un punto de reanalisis: '$Path'."
    }
    $tree = Get-MensorCadDirectoryTree -RootPath $Path
    foreach ($filePath in $tree.Files) {
        [System.IO.File]::Delete($filePath)
    }
    $sortedDirectories = $tree.Directories.ToArray() | Sort-Object -Property Length -Descending
    foreach ($directory in $sortedDirectories) {
        if (Test-Path -LiteralPath $directory) {
            $remaining = [System.IO.Directory]::GetFileSystemEntries($directory)
            if ($remaining.Count -eq 0) {
                [System.IO.Directory]::Delete($directory, $false)
            }
        }
    }
    $remainingAtRoot = [System.IO.Directory]::GetFileSystemEntries($Path)
    if ($remainingAtRoot.Count -ne 0) {
        throw "No se pudo vaciar el directorio temporal '$Path'."
    }
    [System.IO.Directory]::Delete($Path, $false)
}

# ---------------------------------------------------------------------------
# Manifiesto, origen e inventario instalado
# ---------------------------------------------------------------------------

function Read-MensorCadManifest {
    param([string]$ManifestPath, [string]$BundleRoot)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "No se encontro el manifiesto bundle.sha256 en '$ManifestPath'. Extraiga el paquete completo antes de instalar."
    }
    if (Test-MensorCadReparsePoint -Path $ManifestPath) {
        throw "El manifiesto '$ManifestPath' es un punto de reanalisis y se rechazo."
    }
    $lines = [System.IO.File]::ReadAllLines($ManifestPath)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line, '^([0-9a-fA-F]{64})  (.+)$')
        if (-not $match.Success) {
            throw "bundle.sha256, linea ${lineNumber}: formato invalido. Se esperaba '<sha256>  <ruta>'."
        }
        $hash = $match.Groups[1].Value.ToLowerInvariant()
        $relativePath = $match.Groups[2].Value
        Assert-MensorCadRelativePath -RelativePath $relativePath -Context "bundle.sha256, linea $lineNumber"
        if ($seen.ContainsKey($relativePath)) {
            throw "bundle.sha256 contiene una entrada duplicada: '$relativePath'."
        }
        $seen[$relativePath] = $true
        $entries.Add([pscustomobject]@{ RelativePath = $relativePath; Sha256 = $hash })
    }
    if ($entries.Count -eq 0) {
        throw 'bundle.sha256 no contiene entradas.'
    }
    $paths = @()
    foreach ($entry in $entries) { $paths += $entry.RelativePath }
    if (-not ($paths -contains 'PackageContents.xml')) {
        throw 'El paquete no declara PackageContents.xml en bundle.sha256.'
    }
    if (-not ($paths -match '^Contents/Lisp/.+\.lsp$')) {
        throw 'El paquete no declara ningun archivo Contents/Lisp/*.lsp en bundle.sha256.'
    }
    if (-not ($paths -contains 'Contents/UI/MensorCAD.cuix')) {
        throw 'El paquete no declara Contents/UI/MensorCAD.cuix en bundle.sha256.'
    }
    $manifestHash = Get-MensorCadFileHash -Path $ManifestPath
    return [pscustomobject]@{
        Entries = $entries
        ManifestSha256 = $manifestHash
        ManifestPath = $ManifestPath
        BundleRoot = $BundleRoot
    }
}

function Test-MensorCadSource {
    param([string]$SourceRoot, [scriptblock]$ProgressCallback)
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "No existe la carpeta de origen '$SourceRoot'."
    }
    if (Test-MensorCadReparsePoint -Path $SourceRoot) {
        throw "La carpeta de origen '$SourceRoot' es un punto de reanalisis y se rechazo."
    }
    $bundleRoot = Join-Path -Path $SourceRoot -ChildPath $script:MensorCadBundleFolderName
    $manifestPath = Join-Path -Path $SourceRoot -ChildPath $script:MensorCadManifestFileName
    if (-not (Test-Path -LiteralPath $bundleRoot -PathType Container)) {
        throw "No se encontro la carpeta del paquete '$bundleRoot'. Extraiga el ZIP completo antes de instalar."
    }
    if (Test-MensorCadReparsePoint -Path $bundleRoot) {
        throw "La carpeta del paquete '$bundleRoot' es un punto de reanalisis y se rechazo."
    }
    $manifest = Read-MensorCadManifest -ManifestPath $manifestPath -BundleRoot $bundleRoot
    $expected = @{}
    $index = 0
    foreach ($entry in $manifest.Entries) {
        $index++
        Assert-MensorCadPathSegments -BundleRoot $bundleRoot -RelativePath $entry.RelativePath
        $fullPath = Join-Path -Path $bundleRoot -ChildPath ($entry.RelativePath.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Falta el archivo declarado '$($entry.RelativePath)' en el paquete local."
        }
        if (Test-MensorCadReparsePoint -Path $fullPath) {
            throw "El archivo '$($entry.RelativePath)' es un punto de reanalisis y se rechazo."
        }
        if ($ProgressCallback) {
            $null = & $ProgressCallback 'hash' $index $manifest.Entries.Count $entry.RelativePath
        }
        $actualHash = Get-MensorCadFileHash -Path $fullPath
        if ($actualHash -ne $entry.Sha256) {
            throw "El hash de '$($entry.RelativePath)' no coincide con bundle.sha256. El paquete esta danado o fue modificado."
        }
        $expected[$entry.RelativePath] = $true
    }
    $tree = Get-MensorCadDirectoryTree -RootPath $bundleRoot
    foreach ($filePath in $tree.Files) {
        $relative = Get-MensorCadRelativePath -BasePath $bundleRoot -Path $filePath
        if (-not $expected.ContainsKey($relative)) {
            throw "El paquete contiene un archivo no declarado en bundle.sha256: '$relative'."
        }
    }
    return [pscustomobject]@{
        SourceRoot = $SourceRoot
        BundleRoot = $bundleRoot
        ManifestPath = $manifestPath
        ManifestSha256 = $manifest.ManifestSha256
        Entries = $manifest.Entries
        FileCount = $manifest.Entries.Count
    }
}

function Read-MensorCadMarker {
    param([string]$MarkerPath)
    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        throw "Falta la marca de instalacion '$MarkerPath'."
    }
    if (Test-MensorCadReparsePoint -Path $MarkerPath) {
        throw "La marca de instalacion '$MarkerPath' es un punto de reanalisis y se rechazo."
    }
    $parsed = $null
    try {
        $parsed = (Get-Content -LiteralPath $MarkerPath -Raw -Encoding UTF8) | ConvertFrom-Json
    }
    catch {
        throw "La marca de instalacion '$MarkerPath' no contiene JSON valido."
    }
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['format']) {
        throw "La marca de instalacion no tiene el campo 'format'."
    }
    if ([string]$parsed.format -ne $script:MensorCadMarkerFormat) {
        throw 'La marca de instalacion no pertenece a MensorCAD (format inesperado).'
    }
    if (-not $parsed.PSObject.Properties['formatVersion'] -or ([string]$parsed.formatVersion) -ne ([string]$script:MensorCadMarkerVersion)) {
        throw 'La marca de instalacion tiene una version no soportada.'
    }
    if (-not $parsed.PSObject.Properties['product'] -or [string]$parsed.product -ne $script:MensorCadProductName) {
        throw 'La marca de instalacion no pertenece al producto MensorCAD.'
    }
    if (-not $parsed.PSObject.Properties['sourceManifestSha256'] -or ([string]$parsed.sourceManifestSha256) -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'La marca de instalacion no tiene un sourceManifestSha256 valido.'
    }
    if (-not $parsed.PSObject.Properties['installedAtUtc'] -or [string]::IsNullOrWhiteSpace([string]$parsed.installedAtUtc)) {
        throw 'La marca de instalacion no tiene installedAtUtc.'
    }
    if (-not $parsed.PSObject.Properties['files']) {
        throw "La marca de instalacion no tiene el inventario 'files'."
    }
    $rawFiles = @($parsed.files)
    if ($rawFiles.Count -eq 0) {
        throw 'La marca de instalacion no registra archivos.'
    }
    $files = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($file in $rawFiles) {
        if ($null -eq $file -or -not $file.PSObject.Properties['path'] -or -not $file.PSObject.Properties['sha256']) {
            throw 'La marca de instalacion contiene una entrada de archivo invalida.'
        }
        $relativePath = [string]$file.path
        $hash = ([string]$file.sha256).ToLowerInvariant()
        Assert-MensorCadRelativePath -RelativePath $relativePath -Context 'marca de instalacion'
        if ($hash -notmatch '^[0-9a-f]{64}$') {
            throw "La marca de instalacion contiene un hash invalido para '$relativePath'."
        }
        if ($seen.ContainsKey($relativePath)) {
            throw "La marca de instalacion contiene una entrada duplicada: '$relativePath'."
        }
        $seen[$relativePath] = $true
        $files.Add([pscustomobject]@{ Path = $relativePath; Sha256 = $hash })
    }
    return [pscustomobject]@{
        Files = $files
        SourceManifestSha256 = ([string]$parsed.sourceManifestSha256).ToLowerInvariant()
        InstalledAtUtc = [string]$parsed.installedAtUtc
        MarkerPath = $MarkerPath
    }
}

function New-MensorCadMarkerObject {
    param([string]$SourceManifestSha256, [object[]]$FileEntries)
    $files = @()
    foreach ($entry in $FileEntries) {
        $files += [pscustomobject][ordered]@{ path = $entry.RelativePath; sha256 = $entry.Sha256 }
    }
    $installedAt = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    return [pscustomobject][ordered]@{
        format = $script:MensorCadMarkerFormat
        formatVersion = $script:MensorCadMarkerVersion
        product = $script:MensorCadProductName
        installedAtUtc = $installedAt
        sourceManifestSha256 = $SourceManifestSha256
        files = $files
    }
}

function Write-MensorCadMarker {
    param([string]$DestinationRoot, $SourceInfo)
    $marker = New-MensorCadMarkerObject -SourceManifestSha256 $SourceInfo.ManifestSha256 -FileEntries $SourceInfo.Entries
    $json = $marker | ConvertTo-Json -Depth 6
    $markerPath = Join-Path -Path $DestinationRoot -ChildPath $script:MensorCadMarkerFileName
    $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($false)
    [System.IO.File]::WriteAllText($markerPath, $json + "`r`n", $encoding)
}

function Test-MensorCadInventoryMatches {
    param($Marker, $SourceInfo)
    if ($null -eq $Marker.Files -or $null -eq $SourceInfo.Entries) { return $false }
    $installed = $Marker.Files
    $source = $SourceInfo.Entries
    if ($installed.Count -ne $source.Count) { return $false }
    $map = @{}
    foreach ($entry in $source) { $map[$entry.RelativePath] = $entry.Sha256 }
    foreach ($file in $installed) {
        if (-not $map.ContainsKey($file.Path)) { return $false }
        if ($map[$file.Path] -ne $file.Sha256) { return $false }
    }
    return $true
}

function Test-MensorCadSourceEntriesMatch {
    param($LeftEntries, $RightEntries)
    if ($null -eq $LeftEntries -or $null -eq $RightEntries) { return $false }
    if ($LeftEntries.Count -ne $RightEntries.Count) { return $false }
    $map = @{}
    foreach ($entry in $LeftEntries) { $map[$entry.RelativePath] = $entry.Sha256 }
    foreach ($entry in $RightEntries) {
        if (-not $map.ContainsKey($entry.RelativePath)) { return $false }
        if ($map[$entry.RelativePath] -ne $entry.Sha256) { return $false }
    }
    return $true
}

function Assert-MensorCadOwnedDestination {
    param([string]$DestinationRoot)
    if (-not (Test-Path -LiteralPath $DestinationRoot)) { return $null }
    if (Test-MensorCadReparsePoint -Path $DestinationRoot) {
        throw "El destino '$DestinationRoot' es un punto de reanalisis y se rechazo."
    }
    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        throw "El destino '$DestinationRoot' existe y no es un directorio."
    }
    $markerPath = Join-Path -Path $DestinationRoot -ChildPath $script:MensorCadMarkerFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "El destino '$DestinationRoot' ya existe y no pertenece a MensorCAD (falta .mensorcad-install.json). No se modificara."
    }
    $marker = Read-MensorCadMarker -MarkerPath $markerPath
    $tree = Get-MensorCadDirectoryTree -RootPath $DestinationRoot
    $expected = @{}
    foreach ($file in $marker.Files) { $expected[$file.Path] = $file.Sha256 }
    $expected[$script:MensorCadMarkerFileName] = $null
    foreach ($filePath in $tree.Files) {
        $relative = Get-MensorCadRelativePath -BasePath $DestinationRoot -Path $filePath
        if (-not $expected.ContainsKey($relative)) {
            throw "La instalacion existente contiene archivos no reconocidos: '$relative'. No se modificara."
        }
        if ($relative -ieq $script:MensorCadMarkerFileName) { continue }
        $actualHash = Get-MensorCadFileHash -Path $filePath
        if ($actualHash -ne $expected[$relative]) {
            throw "La instalacion existente esta modificada: '$relative'. No se modificara."
        }
    }
    foreach ($file in $marker.Files) {
        $fullPath = Join-Path -Path $DestinationRoot -ChildPath ($file.Path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Falta el archivo registrado '$($file.Path)' en la instalacion existente. No se modificara."
        }
    }
    if ($tree.Files.Count -ne ($marker.Files.Count + 1)) {
        throw 'La instalacion existente no coincide con su inventario. No se modificara.'
    }
    return $marker
}

function Test-MensorCadAutoCadRunning {
    foreach ($processName in @('acad', 'acadlt')) {
        $process = Get-Process -Name $processName -ErrorAction SilentlyContinue
        if ($null -ne $process) { return $true }
    }
    return $false
}

function Invoke-MensorCadPhase {
    param([scriptblock]$PhaseHook, [string]$PhaseName, [hashtable]$Context)
    if ($PhaseHook) {
        $null = & $PhaseHook $PhaseName $Context
    }
}

# ---------------------------------------------------------------------------
# Motor local reutilizable (sin elevacion ni destino fijo)
# ---------------------------------------------------------------------------

function Install-MensorCadBundle {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [string]$TrustedBoundary,
        [scriptblock]$AutoCadProbe,
        [scriptblock]$PhaseHook,
        [scriptblock]$ProgressCallback
    )
    $sourceInfo = Test-MensorCadSource -SourceRoot $SourceRoot -ProgressCallback $ProgressCallback
    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    if ([System.IO.Path]::GetFileName($destination) -ine $script:MensorCadBundleFolderName) {
        throw "El destino interno debe terminar en '$($script:MensorCadBundleFolderName)'."
    }
    if ([string]::IsNullOrWhiteSpace($TrustedBoundary)) {
        $TrustedBoundary = [System.IO.Path]::GetPathRoot($destination)
    }
    Assert-MensorCadNoReparseInPath -Path $destination -Boundary $TrustedBoundary

    $existingMarker = Assert-MensorCadOwnedDestination -DestinationRoot $destination

    if (-not $AutoCadProbe) {
        $AutoCadProbe = { Test-MensorCadAutoCadRunning }
    }
    if (& $AutoCadProbe) {
        throw 'AutoCAD esta en ejecucion. Cierre AutoCAD y vuelva a ejecutar el instalador. No se cerro AutoCAD automaticamente.'
    }

    if ($null -ne $existingMarker -and (Test-MensorCadInventoryMatches -Marker $existingMarker -SourceInfo $sourceInfo)) {
        return [pscustomobject]@{
            Status = 'unchanged'
            FileCount = $sourceInfo.FileCount
            DestinationRoot = $destination
            MarkerPath = (Join-Path -Path $destination -ChildPath $script:MensorCadMarkerFileName)
            CleanupWarnings = @()
        }
    }

    $parent = [System.IO.Path]::GetDirectoryName($destination)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "No se pudo resolver el directorio padre de '$destination'."
    }
    if (Test-Path -LiteralPath $parent -PathType Leaf) {
        throw "El directorio padre '$parent' existe como archivo. No se puede instalar el bundle."
    }
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    Assert-MensorCadNoReparseInPath -Path $destination -Boundary $TrustedBoundary

    $transactionRoot = Join-Path -Path $parent -ChildPath ('.mensorcad-tx-' + [guid]::NewGuid().ToString('N'))
    $stagingRoot = Join-Path -Path $transactionRoot -ChildPath 'staging'
    $stagingBundle = Join-Path -Path $stagingRoot -ChildPath $script:MensorCadBundleFolderName
    $backupRoot = Join-Path -Path $transactionRoot -ChildPath 'backup'
    $backupBundle = Join-Path -Path $backupRoot -ChildPath $script:MensorCadBundleFolderName
    $backupCreated = $false
    $swapped = $false

    try {
        $null = New-Item -ItemType Directory -Path $stagingBundle -Force
        $null = New-Item -ItemType Directory -Path $backupRoot -Force

        $index = 0
        foreach ($entry in $sourceInfo.Entries) {
            $index++
            $sourceFile = Join-Path -Path $sourceInfo.BundleRoot -ChildPath ($entry.RelativePath.Replace('/', '\'))
            $stagedFile = Join-Path -Path $stagingBundle -ChildPath ($entry.RelativePath.Replace('/', '\'))
            $stagedParent = Split-Path -Parent $stagedFile
            if (-not (Test-Path -LiteralPath $stagedParent)) {
                $null = New-Item -ItemType Directory -Path $stagedParent -Force
            }
            if ($ProgressCallback) {
                $null = & $ProgressCallback 'copy' $index $sourceInfo.Entries.Count $entry.RelativePath
            }
            [System.IO.File]::Copy($sourceFile, $stagedFile, $false)
            $stagedHash = Get-MensorCadFileHash -Path $stagedFile
            if ($stagedHash -ne $entry.Sha256) {
                throw "La copia temporal de '$($entry.RelativePath)' no coincide con el hash del paquete."
            }
        }

        $stagedExpected = @{}
        foreach ($entry in $sourceInfo.Entries) { $stagedExpected[$entry.RelativePath] = $true }
        $stagedTree = Get-MensorCadDirectoryTree -RootPath $stagingBundle
        foreach ($filePath in $stagedTree.Files) {
            $relative = Get-MensorCadRelativePath -BasePath $stagingBundle -Path $filePath
            if (-not $stagedExpected.ContainsKey($relative)) {
                throw "La etapa temporal contiene un archivo inesperado: '$relative'."
            }
        }
        if ($stagedTree.Files.Count -ne $sourceInfo.Entries.Count) {
            throw 'La etapa temporal no contiene todos los archivos declarados.'
        }

        Invoke-MensorCadPhase -PhaseHook $PhaseHook -PhaseName 'AfterStage' -Context @{ DestinationRoot = $destination; StagingRoot = $stagingBundle }

        # Revalidacion posterior a la elevacion y a la etapa temporal.
        # La etapa contiene el inventario original; cualquier deriva del origen,
        # incluso si es autoconsistente, se rechaza antes de tocar el destino.
        $revalidatedSource = Test-MensorCadSource -SourceRoot $SourceRoot -ProgressCallback $ProgressCallback
        if (-not (Test-MensorCadSourceEntriesMatch -LeftEntries $sourceInfo.Entries -RightEntries $revalidatedSource.Entries) -or $revalidatedSource.ManifestSha256 -ne $sourceInfo.ManifestSha256) {
            throw 'El inventario del paquete local cambio durante la instalacion. No se modifico el destino.'
        }
        if (& $AutoCadProbe) {
            throw 'AutoCAD esta en ejecucion. Cierre AutoCAD y vuelva a ejecutar el instalador. No se cerro AutoCAD automaticamente.'
        }
        Assert-MensorCadNoReparseInPath -Path $destination -Boundary $TrustedBoundary

        # La marca describe exactamente los bytes ya copiados y verificados en la etapa.
        Write-MensorCadMarker -DestinationRoot $stagingBundle -SourceInfo $sourceInfo
        $stagedMarkerPath = Join-Path -Path $stagingBundle -ChildPath $script:MensorCadMarkerFileName
        $stagedMarker = Read-MensorCadMarker -MarkerPath $stagedMarkerPath
        if (-not (Test-MensorCadInventoryMatches -Marker $stagedMarker -SourceInfo $sourceInfo)) {
            throw 'La etapa temporal no coincide con el inventario del paquete validado.'
        }
        $stagedTreeWithMarker = Get-MensorCadDirectoryTree -RootPath $stagingBundle
        if ($stagedTreeWithMarker.Files.Count -ne ($sourceInfo.Entries.Count + 1)) {
            throw 'La etapa temporal contiene archivos inesperados despues de escribir la marca.'
        }

        if ($null -ne $existingMarker) {
            # Ultima comprobacion de inventario antes de mover el destino.
            $null = Assert-MensorCadOwnedDestination -DestinationRoot $destination
            [System.IO.Directory]::Move($destination, $backupBundle)
            $backupCreated = $true
            # Solo se eliminara un respaldo que siga siendo un bundle propio.
            $null = Assert-MensorCadOwnedDestination -DestinationRoot $backupBundle
            Invoke-MensorCadPhase -PhaseHook $PhaseHook -PhaseName 'AfterBackup' -Context @{ DestinationRoot = $destination; BackupRoot = $backupBundle }
        }
        else {
            Invoke-MensorCadPhase -PhaseHook $PhaseHook -PhaseName 'BeforeSwap' -Context @{ DestinationRoot = $destination; StagingRoot = $stagingBundle }
        }

        [System.IO.Directory]::Move($stagingBundle, $destination)
        $swapped = $true
        Invoke-MensorCadPhase -PhaseHook $PhaseHook -PhaseName 'AfterSwap' -Context @{ DestinationRoot = $destination; BackupRoot = $backupBundle }

        $null = Assert-MensorCadOwnedDestination -DestinationRoot $destination

        $cleanupWarnings = @()
        try {
            if (Test-Path -LiteralPath $backupBundle) {
                $null = Assert-MensorCadOwnedDestination -DestinationRoot $backupBundle
                Remove-MensorCadTree -Path $backupBundle
            }
        }
        catch {
            $cleanupWarnings += ("No se pudo eliminar el respaldo temporal '$backupBundle': " + $_.Exception.Message)
        }
        try {
            if (Test-Path -LiteralPath $transactionRoot) { Remove-MensorCadTree -Path $transactionRoot }
        }
        catch {
            $cleanupWarnings += ("No se pudo eliminar la carpeta temporal '$transactionRoot': " + $_.Exception.Message)
        }

        $status = 'installed'
        if ($null -ne $existingMarker) { $status = 'updated' }
        return [pscustomobject]@{
            Status = $status
            FileCount = $sourceInfo.FileCount
            DestinationRoot = $destination
            MarkerPath = (Join-Path -Path $destination -ChildPath $script:MensorCadMarkerFileName)
            CleanupWarnings = $cleanupWarnings
        }
    }
    catch {
        $originalError = $_
        $recoveryError = $null
        try {
            if ($swapped) {
                if (Test-Path -LiteralPath $destination) {
                    $null = Assert-MensorCadOwnedDestination -DestinationRoot $destination
                    Remove-MensorCadTree -Path $destination
                }
                $swapped = $false
            }
            if ($backupCreated) {
                if (Test-Path -LiteralPath $destination) {
                    throw 'La ruta de destino sigue ocupada; no se puede restaurar la copia de seguridad.'
                }
                [System.IO.Directory]::Move($backupBundle, $destination)
                $backupCreated = $false
            }
            if (Test-Path -LiteralPath $transactionRoot) {
                Remove-MensorCadTree -Path $transactionRoot
            }
        }
        catch {
            $recoveryError = $_
        }
        if ($null -ne $recoveryError) {
            throw ("La instalacion fallo y la restauracion automatica no pudo completarse. Copia de seguridad: '$backupBundle'. Detalle: " + $recoveryError.Exception.Message)
        }
        throw $originalError
    }
}

function Uninstall-MensorCadBundle {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [string]$TrustedBoundary,
        [scriptblock]$AutoCadProbe
    )
    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    if ([System.IO.Path]::GetFileName($destination) -ine $script:MensorCadBundleFolderName) {
        throw "El destino interno debe terminar en '$($script:MensorCadBundleFolderName)'."
    }
    if ([string]::IsNullOrWhiteSpace($TrustedBoundary)) {
        $TrustedBoundary = [System.IO.Path]::GetPathRoot($destination)
    }
    Assert-MensorCadNoReparseInPath -Path $destination -Boundary $TrustedBoundary
    if (-not (Test-Path -LiteralPath $destination)) {
        throw "MensorCAD no esta instalado en '$destination'."
    }
    if (-not $AutoCadProbe) {
        $AutoCadProbe = { Test-MensorCadAutoCadRunning }
    }
    $marker = Assert-MensorCadOwnedDestination -DestinationRoot $destination
    if (& $AutoCadProbe) {
        throw 'AutoCAD esta en ejecucion. Cierre AutoCAD y vuelva a ejecutar la desinstalacion. No se cerro AutoCAD automaticamente.'
    }

    $tree = Get-MensorCadDirectoryTree -RootPath $destination
    $removedFiles = 0
    foreach ($file in $marker.Files) {
        $fullPath = Join-Path -Path $destination -ChildPath ($file.Path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Falta el archivo registrado '$($file.Path)'. La desinstalacion se cancelo."
        }
        [System.IO.File]::Delete($fullPath)
        $removedFiles++
    }
    $markerPath = Join-Path -Path $destination -ChildPath $script:MensorCadMarkerFileName
    [System.IO.File]::Delete($markerPath)
    $removedFiles++

    $sortedDirectories = $tree.Directories.ToArray() | Sort-Object -Property Length -Descending
    foreach ($directory in $sortedDirectories) {
        if (Test-Path -LiteralPath $directory) {
            $remaining = [System.IO.Directory]::GetFileSystemEntries($directory)
            if ($remaining.Count -eq 0) {
                [System.IO.Directory]::Delete($directory, $false)
            }
        }
    }
    $remainingAtRoot = [System.IO.Directory]::GetFileSystemEntries($destination)
    if ($remainingAtRoot.Count -ne 0) {
        throw "La desinstalacion se cancelo: quedan archivos no reconocidos en '$destination'."
    }
    [System.IO.Directory]::Delete($destination, $false)

    return [pscustomobject]@{
        Status = 'uninstalled'
        RemovedFiles = $removedFiles
        DestinationRoot = $destination
    }
}

# ---------------------------------------------------------------------------
# Interfaz de consola
# ---------------------------------------------------------------------------

function Write-MensorCadBanner {
    if ($script:MensorCadPlainMode) {
        Write-Host 'MensorCAD - Instalador local para AutoCAD'
        return
    }
    Write-Host ''
    Write-Host '  ======================================================' -ForegroundColor DarkCyan
    Write-Host '     M E N S O R C A D   |   Instalador para AutoCAD' -ForegroundColor Cyan
    Write-Host '     Plugins LISP y CUIX en Program Files' -ForegroundColor DarkCyan
    Write-Host '  ======================================================' -ForegroundColor DarkCyan
}

function Write-MensorCadStep {
    param([int]$Number, [int]$Total, [string]$Message)
    $line = '  [{0}/{1}] {2}' -f $Number, $Total, $Message
    if ($script:MensorCadPlainMode) {
        Write-Host $line
    }
    else {
        Write-Host ''
        Write-Host $line -ForegroundColor Yellow
    }
}

function Write-MensorCadInfo {
    param([string]$Message)
    if ($script:MensorCadPlainMode) {
        Write-Host ('  ' + $Message)
    }
    else {
        Write-Host ('  ' + $Message) -ForegroundColor DarkGray
    }
}

function Write-MensorCadSuccess {
    param([string]$Message)
    if ($script:MensorCadPlainMode) {
        Write-Host $Message
    }
    else {
        Write-Host ('  ' + $Message) -ForegroundColor Green
    }
}

function Write-MensorCadFailure {
    param([string]$Message)
    [Console]::Error.WriteLine('ERROR: ' + $Message)
}

function Write-MensorCadActivity {
    param([string]$Message)
    if ($script:MensorCadPlainMode) {
        Write-Host ('  ' + $Message)
        return
    }
    $frames = @('|', '/', '-', '\')
    $frame = $frames[$script:MensorCadSpinnerIndex % $frames.Count]
    $script:MensorCadSpinnerIndex = $script:MensorCadSpinnerIndex + 1
    Write-Host ("`r  {0} {1}" -f $frame, $Message) -NoNewline -ForegroundColor DarkCyan
}

function Complete-MensorCadActivity {
    if (-not $script:MensorCadPlainMode) {
        Write-Host ''
    }
}

function Write-MensorCadProgress {
    param([string]$Phase, [int]$Current, [int]$Total, [string]$Path)
    $verb = 'Procesando'
    if ($Phase -eq 'hash') { $verb = 'Verificando' }
    if ($Phase -eq 'copy') { $verb = 'Copiando' }
    $message = '{0} {1}/{2}: {3}' -f $verb, $Current, $Total, $Path
    Write-MensorCadActivity -Message $message
}

function Write-MensorCadUsage {
    Write-Host ''
    if ($script:MensorCadPlainMode) {
        Write-Host 'MensorCAD - Instalador local para AutoCAD'
    }
    else {
        Write-Host 'MensorCAD - Instalador local para AutoCAD' -ForegroundColor Cyan
    }
    Write-Host ''
    Write-Host 'Uso:'
    Write-Host '  Instalar.bat [-NoAnimation]'
    Write-Host '  Instalar.bat -Uninstall [-NoAnimation]'
    Write-Host '  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-MensorCAD.ps1 [-Uninstall] [-NoAnimation] [-Help]'
    Write-Host '  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-MensorCAD.ps1 -FromRelease [-Version <tag>] [-NoAnimation]'
    Write-Host ''
    Write-Host 'Opciones:'
    Write-Host '  -Uninstall    Desinstala la copia propia de MensorCAD.'
    Write-Host '  -NoAnimation  Desactiva colores y animaciones.'
    Write-Host '  -FromRelease  Instala desde el ultimo release publicado en GitHub.'
    Write-Host '  -Version      Fija un tag concreto de la release (requiere -FromRelease).'
    Write-Host '  -Help         Muestra esta ayuda.'
    Write-Host ''
    Write-Host 'Destino fijo:'
    Write-Host '  <Program Files>\Autodesk\ApplicationPlugins\MensorCAD.bundle'
    Write-Host ''
    Write-Host 'Requiere Windows de 64 bits y PowerShell de 64 bits.'
    Write-Host 'La instalacion y la desinstalacion requieren permisos de administrador (UAC).'
    Write-Host 'La instalacion remota requiere un release publicado por un humano con los assets.'
    Write-Host 'SHA-256 detecta corrupcion; no autentica al publicador. Confie en el repositorio.'
}

# ---------------------------------------------------------------------------
# Entrada remota: descarga y verificacion de releases de GitHub
# ---------------------------------------------------------------------------
# La descarga vive solo en esta seccion. La rama local (-Uninstall, sin
# opciones) no toca la red. El ZIP se verifica con SHA-256 y se inspecciona
# antes de extraer; despues se ejecuta el mismo instalador extraido, que
# reutiliza el motor local, el destino fijo y la elevacion UAC.

$script:MensorCadReleaseRepository = 'RonGrasz/Mensor-CAD'
$script:MensorCadReleaseHost = 'https://github.com'
$script:MensorCadReleaseApiHost = 'https://api.github.com'
$script:MensorCadReleaseZipAssetName = 'MensorCAD-Windows.zip'
$script:MensorCadReleaseChecksumAssetName = 'MensorCAD-Windows.zip.sha256'
$script:MensorCadReleaseInstallerAssetName = 'Install-MensorCAD.ps1'
$script:MensorCadRemoteWorkspacePrefix = 'mensorcad-remote-'
$script:MensorCadReleaseTagPattern = '^v?\d+\.\d+(\.\d+)*([-+][0-9A-Za-z][0-9A-Za-z.-]*)?$'
$script:MensorCadReleaseLispPattern = '^MensorCAD\.bundle/Contents/Lisp/[^/]+\.lsp$'
$script:MensorCadRemoteMaxEntries = 512
$script:MensorCadRemoteMaxUncompressedBytes = 268435456
$script:MensorCadRemoteWaitIntervalMilliseconds = 200
$script:MensorCadRemoteChildActivityMessage = 'Instalando con el instalador incluido en el paquete'
$script:MensorCadReleaseFixedFiles = @(
    'MensorCAD.bundle/PackageContents.xml',
    'MensorCAD.bundle/Contents/UI/MensorCAD.cuix',
    'Install-MensorCAD.ps1',
    'Instalar.bat',
    'LICENSE',
    'bundle.sha256'
)
$script:MensorCadReleaseAllowedDirectories = @(
    'MensorCAD.bundle',
    'MensorCAD.bundle/Contents',
    'MensorCAD.bundle/Contents/Lisp',
    'MensorCAD.bundle/Contents/UI'
)

function Get-MensorCadArgumentError {
    param(
        [switch]$Uninstall,
        [switch]$FromRelease,
        [string]$Version,
        [bool]$VersionSpecified
    )
    if ($FromRelease -and $Uninstall) {
        return 'Las opciones -FromRelease y -Uninstall no se pueden combinar. No se descargo nada ni se modifico el destino.'
    }
    if ($VersionSpecified -and -not $FromRelease) {
        return 'La opcion -Version solo es valida junto con -FromRelease. No se descargo nada ni se modifico el destino.'
    }
    if ($FromRelease -and $VersionSpecified -and [string]::IsNullOrWhiteSpace($Version)) {
        return 'La opcion -Version requiere un valor, por ejemplo -Version v1.2.3. No se descargo nada ni se modifico el destino.'
    }
    if ($FromRelease -and $VersionSpecified -and ($Version -notmatch $script:MensorCadReleaseTagPattern)) {
        return ("La version indicada no es valida: '" + $Version + "'. Use un tag como v1.2.3. No se descargo nada ni se modifico el destino.")
    }
    return $null
}

function Get-MensorCadRemoteTempRoot {
    return [System.IO.Path]::GetTempPath()
}

# Costuras de red: toda descarga pasa por estas dos funciones.
function Get-MensorCadRemoteText {
    param([string]$Uri)
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 60
    return [string]$response.Content
}

function Save-MensorCadRemoteFile {
    param([string]$Uri, [string]$DestinationPath)
    $parent = Split-Path -Parent $DestinationPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $null = Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $DestinationPath -TimeoutSec 300
    return $DestinationPath
}

function Assert-MensorCadReleaseTag {
    param([string]$Tag)
    if ([string]::IsNullOrWhiteSpace($Tag)) {
        throw 'La version de la release esta vacia. Use un tag como v1.2.3. No se descargo nada ni se modifico el destino.'
    }
    if ($Tag -notmatch $script:MensorCadReleaseTagPattern) {
        throw ("La version indicada no es valida: '" + $Tag + "'. Use un tag como v1.2.3. No se descargo nada ni se modifico el destino.")
    }
}

function Get-MensorCadReleaseAssetUri {
    param([string]$Tag, [string]$AssetName)
    return ($script:MensorCadReleaseHost + '/' + $script:MensorCadReleaseRepository + '/releases/download/' + $Tag + '/' + $AssetName)
}

function Resolve-MensorCadReleaseTag {
    param([string]$Version)
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        Assert-MensorCadReleaseTag -Tag $Version
        return $Version
    }
    $uri = $script:MensorCadReleaseApiHost + '/repos/' + $script:MensorCadReleaseRepository + '/releases/latest'
    try {
        $json = Get-MensorCadRemoteText -Uri $uri
    }
    catch {
        throw ('No se pudo consultar la ultima release en GitHub: ' + $_.Exception.Message + ' No se descargo ni se modifico nada.')
    }
    $release = $null
    try {
        $release = $json | ConvertFrom-Json
    }
    catch {
        throw 'La respuesta de GitHub no contiene JSON valido. No se descargo ni se modifico nada.'
    }
    if ($null -eq $release) {
        throw 'La respuesta de GitHub no contiene una release utilizable. No se descargo ni se modifico nada.'
    }
    $tagProperty = $release.PSObject.Properties['tag_name']
    $tag = ''
    if ($null -ne $tagProperty) {
        $tag = [string]$tagProperty.Value
    }
    if ([string]::IsNullOrWhiteSpace($tag)) {
        throw 'La release mas reciente no tiene un tag utilizable. No se descargo ni se modifico nada.'
    }
    Assert-MensorCadReleaseTag -Tag $tag
    $assetNames = @()
    $assetsProperty = $release.PSObject.Properties['assets']
    if ($null -ne $assetsProperty) {
        foreach ($asset in @($assetsProperty.Value)) {
            if ($null -eq $asset) { continue }
            $nameProperty = $asset.PSObject.Properties['name']
            if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
                $assetNames += [string]$nameProperty.Value
            }
        }
    }
    foreach ($requiredAsset in @($script:MensorCadReleaseZipAssetName, $script:MensorCadReleaseChecksumAssetName)) {
        if (-not ($assetNames -contains $requiredAsset)) {
            throw ("La release '" + $tag + "' no publica el asset '" + $requiredAsset + "'. No se descargo ni se modifico nada.")
        }
    }
    return $tag
}

function Read-MensorCadReleaseChecksum {
    param([string]$SidecarPath)
    if (-not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
        throw "No se descargo el archivo de verificacion '$SidecarPath'. No se extrajo nada ni se modifico el destino."
    }
    if (Test-MensorCadReparsePoint -Path $SidecarPath) {
        throw "El archivo de verificacion '$SidecarPath' es un punto de reanalisis y se rechazo."
    }
    $lines = @()
    foreach ($line in [System.IO.File]::ReadAllLines($SidecarPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $lines += $line.Trim() }
    }
    if ($lines.Count -ne 1) {
        throw 'El archivo .sha256 de la release no tiene el formato esperado. No se extrajo nada ni se modifico el destino.'
    }
    $match = [regex]::Match($lines[0], '^([0-9a-fA-F]{64})(?:\s+\*?(.+))?$')
    if (-not $match.Success) {
        throw 'El archivo .sha256 de la release no contiene un SHA-256 valido. No se extrajo nada ni se modifico el destino.'
    }
    $fileName = $match.Groups[2].Value
    if (-not [string]::IsNullOrWhiteSpace($fileName) -and $fileName -ine $script:MensorCadReleaseZipAssetName) {
        throw ("El archivo .sha256 corresponde a '" + $fileName + "' y no a '" + $script:MensorCadReleaseZipAssetName + "'. No se extrajo nada ni se modifico el destino.")
    }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Assert-MensorCadReleaseArchiveHash {
    param([string]$ArchivePath, [string]$SidecarPath)
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "No se descargo el paquete '$ArchivePath'. No se extrajo nada ni se modifico el destino."
    }
    $expectedHash = Read-MensorCadReleaseChecksum -SidecarPath $SidecarPath
    $actualHash = Get-MensorCadFileHash -Path $ArchivePath
    if ($actualHash -ne $expectedHash) {
        throw 'El SHA-256 del ZIP descargado no coincide con el archivo .sha256 de la release. No se extrajo nada ni se modifico el destino.'
    }
    return $actualHash
}

function Assert-MensorCadArchiveEntryName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'El ZIP contiene una entrada sin nombre. No se extrajo nada ni se modifico el destino.'
    }
    if ($Name.Contains('\')) {
        throw ("El ZIP contiene una entrada con barras invertidas: '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
    }
    if ($Name.StartsWith('/')) {
        throw ("El ZIP contiene una entrada con ruta absoluta o UNC: '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
    }
    if ($Name -match '^[A-Za-z]:') {
        throw ("El ZIP contiene una entrada con unidad de disco: '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
    }
    $isDirectory = $Name.EndsWith('/')
    $path = $Name
    if ($isDirectory) { $path = $Name.Substring(0, $Name.Length - 1) }
    $segments = $path.Split('/')
    foreach ($segment in $segments) {
        if ($segment.Length -eq 0) {
            throw ("El ZIP contiene una entrada con un segmento vacio: '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
        }
        if ($segment -eq '.' -or $segment -eq '..') {
            throw ("El ZIP contiene una entrada con un segmento no permitido ('" + $segment + "'): '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
        }
        if ($segment.Contains(':')) {
            throw ("El ZIP contiene una entrada con flujo alternativo (ADS): '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
        }
        if ($segment.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw ("El ZIP contiene una entrada con caracteres no validos: '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw ("El ZIP contiene una entrada con un segmento que termina en punto o espacio: '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
        }
        $baseName = ($segment -split '\.')[0]
        if ($baseName -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw ("El ZIP contiene un nombre reservado de Windows: '" + $Name + "'. No se extrajo nada ni se modifico el destino.")
        }
    }
    return [pscustomobject]@{ Name = $Name; RelativePath = $path; IsDirectory = $isDirectory }
}

function Get-MensorCadReleaseArchiveEntries {
    param([string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "No existe el paquete descargado '$ArchivePath'."
    }
    if (Test-MensorCadReparsePoint -Path $ArchivePath) {
        throw "El paquete descargado '$ArchivePath' es un punto de reanalisis y se rechazo."
    }
    $fileMap = @{}
    $files = New-Object 'System.Collections.Generic.List[object]'
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $duplicates = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    $seenFiles = @{}
    $seenDirectories = @{}
    $totalBytes = [long]0
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        if ($archive.Entries.Count -gt $script:MensorCadRemoteMaxEntries) {
            throw ("El ZIP contiene demasiadas entradas ({0}). No se extrajo nada ni se modifico el destino." -f $archive.Entries.Count)
        }
        foreach ($entry in $archive.Entries) {
            $validated = Assert-MensorCadArchiveEntryName -Name $entry.FullName
            $mode = ($entry.ExternalAttributes -shr 16) -band 0xFFFF
            if (($mode -band 0xF000) -eq 0xA000) {
                throw ("El ZIP contiene un enlace (punto de reanalisis) y se rechazo: '" + $entry.FullName + "'. No se extrajo nada ni se modifico el destino.")
            }
            if ($validated.IsDirectory -and $entry.Length -ne 0) {
                throw ("El ZIP contiene un directorio con contenido: '" + $entry.FullName + "'. No se extrajo nada ni se modifico el destino.")
            }
            if ((-not $validated.IsDirectory) -and ($mode -band 0xF000) -eq 0x4000) {
                throw ("El ZIP contiene una entrada de directorio sin barra final: '" + $entry.FullName + "'. No se extrajo nada ni se modifico el destino.")
            }
            $key = $validated.RelativePath.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                $duplicates.Add($validated.RelativePath)
                continue
            }
            $seen[$key] = $true
            if ($validated.IsDirectory) {
                if (-not ($script:MensorCadReleaseAllowedDirectories -ccontains $validated.RelativePath)) {
                    throw ("El ZIP contiene un directorio fuera del paquete distribuido: '" + $validated.RelativePath + "'. No se extrajo nada ni se modifico el destino.")
                }
                if ($seenFiles.ContainsKey($key)) {
                    throw ("El ZIP contiene un archivo y un directorio con la misma ruta: '" + $validated.RelativePath + "'.")
                }
                $seenDirectories[$key] = $true
                $directories.Add($validated.RelativePath)
                $fileMap[$entry.FullName] = $validated
            }
            else {
                $allowed = ($script:MensorCadReleaseFixedFiles -ccontains $validated.RelativePath) -or ($validated.RelativePath -cmatch $script:MensorCadReleaseLispPattern)
                if (-not $allowed) {
                    throw ("El ZIP contiene una entrada fuera del paquete distribuido: '" + $validated.RelativePath + "'. No se extrajo nada ni se modifico el destino.")
                }
                if ($seenDirectories.ContainsKey($key)) {
                    throw ("El ZIP contiene un archivo y un directorio con la misma ruta: '" + $validated.RelativePath + "'.")
                }
                $seenFiles[$key] = $true
                $totalBytes += [long]$entry.Length
                $files.Add([pscustomobject]@{ FullName = $entry.FullName; RelativePath = $validated.RelativePath; Length = [long]$entry.Length })
                $fileMap[$entry.FullName] = $validated
            }
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
    if ($duplicates.Count -gt 0) {
        throw ("El ZIP contiene una entrada duplicada (sin distinguir mayusculas): '" + $duplicates[0] + "'. No se extrajo nada ni se modifico el destino.")
    }
    if ($totalBytes -gt $script:MensorCadRemoteMaxUncompressedBytes) {
        throw ("El ZIP descomprimido supera el limite permitido ({0} bytes). No se extrajo nada ni se modifico el destino." -f $totalBytes)
    }
    foreach ($required in $script:MensorCadReleaseFixedFiles) {
        $found = $false
        foreach ($fileEntry in $files) {
            if ($fileEntry.RelativePath -ceq $required) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            throw ("El ZIP no contiene la entrada obligatoria '" + $required + "'. No se extrajo nada ni se modifico el destino.")
        }
    }
    $lispCount = 0
    foreach ($fileEntry in $files) {
        if ($fileEntry.RelativePath -cmatch $script:MensorCadReleaseLispPattern) { $lispCount++ }
    }
    if ($lispCount -eq 0) {
        throw 'El ZIP no contiene ningun archivo Contents/Lisp/*.lsp. No se extrajo nada ni se modifico el destino.'
    }
    return [pscustomobject]@{
        FileMap = $fileMap
        Files = $files
        Directories = $directories
        Duplicates = $duplicates
        TotalBytes = $totalBytes
    }
}

function Expand-MensorCadReleaseArchive {
    param(
        [string]$ArchivePath,
        [string]$DestinationRoot,
        [object]$Entries,
        [string]$TrustedBoundary
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    if (Test-Path -LiteralPath $DestinationRoot) {
        throw "La carpeta de extraccion '$DestinationRoot' ya existe y se rechazo."
    }
    $null = New-Item -ItemType Directory -Path $DestinationRoot
    Assert-MensorCadNoReparseInPath -Path $DestinationRoot -Boundary $TrustedBoundary
    $destinationFull = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (-not $destinationFull.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) {
        $destinationFull += [string][System.IO.Path]::DirectorySeparatorChar
    }
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        foreach ($entry in $archive.Entries) {
            if (-not $Entries.FileMap.ContainsKey($entry.FullName)) {
                throw ("El ZIP cambio entre la validacion y la extraccion: '" + $entry.FullName + "'.")
            }
            $validated = $Entries.FileMap[$entry.FullName]
            $targetPath = Join-Path -Path $DestinationRoot -ChildPath ($validated.RelativePath.Replace('/', '\'))
            $targetFull = [System.IO.Path]::GetFullPath($targetPath)
            if (-not $targetFull.StartsWith($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw ("La entrada '" + $validated.RelativePath + "' intentaria escribir fuera de la carpeta de extraccion.")
            }
            if ($validated.IsDirectory) {
                if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) {
                    $null = New-Item -ItemType Directory -Path $targetFull -Force
                }
                continue
            }
            $targetParent = Split-Path -Parent $targetFull
            if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $targetParent -Force
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetFull, $false)
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
    $tree = Get-MensorCadDirectoryTree -RootPath $DestinationRoot
    if ($tree.Files.Count -ne $Entries.Files.Count) {
        throw 'La extraccion del ZIP no contiene todos los archivos declarados.'
    }
    return $DestinationRoot
}

# Espera activa: se reutiliza el renderizador local para pintar actividad
# mientras el proceso hijo real (incluida la espera de UAC) sigue vivo. No hay
# demoras despues de que el hijo termina: el sondeo solo existe dentro del bucle.
function Wait-MensorCadRemoteChild {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [string]$Message = $script:MensorCadRemoteChildActivityMessage,
        [int]$IntervalMilliseconds = $script:MensorCadRemoteWaitIntervalMilliseconds
    )
    if ($IntervalMilliseconds -lt 50) {
        $IntervalMilliseconds = 50
    }
    if ($script:MensorCadPlainMode) {
        Write-MensorCadInfo $Message
    }
    while (-not $Process.HasExited) {
        if (-not $script:MensorCadPlainMode) {
            Write-MensorCadActivity -Message $Message
        }
        # Espera del sistema con timeout: vuelve de inmediato cuando el proceso
        # termina, asi que no existe ningun retardo decorativo posterior.
        $null = $Process.WaitForExit($IntervalMilliseconds)
    }
    $Process.WaitForExit()
    Complete-MensorCadActivity
}

function Invoke-MensorCadRemoteChild {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$StdOutPath,
        [Parameter(Mandatory = $true)][string]$StdErrPath
    )
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw ("No se encontro el instalador extraido en '" + $ScriptPath + "'. No se solicito elevacion.")
    }
    $powerShellPath = Get-MensorCadPowerShellPath
    $argumentString = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    foreach ($argument in @($Arguments)) {
        if (-not [string]::IsNullOrWhiteSpace($argument)) {
            $argumentString += ' ' + $argument
        }
    }
    $process = $null
    try {
        try {
            $process = Start-Process -FilePath $powerShellPath -ArgumentList $argumentString -NoNewWindow -PassThru -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath
        }
        catch {
            throw ('No se pudo ejecutar el instalador extraido: ' + $_.Exception.Message + ' La instalacion no se realizo.')
        }
        if ($null -eq $process) {
            throw 'No se pudo iniciar el instalador extraido. La instalacion no se realizo.'
        }
        # Windows PowerShell 5.1 puede dejar sin acceso el estado nativo del proceso
        # cuando Start-Process vuelve sin -Wait: ExitCode se lee entonces como $null
        # y [int]$null convertiria un fallo real en un falso exito 0. Fijar el handle
        # antes de la espera conserva el acceso al estado real del hijo.
        try {
            $null = $process.Handle
            $childPid = $process.Id
        }
        catch {
            throw ('No se pudo fijar el estado del proceso hijo: ' + $_.Exception.Message + ' La instalacion no se confirmo.')
        }
        Wait-MensorCadRemoteChild -Process $process -Message $script:MensorCadRemoteChildActivityMessage
        # El estado crudo se lee una sola vez y se valida antes de convertirlo: un
        # estado ausente nunca puede pasar como exito.
        try {
            $rawExitCode = $process.ExitCode
        }
        catch {
            throw ('No se pudo leer el codigo de salida del proceso hijo ' + $childPid + ': ' + $_.Exception.Message + ' La instalacion no se confirmo.')
        }
        if ($null -eq $rawExitCode) {
            throw ('No se pudo determinar el codigo de salida del proceso hijo ' + $childPid + '. La instalacion no se confirmo.')
        }
        $exitCode = [int]$rawExitCode
        $stdOut = ''
        $stdErr = ''
        if (Test-Path -LiteralPath $StdOutPath -PathType Leaf) { $stdOut = [System.IO.File]::ReadAllText($StdOutPath) }
        if (Test-Path -LiteralPath $StdErrPath -PathType Leaf) { $stdErr = [System.IO.File]::ReadAllText($StdErrPath) }
        return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdOut; StdErr = $stdErr }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Write-MensorCadRelayedOutput {
    param([string]$Text, [switch]$IsError)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $payload = $Text
    if (-not $payload.EndsWith("`n")) { $payload += [Environment]::NewLine }
    if ($IsError) {
        [Console]::Error.Write($payload)
    }
    else {
        [Console]::Out.Write($payload)
    }
}

function Invoke-MensorCadRemoteInstall {
    param([string]$Version, [switch]$NoAnimation)
    # El host, Program Files y el destino fijo ya se validaron en Invoke-MensorCadCli.
    $null = Get-MensorCadProgramFilesRoot
    $null = Get-MensorCadDestinationRoot
    try {
        # TLS 1.2 solo para el proceso actual; no se cambia ninguna politica global.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-MensorCadInfo 'Aviso: no se pudo habilitar TLS 1.2 en este proceso; la descarga podria fallar.'
    }

    $totalSteps = 5
    Write-MensorCadStep -Number 1 -Total $totalSteps -Message 'Resolviendo la release de GitHub'
    $tag = Resolve-MensorCadReleaseTag -Version $Version
    Write-MensorCadInfo ('Release seleccionada: ' + $tag)
    Complete-MensorCadActivity

    $tempRoot = Get-MensorCadRemoteTempRoot
    if ([string]::IsNullOrWhiteSpace($tempRoot) -or -not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
        throw "No existe la carpeta temporal '$tempRoot'. No se descargo nada ni se modifico el destino."
    }
    $workspace = Join-Path -Path $tempRoot -ChildPath ($script:MensorCadRemoteWorkspacePrefix + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path $workspace
        Assert-MensorCadNoReparseInPath -Path $workspace -Boundary $tempRoot

        $zipPath = Join-Path -Path $workspace -ChildPath $script:MensorCadReleaseZipAssetName
        $sidecarPath = Join-Path -Path $workspace -ChildPath $script:MensorCadReleaseChecksumAssetName
        $extractRoot = Join-Path -Path $workspace -ChildPath 'package'
        $stdOutPath = Join-Path -Path $workspace -ChildPath 'install.stdout.log'
        $stdErrPath = Join-Path -Path $workspace -ChildPath 'install.stderr.log'

        Write-MensorCadStep -Number 2 -Total $totalSteps -Message 'Descargando el paquete y su SHA-256 sin permisos de administrador'
        $null = Save-MensorCadRemoteFile -Uri (Get-MensorCadReleaseAssetUri -Tag $tag -AssetName $script:MensorCadReleaseZipAssetName) -DestinationPath $zipPath
        $null = Save-MensorCadRemoteFile -Uri (Get-MensorCadReleaseAssetUri -Tag $tag -AssetName $script:MensorCadReleaseChecksumAssetName) -DestinationPath $sidecarPath
        Complete-MensorCadActivity

        Write-MensorCadStep -Number 3 -Total $totalSteps -Message 'Verificando el SHA-256 y las entradas del ZIP'
        $null = Assert-MensorCadReleaseArchiveHash -ArchivePath $zipPath -SidecarPath $sidecarPath
        $archiveEntries = Get-MensorCadReleaseArchiveEntries -ArchivePath $zipPath
        Write-MensorCadInfo 'SHA-256 verificado: detecta corrupcion, no autentica al publicador.'
        Complete-MensorCadActivity

        Write-MensorCadStep -Number 4 -Total $totalSteps -Message 'Extrayendo el paquete verificado en una carpeta temporal propia'
        $null = Expand-MensorCadReleaseArchive -ArchivePath $zipPath -DestinationRoot $extractRoot -Entries $archiveEntries -TrustedBoundary $workspace
        $null = Test-MensorCadSource -SourceRoot $extractRoot
        Complete-MensorCadActivity

        Write-MensorCadStep -Number 5 -Total $totalSteps -Message $script:MensorCadRemoteChildActivityMessage
        Write-MensorCadInfo 'Si Windows muestra UAC, el proceso elevado abrira su propia ventana de diagnostico.'
        $childScript = Join-Path -Path $extractRoot -ChildPath $script:MensorCadReleaseInstallerAssetName
        $childArguments = @()
        if ($NoAnimation) { $childArguments += '-NoAnimation' }
        $child = Invoke-MensorCadRemoteChild -ScriptPath $childScript -Arguments $childArguments -StdOutPath $stdOutPath -StdErrPath $stdErrPath
        Write-MensorCadRelayedOutput -Text $child.StdOut
        Write-MensorCadRelayedOutput -Text $child.StdErr -IsError
        if ($child.ExitCode -eq 0) {
            Write-MensorCadInfo 'Recuerde abrir AutoCAD para cargar el bundle instalado.'
        }
        return [int]$child.ExitCode
    }
    finally {
        Complete-MensorCadActivity
        if (Test-Path -LiteralPath $workspace) {
            try {
                Remove-MensorCadTree -Path $workspace
            }
            catch {
                Write-MensorCadInfo ('Aviso: no se pudo limpiar la carpeta temporal ' + $workspace + '; se conserva en disco: ' + $_.Exception.Message)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Ventana unica: consola propia y ocultamiento temporal durante UAC
# ---------------------------------------------------------------------------
# Al hacer doble clic en Instalar.bat, Windows abre una consola cmd.exe dedicada
# (su padre es explorer.exe) y el instalador corre dentro de ella. La elevacion
# UAC abre una segunda ventana, de modo que al aceptar quedaban dos. Para dejar
# una sola ventana visible se oculta temporalmente ESA consola mientras el
# proceso elevado exista y se restaura siempre al terminar.
#
# Reglas de seguridad:
#  - La sonda nativa se compila solo cuando se va a pedir elevacion; el
#    dot-source no registra tipos, no oculta nada y no escribe nada.
#  - Nunca se oculta una terminal existente o compartida, una consola con flujos
#    redirigidos ni una pseudoconsola (Windows Terminal / ConPTY): en esos casos
#    se conserva el comportamiento anterior. Una terminal cmd abierta por
#    Explorer tiene la misma topologia de procesos que el doble clic, asi que
#    ademas se exige que su linea de comandos ejecute este Instalar.bat con /c.
#  - Cualquier duda (error de sondeo, cadena de procesos distinta, ventana no
#    visible) se resuelve SIN ocultar nada (fail-open).
#  - La restauracion ocurre en un bloque finally: tambien al cancelar UAC o si
#    el lanzamiento falla. No se cierra ningun proceso.

function Get-MensorCadConsoleNativeType {
    # Devuelve el tipo con las declaraciones Win32 o $null si no se puede
    # compilar. Nunca lanza: sin sonda no se oculta nada.
    if ($null -ne $script:MensorCadConsoleNativeType) {
        return $script:MensorCadConsoleNativeType
    }
    foreach ($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
        try {
            $existing = $assembly.GetType('MensorCadConsoleHost.NativeWindow', $false, $false)
        }
        catch {
            $existing = $null
        }
        if ($null -ne $existing) {
            $script:MensorCadConsoleNativeType = $existing
            return $script:MensorCadConsoleNativeType
        }
    }
    $source = @'
using System;
using System.Runtime.InteropServices;

namespace MensorCadConsoleHost
{
    public static class NativeWindow
    {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint GetConsoleProcessList(uint[] processList, uint processCount);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr windowHandle);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr windowHandle, int command);
    }
}
'@
    try {
        $types = @(Add-Type -TypeDefinition $source -Language CSharp -PassThru -ErrorAction Stop)
    }
    catch {
        $script:MensorCadConsoleNativeType = $null
        return $null
    }
    foreach ($type in $types) {
        if ($type.FullName -eq 'MensorCadConsoleHost.NativeWindow') {
            $script:MensorCadConsoleNativeType = $type
        }
    }
    return $script:MensorCadConsoleNativeType
}

function Get-MensorCadConsoleProbe {
    # Sonda de SOLO lectura: ventana de la consola, clientes conectados y
    # visibilidad. Devuelve $null si no hay consola o si algo no se puede leer.
    param([int]$BufferSize = 8)
    $native = Get-MensorCadConsoleNativeType
    if ($null -eq $native) { return $null }
    try {
        $windowHandle = $native::GetConsoleWindow()
        if ($null -eq $windowHandle) { return $null }
        if ($windowHandle -eq [IntPtr]::Zero) { return $null }
        $buffer = New-Object -TypeName 'uint32[]' -ArgumentList $BufferSize
        $count = [int]$native::GetConsoleProcessList($buffer, [uint32]$BufferSize)
        if ($count -le 0 -or $count -gt $BufferSize) { return $null }
        $processIds = @()
        for ($index = 0; $index -lt $count; $index++) {
            $processIds += [int]$buffer[$index]
        }
        $visible = [bool]$native::IsWindowVisible($windowHandle)
        return [pscustomobject]@{
            WindowHandle = $windowHandle
            ProcessIds = $processIds
            WindowVisible = $visible
        }
    }
    catch {
        return $null
    }
}

function Get-MensorCadProcessParentId {
    param([int]$ProcessId)
    $process = Get-CimInstance -ClassName 'Win32_Process' -Filter ('ProcessId = ' + $ProcessId) -ErrorAction Stop
    if ($null -eq $process) {
        throw ('No se pudo leer el proceso ' + $ProcessId + '.')
    }
    return [int]$process.ParentProcessId
}

function Get-MensorCadProcessName {
    param([int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    return [string]$process.ProcessName
}

function Get-MensorCadProcessCommandLine {
    # Linea de comandos del proceso, de solo lectura. Si no se puede leer se
    # lanza y la deteccion se resuelve sin ocultar nada.
    param([int]$ProcessId)
    $process = Get-CimInstance -ClassName 'Win32_Process' -Filter ('ProcessId = ' + $ProcessId) -ErrorAction Stop
    if ($null -eq $process) {
        throw ('No se pudo leer el proceso ' + $ProcessId + '.')
    }
    $commandLine = [string]$process.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        throw ('No se pudo leer la linea de comandos del proceso ' + $ProcessId + '.')
    }
    return $commandLine
}

function Get-MensorCadBatchCommandTarget {
    # Reconocimiento minimo y estricto del doble clic de Explorer sobre este BAT:
    #   cmd.exe /c ""<carpeta>\Instalar.bat" "
    # Devuelve la ruta reconocida cuando el destino es exactamente el BAT de la
    # raiz del script; en cualquier otro caso devuelve $null (la consola queda
    # visible). No es un interprete de shell: solo separa el ejecutable, exige el
    # interruptor /c exacto (nunca /c dentro de una ruta o argumento entre
    # comillas), rechaza /k, composiciones y objetivos distintos.
    param([string]$CommandLine, [string]$BatchPath)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    if ([string]::IsNullOrWhiteSpace($BatchPath)) { return $null }
    try {
        $expected = [System.IO.Path]::GetFullPath($BatchPath)
    }
    catch {
        return $null
    }

    # 1. Quitar el ejecutable (cmd.exe): entre comillas o hasta el primer espacio.
    $rest = $CommandLine.Trim()
    if ($rest.StartsWith('"')) {
        $executableEnd = $rest.IndexOf('"', 1)
        if ($executableEnd -lt 1) { return $null }
        $rest = $rest.Substring($executableEnd + 1)
    }
    else {
        $executableEnd = $rest.IndexOfAny([char[]]@(' ', "`t"))
        if ($executableEnd -lt 1) { return $null }
        $rest = $rest.Substring($executableEnd)
    }

    # 2. Recorrer los tokens respetando comillas hasta encontrar el /c exacto.
    $index = 0
    $inQuotes = $false
    $commandText = $null
    while ($index -lt $rest.Length) {
        $character = $rest[$index]
        if ($character -eq '"') { $inQuotes = -not $inQuotes; $index++; continue }
        if (-not $inQuotes -and [char]::IsWhiteSpace($character)) { $index++; continue }
        $tokenStart = $index
        while ($index -lt $rest.Length) {
            $current = $rest[$index]
            if ($current -eq '"') { $inQuotes = -not $inQuotes; $index++; continue }
            if (-not $inQuotes -and [char]::IsWhiteSpace($current)) { break }
            $index++
        }
        $token = $rest.Substring($tokenStart, $index - $tokenStart)
        if ($token -ieq '/k') { return $null }
        if ($token -ieq '/c') {
            $commandText = $rest.Substring($index)
            break
        }
        # Un token antes de /c que no sea otro interruptor significa que cmd se
        # abrio de forma interactiva (o con un programa que no es este BAT).
        if (-not $token.StartsWith('/')) { return $null }
    }
    if ($null -eq $commandText) { return $null }

    # 3. Rechazar composiciones de shell: solo un comando simple.
    $inQuotes = $false
    foreach ($character in $commandText.ToCharArray()) {
        if ($character -eq '"') { $inQuotes = -not $inQuotes; continue }
        if ($inQuotes) { continue }
        if ($character -eq '&' -or $character -eq '|' -or $character -eq '>') { return $null }
    }

    # 4. Extraer el primer objetivo y exigir que sea exactamente este BAT.
    $text = $commandText.Trim()
    while ($text.Length -ge 2 -and $text[0] -eq '"' -and $text[$text.Length - 1] -eq '"') {
        $text = $text.Substring(1, $text.Length - 2).Trim()
    }
    if ($text.Length -eq 0) { return $null }
    $target = $text
    if ($text.StartsWith('"')) {
        $targetEnd = $text.IndexOf('"', 1)
        if ($targetEnd -lt 1) { return $null }
        $target = $text.Substring(1, $targetEnd - 1)
    }
    else {
        $targetEnd = $text.IndexOfAny([char[]]@(' ', "`t"))
        if ($targetEnd -ge 1) { $target = $text.Substring(0, $targetEnd) }
    }
    try {
        $resolved = [System.IO.Path]::GetFullPath($target)
    }
    catch {
        return $null
    }
    if (-not [string]::Equals($resolved, $expected, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $resolved
}

function Test-MensorCadConsoleHandoffBlocked {
    # Con cualquier flujo redirigido no hay una consola interactiva propia que
    # ocultar; se trata como motivo para no tocar nada.
    try {
        if ([Console]::IsOutputRedirected) { return $true }
        if ([Console]::IsErrorRedirected) { return $true }
        if ([Console]::IsInputRedirected) { return $true }
        return $false
    }
    catch {
        return $true
    }
}

function Get-MensorCadDedicatedConsole {
    # Devuelve la ventana de la consola propia SOLO cuando es una consola
    # dedicada del doble clic de este BAT: exactamente este proceso y su padre
    # cmd.exe, ese cmd.exe abierto por explorer.exe, ventana visible, sin
    # redireccion y con una linea de comandos que ejecuta este Instalar.bat con
    # /c. Una terminal cmd abierta por Explorer tiene la misma topologia de
    # procesos, asi que la linea de comandos es la prueba adicional. En
    # cualquier otro caso (terminal existente, /k, destino distinto, duda o
    # lectura imposible) devuelve $null y el instalador se comporta como antes.
    param(
        [scriptblock]$ConsoleProbe = { Get-MensorCadConsoleProbe },
        [scriptblock]$ParentIdProbe = { param($ProcessId) Get-MensorCadProcessParentId -ProcessId $ProcessId },
        [scriptblock]$ProcessNameProbe = { param($ProcessId) Get-MensorCadProcessName -ProcessId $ProcessId },
        [scriptblock]$CommandLineProbe = { param($ProcessId) Get-MensorCadProcessCommandLine -ProcessId $ProcessId },
        [string]$BatchPath = '',
        [bool]$OutputRedirected = (Test-MensorCadConsoleHandoffBlocked),
        [string]$TerminalSession = $env:WT_SESSION,
        [int]$CurrentProcessId = $PID
    )
    if ($OutputRedirected) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($TerminalSession)) { return $null }
    try {
        $probe = & $ConsoleProbe
        if ($null -eq $probe) { return $null }
        $windowHandle = $probe.WindowHandle
        if ($null -eq $windowHandle) { return $null }
        if ($windowHandle -eq [IntPtr]::Zero) { return $null }
        if (-not [bool]$probe.WindowVisible) { return $null }
        $consoleProcessIds = @($probe.ProcessIds)
        if ($consoleProcessIds.Count -ne 2) { return $null }
        if (-not ($consoleProcessIds -contains $CurrentProcessId)) { return $null }
        $commandShellId = 0
        foreach ($candidate in $consoleProcessIds) {
            if ([int]$candidate -ne $CurrentProcessId) { $commandShellId = [int]$candidate }
        }
        if ($commandShellId -le 0) { return $null }
        if ((& $ParentIdProbe $CurrentProcessId) -ne $commandShellId) { return $null }
        if ((& $ProcessNameProbe $commandShellId) -notmatch '^cmd$') { return $null }
        $shellParentId = & $ParentIdProbe $commandShellId
        if ((& $ProcessNameProbe $shellParentId) -notmatch '^explorer$') { return $null }
        # Prueba adicional: la linea de comandos debe ser el doble clic de este
        # BAT. Si no se puede leer o no coincide, no se oculta nada.
        $expectedBatch = $BatchPath
        if ([string]::IsNullOrWhiteSpace($expectedBatch)) {
            if ([string]::IsNullOrWhiteSpace($script:MensorCadScriptRoot)) { return $null }
            $expectedBatch = Join-Path -Path $script:MensorCadScriptRoot -ChildPath 'Instalar.bat'
        }
        $commandLine = & $CommandLineProbe $commandShellId
        if ($null -eq (Get-MensorCadBatchCommandTarget -CommandLine $commandLine -BatchPath $expectedBatch)) { return $null }
        return [pscustomobject]@{ WindowHandle = $windowHandle }
    }
    catch {
        return $null
    }
}

function Set-MensorCadConsoleWindowVisible {
    # Oculta (SW_HIDE) o restaura (SW_SHOW) una ventana de consola concreta.
    # Nunca lanza: un fallo de la ventana no debe romper la instalacion.
    param([IntPtr]$WindowHandle, [bool]$Visible)
    if ($null -eq $WindowHandle) { return $false }
    if ($WindowHandle -eq [IntPtr]::Zero) { return $false }
    $native = Get-MensorCadConsoleNativeType
    if ($null -eq $native) { return $false }
    try {
        $command = 0
        if ($Visible) { $command = 5 }
        $null = $native::ShowWindow($WindowHandle, $command)
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-MensorCadElevatedSelf {
    param([switch]$Uninstall, [switch]$NoAnimation)
    $powerShellPath = Get-MensorCadPowerShellPath
    $scriptPath = $script:MensorCadScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = Join-Path -Path $script:MensorCadScriptRoot -ChildPath 'Install-MensorCAD.ps1'
    }
    $argumentString = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -ElevatedProcess'
    if ($Uninstall) { $argumentString += ' -Uninstall' }
    if ($NoAnimation) { $argumentString += ' -NoAnimation' }
    Write-MensorCadInfo 'Se abrira la ventana de UAC. Acepte para continuar.'
    # Ventana unica: solo una consola dedicada comprobada se oculta, y solo
    # mientras el proceso elevado (el que abre su propia ventana) esta vivo.
    # La restauracion vive en el finally, asi que tambien ocurre al cancelar
    # UAC, si el lanzamiento falla o si no hay proceso. El estado de salida y
    # los mensajes no cambian.
    $hiddenConsoleWindow = $null
    try {
        $dedicatedConsole = Get-MensorCadDedicatedConsole
        if ($null -ne $dedicatedConsole) {
            if (Set-MensorCadConsoleWindowVisible -WindowHandle $dedicatedConsole.WindowHandle -Visible $false) {
                $hiddenConsoleWindow = $dedicatedConsole.WindowHandle
            }
        }
        try {
            $process = Start-Process -FilePath $powerShellPath -ArgumentList $argumentString -Verb RunAs -Wait -PassThru
        }
        catch {
            throw ('No se obtuvo elevacion mediante UAC. La instalacion no se realizo. Detalle: ' + $_.Exception.Message)
        }
        if ($null -eq $process) {
            throw 'No se pudo iniciar el proceso elevado. La instalacion no se realizo.'
        }
        return [int]$process.ExitCode
    }
    finally {
        if ($null -ne $hiddenConsoleWindow) {
            $null = Set-MensorCadConsoleWindowVisible -WindowHandle $hiddenConsoleWindow -Visible $true
        }
    }
}

function Invoke-MensorCadCli {
    param(
        [switch]$Uninstall,
        [switch]$NoAnimation,
        [switch]$Help,
        [switch]$FromRelease,
        [string]$Version,
        [switch]$ElevatedProcess
    )
    $script:MensorCadPlainMode = ($NoAnimation -or (Test-MensorCadOutputRedirected))
    if ($Help) {
        Write-MensorCadUsage
        return 0
    }
    try {
        $argumentError = Get-MensorCadArgumentError -Uninstall:$Uninstall -FromRelease:$FromRelease -Version $Version -VersionSpecified:$PSBoundParameters.ContainsKey('Version')
        if ($null -ne $argumentError) {
            throw $argumentError
        }
        if (-not (Test-MensorCadWindows)) {
            throw 'Este instalador solo funciona en Windows con Windows PowerShell 5.1. No se escribio ningun archivo.'
        }
        Assert-MensorCad64BitHost
        if (-not $ElevatedProcess) {
            Write-MensorCadBanner
        }
        $programFilesRoot = Get-MensorCadProgramFilesRoot
        $destinationRoot = Get-MensorCadDestinationRoot

        if ($FromRelease) {
            return (Invoke-MensorCadRemoteInstall -Version $Version -NoAnimation:$NoAnimation)
        }

        $sourceRoot = $script:MensorCadScriptRoot

        if ($Uninstall) {
            Write-MensorCadStep -Number 1 -Total 3 -Message 'Comprobando la instalacion existente'
            $marker = Assert-MensorCadOwnedDestination -DestinationRoot $destinationRoot
            if ($null -eq $marker) {
                throw "MensorCAD no esta instalado en '$destinationRoot'."
            }
            if (-not (Test-MensorCadAdministrator)) {
                if ($ElevatedProcess) {
                    throw 'La sesion elevada no tiene permisos de administrador. La desinstalacion no se realizo.'
                }
                return (Invoke-MensorCadElevatedSelf -Uninstall -NoAnimation:$NoAnimation)
            }
            Write-MensorCadStep -Number 2 -Total 3 -Message 'Comprobando que AutoCAD este cerrado'
            Write-MensorCadStep -Number 3 -Total 3 -Message 'Desinstalando MensorCAD'
            $result = Uninstall-MensorCadBundle -DestinationRoot $destinationRoot -TrustedBoundary $programFilesRoot -AutoCadProbe { Test-MensorCadAutoCadRunning }
            Complete-MensorCadActivity
            Write-MensorCadSuccess ('MensorCAD se desinstalo correctamente. Archivos eliminados: {0}.' -f $result.RemovedFiles)
            return 0
        }

        $progressCallback = {
            param($phase, $current, $total, $path)
            Write-MensorCadProgress -Phase $phase -Current $current -Total $total -Path $path
        }

        Write-MensorCadStep -Number 1 -Total 4 -Message 'Validando el paquete local antes de pedir permisos'
        $null = Test-MensorCadSource -SourceRoot $sourceRoot -ProgressCallback $progressCallback
        Complete-MensorCadActivity

        Write-MensorCadStep -Number 2 -Total 4 -Message 'Comprobando permisos de administrador'
        if (-not (Test-MensorCadAdministrator)) {
            if ($ElevatedProcess) {
                throw 'La sesion elevada no tiene permisos de administrador. La instalacion no se realizo.'
            }
            return (Invoke-MensorCadElevatedSelf -NoAnimation:$NoAnimation)
        }

        Write-MensorCadStep -Number 3 -Total 4 -Message 'Revalidando el paquete despues de la elevacion'
        $null = Test-MensorCadSource -SourceRoot $sourceRoot -ProgressCallback $progressCallback
        Complete-MensorCadActivity

        Write-MensorCadStep -Number 4 -Total 4 -Message 'Instalando en Program Files'
        $result = Install-MensorCadBundle -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -TrustedBoundary $programFilesRoot -AutoCadProbe { Test-MensorCadAutoCadRunning } -ProgressCallback $progressCallback
        Complete-MensorCadActivity

        if ($result.Status -eq 'unchanged') {
            Write-MensorCadSuccess ('MensorCAD ya estaba actualizado en {0}. No se reescribieron archivos.' -f $result.DestinationRoot)
        }
        elseif ($result.Status -eq 'updated') {
            Write-MensorCadSuccess ('MensorCAD se actualizo correctamente en {0}. Archivos: {1}.' -f $result.DestinationRoot, $result.FileCount)
        }
        else {
            Write-MensorCadSuccess ('MensorCAD se instalo correctamente en {0}. Archivos: {1}.' -f $result.DestinationRoot, $result.FileCount)
        }
        foreach ($warning in @($result.CleanupWarnings)) {
            if (-not [string]::IsNullOrWhiteSpace($warning)) {
                Write-MensorCadInfo ('Aviso: ' + $warning)
            }
        }
        Write-MensorCadInfo 'Abra AutoCAD para cargar el bundle instalado.'
        return 0
    }
    catch {
        Complete-MensorCadActivity
        Write-MensorCadFailure $_.Exception.Message
        return 1
    }
}

# Guarda de dot-source: cargar el archivo para pruebas no debe ejecutar nada.
if ($script:MensorCadDotSourced) {
    return
}

$mensorCadCliArguments = @{}
if ($Uninstall) { $mensorCadCliArguments['Uninstall'] = $true }
if ($NoAnimation) { $mensorCadCliArguments['NoAnimation'] = $true }
if ($Help) { $mensorCadCliArguments['Help'] = $true }
if ($FromRelease) { $mensorCadCliArguments['FromRelease'] = $true }
if ($PSBoundParameters.ContainsKey('Version')) { $mensorCadCliArguments['Version'] = $Version }
if ($ElevatedProcess) { $mensorCadCliArguments['ElevatedProcess'] = $true }
exit (Invoke-MensorCadCli @mensorCadCliArguments)
