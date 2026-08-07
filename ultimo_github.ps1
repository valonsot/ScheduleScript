$loginUser = $env:ABONO_USER
$loginPass = $env:ABONO_PASS

$PTH_EVT  = "$PSScriptRoot/nombres_eventos.csv"
$PTH_EVT_OLD = "$PSScriptRoot/cambios_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$PTH_USR  = "$PSScriptRoot/Data.txt"

$CFG_TKN = $env:TELEGRAM_TOKEN
$URL_TGM  = "https://api.telegram.org/bot$CFG_TKN"

Function Enviar-NotificacionTelegram {
    param($Mensaje)

    # Leemos el archivo y extraemos solo los números de cada @{id=XXXXXX}
    $chatIds = Get-Content $PTH_USR | ForEach-Object {
        if ($_ -match 'id=(\d+)') { $Matches[1] }
    }

    # Enviamos el mensaje a cada ID encontrado
    foreach ($id in $chatIds) {
        $payload = @{
            chat_id    = $id
            text       = $Mensaje
            parse_mode = "HTML"
        }
        
        # Envío directo sin rodeos
        Invoke-RestMethod -Uri "$URL_TGM/sendMessage" -Method Post -ContentType "application/json" -Body (ConvertTo-Json $payload)
    }
}


# 1. CSRF token (guarda cookies en $session)
$csrfResponse = Invoke-RestMethod -Uri "$baseUrl/api/auth/csrf" -Method GET -SessionVariable session
$csrfToken = $csrfResponse.csrfToken

# 2. Login
$loginBody = @{
    email       = $email
    password    = $password
    redirect    = "false"
    csrfToken   = $csrfToken
    callbackUrl = "$baseUrl/auth/login"
    json        = "true"
}
Invoke-RestMethod -Uri "$baseUrl/api/auth/callback/credentials?json=true" `
    -Method POST -Body $loginBody -WebSession $session `
    -ContentType "application/x-www-form-urlencoded" | Out-Null

# 3. Obtener el accessToken desde /api/auth/session
$sessionData = Invoke-RestMethod -Uri "$baseUrl/api/auth/session" -Method GET -WebSession $session
$accessToken = $sessionData.accessToken

Write-Host "Token capturado:"
Write-Host $accessToken
Write-Host "Longitud del token: $($accessToken.Length)"

if (-not $accessToken) {
    Write-Error "No se obtuvo accessToken. Revisa credenciales o el flujo de login."
    return
}

Write-Host "Token obtenido correctamente (expira: $($sessionData.expires))"

$apiHeaders = @{
    "Authorization"    = "Bearer $($accessToken.Trim())"
    "Accept"           = "application/json, text/plain, */*"
    "Accept-Language"  = "en-US,en;q=0.9,es-ES;q=0.8,es;q=0.7"
    "Accept-Encoding"  = "gzip, deflate, br"
    "Origin"           = "https://www.abonoteatro.com"
    "Referer"          = "https://www.abonoteatro.com/"
    "User-Agent"       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0"
    "x-device"         = "ko2cygD0zURE"
    "x-locale"         = "es_ES"
    "x-market"         = "01833ce0-3486-7bfd-84a1-ad157cf64005"
    "x-user-type"      = "SUBSCRIBER"
    "sec-ch-ua"        = '"Microsoft Edge";v="149", "Chromium";v="149", "Not)A;Brand";v="24"'
    "sec-ch-ua-mobile" = "?0"
    "sec-ch-ua-platform" = '"Windows"'
    "sec-fetch-dest"   = "empty"
    "sec-fetch-mode"   = "cors"
    "sec-fetch-site"   = "same-site"
}

$allEvents = @()
$page = 1
$itemsPerPage = 36

