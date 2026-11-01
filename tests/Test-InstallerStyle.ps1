#requires -Version 5.1
<#
    Pruebas funcionales de la presentacion jade del instalador de MensorCAD.

    Solo se ejecutan en Windows con Windows PowerShell 5.1. Todas las costuras son
    locales: no piden UAC, no escriben en Program Files, no abren AutoCAD y no
    tocan la red. El host de la prueba se captura con 6>&1 y el error con
    [Console]::SetError; la sonda VT y el ancho de consola se sustituyen por
    valores controlados para que el resultado sea determinista.

    Que cubre: banner de cinco filas con separadores (MENSOR jade / CAD mint),
    encabezado compacto, badge con version estampada y estado desarrollo sin
    lecturas de archivos, respaldo sin VT, resultados con metadatos y accion final,
    titulos interactivos, actividad limitada al ancho, cierre con check solo
    para etapas exitosas, modo plano byte a byte, guia accionable cuando AutoCAD
    esta abierto, texto de ayuda sin cambios y la sonda VT original.

    Lo que estas pruebas NO demuestran: que el banner se vea bien en una terminal
    real. Eso exige prueba visual humana en Windows PowerShell 5.1 y en la
    consola clasica.

    Ejecucion:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-InstallerStyle.ps1
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

if (-not (Test-Path -LiteralPath $script:InstallerPath -PathType Leaf)) {
    Write-Host "ERROR: no se encontro el instalador en '$script:InstallerPath'." -ForegroundColor Red
    exit 1
}

# Carga el instalador sin ejecutar su flujo principal (guarda de dot-source).
. $script:InstallerPath

$script:Escape = [string][char]27
$script:ResetSequence = $script:Escape + '[0m'
$script:AnsiPattern = [regex]::Escape($script:Escape) + '\[[0-9;]*m'

# Estado controlado por caso. Las costuras reemplazan solo sondas de consola y
# funciones del motor que no deben ejecutarse de verdad aqui.
$script:StyleVirtualTerminal = $false
$script:StyleConsoleWidth = 120
$script:StyleOutputRedirected = $false
$script:StyleProgramFiles = ''
$script:StyleSourceError = ''
$script:VtProbeResult = $false
$script:ProbeLog = New-Object 'System.Collections.Generic.List[string]'
$script:FailingStage = ''

$script:SeamNames = @(
    'Test-MensorCadVirtualTerminal',
    'Get-MensorCadConsoleWidth',
    'Test-MensorCadOutputRedirected',
    'Test-MensorCadWindows',
    'Test-MensorCad64BitOperatingSystem',
    'Test-MensorCad64BitProcess',
    'Get-MensorCadProgramFilesRoot',
    'Test-MensorCadAdministrator',
    'Test-MensorCadAutoCadRunning',
    'Test-MensorCadSource'
)
$script:OriginalFunctions = @{}
foreach ($name in $script:SeamNames) {
    $item = Get-Item -LiteralPath ('Function:\' + $name) -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        $script:OriginalFunctions[$name] = $item.ScriptBlock
    }
}

function script:Test-MensorCadVirtualTerminal {
    param(
        [scriptblock]$RedirectProbe = { [Console]::IsOutputRedirected },
        [scriptblock]$HostProbe = { $Host.UI },
        [scriptblock]$ModeProbe = { Get-MensorCadConsoleModeFlags }
    )
    return [bool]$script:StyleVirtualTerminal
}

function script:Get-MensorCadConsoleWidth {
    param([scriptblock]$RawUIProbe = { $Host.UI.RawUI.WindowSize.Width })
    return [int]$script:StyleConsoleWidth
}

function script:Test-MensorCadOutputRedirected { return [bool]$script:StyleOutputRedirected }
function script:Test-MensorCadWindows { return $true }
function script:Test-MensorCad64BitOperatingSystem { return $true }
function script:Test-MensorCad64BitProcess { return $true }
function script:Get-MensorCadProgramFilesRoot { return [string]$script:StyleProgramFiles }
function script:Test-MensorCadAdministrator { return $true }
function script:Test-MensorCadAutoCadRunning { return $false }
function script:Test-MensorCadSource {
    param([string]$SourceRoot, [scriptblock]$ProgressCallback)
    if (-not [string]::IsNullOrWhiteSpace($script:StyleSourceError)) {
        throw $script:StyleSourceError
    }
    return [pscustomobject]@{ Entries = @(); ManifestSha256 = 'stub' }
}

function Restore-StyleSeams {
    foreach ($name in $script:SeamNames) {
        if ($script:OriginalFunctions.ContainsKey($name)) {
            Set-Item -Path ('Function:\script:' + $name) -Value $script:OriginalFunctions[$name] -Force
        }
        else {
            Remove-Item -Path ('Function:\script:' + $name) -ErrorAction SilentlyContinue
        }
    }
}

function Reset-StyleSeams {
    $script:StyleVirtualTerminal = $false
    $script:StyleConsoleWidth = 120
    $script:StyleOutputRedirected = $false
    $script:StyleProgramFiles = ''
    $script:StyleSourceError = ''
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
    Reset-StyleSeams
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
    finally {
        $script:MensorCadPlainMode = $false
        $script:MensorCadActivityLength = 0
        $script:MensorCadActivityStatic = $false
        $script:ProbeLog.Clear()
        $script:FailingStage = ''
        $script:MensorCadReleaseVersion = '__MENSORCAD_RELEASE_VERSION__'
    }
}

