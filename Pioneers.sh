#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi
source $controlfolder/control.txt
get_controls

GAMEDIR=/$directory/ports/pioneers
game_executable="pioneers.aarch64"
ini_filename="pioneers.ini"
game_libs=$GAMEDIR/libs.${DEVICE_ARCH}/:/usr/lib/compat:$LD_LIBRARY_PATH

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

CONFDIR="$GAMEDIR/conf/"
$ESUDO mkdir -p "${CONFDIR}"

# This CFW's whole gdk-pixbuf loaders/ directory is missing (every format,
# not just SVG - confirmed on-device, `ls` on the loaders dir itself fails).
# Setting GDK_PIXBUF_MODULE_FILE also fully REPLACES the module registry
# (built-ins included), so a cache that only lists svg silently breaks
# PNG/JPEG too. Bundled here: our own gdk-pixbuf built with
# -Dbuiltin_loaders=none (so every format, including png/jpeg, is a real
# loadable module we can list), plus librsvg's svg module, in one private
# cache that never touches the system's own loaders.cache.
sed "s#@LIBSDIR@#$GAMEDIR/libs.${DEVICE_ARCH}#" \
  "$GAMEDIR/loaders.cache.tmpl" > "${CONFDIR}/loaders.cache"

# This CFW ships an empty /usr/share/mime (source XML packages only, never
# passed through update-mime-database), so gdk-pixbuf's GIO-based content
# sniffing can't recognize ANY image format, not just missing ones - every
# PNG/JPEG load fails "couldn't recognize format" even with a byte-perfect
# header. Fix: bundle a real compiled mime database. It also has to live off
# exFAT ("/roms" on most CFWs): mime.cache/magic get read via mmap, which
# silently returns garbage over exFAT/FUSE - same root cause as the share/
# bind-mount below, just for GIO's own lookup files instead of game assets.
rm -rf /tmp/pioneers-mime
mkdir -p /tmp/pioneers-mime
cp -r "$GAMEDIR/mime-data/." /tmp/pioneers-mime/
export XDG_DATA_DIRS_PIONEERS="/tmp/pioneers-mime:/usr/share"

# Pioneers is built with its icon/theme paths baked in at /tmp/pioneers-data
# (the only path that's guaranteed writable and identical across every CFW -
# $directory itself varies per CFW, so a compile-time absolute path can't
# point at $GAMEDIR directly). Bind our bundled share/ tree onto it.
$ESUDO mkdir -p /tmp/pioneers-data
if [[ "$PM_CAN_MOUNT" != "N" ]]; then
    $ESUDO umount /tmp/pioneers-data 2>/dev/null
fi
$ESUDO mount --bind "$GAMEDIR/share" /tmp/pioneers-data

# Pioneers' default layout puts the chat/messages panel beside the board
# (fine on a wide 16:9-ish screen) but there's no window manager here to
# enforce a minimum size, so on a narrow/4:3 screen (R36S: 640x480) it just
# overflows and clips. Pioneers already ships a 4:3-friendly layout
# (settings/layout_16_9=0, stacks chat below the board instead) - auto-pick
# it from the device's own reported aspect ratio and seed it into Pioneers'
# GKeyFile config (which lives at $XDG_CONFIG_HOME/pioneers, a different
# path from XDG_DATA_HOME). Only seed on first run, so a later in-game
# change to this setting persists across launches instead of being
# overwritten back to this default every time.
if [ ! -f "${CONFDIR}/pioneers" ]; then
  if awk "BEGIN{exit !($DISPLAY_WIDTH/$DISPLAY_HEIGHT >= 1.5)}"; then
    layout_16_9=1
  else
    layout_16_9=0
  fi
  printf '[settings]\nlayout_16_9=%s\n' "$layout_16_9" > "${CONFDIR}/pioneers"
fi

weston_dir=/tmp/weston
$ESUDO mkdir -p "${weston_dir}"
weston_runtime="weston_pkg_0.2"
if [ ! -f "$controlfolder/libs/${weston_runtime}.squashfs" ]; then
  if [ ! -f "$controlfolder/harbourmaster" ]; then
    pm_message "This port requires the latest PortMaster to run, please go to https://portmaster.games/ for more info."
    sleep 5
    exit 1
  fi
  $ESUDO $controlfolder/harbourmaster --quiet --no-check runtime_check "${weston_runtime}.squashfs"
fi
if [[ "$PM_CAN_MOUNT" != "N" ]]; then
    $ESUDO umount "${weston_dir}"
fi
$ESUDO mount "$controlfolder/libs/${weston_runtime}.squashfs" "${weston_dir}"

cd $GAMEDIR

# The console server spawns "pioneersai" bot processes by searching $PATH for
# that exact name (no arch suffix, no absolute path - it's hardcoded in
# Pioneers itself), so it needs $GAMEDIR on PATH.
export PATH="$GAMEDIR:$PATH"
export PIONEERS_DIR="$GAMEDIR/share/games/pioneers"
./pioneers-server-console.${DEVICE_ARCH} --file "$GAMEDIR/share/games/pioneers/default.game" \
  --computer-players 3 --auto-quit &
SERVER_PID=$!
sleep 2

$GPTOKEYB2 "$game_executable" -c "$GAMEDIR/$ini_filename" &

pm_platform_helper "$GAMEDIR/$game_executable"

$ESUDO env WRAPPED_LIBRARY_PATH=$game_libs \
$weston_dir/westonwrap.sh drm gl kiosk system \
GDK_PIXBUF_MODULE_FILE="${CONFDIR}/loaders.cache" \
XDG_DATA_DIRS="$XDG_DATA_DIRS_PIONEERS" \
PATH="$GAMEDIR:$PATH" \
XDG_DATA_HOME=$CONFDIR \
XDG_CONFIG_HOME=$CONFDIR $GAMEDIR/$game_executable \
--server=127.0.0.1 --port=5556 --name=Player &
CLIENT_PID=$!

# GTK's own window has no size limit under this no-WM DRM/Wayland session
# (there's no compositor policy to constrain it, and GTK's Wayland backend
# doesn't support --geometry the way its X11 backend does), so it renders at
# its natural size regardless of the actual screen - overflowing badly on a
# small panel like the R36S (640x480). Force it to fit via sway directly.
if command -v swaymsg >/dev/null 2>&1; then
  ( sleep 3
    XDG_RUNTIME_DIR=/run/0-runtime-dir SWAYSOCK=/run/0-runtime-dir/sway-ipc.0.sock \
      swaymsg "[app_id=\"$game_executable\"] floating enable, resize set width $DISPLAY_WIDTH height $DISPLAY_HEIGHT, move position 0 0" \
      >/dev/null 2>&1
  ) &
fi

wait "$CLIENT_PID"

kill "$SERVER_PID" 2>/dev/null
$ESUDO $weston_dir/westonwrap.sh cleanup
if [[ "$PM_CAN_MOUNT" != "N" ]]; then
    $ESUDO umount "${weston_dir}"
    $ESUDO umount /tmp/pioneers-data
fi
pm_finish