do {
    $response = Invoke-RestMethod -Uri "https://api.abonoteatro.com/api/web/events?page=$page&itemsPerPage=$itemsPerPage" `
        -Method GET -Headers $apiHeaders

    $allEvents += $response.items
    Write-Host "Página $page : $($response.items.Count) eventos (acumulado: $($allEvents.Count))"

    $page++
    Start-Sleep -Seconds 2   # evita machacar la API

} while ($response.items.Count -eq $itemsPerPage)

Write-Host "TOTAL FINAL: $($allEvents.Count) eventos"

# Quitar duplicados por si acaso (algunas APIs paginadas pueden solaparse si hay cambios entre llamadas)
$allEventsUnique = $allEvents | Sort-Object -Property id -Unique
Write-Host "Total únicos: $($allEventsUnique.Count)"

# Si ya tienes $allEventsUnique de antes, úsalo directamente.
# Si partes del archivo JSON guardado:
$currentData = $allEventsUnique | ForEach-Object {
    [PSCustomObject]@{
        id                         = $_.id
        name                       = $_.name
        startAt                    = $_.startAt
        endAt                      = $_.endAt
        enclosureName              = $_.enclosure.name
        enclosureAddress           = $_.enclosure.address
        types                      = ($_.types.name -join "; ")
        priceMinTicketSubscription = $_.priceMinTicketSubscription
        priceMaxTicket             = $_.priceMaxTicket
        eventFormat                = $_.eventFormat
        dailyAtDays                = $_.dailyAtDays
        photoId                    = $_.photos[0].id
    }
}

# --- 4. Cargar snapshot anterior si existe ---
if (Test-Path $PTH_EVT) {
    $previousData = Import-Csv -Path $PTH_EVT -Delimiter ";"
} else {
    $previousData = @()
    Write-Host "No había CSV previo, se tratará todo como 'nuevo'."
}

$previousIds = $previousData.id
$currentIds  = $currentData.id

# --- 5. Detectar nuevos (id no estaba antes) ---
$nuevos = $currentData | Where-Object { $previousIds -notcontains $_.id }

# --- 6. Detectar eliminados (id ya no está ahora) ---
$eliminados = $previousData | Where-Object { $currentIds -notcontains $_.id }

# --- 7. Montar el listado de cambios ---
$changes = @()

foreach ($e in $nuevos) {
    $changes += [PSCustomObject]@{
        changeType     = "NUEVO"
        id             = $e.id
        name           = $e.name
        startAt        = $e.startAt
        endAt          = $e.endAt
        priceMaxTicket = $e.priceMaxTicket
    }
}

foreach ($e in $eliminados) {
    $changes += [PSCustomObject]@{
        changeType     = "ELIMINADO"
        id             = $e.id
        name           = $e.name
        startAt        = $e.startAt
        endAt          = $e.endAt
        priceMaxTicket = $e.priceMaxTicket
    }
}

# --- 8. Guardar cambios si los hay ---
if ($changes.Count -gt 0) {
    $changes | Export-Csv -Path $PTH_EVT_OLD -NoTypeInformation -Encoding UTF8 -Delimiter ";"
    Write-Host "Cambios detectados: $($changes.Count) (Nuevos: $($nuevos.Count), Eliminados: $($eliminados.Count)) -> guardado en $PTH_EVT_OLD"
} else {
    Write-Host "No hay cambios respecto al snapshot anterior."
}

# --- 9. Sobrescribir eventos.csv con el snapshot actualizado ---
$currentData | Export-Csv -Path $PTH_EVT -NoTypeInformation -Encoding UTF8 -Delimiter ";"
Write-Host "eventos.csv actualizado con $($currentData.Count) eventos."

# --- Notificar cada evento nuevo ---
foreach ($evento in $nuevos) {

    $nombre  = [System.Net.WebUtility]::HtmlEncode($evento.name)
    $recinto = [System.Net.WebUtility]::HtmlEncode($evento.enclosureName)

    # Formatear fechas de forma legible
    try {
        $fechaInicio = ([datetime]$evento.startAt).ToString("dd/MM/yyyy HH:mm")
        $fechaFin    = ([datetime]$evento.endAt).ToString("dd/MM/yyyy HH:mm")
    } catch {
        $fechaInicio = $evento.startAt
        $fechaFin    = $evento.endAt
    }

    $msg  = "<b>🎭 NUEVO EVENTO DETECTADO</b>`n`n"
    $msg += "📌 <b>$nombre</b>`n`n"
    $msg += "📍 <b>$recinto</b>`n`n"
    $msg += "📅 <b>FECHAS:</b>`n"
    $msg += "🗓 Desde: $fechaInicio`n"
    $msg += "🗓 Hasta: $fechaFin`n`n"
    $msg += "💶 Precio hasta: $($evento.priceMaxTicket) €`n`n"
    $msg += "🔗 <a href='https://www.abonoteatro.com/evento/$($evento.id)'>Pulsa aquí para ver más</a>"

    Write-Host $msg
    #Enviar-NotificacionTelegram -Mensaje $msg

    Start-Sleep -Milliseconds 500   # evita rate-limit de Telegram
}


#hago logoff
$csrfResponse = Invoke-RestMethod -Uri "https://www.abonoteatro.com/api/auth/csrf" -Method GET -WebSession $session
$csrfToken = $csrfResponse.csrfToken

$signoutBody = @{
    csrfToken = $csrfToken
    callbackUrl = "https://www.abonoteatro.com/"
    json = "true"
}

Invoke-RestMethod -Uri "https://www.abonoteatro.com/api/auth/signout?json=true" `
    -Method POST -Body $signoutBody -WebSession $session -ContentType "application/x-www-form-urlencoded"