function Get-HostRecords {
    param([scriptblock]$Action)
    $records = @(& $Action 6>&1 | ForEach-Object { [string]$_ })
    return ,$records
}

function Invoke-CliCaptureAll {
    param([scriptblock]$Action)
    # Get-HostRecords usa un parametro llamado $Action: dentro del bloque
    # capturado esa referencia se resolveria al propio bloque por alcance
    # dinamico y se llamaria a si misma hasta desbordar la pila. La accion se
    # guarda con un nombre distinto antes de entrar en la captura.
    $cliAction = $Action
    $originalError = [Console]::Error
    $errorWriter = New-Object 'System.IO.StringWriter'
    $state = @{ ExitCode = 0 }
    try {
        [Console]::SetError($errorWriter)
        $records = Get-HostRecords {
            $state.ExitCode = & $cliAction
        }
    }
    finally {
        [Console]::SetError($originalError)
    }
    return [pscustomobject]@{
        ExitCode = [int]$state.ExitCode
        StdErr = [string]$errorWriter.ToString()
        HostText = (Join-HostRecords -Records $records)
    }
}

function Join-HostRecords {
    param([string[]]$Records)
    return ($Records -join '')
}

function Remove-StyleAnsi {
    param([string]$Text)
    return ($Text -replace $script:AnsiPattern, '')
}

function Get-VisibleActivityText {
    # Quita el retorno de carro y los escapes ANSI: lo que queda son las celdas
    # que ocupa la actividad en pantalla.
    param([string]$Record)
    $text = $Record
    if ($text.StartsWith([string][char]13)) {
        $text = $text.Substring(1)
    }
    return (Remove-StyleAnsi -Text $text)
}

function Invoke-OriginalVtProbe {
    # Ejecuta la implementacion original guardada antes de las costuras, con
    # sondas inyectadas y capturando cualquier salida inesperada del host.
    param(
        [scriptblock]$VirtualTerminal,
        [scriptblock]$RedirectProbe,
        [scriptblock]$HostProbe,
        [scriptblock]$ModeProbe
    )
    $script:VtProbeResult = $false
    $records = Get-HostRecords {
        $script:VtProbeResult = & $VirtualTerminal -RedirectProbe $RedirectProbe -HostProbe $HostProbe -ModeProbe $ModeProbe
    }
    return [pscustomobject]@{ Result = [bool]$script:VtProbeResult; Output = $records }
}

$script:JadeRows = @(
    '█   █ █████ █   █  ████  ███  ████   ',
    '██ ██ █     ██  █ █     █   █ █   █  ',
    '█ █ █ ████  █ █ █  ███  █   █ ████   ',
    '█   █ █     █  ██     █ █   █ █  █   ',
    '█   █ █████ █   █ ████   ███  █   █  '
)
$script:CadRows = @(
    ' ████  ███  ████ ',
    '█     █   █ █   █',
    '█     █████ █   █',
    '█     █   █ █   █',
    ' ████ █   █ ████ '
)

