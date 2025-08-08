@echo off
setlocal enabledelayedexpansion

REM ========================
REM Configuration Variables
REM ========================
set "COMPOSE_FILE=fyntrac-docker-compose.yml"
set "NETWORK_NAME=fyntrac-network"

REM Colors (limited in Windows CMD)
set "GREEN=[INFO]"
set "RED=[ERROR]"

REM Containers
set containers= ^
  fyntrac-dataloader ^
  fyntrac-model ^
  fyntrac-gl ^
  fyntrac-reporting ^
  fyntrac-web

REM Images
set images= ^
  ghcr.io/19btech/fyntrac/docker/dataloader:0.0.1-snapshot ^
  ghcr.io/19btech/fyntrac/docker/model:0.0.1-snapshot ^
  ghcr.io/19btech/fyntrac/docker/gl:0.0.1-snapshot ^
  ghcr.io/19btech/fyntrac/docker/reporting:0.0.1-snapshot ^
  ghcr.io/19btech/fyntrac/docker/web:latest

REM ========================
REM Functions
REM ========================
:log_info
echo %GREEN% %*
goto :eof

:log_error
echo %RED% %*
goto :eof

REM ========================
REM Main Script
REM ========================

call :log_info "Checking for existing Docker network: %NETWORK_NAME%..."
docker network inspect "%NETWORK_NAME%" >nul 2>&1
if errorlevel 1 (
    call :log_info "Creating Docker network: %NETWORK_NAME%"
    docker network create "%NETWORK_NAME%"
) else (
    call :log_info "Docker network %NETWORK_NAME% already exists."
)

call :log_info "Stopping and removing containers..."
for %%C in (%containers%) do (
    docker rm -f "%%C" >nul 2>&1
    if not errorlevel 1 (
        call :log_info "Removed container: %%C"
    ) else (
        call :log_info "Container not found or already removed: %%C"
    )
)

call :log_info "Removing old images..."
for %%I in (%images%) do (
    docker rmi -f "%%I" >nul 2>&1
    if not errorlevel 1 (
        call :log_info "Removed image: %%I"
    ) else (
        call :log_info "Image not found or already removed: %%I"
    )
)

call :log_info "Pulling latest images..."
for %%I in (%images%) do (
    docker pull "%%I"
    if errorlevel 1 (
        call :log_error "Failed to pull image: %%I"
        exit /b 1
    ) else (
        call :log_info "Successfully pulled: %%I"
    )
)

call :log_info "Starting containers using %COMPOSE_FILE%..."
docker compose -f "%COMPOSE_FILE%" up -d
if errorlevel 1 (
    call :log_error "Failed to start containers. Check docker compose logs."
    exit /b 1
) else (
    call :log_info "Containers started successfully."
)

endlocal
exit /b 0

