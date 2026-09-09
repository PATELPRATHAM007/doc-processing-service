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
    # Uninstall cpu paddlepaddle if previously present
    "${VENV_PYTHON}" -m pip uninstall -y paddlepaddle 2>/dev/null || true

    CUDA_REPOS=(
        "https://www.paddlepaddle.org.cn/packages/stable/cu126/paddlepaddle-gpu/"
        "https://www.paddlepaddle.org.cn/packages/stable/cu118/paddlepaddle-gpu/"
        "https://www.paddlepaddle.org.cn/packages/stable/cu120/paddlepaddle-gpu/"
    )

    for repo in "${CUDA_REPOS[@]}"; do
        echo "  Trying CUDA wheel repository: ${repo}..."
        if "${VENV_PYTHON}" -m pip install paddlepaddle-gpu -f "${repo}"; then
            PADDLE_INSTALLED=1
            echo -e "  ${GREEN}paddlepaddle-gpu installed successfully!${NC}"
            break
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

VERIFY_CODE="
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
"

if "${VENV_PYTHON}" -c "${VERIFY_CODE}"; then
    echo -e "\n  ${GREEN}${BOLD}Verification PASSED!${NC}"
else
    echo -e "\n  ${RED}${BOLD}Verification FAILED! Please inspect the error messages above.${NC}"
    exit 1
fi

if [[ ${DOWNLOAD_MODELS} -eq 1 ]]; then
    echo -e "\n${BLUE}Pre-downloading PaddleOCR-VL-1.6 & PP-DocLayoutV3 models (~1.9 GB)...${NC}"
    echo "This may take a few minutes depending on your internet connection."
    "${VENV_PYTHON}" -c "
import paddle
from paddleocr import PaddleOCRVL
device = '${DETECTED_DEVICE}'
try:
    paddle.device.set_device(device)
except Exception:
    paddle.device.set_device('cpu')
    device = 'cpu'

print(f'Initializing PaddleOCRVL (device={device}) to trigger model caching...')
pipeline = PaddleOCRVL(pipeline_version='v1.6', device=device)
print('Model weights downloaded and cached successfully!')
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
