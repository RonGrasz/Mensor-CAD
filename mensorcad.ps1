#requires -Version 5.1
<#
    mensorcad - comando gestor persistente para MensorCAD.

    Uso:
      mensorcad                 Resumen del estado; no instala nada.
      mensorcad install | -i    Instala el complemento con la ultima release.
      mensorcad update          Actualiza sin bajar de version.
      mensorcad uninstall       Quita el complemento; conserva este comando.
      mensorcad status          Estado del complemento frente al gestor.
      mensorcad --help          Esta ayuda.
      mensorcad --version       Version del comando gestor.

    Paquete propio (sin publicar):
      mensorcad install -LocalZip <ruta>   Instala desde un ZIP local y su .sha256.
      mensorcad -i -LocalZip <ruta>        Alias de install.
      mensorcad update -LocalZip <ruta>    Actualiza desde un ZIP local.

    -LocalZip solo se admite en install, -i y update. El ZIP debe ser
    MensorCAD-Windows.zip y su .sha256 debe estar en la misma carpeta. La
    version disponible se lee del PackageContents.xml ya validado, nunca del
    nombre del archivo ni de la red. El SHA-256 prueba integridad, no autentica
    al publicador: usalo solo con paquetes que hayas construido vos.

    Este archivo es el unico que lleva la version del gestor. El motor de
    instalacion se carga de forma perezosa desde el archivo que vive junto a
    este comando. Las rutas de lectura no descargan, no piden UAC y no escriben.
    Cargar este archivo con dot-source solo define funciones: no ejecuta nada.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:MensorCadManagerVersion = '__MENSORCAD_MANAGER_VERSION__'
$script:MensorCadManagerScriptRoot = $PSScriptRoot
$script:MensorCadManagerDotSourced = ($MyInvocation.InvocationName -eq '.')
$script:MensorCadManagerEngineFileName = 'Install-MensorCAD.ps1'
$script:MensorCadManagerBundleManifestFileName = 'PackageContents.xml'
$script:MensorCadManagerExitFailure = 1
$script:MensorCadManagerExitUsage = 2

# ---------------------------------------------------------------------------
# Salida y version del gestor
# ---------------------------------------------------------------------------

function Write-MensorCadManagerLine {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
}

function Write-MensorCadManagerError {
    param([string]$Text)
    [Console]::Error.WriteLine('ERROR: ' + $Text)
}

function Get-MensorCadManagerVersionText {
    # El build reemplaza el marcador por una version estable. Sin sellar, la
    # interfaz muestra "desarrollo" y no inventa una version publicada.
    $value = [string]$script:MensorCadManagerVersion
    if ($value -match '^[0-9]+\.[0-9]+\.[0-9]+$') {
        return $value
    }
    return 'desarrollo'
}

function Write-MensorCadManagerVersion {
    Write-MensorCadManagerLine ('mensorcad ' + (Get-MensorCadManagerVersionText))
}

function Write-MensorCadManagerHelp {
    Write-MensorCadManagerLine 'MensorCAD CLI - comando gestor para Windows'
    Write-MensorCadManagerLine ''
    Write-MensorCadManagerLine 'Uso:'
    Write-MensorCadManagerLine '  mensorcad                  Muestra un resumen y no instala nada.'
    Write-MensorCadManagerLine '  mensorcad install         Instala el complemento con la ultima release.'
    Write-MensorCadManagerLine '  mensorcad -i              Alias de install.'
    Write-MensorCadManagerLine '  mensorcad update          Actualiza sin bajar de version.'
    Write-MensorCadManagerLine '  mensorcad uninstall       Quita el complemento y conserva este comando.'
    Write-MensorCadManagerLine '  mensorcad status          Muestra el estado sin usar la red.'
    Write-MensorCadManagerLine '  mensorcad --help          Muestra esta ayuda.'
    Write-MensorCadManagerLine '  mensorcad --version       Muestra la version del comando gestor.'
    Write-MensorCadManagerLine '  mensorcad install -LocalZip <ruta>   Instala desde un ZIP local y su .sha256.'
    Write-MensorCadManagerLine '  mensorcad update -LocalZip <ruta>    Actualiza desde un ZIP local.'
    Write-MensorCadManagerLine ''
    Write-MensorCadManagerLine 'Comportamiento:'
    Write-MensorCadManagerLine '  install y update delegan en el motor validado que vive junto al comando.'
    Write-MensorCadManagerLine '  -LocalZip solo se admite en install, -i y update; no consulta GitHub.'
    Write-MensorCadManagerLine '  El .sha256 del ZIP local prueba integridad, no autentica al publicador.'
    Write-MensorCadManagerLine '  uninstall usa el motor protegido guardado dentro del complemento.'
    Write-MensorCadManagerLine '  status, --help y --version no descargan, no piden UAC y no escriben.'
    Write-MensorCadManagerLine '  El gestor se instala por usuario; el complemento se instala por equipo.'
}

