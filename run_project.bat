@echo off
cd /d "%~dp0"
title Compilar y Ejecutar - InterfaceFile
echo =======================================================
echo     COMPILANDO Y EJECUTANDO EL PROYECTO C#
echo =======================================================
echo.

echo Ejecutando: dotnet build
dotnet build
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Ocurrio un problema durante la compilacion. Revisa los mensajes arriba.
    pause
    exit /b %errorlevel%
)

echo.
echo [EXITO] Compilacion completada sin errores.
echo.
echo Ejecutando: dotnet run
echo =======================================================
echo La aplicacion esta iniciandose...
echo (Presiona Ctrl+C en cualquier momento para detenerla)
echo =======================================================
dotnet run

pause
