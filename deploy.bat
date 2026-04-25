@echo off
chcp 65001 >nul
title wrong_answer_server auto deploy

echo ==========================================
echo    wrong_answer_server deploy
echo ==========================================
echo.

:: Server Config
set SERVER=192.168.41.177
set USER=tff
set PORT=22
set TARGET_DIR=/home/tff/software/LLM/wrong_answer_server

:: Check tar
tar --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] tar not found, install Git for Windows or WSL
    pause
    exit /b 1
)

:: Check SSH
echo [0/4] Check SSH...
ssh -o ConnectTimeout=5 -o PreferredAuthentications=publickey -o PasswordAuthentication=no -p %PORT% %USER%@%SERVER% "echo ok" >nul 2>&1
if errorlevel 1 (
    echo [WARN] SSH key auth not configured, will prompt for password
    echo        Run first: ssh-copy-id -p %PORT% %USER%@%SERVER%
    echo.
)

:: Step 1: Pack
echo [1/4] Packing code...
cd /d "%~dp0"
tar -czf deploy.tar.gz ^
    --exclude="__pycache__" ^
    --exclude="*.pyc" ^
    --exclude="*.pyo" ^
    --exclude=".pytest_cache" ^
    --exclude=".git" ^
    --exclude="*.log" ^
    --exclude=".venv" ^
    --exclude="venv" ^
    --exclude="storage" ^
    --exclude="logs" ^
    --exclude="deploy.bat" ^
    --exclude="deploy.tar.gz" ^
    --exclude="remote_deploy.sh" ^
    .
if errorlevel 1 (
    echo [ERROR] Pack failed
    pause
    exit /b 1
)

:: Step 2: Upload code
echo [2/4] Upload to %SERVER%:%TARGET_DIR%...
scp -P %PORT% deploy.tar.gz %USER%@%SERVER%:%TARGET_DIR%/
if errorlevel 1 (
    echo [ERROR] Upload code failed
    del deploy.tar.gz >nul 2>&1
    pause
    exit /b 1
)

:: Step 3: Upload deploy script
echo [3/4] Upload deploy script...
scp -P %PORT% remote_deploy.sh %USER%@%SERVER%:%TARGET_DIR%/
if errorlevel 1 (
    echo [ERROR] Upload script failed
    del deploy.tar.gz >nul 2>&1
    pause
    exit /b 1
)

:: Step 4: Remote deploy
echo [4/4] Remote deploy and restart...
ssh -tt -p %PORT% %USER%@%SERVER% "cd %TARGET_DIR% && bash remote_deploy.sh %TARGET_DIR% && rm remote_deploy.sh"

:: Cleanup
echo [5/5] Cleanup local temp files...
del deploy.tar.gz >nul 2>&1

echo.
echo ==========================================
echo    Deploy Done!
echo ==========================================
echo.
echo Service: http://%SERVER%:9000
echo Log:     %TARGET_DIR%/logs/start.log
echo.
echo View realtime log:
echo   ssh -p %PORT% %USER%@%SERVER% "tail -f %TARGET_DIR%/logs/start.log"
echo.
pause
