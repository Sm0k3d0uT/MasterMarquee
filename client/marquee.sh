#!/bin/bash
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONF_FILE="${SCRIPT_DIR}/marquee.conf"
source "$CONF_FILE"
LAST_STATE=""
LAST_ACTIVITY=$(date +%s)
LAST_ATTRACT=0
IS_SLEEPING="false"

# Silence tty3 for clean flicker-free framebuffer transitions
if [ "$RENDER_BACKEND" != "window" ]; then
  TERM=linux setterm -cursor off -blank 0 -foreground black -background black >/dev/tty3 2>/dev/null
  clear >/dev/tty3 2>/dev/null
fi

detect_screen_res() {
  if [ "$RENDER_BACKEND" = "window" ] && [ -n "$WIN_GEOM" ]; then
    local WH=$(echo "$WIN_GEOM" | cut -d'+' -f1)
    SCREEN_W=$(echo "$WH" | cut -d'x' -f1)
    SCREEN_H=$(echo "$WH" | cut -d'x' -f2)
  else
    local FB_NODE=$(basename "$FB_DEV")
    if [ -f "/sys/class/graphics/${FB_NODE}/virtual_size" ]; then
      local SIZE=$(cat "/sys/class/graphics/${FB_NODE}/virtual_size")
      SCREEN_W=$(echo "$SIZE" | cut -d',' -f1)
      SCREEN_H=$(echo "$SIZE" | cut -d',' -f2)
    elif command -v fbset >/dev/null 2>&1; then
      local GEOM=$(fbset -fb "$FB_DEV" 2>/dev/null | grep "geometry")
      SCREEN_W=$(echo "$GEOM" | awk '{print $2}')
      SCREEN_H=$(echo "$GEOM" | awk '{print $3}')
    fi
  fi
  SCREEN_W=${SCREEN_W:-1920}
  SCREEN_H=${SCREEN_H:-1080}
}

detect_screen_res

if [ "$ENABLE_WEB_UI" = "true" ]; then
  pkill -f "web_ui.py" 2>/dev/null
  python3 "${SCRIPT_DIR}/web_ui.py" >/dev/null 2>&1 &
fi

urlencode() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv.pop()))" "$1"
}

discover_host() {
  python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2.0)
s.bind(("", 8126))
try:
    data, addr = s.recvfrom(1024)
    if b"ARCADE_MARQUEE_HOST" in data:
        print(next(iter(addr)))
except Exception:
    pass
' 2>/dev/null
}

find_media() {
  local base="$1"
  local allow_vid="$2"
  if [ "$allow_vid" = "true" ] && [ "$ENABLE_VIDEO" = "true" ]; then
    for ext in mp4 MP4 mkv MKV; do
      [ -f "${base}.${ext}" ] && echo "${base}.${ext}" && return 0
    done
  fi
  for ext in png jpg jpeg svg PNG JPG JPEG SVG; do
    [ -f "${base}.${ext}" ] && echo "${base}.${ext}" && return 0
  done
  return 1
}

