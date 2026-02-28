
# Usage:
#   ./zmk-container-build.sh setup      # Clone repos + init west in container
#   ./zmk-container-build.sh build      # Build firmware
#   ./zmk-container-build.sh clean      # Clean build artifacts
#   ./zmk-container-build.sh shell      # Drop into container shell
#
# Prerequisites:
#   - Fedora with Podman (pre-installed)
#   - Your zmk-config repo: https://github.com/alexgallotta/zmk
# =============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
ZMK_CONFIG_REPO="https://github.com/alexgallotta/zmk.git"
ZMK_WORKSPACE="$HOME/repos/zmk/zmk-workspace"
ZMK_DIR="$ZMK_WORKSPACE/zmk"
CONFIG_DIR="$ZMK_WORKSPACE/config"
FIRMWARE_DIR="$ZMK_WORKSPACE/firmware"

# Official ZMK dev image (includes Zephyr SDK + west + all deps)
ZMK_IMAGE="docker.io/zmkfirmware/zmk-build-arm:stable"
ZMK_REVISION="v0.3" #must use v0.3 with zephyr stable which is 3.5

# ─── Board and shield definitions ────────────────────────────────────────────
# Edit these or rely on build.yaml in your config repo
DEFAULT_BOARD="nice_nano_v2"
DEFAULT_SHIELD_LEFT="corne_left"
DEFAULT_SHIELD_RIGHT="corne_right"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── Clone repos ────────────────────────────────────────────────────────────
clone_repos() {
    mkdir -p "$ZMK_WORKSPACE"

    if [ ! -d "$ZMK_DIR" ]; then
        log_info "Cloning ZMK firmware source..."
        git clone https://github.com/zmkfirmware/zmk.git "$ZMK_DIR"
		cd "$ZMK_DIR" && git checkout "$ZMK_REVISION" && cd -
    else
        log_ok "ZMK source already cloned."
    fi

    if [ ! -d "$CONFIG_DIR" ]; then
        log_info "Cloning your zmk-config..."
        git clone "$ZMK_CONFIG_REPO" "$CONFIG_DIR"
    else
        log_ok "Config repo already cloned."
    fi
}

# ─── Run a command inside the container ──────────────────────────────────────
run_in_container() {
    podman run --rm -it \
        --security-opt label=disable \
        --workdir /workspaces/zmk \
		-e ZEPHYR_SDK_INSTALL_DIR=/opt/zephyr-sdk-0.16.3 \
        -v "$ZMK_DIR:/workspaces/zmk:Z" \
        -v "$CONFIG_DIR:/workspaces/zmk-config:Z" \
        -v "$FIRMWARE_DIR:/workspaces/firmware:Z" \
        "$ZMK_IMAGE" \
        bash -c "$1"
}

# ─── Interactive shell ───────────────────────────────────────────────────────
run_shell() {
    podman run --rm -it \
        --security-opt label=disable \
        --workdir /workspaces/zmk \
        -v "$ZMK_DIR:/workspaces/zmk:Z" \
        -v "$CONFIG_DIR:/workspaces/zmk-config:Z" \
        -v "$FIRMWARE_DIR:/workspaces/firmware:Z" \
        "$ZMK_IMAGE" \
        /bin/bash
}

init_west() {
    log_info "Initializing west workspace inside container..."

    run_in_container '
        set -e
        if [ ! -f /workspaces/zmk/.west/config ]; then
            echo "[*] Running west init..."
            west init -l app/
        else
            echo "[*] West already initialized."
        fi

        echo "[*] Exporting Zephyr CMake package..."
		west update
        west zephyr-export

        echo "[*] Done!"
    '

    log_ok "West workspace initialized."
}

get_config_path() {
    # Look for the config directory that contains .keymap files
    # Common structures:
    #   /workspaces/zmk-config/config/
    #   /workspaces/zmk-config/
    echo "/workspaces/zmk-config/config"
}

