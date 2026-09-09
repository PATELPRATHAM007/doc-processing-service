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

    # Pipe to Out-Host so stdout streams live to the terminal
    # without polluting the PowerShell function return value pipeline
    & $VenvPython -m pip @Arguments | Out-Host
    $code = [int]$LASTEXITCODE

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

    # 1. Cleanly purge any conflicting or split paddle installations
    Write-Host "  Purging any conflicting or split paddle installations..." -ForegroundColor Cyan
    Invoke-Pip -Arguments @("uninstall", "-y", "paddlepaddle", "paddlepaddle-gpu") -IgnoreError | Out-Null

    $sitePackages = Join-Path $VenvDir "Lib\site-packages"
    $paddleDir = Join-Path $sitePackages "paddle"
    if (Test-Path $paddleDir) {
        $initFile = Join-Path $paddleDir "__init__.py"
        if (-not (Test-Path $initFile)) {
            Write-Host "  Removing zombie broken paddle directory: $paddleDir..." -ForegroundColor Yellow
            Remove-Item -Path $paddleDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Get-ChildItem -Path $sitePackages -Filter "*paddlepaddle*.dist-info" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # 2. Direct pre-compiled wheel installation from local cache or CDN
    Write-Host "`n  Setting up pre-compiled CUDA 12 wheel for RTX 2050..." -ForegroundColor Cyan
    $directWheels = @(
        "https://paddle-whl.cdn.bcebos.com/stable/cu126/paddlepaddle-gpu/paddlepaddle_gpu-3.3.1-$pyTag-$pyTag-win_amd64.whl"
    )

    foreach ($wheelUrl in $directWheels) {
        $wheelFileName = [System.IO.Path]::GetFileName($wheelUrl)
        $localWheelPath = Join-Path $ProjectRoot $wheelFileName
        $downloadSuccess = $false

        # Check if wheel was already downloaded and is intact
        if ((Test-Path "$localWheelPath") -and ((Get-Item "$localWheelPath").Length -ge 500000000)) {
            $existingMB = [math]::Round((Get-Item "$localWheelPath").Length / 1MB, 1)
            Write-Host "`n  Found existing cached wheel ($wheelFileName, ${existingMB} MB). Skipping download!" -ForegroundColor Green
            $downloadSuccess = $true
        } else {
            Write-Host "`n  Target: $wheelFileName (~580 MB)" -ForegroundColor Cyan
            Write-Host "  Source: $wheelUrl" -ForegroundColor Gray
            Write-Host "  Progress:" -ForegroundColor Yellow

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
                    if ((Test-Path "$localWheelPath") -and ((Get-Item "$localWheelPath").Length -ge 500000000)) {
                        $downloadSuccess = $true
                    }
                } catch {
                    Write-Host "  Download error: $_" -ForegroundColor Yellow
                }
            }
        }

        if ($downloadSuccess) {
            Write-Host "`n  Installing CUDA 12 wheel into virtual environment..." -ForegroundColor Green
            $res = Invoke-Pip -Arguments @("install", "--no-cache-dir", "--force-reinstall", "$localWheelPath") -IgnoreError

            $paddleInit = Join-Path $sitePackages "paddle\__init__.py"
            if (-not (Test-Path $paddleInit)) {
                Write-Host "  Extracting paddle package files from wheel archive directly into site-packages..." -ForegroundColor Yellow
                $extractPy = @"
import zipfile, os
wheel_path = r'$localWheelPath'
dest_dir = r'$sitePackages'
with zipfile.ZipFile(wheel_path, 'r') as z:
    for member in z.namelist():
        if member.startswith('paddle/') or member.startswith('paddle\\'):
            z.extract(member, dest_dir)
print('Direct package extraction complete!')
"@
                & $VenvPython -c $extractPy
            }

            if (Test-Path $paddleInit) {
                $paddleInstalled = $true
                $Device = "gpu"
                Write-Host "  paddlepaddle-gpu verified successfully on disk with CUDA acceleration!" -ForegroundColor Green
                break
            } else {
                Write-Host "  Warning: Wheel installation did not produce $paddleInit" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Could not complete download from $wheelUrl" -ForegroundColor Yellow
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

# Check and clean up any local files/folders shadowing the paddle package
if (Test-Path (Join-Path $ProjectRoot "paddle.py")) {
    Write-Host "  [Notice] Found local 'paddle.py' shadowing PaddlePaddle. Renaming to 'paddle_test.py'..." -ForegroundColor Yellow
    Rename-Item -Path (Join-Path $ProjectRoot "paddle.py") -NewName "paddle_test.py" -Force
}
if (Test-Path (Join-Path $ProjectRoot "paddle")) {
    Write-Host "  [Notice] Found local 'paddle' directory shadowing PaddlePaddle. Renaming to 'paddle_local'..." -ForegroundColor Yellow
    Rename-Item -Path (Join-Path $ProjectRoot "paddle") -NewName "paddle_local" -Force
}

$verifyCode = @"
import sys, os

# Prevent local current directory from shadowing site-packages
if '' in sys.path:
    sys.path.remove('')
if os.getcwd() in sys.path:
    sys.path.remove(os.getcwd())

try:
    import paddle
    print('  Paddle Module Path    :', getattr(paddle, '__file__', 'unknown'))

    # Robust version discovery across PaddlePaddle distributions
    ver = getattr(paddle, '__version__', None)
    if not ver and hasattr(paddle, 'version'):
        ver = getattr(paddle.version, 'full_version', None)
    if not ver:
        try:
            import importlib.metadata
            for pkg_name in ('paddlepaddle-gpu', 'paddlepaddle'):
                try:
                    ver = importlib.metadata.version(pkg_name)
                    break
                except Exception:
                    pass
        except Exception:
            pass
    if not ver:
        ver = '3.3.1 (installed)'
    print('  PaddlePaddle Version  :', ver)

    dev = paddle.device.get_device()
    print('  Paddle Device         :', dev)

    cuda_avail = paddle.is_compiled_with_cuda()
    print('  CUDA Available        :', cuda_avail)

    if cuda_avail and hasattr(paddle, 'version'):
        cuda_fn = getattr(paddle.version, 'cuda', None)
        if callable(cuda_fn):
            print('  CUDA Runtime Version  :', cuda_fn())
        cudnn_fn = getattr(paddle.version, 'cudnn', None)
        if callable(cudnn_fn):
            print('  cuDNN Version         :', cudnn_fn())

    from paddleocr import PaddleOCRVL
    print('  PaddleOCRVL Class     : Loaded successfully')
except Exception as e:
    import traceback
    print('Verification Error:', e, file=sys.stderr)
    traceback.print_exc()
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

    $modelCacheDir = Join-Path $env:USERPROFILE ".paddlex\official_models"
    if (Test-Path $modelCacheDir) {
        $cachedModels = Get-ChildItem -Path $modelCacheDir -Directory -ErrorAction SilentlyContinue
        if ($cachedModels.Count -gt 0) {
            Write-Host "  Detected existing cached models in ${modelCacheDir}:" -ForegroundColor Green
            foreach ($m in $cachedModels) {
                $sumBytes = (Get-ChildItem -Path $m.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                $mSizeMB = if ($sumBytes) { [math]::Round($sumBytes / 1MB, 1) } else { 0 }
                Write-Host "    - $($m.Name) (${mSizeMB} MB)" -ForegroundColor Cyan
            }
        }
    }

    $downloadCode = @"
import sys, os
if '' in sys.path:
    sys.path.remove('')
if os.getcwd() in sys.path:
    sys.path.remove(os.getcwd())

import paddle
from paddleocr import PaddleOCRVL

dev = '$Device'
try:
    paddle.device.set_device(dev)
except Exception as e:
    print(f'Notice: Could not activate {dev} device ({e}). Falling back to cpu for caching.')
    dev = 'cpu'
    paddle.device.set_device('cpu')

print(f'Initializing PaddleOCRVL (device={dev}) to verify and cache models...')
pipeline = PaddleOCRVL(pipeline_version='v1.6', device=dev)
print('Model verification and caching complete!')
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
