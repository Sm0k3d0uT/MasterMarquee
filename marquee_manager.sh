#!/bin/bash

GITHUB_USER="Sm0k3d0uT"
GITHUB_REPO="MasterMarquee"
GITHUB_BRANCH="main"
REPO_RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CURL_AUTH=()
[ -n "$GITHUB_TOKEN" ] && CURL_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (e.g., sudo -E bash marquee_manager.sh)"
    exit 1
fi

if [ -d "/userdata/system" ]; then FRONTEND="batocera"; BASE_DIR="/userdata/system/arcade-marquee"
elif [ -d "/recalbox/share" ]; then FRONTEND="recalbox"; BASE_DIR="/recalbox/share/system/arcade-marquee"
elif [ -d "/storage/.config/emulationstation" ]; then FRONTEND="emuelec"; BASE_DIR="/storage/.config/arcade-marquee"
elif [ -d "/opt/retropie" ]; then FRONTEND="retropie"; BASE_DIR="/opt/arcade-marquee"
elif [ -d "/storage/.config/retroarch" ] && [ ! -d "/storage/.config/emulationstation" ]; then FRONTEND="lakka"; BASE_DIR="/storage/.config/arcade-marquee"
elif command -v attract >/dev/null 2>&1 || [ -d "/root/.attract" ] || ls -d /home/*/.attract >/dev/null 2>&1; then FRONTEND="attractmode"; BASE_DIR="/opt/arcade-marquee"
elif command -v pegasus-fe >/dev/null 2>&1 || [ -d "/root/.config/pegasus-frontend" ] || ls -d /home/*/.config/pegasus-frontend >/dev/null 2>&1; then FRONTEND="pegasus"; BASE_DIR="/opt/arcade-marquee"
else FRONTEND="linux_generic"; BASE_DIR="/opt/arcade-marquee"
fi

mkdir -p "$BASE_DIR"
INSTALL_PATH="${BASE_DIR}/marquee_manager.sh"
BACKUP_DIR="${BASE_DIR}/backups"

if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]]; then
    curl -sSLf "${CURL_AUTH[@]}" "${REPO_RAW_URL}/marquee_manager.sh" -o "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH"
fi

echo "=================================================="
echo "   Universal Arcade Marquee All-in-One Manager    "
echo "   Detected Environment: ${FRONTEND^^}"
echo "=================================================="
echo "1) Install / Update Full Marquee Suite"
echo "2) Backup All Scripts, Configs & Artwork"
echo "3) Restore From Backup"
echo "4) Uninstall & Revert to Stock"
echo "5) Update Manager & Component Files from GitHub"
echo "--------------------------------------------------"
read -p "Choose an action [1-5]: " ACTION

fetch_component() {
    local REL_PATH="$1" DEST_PATH="$2"
    local SCRIPT_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null)")
    if [ -f "${SCRIPT_DIR}/${REL_PATH}" ]; then
        cp -f "${SCRIPT_DIR}/${REL_PATH}" "$DEST_PATH"
    else
        curl -sSLf "${CURL_AUTH[@]}" "${REPO_RAW_URL}/${REL_PATH}" -o "$DEST_PATH" || { echo "Failed to download ${REL_PATH}"; exit 1; }
    fi
}

detect_theme_logo_path() {
    local THEMES_DIR="$1" ACTIVE_THEME=""
    for CFG in /userdata/system/batocera.conf /recalbox/share/system/recalbox.conf /storage/.config/emulationstation/es_settings.cfg; do
        [ -f "$CFG" ] && ACTIVE_THEME=$(grep -E '^(global\.theme|emulationstation\.theme)=' "$CFG" | tail -n 1 | cut -d'=' -f2 | tr -d "\"'\r") && [ -n "$ACTIVE_THEME" ] && break
    done
    [ -z "$ACTIVE_THEME" ] || [ ! -d "${THEMES_DIR}/${ACTIVE_THEME}" ] && ACTIVE_THEME=$(ls -1 "$THEMES_DIR" 2>/dev/null | head -n 1)
    if [ -n "$ACTIVE_THEME" ] && [ -d "${THEMES_DIR}/${ACTIVE_THEME}" ]; then
        for SUB in "_inc/logos" "art/logos" "logos" "art/system-logos" "_inc/system-logos" "assets/logos"; do
            [ -d "${THEMES_DIR}/${ACTIVE_THEME}/${SUB}" ] && echo "${ACTIVE_THEME}/${SUB}" && return 0
        done
    fi
    echo "es-theme-carbon/art/logos"
}

