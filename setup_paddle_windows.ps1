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

# Prevent PowerShell from treating native command stderr (like pip download progress) as fatal
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $global:PSNativeCommandUseErrorActionPreference = $false
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   PaddleOCR-VL-1.6 & PaddlePaddle Windows PowerShell Setup" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = $ScriptDir
$VenvDir = Join-Path $ProjectRoot "venv"

# ------------------------------------------------------------------------------
# 1. Detect GPU Hardware
# ------------------------------------------------------------------------------
Write-Host "`n[1/6] Detecting GPU Hardware..." -ForegroundColor Blue
$HasGpu = $false
$Device = "cpu"

try {
    $gpuCheck = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($gpuCheck) {
        $gpuName = (& nvidia-smi.exe --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1)
        if ($gpuName) {
            Write-Host "  Detected NVIDIA GPU: $gpuName" -ForegroundColor Green
            $HasGpu = $true
            $Device = "gpu"
        } else {
            Write-Host "  nvidia-smi returned empty. Defaulting to CPU." -ForegroundColor Yellow
        }
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

# ------------------------------------------------------------------------------
# 2. Locate 64-bit Python 3.9 - 3.12
# ------------------------------------------------------------------------------
Write-Host "`n[2/6] Locating 64-bit Python 3.9 - 3.12..." -ForegroundColor Blue
$PythonCmd = $null

foreach ($candidate in @("py -3.11", "py -3.10", "py -3.12", "python3.11", "python3", "python")) {
    try {
        $check = Start-Process -FilePath "powershell" -ArgumentList "-NoProfile -Command $candidate -c 'import sys; exit(0 if sys.version_info >= (3,9) and sys.version_info < (3,13) and sys.maxsize > 2**32 else 1)'" -Wait -Passthru -ErrorAction SilentlyContinue
        if ($check.ExitCode -eq 0) {
            $PythonCmd = $candidate
            break
        }
    } catch {}
}

if (-not $PythonCmd) {
    Write-Host "Error: Could not locate 64-bit Python 3.9 - 3.12 on your Windows system." -ForegroundColor Red
    Write-Host "Please install Python 3.11 (64-bit) from https://www.python.org/downloads/"
    Write-Host "Important: Be sure to check 'Add python.exe to PATH' during installation." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Found Python: $PythonCmd" -ForegroundColor Green

# ------------------------------------------------------------------------------
# 3. Create or Locate Virtual Environment
# ------------------------------------------------------------------------------
Write-Host "`n[3/6] Setting Up Virtual Environment..." -ForegroundColor Blue
if (-not (Test-Path $VenvDir)) {
    Write-Host "  Creating venv at $VenvDir..."
    cmd /c "$PythonCmd -m venv `"$VenvDir`""
} else {
    Write-Host "  Using existing venv at $VenvDir" -ForegroundColor Green
}

$VenvPython = Join-Path $VenvDir "Scripts\python.exe"

if (-not (Test-Path $VenvPython)) {
    Write-Host "Error: Virtual environment python binary not found at $VenvPython" -ForegroundColor Red
    exit 1
}

# Helper function to invoke python -m pip reliably on Windows
function Invoke-Pip {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Arguments,
        [switch]$IgnoreError
    )

    $prevAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    & $VenvPython -m pip @Arguments
    $code = $LASTEXITCODE

    $ErrorActionPreference = $prevAction

    if (-not $IgnoreError -and ($code -ne 0)) {
        $argList = $Arguments -join ' '
        throw "pip command failed with exit code $code. Executed: pip $argList"
    }
    return $code
}

# # Clean up any leftover temporary folders from prior interrupted pip installs (e.g. ~ip)
$sitePackages = Join-Path $VenvDir "Lib\site-packages"
if (Test-Path $sitePackages) {
    Get-ChildItem -Path $sitePackages -Filter "~*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Upgrade pip, setuptools, wheel using python.exe -m pip (prevents Windows file lock on pip.exe)
Write-Host "  Upgrading pip, setuptools, and wheel..."
Invoke-Pip -Arguments @("install", "--upgrade", "pip", "setuptools", "wheel") -IgnoreError | Out-Null

# ------------------------------------------------------------------------------
# 4. Install PaddlePaddle & PaddleOCR
# ------------------------------------------------------------------------------
Write-Host "`n[4/6] Installing PaddlePaddle & PaddleOCR Dependencies..." -ForegroundColor Blue

$paddleInstalled = $false

if ($HasGpu -and ($Device -eq "gpu")) {
    Write-Host "  NVIDIA GPU detected ($gpuName). Attempting to install paddlepaddle-gpu for CUDA..." -ForegroundColor Green

    # Detect Python tag (e.g. cp311, cp310, cp312)
    $pyTag = (& $VenvPython -c "import sys; print(f'cp{sys.version_info.major}{sys.version_info.minor}')").Trim()
    Write-Host "  Python ABI tag: $pyTag" -ForegroundColor Cyan

    # Remove CPU paddlepaddle first if previously installed to avoid distribution collisions
    Invoke-Pip -Arguments @("uninstall", "-y", "paddlepaddle") -IgnoreError | Out-Null

    # Strategy 1: Official PaddlePaddle index with trusted hosts
    $cudaIndexUrls = @(
        "https://www.paddlepaddle.org.cn/packages/stable/cu126/",
        "https://www.paddlepaddle.org.cn/packages/stable/cu118/"
    )

    foreach ($indexUrl in $cudaIndexUrls) {
        Write-Host "  Trying CUDA index: $indexUrl" -ForegroundColor Cyan
        $res = Invoke-Pip -Arguments @("install", "paddlepaddle-gpu", "-i", $indexUrl, "--trusted-host", "www.paddlepaddle.org.cn", "--trusted-host", "paddle-whl.cdn.bcebos.com") -IgnoreError
        if ($res -eq 0) {
            $paddleInstalled = $true
            $Device = "gpu"
            Write-Host "  paddlepaddle-gpu installed successfully via $indexUrl!" -ForegroundColor Green
            break
        }
    }

    # Strategy 2: Direct pre-compiled wheel download from CDN with auto-resume progress bar
    if (-not $paddleInstalled) {
        Write-Host "`n  Downloading pre-compiled CUDA 12 wheel for RTX 2050..." -ForegroundColor Cyan
        $directWheels = @(
            "https://paddle-whl.cdn.bcebos.com/stable/cu126/paddlepaddle-gpu/paddlepaddle_gpu-3.3.1-$pyTag-$pyTag-win_amd64.whl",
            "https://paddle-whl.cdn.bcebos.com/stable/cu118/paddlepaddle-gpu/paddlepaddle_gpu-3.3.1-$pyTag-$pyTag-win_amd64.whl"
        )

        foreach ($wheelUrl in $directWheels) {
            $wheelFileName = [System.IO.Path]::GetFileName($wheelUrl)
            $localWheelPath = Join-Path $ProjectRoot $wheelFileName

            Write-Host "`n  Target: $wheelFileName (~580 MB)" -ForegroundColor Cyan
            Write-Host "  Source: $wheelUrl" -ForegroundColor Gray
            Write-Host "  Progress:" -ForegroundColor Yellow

            $downloadSuccess = $false
            $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue

            if ($curlCmd) {
                # Resilient auto-resume loop: if network flickers, resume from existing bytes
                $maxAttempts = 15
                $attempt = 0

                while ($attempt -lt $maxAttempts) {
                    $attempt++
                    & curl.exe -# -L -C - --retry 3 --retry-delay 2 -o "$localWheelPath" "$wheelUrl"

                    if ((Test-Path "$localWheelPath") -and ($LASTEXITCODE -eq 0) -and ((Get-Item "$localWheelPath").Length -ge 500000000)) {
                        $downloadSuccess = $true
                        break
                    }

                    $currentBytes = if (Test-Path "$localWheelPath") { (Get-Item "$localWheelPath").Length } else { 0 }
                    $currentMB = [math]::Round($currentBytes / 1MB, 1)

                    if ($attempt -lt $maxAttempts) {
                        Write-Host "  [Notice] Connection interrupted at ${currentMB} MB. Auto-resuming from where it left off (Attempt $attempt of $maxAttempts)..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                    }
                }
            } else {
                # Fallback to PowerShell WebRequest
                try {
                    Invoke-WebRequest -Uri $wheelUrl -OutFile "$localWheelPath"
                    if ((Test-Path "$localWheelPath") -and ((Get-Item "$localWheelPath").Length -ge 550000000)) {
                        $downloadSuccess = $true
                    }
                } catch {
                    Write-Host "  Download error: $_" -ForegroundColor Yellow
                }
            }

            if ($downloadSuccess) {
                Write-Host "`n  Download 100% completed! Installing CUDA wheel into virtual environment..." -ForegroundColor Green
                $res = Invoke-Pip -Arguments @("install", "$localWheelPath") -IgnoreError
                if ($res -eq 0) {
                    $paddleInstalled = $true
                    $Device = "gpu"
                    Write-Host "  paddlepaddle-gpu installed successfully with CUDA acceleration!" -ForegroundColor Green
                    Remove-Item "$localWheelPath" -Force -ErrorAction SilentlyContinue
                    break
                } else {
                    Write-Host "  Wheel installation returned exit code $res. Trying next wheel candidate..." -ForegroundColor Yellow
                }
                Remove-Item "$localWheelPath" -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "  Could not complete download from $wheelUrl" -ForegroundColor Yellow
                if (Test-Path "$localWheelPath") {
                    Remove-Item "$localWheelPath" -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if (-not $paddleInstalled) {
        Write-Host "  Could not install GPU wheels from CUDA repositories. Falling back to CPU mode..." -ForegroundColor Yellow
    }
}

# Install CPU mode if GPU was skipped or failed
if (-not $paddleInstalled) {
    Write-Host "  Installing paddlepaddle (CPU mode)..." -ForegroundColor Cyan
    Invoke-Pip -Arguments @("install", "paddlepaddle")
    $Device = "cpu"
    Write-Host "  paddlepaddle (CPU mode) installed successfully!" -ForegroundColor Green
}

# Install PaddleOCR doc-parser, paddlex, and pypdfium2
Write-Host "  Installing paddleocr[doc-parser], paddlex, and pypdfium2..." -ForegroundColor Cyan
Invoke-Pip -Arguments @("install", "paddleocr[doc-parser]>=3.6.0", "paddlex>=3.7.0", "pypdfium2>=5.0.0")

# Install project dependencies if requirements.txt exists
$ReqFile = Join-Path $ProjectRoot "requirements.txt"
if (Test-Path $ReqFile) {
    Write-Host "  Installing project requirements from requirements.txt..." -ForegroundColor Cyan
    Invoke-Pip -Arguments @("install", "-r", $ReqFile)
}

# ------------------------------------------------------------------------------
# 5. Configure .env Environment File
# ------------------------------------------------------------------------------
Write-Host "`n[5/6] Configuring Application Environment (.env)..." -ForegroundColor Blue
$EnvFile = Join-Path $ProjectRoot ".env"
$EnvExample = Join-Path $ProjectRoot ".env.example"

if (-not (Test-Path $EnvFile) -and (Test-Path $EnvExample)) {
    Write-Host "  Creating .env from .env.example..."
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

    Write-Host "  .env configured successfully for local PaddleOCR ($Device):" -ForegroundColor Green
    Write-Host "    OCR_PROVIDER=`"paddleocr_vl`""
    Write-Host "    PADDLEOCR_VL_BACKEND=`"local`""
    Write-Host "    PADDLEOCR_VL_DEVICE=`"$Device`""
    Write-Host "    PADDLEOCR_VL_TIMEOUT_SECONDS=180"
} else {
    Write-Host "  Skipping .env update as requested (-SkipEnv)." -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
# 6. Verification and Model Download
# ------------------------------------------------------------------------------
Write-Host "`n[6/6] Verifying Installation & Pre-Downloading Models..." -ForegroundColor Blue

$verifyCode = @"
import sys
try:
    import paddle
    from paddleocr import PaddleOCRVL
    print('  PaddlePaddle Version :', paddle.__version__)
    print('  Paddle Device         :', paddle.device.get_device())
    print('  CUDA Available        :', paddle.is_compiled_with_cuda())
    print('  PaddleOCRVL Class     : Loaded successfully')
except Exception as e:
    print('Verification Error:', e, file=sys.stderr)
    sys.exit(1)
"@

$prevAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $VenvPython -c $verifyCode
$vCode = $LASTEXITCODE
$ErrorActionPreference = $prevAction

if ($vCode -ne 0) {
    Write-Host "`nVerification FAILED! Please inspect errors above." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n  Verification PASSED!" -ForegroundColor Green
}

if (-not $NoDownloadModels) {
    Write-Host "`nPre-downloading PaddleOCR-VL-1.6 & PP-DocLayoutV3 models (~1.9 GB)..." -ForegroundColor Blue
    Write-Host "This will cache the model files locally in %USERPROFILE%\.paddlex\official_models" -ForegroundColor Cyan

    $downloadCode = @"
import sys
import paddle
from paddleocr import PaddleOCRVL

dev = '$Device'
try:
    paddle.device.set_device(dev)
except Exception as e:
    print(f'Notice: Could not activate {dev} device ({e}). Falling back to cpu for caching.')
    dev = 'cpu'
    paddle.device.set_device('cpu')

print(f'Initializing PaddleOCRVL (device={dev}) to trigger weight download/cache...')
pipeline = PaddleOCRVL(pipeline_version='v1.6', device=dev)
print('Model download and caching complete!')
"@

    $ErrorActionPreference = "Continue"
    & $VenvPython -c $downloadCode
    $ErrorActionPreference = $prevAction
}

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  PaddleOCR-VL-1.6 Windows Setup Completed Successfully!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "`nTo start services on Windows:" -ForegroundColor Cyan
Write-Host "  1. Start Redis & PostgreSQL (e.g. via Docker Desktop):"
Write-Host "     docker compose up -d redis db" -ForegroundColor Yellow
Write-Host "`n  2. Start Celery Worker (Note: Windows requires -P solo):"
Write-Host "     .\venv\Scripts\celery.exe -A app.core.celery_app worker --loglevel=info -P solo" -ForegroundColor Yellow
Write-Host "`n  3. Start FastAPI Server:"
Write-Host "     .\venv\Scripts\uvicorn.exe app.main:app --host 0.0.0.0 --port 9000 --reload" -ForegroundColor Yellow
Write-Host "`n  4. Open Web Dashboard:"
Write-Host "     http://localhost:9000" -ForegroundColor Green
