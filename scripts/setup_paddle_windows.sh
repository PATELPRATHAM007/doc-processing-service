#!/usr/bin/env bash
# ==============================================================================
# PaddleOCR-VL-1.6 & PaddlePaddle Windows PC Setup Script
# Compatible with: Git Bash, MSYS2, MinGW, Cygwin, and WSL on Windows
# ==============================================================================

set -eo pipefail

# Text styling
BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Determine script and project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PROJECT_ROOT}/venv"

# Default flags
FORCE_CPU=0
FORCE_GPU=0
DOWNLOAD_MODELS=1
SKIP_ENV_UPDATE=0

print_banner() {
    echo -e "${BLUE}${BOLD}"
    echo "=================================================================="
    echo "   PaddleOCR-VL-1.6 & PaddlePaddle Windows PC Setup Script"
    echo "   Environment: Git Bash / MSYS2 / MinGW / Windows"
    echo "=================================================================="
    echo -e "${NC}"
}

print_help() {
    echo "Usage: ./scripts/setup_paddle_windows.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --no-download-models Do NOT pre-download model weights (models download on first run)"
    echo "  --cpu                Force CPU-only installation (paddlepaddle)"
    echo "  --gpu                Force NVIDIA GPU installation (paddlepaddle-gpu)"
    echo "  --skip-env           Do not automatically update .env file"
    echo "  -h, --help           Show this help message"
    echo ""
    exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-download-models)
            DOWNLOAD_MODELS=0
            shift
            ;;
        --cpu)
            FORCE_CPU=1
            shift
            ;;
        --gpu)
            FORCE_GPU=1
            shift
            ;;
        --skip-env)
            SKIP_ENV_UPDATE=1
            shift
            ;;
        -h|--help)
            print_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_help
            ;;
    esac
done

print_banner

# ------------------------------------------------------------------------------
# 1. Detect Windows Environment & Hardware
# ------------------------------------------------------------------------------
echo -e "${BLUE}[1/6] Detecting Windows Environment & Architecture...${NC}"

UNAME_OUT="$(uname -s 2>/dev/null || echo "Windows")"
ARCH_TYPE="$(uname -m 2>/dev/null || echo "x86_64")"

echo -e "  Shell Platform : ${GREEN}${UNAME_OUT}${NC}"
echo -e "  Architecture   : ${GREEN}${ARCH_TYPE}${NC}"

HAS_GPU=0
DETECTED_DEVICE="cpu"

# Check for NVIDIA GPU via nvidia-smi
NVIDIA_SMI_CMD=""
if command -v nvidia-smi &>/dev/null; then
    NVIDIA_SMI_CMD="nvidia-smi"
elif command -v nvidia-smi.exe &>/dev/null; then
    NVIDIA_SMI_CMD="nvidia-smi.exe"
elif [ -f "/c/Program Files/NVIDIA Corporation/NVSMI/nvidia-smi.exe" ]; then
    NVIDIA_SMI_CMD="/c/Program Files/NVIDIA Corporation/NVSMI/nvidia-smi.exe"
fi

if [ -n "${NVIDIA_SMI_CMD}" ]; then
    GPU_NAME=$("${NVIDIA_SMI_CMD}" --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || echo "NVIDIA GPU")
    echo -e "  GPU Status     : ${GREEN}Detected ${GPU_NAME}${NC}"
    HAS_GPU=1
    DETECTED_DEVICE="gpu"
else
    echo -e "  GPU Status     : ${YELLOW}No NVIDIA GPU detected (using CPU mode)${NC}"
    DETECTED_DEVICE="cpu"
fi

# Apply user overrides
if [[ ${FORCE_CPU} -eq 1 ]]; then
    DETECTED_DEVICE="cpu"
    HAS_GPU=0
    echo -e "  Override       : ${YELLOW}Forcing CPU mode${NC}"
elif [[ ${FORCE_GPU} -eq 1 ]]; then
    DETECTED_DEVICE="gpu"
    HAS_GPU=1
    echo -e "  Override       : ${GREEN}Forcing GPU mode (CUDA)${NC}"
fi

# ------------------------------------------------------------------------------
# 2. Find Windows Python Executable (Python 3.9 - 3.12 64-bit)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[2/6] Locating 64-bit Python for Windows...${NC}"

PYTHON_CANDIDATES=(
    "py -3.11"
    "py -3.10"
    "py -3.12"
    "python3.11"
    "python3"
    "python"
)

SYSTEM_PYTHON=""
for candidate in "${PYTHON_CANDIDATES[@]}"; do
    if ${candidate} -c "import sys; exit(0 if sys.version_info >= (3, 9) and sys.version_info < (3, 13) and sys.maxsize > 2**32 else 1)" 2>/dev/null; then
        SYSTEM_PYTHON="${candidate}"
        break
    fi
