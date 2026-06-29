$loginUser = $env:ABONO_USER
$loginPass = $env:ABONO_PASS

$PTH_EVT  = "$PSScriptRoot/nombres_eventos.csv"
$PTH_EVT_OLD = "$PSScriptRoot/nombres_eventos_old.csv"
$PTH_USR  = "$PSScriptRoot/Data.txt"

$CFG_TKN = $env:TELEGRAM_TOKEN
$URL_TGM  = "https://api.telegram.org/bot$CFG_TKN"


[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURACIÓN GLOBAL ---

# $PSScriptRoot solo se rellena si el script se ejecuta desde un archivo .ps1 en disco.
# Si se ejecuta pegado en consola o de forma interactiva, viene vacío -> usamos un fallback.
$directorioScript = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($directorioScript)) {
    if ($PSCommandPath) {
        $directorioScript = Split-Path -Parent $PSCommandPath
    } else {
        $directorioScript = (Get-Location).Path
    }
}

$inicio = Get-Date
# DURACIÓN REDUCIDA PARA PRUEBAS EN LOCAL (antes 3 horas). Súbelo cuando esté todo validado.
$fin = $inicio.AddMinutes(10)
$ultimaHora = "Nunca (Primera ejecución)"
$nombreCsv = $PTH_EVT
$csvPath = Join-Path $directorioScript $nombreCsv

$urlLogin = $env:URL_LOGIN

if ([string]::IsNullOrWhiteSpace($loginUser) -or [string]::IsNullOrWhiteSpace($loginPass)) {
    Write-Host "ERROR: Debes definir las variables de entorno ABONO_USER y ABONO_PASS" -ForegroundColor Red
    exit 1
}

# 1. CARGAR SELENIUM (Solo una vez)
if (-not (Get-Module -ListAvailable Selenium)) {
    Install-Module -Name Selenium -Force -Scope CurrentUser -AllowClobber
}
$module = Get-Module -ListAvailable Selenium | Select-Object -First 1
$dllPath = Get-ChildItem -Path $module.ModuleBase -Filter "WebDriver.dll" -Recurse | Select-Object -First 1 -ExpandProperty FullName
Add-Type -Path $dllPath

if (-not (Test-Path $dllPath)) {
    Write-Host "ERROR: No se encuentra WebDriver.dll en '$dllPath'" -ForegroundColor Red
    exit 1
}
Add-Type -Path $dllPath

function Cerrar-AvisoModal {
    param($driver)
    try {
        Write-Host "Buscando modal de aviso post-login..." -ForegroundColor Cyan
        
        # Esperamos un poco a que el JavaScript lance el pop-up después de cargar la página
        $wait = New-Object OpenQA.Selenium.Support.UI.WebDriverWait($driver, [TimeSpan]::FromSeconds(10))
        
        # Intentamos localizar el botón de cerrar (la X)
        # Probamos por el carácter ✖ que se ve en tu captura
        $xpathX = "//button[contains(., '✖')]"
        
        $botonX = $wait.Until([OpenQA.Selenium.Support.UI.ExpectedConditions]::ElementToBeClickable([OpenQA.Selenium.By]::XPath($xpathX)))
        
        # Usamos el clic de JavaScript por si el modal tiene una capa invisible encima
        $js = $driver -as [OpenQA.Selenium.IJavaScriptExecutor]
        $js.ExecuteScript("arguments[0].click();", $botonX)
        
        Write-Host "Aviso de 'Bambalinas' cerrado." -ForegroundColor Green
        Start-Sleep -Seconds 1 # Pausa para que se vaya el fondo gris difuminado
    } catch {
        Write-Host "No apareció el aviso o ya estaba cerrado." -ForegroundColor Gray
    }
}

