# ==============================================================================
# PaddleOCR-VL-1.6 & PaddlePaddle Windows PowerShell Setup Script
# Run in PowerShell: .\setup_paddle_windows.ps1
# ==============================================================================

param (
    [switch]$NoDownloadModels,
    [switch]$CpuOnly,
    [switch]$GpuOnly,
    [switch]$SkipEnv
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   PaddleOCR-VL-1.6 & PaddlePaddle Windows PowerShell Setup" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = $ScriptDir
$VenvDir = Join-Path $ProjectRoot "venv"

# 1. Detect GPU
Write-Host "`n[1/6] Detecting GPU Hardware..." -ForegroundColor Blue
$HasGpu = $false
$Device = "cpu"

try {
    $gpuCheck = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($gpuCheck) {
        $gpuName = & nvidia-smi.exe --query-gpu=name --format=csv,noheader
        Write-Host "  Detected NVIDIA GPU: $gpuName" -ForegroundColor Green
        $HasGpu = $true
        $Device = "gpu"
    } else {
        Write-Host "  No NVIDIA GPU found. Using CPU mode." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  nvidia-smi check skipped. Defaulting to CPU." -ForegroundColor Yellow
}

if ($CpuOnly) {
    $Device = "cpu"
    $HasGpu = $false
    Write-Host "  User Override: Forcing CPU mode" -ForegroundColor Yellow
} elseif ($GpuOnly) {
    $Device = "gpu"
    $HasGpu = $true
    Write-Host "  User Override: Forcing GPU mode" -ForegroundColor Green
}

# 2. Locate 64-bit Python
Write-Host "`n[2/6] Locating 64-bit Python 3.9 - 3.12..." -ForegroundColor Blue
$PythonCmd = $null

foreach ($candidate in @("py -3.11", "py -3.10", "py -3.12", "python3.11", "python3", "python")) {
    try {
        $check = Start-Process -FilePath "powershell" -ArgumentList "-NoProfile -Command $candidate -c 'import sys; exit(0 if sys.version_info >= (3,9) and sys.version_info < (3,13) and sys.maxsize > 2**32 else 1)'" -Wait -Passthru
        if ($check.ExitCode -eq 0) {
            $PythonCmd = $candidate
            break
        }
    } catch {}
}

if (-not $PythonCmd) {
    Write-Host "Error: Could not locate 64-bit Python 3.9-3.12." -ForegroundColor Red
    Write-Host "Please install Python 3.11 (64-bit) from https://www.python.org/downloads/"
    exit 1
}

Write-Host "  Found Python: $PythonCmd" -ForegroundColor Green

# 3. Create or Locate Virtual Environment
Write-Host "`n[3/6] Setting Up Virtual Environment..." -ForegroundColor Blue
if (-not (Test-Path $VenvDir)) {
    Write-Host "  Creating venv at $VenvDir..."
    cmd /c "$PythonCmd -m venv $VenvDir"
} else {
    Write-Host "  Using existing venv at $VenvDir" -ForegroundColor Green
}

$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$VenvPip = Join-Path $VenvDir "Scripts\pip.exe"

& $VenvPip install --upgrade --quiet pip setuptools wheel

# 4. Install Dependencies
Write-Host "`n[4/6] Installing PaddlePaddle & PaddleOCR..." -ForegroundColor Blue
if ($HasGpu -and ($Device -eq "gpu")) {
    Write-Host "  Installing paddlepaddle-gpu for CUDA..." -ForegroundColor Green
    try {
        & $VenvPip install paddlepaddle-gpu
    } catch {
        Write-Host "  Warning: paddlepaddle-gpu installation failed. Falling back to CPU..." -ForegroundColor Yellow
        & $VenvPip install paddlepaddle
        $Device = "cpu"
    }
} else {
    Write-Host "  Installing paddlepaddle (CPU mode)..."
    & $VenvPip install paddlepaddle
}

& $VenvPip install "paddleocr[doc-parser]>=3.6.0" "paddlex>=3.7.0" "pypdfium2>=5.0.0"

$ReqFile = Join-Path $ProjectRoot "requirements.txt"
if (Test-Path $ReqFile) {
    & $VenvPip install -r $ReqFile --quiet
}

# 5. Configure .env
Write-Host "`n[5/6] Updating .env..." -ForegroundColor Blue
$EnvFile = Join-Path $ProjectRoot ".env"
$EnvExample = Join-Path $ProjectRoot ".env.example"

if (-not (Test-Path $EnvFile) -and (Test-Path $EnvExample)) {
    Copy-Item $EnvExample $EnvFile
}

if (-not $SkipEnv) {
    function Set-EnvVar($key, $val) {
        if (-not (Test-Path $EnvFile)) { New-Item -ItemType File -Path $EnvFile | Out-Null }
        $content = Get-Content $EnvFile
        $found = $false
        $newContent = @()
        foreach ($line in $content) {
            if ($line -match "^$key=") {
                $newContent += "$key=$val"
                $found = $true
            } else {
                $newContent += $line
            }
        }
        if (-not $found) {
            $newContent += "$key=$val"
        }
        $newContent | Set-Content $EnvFile
    }

    Set-EnvVar "OCR_PROVIDER" '"paddleocr_vl"'
    Set-EnvVar "PADDLEOCR_VL_BACKEND" '"local"'
    Set-EnvVar "PADDLEOCR_VL_DEVICE" "`"$Device`""
    Set-EnvVar "PADDLEOCR_VL_TIMEOUT_SECONDS" "180"
    Write-Host "  .env configured for local PaddleOCR ($Device)" -ForegroundColor Green
}

# 6. Verify & Download Models
Write-Host "`n[6/6] Verifying Installation..." -ForegroundColor Blue
& $VenvPython -c "import paddle; from paddleocr import PaddleOCRVL; print('Paddle Version:', paddle.__version__); print('Device:', paddle.device.get_device())"

if (-not $NoDownloadModels) {
    Write-Host "`nPre-downloading PaddleOCR-VL-1.6 & PP-DocLayoutV3 models (~1.9 GB)..." -ForegroundColor Blue
    & $VenvPython -c "import paddle; from paddleocr import PaddleOCRVL; d = '$Device'; paddle.device.set_device(d); pipeline = PaddleOCRVL(pipeline_version='v1.6', device=d); print('Models downloaded and cached successfully!')"
}

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  PaddleOCR-VL-1.6 Windows Setup Completed Successfully!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "`nTo start services on Windows:"
Write-Host "  1. Celery Worker : .\venv\Scripts\celery.exe -A app.core.celery_app worker --loglevel=info -P solo" -ForegroundColor Yellow
Write-Host "  2. FastAPI Server: .\venv\Scripts\uvicorn.exe app.main:app --host 0.0.0.0 --port 9000 --reload"