try {
    Test-Case 'El banner amplio pinta MENSOR en jade y CAD en mint con reinicio' {
        $script:MensorCadPlainMode = $false
        $script:StyleVirtualTerminal = $true
        $script:StyleConsoleWidth = 120
        $records = Get-HostRecords { Write-MensorCadBanner }
        $text = Join-HostRecords -Records $records
        for ($index = 0; $index -lt $script:JadeRows.Count; $index++) {
            Assert-True ($text.Contains($script:JadeRows[$index])) ('Falta la fila jade ' + $index + ' del banner.')
            Assert-True ($text.Contains($script:CadRows[$index])) ('Falta la fila mint ' + $index + ' del banner.')
        }
        Assert-True ($text.Contains('38;2;50;214;160')) 'MENSOR debe usar el jade del artboard.'
        Assert-True ($text.Contains('38;2;150;234;211')) 'CAD debe usar el menta del artboard.'
        Assert-True ($text.Contains('MENSORCAD / AUTOCAD')) 'El banner debe conservar la marca.'
        Assert-True (-not $text.Contains('Tu proximo plano')) 'La consigna debe haberse eliminado.'
        Assert-True ($text.Contains('Vamos a preparar tus herramientas para AutoCAD.')) 'Falta la introduccion breve.'
        Assert-True (-not $text.Contains('#')) 'Con VT no debe usarse el glifo ASCII.'
        Assert-Equal '' $records[$records.Count - 1] 'El banner debe cerrar con una separacion antes de las fases.'
        Assert-Equal '' $records[3] 'Debe haber una fila vacia entre el encabezado y los bloques.'
        Assert-Equal '' $records[14] 'Debe haber una fila vacia entre los bloques y la introduccion.'
        foreach ($record in $records) {
            $visible = Remove-StyleAnsi -Text $record
            Assert-True ($visible.Length -le 54) ('La linea visible no debe superar el banner: ' + $visible)
            if ($record.Contains($script:Escape)) {
                Assert-True ($record.EndsWith($script:ResetSequence)) 'Cada segmento ANSI debe cerrar con reinicio.'
            }
        }
    }

    Test-Case 'El banner compacto cubre consolas angostas y ancho desconocido' {
        $script:MensorCadPlainMode = $false
        $script:StyleVirtualTerminal = $true
        foreach ($width in @(50, 0)) {
            $script:StyleConsoleWidth = $width
            $text = Remove-StyleAnsi -Text (Join-HostRecords -Records (Get-HostRecords { Write-MensorCadBanner }))
            Assert-True ($text.Contains('MENSORCAD')) ("El compacto debe conservar la marca con ancho $width.")
            Assert-True ($text.Contains('Instalador para AutoCAD')) ("El compacto debe explicar el instalador con ancho $width.")
            Assert-True (-not $text.Contains([string][char]0x2588)) ("Sin ancho suficiente no debe dibujarse el banner de bloques ($width).")
            Assert-True (-not $text.Contains('Tu proximo plano')) 'El compacto no debe incluir la consigna eliminada.'
        }
    }

    Test-Case 'Sin VT el banner cae a ConsoleColor y al glifo ASCII' {
        $script:MensorCadPlainMode = $false
        $script:StyleVirtualTerminal = $false
        $script:StyleConsoleWidth = 120
        $text = Join-HostRecords -Records (Get-HostRecords { Write-MensorCadBanner })
        Assert-True ($text.Contains('#')) 'Sin VT debe usarse el glifo ASCII.'
        Assert-True (-not $text.Contains([string][char]0x2588)) 'Sin VT no debe depender del bloque Unicode.'
        Assert-True (-not $text.Contains($script:Escape)) 'Sin VT no debe emitirse ninguna secuencia ANSI.'
        Assert-True ($text.Contains('MENSORCAD / AUTOCAD')) 'La marca debe conservarse sin VT.'
    }

    Test-Case 'El modo plano conserva banner, fases, info y exito byte a byte' {
        $script:MensorCadPlainMode = $true
        $records = Get-HostRecords {
            Write-MensorCadBanner
            Write-MensorCadStep -Number 1 -Total 4 -Message 'Fase tecnica' -Hint 'pista solo con color'
            Write-MensorCadInfo 'Info tecnica'
            Write-MensorCadSuccess -Message 'MensorCAD se instalo correctamente.' -Headline 'Listo.' -Detail 'detalle amigable' -NextAction 'siguiente accion'
        }
        Assert-Equal (@(
            'MensorCAD - Instalador local para AutoCAD',
            '  [1/4] Fase tecnica',
            '  Info tecnica',
            'MensorCAD se instalo correctamente.'
        ) -join "`n") ($records -join "`n") 'El modo plano debe conservar el texto tecnico exacto.'
        $text = Join-HostRecords -Records $records
        foreach ($forbidden in ('pista solo con color', 'detalle amigable', 'siguiente accion', [string][char]0x2588, $script:Escape, [string][char]13)) {
            Assert-True (-not $text.Contains($forbidden)) ('El modo plano no debe incluir ' + $forbidden)
        }

        $originalError = [Console]::Error
        $writer = New-Object -TypeName 'System.IO.StringWriter'
        try {
            [Console]::SetError($writer)
            Write-MensorCadFailure -Message 'AutoCAD esta en ejecucion.' -Headline 'Cierra AutoCAD para continuar.' -Guidance 'Guarda tus dibujos.'
        }
        finally {
            [Console]::SetError($originalError)
        }
        Assert-Equal ('ERROR: AutoCAD esta en ejecucion.' + [Environment]::NewLine) $writer.ToString() 'stderr debe conservar el mensaje original.'
    }

    Test-Case 'Las fases muestran titulos amigables solo con color' {
        $script:MensorCadPlainMode = $true
        $plain = Get-HostRecords {
            Write-MensorCadStep -Number 1 -Total 4 -Message 'Mensaje tecnico' -Title 'Titulo amigable' -Hint 'pista solo con color'
        }
        Assert-Equal 1 $plain.Count 'El modo plano debe emitir una sola linea de fase.'
        Assert-Equal '  [1/4] Mensaje tecnico' $plain[0] 'El modo plano conserva el mensaje tecnico, no el titulo.'

        foreach ($virtualTerminal in @($false, $true)) {
            $script:MensorCadPlainMode = $false
            $script:StyleVirtualTerminal = $virtualTerminal
            $text = Remove-StyleAnsi -Text (Join-HostRecords -Records (Get-HostRecords {
                Write-MensorCadStep -Number 1 -Total 4 -Message 'Mensaje tecnico' -Title 'Titulo amigable' -Hint 'pista solo con color'
            }))
            Assert-True ($text.Contains('Titulo amigable')) 'Con color debe verse el titulo de la fase.'
            Assert-True (-not $text.Contains('Mensaje tecnico')) 'Con color no debe repetirse la etiqueta tecnica.'
            Assert-True ($text.Contains('pista solo con color')) 'La pista debe conservarse con color.'
        }
    }

    Test-Case 'Los resultados distinguen instalado, actualizado, ya actualizado y desinstalado' {
        $script:MensorCadPlainMode = $false
        $script:StyleVirtualTerminal = $false
        $finalAction = 'Todo listo. Abrí AutoCAD para empezar.'
        $cases = @(
            @{ Headline = 'MensorCAD está instalado.'; Message = 'MensorCAD se instalo correctamente en C:\PF.'; Metadata = 'Ubicación: C:\PF - Archivos: 4'; NextAction = $finalAction },
            @{ Headline = 'MensorCAD se actualizó.'; Message = 'MensorCAD se actualizo correctamente en C:\PF.'; Metadata = 'Ubicación: C:\PF - Archivos: 4'; NextAction = $finalAction },
            @{ Headline = 'MensorCAD ya estaba actualizado.'; Message = 'MensorCAD ya estaba actualizado en C:\PF.'; Metadata = 'Ubicación: C:\PF'; NextAction = $finalAction },
            @{ Headline = 'MensorCAD se desinstaló.'; Message = 'MensorCAD se desinstalo correctamente. Archivos eliminados: 3.'; Metadata = 'Archivos eliminados: 3'; NextAction = 'Puedes volver a instalar cuando quieras.' }
        )
        $seen = @()
        foreach ($case in $cases) {
            $records = Get-HostRecords {
                Write-MensorCadSuccess -Message $case.Message -Headline $case.Headline -Detail 'Detalle amigable.' -NextAction $case.NextAction -Metadata $case.Metadata
            }
            Assert-Equal '' $records[0] 'El resultado debe separarse del bloque de fases.'
            Assert-True ($records[1] -match '^  -+$') 'Debe aparecer una regla ASCII antes del resultado.'
            Assert-Equal '' $records[2] 'La regla debe separarse del titulo.'
            Assert-Equal '' $records[3] 'El titulo necesita padding respecto de la regla.'
            $text = Join-HostRecords -Records $records
            Assert-True ($text.Contains($case.Headline)) ('Falta el resultado ' + $case.Headline)
            Assert-True ($text.Contains($case.Metadata)) 'La ubicacion o el conteo debe verse como metadato separado.'
            Assert-True (-not $text.Contains($case.Message)) 'Con color no debe repetirse la frase tecnica completa.'
            Assert-True ($text.EndsWith($case.NextAction)) 'La accion final debe cerrar el resultado.'
            Assert-Equal 1 ([regex]::Matches($text, [regex]::Escape($case.NextAction))).Count 'La accion final debe aparecer una sola vez.'
            $seen += $case.Headline
            if ($case.Headline -eq 'MensorCAD se desinstaló.') {
                Assert-True (-not ($text -match 'MensorCAD se instalo|instalado correctamente')) 'Desinstalar no debe sugerir una instalacion.'
                Assert-True (-not $text.Contains('Abre AutoCAD')) 'Desinstalar no debe pedir abrir AutoCAD.'
            }
        }
        Assert-Equal 4 @($seen | Sort-Object -Unique).Count 'Cada estado debe tener un resultado distinto.'
    }

    Test-Case 'La regla del resultado se limita al ancho y tiene respaldo ASCII' {
        foreach ($virtualTerminal in @($false, $true)) {
            $script:MensorCadPlainMode = $false
            $script:StyleVirtualTerminal = $virtualTerminal
            $script:StyleConsoleWidth = 40
            $records = Get-HostRecords { Write-MensorCadResultRule }
            Assert-Equal 1 $records.Count 'La regla debe emitirse una sola vez.'
            $visible = Remove-StyleAnsi -Text $records[0]
            Assert-Equal 39 $visible.Length 'La regla debe caber con una columna de margen.'
            if ($virtualTerminal) {
                Assert-True ($records[0].Contains([string][char]0x2500)) 'Con VT la regla debe usar la linea Unicode.'
                Assert-True ($records[0].EndsWith($script:ResetSequence)) 'La regla ANSI debe cerrar con reinicio.'
            }
            else {
                Assert-True ($visible -match '^  -+$') 'Sin VT la regla debe ser ASCII.'
                Assert-True (-not $records[0].Contains($script:Escape)) 'Sin VT la regla no debe llevar ANSI.'
            }
        }
        foreach ($width in @(4, 0)) {
            $script:MensorCadPlainMode = $false
            $script:StyleVirtualTerminal = $false
            $script:StyleConsoleWidth = $width
            $records = Get-HostRecords { Write-MensorCadResultRule }
            Assert-Equal 0 $records.Count ('Con ancho ' + $width + ' no debe inventarse una regla.')
            Assert-Equal '' ($records -join '') ('Con ancho ' + $width + ' no debe quedar texto ni una regla.')
        }
        $script:MensorCadPlainMode = $true
        $records = Get-HostRecords { Write-MensorCadResultRule }
        Assert-Equal 0 $records.Count 'El modo plano no debe decorar el resultado.'
        Assert-Equal '' ($records -join '') 'El modo plano no debe dejar residuo de la regla.'
    }

    Test-Case 'La actividad limita texto y relleno al ancho actual (reducir y crecer)' {
        $longMessage = 'Copiando 1/3: un archivo con un nombre mucho mas largo que el ancho disponible'
        foreach ($virtualTerminal in @($false, $true)) {
            $script:MensorCadPlainMode = $false
            $script:StyleVirtualTerminal = $virtualTerminal
            $script:MensorCadSpinnerIndex = 0
            $script:MensorCadActivityLength = 0
            $script:MensorCadActivityStatic = $false

            $script:StyleConsoleWidth = 100
            $first = Get-HostRecords { Write-MensorCadActivity -Message $longMessage }
            Assert-Equal 1 $first.Count 'La actividad debe redibujarse una vez.'
            $firstVisible = Get-VisibleActivityText -Record $first[0]
            Assert-True ($firstVisible.Length -le 99) ('La actividad amplia debe caber: ' + $firstVisible)

            $script:StyleConsoleWidth = 40
            $shrunk = Get-HostRecords { Write-MensorCadActivity -Message $longMessage }
            $shrunkVisible = Get-VisibleActivityText -Record $shrunk[0]
            Assert-True ($shrunk[0].StartsWith([string][char]13)) 'La actividad dinamica empieza con retorno de carro.'
            Assert-True (-not $shrunk[0].Contains("`n")) 'La actividad nunca debe ocupar mas de una linea.'
            Assert-True ($shrunkVisible.Length -le 39) ('Al reducir, texto y relleno deben caber: ' + $shrunkVisible)
            Assert-True ($shrunkVisible.EndsWith('...')) 'El texto recortado debe terminar en puntos suspensivos.'

            $script:StyleConsoleWidth = 100
            $grown = Get-HostRecords { Write-MensorCadActivity -Message 'ok' }
            $grownVisible = Get-VisibleActivityText -Record $grown[0]
            Assert-True ($grownVisible.Length -le 99) 'Al crecer, la linea debe caber en el nuevo ancho.'
            Assert-True ($grownVisible.Length -gt 6) 'La linea anterior debe rellenarse con espacios.'
            Assert-True ($grownVisible.EndsWith(' ')) 'El relleno de limpieza son espacios finales.'

            if ($virtualTerminal) {
                Assert-True ($first[0].Contains($script:Escape)) 'Con VT la actividad debe llevar ANSI.'
                Assert-True ($first[0].EndsWith($script:ResetSequence)) 'La actividad ANSI debe cerrar con reinicio.'
            }
            else {
                Assert-True (-not $first[0].Contains($script:Escape)) 'Sin VT no debe emitirse ANSI.'
            }

            Complete-MensorCadActivity
            Assert-Equal 0 $script:MensorCadActivityLength 'Completar la actividad debe reiniciar el relleno.'
        }
    }

    Test-Case 'La actividad usa una linea estatica con ancho diminuto o desconocido' {
        foreach ($virtualTerminal in @($false, $true)) {
            foreach ($width in @(4, 1, 0)) {
                $script:MensorCadPlainMode = $false
                $script:StyleVirtualTerminal = $virtualTerminal
                $script:StyleConsoleWidth = $width
                $script:MensorCadSpinnerIndex = 0
                $script:MensorCadActivityLength = 0
                $script:MensorCadActivityStatic = $false

                $records = Get-HostRecords {
                    Write-MensorCadActivity -Message 'Copiando un archivo largo'
                    Write-MensorCadActivity -Message 'Otro aviso'
                }
                if ($width -le 1) {
                    Assert-Equal 0 $records.Count ('Con ancho ' + $width + ' no debe escribirse una linea que no cabe.')
                }
                else {
                    Assert-Equal 1 $records.Count ('Con ancho ' + $width + ' solo se emite una linea estatica.')
                    $visible = Get-VisibleActivityText -Record $records[0]
                    Assert-True (-not $records[0].StartsWith([string][char]13)) 'La linea estatica no debe usar retorno de carro.'
                    Assert-True ($visible.Length -le ($width - 1)) ('La linea estatica debe caber: ' + $visible)
                    if ($virtualTerminal) {
                        Assert-True ($records[0].Contains($script:Escape)) 'La linea estatica con VT debe llevar ANSI.'
                        Assert-True ($records[0].EndsWith($script:ResetSequence)) 'La linea estatica ANSI debe cerrar con reinicio.'
                    }
                    else {
                        Assert-True (-not $records[0].Contains($script:Escape)) 'La linea estatica sin VT no debe llevar ANSI.'
                    }
                }
                Complete-MensorCadActivity
            }
        }
    }

    Test-Case 'La sonda VT original respeta salidas tempranas y modos con costuras inyectadas' {
        $original = $script:OriginalFunctions['Test-MensorCadVirtualTerminal']
        Assert-True ($null -ne $original) 'La implementacion original de la sonda VT debe estar guardada.'

        $script:ProbeLog.Clear()
        $probe = Invoke-OriginalVtProbe -VirtualTerminal $original `
            -RedirectProbe { $null = $script:ProbeLog.Add('redirect'); return $true } `
            -HostProbe { $null = $script:ProbeLog.Add('host'); return [pscustomobject]@{} } `
            -ModeProbe { $null = $script:ProbeLog.Add('mode'); return [uint32]4 }
        Assert-Equal $false $probe.Result 'Con salida redirigida la sonda debe devolver false.'
        Assert-Equal 'redirect' ($script:ProbeLog -join ',') 'La salida redirigida debe cortar antes de tocar host o modo.'
        Assert-Equal 0 $probe.Output.Count 'La sonda no debe escribir en el host.'

        $script:ProbeLog.Clear()
        $probe = Invoke-OriginalVtProbe -VirtualTerminal $original `
            -RedirectProbe { $null = $script:ProbeLog.Add('redirect'); return $false } `
            -HostProbe { $null = $script:ProbeLog.Add('host'); return [pscustomobject]@{ SupportsVirtualTerminal = $false } } `
            -ModeProbe { $null = $script:ProbeLog.Add('mode'); return [uint32]4 }
        Assert-Equal $false $probe.Result 'Un host que niega VT debe devolver false.'
        Assert-Equal 'redirect,host' ($script:ProbeLog -join ',') 'La propiedad falsa debe cortar antes del modo nativo.'
        Assert-Equal 0 $probe.Output.Count 'La sonda no debe escribir en el host.'

        $script:ProbeLog.Clear()
        $probe = Invoke-OriginalVtProbe -VirtualTerminal $original `
            -RedirectProbe { $null = $script:ProbeLog.Add('redirect'); return $false } `
            -HostProbe { $null = $script:ProbeLog.Add('host'); return [pscustomobject]@{} } `
            -ModeProbe { $null = $script:ProbeLog.Add('mode'); return $null }
        Assert-Equal $false $probe.Result 'Sin modo legible la sonda debe devolver false.'
        Assert-Equal 'redirect,host,mode' ($script:ProbeLog -join ',') 'Sin propiedad de host se consulta el modo.'
        Assert-Equal 0 $probe.Output.Count 'La sonda no debe escribir en el host.'

        $script:ProbeLog.Clear()
        $probe = Invoke-OriginalVtProbe -VirtualTerminal $original `
            -RedirectProbe { $null = $script:ProbeLog.Add('redirect'); return $false } `
            -HostProbe { $null = $script:ProbeLog.Add('host'); return [pscustomobject]@{} } `
            -ModeProbe { $null = $script:ProbeLog.Add('mode'); return [uint32]4 }
        Assert-Equal $true $probe.Result 'El flag VT ya habilitado debe devolver true.'
        Assert-Equal 0 $probe.Output.Count 'La sonda no debe escribir en el host.'

        $script:ProbeLog.Clear()
        $probe = Invoke-OriginalVtProbe -VirtualTerminal $original `
            -RedirectProbe { $null = $script:ProbeLog.Add('redirect'); return $false } `
            -HostProbe { $null = $script:ProbeLog.Add('host'); return [pscustomobject]@{} } `
            -ModeProbe { $null = $script:ProbeLog.Add('mode'); return [uint32]0 }
        Assert-Equal $false $probe.Result 'Un modo sin el flag VT debe devolver false.'
        Assert-Equal 0 $probe.Output.Count 'La sonda no debe escribir en el host.'

        foreach ($failingStage in @('redirect', 'host', 'mode')) {
            $script:FailingStage = $failingStage
            $script:ProbeLog.Clear()
            $probe = Invoke-OriginalVtProbe -VirtualTerminal $original `
                -RedirectProbe { $null = $script:ProbeLog.Add('redirect'); if ($script:FailingStage -eq 'redirect') { throw 'fallo redirect' }; return $false } `
                -HostProbe { $null = $script:ProbeLog.Add('host'); if ($script:FailingStage -eq 'host') { throw 'fallo host' }; return [pscustomobject]@{} } `
                -ModeProbe { $null = $script:ProbeLog.Add('mode'); if ($script:FailingStage -eq 'mode') { throw 'fallo mode' }; return [uint32]4 }
            Assert-Equal $false $probe.Result ('Una excepcion en ' + $failingStage + ' debe devolver false.')
            Assert-Equal 0 $probe.Output.Count 'La sonda no debe escribir en el host.'
        }
        $script:FailingStage = ''
    }

    Test-Case 'El badge usa la version estampada sin leer archivos' {
        $previousVersion = $script:MensorCadReleaseVersion
        try {
            $script:MensorCadPlainMode = $false
            $script:StyleVirtualTerminal = $true
            $script:StyleConsoleWidth = 120
            $script:MensorCadReleaseVersion = '1.2.3'
            $text = Join-HostRecords -Records (Get-HostRecords { Write-MensorCadReleaseVersionBadge })
            Assert-True ($text.Contains('1.2.3')) 'El badge debe mostrar la version estampada.'
            Assert-True ($text.Contains('48;2;50;214;160')) 'El badge debe usar fondo jade verdadero.'
            Assert-True ($text.Contains($script:ResetSequence)) 'El badge debe reiniciar ANSI.'

            $script:MensorCadReleaseVersion = '__MENSORCAD_RELEASE_VERSION__'
            $development = Join-HostRecords -Records (Get-HostRecords { Write-MensorCadReleaseVersionBadge })
            Assert-True ($development.Contains('desarrollo')) 'La plantilla sin construir debe mostrar desarrollo.'
            Assert-True (-not $development.Contains('1.2.3')) 'La plantilla no debe inventar una version.'
        }
        finally {
            $script:MensorCadReleaseVersion = $previousVersion
        }
    }

    Test-Case 'El modo plano y el banner local no consultan archivos de version' {
        $previousVersion = $script:MensorCadReleaseVersion
        try {
            $script:MensorCadReleaseVersion = '1.2.3'
            $script:MensorCadPlainMode = $true
            $plainRecords = Get-HostRecords {
                Write-MensorCadBanner -ShowVersion
                Write-MensorCadReleaseVersionBadge
            }
            Assert-Equal 1 $plainRecords.Count 'El modo plano solo debe emitir el banner tecnico.'
            Assert-Equal 'MensorCAD - Instalador local para AutoCAD' $plainRecords[0] 'El banner plano debe conservarse intacto.'
            Assert-True (-not ((Join-HostRecords -Records $plainRecords).Contains('1.2.3'))) 'El modo plano no debe mostrar la version.'

            $script:MensorCadPlainMode = $false
            $script:StyleVirtualTerminal = $true
            $script:StyleConsoleWidth = 120
            $pretty = Join-HostRecords -Records (Get-HostRecords { Write-MensorCadBanner -ShowVersion })
            Assert-True ($pretty.Contains('1.2.3')) 'El banner local debe mostrar la version estampada.'
            Assert-True ($pretty.Contains('48;2;50;214;160')) 'El banner local debe mostrar el badge jade.'
            Assert-True ($pretty.Contains('Vamos a preparar tus herramientas para AutoCAD.')) 'La introduccion breve debe conservarse.'
            Assert-True (-not $pretty.Contains('Tu proximo plano')) 'La consigna eliminada no debe reaparecer.'
        }
        finally {
            $script:MensorCadReleaseVersion = $previousVersion
        }
    }

    Test-Case 'El badge de version usa jade, respaldo y etiqueta compacta' {
        $script:MensorCadPlainMode = $false
        $script:StyleVirtualTerminal = $true
        $script:StyleConsoleWidth = 120
        $text = Join-HostRecords -Records (Get-HostRecords { Write-MensorCadVersionBadge -Version '0.1.0' })
        Assert-True ($text.Contains('48;2;50;214;160')) 'El badge debe usar fondo jade verdadero.'
        Assert-True ($text.Contains('38;2;9;14;13')) 'El badge debe usar texto oscuro legible.'
        Assert-True ($text.Contains($script:ResetSequence)) 'El badge debe reiniciar ANSI.'
        Assert-True ($text.Contains('MensorCAD')) 'El badge debe nombrar el producto.'
        Assert-True ($text.Contains('0.1.0')) 'El badge debe mostrar la version real recibida.'

        $unavailable = Join-HostRecords -Records (Get-HostRecords { Write-MensorCadVersionBadge -Version $null })
        Assert-True ($unavailable.Contains('versión no disponible')) 'Sin version el badge debe ser honesto.'

        $script:StyleVirtualTerminal = $false
        $plainText = Join-HostRecords -Records (Get-HostRecords { Write-MensorCadVersionBadge -Version '0.1.0' })
        Assert-True (-not $plainText.Contains($script:Escape)) 'Sin VT el badge no debe emitir ANSI.'
        Assert-True ($plainText.Contains('MensorCAD 0.1.0')) 'Sin VT debe verse la etiqueta y la version.'

        foreach ($width in @(15, 0)) {
            $script:StyleConsoleWidth = $width
            $compact = Remove-StyleAnsi -Text (Join-HostRecords -Records (Get-HostRecords { Write-MensorCadVersionBadge -Version '0.1.0' }))
            Assert-True ($compact.Contains('MensorCAD')) ('El badge compacto debe conservar la marca con ancho ' + $width + '.')
            Assert-True (-not $compact.Contains('0.1.0')) ('El badge compacto no debe arriesgar el corte de la version con ancho ' + $width + '.')
        }
    }

    Test-Case 'El cierre exitoso reemplaza el indicador y el cierre neutral no pinta check' {
        foreach ($virtualTerminal in @($false, $true)) {
            $script:MensorCadPlainMode = $false
            $script:StyleVirtualTerminal = $virtualTerminal
            $script:StyleConsoleWidth = 40
            $script:MensorCadSpinnerIndex = 0
            $script:MensorCadActivityLength = 0
            $script:MensorCadActivityStatic = $false

            $null = Get-HostRecords { Write-MensorCadActivity -Message 'Verificando 1/3: archivo' }
            $completion = Get-HostRecords { Complete-MensorCadActivity -Success -Text 'Paquete validado' }
            Assert-True ($completion[0].StartsWith([string][char]13)) 'El cierre exitoso debe reescribir la linea activa.'
            Assert-True (-not $completion[0].Contains("`n")) 'El cierre no debe ocupar mas de una linea.'
            $visible = Get-VisibleActivityText -Record $completion[0]
            Assert-True ($visible.Length -le 39) ('El cierre debe caber en el ancho: ' + $visible)
            if ($virtualTerminal) {
                Assert-True ($visible.Contains('✓')) 'Con VT el cierre debe mostrar el check.'
                Assert-True ($completion[0].EndsWith($script:ResetSequence)) 'El check ANSI debe cerrar con reinicio.'
            }
            else {
                Assert-True ($visible.Contains('[OK]')) 'Sin VT el cierre debe usar el respaldo ASCII.'
                Assert-True (-not $completion[0].Contains($script:Escape)) 'Sin VT el cierre no debe llevar ANSI.'
            }
            Assert-Equal 0 $script:MensorCadActivityLength 'El cierre debe reiniciar el relleno.'

            $null = Get-HostRecords { Write-MensorCadActivity -Message 'ok' }
            $neutral = Get-HostRecords { Complete-MensorCadActivity }
            Assert-Equal 1 $neutral.Count 'El cierre neutral debe emitir solo el salto de linea.'
            Assert-Equal '' $neutral[0] 'El cierre neutral no debe inventar un check.'
        }

        $script:MensorCadPlainMode = $false
        $script:StyleVirtualTerminal = $false
        $script:StyleConsoleWidth = 4
        $script:MensorCadActivityLength = 0
        $tiny = Get-HostRecords { Complete-MensorCadActivity -Success -Text 'Paquete validado' }
        Assert-Equal 1 $tiny.Count 'Con ancho diminuto solo debe quedar el salto de linea.'
        Assert-Equal '' $tiny[0] 'Con ancho diminuto no debe dibujarse un check inseguro.'

        $script:MensorCadPlainMode = $true
        $plain = Get-HostRecords { Complete-MensorCadActivity -Success -Text 'Paquete validado' }
        Assert-Equal 0 $plain.Count 'El modo plano no debe emitir el check.'
    }

    Test-Case 'La espera remota nunca convierte un hijo fallido en check' {
        $script:MensorCadPlainMode = $false
        $script:StyleVirtualTerminal = $false
        $script:StyleConsoleWidth = 120
        $fake = [pscustomobject]@{ HasExited = $true; ExitCode = 1; Id = 4242 }
        $null = $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) }
        $records = Get-HostRecords {
            Wait-MensorCadRemoteChild -Process $fake -Message 'Instalando con el instalador incluido en el paquete' -IntervalMilliseconds 50
        }
        Assert-Equal 1 $records.Count 'La espera debe cerrar la actividad una sola vez.'
        Assert-Equal '' $records[0] 'La espera no debe agregar texto de exito.'
        Assert-True (-not ((Join-HostRecords -Records $records) -match '\[OK\]|✓')) 'Un hijo con codigo 1 no debe recibir check.'
    }

    Test-Case 'El fallo de AutoCAD conserva stderr, codigo 1 y agrega guia accionable' {
        $script:StyleProgramFiles = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('MCSTYLE-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:StyleSourceError = 'AutoCAD esta en ejecucion. Cierre AutoCAD y vuelva a ejecutar el instalador. No se cerro AutoCAD automaticamente.'
        $expected = 'ERROR: ' + $script:StyleSourceError + [Environment]::NewLine

        $script:MensorCadPlainMode = $false
        $plain = Invoke-CliCaptureAll { Invoke-MensorCadCli -NoAnimation }
        Assert-Equal 1 $plain.ExitCode 'En modo plano el fallo debe conservar el codigo 1.'
        Assert-Equal $expected $plain.StdErr 'En modo plano stderr debe ser exactamente el original.'
        Assert-True (-not $plain.HostText.Contains('Guarda tus dibujos')) 'En modo plano no debe agregarse la guia.'
        Assert-True ($plain.HostText.Contains('MensorCAD - Instalador local para AutoCAD')) 'El banner plano debe conservarse.'

        $script:StyleOutputRedirected = $false
        $script:StyleConsoleWidth = 120
        $pretty = Invoke-CliCaptureAll { Invoke-MensorCadCli }
        Assert-Equal 1 $pretty.ExitCode 'Con color el fallo tambien debe salir con codigo 1.'
        Assert-Equal $expected $pretty.StdErr 'Con color stderr debe conservar el detalle original.'
        Assert-True ($pretty.HostText.Contains('Cierra AutoCAD para continuar.')) 'Debe mostrarse el titulo accionable.'
        Assert-True ($pretty.HostText.Contains('vuelve a ejecutar Instalar.bat')) 'Debe indicarse como continuar sin implicar exito.'
    }

    Test-Case 'La ayuda conserva el mismo texto y solo cambia el color' {
        $script:MensorCadPlainMode = $true
        $plainRecords = Get-HostRecords { Write-MensorCadUsage }
        $script:MensorCadPlainMode = $false
        $script:StyleVirtualTerminal = $true
        $prettyRecords = Get-HostRecords { Write-MensorCadUsage }
        $stripped = @($prettyRecords | ForEach-Object { Remove-StyleAnsi -Text $_ })
        Assert-Equal ($plainRecords -join "`n") ($stripped -join "`n") 'La ayuda no debe cambiar su texto.'
        Assert-True ((Join-HostRecords -Records $prettyRecords).Contains($script:Escape)) 'Con VT el encabezado de ayuda debe tener color.'
        Assert-True ((Join-HostRecords -Records $plainRecords).Contains('Desinstalar.bat')) 'La ayuda debe conservar el acceso de desinstalacion.'
    }
}
finally {
    Restore-StyleSeams
    $script:MensorCadPlainMode = $false
    $script:MensorCadActivityLength = 0
    $script:MensorCadActivityStatic = $false
    for ($index = [Math]::Max(0, $script:FailureMessages.Count - 20); $index -lt $script:FailureMessages.Count; $index++) {
        Write-Host ('  - ' + $script:FailureMessages[$index]) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ('Resultado: {0} correctas, {1} fallidas, {2} omitidas.' -f $script:Passed, $script:Failed, $script:Skipped)

if ($script:Failed -gt 0) {
    exit 1
}
exit 0