# ---------------------------------------------------------------------------
# Entrada publica: argv crudo, sin parametros que fallen antes de tiempo
# ---------------------------------------------------------------------------

function Get-MensorCadManagerSuggestion {
    param([string]$Value)
    $map = @{
        'unistall' = 'uninstall'
        'uninstal' = 'uninstall'
        'instal' = 'install'
        'updat' = 'update'
        'stat' = 'status'
        'help' = '--help'
    }
    $key = ([string]$Value).ToLowerInvariant()
    if ($map.ContainsKey($key)) { return $map[$key] }
    return $null
}

function Get-MensorCadManagerLocalZipOption {
    # Unica gramatica local: '-LocalZip <ruta>' una sola vez. Cualquier otro
    # extra conserva el rechazo generico de argumentos adicionales, de modo que
    # los comandos hermanos no ganan sintaxis nueva.
    param([string[]]$Extras)
    $items = @($Extras)
    $path = $null
    $index = 0
    while ($index -lt $items.Count) {
        $token = [string]$items[$index]
        if ($token -ine '-LocalZip') {
            $extra = ($items -join ' ')
            return [pscustomobject]@{
                Path = $null
                Error = ('Argumentos adicionales no admitidos: ''' + $extra + '''. No se modificó nada.')
            }
        }
        if ($null -ne $path) {
            return [pscustomobject]@{
                Path = $null
                Error = 'La opción -LocalZip no se puede repetir. No se modificó nada.'
            }
        }
        if ($index + 1 -ge $items.Count) {
            return [pscustomobject]@{
                Path = $null
                Error = 'La opción -LocalZip requiere una ruta de paquete. No se modificó nada.'
            }
        }
        $value = [string]$items[$index + 1]
        if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('-')) {
            return [pscustomobject]@{
                Path = $null
                Error = ('La opción -LocalZip requiere una ruta de paquete y se encontró ''' + $value + '''. No se modificó nada.')
            }
        }
        $path = $value
        $index += 2
    }
    return [pscustomobject]@{ Path = $path; Error = $null }
}

function Get-MensorCadManagerCommand {
    param([string[]]$Arguments)
    $items = @($Arguments)
    if ($items.Count -eq 0) {
        return [pscustomobject]@{ Name = 'summary'; Error = $null; LocalZip = $null }
    }
    $first = [string]$items[0]
    $name = $null
    if ($first -ieq 'install' -or $first -ieq '-i') { $name = 'install' }
    elseif ($first -ieq 'update') { $name = 'update' }
    elseif ($first -ieq 'uninstall') { $name = 'uninstall' }
    elseif ($first -ieq 'status') { $name = 'status' }
    elseif ($first -ieq '--help') { $name = 'help' }
    elseif ($first -ieq '--version') { $name = 'version' }
    else {
        $suggestion = Get-MensorCadManagerSuggestion -Value $first
        if ([string]::IsNullOrWhiteSpace($first)) {
            $message = 'No se indicó ningún comando. No se modificó nada.'
        }
        elseif ($first.StartsWith('-')) {
            $message = ('Opción no reconocida: ''' + $first + '''. No se modificó nada.')
        }
        elseif ($null -ne $suggestion) {
            $message = ('Comando no reconocido: ''' + $first + '''. ¿Quisiste decir ''' + $suggestion + '''? No se modificó nada.')
        }
        else {
            $message = ('Comando no reconocido: ''' + $first + '''. No se modificó nada.')
        }
        return [pscustomobject]@{ Name = 'usage'; Error = $message; LocalZip = $null }
    }
    $localZip = $null
    if ($items.Count -gt 1) {
        $extras = @($items[1..($items.Count - 1)])
        if ($name -eq 'install' -or $name -eq 'update') {
            $localOption = Get-MensorCadManagerLocalZipOption -Extras $extras
            if ($null -ne $localOption.Error) {
                return [pscustomobject]@{ Name = 'usage'; Error = $localOption.Error; LocalZip = $null }
            }
            $localZip = $localOption.Path
        }
        else {
            $extra = $extras -join ' '
            return [pscustomobject]@{
                Name = 'usage'
                Error = ('Argumentos adicionales no admitidos: ''' + $extra + '''. No se modificó nada.')
                LocalZip = $null
            }
        }
    }
    return [pscustomobject]@{ Name = $name; Error = $null; LocalZip = $localZip }
}

# ---------------------------------------------------------------------------
# Motor adyacente y estado instalado (solo lectura, sin duplicar validaciones)
# ---------------------------------------------------------------------------

function Get-MensorCadManagerEnginePath {
    $path = Join-Path -Path $script:MensorCadManagerScriptRoot -ChildPath $script:MensorCadManagerEngineFileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ('No se encontró el motor "' + $script:MensorCadManagerEngineFileName + '" junto a mensorcad.ps1. Reinstalá el comando gestor.')
    }
    return $path
}

function Get-MensorCadManagerInstalledVersion {
    # La marca de instalacion no guarda version: la version publica del
    # complemento vive en PackageContents.xml. Se prefiere AppVersion y se cae
    # a Version sin interpretar ni escribir nada.
    param([string]$DestinationRoot)
    $manifestPath = Join-Path -Path $DestinationRoot -ChildPath $script:MensorCadManagerBundleManifestFileName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
    $document = New-Object -TypeName 'System.Xml.XmlDocument'
    $document.XmlResolver = $null
    try {
        $document.Load($manifestPath)
    }
    catch {
        # Un manifiesto ilegible no debe impedir una desinstalacion local: la
        # propiedad ya la valido el motor con la marca. Para status se informa
        # "desconocida" y para install/update se rechaza por ambiguedad.
        return $null
    }
    $root = $document.DocumentElement
    if ($null -eq $root) { return $null }
    foreach ($attributeName in @('AppVersion', 'Version')) {
        $value = [string]$root.GetAttribute($attributeName)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return $null
}

function Get-MensorCadManagerInstalledState {
    # Assert-MensorCadOwnedDestination valida marca (Read-MensorCadMarker),
    # inventario y puntos de reanalisis; devolver $null significa que no hay
    # complemento instalado. No se reparsea la marca aqui.
    $destinationRoot = Get-MensorCadDestinationRoot
    $marker = Assert-MensorCadOwnedDestination -DestinationRoot $destinationRoot
    if ($null -eq $marker) { return $null }
    $version = Get-MensorCadManagerInstalledVersion -DestinationRoot $destinationRoot
    return [pscustomobject]@{
        DestinationRoot = $destinationRoot
        Version = $version
        InstalledAtUtc = [string]$marker.InstalledAtUtc
    }
}

function Get-MensorCadManagerVersionLabel {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'desconocida' }
    # Se reutiliza el saneador del motor: la version se muestra, nunca se
    # interpreta. Un valor con caracteres de control se informa como desconocido.
    $display = Get-MensorCadDisplayVersion -Value $Value
    if ([string]::IsNullOrWhiteSpace($display)) { return 'desconocida' }
    return $display
}

function Write-MensorCadManagerState {
    param([switch]$IncludeCommands)
    Write-MensorCadManagerLine ('MensorCAD CLI ' + (Get-MensorCadManagerVersionText))
    $state = Get-MensorCadManagerInstalledState
    if ($null -eq $state) {
        Write-MensorCadManagerLine 'Complemento: no instalado'
        Write-MensorCadManagerLine 'Sugerencia: ejecutá "mensorcad install" para instalarlo.'
    }
    else {
        Write-MensorCadManagerLine 'Complemento: instalado'
        Write-MensorCadManagerLine ('Versión instalada: ' + (Get-MensorCadManagerVersionLabel -Value $state.Version))
        Write-MensorCadManagerLine ('Ubicación: ' + $state.DestinationRoot)
        if (-not [string]::IsNullOrWhiteSpace($state.InstalledAtUtc)) {
            Write-MensorCadManagerLine ('Instalado: ' + $state.InstalledAtUtc)
        }
    }
    if ($IncludeCommands) {
        Write-MensorCadManagerLine 'Comandos: install, -i, update, uninstall, status, --help, --version'
        Write-MensorCadManagerLine 'Este resumen no instala nada, no usa la red y no pide permisos de administrador.'
    }
    return $state
}

# ---------------------------------------------------------------------------
# Comparacion conservadora de versiones estables
# ---------------------------------------------------------------------------

function ConvertTo-MensorCadManagerVersion {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    if ($text -notmatch '^[vV]?([0-9]+(\.[0-9]+)*)$') { return $null }
    $numbers = New-Object 'System.Collections.Generic.List[long]'
    foreach ($part in $Matches[1].Split('.')) {
        $parsed = [long]0
        if (-not [long]::TryParse($part, [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            return $null
        }
        $numbers.Add($parsed)
    }
    while ($numbers.Count -gt 1 -and $numbers[$numbers.Count - 1] -eq 0) {
        $numbers.RemoveAt($numbers.Count - 1)
    }
    return ,$numbers.ToArray()
}

function Compare-MensorCadManagerVersion {
    # Devuelve negativo si la instalada es anterior a la disponible, 0 si son
    # iguales, positivo si la instalada es posterior (downgrade) y $null cuando
    # la comparacion no es posible. La ambiguedad nunca se resuelve adivinando.
    param([string]$Installed, [string]$Available)
    $left = ConvertTo-MensorCadManagerVersion -Value $Installed
    $right = ConvertTo-MensorCadManagerVersion -Value $Available
    if ($null -eq $left -or $null -eq $right) { return $null }
    $count = [Math]::Max($left.Count, $right.Count)
    for ($index = 0; $index -lt $count; $index++) {
        $a = [long]0
        if ($index -lt $left.Count) { $a = [long]$left[$index] }
        $b = [long]0
        if ($index -lt $right.Count) { $b = [long]$right[$index] }
        if ($a -lt $b) { return -1 }
        if ($a -gt $b) { return 1 }
    }
    return 0
}

function Write-MensorCadManagerAmbiguity {
    param([string]$Installed, [string]$Tag)
    Write-MensorCadManagerError ('No se pudo comparar la versión instalada "' + (Get-MensorCadManagerVersionLabel -Value $Installed) + '" con la disponible "' + $Tag + '". Por seguridad no se modificó nada; ejecutá "mensorcad uninstall" y después "mensorcad install".')
}

function Write-MensorCadManagerDowngrade {
    param([string]$Installed, [string]$Tag)
    Write-MensorCadManagerError ('La versión disponible ' + $Tag + ' es anterior a la instalada ' + (Get-MensorCadManagerVersionLabel -Value $Installed) + '. No se baja de versión automáticamente. No se modificó nada.')
}

function Write-MensorCadManagerUpToDate {
    param([string]$Version)
    Write-MensorCadManagerLine 'Ya estás actualizado'
    Write-MensorCadManagerLine ('Complemento: versión ' + (Get-MensorCadManagerVersionLabel -Value $Version) + ' (sin cambios).')
}

# ---------------------------------------------------------------------------
# Rutas publicas
# ---------------------------------------------------------------------------

function Invoke-MensorCadManagerLocalInstall {
    # Paquete propio elegido por la persona: el motor copia el ZIP y su .sha256 a
    # una carpeta temporal propia, valida, extrae y devuelve la version real del
    # PackageContents.xml. El gestor decide con las mismas reglas de version y
    # solo entonces ejecuta el instalador incluido. Ninguna validacion se
    # duplica aqui y el gestor nunca se eleva a si mismo. El .sha256 prueba
    # integridad, no autentica al publicador: la confianza esta en el ZIP propio.
    param([string]$LocalZip, [string]$Operation)
    if (-not (Get-Command -Name 'Open-MensorCadLocalPackage' -ErrorAction SilentlyContinue)) {
        Write-MensorCadManagerError 'El motor que está junto al gestor no admite -LocalZip. Volvé a registrar el comando gestor con el ZIP actual del release. No se modificó nada.'
        return $script:MensorCadManagerExitFailure
    }
    $state = Get-MensorCadManagerInstalledState
    if ($Operation -eq 'update' -and $null -eq $state) {
        Write-MensorCadManagerError 'MensorCAD no está instalado. Ejecutá "mensorcad install" para instalarlo. No se modificó nada.'
        return $script:MensorCadManagerExitFailure
    }
    $package = $null
    try {
        $package = Open-MensorCadLocalPackage -ArchivePath $LocalZip
        $available = [string]$package.Version
        if ($null -ne $state) {
            $comparison = Compare-MensorCadManagerVersion -Installed $state.Version -Available $available
            if ($null -eq $comparison) {
                Write-MensorCadManagerAmbiguity -Installed $state.Version -Tag $available
                return $script:MensorCadManagerExitFailure
            }
            if ($comparison -eq 0) {
                Write-MensorCadManagerUpToDate -Version $state.Version
                return 0
            }
            if ($comparison -gt 0) {
                Write-MensorCadManagerDowngrade -Installed $state.Version -Tag $available
                return $script:MensorCadManagerExitFailure
            }
        }
        $result = Install-MensorCadLocalPackage -Package $package
        if ($null -eq $result) { return $script:MensorCadManagerExitFailure }
        return [int]$result
    }
    finally {
        if ($null -ne $package) { Remove-MensorCadLocalPackage -Package $package }
    }
}

function Invoke-MensorCadManagerInstall {
    param([string]$LocalZip)
    if (-not [string]::IsNullOrWhiteSpace($LocalZip)) {
        return (Invoke-MensorCadManagerLocalInstall -LocalZip $LocalZip -Operation 'install')
    }
    $state = Get-MensorCadManagerInstalledState
    $tag = Resolve-MensorCadReleaseTag
    if ($null -ne $state) {
        $comparison = Compare-MensorCadManagerVersion -Installed $state.Version -Available $tag
        if ($null -eq $comparison) {
            Write-MensorCadManagerAmbiguity -Installed $state.Version -Tag $tag
            return $script:MensorCadManagerExitFailure
        }
        if ($comparison -eq 0) {
            Write-MensorCadManagerUpToDate -Version $state.Version
            return 0
        }
        if ($comparison -gt 0) {
            Write-MensorCadManagerDowngrade -Installed $state.Version -Tag $tag
            return $script:MensorCadManagerExitFailure
        }
    }
    $result = Invoke-MensorCadCli -FromRelease -Version $tag
    if ($null -eq $result) { return $script:MensorCadManagerExitFailure }
    return [int]$result
}

function Invoke-MensorCadManagerUpdate {
    # Sin complemento se falla antes de tocar la red o el paquete elegido y se
    # sugiere install.
    param([string]$LocalZip)
    if (-not [string]::IsNullOrWhiteSpace($LocalZip)) {
        return (Invoke-MensorCadManagerLocalInstall -LocalZip $LocalZip -Operation 'update')
    }
    $state = Get-MensorCadManagerInstalledState
    if ($null -eq $state) {
        Write-MensorCadManagerError 'MensorCAD no está instalado. Ejecutá "mensorcad install" para instalarlo. No se modificó nada.'
        return $script:MensorCadManagerExitFailure
    }
    $tag = Resolve-MensorCadReleaseTag
    $comparison = Compare-MensorCadManagerVersion -Installed $state.Version -Available $tag
    if ($null -eq $comparison) {
        Write-MensorCadManagerAmbiguity -Installed $state.Version -Tag $tag
        return $script:MensorCadManagerExitFailure
    }
    if ($comparison -eq 0) {
        Write-MensorCadManagerUpToDate -Version $state.Version
        return 0
    }
    if ($comparison -gt 0) {
        Write-MensorCadManagerDowngrade -Installed $state.Version -Tag $tag
        return $script:MensorCadManagerExitFailure
    }
    $result = Invoke-MensorCadCli -FromRelease -Version $tag
    if ($null -eq $result) { return $script:MensorCadManagerExitFailure }
    return [int]$result
}

function Invoke-MensorCadManagerUninstall {
    # La desinstalacion es sin conexion: valida propiedad y reparse, y despues
    # ejecuta el motor protegido que forma parte del propio complemento. El
    # gestor nunca se eleva ni usa el motor cacheado que tiene al lado.
    $state = Get-MensorCadManagerInstalledState
    if ($null -eq $state) {
        Write-MensorCadManagerLine 'MensorCAD no está instalado. No hay nada que desinstalar.'
        return 0
    }
    $protectedEnginePath = Join-Path -Path $state.DestinationRoot -ChildPath $script:MensorCadManagerEngineFileName
    if (-not (Test-Path -LiteralPath $protectedEnginePath -PathType Leaf)) {
        Write-MensorCadManagerError ('Esta instalación no incluye el motor de desinstalación "' + $script:MensorCadManagerEngineFileName + '". Para quitarla, descargá el ZIP de la release desde GitHub y ejecutá "Desinstalar.bat" (o "' + $script:MensorCadManagerEngineFileName + ' -Uninstall") desde esa carpeta. El gestor no descarga nada por su cuenta. No se modificó nada.')
        return $script:MensorCadManagerExitFailure
    }
    if (Test-MensorCadReparsePoint -Path $protectedEnginePath) {
        Write-MensorCadManagerError ('El motor de desinstalación "' + $protectedEnginePath + '" es un punto de reanálisis y se rechazó. No se modificó nada.')
        return $script:MensorCadManagerExitFailure
    }
    # Se ejecuta el archivo protegido con su propia entrada -Uninstall, igual
    # que lo haria una persona desde esa carpeta. El motor decide su elevacion
    # UAC y devuelve el codigo real; el gestor nunca se eleva a si mismo. El
    # centinela evita que un codigo viejo pase por resultado de esta ejecucion.
    $global:LASTEXITCODE = $null
    $null = & $protectedEnginePath -Uninstall
    if ($null -eq $LASTEXITCODE) {
        Write-MensorCadManagerError 'El motor de desinstalación no devolvió un código de salida. No se da la desinstalación por hecha.'
        return $script:MensorCadManagerExitFailure
    }
    return [int]$LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Despacho
# ---------------------------------------------------------------------------

# La guarda se evalua antes de cualquier trabajo: cargar el archivo para
# pruebas aisladas no debe ejecutar la CLI ni terminar el proceso llamador.
if ($script:MensorCadManagerDotSourced) { return }

# Salida redirigida: siempre UTF-8. Un log o una tuberia no pueden depender de la
# pagina de codigos de la consola que los captura, y los acentos de los mensajes
# se conservan igual en Windows, en CI y en cualquier otra terminal. Sin
# redireccion no se toca nada: la terminal del usuario conserva su codificacion.
if ([Console]::IsOutputRedirected) {
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    }
    catch {
        # Sin consola propia el cambio no aplica: se conserva la salida actual.
    }
}

$managerCommand = Get-MensorCadManagerCommand -Arguments $args
$managerExitCode = 0
if ($null -ne $managerCommand.Error) {
    Write-MensorCadManagerError -Text $managerCommand.Error
    $managerExitCode = $script:MensorCadManagerExitUsage
}
else {
    try {
        $engineRoutes = @('summary', 'status', 'install', 'update', 'uninstall')
        if ($engineRoutes -contains $managerCommand.Name) {
            $enginePath = Get-MensorCadManagerEnginePath
            . $enginePath
        }
        switch ($managerCommand.Name) {
            'help' { Write-MensorCadManagerHelp }
            'version' { Write-MensorCadManagerVersion }
            'summary' { $null = Write-MensorCadManagerState -IncludeCommands }
            'status' { $null = Write-MensorCadManagerState }
            'install' { $managerExitCode = Invoke-MensorCadManagerInstall -LocalZip $managerCommand.LocalZip }
            'update' { $managerExitCode = Invoke-MensorCadManagerUpdate -LocalZip $managerCommand.LocalZip }
            'uninstall' { $managerExitCode = Invoke-MensorCadManagerUninstall }
            default { throw ('Comando no soportado: ' + $managerCommand.Name) }
        }
    }
    catch {
        Write-MensorCadManagerError -Text $_.Exception.Message
        $managerExitCode = $script:MensorCadManagerExitFailure
    }
}
exit $managerExitCode