install_missing_linux_deps() {
    if [ "$FRONTEND" = "batocera" ] || [ "$FRONTEND" = "recalbox" ] || [ "$FRONTEND" = "emuelec" ] || [ "$FRONTEND" = "lakka" ]; then return 0; fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y fbi fbset mpv curl python3 imagemagick librsvg2-bin psmisc tar iputils-ping
        pgrep -x "Xorg" >/dev/null 2>&1 && apt-get install -y x11-xserver-utils
        pgrep -x "Xwayland|gnome-shell|plasmashell|sway|weston|labwc" >/dev/null 2>&1 && apt-get install -y wlr-randr
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm fbida fbset mpv curl python imagemagick librsvg psmisc tar iputils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y fbida fbset mpv curl python3 ImageMagick librsvg2-tools psmisc tar iputils
    fi
}

start_host_services() {
    local BIND_SCOPE="$1" ROMS_DIR="$2" THEMES_DIR="$3" STARTUP_HOOK_FILE="$4"
    fetch_component "host/host_server.py" "${BASE_DIR}/host_server.py"
    read -p "Optional Official Pixelcade Hardware IP (blank for none): " PIXELCADE_HW_IP
    read -p "Optional RetroAchievements Username (blank for none): " RA_USER
    RA_API_KEY=""
    [ -n "$RA_USER" ] && read -p "RetroAchievements Web API Key: " RA_API_KEY
    [ "$BIND_SCOPE" = "local" ] && BIND_ADDR="127.0.0.1" || BIND_ADDR="0.0.0.0"

    cat << EOF > "${BASE_DIR}/host.conf"
BASE_DIR="${BASE_DIR}"
ROMS_DIR="${ROMS_DIR}"
THEMES_DIR="${THEMES_DIR}"
BIND_ADDR="${BIND_ADDR}"
PIXELCADE_HW_IP="${PIXELCADE_HW_IP}"
RA_USER="${RA_USER}"
RA_API_KEY="${RA_API_KEY}"
EOF
    chmod 600 "${BASE_DIR}/host.conf"

    if [ -n "$STARTUP_HOOK_FILE" ]; then
        touch "$STARTUP_HOOK_FILE"
        sed -i '/# Arcade Marquee Host Server/d;/host_server.py/d' "$STARTUP_HOOK_FILE"
        printf '\n# Arcade Marquee Host Server\npython3 "%s/host_server.py" >/dev/null 2>&1 &\n' "$BASE_DIR" >> "$STARTUP_HOOK_FILE"
        chmod +x "$STARTUP_HOOK_FILE"
    elif command -v systemctl >/dev/null 2>&1; then
        cat << EOF > /etc/systemd/system/arcade-marquee-host.service
[Unit]
Description=Arcade Marquee Host Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 ${BASE_DIR}/host_server.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable --now arcade-marquee-host.service
    fi

    pkill -f "host_server.py" 2>/dev/null
    python3 "${BASE_DIR}/host_server.py" >/dev/null 2>&1 &
    [ "$BIND_SCOPE" = "network" ] && [ -d "$ROMS_DIR" ] && cd "$ROMS_DIR" && find . -type f \( -iname "*-marquee.mp4" -o -iname "*-marquee.png" -o -iname "*-wheel.png" \) | tar -czf "${BASE_DIR}/marquees.tar.gz" -T - 2>/dev/null
}

