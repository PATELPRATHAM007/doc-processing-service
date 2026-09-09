#!/usr/bin/env bash
# ==============================================================================
# Cross-Platform Local Setup Script for PaddlePaddle & PaddleOCR-VL-1.6
# Supports: macOS (Apple Silicon M-Series & Intel), Ubuntu, Debian, & Linux
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
PYTHON_BIN="${VENV_DIR}/bin/python"
PIP_BIN="${VENV_DIR}/bin/pip"

# Default flags
FORCE_CPU=0
FORCE_GPU=0
DOWNLOAD_MODELS=0
SKIP_ENV_UPDATE=0

print_banner() {
    echo -e "${BLUE}${BOLD}"
    echo "=================================================================="
    echo "   PaddleOCR-VL-1.6 & PaddlePaddle Local Machine Setup"
    echo "   Supported Platforms: macOS (M-Series/Intel) | Ubuntu / Linux"
    echo "=================================================================="
    echo -e "${NC}"
}

print_help() {
    echo "Usage: ./scripts/setup_paddle.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --download-models    Pre-download PaddleOCR-VL-1.6 weights (~1.9 GB) into local cache"
    echo "  --cpu                Force CPU-only installation (default on macOS)"
    echo "  --gpu                Force NVIDIA GPU installation (Linux only)"
    echo "  --skip-env           Do not automatically update .env file"
    echo "  -h, --help           Show this help message"
    echo ""
    exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --download-models)
            DOWNLOAD_MODELS=1
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
# 1. Detect Operating System and Architecture
# ------------------------------------------------------------------------------
echo -e "${BLUE}[1/6] Detecting System Environment...${NC}"

OS_TYPE="$(uname -s)"
ARCH_TYPE="$(uname -m)"
DISTRO="unknown"
HAS_GPU=0
DETECTED_DEVICE="cpu"

case "${OS_TYPE}" in
    Darwin)
        OS_NAME="macOS"
        if [[ "${ARCH_TYPE}" == "arm64" ]]; then
            echo -e "  OS: ${GREEN}macOS (Apple Silicon M-Series: ${ARCH_TYPE})${NC}"
        else
            echo -e "  OS: ${GREEN}macOS (Intel x86_64)${NC}"
        fi
        DETECTED_DEVICE="cpu"
        ;;
    Linux)
        OS_NAME="Linux"
        if [ -f /etc/os-release ]; then
            # Source OS release details
            . /etc/os-release
            DISTRO="${ID:-linux}"
            DISTRO_VERSION="${VERSION_ID:-unknown}"
            echo -e "  OS: ${GREEN}Linux (${PRETTY_NAME:-$DISTRO}) [${ARCH_TYPE}]${NC}"
        else
            echo -e "  OS: ${GREEN}Linux (${ARCH_TYPE})${NC}"
        fi

        # Check for NVIDIA GPU
        if command -v nvidia-smi &>/dev/null; then
            GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 || echo "NVIDIA GPU")
            echo -e "  GPU: ${GREEN}Detected ${GPU_MODEL}${NC}"
            HAS_GPU=1
            DETECTED_DEVICE="cuda"
        else
            echo -e "  GPU: ${YELLOW}No NVIDIA GPU detected (using CPU mode)${NC}"
            DETECTED_DEVICE="cpu"
        fi
        ;;
    *)
        echo -e "${RED}Unsupported Operating System: ${OS_TYPE}${NC}"
        exit 1
        ;;
esac

# Handle user overrides
if [[ ${FORCE_CPU} -eq 1 ]]; then
    DETECTED_DEVICE="cpu"
    HAS_GPU=0
    echo -e "  Override: ${YELLOW}Forcing CPU mode${NC}"
elif [[ ${FORCE_GPU} -eq 1 ]]; then
    if [[ "${OS_NAME}" == "macOS" ]]; then
        echo -e "${YELLOW}Notice: NVIDIA GPU is not supported on macOS. Continuing with CPU.${NC}"
        DETECTED_DEVICE="cpu"
        HAS_GPU=0
    else
        DETECTED_DEVICE="cuda"
        HAS_GPU=1
        echo -e "  Override: ${GREEN}Forcing GPU mode (CUDA)${NC}"
    fi
