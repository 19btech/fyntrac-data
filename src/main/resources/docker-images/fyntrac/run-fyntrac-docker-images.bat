@echo off

set COMPOSE_FILE=fyntrac-docker-compose.yml

REM Define container names
set containers=fyntrac-dataloader fyntrac-model fyntrac-gl fyntrac-reporting

REM Stop and remove containers
for %%C in (%containers%) do (
    docker rm -f %%C >nul 2>&1
)

REM Define image names
set images=ghcr.io/19btech/fyntrac/docker/dataloader:latest ghcr.io/19btech/fyntrac/docker/model:latest ghcr.io/19btech/fyntrac/docker/gl:latest ghcr.io/19btech/fyntrac/docker/reporting:latest

REM Remove old images
for %%I in (%images%) do (
    docker rmi -f %%I >nul 2>&1
)

REM Pull latest images
for %%I in (%images%) do (
    docker pull %%I
)

REM Start containers using the specified compose file
docker compose -f %COMPOSE_FILE% up -d