done

if [ -z "${SYSTEM_PYTHON}" ]; then
    echo -e "${RED}Error: Could not find a compatible 64-bit Python 3.9 - 3.12 installation on your Windows system.${NC}"
    echo -e "Please install Python 3.11 (64-bit) from ${BOLD}https://www.python.org/downloads/${NC}"
    echo -e "${YELLOW}Important: Check the box 'Add python.exe to PATH' during installation.${NC}"
    exit 1
fi

PY_INFO=$(${SYSTEM_PYTHON} -c "import sys, platform; print(f'{platform.python_version()} ({platform.architecture()[0]})')")
echo -e "  Found Python   : ${GREEN}${SYSTEM_PYTHON} -> ${PY_INFO}${NC}"

# ------------------------------------------------------------------------------
# 3. Create or Locate Virtual Environment
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/6] Setting Up Python Virtual Environment...${NC}"

if [ ! -d "${VENV_DIR}" ]; then
    echo "  Creating virtual environment at: ${VENV_DIR}..."
    ${SYSTEM_PYTHON} -m venv "${VENV_DIR}"
else
    echo -e "  Using existing virtual environment at: ${GREEN}${VENV_DIR}${NC}"
fi

# Resolve Windows venv executable paths
if [ -f "${VENV_DIR}/Scripts/python.exe" ]; then
    VENV_PYTHON="${VENV_DIR}/Scripts/python.exe"
    VENV_PIP="${VENV_DIR}/Scripts/pip.exe"
elif [ -f "${VENV_DIR}/Scripts/python" ]; then
    VENV_PYTHON="${VENV_DIR}/Scripts/python"
    VENV_PIP="${VENV_DIR}/Scripts/pip"
elif [ -f "${VENV_DIR}/bin/python" ]; then
    VENV_PYTHON="${VENV_DIR}/bin/python"
    VENV_PIP="${VENV_DIR}/bin/pip"
else
    echo -e "${RED}Error: Virtual environment python binary not found under ${VENV_DIR}${NC}"
    exit 1
fi

echo -e "  Venv Python    : ${GREEN}${VENV_PYTHON}${NC}"

# Upgrade pip, setuptools, wheel using python -m pip (avoids Windows pip.exe file-lock)
echo "  Upgrading pip, setuptools, and wheel..."
"${VENV_PYTHON}" -m pip install --upgrade --quiet pip setuptools wheel || true

# ------------------------------------------------------------------------------
# 4. Install PaddlePaddle & PaddleOCR Windows Packages
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/6] Installing PaddlePaddle & PaddleOCR Dependencies...${NC}"

# Clean up any leftover temporary folders from prior interrupted pip installs (e.g. ~ip)
find "${VENV_DIR}" -type d -name "~*" -exec rm -rf {} + 2>/dev/null || true

