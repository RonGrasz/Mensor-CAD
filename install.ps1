# Bootstrap de la entrada remota del gestor "mensorcad" de MensorCAD.
#
# Este archivo ya no instala el complemento de AutoCAD. Instala SOLO el gestor
# de linea de comandos en la carpeta fija del usuario y lo registra en el PATH
# del usuario actual. El complemento se instala despues, a proposito, con
# "mensorcad install": son dos pasos distintos y este bootstrap nunca ejecuta
# nada descargado.
#
# Comandos publicados (la guia completa esta en docs/cli-bootstrap.md):
#   - release mas reciente, con el comando corto irm ... | iex;
#   - release fijado con -Version, si hace falta reproducir una version.
#
# Contrato de salida: no ejecuta exit para no cerrar la sesion del usuario
# cuando el texto llega por iex, que corre en el ambito del llamador. El codigo
# real (0 exito, 1 fallo) queda en $global:LASTEXITCODE y no hay otra salida en
# la tuberia. Para automatizar con un codigo de salida del sistema operativo
# ejecute "& .\install.ps1; exit $LASTEXITCODE" o consulte la guia.
#
# Seguridad del flujo:
#   1. resuelve el release oficial una sola vez (API o -Version);
#   2. descarga MensorCAD-CLI.zip y su sidecar .sha256 del tag fijado;
#   3. valida tamano, SHA-256 y las tres entradas planas exactas del ZIP
#      (sin duplicados, traversal ni enlaces) ANTES de escribir el destino;
#   4. prepara una carpeta de staging propia, escribe el marcador y reemplaza
#      el gestor de forma transaccional, con respaldo y rollback;
#   5. agrega la carpeta al PATH del USUARIO una sola vez, conservando el
#      contenido sin expandir y el tipo REG_SZ o REG_EXPAND_SZ.
#
# Nunca se escribe el PATH de maquina, no se cambia la politica de ejecucion, no
# se pide elevacion y no se toca ningun archivo ajeno del destino. La revision
# SHA-256 no autentica al publicador: solo comprueba que el ZIP coincide con el
# sidecar del release fijo RonGrasz/Mensor-CAD.

param(
    [string]$Version,
    [switch]$NoAnimation
)