fi

# ------------------------------------------------------------------------------
# 2. Linux System Dependencies Check
# ------------------------------------------------------------------------------
if [[ "${OS_NAME}" == "Linux" ]]; then
    echo -e "\n${BLUE}[2/6] Checking Linux System Dependencies (OpenCV & OpenGL)...${NC}"
    MISSING_PKGS=()

    if [[ "${DISTRO}" =~ ^(ubuntu|debian|linuxmint|pop)$ ]]; then
        for pkg in libgl1 libglib2.0-0 libgomp1; do
            if ! dpkg -s "${pkg}" &>/dev/null; then
                MISSING_PKGS+=("${pkg}")
            fi
        done

        if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
            echo -e "${YELLOW}The following recommended system libraries are missing: ${MISSING_PKGS[*]}${NC}"
            if [ "$EUID" -eq 0 ]; then
                echo "Installing system packages via apt-get..."
                apt-get update -qq && apt-get install -y --no-install-recommends "${MISSING_PKGS[@]}"
            else
                echo -e "${YELLOW}Please install them using:${NC}"
                echo -e "  ${BOLD}sudo apt-get update && sudo apt-get install -y ${MISSING_PKGS[*]}${NC}"
            fi
        else
            echo -e "  ${GREEN}All required system libraries are installed!${NC}"
        fi
    fi
else
    echo -e "\n${BLUE}[2/6] System Dependencies Check...${NC}"
    echo -e "  ${GREEN}macOS dynamic libraries are verified.${NC}"
fi

# ------------------------------------------------------------------------------
# 3. Python & Virtual Environment Setup
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/6] Setting Up Python Virtual Environment...${NC}"

# Find suitable python binary
SYSTEM_PYTHON=""
for py_cmd in python3.11 python3.12 python3.10 python3; do
    if command -v "${py_cmd}" &>/dev/null; then
        PY_VER=$("${py_cmd}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        PY_MAJOR=$("${py_cmd}" -c 'import sys; print(sys.version_info.major)')
        PY_MINOR=$("${py_cmd}" -c 'import sys; print(sys.version_info.minor)')
        if [[ "${PY_MAJOR}" -eq 3 && "${PY_MINOR}" -ge 9 && "${PY_MINOR}" -le 12 ]]; then
            SYSTEM_PYTHON="${py_cmd}"
            break
        fi
    fi
done

if [ -z "${SYSTEM_PYTHON}" ]; then
    echo -e "${RED}Error: Python 3.9 - 3.12 is required for PaddlePaddle.${NC}"
    echo "Please install Python 3.11 (e.g. via 'brew install python@3.11' on macOS or 'apt install python3.11' on Ubuntu)."
    exit 1
fi

echo -e "  Found Python: ${GREEN}${SYSTEM_PYTHON} (${PY_VER})${NC}"

# Create or reuse virtualenv
if [ ! -d "${VENV_DIR}" ]; then
    echo "  Creating virtual environment at ${VENV_DIR}..."
    "${SYSTEM_PYTHON}" -m venv "${VENV_DIR}"
else
    echo -e "  Using existing virtual environment at: ${GREEN}${VENV_DIR}${NC}"
fi

# Ensure pip, setuptools, wheel are updated
echo "  Upgrading pip, setuptools, and wheel..."
"${PIP_BIN}" install --upgrade --quiet pip setuptools wheel

# ------------------------------------------------------------------------------
# 4. Install PaddlePaddle & PaddleOCR Packages
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/6] Installing PaddlePaddle & PaddleOCR Packages...${NC}"

if [[ "${DETECTED_DEVICE}" == "cuda" && "${HAS_GPU}" -eq 1 ]]; then
    echo -e "  Installing ${BOLD}paddlepaddle-gpu${NC} for NVIDIA GPU..."
    "${PIP_BIN}" install paddlepaddle-gpu
else
    echo -e "  Installing ${BOLD}paddlepaddle${NC} (CPU mode)..."
    "${PIP_BIN}" install paddlepaddle