install_es_hooks() {
    local SYS_ROOT="$1" ROMS_ROOT="$2" THEMES_ROOT="$3" ES_SCRIPTS="$4" BIND_SCOPE="$5"
    detect_theme_logo_path "$THEMES_ROOT" > "${BASE_DIR}/theme_path.txt"
    mkdir -p "${ES_SCRIPTS}/game-selected" "${ES_SCRIPTS}/system-selected" "${ES_SCRIPTS}/game-start" "${ES_SCRIPTS}/game-end"
    printf '#!/bin/bash\nROM_NAME=$(basename "$2" | sed "s/\\.[^.]*$//")\nprintf "browse|%%s|%%s\\n" "$1" "$ROM_NAME" > "%s/current_game.txt"\n' "$BASE_DIR" > "${ES_SCRIPTS}/game-selected/marquee.sh"
    printf '#!/bin/bash\nprintf "system|%%s|%%s\\n" "$1" "$1" > "%s/current_game.txt"\n' "$BASE_DIR" > "${ES_SCRIPTS}/system-selected/marquee.sh"
    printf '#!/bin/bash\nROM_NAME=$(basename "$1" | sed "s/\\.[^.]*$//")\nSYS_NAME="$2"; [ -z "$SYS_NAME" ] && SYS_NAME=$(basename "$(dirname "$1")")\nprintf "playing|%%s|%%s\\n" "$SYS_NAME" "$ROM_NAME" > "%s/current_game.txt"\n' "$BASE_DIR" > "${ES_SCRIPTS}/game-start/marquee.sh"
    printf '#!/bin/bash\n[ -f "%s/current_game.txt" ] && sed -i "s/^playing|/browse|/" "%s/current_game.txt"\n' "$BASE_DIR" "$BASE_DIR" > "${ES_SCRIPTS}/game-end/marquee.sh"
    chmod +x "${ES_SCRIPTS}/"*"/marquee.sh"
    start_host_services "$BIND_SCOPE" "$ROMS_ROOT" "$THEMES_ROOT" "${SYS_ROOT}/custom.sh"
}

