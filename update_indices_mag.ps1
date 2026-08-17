<#
  Actualiza la sección "Índices MAG" de index.html con los valores publicados en
  https://www.grupoguarino.com.ar/mercado-vision/ (Mercadovisión / Grupo Guarino).

  Pensado para correr sin supervisión (Programador de tareas de Windows, martes/
  miércoles/viernes). No falla nunca "a medias": si el fetch o el parseo no
  encuentran EXACTAMENTE los 3 índices esperados, no toca index.html y solo
  deja constancia en update_log.txt.
#>

$ErrorActionPreference = 'Stop'
$root      = $PSScriptRoot
$htmlPath  = Join-Path $root 'index.html'
$logPath   = Join-Path $root 'update_log.txt'
$sourceUrl = 'https://www.grupoguarino.com.ar/mercado-vision/'

function Write-Log($msg) {
    # El log es solo para diagnóstico -- un bloqueo transitorio del archivo (antivirus,
    # indexador de Windows, OneDrive) nunca debe impedir que se actualicen los índices.
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
                $writer.WriteLine($line)
                $writer.Flush()
            } finally {
                $stream.Dispose()
            }
            return
        } catch {
            Start-Sleep -Milliseconds 400
        }
    }
}

function Format-ArNumber([string]$raw) {
    # "4.317,719" (miles con punto, decimales con coma) -> "4.317,72" (2 decimales, mismo formato)
    $normalized = $raw.Trim() -replace '\.', '' -replace ',', '.'
    $val = [double]::Parse($normalized, [System.Globalization.CultureInfo]::InvariantCulture)
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('es-AR')
    return $val.ToString('N2', $culture)
}

try {
    Write-Log "Ejecución iniciada. Consultando $sourceUrl"

    $resp = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing -TimeoutSec 30 `
        -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
    $html = $resp.Content

    $pattern = '<span class="rmag-idxmini-sigla">([^<]+)</span><span class="rmag-idxmini-valor">([^<]+)</span><span class="rmag-idxmini-var rmag-idxmini-(pos|neg)">([^<]+)</span><span class="rmag-idxmini-fecha">[^·]*·\s*([\d/]+)</span><span class="rmag-idxmini-cons"><span class="rmag-idxmini-cons-lbl">[^<]*</span><span class="rmag-idxmini-cons-val"><b>([^:<]+):\s*([^<]+)</b>\s*Variaci[oó]n:\s*<b>([^<]+)</b>'
    $idxMatches = [regex]::Matches($html, $pattern)

    if ($idxMatches.Count -ne 3) {
        Write-Log "ABORTADO: se esperaban 3 índices y se encontraron $($idxMatches.Count). La página pudo haber cambiado de estructura. index.html NO fue modificado."
        exit 1
    }

    $indices = foreach ($m in $idxMatches) {
        [pscustomobject]@{
            Sigla        = $m.Groups[1].Value.Trim()
            Valor        = Format-ArNumber $m.Groups[2].Value
            Signo        = if ($m.Groups[3].Value -eq 'pos') { '+' } else { '-' }
            Variacion    = ($m.Groups[4].Value.Trim() -replace '^[+-]', '')
            Fecha        = $m.Groups[5].Value.Trim()
            MesLabel     = $m.Groups[6].Value.Trim()
            ValorMensual = Format-ArNumber $m.Groups[7].Value
            VarMensual   = $m.Groups[8].Value.Trim()
        }
    }

    function Find-Indice($siglaContains) {
        $r = $indices | Where-Object { $_.Sigla -like "*$siglaContains*" }
        if (-not $r) { throw "No se encontró el índice '$siglaContains' entre los 3 publicados." }
        return $r
    }

    $inmag   = Find-Indice 'INMAG'
    $igmag   = Find-Indice 'IGMAG'
    $arrend  = Find-Indice 'ARRENDAMIENTO'

    $htmlText = Get-Content -Raw -Path $htmlPath -Encoding UTF8

    function Get-SignClass($signo) { if ($signo -eq '+') { 'up' } else { 'down' } }
    function Format-MonthLabel($mesLabel) {
        # "Julio 2026" -> "julio 2026"
        $parts = $mesLabel -split ' ', 2
        return ($parts[0].ToLowerInvariant()) + ' ' + $parts[1]
    }

    function Update-Card([string]$text, [string]$labelAnchor, $idx) {
        $escLabel = [regex]::Escape($labelAnchor)
        $cardPattern = '(<div class="mk-label">' + $escLabel + '</div>\s*<div class="mk-value">\$ )[\d\.,]+( <span class="mk-change )(up|down)("\s*>)[+-][\d,]+%(</span></div>\s*<div class="mk-sub">Promedio )[a-zA-Zé]+ \d{4}(: \$ )[\d\.,]+( <span class="mk-change )(up|down)("\s*>)[+-][\d,]+%(</span></div>)'
        $rx = [regex]$cardPattern
        if (-not $rx.IsMatch($text)) { throw "No se pudo localizar el bloque de '$labelAnchor' en index.html (¿cambió el markup?)." }
        # Variacion ya trae el "%" (p.ej. "3,4%"); VarMensual ya trae signo+"%" (p.ej. "+3,7%") -- no duplicar el símbolo.
        $replacement = '${1}' + $idx.Valor + '${2}' + (Get-SignClass $idx.Signo) + '${4}' + $idx.Signo + $idx.Variacion + '${5}' + (Format-MonthLabel $idx.MesLabel) + '${6}' + $idx.ValorMensual + '${7}' + (Get-SignClass ($idx.VarMensual.Substring(0,1))) + '${9}' + $idx.VarMensual + '${10}'
        return $rx.Replace($text, $replacement)
    }

    $htmlText = Update-Card $htmlText 'INMAG · Novillo' $inmag
    $htmlText = Update-Card $htmlText 'IGMAG · General' $igmag
    $htmlText = Update-Card $htmlText 'Índice arrendamientos rurales' $arrend

    $datePattern = '(<div class="market-date">Último índice operado — )\d{2}/\d{2}/\d{4}(</div>)'
    $htmlText = [regex]::Replace($htmlText, $datePattern, ('${1}' + $inmag.Fecha + '${2}'))

    [System.IO.File]::WriteAllText($htmlPath, $htmlText, (New-Object System.Text.UTF8Encoding($false)))

    Write-Log ("OK. INMAG=$($inmag.Valor) ($($inmag.Signo)$($inmag.Variacion)) | IGMAG=$($igmag.Valor) ($($igmag.Signo)$($igmag.Variacion)) | Arrendamientos=$($arrend.Valor) ($($arrend.Signo)$($arrend.Variacion)) | Fecha=$($inmag.Fecha)")
}
catch {
    Write-Log ("ERROR: " + $_.Exception.Message)
    exit 1
}
