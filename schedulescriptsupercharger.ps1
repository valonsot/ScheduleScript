# 1. Borra archivos de transcripción que tengan más de 1 día de antigüedad
Get-ChildItem "transcripcion_*.txt" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -ErrorAction SilentlyContinue
$fecha = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "transcripcion_$fecha.txt"

# 2. Iniciar la transcripción
Start-Transcript -Path $logFile

try {
    # Variables de entorno y configuración general
    $CFG_USR = $env:ABONO_USER
    $CFG_PWD = $env:ABONO_PASS
    $CFG_TKN = $env:TELEGRAM_TOKEN

    $URL_BASE = $env:URL_BASE
    $URL_DET  = $env:URL_DETALLE
    $URL_LGN  = $env:URL_LOGIN
    $URL_TRT  = $env:URL_TEATRO
    $URL_REF  = $env:URL_REFERER
    $URL_TGM  = "https://api.telegram.org/bot$CFG_TKN"

    $PTH_EVT  = "$PSScriptRoot/eventos_anteriores.csv"
    $PTH_USR  = "$PSScriptRoot/Data.txt"

    $GLB_UA   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    # Definir funciones fuera del bucle
    Function Get-fechas($code, $session) {
        $headers = @{
            "Accept"           = "text/html, */*; q=0.01"
            "Accept-Language"  = "es-ES,es;q=0.9"
            "Origin"           = $URL_BASE
            "Referer"          = "$URL_BASE/"
            "X-Requested-With" = "XMLHttpRequest"
        }

        $body = @{ action = "show"; content = $code }

        $response = Invoke-WebRequest -Uri $URL_DET -Method Post -WebSession $session -Headers $headers -Body $body -UserAgent $GLB_UA
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

    function Add-AbonoCookie($name, $value, $session) {
        $cookie = New-Object System.Net.Cookie
        $cookie.Name = $name
        $cookie.Value = $value
        $cookie.Domain = ".abonoteatro.com"
        $session.Cookies.Add($cookie)
    }

    # Definir límite de tiempo (2 horas desde que arranca)
    $horaInicio = Get-Date
    $horaFin = $horaInicio.AddHours(2)
    Write-Host "Arrancando script continuo. Finalizará automáticamente a las: $horaFin"

    # BUCLE PRINCIPAL (Se ejecutará repetidamente hasta que pasen 2 horas)
    while ((Get-Date) -lt $horaFin) {
        Write-Host "`n--- Iniciando iteración a las $(Get-Date -Format 'HH:mm:ss') ---"
        
        try {
            # Limpiamos la sesión en cada iteración para que sea una solicitud "limpia"
            $mySession = New-Object Microsoft.PowerShell.Commands.WebRequestSession

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

            $response = Invoke-WebRequest -Uri $URL_LGN -Method Post -Body $bodyLogin -Headers $headersLogin -UserAgent $GLB_UA -WebSession $mySession
            $paginaInterna = Invoke-WebRequest -Uri $URL_TRT -WebSession $mySession -Method Get
            Write-Host "He conectado correctamente con el portal de inicio..."

            $pattern = '(?i)<iframe\s+[^>]*src="(https://programacion\.abonoteatro\.com/catalogo/teatros\d\.php\?token=[^"]+)"'

            if ($paginaInterna.Content -match $pattern) {
                $urlCatalogo = $Matches[1]
            } else {
                throw "No encuentro el catálogo iframe en la página interna" 
            }

            $cookiesRecibidas = $mySession.Cookies.GetCookies($URL_BASE)

            $iduserab = $cookiesRecibidas | Where-Object { $_.Name -like "iduserab" } | Select-Object -ExpandProperty Value
            $unabonado = $cookiesRecibidas | Where-Object { $_.Name -like "unabonado" } | Select-Object -ExpandProperty Value
            $version = $cookiesRecibidas | Where-Object { $_.Name -like "version" } | Select-Object -ExpandProperty Value

            Add-AbonoCookie "iduserab" $iduserab $mySession
            Add-AbonoCookie "unabonado" $unabonado $mySession
            Add-AbonoCookie "version" $version $mySession

            $respuesta = Invoke-WebRequest -Uri $urlCatalogo -WebSession $mySession -Headers @{"Referer" = "$URL_BASE/"} -UserAgent $GLB_UA
            Write-Host "He metido las cookies y recuperado el catálogo..."
            
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

            Write-Host "Se han parseado $($eventos.Count) eventos en esta iteración."

            if (Test-Path $PTH_EVT) {
                $eventosAnteriores = Import-Csv $PTH_EVT
                $eventosNuevos = $eventos | Where-Object { $tituloActual = $_.Titulo; -not ($eventosAnteriores | Where-Object { $_.Titulo -eq $tituloActual }) }
            } else {
                $eventosNuevos = $eventos
            }

            # Guardamos para la siguiente iteración de forma local
            $eventos | Export-Csv $PTH_EVT -NoTypeInformation -Encoding UTF8

            $upd = Invoke-RestMethod -Uri "$URL_TGM/getUpdates"
            if ($null -ne $upd -and $null -ne $upd.result) {
                $listaChatIds = $upd.result.message.chat | Select-Object id -Unique
                if (!(Test-Path $PTH_USR)) { New-Item $PTH_USR -Force | Out-Null }
                $idsExistentes = Get-Content $PTH_USR
                $listaChatIds | Where-Object { $_ -notin $idsExistentes } | ForEach-Object { Add-Content $PTH_USR $_ }
            }
            
            if (Test-Path $PTH_USR) {
                $finalIds = Get-Content $PTH_USR | ForEach-Object { if ($_ -match '(\d+)') { [pscustomobject]@{id = $matches[1]} } }
            }

            # Enviar mensajes de Telegram
            if ($eventosNuevos){
                Write-Host "¡Se han detectado $($eventosNuevos.Count) eventos nuevos! Enviando por Telegram..."
                foreach ($ne in $eventosNuevos){
                    foreach ($cid in $finalIds){
                        $textoFechas = ""
                        if ($ne.Fecha -is[array]) {
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
                            Write-Host "Mensaje enviado a $($cid.id)"
                        } catch {
                            Write-Host "Error al enviar mensaje a Telegram: $($_.Exception.Message)"
                        }
                    }
                }
            } else {
                Write-Host "No hay eventos nuevos en esta iteración."
            }

            # ==========================================================
            # NUEVO: FORZAR SUBIDA A GITHUB EN CADA ITERACIÓN DEL BUCLE
            # ==========================================================
            Write-Host "Comprobando si hay cambios en el CSV o TXT para subir a GitHub..."
            
            git config --local user.email "github-actions[bot]@users.noreply.github.com"
            git config --local user.name "github-actions[bot]"
            
            # Usamos los nombres directos en vez de variables con rutas completas
            # Esto evita que Git de Windows se vuelva loco con las barras \ y /
            git add eventos_anteriores.csv
            if (Test-Path "Data.txt") { git add Data.txt }
            
            # Comprobamos si REALMENTE se ha modificado el CSV o el TXT
            $staged = git diff --cached --name-only
            
            if ($staged) {
                Write-Host "Se han detectado cambios reales en estos ficheros: $staged"
                Write-Host "Subiendo a GitHub..."
                
                git commit -m "Auto-update desde bucle: $(Get-Date -Format 'HH:mm:ss')"
                git push
                
                Write-Host "¡Subida a GitHub completada en directo!"
            } else {
                Write-Host "El contenido del CSV no ha cambiado respecto a la anterior iteración. Omitiendo subida para no hacer spam de commits."
            }
            # ==========================================================

        } catch {
            Write-Host "Error en la iteración: $($_.Exception.Message)"
        }

        # Comprobar que no nos hemos pasado de las 2 horas antes de dormir
        if ((Get-Date) -lt $horaFin) {
            # Selecciona de forma aleatoria un tiempo de espera entre 120 segs (2 min) y 180 segs (3 min)
            $sleepSeconds = Get-Random -Minimum 120 -Maximum 181
            Write-Host "Esperando $sleepSeconds segundos (aprox $([math]::Round($sleepSeconds/60, 1)) min) para despistar al bot..."
            Start-Sleep -Seconds $sleepSeconds
        }
    }
    Write-Host "Han pasado las 2 horas. Finalizando ejecución correctamente."
}
finally {
    Stop-Transcript

    $rutaActual = $PSScriptRoot
    Write-Host "Limpiando logs en: $rutaActual"
    
    $limiteHora = (Get-Date).AddHours(-1)
    Get-ChildItem -Path "$rutaActual\transcripcion_*.txt" | Where-Object { 
        $_.LastWriteTime -lt $limiteHora 
    } | Remove-Item -Force -ErrorAction SilentlyContinue
}