setup_host() {
    local BIND_SCOPE="$1"
    echo "1) Batocera  2) Recalbox  3) EmuELEC/ROCKNIX  4) Attract-Mode  5) RetroPie  6) Pegasus  7) Lakka"
    read -p "Select frontend [1-7, Detected: ${FRONTEND^^}]: " FE_CHOICE
    [ -z "$FE_CHOICE" ] && case "$FRONTEND" in
        batocera) FE_CHOICE=1 ;; recalbox) FE_CHOICE=2 ;; emuelec) FE_CHOICE=3 ;;
        attractmode) FE_CHOICE=4 ;; retropie) FE_CHOICE=5 ;; pegasus) FE_CHOICE=6 ;; lakka) FE_CHOICE=7 ;; *) FE_CHOICE=1 ;;
    esac
    case "$FE_CHOICE" in
        1) FRONTEND="batocera"; install_es_hooks "/userdata/system" "/userdata/roms" "/userdata/themes" "/userdata/system/configs/emulationstation/scripts" "$BIND_SCOPE" ;;
        2) FRONTEND="recalbox"; install_es_hooks "/recalbox/share/system" "/recalbox/share/roms" "/recalbox/share/themes" "/recalbox/share/system/configs/emulationstation/scripts" "$BIND_SCOPE" ;;
        3) FRONTEND="emuelec"; install_es_hooks "/storage/.config" "/storage/roms" "/storage/.config/emulationstation/themes" "/storage/.config/emulationstation/scripts" "$BIND_SCOPE" ;;
        4)
            FRONTEND="attractmode"; AM_DIR="/root/.attract"; for d in /home/*/.attract; do [ -d "$d" ] && AM_DIR="$d" && break; done
            mkdir -p "${AM_DIR}/plugins"
            cat << EOF > "${AM_DIR}/plugins/ArcadeMarquee.nut"
fe.add_transition_callback("arcade_marquee_transition");
function arcade_marquee_transition(ttype, var, ttime) {
    local sys = fe.game_info(Info.Emulator); local rom = fe.game_info(Info.Name);
    if (ttype == Transition.ToNewSelection || ttype == Transition.StartLayout || ttype == Transition.FromGame)
        system("printf 'browse|%s|%s\\n' '" + sys + "' '" + rom + "' > ${BASE_DIR}/current_game.txt");
    else if (ttype == Transition.ToGame)
        system("printf 'playing|%s|%s\\n' '" + sys + "' '" + rom + "' > ${BASE_DIR}/current_game.txt");
    return false;
}
EOF
            read -p "ROMs root path: " ROMS_ROOT; read -p "Themes root path: " THEMES_ROOT
            start_host_services "$BIND_SCOPE" "$ROMS_ROOT" "$THEMES_ROOT" "" ;;
        5)
            FRONTEND="retropie"; mkdir -p /opt/retropie/configs/all
            ROMS_ROOT="/home/pi/RetroPie/roms"; [ ! -d "$ROMS_ROOT" ] && ROMS_ROOT=$(ls -d /home/*/RetroPie/roms 2>/dev/null | head -n 1)
            detect_theme_logo_path "/etc/emulationstation/themes" > "${BASE_DIR}/theme_path.txt"
            touch /opt/retropie/configs/all/runcommand-onstart.sh /opt/retropie/configs/all/runcommand-onend.sh
            sed -i '/# Arcade Marquee Hook/d;/current_game.txt/d' /opt/retropie/configs/all/runcommand-onstart.sh /opt/retropie/configs/all/runcommand-onend.sh
            printf '# Arcade Marquee Hook\nprintf "playing|%%s|%%s\\n" "$1" "$(basename "$3" | sed "s/\\.[^.]*$//")" > "%s/current_game.txt"\n' "$BASE_DIR" >> /opt/retropie/configs/all/runcommand-onstart.sh
            printf '# Arcade Marquee Hook\n[ -f "%s/current_game.txt" ] && sed -i "s/^playing|/browse|/" "%s/current_game.txt"\n' "$BASE_DIR" "$BASE_DIR" >> /opt/retropie/configs/all/runcommand-onend.sh
            chmod +x /opt/retropie/configs/all/runcommand-onstart.sh /opt/retropie/configs/all/runcommand-onend.sh
            start_host_services "$BIND_SCOPE" "$ROMS_ROOT" "/etc/emulationstation/themes" "" ;;
        6)
            FRONTEND="pegasus"
            printf '#!/bin/bash\nROM_PATH="$1"; SYS_NAME="$2"; shift 2; ROM_NAME=$(basename "$ROM_PATH" | sed "s/\\.[^.]*$//")\nprintf "playing|%%s|%%s\\n" "$SYS_NAME" "$ROM_NAME" > "%s/current_game.txt"; "$@"\nprintf "browse|%%s|%%s\\n" "$SYS_NAME" "$ROM_NAME" > "%s/current_game.txt"\n' "$BASE_DIR" "$BASE_DIR" > "${BASE_DIR}/pegasus_launch_wrapper.sh"
            chmod +x "${BASE_DIR}/pegasus_launch_wrapper.sh"
            read -p "ROMs root path: " ROMS_ROOT; read -p "Themes root path: " THEMES_ROOT
            start_host_services "$BIND_SCOPE" "$ROMS_ROOT" "$THEMES_ROOT" "" ;;
        7) FRONTEND="lakka"; echo "boot|lakka|default" > "${BASE_DIR}/current_game.txt"; start_host_services "$BIND_SCOPE" "/storage/roms" "/storage/assets" "/storage/.config/autostart.sh" ;;
        *) exit 1 ;;
    esac
}