function Escape-Html {
    param([string]$texto)
    if ($null -eq $texto) { return "" }
    return $texto.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function Iniciar-Driver {
    $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
    if (Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe") {
        $options.BinaryLocation = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    }
    # --headless desactivado temporalmente para PRUEBAS EN LOCAL:
    # así puedes ver el navegador abrirse y confirmar visualmente que el login funciona.
    # Cuando lo confirmemos, lo volvemos a activar.
    $options.AddArgument("--headless=new")
    $options.AddArgument("--no-sandbox")
    $options.AddArgument("--disable-dev-shm-usage")
    $options.AddArgument("--window-size=1920,1080")
    $options.AddArgument("--disable-blink-features=AutomationControlled")
    $options.AddExcludedArgument("enable-automation")
    $options.AddArgument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36")

    # RUTA DEL CHROMEDRIVER: usamos la carpeta real del equipo ($driverPath, definida arriba)
    $rutaDriver = if ($env:CHROMEWEBDRIVER) { $env:CHROMEWEBDRIVER } else { $driverPath }

    Write-Host "[DEBUG] rutaDriver final = '$rutaDriver'" -ForegroundColor Magenta
    if (-not (Test-Path (Join-Path $rutaDriver "chromedriver.exe"))) {
        Write-Host "⚠️ No se encuentra chromedriver.exe en '$rutaDriver'." -ForegroundColor Red
        Write-Host "   Descárgalo desde https://googlechromelabs.github.io/chrome-for-testing/ (versión que coincida con tu Chrome)" -ForegroundColor Red
        Write-Host "   y colócalo en esa carpeta." -ForegroundColor Red
        throw "chromedriver.exe no encontrado en '$rutaDriver'"
    }

    $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)
    return $driver
}