build_firmware() {
    mkdir -p "$FIRMWARE_DIR"

    local config_path
    config_path=$(get_config_path)

    # Check for build.yaml
    local build_yaml=""
    for candidate in "$CONFIG_DIR/build.yaml" "$CONFIG_DIR/config/build.yaml"; do
        if [ -f "$candidate" ]; then
            build_yaml="$candidate"
            break
        fi
    done

    local build_commands+="
west update
west zephyr-export
	"

    if [ -n "$build_yaml" ]; then
        log_info "Found build.yaml, parsing targets..."

        local boards=()
        local shields=()

        while IFS= read -r line; do
            if [[ "$line" =~ board:\ *(.+) ]]; then
                boards+=("$(echo "${BASH_REMATCH[1]}" | xargs)")
            fi
            if [[ "$line" =~ shield:\ *(.+) ]]; then
                shields+=("$(echo "${BASH_REMATCH[1]}" | xargs)")
            fi
        done < "$build_yaml"

        if [ ${#boards[@]} -eq 0 ]; then
            log_warn "Could not parse build.yaml, using defaults."
            boards=("$DEFAULT_BOARD" "$DEFAULT_BOARD")
            shields=("$DEFAULT_SHIELD_LEFT" "$DEFAULT_SHIELD_RIGHT")
        fi

        for i in "${!boards[@]}"; do
            local board="${boards[$i]}"
            local shield="${shields[$i]:-}"
            local build_dir="build_${i}"

            if [ -n "$shield" ]; then
                build_commands+="
echo '════════════════════════════════════════════════'
echo \"Building: board=${board} shield=${shield}\"
echo '════════════════════════════════════════════════'
cd /workspaces/zmk/app
west build -p -d ${build_dir} -b ${board} -- -DSHIELD=${shield} -DZMK_CONFIG=${config_path}
if [ -f ${build_dir}/zephyr/zmk.uf2 ]; then
    cp ${build_dir}/zephyr/zmk.uf2 /workspaces/firmware/${shield}-${board}-zmk.uf2
    echo \"[OK] Saved: ${shield}-${board}-zmk.uf2\"
elif [ -f ${build_dir}/zephyr/zmk.hex ]; then
    cp ${build_dir}/zephyr/zmk.hex /workspaces/firmware/${shield}-${board}-zmk.hex
    echo \"[OK] Saved: ${shield}-${board}-zmk.hex\"
else
    echo \"[ERROR] No firmware output found for ${shield}\"
fi
"
            else
                build_commands+="
echo '════════════════════════════════════════════════'
echo \"Building: board=${board} (no shield)\"
echo '════════════════════════════════════════════════'
cd /workspaces/zmk/app
west build -p -d ${build_dir} -b ${board} -- -DZMK_CONFIG=${config_path}
if [ -f ${build_dir}/zephyr/zmk.uf2 ]; then
    cp ${build_dir}/zephyr/zmk.uf2 /workspaces/firmware/${board}-zmk.uf2
    echo \"[OK] Saved: ${board}-zmk.uf2\"
fi
"
            fi
        done
    else
        log_warn "No build.yaml found, using defaults..."
        build_commands="
cd /workspaces/zmk/app

echo '════════════════════════════════════════════════'
echo 'Building LEFT half: ${DEFAULT_BOARD} + ${DEFAULT_SHIELD_LEFT}'
echo '════════════════════════════════════════════════'
west build -p -d build_left -b ${DEFAULT_BOARD} -- -DSHIELD=${DEFAULT_SHIELD_LEFT} -DZMK_CONFIG=${config_path}
cp build_left/zephyr/zmk.uf2 /workspaces/firmware/${DEFAULT_SHIELD_LEFT}-${DEFAULT_BOARD}-zmk.uf2 2>/dev/null && echo '[OK] Left saved' || echo '[WARN] No .uf2 for left'

echo '════════════════════════════════════════════════'
echo 'Building RIGHT half: ${DEFAULT_BOARD} + ${DEFAULT_SHIELD_RIGHT}'
echo '════════════════════════════════════════════════'
west build -p -d build_right -b ${DEFAULT_BOARD} -- -DSHIELD=${DEFAULT_SHIELD_RIGHT} -DZMK_CONFIG=${config_path}
cp build_right/zephyr/zmk.uf2 /workspaces/firmware/${DEFAULT_SHIELD_RIGHT}-${DEFAULT_BOARD}-zmk.uf2 2>/dev/null && echo '[OK] Right saved' || echo '[WARN] No .uf2 for right'
"
    fi

    run_in_container "set -e; $build_commands"
}

# ─── Flash info ──────────────────────────────────────────────────────────────
flash_info() {
    echo ""
    log_info "═══════════════════════════════════════════════════"
    log_info "  HOW TO FLASH"
    log_info "═══════════════════════════════════════════════════"
    echo ""
    echo "  1. Connect keyboard half via USB-C"
    echo "  2. Double-tap reset → USB drive appears (NICENANO)"
    echo "  3. Copy the .uf2 file:"
    echo ""
    echo "     cp $FIRMWARE_DIR/<name>.uf2 /run/media/$USER/NICENANO/"
    echo ""
    echo "  4. Keyboard flashes and reboots automatically"
    echo "  5. Repeat for the other half"
    echo ""
    log_info "Built firmware files:"
    if [ -d "$FIRMWARE_DIR" ]; then
        find "$FIRMWARE_DIR" -name "*.uf2" -o -name "*.hex" 2>/dev/null | sort | while read -r f; do
            echo "    $(basename "$f")"
        done
    fi
    echo ""
}

# ─── Commands ────────────────────────────────────────────────────────────────
cmd_setup() {
    log_info "══════════════════════════════════════════════"
    log_info "  ZMK Container Build - First Time Setup"
    log_info "══════════════════════════════════════════════"
	podman pull "$ZMK_IMAGE"
    clone_repos
    mkdir -p "$FIRMWARE_DIR"
    init_west
    echo ""
}

cmd_build() {
    log_info "══════════════════════════════════════════════"
    log_info "  ZMK Container Build - Building Firmware"
    log_info "══════════════════════════════════════════════"
    cd "$CONFIG_DIR"
    git pull
	cd -
    build_firmware
    flash_info
    log_ok "Build complete!"
}

cmd_clean() {
    log_info "Cleaning build artifacts..."
    rm -rf "$ZMK_DIR/app/build"*
    rm -rf "$FIRMWARE_DIR"/*
    log_ok "Cleaned."
}

cmd_shell() {
    log_info "Dropping into container shell..."
    log_info "  ZMK source:  /workspaces/zmk"
    log_info "  Your config: /workspaces/zmk-config"
    log_info "  Firmware:    /workspaces/firmware"
    echo ""
    run_shell
}

# ─── Help ────────────────────────────────────────────────────────────────────
show_help() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup        Pull image, clone repos, init west workspace"
    echo "  build        Build firmware inside container"
    echo "  clean        Clean build artifacts"
    echo "  shell        Interactive bash shell inside the container"
    echo "  help         Show this message"
    echo ""
    echo "Configuration (edit at top of script):"
    echo "  ZMK_CONFIG_REPO:  $ZMK_CONFIG_REPO"
    echo "  ZMK_WORKSPACE:    $ZMK_WORKSPACE"
    echo "  ZMK_IMAGE:        $ZMK_IMAGE"
    echo "  DEFAULT_BOARD:    $DEFAULT_BOARD"
    echo "  DEFAULT_SHIELD_L: $DEFAULT_SHIELD_LEFT"
    echo "  DEFAULT_SHIELD_R: $DEFAULT_SHIELD_RIGHT"
    echo ""
    echo "Requirements: podman (pre-installed on Fedora)"
}

# ─── Main ────────────────────────────────────────────────────────────────────
case "${1:-help}" in
    setup)       cmd_setup ;;
    build)       cmd_build ;;
    clean)       cmd_clean ;;
    shell)       cmd_shell ;;
    help|*)      show_help ;;
esac