setup_client() {
    local CLIENT_MODE="$1"
    install_missing_linux_deps
    fetch_component "client/marquee.sh" "${BASE_DIR}/marquee.sh"
    fetch_component "client/web_ui.py" "${BASE_DIR}/web_ui.py"
    fetch_component "client/hotkey_listener.py" "${BASE_DIR}/hotkey_listener.py"
    chmod +x "${BASE_DIR}/marquee.sh"
    EXISTING_PC_IP=""
    [ -f "${BASE_DIR}/host.conf" ] && EXISTING_PC_IP=$(grep '^PIXELCADE_HW_IP=' "${BASE_DIR}/host.conf" | cut -d'=' -f2 | tr -d '"')
    echo "1) Universal Marquee Native  2) Pixelcade Receiver  3) Hybrid Mode"
    read -p "Choose protocol mode [1-3, Default: 1]: " PROTO_CHOICE
    case "$PROTO_CHOICE" in 2) MARQUEE_MODE="pixelcade_rx" ;; 3) MARQUEE_MODE="hybrid" ;; *) MARQUEE_MODE="native" ;; esac
    if [ "$CLIENT_MODE" = "local" ]; then
        HOST_IP="127.0.0.1"; AUTO_DISCOVER="false"; PIXELCADE_HW_IP="$EXISTING_PC_IP"
        [ "$FRONTEND" = "batocera" ] && LOCAL_ROMS="/userdata/roms" && LOCAL_THEMES="/userdata/themes"
        [ "$FRONTEND" = "recalbox" ] && LOCAL_ROMS="/recalbox/share/roms" && LOCAL_THEMES="/recalbox/share/themes"
        [ "$FRONTEND" = "emuelec" ] && LOCAL_ROMS="/storage/roms" && LOCAL_THEMES="/storage/.config/emulationstation/themes"
        [ "$FRONTEND" = "retropie" ] && LOCAL_ROMS="/home/pi/RetroPie/roms" && LOCAL_THEMES="/etc/emulationstation/themes"
        [ ! -d "$LOCAL_ROMS" ] && read -p "Local ROMs path: " LOCAL_ROMS && read -p "Local Themes path: " LOCAL_THEMES
        DEFAULT_THEME=$(detect_theme_logo_path "$LOCAL_THEMES")
        CONNECTED_PORTS=()
        for drm in /sys/class/drm/card*-*; do
            [ -d "$drm" ] && [ "$(cat "$drm/status" 2>/dev/null)" = "connected" ] && CONNECTED_PORTS+=("$(basename "$drm" | sed -E 's/^card[0-9]+-//')")
        done
        FIRST_PORT="${CONNECTED_PORTS[@]:0:1}"; SECOND_PORT="${CONNECTED_PORTS[@]:1:1}"
        SUGGESTED_PORT="${SECOND_PORT:-${FIRST_PORT:-auto}}"
        [ -e "/dev/fb1" ] && DEFAULT_BACKEND="1" || DEFAULT_BACKEND="2"
        echo "1) Headless Framebuffer/DRM (/dev/fb1)  2) X11/Wayland Window Mode"
        read -p "Rendering backend [1-2, Suggested: ${DEFAULT_BACKEND}]: " BACKEND_CHOICE
        BACKEND_CHOICE=${BACKEND_CHOICE:-"$DEFAULT_BACKEND"}
        if [ "$BACKEND_CHOICE" = "2" ]; then
            RENDER_BACKEND="window"; FB_DEV="/dev/fb0"; DRM_CONN="$SUGGESTED_PORT"; SUGGESTED_GEOM="1920x440+1920+0"
            if command -v xrandr >/dev/null 2>&1; then
                PARSED=$(DISPLAY=:0.0 xrandr --query 2>/dev/null | grep " connected" | sed -n '2p' | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+')
                [ -n "$PARSED" ] && SUGGESTED_GEOM="$PARSED"
            fi
            read -p "Window Geometry WxH+X+Y [Detected: ${SUGGESTED_GEOM}]: " WIN_GEOM; WIN_GEOM=${WIN_GEOM:-"$SUGGESTED_GEOM"}
        else
            RENDER_BACKEND="drm"; WIN_GEOM=""
            [ -e "/dev/fb1" ] && SUGGESTED_FB="/dev/fb1" || SUGGESTED_FB="/dev/fb0"
            read -p "Framebuffer [Suggested: ${SUGGESTED_FB}]: " FB_DEV; FB_DEV=${FB_DEV:-"$SUGGESTED_FB"}
            read -p "DRM Connector [Suggested: ${SUGGESTED_PORT}]: " DRM_CONN; DRM_CONN=${DRM_CONN:-"$SUGGESTED_PORT"}
        fi
    else
        RENDER_BACKEND="drm"; WIN_GEOM=""; LOCAL_ROMS=""; LOCAL_THEMES=""; FB_DEV="/dev/fb0"; DRM_CONN="auto"
        if [ "$MARQUEE_MODE" = "pixelcade_rx" ]; then
            HOST_IP="pixelcade"; AUTO_DISCOVER="false"
        else
            DISCOVERED_IP=$(python3 -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(5.0); s.bind(("",8126)); d,a=s.recvfrom(1024); print(next(iter(a))) if b"ARCADE_MARQUEE_HOST" in d else None' 2>/dev/null)
            if [ -n "$DISCOVERED_IP" ]; then
                read -p "Found Host at ${DISCOVERED_IP}. Press Enter to lock or type IP: " INPUT_IP
                HOST_IP=${INPUT_IP:-"$DISCOVERED_IP"}; AUTO_DISCOVER="false"
            else
                read -p "Host IP (blank for auto-discovery): " HOST_IP
                [ -z "$HOST_IP" ] && HOST_IP="auto" && AUTO_DISCOVER="true" || AUTO_DISCOVER="false"
            fi
        fi
        [ "$HOST_IP" != "auto" ] && [ "$HOST_IP" != "pixelcade" ] && REMOTE_THEME=$(curl -s -f --connect-timeout 3 "${HOST_IP}:8123/state/theme_path.txt" | tr -d '\r\n')
        DEFAULT_THEME=${REMOTE_THEME:-"es-theme-carbon/art/logos"}
        read -p "Optional Official Pixelcade Hardware IP: " PIXELCADE_HW_IP
    fi
    echo "1) Auto-Fit  2) Auto-Stretch"
    read -p "Scaling mode [1-2, Default: 1]: " SCALE_CHOICE
    [ "$SCALE_CHOICE" = "2" ] && SCALE_MODE="stretch" || SCALE_MODE="fit"
    read -p "Physical LCD Width (blank for auto, e.g. 1920): " PHYS_W
    read -p "Physical LCD Height (blank for auto, e.g. 440): " PHYS_H
    read -p "Theme logo path [Detected: ${DEFAULT_THEME}]: " INPUT_THEME; THEME_PATH=${INPUT_THEME:-"$DEFAULT_THEME"}
    read -p "Enable .mp4 video marquees? [Y/n]: " VC; [[ "$VC" =~ ^[Nn]$ ]] && ENABLE_VIDEO="false" || ENABLE_VIDEO="true"
    read -p "Show controller overlays? [Y/n]: " CC; [[ "$CC" =~ ^[Nn]$ ]] && ENABLE_CONTROLS="false" || ENABLE_CONTROLS="true"
    read -p "Display High Scores on Marquee? [Y/n]: " HC; [[ "$HC" =~ ^[Nn]$ ]] && ENABLE_HIGHSCORES="false" || ENABLE_HIGHSCORES="true"
    read -p "Enable Idle Attract Slideshow (5m)? [Y/n]: " AC; [[ "$AC" =~ ^[Nn]$ ]] && ATTRACT_IDLE_SEC="0" || ATTRACT_IDLE_SEC="300"
    read -p "Enable Web Dashboard & Pixelcade API (8080)? [Y/n]: " WC; [[ "$WC" =~ ^[Nn]$ ]] && ENABLE_WEB_UI="false" || ENABLE_WEB_UI="true"
    WEB_PASS_HASH=""; WEB_PASS_SALT=""
    if [ "$ENABLE_WEB_UI" = "true" ]; then
        read -s -p "Optional Web Password (blank for none): " RAW_PASS; echo ""
        if [ -n "$RAW_PASS" ]; then
            HASH_OUT=$(python3 -c "import os,hashlib,sys; pw=sys.argv.pop(); s=os.urandom(16).hex(); dk=hashlib.pbkdf2_hmac('sha256',pw.encode(),bytes.fromhex(s),100000).hex(); print(f'{s}:{dk}')" "$RAW_PASS")
            WEB_PASS_SALT=$(echo "$HASH_OUT" | cut -d':' -f1); WEB_PASS_HASH=$(echo "$HASH_OUT" | cut -d':' -f2)
        fi
    fi
    read -p "Optional custom banner text overlay: " OVERLAY_TEXT
    MEDIA_DIR="${BASE_DIR}/marquees"
    mkdir -p "${MEDIA_DIR}/custom/startup" "${MEDIA_DIR}/custom/systems" "${MEDIA_DIR}/custom/controls" "${MEDIA_DIR}/custom/effects" "${MEDIA_DIR}/systems"
    cat << EOF > "${BASE_DIR}/marquee.conf"
CLIENT_MODE="${CLIENT_MODE}"
MARQUEE_MODE="${MARQUEE_MODE}"
RENDER_BACKEND="${RENDER_BACKEND}"
WIN_GEOM="${WIN_GEOM}"
HOST_IP="${HOST_IP}"
AUTO_DISCOVER="${AUTO_DISCOVER}"
PIXELCADE_HW_IP="${PIXELCADE_HW_IP}"
BASE_DIR="${BASE_DIR}"
MEDIA_DIR="${MEDIA_DIR}"
LOCAL_ROMS="${LOCAL_ROMS}"
LOCAL_THEMES="${LOCAL_THEMES}"
THEME_PATH="${THEME_PATH}"
FB_DEV="${FB_DEV}"
DRM_CONN="${DRM_CONN}"
SCALE_MODE="${SCALE_MODE}"
PHYS_W="${PHYS_W}"
PHYS_H="${PHYS_H}"
ENABLE_VIDEO="${ENABLE_VIDEO}"
ENABLE_CONTROLS="${ENABLE_CONTROLS}"
ENABLE_HIGHSCORES="${ENABLE_HIGHSCORES}"
ATTRACT_IDLE_SEC="${ATTRACT_IDLE_SEC}"
ATTRACT_INTERVAL_SEC="15"
SLEEP_START=""
SLEEP_END=""
ENABLE_WEB_UI="${ENABLE_WEB_UI}"
WEB_PASS_SALT="${WEB_PASS_SALT}"
WEB_PASS_HASH="${WEB_PASS_HASH}"
OVERLAY_TEXT="${OVERLAY_TEXT}"
OVERLAY_EFFECT="none"
EOF
    chmod 600 "${BASE_DIR}/marquee.conf"
    if [ "$CLIENT_MODE" = "network" ] && [ "$HOST_IP" != "auto" ] && [ "$HOST_IP" != "pixelcade" ]; then
        curl -s -f --connect-timeout 5 "${HOST_IP}:8123/state/marquees.tar.gz" -o /tmp/marquees.tar.gz && tar -xzf /tmp/marquees.tar.gz -C "${MEDIA_DIR}/" && rm -f /tmp/marquees.tar.gz
    fi
    if [ "$FRONTEND" = "batocera" ] || [ "$FRONTEND" = "recalbox" ] || [ "$FRONTEND" = "emuelec" ]; then
        [ "$FRONTEND" = "batocera" ] && SYS_ROOT="/userdata/system"
        [ "$FRONTEND" = "recalbox" ] && SYS_ROOT="/recalbox/share/system"
        [ "$FRONTEND" = "emuelec" ] && SYS_ROOT="/storage/.config"
        touch "${SYS_ROOT}/custom.sh"; sed -i '/# Arcade Marquee Local Client/d;/marquee.sh/d' "${SYS_ROOT}/custom.sh"
        printf '\n# Arcade Marquee Local Client\nchvt 3 2>/dev/null\n"%s/marquee.sh" >/dev/null 2>&1 &\n' "$BASE_DIR" >> "${SYS_ROOT}/custom.sh"
        chmod +x "${SYS_ROOT}/custom.sh"
    elif command -v systemctl >/dev/null 2>&1; then
        cat << EOF > /etc/systemd/system/arcade-marquee.service
[Unit]
Description=Arcade Marquee Display Client
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStartPre=/bin/chvt 3
ExecStart=${BASE_DIR}/marquee.sh
Restart=always
RestartSec=2
StandardInput=tty
TTYPath=/dev/tty3
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable arcade-marquee.service
    fi
}

case "$ACTION" in
    5)
        fetch_component "marquee_manager.sh" "${INSTALL_PATH}.tmp" && mv "${INSTALL_PATH}.tmp" "$INSTALL_PATH" && chmod +x "$INSTALL_PATH"
        [ -f "${BASE_DIR}/marquee.sh" ] && fetch_component "client/marquee.sh" "${BASE_DIR}/marquee.sh" && chmod +x "${BASE_DIR}/marquee.sh"
        [ -f "${BASE_DIR}/web_ui.py" ] && fetch_component "client/web_ui.py" "${BASE_DIR}/web_ui.py"
        [ -f "${BASE_DIR}/hotkey_listener.py" ] && fetch_component "client/hotkey_listener.py" "${BASE_DIR}/hotkey_listener.py"
        [ -f "${BASE_DIR}/host_server.py" ] && fetch_component "host/host_server.py" "${BASE_DIR}/host_server.py"
        touch /dev/shm/marquee_force_refresh && exec "$INSTALL_PATH" ;;
    2)
        mkdir -p "$BACKUP_DIR"
        ARCHIVE="${BACKUP_DIR}/marquee_${FRONTEND}_$(date +"%Y%m%d_%H%M%S").tar.gz"
        tar -czf "$ARCHIVE" "$BASE_DIR" /userdata/system/custom.sh /userdata/system/configs/emulationstation/scripts /recalbox/share/system/custom.sh /recalbox/share/system/configs/emulationstation/scripts /storage/.config/custom.sh /storage/.config/emulationstation/scripts /opt/retropie/configs/all/runcommand-onstart.sh /opt/retropie/configs/all/runcommand-onend.sh /etc/systemd/system/arcade-marquee.service /etc/systemd/system/arcade-marquee-host.service 2>/dev/null
        echo "Backup saved to ${ARCHIVE}"; exit 0 ;;
    3)
        [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" ] && echo "No backups found." && exit 1
        ls -1 "$BACKUP_DIR"/*.tar.gz | nl; read -p "Backup number: " B_NUM
        SEL=$(ls -1 "$BACKUP_DIR"/*.tar.gz | sed -n "${B_NUM}p"); [ ! -f "$SEL" ] && exit 1
        tar -xzf "$SEL" -C / && chmod +x "${BASE_DIR}/marquee.sh" "$INSTALL_PATH" 2>/dev/null
        read -p "Restore complete! Press Enter to reboot..." && reboot; exit 0 ;;
    4)
        read -p "Uninstall all marquee scripts? [y/N]: " CONFIRM; [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0
        pkill -f "host_server.py|web_ui.py|hotkey_listener.py|marquee.sh|mpv.marquee_player" 2>/dev/null; killall fbi 2>/dev/null
        command -v systemctl >/dev/null 2>&1 && systemctl disable --now arcade-marquee.service arcade-marquee-host.service 2>/dev/null && rm -f /etc/systemd/system/arcade-marquee.service && systemctl daemon-reload
        for SR in /userdata/system /recalbox/share/system /storage/.config; do
            [ -d "$SR" ] && rm -f "${SR}/configs/emulationstation/scripts/"*/marquee.sh "${SR}/emulationstation/scripts/"*/marquee.sh 2>/dev/null
            for SF in "${SR}/custom.sh" "${SR}/autostart.sh"; do [ -f "$SF" ] && sed -i '/# Arcade Marquee/d;/host_server.py/d;/marquee.sh/d' "$SF"; done
        done
        read -p "Also delete artwork in ${BASE_DIR}/marquees? [y/N]: " DEL_IMG; [[ "$DEL_IMG" =~ ^[Yy]$ ]] && rm -rf "${BASE_DIR}/marquees"
        rm -f "${BASE_DIR}/marquee.sh" "${BASE_DIR}/marquee.conf" "${BASE_DIR}/host.conf" "${BASE_DIR}/web_ui.py" "${BASE_DIR}/hotkey_listener.py" "${BASE_DIR}/host_server.py" "${BASE_DIR}/current_game.txt" "${BASE_DIR}/theme_path.txt" "${BASE_DIR}/marquees.tar.gz"
        read -p "Reverted to stock. Press Enter to reboot..." && reboot; exit 0 ;;
    1)
        echo "1) Arcade Host Only  2) Network Marquee Client Only  3) Standalone All-in-One"
        read -p "Choose role [1-3]: " ROLE
        case "$ROLE" in
            1) setup_host "network"; echo "Host active on port 8123 (IP: $(hostname -I | awk '{print $1}'))" ;;
            2) setup_client "network"; echo "Client ready! Web UI: http://$(hostname -I | awk '{print $1}'):8080"; read -p "Press Enter to reboot..." && reboot ;;
            3) read -p "Expose Host to network? [y/N]: " AN; [[ "$AN" =~ ^[Yy]$ ]] && SC="network" || SC="local"; setup_host "$SC"; setup_client "local"; echo "All-in-One ready! Web UI: http://$(hostname -I | awk '{print $1}'):8080"; read -p "Press Enter to reboot..." && reboot ;;
            *) echo "Invalid role."; exit 1 ;;
        esac ;;
    *) echo "Invalid option."; exit 1 ;;
esac