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

function Iniciar-Driver {
    $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
    
    # Cambiamos el nombre de la variable para evitar el conflicto
    $esSistemaWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    
    if ($esSistemaWindows) {
        # En Windows usamos la variable de entorno que da GitHub Actions
        $rutaDriver = $env:CHROMEWEBDRIVER
        $driverName = "chromedriver.exe"
    } else {
        # En Linux/Ubuntu, el driver está en /usr/bin/chromedriver (si instalas chromium-chromedriver)
        $rutaDriver = "/usr/bin"
        $driverName = "chromedriver"
    }

    $pathCompleto = Join-Path $rutaDriver $driverName
    
    if (!(Test-Path $pathCompleto)) {
        throw "No se encontró el driver en: $pathCompleto"
    }

    # Opciones (Headless obligatorio en servidores)
    $options.AddArgument("--headless=new")
    $options.AddArgument("--no-sandbox")
    $options.AddArgument("--disable-dev-shm-usage")
    $options.AddArgument("--window-size=1920,1080")
    $options.AddArgument("--disable-blink-features=AutomationControlled")
    $options.AddExcludedArgument("enable-automation")
    $options.AddArgument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36")

    #Ayuda a que el driver no dependa de la memoria compartida del sistema host
    $options.AddArgument("--disable-gpu") 
    
    # Asegura que el driver no intente buscar impresoras o archivos locales del servidor
    $options.AddArgument("--disable-extensions")
    $options.AddArgument("--disable-infobars")

    Write-Host "[DEBUG] Iniciando Driver en: $pathCompleto" -ForegroundColor Magenta
    
    # Inicialización del Driver
    $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)
    return $driver
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
        # Cargar-TodosLosEventos -driver $driver
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
    write-host "actualizo archivo de eventos"
    return $eventosNuevos
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

Function Preparar-InterceptorRouter {
    param($driver)

    $driver.ExecuteScript(@"
if (!window.__routerPatched) {
    window.__lastPushedUrl = null;
    if (window.next && window.next.router) {
        const originalPush = window.next.router.push.bind(window.next.router);
        window.next.router.push = function(url, as, options) {
            window.__lastPushedUrl = as || url;
            return Promise.resolve(true); // bloquea la navegación real
        };
        window.__routerPatched = true;
        window.__interceptorDisponible = true;
    } else {
        window.__interceptorDisponible = false;
    }
}
"@)

    $disponible = $driver.ExecuteScript("return window.__interceptorDisponible;")
    return $disponible
}

Function Obtener-Urls-Nuevas {
    param($driver, $listaNuevos)

    $eventosConLinkReal = New-Object System.Collections.Generic.List[PSCustomObject]

    $interceptorOk = Preparar-InterceptorRouter -driver $driver
    if (-not $interceptorOk) {
        Write-Host "[!] window.next.router no disponible. Se usará el método con Back() (más lento)." -ForegroundColor Yellow
    }

    foreach ($evento in $listaNuevos) {
        $nombre = $evento.NombreEvento
        Write-Host "Procesando: $nombre" -ForegroundColor Cyan

        try {
            
            [void]$driver.ExecuteScript("window.__lastPushedUrl = null;")
            Start-Sleep -Milliseconds 200

            $selector = "//*[contains(normalize-space(text()), '$nombre')]"
            $target = $driver.FindElement([OpenQA.Selenium.By]::XPath($selector))

            [void]$driver.ExecuteScript("arguments[0].scrollIntoView({block: 'center'});", $target)
            Start-Sleep -Milliseconds 200

            # En lugar de $target.Click(), usamos click nativo vía JS:
            [void]$driver.ExecuteScript("arguments[0].click();", $target)
            
            $urlCapturada = $null
            for ($i = 0; $i -lt 20; $i++) {
                $urlCapturada = $driver.ExecuteScript("return window.__lastPushedUrl;")
                if ($urlCapturada) { break }
                Start-Sleep -Milliseconds 150
            }

            if (-not $urlCapturada) {
                Write-Host "   [!] No se interceptó ninguna navegación para '$nombre'." -ForegroundColor Yellow
                $nuevoObjeto = [PSCustomObject]@{
                    NombreEvento = $nombre
                    UrlEvento    = ""
                    Recinto      = $evento.Recinto
                }
                [void]$eventosConLinkReal.Add($nuevoObjeto)
                continue
            }

            $urlAbsoluta = if ($urlCapturada -match "^https?://") {
                $urlCapturada
            } else {
                "https://www.abonoteatro.com$urlCapturada"
            }

            Write-Host "   URL: $urlAbsoluta" -ForegroundColor Green

            $nuevoObjeto = [PSCustomObject]@{
                NombreEvento = $nombre
                UrlEvento    = $urlAbsoluta
                Recinto      = $evento.Recinto
            }
            [void]$eventosConLinkReal.Add($nuevoObjeto)

        } catch {
            Write-Host "   [!] Error con '$nombre': $($_.Exception.Message)" -ForegroundColor Yellow
            $nuevoObjeto = [PSCustomObject]@{
                NombreEvento = $nombre
                UrlEvento    = ""
                Recinto      = $evento.Recinto
            }
            [void]$eventosConLinkReal.Add($nuevoObjeto)
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
    $listaFinal = @()
    $finProceso = (Get-Date).AddMinutes(13)


        do {

        Write-Host ""
        Write-Host "=============================" -ForegroundColor Cyan
        Write-Host "Revision: $(Get-Date)"
        Write-Host "=============================" -ForegroundColor Cyan

        # Refrescamos la pagina
        $driverActivo.Navigate().GoToUrl("https://www.abonoteatro.com/programacion")

        Start-Sleep -Seconds 5

        # Bajamos hasta el final para que cargue todos los eventos
        Cargar-TodosLosEventos -driver $driverActivo

        # Capturamos HTML actualizado
        $htmlCatalogo = $driverActivo.PageSource

        # Generamos CSV
        Listar-Eventos -htmlDeLaWeb $htmlCatalogo

        # Comparamos
        $listaParaTelegram = Comparar-Eventos

        if ($null -ne $listaParaTelegram -and $listaParaTelegram.Count -gt 0) {

            $listaFinal = Obtener-Urls-Nuevas `
                -driver $driverActivo `
                -listaNuevos $listaParaTelegram

            foreach ($evento in $listaFinal) {
                $nombre = [System.Net.WebUtility]::HtmlEncode($evento.NombreEvento)
                $msg = "<b>🎭 NUEVO EVENTO DETECTADO</b>`n`n"
                $msg += "📌 <b>$nombre</b>`n`n"
                $msg += "🔗 <a href='$($evento.UrlEvento)'>Pulsa aquí para ver fechas y lugar</a>"

                Enviar-NotificacionTelegram -Mensaje $msg
            }

            Subir-CambiosAlRepositorio -archivo $PTH_EVT_OLD
        }

        if ((Get-Date) -lt $finProceso) {
            $espera = Get-Random -Minimum 165 -Maximum 196
            Write-Host "Esperando $espera segundos..." -ForegroundColor Yellow
            Start-Sleep -Seconds $espera
        }

    }
    while ((Get-Date) -lt $finProceso)

    Write-Host "Finalizado. Cerrando navegador..."

    $driverActivo.Quit()
    $driverActivo.Dispose()

} else {
    Write-Host "No se pudo iniciar el proceso de Selenium." -ForegroundColor Red
}
