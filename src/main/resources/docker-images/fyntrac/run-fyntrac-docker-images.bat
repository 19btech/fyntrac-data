@echo off
setlocal enabledelayedexpansion

:: === CONFIG ===
set "COMPOSE_FILE=fyntrac-docker-compose.yml"
set "NETWORK_NAME=fyntrac-network"

:: === COLORS (Windows doesn't fully support ANSI by default in cmd.exe) ===
set "GREEN=[INFO]"
set "RED=[ERROR]"

:: === LOG FUNCTIONS ===
:log_info
echo %GREEN% %~1
goto :eof

:log_error
echo %RED% %~1
goto :eof

:: === CHECK MINIMUM ARGS ===
if "%~1"=="" (
    call :log_error "No components specified. Usage: %~nx0 version [component1] [component2] ... | all"
    exit /b 1
)

:: === VERSION PARAM ===
set "VERSION=%~1"
shift
if "%VERSION%"=="" set "VERSION=0.0.2-SNAPSHOT"

call :log_info "Using version: %VERSION%"

:: === VALID COMPONENTS ===
set "COMPONENTS="

if "%~1"=="" (
    call :log_error "No components specified after version. Usage: %~nx0 version [component1] [component2] ... | all"
    exit /b 1
)

if /i "%~1"=="all" (
    set "COMPONENTS=dataloader model gl reporting web"
) else (
    :component_loop
    if "%~1"=="" goto after_component_loop

    set "ARG=%~1"
    set "valid=false"
    for %%C in (dataloader model gl reporting web) do (
        if /i "!ARG!"=="%%C" set "COMPONENTS=!COMPONENTS! %%C" & set "valid=true"
    )
    if "!valid!"=="false" (
        call :log_error "Unknown component: %ARG%"
        exit /b 1
    )
    shift
    goto component_loop
)
:after_component_loop

call :log_info "Components to deploy: %COMPONENTS%"

:: === ENSURE NETWORK EXISTS ===
call :log_info "Checking for existing Docker network: %NETWORK_NAME%..."
docker network inspect %NETWORK_NAME% >nul 2>&1
if errorlevel 1 (
    call :log_info "Creating Docker network: %NETWORK_NAME%"
    docker network create %NETWORK_NAME%
) else (
    call :log_info "Docker network %NETWORK_NAME% already exists."
)

:: === STOP & REMOVE CONTAINERS ===
call :log_info "Stopping and removing containers..."
for %%C in (%COMPONENTS%) do (
    if /i "%%C"=="dataloader" set "CONTAINER=fyntrac-dataloader"
    if /i "%%C"=="model" set "CONTAINER=fyntrac-model"
    if /i "%%C"=="gl" set "CONTAINER=fyntrac-gl"
    if /i "%%C"=="reporting" set "CONTAINER=fyntrac-reporting"
    if /i "%%C"=="web" set "CONTAINER=fyntrac-web"

    docker rm -f !CONTAINER! >nul 2>&1
    if not errorlevel 1 (
        call :log_info "Removed container: !CONTAINER!"
    ) else (
        call :log_info "Container not found or already removed: !CONTAINER!"
    )
)

:: === REMOVE OLD IMAGES ===
call :log_info "Removing old images..."
for %%C in (%COMPONENTS%) do (
    if /i "%%C"=="dataloader" set "IMAGE=ghcr.io/19btech/fyntrac/docker/dataloader:%VERSION%"
    if /i "%%C"=="model" set "IMAGE=ghcr.io/19btech/fyntrac/docker/model:%VERSION%"
    if /i "%%C"=="gl" set "IMAGE=ghcr.io/19btech/fyntrac/docker/gl:%VERSION%"
    if /i "%%C"=="reporting" set "IMAGE=ghcr.io/19btech/fyntrac/docker/reporting:%VERSION%"
    if /i "%%C"=="web" set "IMAGE=ghcr.io/19btech/fyntrac/docker/web:latest"

    docker rmi -f !IMAGE! >nul 2>&1
    if not errorlevel 1 (
        call :log_info "Removed image: !IMAGE!"
    ) else (
        call :log_info "Image not found or already removed: !IMAGE!"
    )
)

:: === PULL LATEST IMAGES ===
call :log_info "Pulling latest images..."
for %%C in (%COMPONENTS%) do (
    if /i "%%C"=="dataloader" set "IMAGE=ghcr.io/19btech/fyntrac/docker/dataloader:%VERSION%"
    if /i "%%C"=="model" set "IMAGE=ghcr.io/19btech/fyntrac/docker/model:%VERSION%"
    if /i "%%C"=="gl" set "IMAGE=ghcr.io/19btech/fyntrac/docker/gl:%VERSION%"
    if /i "%%C"=="reporting" set "IMAGE=ghcr.io/19btech/fyntrac/docker/reporting:%VERSION%"
    if /i "%%C"=="web" set "IMAGE=ghcr.io/19btech/fyntrac/docker/web:latest"

    docker pull !IMAGE!
    if errorlevel 1 (
        call :log_error "Failed to pull image: !IMAGE!"
        exit /b 1
    ) else (
        call :log_info "Successfully pulled: !IMAGE!"
    )
)

:: === START SERVICES ===
call :log_info "Starting containers using %COMPOSE_FILE%..."
docker compose -f "%COMPOSE_FILE%" up -d %COMPONENTS%
if errorlevel 1 (
    call :log_error "Failed to start containers. Check docker compose logs."
    exit /b 1
) else (
    call :log_info "Containers started successfully."
)

endlocal
