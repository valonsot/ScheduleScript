
# 1. Obtener la ruta donde está el script
$rutaActual = $PSScriptRoot

Write-Host "Buscando archivos 'transcripcion' en: $rutaActual" -ForegroundColor Cyan

# 2. Buscar todos los archivos que empiecen por transcripcion
$archivos = Get-ChildItem -Path "$rutaActual\transcripcion*"

if ($archivos) {
    Write-Host "Se han encontrado $($archivos.Count) archivos para eliminar." -ForegroundColor Yellow
    foreach ($archivo in $archivos) {
        Write-Host "Eliminando: $($archivo.Name)"
        Remove-Item -Path $archivo.FullName -Force
    }
    Write-Host "Limpieza completada en el disco local." -ForegroundColor Green
} else {
    Write-Host "No se encontraron archivos de transcripción." -ForegroundColor Green
}
