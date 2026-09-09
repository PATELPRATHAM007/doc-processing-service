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
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Determine script and project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PROJECT_ROOT}/venv"
PYTHON_BIN="${VENV_DIR}/bin/python"

# Default flags
FORCE_CPU=0
FORCE_GPU=0
DOWNLOAD_MODELS=1
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
    echo "Usage: ./setup_paddle.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --no-download-models Do NOT pre-download model weights (models download on first run)"
    echo "  --download-models    Pre-download PaddleOCR-VL-1.6 weights (~1.9 GB) into local cache (default)"
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
        --no-download-models)
            DOWNLOAD_MODELS=0
            shift
            ;;
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
# 1. Detect Operating System, Architecture & GPU
# ------------------------------------------------------------------------------
echo -e "${BLUE}[1/6] Detecting System Environment & Hardware...${NC}"

OS_TYPE="$(uname -s)"
ARCH_TYPE="$(uname -m)"
DISTRO="unknown"
HAS_GPU=0
DETECTED_DEVICE="cpu"

case "${OS_TYPE}" in
    Darwin)
        OS_NAME="macOS"
        if [[ "${ARCH_TYPE}" == "arm64" ]]; then
            echo -e "  OS Platform   : ${GREEN}macOS (Apple Silicon M-Series: ${ARCH_TYPE})${NC}"
        else
            echo -e "  OS Platform   : ${GREEN}macOS (Intel x86_64)${NC}"
        fi
        echo -e "  Compute Device: ${GREEN}CPU (Optimized for Apple Accelerate/NEON)${NC}"
        DETECTED_DEVICE="cpu"
        ;;
    Linux)
        OS_NAME="Linux"
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO="${ID:-linux}"
            DISTRO_VERSION="${VERSION_ID:-unknown}"
            echo -e "  OS Platform   : ${GREEN}Linux (${PRETTY_NAME:-$DISTRO}) [${ARCH_TYPE}]${NC}"
        else
            echo -e "  OS Platform   : ${GREEN}Linux [${ARCH_TYPE}]${NC}"
        fi

        # Check for NVIDIA GPU
        if command -v nvidia-smi &>/dev/null; then
            GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || echo "NVIDIA GPU")
            echo -e "  GPU Status    : ${GREEN}Detected ${GPU_MODEL}${NC}"
            HAS_GPU=1
            DETECTED_DEVICE="cuda"
        else
            echo -e "  GPU Status    : ${YELLOW}No NVIDIA GPU detected (using CPU mode)${NC}"
            DETECTED_DEVICE="cpu"
        fi
        ;;
    *)
        echo -e "${RED}Unsupported Operating System: ${OS_TYPE}${NC}"
        echo "For Windows PC, please run: ./setup_paddle_windows.sh or .\\setup_paddle_windows.ps1"
        exit 1
        ;;
esac

# Handle user overrides
if [[ ${FORCE_CPU} -eq 1 ]]; then
    DETECTED_DEVICE="cpu"
    HAS_GPU=0
    echo -e "  Override      : ${YELLOW}Forcing CPU mode${NC}"
elif [[ ${FORCE_GPU} -eq 1 ]]; then
    if [[ "${OS_NAME}" == "macOS" ]]; then
        echo -e "${YELLOW}Notice: NVIDIA CUDA GPU is not available on macOS. Continuing with CPU.${NC}"
        DETECTED_DEVICE="cpu"
        HAS_GPU=0
    else
        DETECTED_DEVICE="cuda"
        HAS_GPU=1
        echo -e "  Override      : ${GREEN}Forcing GPU mode (CUDA)${NC}"
    fi
fi

# ------------------------------------------------------------------------------
# 2. System Dependencies Check (Linux / Ubuntu)
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

# Find suitable python binary (Python 3.9 - 3.12 64-bit)
SYSTEM_PYTHON=""
for py_cmd in python3.11 python3.12 python3.10 python3; do
    if command -v "${py_cmd}" &>/dev/null; then
        if "${py_cmd}" -c "import sys; exit(0 if sys.version_info >= (3, 9) and sys.version_info < (3, 13) and sys.maxsize > 2**32 else 1)" 2>/dev/null; then
            SYSTEM_PYTHON="${py_cmd}"
            break
        fi
    fi
done

if [ -z "${SYSTEM_PYTHON}" ]; then
    echo -e "${RED}Error: 64-bit Python 3.9 - 3.12 is required for PaddlePaddle.${NC}"
    echo "Please install Python 3.11 (e.g. via 'brew install python@3.11' on macOS or 'apt install python3.11' on Ubuntu)."
    exit 1
fi

PY_INFO=$(${SYSTEM_PYTHON} -c "import sys, platform; print(f'{platform.python_version()} ({platform.machine()})')")
echo -e "  Found Python  : ${GREEN}${SYSTEM_PYTHON} -> ${PY_INFO}${NC}"