render_media() {
  local file="$1"
  local label="$2"
  local hiscore="$3"
  [ ! -f "$file" ] && [ -z "$hiscore" ] && return

  detect_screen_res
  local TARGET_W="${PHYS_W:-$SCREEN_W}"
  local TARGET_H="${PHYS_H:-$SCREEN_H}"

  printf '%s (%sx%s)\n' "${label:-$(basename "$file")}" "$TARGET_W" "$TARGET_H" > /dev/shm/marquee_now.txt

  local OLD_FBI=$(pgrep -f "fbi.*$FB_DEV")
  local OLD_MPV=$(pgrep -f "mpv.*marquee_player")
  local RENDER_FILE="$file"
  local PREVIEW_PNG="/dev/shm/marquee_display.png"
  local FAST_BMP="/dev/shm/marquee_display.bmp"

  # Generate dynamic scoreboard canvas if no image file exists but high score is present
  if [ ! -f "$RENDER_FILE" ] && [ -n "$hiscore" ] && command -v convert >/dev/null 2>&1; then
    convert -size "${TARGET_W}x${TARGET_H}" xc:black \
      -gravity center -fill "#facc15" -pointsize 56 -annotate +0-40 "${label}" \
      -gravity center -fill white -pointsize 48 -annotate +0+45 "${hiscore}" \
      "$PREVIEW_PNG"
    RENDER_FILE="$PREVIEW_PNG"
  fi

  if [[ ! "$RENDER_FILE" =~ \.(mp4|MP4|mkv|MKV)$ ]]; then
    if [[ "$RENDER_FILE" =~ \.(svg|SVG)$ ]]; then
      if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w "$TARGET_W" -h "$TARGET_H" -a "$RENDER_FILE" -o /dev/shm/svg_rendered.png
        RENDER_FILE="/dev/shm/svg_rendered.png"
      elif command -v convert >/dev/null 2>&1; then
        convert -background none "$RENDER_FILE" /dev/shm/svg_rendered.png
        RENDER_FILE="/dev/shm/svg_rendered.png"
      fi
    fi

    [ "$SCALE_MODE" = "stretch" ] && RESIZE_ARG="${TARGET_W}x${TARGET_H}!" || RESIZE_ARG="${TARGET_W}x${TARGET_H}"

    if command -v convert >/dev/null 2>&1; then
      local STRETCH_CMD=""
      if [ "$TARGET_W" != "$SCREEN_W" ] || [ "$TARGET_H" != "$SCREEN_H" ]; then
        STRETCH_CMD="-resize ${SCREEN_W}x${SCREEN_H}!"
      fi

      local ANNOTATE_ARGS=()
      if [ -n "$hiscore" ]; then
        ANNOTATE_ARGS+=(-gravity north -fill "#facc15" -stroke black -strokewidth 2 -pointsize 38 -annotate +0+16 "$hiscore")
      fi
      if [ -n "$OVERLAY_TEXT" ]; then
        ANNOTATE_ARGS+=(-gravity south -fill white -stroke black -strokewidth 2 -pointsize 42 -annotate +0+20 "$OVERLAY_TEXT")
      fi

      convert "$RENDER_FILE" -background black -gravity center -resize "$RESIZE_ARG" -extent "${TARGET_W}x${TARGET_H}" \
        "${ANNOTATE_ARGS[@]}" \
        -write "$PREVIEW_PNG" $STRETCH_CMD "BMP3:${FAST_BMP}"
      RENDER_FILE="$FAST_BMP"
    else
      cp -f "$RENDER_FILE" "$PREVIEW_PNG" 2>/dev/null
    fi
  fi

  local MPV_OSD=()
  if [ -n "$hiscore" ]; then
    MPV_OSD=(--osd-level=1 --osd-align-y=top --osd-font-size=36 --osd-color="#FFFACC15" --osd-msg1="$hiscore")
  fi

  if [ "$RENDER_BACKEND" = "window" ]; then
    local DISPLAY_TARGET="${DISPLAY:-:0.0}"
    local ASPECT_ARG=""
    [ "$SCALE_MODE" = "stretch" ] && ASPECT_ARG="--panscan=1.0 --video-aspect-override=${TARGET_W}:${TARGET_H}"
    DISPLAY="$DISPLAY_TARGET" mpv --title=marquee_player --no-border --ontop --no-osc --no-input-default-bindings \
      --geometry="$WIN_GEOM" --image-display-duration=inf --loop-file=inf --no-audio $ASPECT_ARG "${MPV_OSD[@]}" "$PREVIEW_PNG" &>/dev/null &
  elif [[ "$RENDER_FILE" =~ \.(mp4|MP4|mkv|MKV)$ ]]; then
    DRM_ARG=""
    [ "$DRM_CONN" != "auto" ] && [ -n "$DRM_CONN" ] && DRM_ARG="--drm-connector=${DRM_CONN}"
    if [ "$SCALE_MODE" = "stretch" ] || [ "$TARGET_H" != "$SCREEN_H" ]; then
      mpv --title=marquee_player --vo=drm $DRM_ARG --hwdec=auto --loop=inf --no-audio --panscan=1.0 --video-aspect-override="${SCREEN_W}:${SCREEN_H}" "${MPV_OSD[@]}" "$RENDER_FILE" &>/dev/null &
    else
      mpv --title=marquee_player --vo=drm $DRM_ARG --hwdec=auto --loop=inf --no-audio "${MPV_OSD[@]}" "$RENDER_FILE" &>/dev/null &
    fi
  else
    fbi -d "$FB_DEV" --noverbose -T 3 "$RENDER_FILE" </dev/tty3 >/dev/null 2>&1 &
  fi

  sleep 0.08
  [ -n "$OLD_FBI" ] && kill $OLD_FBI 2>/dev/null
  [ -n "$OLD_MPV" ] && kill $OLD_MPV 2>/dev/null
}