& {
    param(
        $Version,
        [switch]$NoAnimation,
        [bool]$VersionSpecified
    )
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'

    # Fuente fija: no hay parametro publico de URL, repositorio, destino ni UAC.
    $repository = 'RonGrasz/Mensor-CAD'
    $releaseHost = 'https://github.com'
    $apiHost = 'https://api.github.com'
    $cliAssetName = 'MensorCAD-CLI.zip'
    $cliHashAssetName = 'MensorCAD-CLI.zip.sha256'
    # Mismo patron de tag que usa el instalador real: si no coincide, no hay red
    # ni escrituras.
    $releaseTagPattern = '^v?\d+\.\d+(\.\d+)*([-+][0-9A-Za-z][0-9A-Za-z.-]*)?$'
    # Destino fijo del gestor, siempre dentro del perfil del usuario actual.
    $managerFolderName = 'MensorCAD'
    $managerSubfolderName = 'cli'
    $managerFiles = @('mensorcad.ps1', 'mensorcad.cmd', 'Install-MensorCAD.ps1')
    $markerName = '.mensorcad-cli.json'
    # Carpetas propias: el GUID completo hace imposible reutilizar una ajena.
    $workspacePrefix = 'mensorcad-cli-'
    $stagingPrefix = 'cli.staging-'
    $backupPrefix = 'cli.backup-'
    # Topes acotados: un ZIP del gestor ronda unos pocos kilobytes.
    $maxZipBytes = 16777216
    $maxSidecarBytes = 4096
    $maxEntryBytes = 4194304
    $maxTotalEntryBytes = 8388608
    $userEnvironmentKeyPath = 'HKCU:\Environment'
    $hashPattern = '^(?<hash>[0-9a-fA-F]{64})  MensorCAD-CLI\.zip\r?\n\z'

    # La presencia de -Version se decide en el ambito que realmente ligo los
    # parametros: un [string] omitido no es una cadena vacia explicita.
    $versionSpecified = $VersionSpecified
    $versionTag = ''
    if ($versionSpecified) { $versionTag = [string]$Version }

    function Write-CliBootstrapInfo {
        param([string]$Message)
        [Console]::Out.WriteLine($Message)
    }

    function Write-CliBootstrapError {
        param([string]$Message)
        [Console]::Error.WriteLine('ERROR: ' + $Message)
    }

    function Write-CliBootstrapWarning {
        param([string]$Message)
        [Console]::Error.WriteLine('AVISO: ' + $Message)
    }

    # Un fallo previsto (validacion, descarga, destino, PATH) viaja como una
    # excepcion con prefijo propio. El catch exterior distingue ese prefijo de
    # un error inesperado de PowerShell para no perder el mensaje exacto.
    function New-CliBootstrapStopException {
        param([string]$Message)
        return (New-Object -TypeName System.OperationCanceledException -ArgumentList @('MENSORCAD-CLI: ' + $Message))
    }

    function Test-CliBootstrapReparse {
        param([string]$Path)
        if (-not ([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path))) { return $false }
        $attributes = [System.IO.File]::GetAttributes($Path)
        return (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }

    function Get-CliBootstrapMarker {
        # Un marcador solo cuenta si se puede leer y declara schema y duenio. Un
        # archivo con ese nombre pero contenido dudoso no autoriza a borrar nada.
        param([string]$DirectoryPath)
        $markerPath = Join-Path -Path $DirectoryPath -ChildPath $markerName
        if (-not [System.IO.File]::Exists($markerPath)) { return $null }
        try {
            $markerText = [System.IO.File]::ReadAllText($markerPath)
            $data = $markerText | ConvertFrom-Json
        }
        catch {
            return $null
        }
        if ($null -eq $data) { return $null }
        $schemaProperty = $data.PSObject.Properties['schema']
        $ownerProperty = $data.PSObject.Properties['owner']
        if (($null -eq $schemaProperty) -or ($null -eq $ownerProperty)) { return $null }
        if ([int]$schemaProperty.Value -ne 1) { return $null }
        if ([string]$ownerProperty.Value -ne 'MensorCAD-CLI') { return $null }
        return $data
    }

    function Get-CliBootstrapDestinationMessage {
        param([string]$DestinationPath)
        return ('El destino no es una instalacion del gestor de MensorCAD: ' + $DestinationPath + '. Se cancela sin tocar archivos ajenos.')
    }

    function Get-CliBootstrapReparseMessage {
        param([string]$Path)
        return ('El destino o su carpeta padre es un punto de reanalisis: ' + $Path + '. Se cancela sin tocar archivos ajenos.')
    }

    function Assert-CliBootstrapManagedRoot {
        param([string]$ManagedRootPath)
        if ([System.IO.File]::Exists($ManagedRootPath) -and -not [System.IO.Directory]::Exists($ManagedRootPath)) {
            throw (New-CliBootstrapStopException ('El destino existe y no es una carpeta: ' + $ManagedRootPath + '. Se cancela sin tocar archivos ajenos.'))
        }
        if ((Test-CliBootstrapReparse -Path $ManagedRootPath) -and [System.IO.Directory]::Exists($ManagedRootPath)) {
            throw (New-CliBootstrapStopException (Get-CliBootstrapReparseMessage -Path $ManagedRootPath))
        }
    }

    function Assert-CliBootstrapDestination {
        # Solo es propio un destino con marcador valido y sin contenido
        # desconocido. Cualquier otra cosa es ajena y no se toca.
        param([string]$DestinationPath)
        if ([System.IO.File]::Exists($DestinationPath) -and -not [System.IO.Directory]::Exists($DestinationPath)) {
            throw (New-CliBootstrapStopException ('El destino existe y no es una carpeta: ' + $DestinationPath + '. Se cancela sin tocar archivos ajenos.'))
        }
        if (-not [System.IO.Directory]::Exists($DestinationPath)) { return }
        if (Test-CliBootstrapReparse -Path $DestinationPath) {
            throw (New-CliBootstrapStopException (Get-CliBootstrapReparseMessage -Path $DestinationPath))
        }
        $marker = Get-CliBootstrapMarker -DirectoryPath $DestinationPath
        if ($null -eq $marker) {
            throw (New-CliBootstrapStopException (Get-CliBootstrapDestinationMessage -DestinationPath $DestinationPath))
        }
        foreach ($entryPath in [System.IO.Directory]::GetFileSystemEntries($DestinationPath)) {
            $entryName = [System.IO.Path]::GetFileName($entryPath)
            $allowed = $false
            if ($entryName -ieq $markerName) { $allowed = $true }
            foreach ($name in $managerFiles) {
                if ($entryName -ieq $name) { $allowed = $true; break }
            }
            if (-not $allowed) {
                throw (New-CliBootstrapStopException (Get-CliBootstrapDestinationMessage -DestinationPath $DestinationPath))
            }
            if (-not [System.IO.File]::Exists($entryPath)) {
                throw (New-CliBootstrapStopException (Get-CliBootstrapDestinationMessage -DestinationPath $DestinationPath))
            }
            if (Test-CliBootstrapReparse -Path $entryPath) {
                throw (New-CliBootstrapStopException (Get-CliBootstrapReparseMessage -Path $DestinationPath))
            }
        }
    }

    function Get-CliBootstrapEnvironmentKey {
        # Get-Item devuelve la clave de registro real: se usa .NET para leer el
        # tipo del valor sin expandirlo y para escribirlo con el mismo tipo.
        return Get-Item -LiteralPath $userEnvironmentKeyPath -Force
    }

    function Get-CliBootstrapPathEntryKey {
        param([string]$Entry)
        $value = [string]$Entry
        $value = $value.Trim()
        if (($value.Length -ge 2) -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $expanded = $value
        try { $expanded = [System.Environment]::ExpandEnvironmentVariables($value) }
        catch { $expanded = $value }
        return $expanded.TrimEnd('\').ToLowerInvariant()
    }

    function Set-CliBootstrapUserPath {
        # Agrega la carpeta del gestor solo si no esta ya. No reescribe ni
        # expande las entradas existentes y conserva REG_SZ o REG_EXPAND_SZ.
        param([string]$ManagerDirectory)
        $key = Get-CliBootstrapEnvironmentKey
        $names = @($key.GetValueNames())
        $pathName = $null
        foreach ($name in $names) {
            if ([string]$name -ieq 'Path') { $pathName = [string]$name; break }
        }
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        $rawValue = ''
        if ($null -ne $pathName) {
            $kind = $key.GetValueKind($pathName)
            if (($kind -ne [Microsoft.Win32.RegistryValueKind]::String) -and ($kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
                throw (New-CliBootstrapStopException ('El PATH del usuario tiene un tipo no soportado: ' + [string]$kind + '. Se restauro la instalacion anterior.'))
            }
            $raw = $key.GetValue($pathName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $raw) { $rawValue = [string]$raw }
        }
        else {
            $pathName = 'Path'
        }

        $targetKey = Get-CliBootstrapPathEntryKey -Entry $ManagerDirectory
        foreach ($entry in @($rawValue -split ';')) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            if ((Get-CliBootstrapPathEntryKey -Entry $entry) -eq $targetKey) {
                return [pscustomobject]@{ Changed = $false; Kind = $kind; Value = $rawValue }
            }
        }

        $newValue = $rawValue.TrimEnd(';')
        if ($newValue.Length -eq 0) { $newValue = $ManagerDirectory }
        else { $newValue = $newValue + ';' + $ManagerDirectory }

        $written = $false
        try {
            $key.SetValue($pathName, $newValue, $kind)
            $written = $true
            $readBack = $key.GetValue($pathName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $readKind = $key.GetValueKind($pathName)
            if ([string]$readBack -ne $newValue) {
                throw 'La verificacion del PATH no coincide con lo escrito.'
            }
            if ($readKind -ne $kind) {
                throw 'La verificacion del tipo del PATH no coincide con lo escrito.'
            }
        }
        catch {
            if ($written) {
                try { $key.SetValue($pathName, $rawValue, $kind) }
                catch { }
            }
            throw (New-CliBootstrapStopException ('No se pudo registrar la carpeta del gestor en el PATH del usuario: ' + $_.Exception.Message + ' Se restauro la instalacion anterior.'))
        }
        return [pscustomobject]@{ Changed = $true; Kind = $kind; Value = $newValue }
    }

    function Add-CliBootstrapProcessPath {
        # Comodidad para la sesion que ejecuta irm ... | iex: el PATH del
        # proceso actual tambien queda listo. Las demas terminales ya abiertas
        # necesitan reiniciarse; se explica en la salida.
        param([string]$ManagerDirectory)
        $current = [string]$env:Path
        $targetKey = Get-CliBootstrapPathEntryKey -Entry $ManagerDirectory
        foreach ($entry in @($current -split ';')) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            if ((Get-CliBootstrapPathEntryKey -Entry $entry) -eq $targetKey) { return }
        }
        if ([string]::IsNullOrWhiteSpace($current)) { $env:Path = $ManagerDirectory }
        else { $env:Path = $current.TrimEnd(';') + ';' + $ManagerDirectory }
    }

    function Resolve-CliBootstrapReleaseTag {
        # Una sola resolucion: la API se consulta una vez y despues todo sale
        # del tag fijado. Con -Version no hay ninguna consulta.
        param([string]$RequestedTag, [bool]$Requested)
        if ($Requested) { return $RequestedTag }
        $releaseUri = $apiHost + '/repos/' + $repository + '/releases/latest'
        $release = $null
        try {
            $release = Invoke-RestMethod -UseBasicParsing -Uri $releaseUri -Headers @{
                'User-Agent' = 'MensorCAD-Bootstrap'
                'Accept' = 'application/vnd.github+json'
            } -ErrorAction Stop
        }
        catch {
            throw (New-CliBootstrapStopException ('No se pudo consultar el release oficial de MensorCAD: ' + $_.Exception.Message + ' No se instalo nada.'))
        }
        $tagText = '(sin tag)'
        if ($null -ne $release) {
            $tagProperty = $release.PSObject.Properties['tag_name']
            if ($null -ne $tagProperty) { $tagText = [string]$tagProperty.Value }
        }
        if ([string]::IsNullOrWhiteSpace($tagText)) { $tagText = '(sin tag)' }
        if (($tagText -eq '(sin tag)') -or ($tagText -notmatch $releaseTagPattern)) {
            throw (New-CliBootstrapStopException ('El release oficial no informo un tag valido: ' + $tagText + '. No se instalo nada.'))
        }
        return $tagText
    }

    function Save-CliBootstrapAsset {
        param([string]$AssetName, [string]$Uri, [string]$Destination, [string]$Tag, [long]$MaxBytes)
        try {
            $null = Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -ErrorAction Stop
        }
        catch {
            throw (New-CliBootstrapStopException ('No se pudo descargar ' + $AssetName + ' del release ' + $Tag + ': ' + $_.Exception.Message + ' No se instalo nada.'))
        }
        if (-not [System.IO.File]::Exists($Destination)) {
            throw (New-CliBootstrapStopException ('El archivo descargado no existe o supera el limite permitido: ' + $AssetName + '. No se instalo nada.'))
        }
        $length = (New-Object -TypeName System.IO.FileInfo -ArgumentList @($Destination)).Length
        if (($length -le 0) -or ($length -gt $MaxBytes)) {
            throw (New-CliBootstrapStopException ('El archivo descargado no existe o supera el limite permitido: ' + $AssetName + '. No se instalo nada.'))
        }
    }

    function Read-CliBootstrapSidecarHash {
        # Formato exacto del sidecar publicado: 64 hex, DOS espacios,
        # MensorCAD-CLI.zip y salto de linea final. Nada mas.
        param([string]$SidecarPath)
        $length = (New-Object -TypeName System.IO.FileInfo -ArgumentList @($SidecarPath)).Length
        if (($length -le 0) -or ($length -gt $maxSidecarBytes)) {
            throw (New-CliBootstrapStopException 'El sidecar SHA256 no tiene el formato esperado (64 hex, dos espacios, MensorCAD-CLI.zip y salto de linea). No se instalo nada.')
        }
        $text = [System.IO.File]::ReadAllText($SidecarPath)
        $match = [System.Text.RegularExpressions.Regex]::Match($text, $hashPattern)
        if (-not $match.Success) {
            throw (New-CliBootstrapStopException 'El sidecar SHA256 no tiene el formato esperado (64 hex, dos espacios, MensorCAD-CLI.zip y salto de linea). No se instalo nada.')
        }
        return $match.Groups['hash'].Value
    }

    function Test-CliBootstrapZipHash {
        param([string]$ZipPath, [string]$ExpectedHash)
        $actualHash = ''
        try {
            $actualHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            throw (New-CliBootstrapStopException ('No se pudo calcular el SHA256 del ZIP descargado: ' + $_.Exception.Message + ' No se instalo nada.'))
        }
        if ($actualHash.ToLowerInvariant() -ne $ExpectedHash.ToLowerInvariant()) {
            throw (New-CliBootstrapStopException 'El SHA256 del ZIP no coincide con el sidecar publicado. No se instalo nada.')
        }
    }

    function Assert-CliBootstrapZipEntries {
        # Valida el indice del ZIP sin extraer nada: tres entradas planas
        # exactas, sin duplicados por caja, sin enlaces y con tamanios acotados.
        param([string]$ZipPath)
        try {
            Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        }
        catch {
            throw (New-CliBootstrapStopException ('No se pudo preparar la lectura del ZIP: ' + $_.Exception.Message + ' No se instalo nada.'))
        }
        $archive = $null
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        }
        catch {
            throw (New-CliBootstrapStopException ('El ZIP descargado no se puede abrir: ' + $_.Exception.Message + ' No se instalo nada.'))
        }
        try {
            $entries = @($archive.Entries)
            if ($entries.Count -ne $managerFiles.Count) {
                throw (New-CliBootstrapStopException 'El ZIP no contiene exactamente mensorcad.ps1, mensorcad.cmd e Install-MensorCAD.ps1. No se instalo nada.')
            }
            $seen = New-Object 'System.Collections.Generic.List[string]'
            $totalLength = [long]0
            foreach ($entry in $entries) {
                $entryName = [string]$entry.FullName
                if ([string]::IsNullOrEmpty($entryName)) {
                    throw (New-CliBootstrapStopException 'El ZIP tiene entradas duplicadas, rutas no planas o nombres no permitidos. No se instalo nada.')
                }
                if ($entryName.Contains('/') -or $entryName.Contains('\') -or $entryName.Contains('..')) {
                    throw (New-CliBootstrapStopException 'El ZIP tiene entradas duplicadas, rutas no planas o nombres no permitidos. No se instalo nada.')
                }
                if ($entryName -ne [System.IO.Path]::GetFileName($entryName)) {
                    throw (New-CliBootstrapStopException 'El ZIP tiene entradas duplicadas, rutas no planas o nombres no permitidos. No se instalo nada.')
                }
                $matchedName = $null
                foreach ($name in $managerFiles) {
                    if ($entryName -ieq $name) { $matchedName = $name; break }
                }
                if ($null -eq $matchedName) {
                    throw (New-CliBootstrapStopException 'El ZIP no contiene exactamente mensorcad.ps1, mensorcad.cmd e Install-MensorCAD.ps1. No se instalo nada.')
                }
                foreach ($already in $seen) {
                    if ($already -ieq $matchedName) {
                        throw (New-CliBootstrapStopException 'El ZIP tiene entradas duplicadas, rutas no planas o nombres no permitidos. No se instalo nada.')
                    }
                }
                $seen.Add($matchedName)
                $unixMode = (($entry.ExternalAttributes -shr 16) -band 0xF000)
                if (($unixMode -eq 0xA000) -or (($entry.ExternalAttributes -band 0x400) -ne 0)) {
                    throw (New-CliBootstrapStopException 'El ZIP contiene una entrada que no es un archivo regular. No se instalo nada.')
                }
                if (($entry.Length -lt 0) -or ($entry.Length -gt $maxEntryBytes)) {
                    throw (New-CliBootstrapStopException 'El ZIP supera los limites de tamano permitidos. No se instalo nada.')
                }
                $totalLength += $entry.Length
                if ($totalLength -gt $maxTotalEntryBytes) {
                    throw (New-CliBootstrapStopException 'El ZIP supera los limites de tamano permitidos. No se instalo nada.')
                }
            }
            if ($seen.Count -ne $managerFiles.Count) {
                throw (New-CliBootstrapStopException 'El ZIP no contiene exactamente mensorcad.ps1, mensorcad.cmd e Install-MensorCAD.ps1. No se instalo nada.')
            }
        }
        finally {
            $archive.Dispose()
        }
    }

    function Expand-CliBootstrapZip {
        # Extraccion propia: nunca ExtractToDirectory, siempre archivos regulares
        # y un tope real de bytes leidos por entrada. Se ejecuta solo despues de
        # Assert-CliBootstrapZipEntries, pero carga el ensamblado por si sola
        # para no depender del orden de las funciones.
        param([string]$ZipPath, [string]$StagingPath)
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($name in $managerFiles) {
                $entry = $null
                foreach ($candidate in @($archive.Entries)) {
                    if ([string]$candidate.FullName -ieq $name) { $entry = $candidate; break }
                }
                if ($null -eq $entry) {
                    throw (New-CliBootstrapStopException 'El ZIP no contiene exactamente mensorcad.ps1, mensorcad.cmd e Install-MensorCAD.ps1. No se instalo nada.')
                }
                $targetPath = Join-Path -Path $StagingPath -ChildPath $name
                $source = $entry.Open()
                try {
                    $target = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $buffer = New-Object byte[] 65536
                        $written = [long]0
                        while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $written += $read
                            if (($written -gt $entry.Length) -or ($written -gt $maxEntryBytes)) {
                                throw (New-CliBootstrapStopException 'El ZIP supera los limites de tamano permitidos. No se instalo nada.')
                            }
                            $target.Write($buffer, 0, $read)
                        }
                        if ($written -ne $entry.Length) {
                            throw (New-CliBootstrapStopException 'El ZIP supera los limites de tamano permitidos. No se instalo nada.')
                        }
                    }
                    finally {
                        $target.Dispose()
                    }
                }
                finally {
                    $source.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }

    function Write-CliBootstrapMarker {
        param([string]$DirectoryPath, [string]$Tag)
        $marker = [ordered]@{
            schema = 1
            owner = 'MensorCAD-CLI'
            source = $repository
            version = $Tag
            installed = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            files = @($managerFiles)
        }
        $markerPath = Join-Path -Path $DirectoryPath -ChildPath $markerName
        [System.IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Compress), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)))
    }

    function New-CliBootstrapStagingDirectory {
        param([string]$ManagedRootPath)
        $stagingPath = Join-Path -Path $ManagedRootPath -ChildPath ($stagingPrefix + [guid]::NewGuid().ToString('N'))
        if ([System.IO.File]::Exists($stagingPath) -or [System.IO.Directory]::Exists($stagingPath)) {
            throw (New-CliBootstrapStopException ('No se pudo preparar una carpeta propia de trabajo: ' + $stagingPath + '. No se instalo nada.'))
        }
        $null = [System.IO.Directory]::CreateDirectory($stagingPath)
        if (Test-CliBootstrapReparse -Path $stagingPath) {
            throw (New-CliBootstrapStopException ('No se pudo preparar una carpeta propia de trabajo: ' + $stagingPath + '. No se instalo nada.'))
        }
        return $stagingPath
    }

    function Remove-CliBootstrapOwnedDirectory {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        if (-not [System.IO.Directory]::Exists($Path)) { return }
        if (Test-CliBootstrapReparse -Path $Path) {
            throw (New-CliBootstrapStopException ('La carpeta propia a limpiar es un punto de reanalisis: ' + $Path + '. Se conserva en disco.'))
        }
        [System.IO.Directory]::Delete($Path, $true)
    }

    function Install-CliBootstrapManager {
        # Reemplazo transaccional: respaldo del gestor anterior y staging propio.
        param([string]$StagingPath, [string]$DestinationPath)
        $backupPath = $null
        $hadPrevious = [System.IO.Directory]::Exists($DestinationPath)
        if ($hadPrevious) {
            Assert-CliBootstrapDestination -DestinationPath $DestinationPath
            $backupPath = Join-Path -Path (Split-Path -Parent $DestinationPath) -ChildPath ($backupPrefix + [guid]::NewGuid().ToString('N'))
            [System.IO.Directory]::Move($DestinationPath, $backupPath)
        }
        try {
            [System.IO.Directory]::Move($StagingPath, $DestinationPath)
        }
        catch {
            if ((-not [string]::IsNullOrWhiteSpace($backupPath)) -and [System.IO.Directory]::Exists($backupPath)) {
                try {
                    if (-not [System.IO.Directory]::Exists($DestinationPath)) {
                        [System.IO.Directory]::Move($backupPath, $DestinationPath)
                    }
                }
                catch {
                    Write-CliBootstrapWarning ('No se pudo devolver el respaldo anterior: ' + $backupPath + '. Se conserva en disco: ' + $_.Exception.Message)
                }
            }
            throw (New-CliBootstrapStopException ('No se pudo colocar el gestor en el destino: ' + $_.Exception.Message + ' No se instalo nada.'))
        }
        return [pscustomobject]@{ Backup = $backupPath; HadPrevious = $hadPrevious }
    }

    function Undo-CliBootstrapManagerInstall {
        param([string]$DestinationPath, [string]$BackupPath, [string]$StagingPath)
        if ((-not [string]::IsNullOrWhiteSpace($StagingPath)) -and [System.IO.Directory]::Exists($StagingPath)) {
            Remove-CliBootstrapOwnedDirectory -Path $StagingPath
        }
        if ([string]::IsNullOrWhiteSpace($DestinationPath)) { return }
        if (-not [System.IO.Directory]::Exists($DestinationPath)) { return }
        # Solo se revierte una carpeta que el marcador identifica como nuestra.
        $marker = Get-CliBootstrapMarker -DirectoryPath $DestinationPath
        if ($null -eq $marker) { return }
        if ((-not [string]::IsNullOrWhiteSpace($BackupPath)) -and [System.IO.Directory]::Exists($BackupPath)) {
            Remove-CliBootstrapOwnedDirectory -Path $DestinationPath
            [System.IO.Directory]::Move($BackupPath, $DestinationPath)
            return
        }
        Remove-CliBootstrapOwnedDirectory -Path $DestinationPath
    }

    $exitCode = $null
    $tempRoot = $null
    $tempWorkspace = $null
    $tempWorkspaceOwned = $false
    $stagingPath = $null
    $backupPath = $null
    $destinationPath = $null
    $managerInstalled = $false

    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw (New-CliBootstrapStopException 'Este bootstrap solo funciona en Windows con Windows PowerShell 5.1. No se descargo nada.')
        }
        if ($versionSpecified -and [string]::IsNullOrWhiteSpace($versionTag)) {
            throw (New-CliBootstrapStopException 'La opcion -Version necesita un tag, por ejemplo v1.2.3. No se descargo nada ni se escribio nada.')
        }
        if ($versionSpecified -and ($versionTag -notmatch $releaseTagPattern)) {
            throw (New-CliBootstrapStopException ('El tag de -Version no es valido: ' + $versionTag + '. Se espera un tag como v1.2.3. No se descargo nada ni se escribio nada.'))
        }

        # Carpeta del usuario y destino: se comprueban antes de la red y de
        # cualquier escritura. Un destino ajeno detiene el flujo aqui mismo.
        $localAppData = [string]$env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($localAppData) -or (-not [System.IO.Path]::IsPathRooted($localAppData)) -or (-not [System.IO.Directory]::Exists($localAppData))) {
            throw (New-CliBootstrapStopException 'Falta LOCALAPPDATA o no es una carpeta absoluta existente. No se modifico el destino.')
        }
        $managedRoot = Join-Path -Path $localAppData -ChildPath $managerFolderName
        $destinationPath = Join-Path -Path $managedRoot -ChildPath $managerSubfolderName
        Assert-CliBootstrapManagedRoot -ManagedRootPath $managedRoot
        Assert-CliBootstrapDestination -DestinationPath $destinationPath

        $tempRoot = [System.IO.Path]::GetTempPath()
        if ([string]::IsNullOrWhiteSpace($tempRoot) -or (-not [System.IO.Directory]::Exists($tempRoot))) {
            throw (New-CliBootstrapStopException 'No existe una carpeta temporal valida para descargar el gestor. No se modifico el destino.')
        }

        # TLS 1.2 solo para este proceso; no se cambia ninguna politica global.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        catch {
            Write-CliBootstrapWarning 'no se pudo habilitar TLS 1.2 en este proceso; la descarga podria fallar.'
        }

        $workspaceCandidate = Join-Path -Path $tempRoot -ChildPath ($workspacePrefix + [guid]::NewGuid().ToString('N'))
        if ([System.IO.File]::Exists($workspaceCandidate) -or [System.IO.Directory]::Exists($workspaceCandidate)) {
            throw (New-CliBootstrapStopException ('No se pudo crear una carpeta temporal propia: ' + $workspaceCandidate + '. No se modifico el destino.'))
        }
        $null = [System.IO.Directory]::CreateDirectory($workspaceCandidate)
        if (Test-CliBootstrapReparse -Path $workspaceCandidate) {
            throw (New-CliBootstrapStopException ('La carpeta temporal propia es un punto de reanalisis: ' + $workspaceCandidate + '. Se cancela sin instalar.'))
        }
        $tempWorkspace = $workspaceCandidate
        $tempWorkspaceOwned = $true

        $releaseTag = Resolve-CliBootstrapReleaseTag -RequestedTag $versionTag -Requested $versionSpecified

        $zipPath = Join-Path -Path $tempWorkspace -ChildPath $cliAssetName
        $hashPath = Join-Path -Path $tempWorkspace -ChildPath $cliHashAssetName
        $releaseBase = $releaseHost + '/' + $repository + '/releases/download/' + $releaseTag + '/'
        Save-CliBootstrapAsset -AssetName $cliAssetName -Uri ($releaseBase + $cliAssetName) -Destination $zipPath -Tag $releaseTag -MaxBytes $maxZipBytes
        Save-CliBootstrapAsset -AssetName $cliHashAssetName -Uri ($releaseBase + $cliHashAssetName) -Destination $hashPath -Tag $releaseTag -MaxBytes $maxSidecarBytes

        $expectedHash = Read-CliBootstrapSidecarHash -SidecarPath $hashPath
        Test-CliBootstrapZipHash -ZipPath $zipPath -ExpectedHash $expectedHash
        Assert-CliBootstrapZipEntries -ZipPath $zipPath

        # Primera escritura persistente: recien despues de validar el ZIP.
        if (-not [System.IO.Directory]::Exists($managedRoot)) {
            $null = [System.IO.Directory]::CreateDirectory($managedRoot)
        }
        Assert-CliBootstrapManagedRoot -ManagedRootPath $managedRoot
        Assert-CliBootstrapDestination -DestinationPath $destinationPath

        $stagingPath = New-CliBootstrapStagingDirectory -ManagedRootPath $managedRoot
        Expand-CliBootstrapZip -ZipPath $zipPath -StagingPath $stagingPath
        Write-CliBootstrapMarker -DirectoryPath $stagingPath -Tag $releaseTag

        $swap = Install-CliBootstrapManager -StagingPath $stagingPath -DestinationPath $destinationPath
        $stagingPath = $null
        $backupPath = $swap.Backup
        $managerInstalled = $true

        $pathResult = Set-CliBootstrapUserPath -ManagerDirectory $destinationPath
        Add-CliBootstrapProcessPath -ManagerDirectory $destinationPath

        # El respaldo ya no hace falta: el gestor y el PATH quedaron bien.
        if ((-not [string]::IsNullOrWhiteSpace($backupPath)) -and [System.IO.Directory]::Exists($backupPath)) {
            try {
                Remove-CliBootstrapOwnedDirectory -Path $backupPath
            }
            catch {
                Write-CliBootstrapWarning ('no se pudo limpiar el respaldo ' + $backupPath + '; se conserva en disco: ' + $_.Exception.Message)
            }
            $backupPath = $null
        }

        if ($swap.HadPrevious) { $stateText = 'actualizado' }
        else { $stateText = 'instalado' }
        Write-CliBootstrapInfo ('MensorCAD: gestor ' + $stateText + ' en ' + $destinationPath)
        if ($pathResult.Changed) {
            Write-CliBootstrapInfo 'PATH de usuario actualizado: abra una terminal nueva y ejecute "mensorcad --help". Otras terminales abiertas necesitan reiniciarse.'
        }
        else {
            Write-CliBootstrapInfo 'El PATH de usuario ya incluia la carpeta del gestor; no se agrego de nuevo.'
        }
        Write-CliBootstrapInfo 'Siguiente paso: "mensorcad install" instala el complemento para AutoCAD.'
        $exitCode = 0
    }
    catch {
        $errorText = [string]$_.Exception.Message
        if ($errorText.StartsWith('MENSORCAD-CLI: ')) {
            $errorText = $errorText.Substring('MENSORCAD-CLI: '.Length)
        }
        else {
            $errorText = 'No se pudo instalar el gestor de MensorCAD: ' + $errorText + ' No se da la instalacion por hecha.'
        }
        if ($managerInstalled) {
            try {
                Undo-CliBootstrapManagerInstall -DestinationPath $destinationPath -BackupPath $backupPath -StagingPath $stagingPath
                $stagingPath = $null
                $backupPath = $null
            }
            catch {
                Write-CliBootstrapWarning ('no se pudo revertir la instalacion anterior: ' + $_.Exception.Message)
            }
        }
        # Una carpeta de staging propia puede sobrevivir a un fallo previo al
        # reemplazo (por ejemplo, si el destino dejo de ser movible). Se limpia
        # siempre por su prefijo con GUID completo; nunca se toca el destino.
        if ((-not [string]::IsNullOrWhiteSpace($stagingPath)) -and [System.IO.Directory]::Exists($stagingPath)) {
            try {
                Remove-CliBootstrapOwnedDirectory -Path $stagingPath
            }
            catch {
                Write-CliBootstrapWarning ('no se pudo limpiar la carpeta propia de trabajo ' + $stagingPath + '; se conserva en disco: ' + $_.Exception.Message)
            }
            $stagingPath = $null
        }
        Write-CliBootstrapError $errorText
        $exitCode = 1
    }
    finally {
        # Limpieza de la carpeta de descarga propia: solo si esta directamente
        # bajo la raiz temporal y conserva el prefijo con GUID completo.
        if ($tempWorkspaceOwned -and (-not [string]::IsNullOrWhiteSpace($tempWorkspace))) {
            try {
                $separator = [char[]]@([System.IO.Path]::DirectorySeparatorChar)
                $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $tempWorkspace)).TrimEnd($separator)
                $root = [System.IO.Path]::GetFullPath($tempRoot).TrimEnd($separator)
                $leaf = Split-Path -Leaf $tempWorkspace
                if (($parent -eq $root) -and $leaf.StartsWith($workspacePrefix) -and [System.IO.Directory]::Exists($tempWorkspace)) {
                    Remove-CliBootstrapOwnedDirectory -Path $tempWorkspace
                }
            }
            catch {
                Write-CliBootstrapWarning ('no se pudo limpiar la carpeta temporal ' + $tempWorkspace + '; se conserva en disco: ' + $_.Exception.Message)
            }
        }
        if ($null -eq $exitCode) { $exitCode = 1 }
        $global:LASTEXITCODE = [int]$exitCode
    }
} -Version $Version -NoAnimation:$NoAnimation -VersionSpecified (($null -ne $PSBoundParameters) -and $PSBoundParameters.ContainsKey('Version'))
