# 1. Definir la ruta y el nombre del archivo con fecha y hora

# Borra archivos de transcripción que tengan más de 1 día de antigüedad
Get-ChildItem "transcripcion_*.txt" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item
$fecha = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "transcripcion_$fecha.txt"

# 2. Iniciar la transcripción
# Esto grabará todo lo que salga en la consola a partir de aquí
Start-Transcript -Path $logFile

try {
$CFG_USR = $env:ABONO_USER
$CFG_PWD = $env:ABONO_PASS
$CFG_TKN = $env:TELEGRAM_TOKEN

$URL_BASE = $env:URL_BASE
$URL_DET  = $env:URL_DETALLE
$URL_LGN  = $env:URL_LOGIN
$URL_TRT  = $env:URL_TEATRO
$URL_REF  = $env:URL_REFERER
$URL_TGM  = "https://api.telegram.org/bot$CFG_TKN"

# Rutas relativas para que funcione en cualquier carpeta de GitHub
$PTH_EVT  = "$PSScriptRoot/eventos_anteriores.csv"
$PTH_USR  = "$PSScriptRoot/Data.txt"

$GLB_UA   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

Function Get-fechas($code) {
    $headers = @{
        "Accept"           = "text/html, */*; q=0.01"
        "Accept-Language"  = "es-ES,es;q=0.9"
        "Origin"           = $URL_BASE
        "Referer"          = "$URL_BASE/"
        "X-Requested-With" = "XMLHttpRequest"
    }

    $body = @{
        action  = "show"
        content = $code
    }

    $response = Invoke-WebRequest -Uri $URL_DET -Method Post -WebSession $mySession -Headers $headers -Body $body -UserAgent $GLB_UA
    $bloque = $response.Content
    $regexFecha = '<p class="psess">\s*([^<]+)\s*</p>\s*<p class="psesb">\s*([^<]+)\s*</p>\s*<p class="psess">\s*([^<]+)\s*</p>'
    $coincidencias = [regex]::Matches($bloque, $regexFecha)
    $fechas = @()

    foreach ($m in $coincidencias) {
        $mesAnio = $m.Groups[1].Value.Trim()
        $dia     = $m.Groups[2].Value.Trim()
        $semana  = $m.Groups[3].Value.Trim()
        $fechas += "$($semana.ToLower()) $dia $($mesAnio.ToLower())"
    }
    return $fechas
}

$bodyLogin = @{
    nabonadologin   = $CFG_USR
    contrasenalogin = $CFG_PWD
    dominiourl      = "$URL_BASE/"
    nocache         = (Get-Random -Minimum 0 -Maximum 1).ToString()
}

$headersLogin = @{
    "Accept"          = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"
    "Accept-Language" = "es-ES,es;q=0.9"
    "Origin"          = $URL_BASE
    "Referer"         = $URL_REF
}

try {
    $response = Invoke-WebRequest -Uri $URL_LGN -Method Post -Body $bodyLogin -Headers $headersLogin -UserAgent $GLB_UA -SessionVariable "mySession"
    $paginaInterna = Invoke-WebRequest -Uri $URL_TRT -WebSession $mySession -Method Get
    write-host "he conectado con ...."
    $response
} catch {
    write-host "no conecto con....."
    return
}

$pattern = '(?i)<iframe\s+[^>]*src="(https://programacion\.abonoteatro\.com/catalogo/teatros\d\.php\?token=[^"]+)"'

if ($paginaInterna.Content -match $pattern) {
    $urlCatalogo = $Matches[1]
} else {
    write-host "no encuentro el catalogo"
    return
}

$cookiesRecibidas = $mySession.Cookies.GetCookies($URL_BASE)

function Add-AbonoCookie($name, $value) {
    $cookie = New-Object System.Net.Cookie
    $cookie.Name = $name
    $cookie.Value = $value
    $cookie.Domain = ".abonoteatro.com"
    $mySession.Cookies.Add($cookie)
}

$iduserab = $cookiesRecibidas | Where-Object { $_.Name -like "iduserab" } | Select-Object -ExpandProperty Value
$unabonado = $cookiesRecibidas | Where-Object { $_.Name -like "unabonado" } | Select-Object -ExpandProperty Value
$version = $cookiesRecibidas | Where-Object { $_.Name -like "version" } | Select-Object -ExpandProperty Value

Add-AbonoCookie "iduserab" $iduserab
Add-AbonoCookie "unabonado" $unabonado
Add-AbonoCookie "version" $version

if (-not $mySession) { $mySession = New-Object Microsoft.PowerShell.Commands.WebRequestSession }

$respuesta = Invoke-WebRequest -Uri $urlCatalogo -WebSession $mySession -Headers @{"Referer" = "$URL_BASE/"} -UserAgent $GLB_UA
write-host "he metido las cookies"
$html = $respuesta.Content
$regexEvento = '<!--\s*INICIO EVENTO\s*-->[\s\S]*?<!--\s*FIN EVENTO\s*-->[\s\S]*?<input[^>]*value="([^"]+)"'
$bloquesEventos = [regex]::Matches($html, $regexEvento)
$eventos = @()

foreach ($bloque in $bloquesEventos) {
    $contenido = $bloque
    $contentValue = $bloque.Groups[1].Value
    
    $headersDetalle = @{
        "Accept"           = "text/html, */*; q=0.01"
        "Origin"           = $URL_BASE
        "Referer"          = "$URL_BASE/"
        "X-Requested-With" = "XMLHttpRequest"
    }

    $resDetalle = Invoke-WebRequest -Uri $URL_DET -Method Post -WebSession $mySession -Headers $headersDetalle -Body @{action="show"; content=$contentValue} -UserAgent $GLB_UA
    $htmlModal = $resDetalle.Content
    $bloquesSesion = $htmlModal -split 'class="bsesion"' | Select-Object -Skip 1

    $listaFechas = @()
    $listaIds = @()
    
    $titulo = if ($contenido -match 'class="url"[^>]*title="([^"]+)"') { $matches[1].Trim() }
    $eventId = if ($contenido -match 'id="post-(\d+)"') { $matches[1] }
    $lugar = if ($contenido -match 'tribe-events-venue-details[\s\S]*?<a[^>]*>[\s\S]*?<i[^>]*></i>\s*([^<]+)') { $matches[1].Trim() }
    $precio = if ($contenido -match 'class="precioboxsesion">([^<]+)<') { $matches[1].Trim() }
    $listaLinks = "$URL_BASE/?pagename=espectaculo&eventid=$eventid#compradias"

    foreach ($bs in $bloquesSesion) {
        if ($bs -match 'eventocurrence=(\d+)') { $listaIds += $matches[1] }
        $partesFecha = [regex]::Matches($bs, 'class="pses[sb]">([^<]+)')
        if ($partesFecha.Count -ge 3) {
            $mAnio = $partesFecha[0].Groups[1].Value.Trim()
            $dNum  = $partesFecha[1].Groups[1].Value.Trim()
            $dNom  = $partesFecha[2].Groups[1].Value.Trim()
        }
        $hora = if ($bs -match 'horasesion[^>]*>.*?</i>\s*([^<]+)') { $matches[1].Trim() } else { "---" }
        $listaFechas += "$dNum $dNom ($mAnio) - $hora"
    }   

    $eventos += [PSCustomObject]@{
        Titulo = $titulo
        Lugar  = $lugar
        Precio = $precio
        Fecha  = $listaFechas
        Link   = $listaLinks  
        Ids    = $listaIds
        EventId = $eventId
    }
}

$eventos

if (Test-Path $PTH_EVT) {
    $eventosAnteriores = Import-Csv $PTH_EVT
    $eventosNuevos = $eventos | Where-Object { $tituloActual = $_.Titulo; -not ($eventosAnteriores | Where-Object { $_.Titulo -eq $tituloActual }) }
} else {
    $eventosNuevos = $eventos
}

$eventos | Export-Csv $PTH_EVT -NoTypeInformation -Encoding UTF8

$upd = Invoke-RestMethod -Uri "$URL_TGM/getUpdates"
$listaChatIds = $upd.result.message.chat | Select-Object id -Unique
if (!(Test-Path $PTH_USR)) { New-Item $PTH_USR }
$idsExistentes = Get-Content $PTH_USR
$listaChatIds | Where-Object { $_ -notin $idsExistentes } | ForEach-Object { Add-Content $PTH_USR $_ }
$finalIds = Get-Content $PTH_USR | ForEach-Object { if ($_ -match '(\d+)') { [pscustomobject]@{id = $matches[1]} } }

if ($eventosNuevos){
    foreach ($ne in $eventosNuevos){
        foreach ($cid in $finalIds){
            $textoFechas = ""
            if ($ne.Fecha -is [array]) {
                foreach ($f in $ne.Fecha) { $textoFechas += "  • $f`n" }
            } else {
                $textoFechas = "  • $($ne.Fecha)`n"
            }

            $msg = @"
<b>📌 $($ne.Titulo)</b>

📍 <b>Lugar:</b> $($ne.Lugar)
💰 <b>Precio:</b> $($ne.Precio)

📅 <b>Fechas:</b>
$textoFechas
👉 <a href='$($ne.Link)'>Hacer clic aquí para Comprar</a>
"@
            $payload = @{ chat_id = $cid.id; text = $msg; parse_mode = "HTML" }

            try {
                $r = Invoke-RestMethod -Uri "$URL_TGM/sendMessage" -Method Post -Body $payload
                $l = "{0},{1},""{2}"",{3},{4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $cid.id, ($ne.Titulo -replace '"','""'), $r.ok, $r.result.message_id
            } catch {
                $l = "{0},{1},""{2}"",false,""{3}""" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $cid.id, ($ne.Titulo -replace '"','""'), ($_.Exception.Message -replace '"','""')
            }
            #Add-Content $PTH_LOG $l
        }
    }
}
}
finally {
   Stop-Transcript
    Write-Host "Limpiando logs antiguos (mayores a 60 minutos)..."
    
    # 1. Definir el límite de tiempo (Hace 1 hora)
    $limiteHora = (Get-Date).AddHours(-1)
    
    # 2. Buscar y borrar archivos que coincidan con el patrón y sean viejos
    Get-ChildItem "transcripcion_*.txt" | Where-Object { 
        $_.LastWriteTime -lt $limiteHora 
    } | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host "Limpieza completada."
}