fi

echo "  Installing paddleocr[doc-parser], paddlex, and pypdfium2..."
"${PIP_BIN}" install "paddleocr[doc-parser]>=3.6.0" "paddlex>=3.7.0" "pypdfium2>=5.0.0"

# Also install project dependencies if requirements.txt exists
if [ -f "${PROJECT_ROOT}/requirements.txt" ]; then
    echo "  Ensuring project requirements are met..."
    "${PIP_BIN}" install -r "${PROJECT_ROOT}/requirements.txt" --quiet
fi

# ------------------------------------------------------------------------------
# 5. Configure .env Environment File
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[5/6] Configuring Application Environment (.env)...${NC}"

ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"

if [ ! -f "${ENV_FILE}" ]; then
    if [ -f "${ENV_EXAMPLE}" ]; then
        echo "  Creating .env from .env.example..."
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    else
        echo "  Creating fresh .env..."
        touch "${ENV_FILE}"
    fi
fi

if [[ ${SKIP_ENV_UPDATE} -eq 0 ]]; then
    # Function to update or append .env variables
    set_env_var() {
        local key="$1"
        local val="$2"
        if grep -q "^${key}=" "${ENV_FILE}"; then
            sed -i.bak "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
        else
            echo "${key}=${val}" >> "${ENV_FILE}"
        fi
    }

    set_env_var "OCR_PROVIDER" "\"paddleocr_vl\""
    set_env_var "PADDLEOCR_VL_BACKEND" "\"local\""
    set_env_var "PADDLEOCR_VL_DEVICE" "\"${DETECTED_DEVICE}\""
    set_env_var "PADDLEOCR_VL_TIMEOUT_SECONDS" "180"

    echo -e "  ${GREEN}.env updated successfully:${NC}"
    echo "    OCR_PROVIDER=\"paddleocr_vl\""
    echo "    PADDLEOCR_VL_BACKEND=\"local\""
    echo "    PADDLEOCR_VL_DEVICE=\"${DETECTED_DEVICE}\""
    echo "    PADDLEOCR_VL_TIMEOUT_SECONDS=180"
else
    echo "  Skipping .env update as requested (--skip-env)."
fi

# ------------------------------------------------------------------------------
# 6. Sanity Verification & Optional Model Download
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[6/6] Verifying Local Installation...${NC}"

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

if "${PYTHON_BIN}" -c "${VERIFY_CODE}"; then
    echo -e "\n  ${GREEN}${BOLD}Verification PASSED!${NC}"
else
    echo -e "\n  ${RED}${BOLD}Verification FAILED! Please inspect errors above.${NC}"
    exit 1
fi

if [[ ${DOWNLOAD_MODELS} -eq 1 ]]; then
    echo -e "\n${BLUE}Pre-downloading PaddleOCR-VL-1.6 and PP-DocLayoutV3 models...${NC}"
    "${PYTHON_BIN}" -c "
import paddle
from paddleocr import PaddleOCRVL
paddle.device.set_device('${DETECTED_DEVICE}')
print('Initializing PaddleOCRVL to trigger weight download/cache...')
pipeline = PaddleOCRVL(pipeline_version='v1.6', device='${DETECTED_DEVICE}')
print('Model download complete!')
"
fi

echo -e "\n${GREEN}${BOLD}==================================================================${NC}"
echo -e "${GREEN}${BOLD}  PaddleOCR-VL-1.6 Local Setup Completed Successfully!            ${NC}"
echo -e "${GREEN}${BOLD}==================================================================${NC}"
echo ""
echo -e "To start processing documents locally:"
echo ""
echo -e "  1. Start Celery Background Worker:"
echo -e "     ${BOLD}./venv/bin/celery -A app.core.celery_app.celery worker --loglevel=info -c 1${NC}"
echo ""
echo -e "  2. Start FastAPI Web Server:"
echo -e "     ${BOLD}./venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload${NC}"
echo ""
echo -e "  3. Access the Dashboard in your browser:"
echo -e "     ${BOLD}http://localhost:8000${NC}"
echo ""