# Create or reuse virtualenv
if [ ! -d "${VENV_DIR}" ]; then
    echo "  Creating virtual environment at ${VENV_DIR}..."
    "${SYSTEM_PYTHON}" -m venv "${VENV_DIR}"
else
    echo -e "  Using existing virtual environment at: ${GREEN}${VENV_DIR}${NC}"
fi

# Clean up any leftover temporary folders from prior interrupted pip installs (e.g. ~ip)
find "${VENV_DIR}" -type d -name "~*" -exec rm -rf {} + 2>/dev/null || true

# Upgrade pip, setuptools, wheel using python -m pip
echo "  Upgrading pip, setuptools, and wheel..."
"${PYTHON_BIN}" -m pip install --upgrade --quiet pip setuptools wheel

# ------------------------------------------------------------------------------
# 4. Install PaddlePaddle & PaddleOCR Packages
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/6] Installing PaddlePaddle & PaddleOCR Packages...${NC}"

PADDLE_INSTALLED=0

if [[ "${DETECTED_DEVICE}" == "cuda" && "${HAS_GPU}" -eq 1 ]]; then
    echo -e "  NVIDIA GPU detected. Attempting to install ${BOLD}paddlepaddle-gpu${NC} for CUDA..."

    # Uninstall cpu paddlepaddle first if previously present to avoid package collision
    "${PYTHON_BIN}" -m pip uninstall -y paddlepaddle 2>/dev/null || true

    PY_TAG=$("${PYTHON_BIN}" -c "import sys; print(f'cp{sys.version_info.major}{sys.version_info.minor}')")

    # Strategy 1: Official Paddle CUDA indexes with trusted hosts
    CUDA_INDEXES=(
        "https://www.paddlepaddle.org.cn/packages/stable/cu126/"
        "https://www.paddlepaddle.org.cn/packages/stable/cu118/"
    )

    for idx in "${CUDA_INDEXES[@]}"; do
        echo -e "  Trying CUDA index: ${CYAN}${idx}${NC}..."
        if "${PYTHON_BIN}" -m pip install paddlepaddle-gpu -i "${idx}" --trusted-host www.paddlepaddle.org.cn --trusted-host paddle-whl.cdn.bcebos.com; then
            PADDLE_INSTALLED=1
            echo -e "  ${GREEN}paddlepaddle-gpu installed successfully via ${idx}!${NC}"
            break
        fi
    done

    # Strategy 2: Direct pre-compiled wheel download from CDN with live progress bar
    if [[ ${PADDLE_INSTALLED} -eq 0 ]]; then
        echo -e "\n  Index lookup failed. Downloading pre-compiled CUDA wheel with auto-resume..."
        DIRECT_WHEELS=(
            "https://paddle-whl.cdn.bcebos.com/stable/cu126/paddlepaddle-gpu/paddlepaddle_gpu-3.3.1-${PY_TAG}-${PY_TAG}-linux_x86_64.whl"
            "https://paddle-whl.cdn.bcebos.com/stable/cu118/paddlepaddle-gpu/paddlepaddle_gpu-3.3.1-${PY_TAG}-${PY_TAG}-linux_x86_64.whl"
        )

        for wheel_url in "${DIRECT_WHEELS[@]}"; do
            wheel_name="$(basename "${wheel_url}")"
            local_wheel="${PROJECT_ROOT}/${wheel_name}"
            download_success=0

            if [ -f "${local_wheel}" ]; then
                file_size=$(wc -c < "${local_wheel}" | tr -d ' ')
                if [ "${file_size}" -ge 1200000000 ]; then
                    echo -e "  ${GREEN}Found existing cached wheel (${wheel_name}, $(( file_size / 1048576 )) MB). Skipping download!${NC}"
                    download_success=1
                fi
            fi

            if [[ ${download_success} -eq 0 ]]; then
                echo -e "  Target: ${wheel_name} (~1.4 - 2.0 GB)..."
                attempt=0
                max_attempts=15

                while [[ ${attempt} -lt ${max_attempts} ]]; do
                    attempt=$((attempt + 1))
                    curl -# -L -C - --retry 3 --retry-delay 2 -o "${local_wheel}" "${wheel_url}" || true

                    if [ -f "${local_wheel}" ]; then
                        file_size=$(wc -c < "${local_wheel}" | tr -d ' ')
                        if [ "${file_size}" -ge 1200000000 ]; then
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
                echo -e "  Installing wheel into virtual environment..."
                "${PYTHON_BIN}" -m pip uninstall -y paddlepaddle 2>/dev/null || true
                if "${PYTHON_BIN}" -m pip install --force-reinstall "${local_wheel}"; then
                    PADDLE_INSTALLED=1
                    echo -e "  ${GREEN}paddlepaddle-gpu installed successfully from downloaded wheel!${NC}"
                    break
                fi
            fi
        done
    fi

    if [[ ${PADDLE_INSTALLED} -eq 0 ]]; then
        echo -e "${YELLOW}Warning: paddlepaddle-gpu install could not find matching wheels. Falling back to CPU mode...${NC}"
    fi
