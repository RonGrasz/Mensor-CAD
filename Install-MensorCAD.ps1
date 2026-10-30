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

.PARAMETER ElevatedProcess
    Reservado. Lo usa la relanzada elevada para no repetir el banner. No evita
    ninguna comprobacion de administrador.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoAnimation,
    [switch]$Help,
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
    Write-Host ''
    Write-Host 'Opciones:'
    Write-Host '  -Uninstall    Desinstala la copia propia de MensorCAD.'
    Write-Host '  -NoAnimation  Desactiva colores y animaciones.'
    Write-Host '  -Help         Muestra esta ayuda.'
    Write-Host ''
    Write-Host 'Destino fijo:'
    Write-Host '  <Program Files>\Autodesk\ApplicationPlugins\MensorCAD.bundle'
    Write-Host ''
    Write-Host 'Requiere Windows de 64 bits y PowerShell de 64 bits.'
    Write-Host 'La instalacion y la desinstalacion requieren permisos de administrador (UAC).'
}

function Invoke-MensorCadElevatedSelf {
    param([switch]$Uninstall, [switch]$NoAnimation)
    $powerShellPath = 'powershell.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $candidatePath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $powerShellPath = $candidatePath
        }
    }
    $scriptPath = $script:MensorCadScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = Join-Path -Path $script:MensorCadScriptRoot -ChildPath 'Install-MensorCAD.ps1'
    }
    $argumentString = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -ElevatedProcess'
    if ($Uninstall) { $argumentString += ' -Uninstall' }
    if ($NoAnimation) { $argumentString += ' -NoAnimation' }
    Write-MensorCadInfo 'Se abrira la ventana de UAC. Acepte para continuar.'
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

function Invoke-MensorCadCli {
    param(
        [switch]$Uninstall,
        [switch]$NoAnimation,
        [switch]$Help,
        [switch]$ElevatedProcess
    )
    $script:MensorCadPlainMode = ($NoAnimation -or (Test-MensorCadOutputRedirected))
    if ($Help) {
        Write-MensorCadUsage
        return 0
    }
    try {
        if (-not (Test-MensorCadWindows)) {
            throw 'Este instalador solo funciona en Windows con Windows PowerShell 5.1. No se escribio ningun archivo.'
        }
        Assert-MensorCad64BitHost
        if (-not $ElevatedProcess) {
            Write-MensorCadBanner
        }
        $sourceRoot = $script:MensorCadScriptRoot
        $programFilesRoot = Get-MensorCadProgramFilesRoot
        $destinationRoot = Get-MensorCadDestinationRoot

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

exit (Invoke-MensorCadCli -Uninstall:$Uninstall -NoAnimation:$NoAnimation -Help:$Help -ElevatedProcess:$ElevatedProcess)