check_night_sleep() {
  [ -z "$SLEEP_START" ] || [ -z "$SLEEP_END" ] && return 1
  local NOW=$(date +%H:%M)
  if [[ "$SLEEP_START" < "$SLEEP_END" ]]; then
    [[ "$NOW" > "$SLEEP_START" && "$NOW" < "$SLEEP_END" ]] && return 0
  else
    [[ "$NOW" > "$SLEEP_START" || "$NOW" < "$SLEEP_END" ]] && return 0
  fi
  return 1
}

DEFAULT_MEDIA=$(find_media "${MEDIA_DIR}/custom/startup/default" "true")
[ -n "$DEFAULT_MEDIA" ] && render_media "$DEFAULT_MEDIA" "Boot Splash" ""

while true; do
  source "$CONF_FILE"

  if [ -f /dev/shm/marquee_force_refresh ]; then
    rm -f /dev/shm/marquee_force_refresh
    LAST_STATE=""
  fi
  if [ -f /dev/shm/marquee_test_splash ]; then
    rm -f /dev/shm/marquee_test_splash
    SPLASH=$(find_media "${MEDIA_DIR}/custom/startup/default" "true")
    [ -n "$SPLASH" ] && render_media "$SPLASH" "Test Splash Screen" ""
  fi
  if [ -f /dev/shm/marquee_test_attract ]; then
    rm -f /dev/shm/marquee_test_attract
    SEARCH_PATH="$MEDIA_DIR"
    [ "$CLIENT_MODE" = "local" ] && [ -d "$LOCAL_ROMS" ] && SEARCH_PATH="$LOCAL_ROMS"
    RAND_IMG=$(find "$SEARCH_PATH" -type f \( -iname "*-marquee.png" -o -iname "*.jpg" -o -iname "*.png" \) ! -path "*/controls/*" 2>/dev/null | shuf -n 1)
    [ -n "$RAND_IMG" ] && render_media "$RAND_IMG" "Attract Mode Preview" ""
  fi

  if check_night_sleep; then
    if [ "$IS_SLEEPING" = "false" ]; then
      IS_SLEEPING="true"
      pkill -f "fbi.*$FB_DEV" 2>/dev/null
      pkill -f "mpv.*marquee_player" 2>/dev/null
      [ "$RENDER_BACKEND" != "window" ] && dd if=/dev/zero of="$FB_DEV" bs=4096 count=2048 2>/dev/null
    fi
    sleep 5
    continue
  elif [ "$IS_SLEEPING" = "true" ]; then
    IS_SLEEPING="false"
    LAST_STATE=""
  fi

  RAW_LINE=""
  if [ "$MARQUEE_MODE" = "pixelcade_rx" ]; then
    RAW_LINE=$(cat /dev/shm/pixelcade_state.txt 2>/dev/null | tr -d '\r\n')
  elif [ "$MARQUEE_MODE" = "hybrid" ] && [ -f /dev/shm/pixelcade_state.txt ]; then
    RAW_LINE=$(cat /dev/shm/pixelcade_state.txt 2>/dev/null | tr -d '\r\n')
  elif [ "$CLIENT_MODE" = "network" ]; then
    if [ "$HOST_IP" = "auto" ] || [ -z "$HOST_IP" ]; then
      FOUND=$(discover_host)
      if [ -n "$FOUND" ]; then
        HOST_IP="$FOUND"
        sed -i "s|^HOST_IP=.*|HOST_IP=\"${HOST_IP}\"|" "$CONF_FILE"
        sed -i 's|^AUTO_DISCOVER=.*|AUTO_DISCOVER="false"|' "$CONF_FILE"
      fi
    fi
    [ "$HOST_IP" != "auto" ] && RAW_LINE=$(curl -s -f --connect-timeout 1 "${HOST_IP}:8123/state/current_game.txt" | tr -d '\r\n')
  else
    RAW_LINE=$(cat "${BASE_DIR}/current_game.txt" 2>/dev/null | tr -d '\r\n')
  fi

  NOW_SEC=$(date +%s)

  if [ -n "$RAW_LINE" ] && [ "$RAW_LINE" != "$LAST_STATE" ]; then
    LAST_STATE="$RAW_LINE"
    LAST_ACTIVITY=$NOW_SEC
    MODE=$(echo "$RAW_LINE" | cut -d'|' -f1)
    SYS=$(echo "$RAW_LINE" | cut -d'|' -f2)
    ROM=$(echo "$RAW_LINE" | cut -d'|' -f3)
    URL_ROM=$(urlencode "$ROM")
    URL_SYS=$(urlencode "$SYS")
    MEDIA=""
    HISCORE=""

    if [ "${ENABLE_HIGHSCORES:-true}" = "true" ] && [ "$MODE" != "system" ] && [ "$SYS" != "system" ]; then
      SCORE_HOST="${HOST_IP:-127.0.0.1}"
      [ "$SCORE_HOST" != "auto" ] && [ "$SCORE_HOST" != "pixelcade" ] && HISCORE=$(curl -s -f --connect-timeout 1 "http://${SCORE_HOST}:8123/highscore/${URL_SYS}/${URL_ROM}" 2>/dev/null | tr -d '\r\n')
    fi

    if [ -n "$PIXELCADE_HW_IP" ]; then
      PC_EVT="GameSelect"
      [ "$MODE" = "playing" ] && PC_EVT="GameStart"
      [ "$MODE" = "system" ] && PC_EVT="SystemSelect"
      curl -s -f --connect-timeout 1 "http://${PIXELCADE_HW_IP}:8080/arcade/stream/${URL_SYS}/${URL_ROM}?event=${PC_EVT}" >/dev/null 2>&1 &
    fi

    if [ "$MODE" = "playing" ] && [ "$ENABLE_CONTROLS" = "true" ]; then
      MEDIA=$(find_media "${MEDIA_DIR}/custom/controls/${SYS}/${ROM}" "true")
      [ -z "$MEDIA" ] && MEDIA=$(find_media "${MEDIA_DIR}/custom/controls/${SYS}" "true")
      [ -z "$MEDIA" ] && MEDIA=$(find_media "${MEDIA_DIR}/custom/controls/default" "true")
    fi

    if [ -z "$MEDIA" ] && [ "$MODE" = "system" ]; then
      MEDIA=$(find_media "${MEDIA_DIR}/custom/systems/${ROM}" "true")
      if [ -z "$MEDIA" ]; then
        if [ "$CLIENT_MODE" = "local" ]; then
          for EXT in png svg; do
            [ -f "${LOCAL_THEMES}/${THEME_PATH}/us/${ROM}.${EXT}" ] && MEDIA="${LOCAL_THEMES}/${THEME_PATH}/us/${ROM}.${EXT}" && break
            [ -f "${LOCAL_THEMES}/${THEME_PATH}/${ROM}.${EXT}" ] && MEDIA="${LOCAL_THEMES}/${THEME_PATH}/${ROM}.${EXT}" && break
          done
        elif [ "$HOST_IP" != "auto" ] && [ "$HOST_IP" != "pixelcade" ]; then
          LOCAL_DIR="${MEDIA_DIR}/systems"
          mkdir -p "$LOCAL_DIR"
          for EXT in png svg; do
            SYS_IMG="${LOCAL_DIR}/${ROM}.${EXT}"
            if [ -f "$SYS_IMG" ]; then
              curl -s -f -z "$SYS_IMG" "${HOST_IP}:8123/themes/${THEME_PATH}/us/${URL_ROM}.${EXT}" -o "$SYS_IMG" || curl -s -f -z "$SYS_IMG" "${HOST_IP}:8123/themes/${THEME_PATH}/${URL_ROM}.${EXT}" -o "$SYS_IMG"
            else
              curl -s -f "${HOST_IP}:8123/themes/${THEME_PATH}/us/${URL_ROM}.${EXT}" -o "$SYS_IMG" || curl -s -f "${HOST_IP}:8123/themes/${THEME_PATH}/${URL_ROM}.${EXT}" -o "$SYS_IMG" || rm -f "$SYS_IMG"
            fi
            [ -f "$SYS_IMG" ] && MEDIA="$SYS_IMG" && break
          done
        fi
      fi
    fi

    if [ -z "$MEDIA" ] && [ "$SYS" != "system" ]; then
      MEDIA=$(find_media "${MEDIA_DIR}/custom/${SYS}/${ROM}" "true")
      if [ -z "$MEDIA" ]; then
        if [ "$CLIENT_MODE" = "local" ]; then
          [ "$ENABLE_VIDEO" = "true" ] && [ -f "${LOCAL_ROMS}/${SYS}/images/${ROM}-marquee.mp4" ] && MEDIA="${LOCAL_ROMS}/${SYS}/images/${ROM}-marquee.mp4"
          [ -z "$MEDIA" ] && [ -f "${LOCAL_ROMS}/${SYS}/images/${ROM}-marquee.png" ] && MEDIA="${LOCAL_ROMS}/${SYS}/images/${ROM}-marquee.png"
          [ -z "$MEDIA" ] && [ -f "${LOCAL_ROMS}/${SYS}/images/${ROM}-wheel.png" ] && MEDIA="${LOCAL_ROMS}/${SYS}/images/${ROM}-wheel.png"
        elif [ "$HOST_IP" != "auto" ] && [ "$HOST_IP" != "pixelcade" ]; then
          LOCAL_DIR="${MEDIA_DIR}/${SYS}/images"
          mkdir -p "$LOCAL_DIR"
          if [ "$ENABLE_VIDEO" = "true" ]; then
            if [ -f "${LOCAL_DIR}/${ROM}-marquee.mp4" ]; then
              curl -s -f -z "${LOCAL_DIR}/${ROM}-marquee.mp4" "${HOST_IP}:8123/roms/${SYS}/images/${URL_ROM}-marquee.mp4" -o "${LOCAL_DIR}/${ROM}-marquee.mp4"
            else
              curl -s -f "${HOST_IP}:8123/roms/${SYS}/images/${URL_ROM}-marquee.mp4" -o "${LOCAL_DIR}/${ROM}-marquee.mp4" || rm -f "${LOCAL_DIR}/${ROM}-marquee.mp4"
            fi
            [ -f "${LOCAL_DIR}/${ROM}-marquee.mp4" ] && MEDIA="${LOCAL_DIR}/${ROM}-marquee.mp4"
          fi
          if [ -z "$MEDIA" ]; then
            if [ -f "${LOCAL_DIR}/${ROM}-marquee.png" ]; then
              curl -s -f -z "${LOCAL_DIR}/${ROM}-marquee.png" "${HOST_IP}:8123/roms/${SYS}/images/${URL_ROM}-marquee.png" -o "${LOCAL_DIR}/${ROM}-marquee.png"
            else
              curl -s -f "${HOST_IP}:8123/roms/${SYS}/images/${URL_ROM}-marquee.png" -o "${LOCAL_DIR}/${ROM}-marquee.png" || rm -f "${LOCAL_DIR}/${ROM}-marquee.png"
            fi
            [ -f "${LOCAL_DIR}/${ROM}-marquee.png" ] && MEDIA="${LOCAL_DIR}/${ROM}-marquee.png"
          fi
          if [ -z "$MEDIA" ]; then
            if [ -f "${LOCAL_DIR}/${ROM}-wheel.png" ]; then
              curl -s -f -z "${LOCAL_DIR}/${ROM}-wheel.png" "${HOST_IP}:8123/roms/${SYS}/images/${URL_ROM}-wheel.png" -o "${LOCAL_DIR}/${ROM}-wheel.png"
            else
              curl -s -f "${HOST_IP}:8123/roms/${SYS}/images/${URL_ROM}-wheel.png" -o "${LOCAL_DIR}/${ROM}-wheel.png" || rm -f "${LOCAL_DIR}/${ROM}-wheel.png"
            fi
            [ -f "${LOCAL_DIR}/${ROM}-wheel.png" ] && MEDIA="${LOCAL_DIR}/${ROM}-wheel.png"
          fi
        fi
      fi
    fi

    # Only fall back to default boot splash if there is neither game art nor a high score to show
    if [ -z "$MEDIA" ] && [ -z "$HISCORE" ]; then
      MEDIA=$(find_media "${MEDIA_DIR}/custom/startup/default" "true")
    fi

    if [ -n "$MEDIA" ] || [ -n "$HISCORE" ]; then
      render_media "$MEDIA" "${SYS} / ${ROM}" "$HISCORE"
    fi
  elif [ "${ATTRACT_IDLE_SEC:-0}" -gt 0 ] && [ $((NOW_SEC - LAST_ACTIVITY)) -ge "$ATTRACT_IDLE_SEC" ]; then
    if [ $((NOW_SEC - LAST_ATTRACT)) -ge "${ATTRACT_INTERVAL_SEC:-15}" ]; then
      LAST_ATTRACT=$NOW_SEC
      SEARCH_PATH="$MEDIA_DIR"
      [ "$CLIENT_MODE" = "local" ] && [ -d "$LOCAL_ROMS" ] && SEARCH_PATH="$LOCAL_ROMS"
      RAND_IMG=$(find "$SEARCH_PATH" -type f \( -iname "*-marquee.png" -o -iname "*.jpg" -o -iname "*.png" \) ! -path "*/controls/*" 2>/dev/null | shuf -n 1)
      [ -n "$RAND_IMG" ] && render_media "$RAND_IMG" "Attract Mode" ""
    fi
  fi
  sleep 0.2
done