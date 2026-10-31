#requires -Version 5.1
<#
    Pruebas funcionales del instalador local de MensorCAD.

    Estas pruebas SOLO se ejecutan en Windows con Windows PowerShell 5.1.
    Usan exclusivamente destinos temporales aislados; nunca escriben en
    Program Files ni modifican AutoCAD.

    Ejecucion:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Installer.ps1
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
$script:InstallerPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Install-MensorCAD.ps1'
$script:BatPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Instalar.bat'
$script:TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('MensorCadInstallerTests-' + [guid]::NewGuid().ToString('N'))

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

function Assert-Throws {
    param([scriptblock]$Action, [string]$Contains, [string]$Message)
    $caught = $null
    try {
        $null = & $Action
    }
    catch {
        $caught = $_.Exception.Message
    }
    Assert-True ($null -ne $caught) ($Message + ': se esperaba un error y no ocurrio.')
    if (-not [string]::IsNullOrWhiteSpace($Contains)) {
        Assert-True ($caught.IndexOf($Contains, [StringComparison]::OrdinalIgnoreCase) -ge 0) ($Message + ": el error no contiene '$Contains'. Mensaje: $caught")
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
    param([string]$RootPath, [string]$Version = 'v1')
    $sourceRoot = Join-Path -Path $RootPath -ChildPath 'dist'
    $bundleRoot = Join-Path -Path $sourceRoot -ChildPath 'MensorCAD.bundle'
    $null = New-Item -ItemType Directory -Path $bundleRoot -Force

    Write-FixtureFile -Path (Join-Path $bundleRoot 'PackageContents.xml') -Content ('<ApplicationPackage Name="MensorCAD" Version="' + $Version + '" />')
    Write-FixtureFile -Path (Join-Path $bundleRoot 'Contents\Lisp\MC-AREA.lsp') -Content ('; MC-AREA fixture ' + $Version + "`r`n")
    Write-FixtureFile -Path (Join-Path $bundleRoot 'Contents\Lisp\MC-TABLE.lsp') -Content ('; MC-TABLE fixture ' + $Version + "`r`n")
    Write-FixtureFile -Path (Join-Path $bundleRoot 'Contents\UI\MensorCAD.cuix') -Content ('CUIX-FIXTURE-' + $Version)

    Write-FixtureManifest -SourceRoot $sourceRoot
    return $sourceRoot
}

function Get-PayloadInventory {
    param([string]$BundleRoot)
    $map = @{}
    if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) { return $map }
    $baseFull = [System.IO.Path]::GetFullPath($BundleRoot)
    $files = Get-ChildItem -LiteralPath $baseFull -Recurse -File -Force
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($baseFull.Length + 1).Replace('\', '/')
        if ($relative -ieq $script:MensorCadMarkerFileName) { continue }
        $map[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $map
}

function Assert-InventoryEqual {
    param([hashtable]$Expected, [hashtable]$Actual, [string]$Message)
    Assert-Equal $Expected.Count $Actual.Count ($Message + ': cantidad de archivos')
    foreach ($key in $Expected.Keys) {
        Assert-True ($Actual.ContainsKey($key)) ($Message + ": falta el archivo '$key'.")
        Assert-Equal $Expected[$key] $Actual[$key] ($Message + ": hash inesperado para '$key'.")
    }
}

function Get-TransactionLeftovers {
    param([string]$ParentPath)
    if (-not (Test-Path -LiteralPath $ParentPath)) { return @() }
    return @(Get-ChildItem -LiteralPath $ParentPath -Force -Directory | Where-Object { $_.Name -like '.mensorcad-tx-*' })
}

function Invoke-EngineInstall {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [scriptblock]$PhaseHook,
        [scriptblock]$AutoCadProbe = { $false }
    )
    return Install-MensorCadBundle -SourceRoot $SourceRoot -DestinationRoot $DestinationRoot -TrustedBoundary $script:TestRoot -AutoCadProbe $AutoCadProbe -PhaseHook $PhaseHook
}

function Invoke-EngineUninstall {
    param(
        [string]$DestinationRoot,
        [scriptblock]$AutoCadProbe = { $false }
    )
    return Uninstall-MensorCadBundle -DestinationRoot $DestinationRoot -TrustedBoundary $script:TestRoot -AutoCadProbe $AutoCadProbe
}

function Get-FixtureDestination {
    param([string]$RootPath)
    return Join-Path -Path $RootPath -ChildPath 'ProgramFilesLike\Autodesk\ApplicationPlugins\MensorCAD.bundle'
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

function Invoke-BatCommand {
    param([string]$BatPath, [string[]]$Arguments = @())
    # Windows PowerShell 5.1 con $ErrorActionPreference = 'Stop' convierte el
    # stderr de un comando nativo en un error terminante (NativeCommandError)
    # cuando los flujos se fusionan en la tuberia de PowerShell. Un fallo
    # esperado del instalador abortaria la prueba antes de poder comprobar su
    # codigo de salida, asi que cada flujo se captura en su propio archivo,
    # igual que Invoke-ChildInstaller.
    # cmd.exe /c con una ruta entre comillas exige el patron ""ruta" args" para
    # que no se pierdan las comillas internas.
    $commandShell = $env:ComSpec
    if ([string]::IsNullOrWhiteSpace($commandShell)) {
        $commandShell = 'cmd.exe'
    }
    $commandLine = '/c ""' + $BatPath + '"'
    if ($Arguments.Count -gt 0) {
        $commandLine += ' ' + ($Arguments -join ' ')
    }
    $commandLine += '"'
    $stdoutPath = Join-Path -Path $script:TestRoot -ChildPath ('bat-stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrPath = Join-Path -Path $script:TestRoot -ChildPath ('bat-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    $process = Start-Process -FilePath $commandShell -ArgumentList $commandLine -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
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

try {
    Test-Case 'Dot-source no ejecuta el flujo principal y expone el motor' {
        Assert-True $script:MensorCadDotSourced 'El instalador no detecto que fue cargado con dot-source.'
        $before = @(Get-ChildItem -LiteralPath $script:TestRoot -Force).Count
        . $script:InstallerPath
        $after = @(Get-ChildItem -LiteralPath $script:TestRoot -Force).Count
        Assert-Equal $before $after 'Cargar el instalador con dot-source no debe crear archivos.'
        foreach ($name in @('Test-MensorCadSource', 'Install-MensorCadBundle', 'Uninstall-MensorCadBundle', 'Read-MensorCadManifest', 'Assert-MensorCadOwnedDestination', 'Read-MensorCadMarker', 'Write-MensorCadMarker')) {
            Assert-True ($null -ne (Get-Command -Name $name -ErrorAction SilentlyContinue)) ("No se expuso la funcion interna '$name'.")
        }
    }

    Test-Case 'La deteccion de plataforma identifica Windows' {
        Assert-True (Test-MensorCadWindows) 'Test-MensorCadWindows debe devolver verdadero en Windows.'
    }

    Test-Case 'Ayuda publica sale con codigo 0 y muestra el uso' {
        $root = New-TestCaseRoot
        try {
            $scriptCopy = Copy-InstallerTo -RootPath $root
            $result = Invoke-ChildInstaller -ScriptPath $scriptCopy -Arguments @('-Help')
            Assert-Equal 0 $result.ExitCode 'La ayuda debe salir con codigo 0.'
            Assert-True ($result.Stdout -match 'Uso:') 'La ayuda debe mostrar la seccion Uso:.'
            Assert-True ($result.Stdout -match 'MensorCAD') 'La ayuda debe mencionar MensorCAD.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case '-NoAnimation conserva el comportamiento de la ayuda' {
        $root = New-TestCaseRoot
        try {
            $scriptCopy = Copy-InstallerTo -RootPath $root
            $result = Invoke-ChildInstaller -ScriptPath $scriptCopy -Arguments @('-NoAnimation', '-Help')
            Assert-Equal 0 $result.ExitCode '-NoAnimation con -Help debe salir con codigo 0.'
            Assert-True ($result.Stdout -match 'Uso:') 'La ayuda sin animacion debe mostrar Uso:.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Falta el paquete local: error publico en stderr y codigo 1 sin UAC' {
        $root = New-TestCaseRoot
        try {
            $scriptCopy = Copy-InstallerTo -RootPath $root
            $result = Invoke-ChildInstaller -ScriptPath $scriptCopy -Arguments @('-NoAnimation')
            Assert-Equal 1 $result.ExitCode 'Un paquete local ausente debe salir con codigo 1.'
            Assert-True ($result.Stderr -match 'bundle\.sha256|paquete') 'stderr debe explicar que falta el manifiesto o el paquete.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'MensorCAD.bundle'))) 'La validacion fallida no debe crear el bundle.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath $root).Count 'La validacion fallida no debe dejar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'El BAT reenvia opciones y conserva el codigo de salida' {
        $root = New-TestCaseRoot
        $previousNoPause = $env:MENSORCAD_NO_PAUSE
        try {
            $env:MENSORCAD_NO_PAUSE = '1'
            $null = Copy-InstallerTo -RootPath $root
            $batCopy = Join-Path -Path $root -ChildPath 'Instalar.bat'
            Copy-Item -LiteralPath $script:BatPath -Destination $batCopy -Force

            $help = Invoke-BatCommand -BatPath $batCopy -Arguments @('-Help')
            Assert-Equal 0 $help.ExitCode 'El BAT debe conservar el codigo 0 de -Help.'
            Assert-True ($help.Stdout -match 'Uso:') 'El BAT debe reenviar -Help al instalador.'
            Assert-Equal '' ($help.Stderr.Trim()) 'La ayuda del BAT no debe escribir en stderr.'

            $failure = Invoke-BatCommand -BatPath $batCopy -Arguments @('-NoAnimation')
            Assert-Equal 1 $failure.ExitCode 'El BAT debe conservar el codigo 1 de un fallo.'
            Assert-True ($failure.Stderr -match 'ERROR|bundle') 'El BAT no debe ocultar el mensaje de fallo en stderr.'
            Assert-True ($failure.Stdout -match 'codigo 1') 'El BAT debe informar el codigo de salida del instalador.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'MensorCAD.bundle'))) 'Un fallo del BAT no debe crear el bundle.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath $root).Count 'Un fallo del BAT no debe dejar transacciones.'
        }
        finally {
            if ($null -eq $previousNoPause) {
                Remove-Item Env:MENSORCAD_NO_PAUSE -ErrorAction SilentlyContinue
            }
            else {
                $env:MENSORCAD_NO_PAUSE = $previousNoPause
            }
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'La entrada publica instala y desinstala en un destino aislado sin UAC real' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $programFiles = Join-Path $root 'ProgramFilesLike'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $script:MensorCadScriptRoot = $source
            $script:MensorCadTestProgramFiles = $programFiles
            function script:Get-MensorCadProgramFilesRoot { return $script:MensorCadTestProgramFiles }
            function script:Test-MensorCadAdministrator { return $true }
            function script:Test-MensorCadAutoCadRunning { return $false }
            function script:Test-MensorCad64BitOperatingSystem { return $true }
            function script:Test-MensorCad64BitProcess { return $true }

            $resolvedDestination = Get-MensorCadDestinationRoot
            $testRootFull = [System.IO.Path]::GetFullPath($script:TestRoot)
            Assert-True ($resolvedDestination.StartsWith($testRootFull, [StringComparison]::OrdinalIgnoreCase)) 'La prueba debe usar un destino aislado bajo la carpeta temporal.'
            Assert-Equal ([System.IO.Path]::GetFullPath($source)) ([System.IO.Path]::GetFullPath($script:MensorCadScriptRoot)) 'La prueba debe usar la raiz de origen del fixture.'

            $installExit = Invoke-MensorCadCli -NoAnimation 6>$null
            Assert-Equal 0 $installExit 'La entrada publica debe salir con codigo 0 tras instalar.'

            $destination = Join-Path $programFiles 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
            $markerPath = Join-Path $destination '.mensorcad-install.json'
            Assert-True (Test-Path -LiteralPath $markerPath -PathType Leaf) 'La entrada publica debe crear la marca de instalacion.'
            $oldMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            $oldPayloadHash = (Get-FileHash -LiteralPath (Join-Path $destination 'Contents\Lisp\MC-AREA.lsp') -Algorithm SHA256).Hash.ToLowerInvariant()

            # Regresion L1: segunda pasada por la entrada publica (instalacion -> actualizacion).
            Write-FixtureFile -Path (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp') -Content '; MC-AREA fixture v2 publica'
            Write-FixtureManifest -SourceRoot $source
            $updateExit = Invoke-MensorCadCli -NoAnimation 6>$null
            Assert-Equal 0 $updateExit 'La entrada publica debe salir con codigo 0 tras actualizar.'
            $newPayloadHash = (Get-FileHash -LiteralPath (Join-Path $destination 'Contents\Lisp\MC-AREA.lsp') -Algorithm SHA256).Hash.ToLowerInvariant()
            $sourcePayloadHash = (Get-FileHash -LiteralPath (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp') -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-Equal $sourcePayloadHash $newPayloadHash 'La entrada publica debe instalar el payload actualizado.'
            Assert-True ($newPayloadHash -ne $oldPayloadHash) 'La actualizacion publica debe cambiar el hash instalado.'
            $newMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            Assert-True ([string]$newMarker.sourceManifestSha256 -ne [string]$oldMarker.sourceManifestSha256) 'La actualizacion publica debe actualizar sourceManifestSha256.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'La actualizacion publica no debe dejar transacciones.'

            $uninstallExit = Invoke-MensorCadCli -NoAnimation -Uninstall 6>$null
            Assert-Equal 0 $uninstallExit 'La entrada publica debe salir con codigo 0 tras desinstalar.'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'La entrada publica de desinstalacion debe eliminar el bundle.'
        }
        finally {
            # Restaura las funciones y variables originales del instalador.
            . $script:InstallerPath
            Remove-Variable -Name MensorCadTestProgramFiles -Scope Script -ErrorAction SilentlyContinue
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Instalacion inicial escribe archivos exactos y marca valida' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $result = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            Assert-Equal 'installed' $result.Status 'La primera instalacion debe informar installed.'

            $expected = Get-PayloadInventory -BundleRoot (Join-Path $source 'MensorCAD.bundle')
            $actual = Get-PayloadInventory -BundleRoot $destination
            Assert-InventoryEqual -Expected $expected -Actual $actual -Message 'inventario instalado'

            $markerPath = Join-Path $destination '.mensorcad-install.json'
            Assert-True (Test-Path -LiteralPath $markerPath -PathType Leaf) 'Debe existir la marca de instalacion.'
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            Assert-Equal 'mensorcad-bundle-marker' ([string]$marker.format) 'format de la marca'
            Assert-Equal 1 ([int]$marker.formatVersion) 'formatVersion de la marca'
            Assert-Equal 'MensorCAD' ([string]$marker.product) 'product de la marca'
            $markerFiles = @($marker.files)
            Assert-Equal $expected.Count $markerFiles.Count 'cantidad de archivos en la marca'
            foreach ($entry in $markerFiles) {
                $relative = [string]$entry.path
                Assert-True ($actual.ContainsKey($relative)) ("La marca registra un archivo inexistente: '$relative'.")
                Assert-Equal $actual[$relative] ([string]$entry.sha256) ("hash de la marca para '$relative'.")
            }
            $manifestHash = (Get-FileHash -LiteralPath (Join-Path $source 'bundle.sha256') -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-Equal $manifestHash ([string]$marker.sourceManifestSha256) 'sourceManifestSha256 de la marca'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'La instalacion no debe dejar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Actualizacion reemplaza el payload y actualiza la marca' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $oldMarker = Get-Content -LiteralPath (Join-Path $destination '.mensorcad-install.json') -Raw | ConvertFrom-Json
            $oldInventory = Get-PayloadInventory -BundleRoot $destination

            Write-FixtureFile -Path (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp') -Content "; MC-AREA fixture v2`r`n"
            Write-FixtureManifest -SourceRoot $source

            $result = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            Assert-Equal 'updated' $result.Status 'Una reinstalacion con cambios debe informar updated.'

            $expected = Get-PayloadInventory -BundleRoot (Join-Path $source 'MensorCAD.bundle')
            $actual = Get-PayloadInventory -BundleRoot $destination
            Assert-InventoryEqual -Expected $expected -Actual $actual -Message 'inventario actualizado'
            Assert-True ($actual['Contents/Lisp/MC-AREA.lsp'] -ne $oldInventory['Contents/Lisp/MC-AREA.lsp']) 'El archivo actualizado debe tener un hash distinto.'
            $newMarker = Get-Content -LiteralPath (Join-Path $destination '.mensorcad-install.json') -Raw | ConvertFrom-Json
            Assert-True ([string]$newMarker.sourceManifestSha256 -ne [string]$oldMarker.sourceManifestSha256) 'La marca debe registrar el nuevo manifiesto.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'La actualizacion no debe dejar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Reinstalar el mismo payload informa unchanged sin reescribir' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $markerPath = Join-Path $destination '.mensorcad-install.json'
            $firstMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json

            $result = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            Assert-Equal 'unchanged' $result.Status 'Un payload identico debe informar unchanged.'
            $secondMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            Assert-Equal ([string]$firstMarker.installedAtUtc) ([string]$secondMarker.installedAtUtc) 'unchanged no debe reescribir la marca.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Desinstalacion elimina solo el bundle propio' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $parent = Split-Path -Parent $destination
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $unrelatedPath = Join-Path $parent 'no-tocar.txt'
            Write-FixtureFile -Path $unrelatedPath -Content 'contenido ajeno'

            $result = Invoke-EngineUninstall -DestinationRoot $destination
            Assert-Equal 'uninstalled' $result.Status 'La desinstalacion debe informar uninstalled.'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'El bundle desinstalado no debe existir.'
            Assert-True (Test-Path -LiteralPath $unrelatedPath -PathType Leaf) 'La desinstalacion no debe tocar archivos ajenos.'
            Assert-Equal 'contenido ajeno' ([System.IO.File]::ReadAllText($unrelatedPath)) 'El archivo ajeno debe conservar su contenido.'
            Assert-True (Test-Path -LiteralPath $parent -PathType Container) 'La desinstalacion no debe borrar el directorio padre.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza un hash de origen incorrecto sin escribir el destino' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            Write-FixtureFile -Path (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp') -Content 'contenido alterado'
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'hash' -Message 'Un origen alterado debe rechazarse'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'Un origen invalido no debe crear el destino.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'Un origen invalido no debe dejar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza una ruta con salto de directorio en bundle.sha256' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $manifestPath = Join-Path $source 'bundle.sha256'
            $line = (('0' * 64) + '  ../escape.txt')
            [System.IO.File]::AppendAllText($manifestPath, $line + "`r`n")
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'segmento' -Message 'Un salto de directorio debe rechazarse'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'escape.txt'))) 'No debe escribirse ningun archivo fuera del paquete.'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'Un manifiesto invalido no debe crear el destino.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza un inventario duplicado' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $manifestPath = Join-Path $source 'bundle.sha256'
            $firstLine = ([System.IO.File]::ReadAllLines($manifestPath))[0]
            [System.IO.File]::AppendAllText($manifestPath, $firstLine + "`r`n")
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'duplicada' -Message 'Un inventario duplicado debe rechazarse'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'Un inventario duplicado no debe crear el destino.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza archivos del bundle no declarados' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            Write-FixtureFile -Path (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\EXTRA.lsp') -Content '; archivo no declarado'
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'no declarado' -Message 'Un archivo extra debe rechazarse'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'Un paquete con extras no debe instalar nada.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza un archivo declarado ausente' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            Remove-Item -LiteralPath (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-TABLE.lsp') -Force
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'Falta el archivo' -Message 'Un archivo ausente debe rechazarse'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'Un paquete incompleto no debe instalar nada.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza puntos de reanalisis dentro del origen' {
        $root = New-TestCaseRoot
        $outsideRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('MensorCadOutside-' + [guid]::NewGuid().ToString('N'))
        $linkPath = $null
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = New-Item -ItemType Directory -Path $outsideRoot -Force
            $outside = Join-Path $outsideRoot 'fuera.txt'
            Write-FixtureFile -Path $outside -Content 'fuera del bundle'
            $linkPath = Join-Path $source 'MensorCAD.bundle\Contents\Lisp\enlace.lsp'
            $created = $false
            try {
                $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $outside -ErrorAction Stop
                $created = $true
            }
            catch {
                try {
                    $null = New-Item -ItemType Junction -Path $linkPath -Target $outsideRoot -ErrorAction Stop
                    $created = $true
                }
                catch {
                    $created = $false
                }
            }
            if (-not $created) {
                Skip-Case 'El entorno no permite crear enlaces simbolicos ni junctions para probar reparse points.'
                return
            }
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'reanalisis' -Message 'Un punto de reanalisis debe rechazarse'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'Un origen con reparse points no debe instalar nada.'
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace($linkPath) -and (Test-Path -LiteralPath $linkPath)) {
                Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $outsideRoot) {
                Remove-Item -LiteralPath $outsideRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza un host de 32 bits antes de UAC y sin escribir' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $programFiles = Join-Path $root 'ProgramFilesLike'
            $null = New-Item -ItemType Directory -Path $programFiles -Force
            $script:MensorCadScriptRoot = $source
            $script:MensorCadTestProgramFiles = $programFiles
            function script:Get-MensorCadProgramFilesRoot { return $script:MensorCadTestProgramFiles }
            function script:Test-MensorCadAdministrator { return $true }
            function script:Test-MensorCadAutoCadRunning { return $false }

            # WOW64: Windows de 64 bits con PowerShell de 32 bits.
            function script:Test-MensorCad64BitOperatingSystem { return $true }
            function script:Test-MensorCad64BitProcess { return $false }
            $expectedArchitectureError = 'MensorCAD requiere Windows de 64 bits y PowerShell de 64 bits. Ejecute Instalar.bat o el powershell.exe nativo de 64 bits. No se escribio ningun archivo.'
            $architectureMessage = $null
            try {
                Assert-MensorCad64BitHost
            }
            catch {
                $architectureMessage = $_.Exception.Message
            }
            Assert-Equal $expectedArchitectureError $architectureMessage 'WOW64 debe fallar con el mensaje exacto de arquitectura'
            $exitWow64 = Invoke-MensorCadCli -NoAnimation 6>$null
            Assert-Equal 1 $exitWow64 'La entrada publica debe salir con codigo 1 en WOW64.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $programFiles 'Autodesk'))) 'WOW64 no debe crear el destino.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force).Count 'WOW64 no debe escribir en Program Files.'

            # Windows de 32 bits.
            function script:Test-MensorCad64BitOperatingSystem { return $false }
            function script:Test-MensorCad64BitProcess { return $false }
            $architectureMessage32 = $null
            try {
                Assert-MensorCad64BitHost
            }
            catch {
                $architectureMessage32 = $_.Exception.Message
            }
            Assert-Equal $expectedArchitectureError $architectureMessage32 'Windows de 32 bits debe fallar con el mensaje exacto'
            $exit32 = Invoke-MensorCadCli -NoAnimation 6>$null
            Assert-Equal 1 $exit32 'La entrada publica debe salir con codigo 1 en Windows de 32 bits.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $programFiles 'Autodesk'))) 'Windows de 32 bits no debe crear el destino.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $programFiles -Force).Count 'Windows de 32 bits no debe escribir en Program Files.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath $programFiles).Count 'El rechazo por arquitectura no debe dejar transacciones.'
        }
        finally {
            . $script:InstallerPath
            Remove-Variable -Name MensorCadTestProgramFiles -Scope Script -ErrorAction SilentlyContinue
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza un destino bajo un padre con punto de reanalisis' {
        $root = New-TestCaseRoot
        $outsideRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('MensorCadOutside-' + [guid]::NewGuid().ToString('N'))
        $linkPath = Join-Path $root 'ProgramFilesLike'
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $null = New-Item -ItemType Directory -Path $outsideRoot -Force
            $created = $false
            try {
                $null = New-Item -ItemType Junction -Path $linkPath -Target $outsideRoot -ErrorAction Stop
                $created = $true
            }
            catch {
                $created = $false
            }
            if (-not $created) {
                Skip-Case 'El entorno no permite crear una junction para probar el padre del destino.'
                return
            }
            $destination = Join-Path $linkPath 'Autodesk\ApplicationPlugins\MensorCAD.bundle'
            Assert-Throws -Action { Install-MensorCadBundle -SourceRoot $source -DestinationRoot $destination -TrustedBoundary $script:TestRoot -AutoCadProbe { $false } } -Contains 'reanalisis' -Message 'Un padre con reparse point debe rechazarse'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $outsideRoot 'Autodesk'))) 'No debe escribirse nada a traves del junction.'
        }
        finally {
            if (Test-Path -LiteralPath $linkPath) {
                Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $outsideRoot) {
                Remove-Item -LiteralPath $outsideRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza un destino existente no propio y lo deja intacto' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = New-Item -ItemType Directory -Path $destination -Force
            $keepPath = Join-Path $destination 'ajeno.txt'
            Write-FixtureFile -Path $keepPath -Content 'no tocar'
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'no pertenece' -Message 'Un destino ajeno debe rechazarse'
            Assert-Equal 'no tocar' ([System.IO.File]::ReadAllText($keepPath)) 'El destino ajeno debe quedar intacto.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json'))) 'No debe crearse una marca en un destino ajeno.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'Un destino ajeno no debe generar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza actualizar si la instalacion tiene archivos no reconocidos' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $extraPath = Join-Path $destination 'Contents\Lisp\AGREGADO.lsp'
            Write-FixtureFile -Path $extraPath -Content '; agregado por el usuario'
            Write-FixtureFile -Path (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp') -Content '; v2'
            Write-FixtureManifest -SourceRoot $source
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'no reconocidos' -Message 'Un agregado no reconocido debe bloquear la actualizacion'
            Assert-True (Test-Path -LiteralPath $extraPath -PathType Leaf) 'El archivo no reconocido debe conservarse.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'La actualizacion bloqueada no debe dejar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza actualizar si la instalacion fue modificada' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            [System.IO.File]::AppendAllText((Join-Path $destination 'Contents\Lisp\MC-AREA.lsp'), "`r`n; modificado")
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination } -Contains 'modificada' -Message 'Una instalacion modificada debe rechazarse'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination 'Contents\Lisp\MC-AREA.lsp')) 'No debe eliminarse la instalacion modificada.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rollback restaura la version anterior si falla despues del respaldo' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $oldInventory = Get-PayloadInventory -BundleRoot $destination

            Write-FixtureFile -Path (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp') -Content '; v2'
            Write-FixtureManifest -SourceRoot $source
            $hook = { param($phase) if ($phase -eq 'AfterBackup') { throw 'fallo simulado despues del respaldo' } }
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination -PhaseHook $hook } -Contains 'fallo simulado' -Message 'El fallo inyectado debe propagarse'

            $restored = Get-PayloadInventory -BundleRoot $destination
            Assert-InventoryEqual -Expected $oldInventory -Actual $restored -Message 'rollback'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json') -PathType Leaf) 'El rollback debe restaurar la marca anterior.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'El rollback no debe dejar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rollback restaura la version anterior si falla despues del intercambio' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $oldInventory = Get-PayloadInventory -BundleRoot $destination

            Write-FixtureFile -Path (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp') -Content '; v2'
            Write-FixtureManifest -SourceRoot $source
            $hook = { param($phase) if ($phase -eq 'AfterSwap') { throw 'fallo simulado despues del intercambio' } }
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination -PhaseHook $hook } -Contains 'fallo simulado' -Message 'El fallo posterior al intercambio debe propagarse'

            $restored = Get-PayloadInventory -BundleRoot $destination
            Assert-InventoryEqual -Expected $oldInventory -Actual $restored -Message 'rollback posterior al intercambio'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json') -PathType Leaf) 'El rollback posterior al intercambio debe restaurar la marca anterior.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'El rollback posterior al intercambio no debe dejar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Revalida el origen despues de la etapa temporal' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $oldInventory = Get-PayloadInventory -BundleRoot $destination
            $sourceLisp = Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp'
            Write-FixtureFile -Path $sourceLisp -Content '; v2'
            Write-FixtureManifest -SourceRoot $source
            $hook = { param($phase) if ($phase -eq 'AfterStage') { [System.IO.File]::AppendAllText($sourceLisp, "`r`n; cambiado durante la instalacion") } }.GetNewClosure()
            Assert-Throws -Action { Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination -PhaseHook $hook } -Contains 'hash' -Message 'La revalidacion posterior a la etapa debe detectar el cambio'

            $current = Get-PayloadInventory -BundleRoot $destination
            Assert-InventoryEqual -Expected $oldInventory -Actual $current -Message 'destino tras revalidacion fallida'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'La revalidacion fallida no debe dejar transacciones.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Rechaza deriva autoconsistente del origen despues de la etapa' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $oldInventory = Get-PayloadInventory -BundleRoot $destination
            $markerPath = Join-Path $destination '.mensorcad-install.json'
            $oldMarkerText = [System.IO.File]::ReadAllText($markerPath)
            $sourceLisp = Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp'

            Write-FixtureFile -Path $sourceLisp -Content '; payload B antes de iniciar'
            Write-FixtureManifest -SourceRoot $source
            # La etapa copia el payload B; despues de la etapa el origen cambia a C
            # y se regenera el manifiesto, de modo que C es autoconsistente.
            $hook = {
                param($phase)
                if ($phase -eq 'AfterStage') {
                    [System.IO.File]::AppendAllText($sourceLisp, "`r`n; deriva autoconsistente despues de la etapa")
                    Write-FixtureManifest -SourceRoot $source
                }
            }.GetNewClosure()
            $driftMessage = $null
            try {
                $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination -PhaseHook $hook
            }
            catch {
                $driftMessage = $_.Exception.Message
            }
            Assert-Equal 'El inventario del paquete local cambio durante la instalacion. No se modifico el destino.' $driftMessage 'La deriva autoconsistente debe fallar con el mensaje exacto'

            $currentInventory = Get-PayloadInventory -BundleRoot $destination
            Assert-InventoryEqual -Expected $oldInventory -Actual $currentInventory -Message 'destino tras deriva autoconsistente'
            Assert-Equal $oldMarkerText ([System.IO.File]::ReadAllText($markerPath)) 'La marca instalada no debe cambiar tras la deriva.'
            Assert-Equal 0 @(Get-TransactionLeftovers -ParentPath (Split-Path -Parent $destination)).Count 'La deriva no debe dejar etapa ni respaldo abandonados.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'AutoCAD en ejecucion bloquea la instalacion antes de escribir' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            Assert-Throws -Action { Install-MensorCadBundle -SourceRoot $source -DestinationRoot $destination -TrustedBoundary $script:TestRoot -AutoCadProbe { $true } } -Contains 'AutoCAD' -Message 'AutoCAD abierto debe bloquear la instalacion'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'AutoCAD abierto no debe permitir escrituras.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'AutoCAD en ejecucion bloquea la actualizacion sin tocar la version instalada' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            $oldInventory = Get-PayloadInventory -BundleRoot $destination
            Assert-Throws -Action { Install-MensorCadBundle -SourceRoot $source -DestinationRoot $destination -TrustedBoundary $script:TestRoot -AutoCadProbe { $true } } -Contains 'AutoCAD' -Message 'AutoCAD abierto debe bloquear incluso el caso sin cambios'
            Write-FixtureFile -Path (Join-Path $source 'MensorCAD.bundle\Contents\Lisp\MC-AREA.lsp') -Content '; v2'
            Write-FixtureManifest -SourceRoot $source
            Assert-Throws -Action { Install-MensorCadBundle -SourceRoot $source -DestinationRoot $destination -TrustedBoundary $script:TestRoot -AutoCadProbe { $true } } -Contains 'AutoCAD' -Message 'AutoCAD abierto debe bloquear la actualizacion'
            $current = Get-PayloadInventory -BundleRoot $destination
            Assert-InventoryEqual -Expected $oldInventory -Actual $current -Message 'destino bloqueado por AutoCAD'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'AutoCAD en ejecucion bloquea la desinstalacion' {
        $root = New-TestCaseRoot
        try {
            $source = New-FixtureSource -RootPath $root -Version 'v1'
            $destination = Get-FixtureDestination -RootPath $root
            $null = Invoke-EngineInstall -SourceRoot $source -DestinationRoot $destination
            Assert-Throws -Action { Invoke-EngineUninstall -DestinationRoot $destination -AutoCadProbe { $true } } -Contains 'AutoCAD' -Message 'AutoCAD abierto debe bloquear la desinstalacion'
            Assert-True (Test-Path -LiteralPath (Join-Path $destination '.mensorcad-install.json') -PathType Leaf) 'La desinstalacion bloqueada no debe borrar nada.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Desinstalacion rechaza un destino no propio y lo deja intacto' {
        $root = New-TestCaseRoot
        try {
            $destination = Get-FixtureDestination -RootPath $root
            $null = New-Item -ItemType Directory -Path $destination -Force
            $keepPath = Join-Path $destination 'ajeno.txt'
            Write-FixtureFile -Path $keepPath -Content 'no tocar'
            Assert-Throws -Action { Invoke-EngineUninstall -DestinationRoot $destination } -Contains 'no pertenece' -Message 'La desinstalacion de un destino ajeno debe rechazarse'
            Assert-Equal 'no tocar' ([System.IO.File]::ReadAllText($keepPath)) 'El destino ajeno debe quedar intacto.'
        }
        finally {
            Remove-TestCaseRoot -Path $root
        }
    }

    Test-Case 'Desinstalacion de una ruta inexistente falla con mensaje claro' {
        $root = New-TestCaseRoot
        try {
            $destination = Get-FixtureDestination -RootPath $root
            Assert-Throws -Action { Invoke-EngineUninstall -DestinationRoot $destination } -Contains 'no esta instalado' -Message 'Desinstalar sin instalacion debe fallar'
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