PADDLE_INSTALLED=0
if [[ "${DETECTED_DEVICE}" == "gpu" && "${HAS_GPU}" -eq 1 ]]; then
    echo -e "  Attempting to install ${BOLD}paddlepaddle-gpu${NC} for CUDA on Windows..."

    # Purge any conflicting or split paddle installations
    "${VENV_PYTHON}" -m pip uninstall -y paddlepaddle paddlepaddle-gpu 2>/dev/null || true

    SITE_PACKAGES=$("${VENV_PYTHON}" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "${VENV_DIR}/Lib/site-packages")
    PADDLE_DIR="${SITE_PACKAGES}/paddle"
    if [ -d "${PADDLE_DIR}" ] && [ ! -f "${PADDLE_DIR}/__init__.py" ]; then
        echo -e "  ${YELLOW}Removing zombie broken paddle directory: ${PADDLE_DIR}...${NC}"
        rm -rf "${PADDLE_DIR}" 2>/dev/null || true
    fi
    rm -rf "${SITE_PACKAGES}"/*paddlepaddle*.dist-info 2>/dev/null || true

    PY_TAG=$("${VENV_PYTHON}" -c "import sys; print(f'cp{sys.version_info.major}{sys.version_info.minor}')")

    # Direct pre-compiled wheel installation from local cache or CDN
    echo -e "\n  Setting up pre-compiled CUDA 12 wheel for RTX 2050..."
    DIRECT_WHEELS=(
        "https://paddle-whl.cdn.bcebos.com/stable/cu126/paddlepaddle-gpu/paddlepaddle_gpu-3.3.1-${PY_TAG}-${PY_TAG}-win_amd64.whl"
    )

    for wheel_url in "${DIRECT_WHEELS[@]}"; do
        wheel_name="$(basename "${wheel_url}")"
        local_wheel="${PROJECT_ROOT}/${wheel_name}"
        download_success=0

        if [ -f "${local_wheel}" ]; then
            file_size=$(wc -c < "${local_wheel}" | tr -d ' ')
            if [ "${file_size}" -ge 500000000 ]; then
                echo -e "  ${GREEN}Found existing cached wheel (${wheel_name}, $(( file_size / 1048576 )) MB). Skipping download!${NC}"
                download_success=1
            fi
        fi

        if [[ ${download_success} -eq 0 ]]; then
            echo -e "  Target: ${wheel_name} (~580 MB)..."
            attempt=0
            max_attempts=15

            while [[ ${attempt} -lt ${max_attempts} ]]; do
                attempt=$((attempt + 1))
                curl -# -L -C - --retry 3 --retry-delay 2 -o "${local_wheel}" "${wheel_url}" || true

                if [ -f "${local_wheel}" ]; then
                    file_size=$(wc -c < "${local_wheel}" | tr -d ' ')
                    if [ "${file_size}" -ge 500000000 ]; then
                        download_success=1
                        break
                    fi
                fi

                if [ ${attempt} -lt ${max_attempts} ]; then
                    echo -e "  ${YELLOW}[Notice] Connection interrupted. Auto-resuming from where it left off (Attempt ${attempt} of ${max_attempts})...${NC}"
                    sleep 2
                fi
            done
        fi

        if [[ ${download_success} -eq 1 ]]; then
            echo -e "  Installing CUDA wheel into venv..."
            "${VENV_PYTHON}" -m pip install --no-cache-dir --force-reinstall "${local_wheel}" || true

            PADDLE_INIT="${SITE_PACKAGES}/paddle/__init__.py"
            if [ ! -f "${PADDLE_INIT}" ]; then
                echo -e "  ${YELLOW}Extracting paddle package files from wheel archive directly into site-packages...${NC}"
                "${VENV_PYTHON}" -c "
import zipfile
with zipfile.ZipFile(r'${local_wheel}', 'r') as z:
    for m in z.namelist():
        if m.startswith('paddle/') or m.startswith('paddle\\\\'):
            z.extract(m, r'${SITE_PACKAGES}')
print('Direct package extraction complete!')
"
            fi

            if [ -f "${PADDLE_INIT}" ]; then
                PADDLE_INSTALLED=1
                echo -e "  ${GREEN}paddlepaddle-gpu verified successfully on disk with CUDA acceleration!${NC}"
                break
            fi
        fi
    done

    if [[ ${PADDLE_INSTALLED} -eq 0 ]]; then
        echo -e "${YELLOW}Warning: paddlepaddle-gpu install failed. Falling back to CPU mode...${NC}"
    fi
fi

if [[ ${PADDLE_INSTALLED} -eq 0 ]]; then
    echo -e "  Installing ${BOLD}paddlepaddle${NC} (CPU mode)..."
    "${VENV_PYTHON}" -m pip install paddlepaddle
    DETECTED_DEVICE="cpu"
fi

echo "  Installing paddleocr[doc-parser], paddlex, and pypdfium2..."
"${VENV_PYTHON}" -m pip install "paddleocr[doc-parser]>=3.6.0" "paddlex>=3.7.0" "pypdfium2>=5.0.0"

# Install main requirements if present
if [ -f "${PROJECT_ROOT}/requirements.txt" ]; then
    echo "  Installing project requirements from requirements.txt..."
    "${VENV_PYTHON}" -m pip install -r "${PROJECT_ROOT}/requirements.txt" --quiet
fi

# ------------------------------------------------------------------------------
# 5. Configure .env Environment File for Windows
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[5/6] Configuring Application Environment (.env)...${NC}"

ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"

if [ ! -f "${ENV_FILE}" ]; then
    if [ -f "${ENV_EXAMPLE}" ]; then
        echo "  Creating .env from .env.example..."
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    else
        echo "  Creating new .env file..."
        touch "${ENV_FILE}"
    fi
fi

if [[ ${SKIP_ENV_UPDATE} -eq 0 ]]; then
    set_env_val() {
        local key="$1"
        local val="$2"
        if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
            sed -i.bak "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
        else
            echo "${key}=${val}" >> "${ENV_FILE}"
        fi
    }

    set_env_val "OCR_PROVIDER" "\"paddleocr_vl\""
    set_env_val "PADDLEOCR_VL_BACKEND" "\"local\""
    set_env_val "PADDLEOCR_VL_DEVICE" "\"${DETECTED_DEVICE}\""
    set_env_val "PADDLEOCR_VL_TIMEOUT_SECONDS" "180"

    echo -e "  ${GREEN}.env updated successfully:${NC}"
    echo "    OCR_PROVIDER=\"paddleocr_vl\""
    echo "    PADDLEOCR_VL_BACKEND=\"local\""
    echo "    PADDLEOCR_VL_DEVICE=\"${DETECTED_DEVICE}\""
    echo "    PADDLEOCR_VL_TIMEOUT_SECONDS=180"
else
    echo "  Skipping .env update as requested (--skip-env)."
fi

# ------------------------------------------------------------------------------
# 6. Verification and Model Download
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[6/6] Verifying Installation & Pre-Downloading Models...${NC}"

# Check and clean up any local files/folders shadowing the paddle package
if [ -f "${PROJECT_ROOT}/paddle.py" ]; then
    echo -e "  ${YELLOW}[Notice] Found local 'paddle.py' shadowing PaddlePaddle. Renaming to 'paddle_test.py'...${NC}"
    mv "${PROJECT_ROOT}/paddle.py" "${PROJECT_ROOT}/paddle_test.py"
fi
if [ -d "${PROJECT_ROOT}/paddle" ]; then
    echo -e "  ${YELLOW}[Notice] Found local 'paddle' directory shadowing PaddlePaddle. Renaming to 'paddle_local'...${NC}"
    mv "${PROJECT_ROOT}/paddle" "${PROJECT_ROOT}/paddle_local"
fi

VERIFY_CODE="
import sys, os
if '' in sys.path:
    sys.path.remove('')
if os.getcwd() in sys.path:
    sys.path.remove(os.getcwd())

try:
    import paddle
    print('  Paddle Module Path    :', getattr(paddle, '__file__', 'unknown'))

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
"

if "${VENV_PYTHON}" -c "${VERIFY_CODE}"; then
    echo -e "\n  ${GREEN}${BOLD}Verification PASSED!${NC}"
else
    echo -e "\n  ${RED}${BOLD}Verification FAILED! Please inspect the error messages above.${NC}"
    exit 1
fi

if [[ ${DOWNLOAD_MODELS} -eq 1 ]]; then
    echo -e "\n${BLUE}Pre-downloading PaddleOCR-VL-1.6 & PP-DocLayoutV3 models (~1.9 GB)...${NC}"

    MODEL_CACHE_DIR="${USERPROFILE:-$HOME}/.paddlex/official_models"
    if [ -d "${MODEL_CACHE_DIR}" ]; then
        echo -e "  ${GREEN}Detected existing cached models in ${MODEL_CACHE_DIR}:${NC}"
        for d in "${MODEL_CACHE_DIR}"/*; do
            if [ -d "${d}" ]; then
                d_size=$(du -sh "${d}" 2>/dev/null | cut -f1)
                echo -e "    - $(basename "${d}") (${d_size})"
            fi
        done
    fi

    "${VENV_PYTHON}" -c "
import sys, os
if '' in sys.path: sys.path.remove('')
if os.getcwd() in sys.path: sys.path.remove(os.getcwd())

import paddle
from paddleocr import PaddleOCRVL
device = '${DETECTED_DEVICE}'
try:
    paddle.device.set_device(device)
except Exception:
    paddle.device.set_device('cpu')
    device = 'cpu'

print(f'Initializing PaddleOCRVL (device={device}) to verify and cache models...')
pipeline = PaddleOCRVL(pipeline_version='v1.6', device=device)
print('Model verification and caching complete!')
"
fi

echo -e "\n${GREEN}${BOLD}==================================================================${NC}"
echo -e "${GREEN}${BOLD}  PaddleOCR-VL-1.6 Windows PC Setup Completed Successfully!       ${NC}"
echo -e "${GREEN}${BOLD}==================================================================${NC}"
echo ""
echo -e "${BOLD}To start the service on Windows:${NC}"
echo ""
echo -e "  1. Start Redis & PostgreSQL (e.g. via Docker Desktop):"
echo -e "     ${BOLD}docker compose up -d redis db${NC}"
echo ""
echo -e "  2. Start Celery Background Worker on Windows:"
echo -e "     ${YELLOW}Note: Windows requires '-P solo' or '-P threads' for Celery!${NC}"
echo -e "     Git Bash   : ${BOLD}./venv/Scripts/celery -A app.core.celery_app worker --loglevel=info -P solo${NC}"
echo -e "     PowerShell : ${BOLD}.\\venv\\Scripts\\celery.exe -A app.core.celery_app worker --loglevel=info -P solo${NC}"
echo ""
echo -e "  3. Start FastAPI Web Server:"
echo -e "     Git Bash   : ${BOLD}./venv/Scripts/uvicorn app.main:app --host 0.0.0.0 --port 9000 --reload${NC}"
echo -e "     PowerShell : ${BOLD}.\\venv\\Scripts\\uvicorn.exe app.main:app --host 0.0.0.0 --port 9000 --reload${NC}"
echo ""
echo -e "  4. Access the Dashboard in your browser:"
echo -e "     ${BOLD}http://localhost:9000${NC}"
echo ""