function Esperar-Elemento {
    param($driver, $by, [int]$timeoutSegundos = 20)
    $intentos = $timeoutSegundos * 2  # comprobamos cada 0.5s
    for ($i = 0; $i -lt $intentos; $i++) {
        try {
            $el = $driver.FindElement($by)
            if ($el.Displayed) { return $el }
        } catch {
            # Elemento aún no existe en el DOM, seguimos esperando
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Timeout esperando el elemento tras $timeoutSegundos segundos."
}

function Esperar-CondicionUrl {
    param($driver, [scriptblock]$condicion, [int]$timeoutSegundos = 20)
    $intentos = $timeoutSegundos * 2
    for ($i = 0; $i -lt $intentos; $i++) {
        if (& $condicion $driver) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Cerrar-BannerCookies {
    param($driver)
    # El banner "Valoramos tu privacidad" tapa el botón de login y bloquea el click.
    # Probamos varios selectores típicos de botones de cookies, por si el texto/atributo varía.
    $posiblesSelectores = @(
        "//button[contains(text(),'Aceptar todo')]",
        "//button[contains(text(),'Rechazar todo')]",
        "//button[contains(text(),'Aceptar')]"
    )
    foreach ($selector in $posiblesSelectores) {
        try {
            $boton = $driver.FindElement([OpenQA.Selenium.By]::XPath($selector))
            if ($boton.Displayed) {
                $boton.Click()
                Write-Host "Banner de cookies cerrado (selector: $selector)" -ForegroundColor Cyan
                Start-Sleep -Milliseconds 500
                return $true
            }
        } catch {
            # Este selector no encontró nada, probamos el siguiente
        }
    }
    Write-Host "[DEBUG] No se encontró banner de cookies (puede que ya estuviera cerrado o no haya aparecido)" -ForegroundColor Magenta
    return $false
}

function Hacer-Login {
    param($driver)

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Cargando página de login..." -ForegroundColor Cyan
    $driver.Navigate().GoToUrl($urlLogin)

    # El banner de cookies tapa el botón de login y bloquea el click si no lo cerramos antes
    Start-Sleep -Seconds 2
    Cerrar-BannerCookies -driver $driver | Out-Null

    # Esperar a que el campo email esté presente (la página tarda en hidratar con Next.js)
    $campoEmail = Esperar-Elemento -driver $driver -by ([OpenQA.Selenium.By]::Id("email")) -timeoutSegundos 20
    $campoPass = $driver.FindElement([OpenQA.Selenium.By]::Id("password"))
    #$botonLogin = $driver.FindElement([OpenQA.Selenium.By]::CssSelector("button[data-testid='button']"))

    Write-Host "Rellenando credenciales..." -ForegroundColor Cyan
    $campoEmail.Clear()
    $campoEmail.SendKeys($loginUser)
    $campoPass.Clear()
    $campoPass.SendKeys($loginPass)

    # Comprobación: leemos de vuelta lo que hay realmente en los campos
    $valorEmail = $campoEmail.GetAttribute("value")
    $valorPass = $campoPass.GetAttribute("value")
    Write-Host "[DEBUG] Valor en campo email tras escribir: '$valorEmail'" -ForegroundColor Magenta
    Write-Host "[DEBUG] Longitud del valor en campo password: $($valorPass.Length) caracteres" -ForegroundColor Magenta

    #Guardar-Captura -driver $driver -nombre "01_antes_de_click"

    # Por si el banner de cookies tardó en aparecer o reapareció, lo intentamos cerrar de nuevo
    Cerrar-BannerCookies -driver $driver | Out-Null

    # El botón es type="button" (no submit), así que el login se dispara por JS al hacer click.
    #$jsExecutor = $driver -as [OpenQA.Selenium.IJavaScriptExecutor]
    #try {
    #    $botonLogin.Click()
    #} catch {
    #    Write-Host "[DEBUG] Click nativo falló ($($_.Exception.Message)), probando click vía JavaScript..." -ForegroundColor Magenta
    #    $jsExecutor.ExecuteScript("arguments[0].click();", $botonLogin)
    #}

    # Buscamos un botón que contenga el texto "Acceder"
    
    $selector = "//button[contains(text(), 'Iniciar sesión')]"
    $boton = $driver.FindElement([OpenQA.Selenium.By]::XPath($selector))

    # Usar Actions para mover el ratón y pulsar
    $actions = New-Object OpenQA.Selenium.Interactions.Actions($driver)
    $actions.MoveToElement($boton).Click().Perform()

    Start-Sleep -Seconds 2
    

    # Esperar a que el login se complete: la URL deja de ser /auth/login
    $loginOk = Esperar-CondicionUrl -driver $driver -timeoutSegundos 30 -condicion {
        param($d)
        -not $d.Url.Contains("/auth/login")
    }

    #Guardar-Captura -driver $driver -nombre "03_estado_final"

    if ($loginOk) {
        Write-Host "Login completado. URL actual: $($driver.Url)" -ForegroundColor Green
        return $true
    } else {
        Write-Host "⚠️ El login no parece haber redirigido. Puede que las credenciales sean incorrectas o haya cambiado el flujo." -ForegroundColor Red
        Write-Host "[DEBUG] URL actual: $($driver.Url)" -ForegroundColor Magenta
        try {
            $bodyTexto = $driver.FindElement([OpenQA.Selenium.By]::TagName("body")).Text
            Write-Host "[DEBUG] Texto visible en la página:" -ForegroundColor Magenta
            Write-Host $bodyTexto -ForegroundColor Magenta
        } catch {
            Write-Host "[DEBUG] No se pudo leer el texto de la página." -ForegroundColor Magenta
        }
        Write-Host "[DEBUG] Dejo el navegador abierto 25 segundos para que puedas ver qué muestra la pantalla..." -ForegroundColor Magenta
        Start-Sleep -Seconds 25
        return $false
    }
}

function Obtener-CookieSesion {
    param($driver)
    # NextAuth usa esta cookie para mantener la sesión
    $cookie = $driver.Manage().Cookies.GetCookieNamed("__Secure-next-auth.session-token")
    if ($null -eq $cookie) {
        # En local (sin HTTPS) a veces no lleva el prefijo __Secure-
        $cookie = $driver.Manage().Cookies.GetCookieNamed("next-auth.session-token")
    }
    return $cookie
}


Function Listar-Eventos {
    param($htmlDeLaWeb)
    
    if (-not $htmlDeLaWeb) {
        Write-Host "Error: El HTML recibido está vacío." -ForegroundColor Red
        return
    }

    # 1. Unificamos el HTML
    $htmlString = ($htmlDeLaWeb -join "")

    # 2. REGEX MEJORADO:
    # - (?i) hace que no distinga entre mayúsculas y minúsculas
    # - Se flexibiliza el separador de la URL (acepta %252F, %2F o /)
    # - Se flexibiliza la longitud del ID
    $regex = '(?i)alt="(?<nombre>[^"]+?)".*?files(?:%252F|%2F|/)(?<id>[a-f0-9-]+?)(?:%252F|%2F|/|raw)'
    
    $coincidencias = [regex]::Matches($htmlString, $regex)

    # --- DEBUG: Línea para saber si el regex está encontrando algo ---
    Write-Host "DEBUG: Se han encontrado $($coincidencias.Count) coincidencias brutas con el Regex." -ForegroundColor Cyan

    $lista = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($m in $coincidencias) {
        $n = $m.Groups['nombre'].Value.Trim()
        $id = $m.Groups['id'].Value

        # Filtro de categorías
        $ignorar = "image|Teatro|Música|Circo|Cabaret|Infantil|Familiar|Danza|Cine|Deporte|Monólogo|Magia|Conferencia|Talleres|Visitas|Abonoteatro"
        
        if ($n -notmatch "^($ignorar)$" -and $n -ne "") {
            $lista.Add([PSCustomObject]@{
                NombreEvento = $n
                UrlEvento    = "https://www.abonoteatro.com/evento/$id"
            })
        }
    }

    # 3. Deduplicar
    $final = $lista | Group-Object NombreEvento | ForEach-Object { $_.Group[0] }
    
    if ($final) {
        # Asegúrate de que $PTH_EVT esté definida globalmente o pásala como parámetro
        $final | Export-Csv -Path $script:PTH_EVT -NoTypeInformation -Encoding UTF8 -Delimiter ";"
        Write-Host "Carga finalizada: $($final.Count) eventos únicos guardados en $script:PTH_EVT" -ForegroundColor Green
    } else {
        Write-Host "Error: No se han podido extraer eventos." -ForegroundColor Red
        Write-Host "Posible motivo: El formato del HTML ha cambiado o los nombres coinciden con la lista de 'ignorar'." -ForegroundColor Yellow
        
        # Tip de ayuda: mostrar un trozo del HTML para inspeccionar
        Write-Host "Muestra del HTML recibido (primeros 200 caracteres):"
        Write-Host ($htmlString.Substring(0, [Math]::Min(200, $htmlString.Length))) -ForegroundColor Gray
    }
}

function Subir-CambiosAlRepositorio {
    # NOTA: función pausada mientras probamos en local. Se reactivará cuando
    # volvamos a desplegar en GitHub Actions (necesita GITHUB_TOKEN configurado).
    param($archivo)
    try {
        Write-Host "Sincronizando $archivo con el repositorio web..." -ForegroundColor DarkCyan
        git add $archivo
        $status = git status --porcelain
        if ($null -ne $status) {
            git commit -m "Auto-update: Datos actualizados [$(Get-Date -Format 'HH:mm:ss')]"
            git push
            Write-Host "¡Cambios subidos con éxito!" -ForegroundColor Green
        } else {
            Write-Host "Sin cambios detectados en el CSV, saltando subida." -ForegroundColor Gray
        }
    } catch {
        Write-Host "No se pudo subir al repositorio: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Iniciar-CuentaAtras {
    param([int]$segundosTotales)
    for ($i = $segundosTotales; $i -gt 0; $i--) {
        $tiempo = New-TimeSpan -Seconds $i
        $reloj = "{0:D2}:{1:D2}" -f $tiempo.Minutes, $tiempo.Seconds
        Start-Sleep -Seconds 1
    }
    Write-Host -NoNewline "`rPróxima revisión en: $reloj | Fin del script: $($fin.ToString('HH:mm:ss')) " -ForegroundColor Gray
    Write-Host "`r" + (" " * 70) + "`r" -NoNewline
}

function MiFuncionSelenium {
    param($horaReferencia, $pathAlCsv)
    $driver = $null
    try {
        $driver = Iniciar-Driver
        

        # PASO 1: Pantalla de Login (aquí cierras las Cookies)
        $driver.Navigate().GoToUrl("https://www.abonoteatro.com/auth/login")
        Cerrar-BannerCookies -driver $driver | Out-Null
        
        $loginOk = Hacer-Login -driver $driver # Introduce user/pass y pulsa entrar
        if (-not $loginOk) { throw "Login fallido" }

        # PASO 2: Navegación al Catálogo (aquí es donde aparece el Aviso de la foto)
        Write-Host "Navegando a programación..."
        $driver.Navigate().GoToUrl("https://www.abonoteatro.com/programacion")
        
        # --- AQUÍ LLAMAMOS A LA NUEVA FUNCIÓN ---
        # Ponemos [void] delante de las funciones que devuelven Booleanos 
        # para que NO se mezclen con el HTML final
        [void](Cerrar-AvisoModal -driver $driver)        
        # ----------------------------------------

        # --- AQUÍ CARGAMOS TODOS LOS EVENTOS ---
        Cargar-TodosLosEventos -driver $driver
        # ----------------------------------------

        Write-Host "Capturando HTML completo con todos los eventos cargados..."
        $htmlCatalogo = $driver.PageSource
        
        return [PSCustomObject]@{
            Html   = $htmlCatalogo
            Driver = $driver
        }

    }
    finally {
    #    if ($null -ne $driver) { $driver.Quit(); $driver.Dispose() }
    }
}

function Cargar-TodosLosEventos {
    param($driver)
    Write-Host "Bajando scroll para cargar todos los eventos..."
    $js = $driver -as [OpenQA.Selenium.IJavaScriptExecutor]
    
    $eventosAnteriores = 0
    $pausaEntreScrolls = 4 # Segundos para esperar a que carguen los nuevos datos

    for ($i = 1; $i -le 30; $i++) { # Máximo 30 bajadas de scroll
        # 1. Bajamos al final de la página
        $js.ExecuteScript("window.scrollTo(0, document.body.scrollHeight);")
        
        # 2. Esperamos a que la web pida los datos y los pinte
        Start-Sleep -Seconds $pausaEntreScrolls

        # 3. Contamos cuántos eventos hay ahora en el HTML
        $html = $driver.PageSource
        $eventosActuales = ([regex]::Matches($html, "flex flex-col justify-center")).Count

        Write-Host "Vuelta $i Eventos detectados: $eventosActuales"

        # 4. Si el número de eventos no ha crecido, es que hemos llegado al final real
        if ($eventosActuales -le $eventosAnteriores) {
            Write-Host "Final del catálogo alcanzado."
            break
        }

        $eventosAnteriores = $eventosActuales
    }
}


Function Comparar-Eventos {
    $rutaNuevo = $PTH_EVT
    $rutaOld   = $PTH_EVT_OLD

    if (-not (Test-Path $rutaNuevo)) { return $null }

    $eventosActuales = Import-Csv $rutaNuevo -Delimiter ";"

    if (-not (Test-Path $rutaOld)) {
        Write-Host "Base de datos inicial creada." -ForegroundColor Yellow
        Move-Item -Path $rutaNuevo -Destination $rutaOld -Force
        return $null 
    }

    $eventosAnteriores = Import-Csv $rutaOld -Delimiter ";"

    # Buscamos eventos que no estaban en el archivo anterior (por nombre)
    $eventosNuevos = $eventosActuales | Where-Object { 
        $_.NombreEvento -notin $eventosAnteriores.NombreEvento 
    }

    # Rotamos archivos
    Move-Item -Path $rutaNuevo -Destination $rutaOld -Force

    return $eventosNuevos
}
Function Obtener-DetalleEvento {
    param($driver, $urlEvento)
    
    try {
        Write-Host "Navegando a: $urlEvento" -ForegroundColor Gray
        $driver.Navigate().GoToUrl($urlEvento)
        Start-Sleep -Seconds 3 # Tiempo para que carguen las fechas
        
        return $driver.PageSource
    } catch {
        Write-Host "Error al entrar en el evento $urlEvento" -ForegroundColor Red
        return $null
    }
}

function Subir-CambiosAlRepositorio {
    param($archivo)
    
    if ([string]::IsNullOrEmpty($archivo)) { 
        Write-Host "AVISO: No se ha pasado ningun nombre de archivo para subir."
        return 
    }

    try {
        # Extraemos solo el nombre del archivo (ej: nombres_eventos_old.csv) 
        # por si le pasas una ruta completa como C:\temp\...
        $soloNombre = Split-Path -Leaf $archivo
        
        Write-Host "Sincronizando $soloNombre con GitHub..."
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        
        git add $soloNombre
        if (git status --porcelain) {
            git commit -m "Auto-update: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
            git push
            Write-Host "OK: Cambios subidos."
        } else {
            Write-Host "INFO: Sin cambios que subir."
        }
    } catch {
        Write-Host "Error en Git: $($_.Exception.Message)"
    }
}
Function Obtener-Urls-Nuevas {
    param($driver, $listaNuevos)

    $eventosConLinkReal = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($evento in $listaNuevos) {
        $nombre = $evento.NombreEvento
        Write-Host "Haciendo click en: $nombre" -ForegroundColor Cyan

        try {
            # 1. SELECTOR IGUAL AL TUYO:
            # Cambiamos 'button' por '*' para que busque el texto en cualquier etiqueta (div, span, etc.)
            # Usamos normalize-space() por si hay espacios o saltos de línea invisibles
            $selector = "//*[contains(normalize-space(text()), '$nombre')]"
            
            $target = $driver.FindElement([OpenQA.Selenium.By]::XPath($selector))

            # 2. SCROLL Y CLICK (Igual que un humano)
            $driver.ExecuteScript("arguments[0].scrollIntoView({block: 'center'});", $target)
            Start-Sleep -Milliseconds 500
            $target.Click()

            # 3. ESPERAR Y CAPTURAR
            Start-Sleep -Seconds 2 # Esperamos a que cargue la ficha
            $urlReal = $driver.Url
            Write-Host "   URL Real: $urlReal" -ForegroundColor Green

            # 4. GUARDAR DATOS
            $eventosConLinkReal.Add([PSCustomObject]@{
                NombreEvento = $nombre
                UrlEvento    = $urlReal
                Recinto      = $evento.Recinto
            })

            # 5. VOLVER ATRÁS
            $driver.Navigate().Back()
            Start-Sleep -Seconds 2 # Esperamos a que recargue la lista principal

        } catch {
            Write-Host "   [!] No se pudo clicar en '$nombre'. Es posible que el nombre tenga carácteres especiales." -ForegroundColor Yellow
            $eventosConLinkReal.Add($evento) # Mantenemos el original si falla
        }
    }
    return $eventosConLinkReal
}

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

# 1. Ejecutamos la carga inicial. Obtenemos el HTML y mantenemos el DRIVER abierto.
$resultado = MiFuncionSelenium -horaReferencia $ultimaHora -pathAlCsv $csvPath

if ($null -ne $resultado) {
    $htmlCatalogo = $resultado.Html
    $driverActivo = $resultado.Driver

    # 2. Sacamos la lista de eventos con sus URLs (C:\temp\nombres_eventos.csv)
     Listar-Eventos -driver $driverActivo

    # 3. Comparamos para ver qué hay de nuevo
    $listaParaTelegram = Comparar-Eventos

    #Vamos evento a evento para sacar la url correcta.
    if ($listaParaTelegram.Count -gt 0) {
    
        # 3. LLAMADA A LA NUEVA FUNCIÓN
        # Solo entramos en los eventos que realmente vamos a enviar a Telegram
       $listaFinal = Obtener-Urls-Nuevas -driver $driverActivo -listaNuevos $listaParaTelegram

        # 4. Ahora sí, envías a Telegram con la URL corregida
        # Enviar-Telegram -lista $eventosListosParaEnviar
    }

    if ($null -ne $listaFinal) {
        Write-Host "[+] Iniciando envío de alertas por Telegram..." -ForegroundColor Cyan
    
        foreach ($evento in $listaFinal) {
            # Construimos un mensaje atractivo con el enlace real que ya extrajimos
            $msg = "<b>🎭 NUEVO EVENTO DETECTADO</b>`n`n"
            $msg += "📌 <b>$($evento.NombreEvento)</b>`n`n"
            $msg += "🔗 <a href='$($evento.UrlEvento)'>Pulsa aquí para ver fechas y lugar</a>"

        # Llamamos a la función de envío
            #Enviar-NotificacionTelegram -Mensaje $msg
        
            # Pausa de seguridad para no saturar el API de Telegram (antispam)
            Start-Sleep -Milliseconds 500
    }
    
    
    Write-Host "[+] Alertas enviadas correctamente." -ForegroundColor Green
    } else {
    Write-Host "[--] No hay eventos nuevos para notificar." -ForegroundColor Gray
    }

    # 4. Bucle para entrar en cada evento nuevo SIN CERRAR el navegador
    <#if ($null -ne $listaParaTelegram) {
        foreach ($evento in $listaParaTelegram) {
            Write-Host "--- Procesando: $($evento.NombreEvento) ---" -ForegroundColor Magenta
            
            # Entramos en la web del evento para sacar sus detalles
            $htmlDetalle = Obtener-DetalleEvento -driver $driverActivo -urlEvento $evento.UrlEvento
            
            if ($htmlDetalle) {
                # Aquí llamarías a una función tuya para sacar la fecha/lugar del HTML
                # Ejemplo: $datosExtra = Procesar-HTML-Detalle -html $htmlDetalle
                Write-Host "Detalle capturado para $($evento.NombreEvento)" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "No hay eventos nuevos para procesar." -ForegroundColor Yellow
    }#>

    # 5. AHORA SÍ: Cerramos el navegador al final de todo el proceso
    Write-Host "Finalizado. Cerrando navegador..." -ForegroundColor Yellow
    $driverActivo.Quit()
    $driverActivo.Dispose()

    Subir-CambiosAlRepositorio -archivo $PTH_EVT_OLD

} else {
    Write-Host "No se pudo iniciar el proceso de Selenium." -ForegroundColor Red
}