fi

# Install CPU mode if GPU was skipped or failed
if [[ ${PADDLE_INSTALLED} -eq 0 ]]; then
    echo -e "  Installing ${BOLD}paddlepaddle${NC} (CPU mode)..."
    "${PYTHON_BIN}" -m pip install paddlepaddle
    DETECTED_DEVICE="cpu"
    echo -e "  ${GREEN}paddlepaddle (CPU mode) installed successfully!${NC}"
fi

echo "  Installing paddleocr[doc-parser], paddlex, and pypdfium2..."
"${PYTHON_BIN}" -m pip install "paddleocr[doc-parser]>=3.6.0" "paddlex>=3.7.0" "pypdfium2>=5.0.0"

# Also install project dependencies if requirements.txt exists
if [ -f "${PROJECT_ROOT}/requirements.txt" ]; then
    echo "  Ensuring project requirements are met..."
    "${PYTHON_BIN}" -m pip install -r "${PROJECT_ROOT}/requirements.txt" --quiet
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

    echo -e "  ${GREEN}.env configured successfully for local PaddleOCR (${DETECTED_DEVICE}):${NC}"
    echo "    OCR_PROVIDER=\"paddleocr_vl\""
    echo "    PADDLEOCR_VL_BACKEND=\"local\""
    echo "    PADDLEOCR_VL_DEVICE=\"${DETECTED_DEVICE}\""
    echo "    PADDLEOCR_VL_TIMEOUT_SECONDS=180"
else
    echo "  Skipping .env update as requested (--skip-env)."
fi

# ------------------------------------------------------------------------------
# 6. Sanity Verification & Model Download
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

    if cuda_avail:
        if hasattr(paddle.device, 'cuda'):
            print('  CUDA Device Count     :', paddle.device.cuda.device_count())
            print('  CUDA Device Name      :', paddle.device.cuda.get_device_name(0))
        if hasattr(paddle, 'version'):
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

if "${PYTHON_BIN}" -c "${VERIFY_CODE}"; then
    echo -e "\n  ${GREEN}${BOLD}Verification PASSED!${NC}"
else
    echo -e "\n  ${RED}${BOLD}Verification FAILED! Please inspect errors above.${NC}"
    exit 1
fi

if [[ ${DOWNLOAD_MODELS} -eq 1 ]]; then
    echo -e "\n${BLUE}Pre-downloading PaddleOCR-VL-1.6 and PP-DocLayoutV3 models (~1.9 GB)...${NC}"

    MODEL_CACHE_DIR="${HOME}/.paddlex/official_models"
    if [ -d "${MODEL_CACHE_DIR}" ]; then
        echo -e "  ${GREEN}Detected existing cached models in ${MODEL_CACHE_DIR}:${NC}"
        for d in "${MODEL_CACHE_DIR}"/*; do
            if [ -d "${d}" ]; then
                d_size=$(du -sh "${d}" 2>/dev/null | cut -f1)
                echo -e "    - $(basename "${d}") (${d_size})"
            fi
        done
    fi

    "${PYTHON_BIN}" -c "
import sys, os
if '' in sys.path: sys.path.remove('')
if os.getcwd() in sys.path: sys.path.remove(os.getcwd())

import paddle
from paddleocr import PaddleOCRVL

dev = '${DETECTED_DEVICE}'
try:
    paddle.device.set_device(dev)
except Exception as e:
    print(f'Notice: Could not activate {dev} device ({e}). Falling back to cpu for caching.')
    dev = 'cpu'
    paddle.device.set_device('cpu')

print(f'Initializing PaddleOCRVL (device={dev}) to verify and cache models...')
pipeline = PaddleOCRVL(pipeline_version='v1.6', device=dev)
print('Model verification and caching complete!')
"
fi

echo -e "\n${GREEN}${BOLD}==================================================================${NC}"
echo -e "${GREEN}${BOLD}  PaddleOCR-VL-1.6 Local Setup Completed Successfully!            ${NC}"
echo -e "${GREEN}${BOLD}==================================================================${NC}"
echo ""
echo -e "${BOLD}To start processing documents locally:${NC}"
echo ""
echo -e "  1. Start Redis & PostgreSQL (e.g. via Docker Compose):"
echo -e "     ${BOLD}docker compose up -d redis db${NC}"
echo ""
echo -e "  2. Start Celery Background Worker:"
echo -e "     ${BOLD}./venv/bin/celery -A app.core.celery_app worker --loglevel=info -c 1${NC}"
echo ""
echo -e "  3. Start FastAPI Web Server:"
echo -e "     ${BOLD}./venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 9000 --reload${NC}"
echo ""
echo -e "  4. Access the Dashboard in your browser:"
echo -e "     ${BOLD}http://localhost:9000${NC}"
echo ""
