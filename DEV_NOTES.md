# Pioneers PortMaster port -- developer notes

Build/technical reference for anyone maintaining or rebuilding this port. Not shipped to players; see `README.md` for that. `testing_thread.txt` has the condensed investigation summary this was distilled from.

## Compile

Source: [sourceforge.net/projects/pio](https://sourceforge.net/projects/pio/), release 15.6 (2020-08-02). Standard autotools, built native aarch64 in an Ubuntu 24.04 chroot (no cross-compile needed, the build box is itself aarch64 under qemu-user):

```bash
tar xf pioneers-15.6.tar.gz
cd pioneers-15.6
./configure --prefix=/usr --datadir=/tmp/pioneers-data --without-avahi --disable-help --without-notify --without-sound
make
```

Notes on the flags:
- `--datadir=/tmp/pioneers-data`: Pioneers bakes its icon/theme/game-data search paths in at compile time (`DATADIR`/`THEMEDIR`/`PIONEERS_DIR_DEFAULT`). `$directory` (and so the real port install path) varies per CFW, so no single absolute path can be baked in that works everywhere. `/tmp` is the one path guaranteed to exist, be writable, and be identical across every CFW - the launch script bind-mounts the bundled `share/` tree onto `/tmp/pioneers-data` at runtime instead.
- `--without-avahi` / `--disable-help` / `--without-notify` / `--without-sound`: LAN game discovery, inline help (needs itstool/rsvg-convert), desktop notifications, and libcanberra sound are all things a single-device offline port doesn't need, and dropping them avoids pulling in dependencies this CFW may not have. `--without-sound` does have one side effect - see the `beep` stub note below.

Only three of the six binaries `make` produces get shipped: `pioneers` (the GTK client), `pioneers-server-console` (headless server), `pioneersai` (the AI bot). `pioneers-server-gtk`, `pioneers-editor`, and `pioneers-metaserver` aren't used by this port's single-player-vs-AI flow.

Bundled data is trimmed to what's actually reachable: `share/games/pioneers/{default.game,computer_names}`, six PNG-based themes (Classic/ccFlickr/FreeCIV-like/Iceland/Tiny/Wesnoth-like - `Nouvellia` was left out, it's SVG-only for terrain art and the other six already cover it), and `share/pixmaps/pioneers/*` (the toolbar action icons - several are SVG, see below - plus the human player avatar PNGs and the AI badge SVG).

## Single-player vs AI, no separate client/server dance

Pioneers' GTK client's own "Create Game" flow spawns `pioneers-server-gtk` (a second GTK window) via `g_spawn_async` - avoided entirely here. Instead: `Pioneers.sh` launches `pioneers-server-console --file default.game --computer-players 3 --auto-quit` directly in the background, waits ~2s, then launches the plain `pioneers` client with `--server=127.0.0.1 --port=5556 --name=Player`, which auto-connects at startup (confirmed by reading `client/gtk/offline.c`: passing both `--server` and `--port` sets `server_from_commandline`, which fires `GUI_CONNECT_TRY` immediately instead of showing the connect dialog).

`pioneers-server-console` spawns `pioneersai` bot processes via `g_spawn_async(..., G_SPAWN_SEARCH_PATH)` - a bare `PATH` search for the literal name `pioneersai`, no arch suffix, no absolute path (hardcoded in `server/server.c`). This is why `pioneersai` in the bundle keeps its plain name (no `.aarch64` suffix like the other two binaries) and why `Pioneers.sh` exports `PATH="$GAMEDIR:$PATH"` before starting the server.

**Gotcha**: `westonwrap.sh` re-sources `control.txt` internally before running the wrapped command, which silently resets any `export PATH=...` done earlier in the script. The server's own `pioneersai` spawn happens outside `westonwrap.sh` so it's unaffected, but the *client* process (launched through `westonwrap.sh`) needs `PATH` passed as a positional `VAR=value` argument on that specific invocation line, not as an earlier `export` - same rule applies to every other env var the wrapped process needs (`GDK_PIXBUF_MODULE_FILE`, `XDG_DATA_DIRS`, `XDG_CONFIG_HOME`, all set the same way).

## gdk-pixbuf: this CFW's build has no built-in loaders, and the whole loaders/ directory is gone

Every image load failed with `gdk-pixbuf-error-quark: Couldn't recognize the image file format`, for every format, even a byte-perfect PNG header (confirmed via a minimal standalone C reproduction: `gdk_pixbuf_get_formats()` correctly listed `png`/`jpeg` as registered types, but `gdk_pixbuf_new_from_file()` still refused to sniff them).

Root cause, found by pulling this CFW's actual gdk-pixbuf source package rather than guessing:
```bash
sudo apt-get install meson ninja-build gettext libglib2.0-dev-bin libpng-dev libjpeg-dev libtiff-dev
apt-get source gdk-pixbuf2.0
cd gdk-pixbuf-2.42.10+dfsg
meson setup build -Dbuiltin_loaders=none -Dman=false -Dgtk_doc=false -Dintrospection=disabled -Dtests=false -Dinstalled_tests=false
ninja -C build
```
`meson_options.txt` shows the real default is `builtin_loaders: ['png', 'jpeg']` - a normal Ubuntu build compiles those two directly into `libgdk_pixbuf-2.0.so.0` (no separate `.so`, no cache entry needed) and only ships the rest (bmp/gif/ico/tiff/xpm/etc, never png/jpeg) as real loadable modules under `gdk-pixbuf-2.0/2.10.0/loaders/`. This CFW's own `libgdk_pixbuf-2.0.so.0` has **zero** `png_*`/`jpeg_*` symbols in its dynamic table (checked with `nm -D`) - it was built expecting *every* format including png/jpeg to be an external module - but the entire `loaders/` directory it needs doesn't exist on the shipped image (confirmed with a plain `ls`, not just a missing file or two).

**Also confirmed real, and initially misdiagnosed as the actual bug**: setting `GDK_PIXBUF_MODULE_FILE` to a cache that lists *only* svg (the first, narrower fix attempt, before finding the real scope of the problem) made a build that otherwise has real built-in png/jpeg support (i.e. this project's own locally-built gdk-pixbuf, tested standalone) drop back to reporting only 1 registered format. Setting this env var fully replaces the module registry, built-ins included - it doesn't supplement whatever the library would normally find on its own. This is why the fix has to be "give it a complete cache with every format the port actually uses," not "give it a cache with just the one missing format."

**Fix shipped**: `libs.aarch64/` bundles this project's own locally-built `libgdk_pixbuf-2.0.so.0` (same `-Dbuiltin_loaders=none` config as above) plus real `libpixbufloader-png.so`/`libpixbufloader-jpeg.so` modules from that same build, plus `libpixbufloader-svg.so` from the system `librsvg2-common` package (svg isn't part of gdk-pixbuf's own source tree). `loaders.cache.tmpl` is a hand-written cache listing all three with a `@LIBSDIR@` placeholder, `sed`-substituted to the real absolute path at launch time (`libs.$DEVICE_ARCH` lives under `$GAMEDIR`, which varies per CFW). `GDK_PIXBUF_MODULE_FILE` points at the generated copy.

An earlier, much heavier attempt bundled the *entire* GTK3/glib/pango/cairo/atk stack (~70 libraries, ~69MB) on the theory that the CFW's much newer glib (2.85, vs this build chroot's 2.80) was an ABI mismatch breaking gdk-pixbuf's built-in registration. That bundle still failed identically - proving the theory wrong - and was discarded once the real cause (missing loader modules + missing mime database, below) was found. The shipped bundle is under 1MB: the four `.so` files above, nothing else. GTK3/glib/pango/cairo/X11/Wayland all still come from the device's own system libraries.

## /usr/share/mime is present but empty (source XML only, never compiled)

Even after the above fix, PNG/JPEG still failed to sniff. `/usr/share/mime/` on-device has only a `packages/` subfolder (the source XML type definitions) - no `magic`, `mime.cache`, `globs2`, or any of the other files `update-mime-database` normally compiles from them. gdk-pixbuf's `gio_sniffing` build option (also visible in `meson_options.txt`, default `true`) routes format detection through GIO's `g_content_type_guess()`, which depends on that compiled database - with it absent, every format sniff comes back empty regardless of which loader modules are present or working.

**Fix**: generate a real compiled database and bundle it.
```bash
sudo apt-get install shared-mime-info
mkdir -p mime-data/mime/packages
cp /usr/share/mime/packages/freedesktop.org.xml mime-data/mime/packages/
update-mime-database mime-data/mime
```
Only the compiled lookup files matter at runtime, not the source packages - `mime-data/mime/` in this port only ships `magic`, `mime.cache`, `globs`/`globs2`, `aliases`, `subclasses`, `types`, `treemagic`, `generic-icons`, `XMLnamespaces`, `version` (~340KB total; the full `update-mime-database` output including `packages/` and all the per-type-category subfolders is closer to 6MB and none of the extra content is read at runtime for this).

`Pioneers.sh` points `XDG_DATA_DIRS` at this bundle (prefixed ahead of `/usr/share`) - GIO/gdk-pixbuf look for `$dir/mime/...` under each `XDG_DATA_DIRS` entry.

## Everything on exFAT has to be copied to tmpfs first, not read in place

Most CFWs mount their games partition (`/roms`, where a port's `$GAMEDIR` lives) as exFAT for cross-platform drag-and-drop compatibility. Two completely separate things broke because of this, both root-caused by direct on-device testing rather than assumed from the reference doc's general exFAT/FUSE caveat:

1. **The mime database** (`mime.cache`/`magic`): shared-mime-info's own format is designed to be `mmap()`'d directly for fast lookup. `GMappedFile`-based reads over exFAT/FUSE silently return corrupted/empty data - confirmed by copying the exact same bundled files to tmpfs and re-running the identical test, which then passed.
2. **The compile-time-baked share/ data** (themes, pixmaps): Pioneers' `DATADIR`/`THEMEDIR` point at `/tmp/pioneers-data`, which `Pioneers.sh` populates by bind-mounting the port's own bundled `share/` folder onto it. A bind-mount reads through to the same exFAT-backed inodes as the original files - this alone was *not* the mmap problem (bind-mounting doesn't change the underlying filesystem the data ultimately comes from), but is done anyway since it's the only way to redirect Pioneers' hardcoded absolute path to wherever `$GAMEDIR` actually is per-CFW. In practice this worked fine once the *loader module* and *mime database* problems above were separately fixed - the theme PNGs themselves loaded correctly once gdk-pixbuf's sniffing had a working module + database to sniff *with*, regardless of which filesystem backs the file.

The mime database specifically is copied to `/tmp/pioneers-mime` (plain `cp -r`, not bind-mounted) at every launch rather than read from `$GAMEDIR/mime-data` directly, since it's small (~340KB) and this sidesteps the mmap/exFAT interaction entirely rather than relying on it happening to not matter.

## `beep`: `--without-sound` needs a stub, not nothing

With libcanberra disabled at compile time, `client/gtk/audio.c`'s fallback `play_sound()` implementation shells out to the classic Linux `beep` command-line tool (`g_spawn_async(["beep", "-f", freq])`) instead. That binary doesn't exist on this CFW, so every attempted beep (turn notification, dice-roll announce) logged a one-time in-game error to the message panel: `Error starting beep: Failed to execute child process "beep" (No such file or directory)`. Fixed by bundling a 2-line no-op shell script named `beep` in the port folder (already on `PATH` for the `pioneersai` spawn reason above, so this comes along for free) - `play_sound()` still "succeeds" from the game's point of view, just silently does nothing, which is the actually-desired behavior here anyway (no PC-speaker hardware to beep on a handheld).

## Auto-detecting 16:9 vs 4:3 layout

GTK's own window has no size ceiling under this CFW's `drm gl kiosk system` session (no real window manager, so nothing enforces a minimum/maximum on the client's surface). Pioneers' default layout puts the chat/messages panel *beside* the board (`main_paned`, a horizontal `GtkPaned` in `client/gtk/gui.c`'s `build_main_interface()`) - fine on a wide screen, but the combined minimum width of toolbar + board + sidebar + chat is wider than a 640x480 4:3 screen (R36S), so the sidebar just overflows past the visible framebuffer edge with no scrollbar or reflow.

Pioneers 15.6 already ships a fix for exactly this (per its own `NEWS`: *"New default: wide-screen layout"* - i.e. 15.6 added a *toggleable* 4:3-compatible layout alongside the new 16:9 default). `set_16_9_layout(gboolean)` in `gui.c` moves `chat_panel` between `main_paned` (beside the board) and `vpaned` (stacked below it) depending on `settings/layout_16_9` in Pioneers' own GKeyFile config. That config file lives at `$XDG_CONFIG_HOME/pioneers` (a single flat file, not a directory - confirmed from `common/gtk/config-gnome.c`'s `config_init()`) - **a different env var than `XDG_DATA_HOME`**, which is what the rest of this port's config (log directory, etc.) uses. Easy to miss since both are plausible-sounding "where does Pioneers keep its stuff" candidates.

`Pioneers.sh` computes the device's aspect ratio from `$DISPLAY_WIDTH`/`$DISPLAY_HEIGHT` (both already exported by every CFW's `control.txt`) and seeds `layout_16_9=1` (ratio >= 1.5, e.g. 1280x720) or `=0` (below, e.g. 1024x768/640x480) into a fresh config file - **only if one doesn't already exist**, so a later in-game settings change (which Pioneers persists back to the same file via `config_sync()`) survives across relaunches instead of being overwritten back to the auto-detected default every time.

Confirmed via real screenshots on both a 1280x720 (X55) and a 1024x768-reported/640x480-panel (R36S) device: same build, same zip, correct layout picked on both with zero manual configuration.

A `swaymsg` floating/resize/move call (targeting `[app_id="pioneers.aarch64"]`, run from a backgrounded subshell a few seconds after launch) is also kept as a belt-and-suspenders safety net to explicitly pin the window to the device's exact reported resolution at position `0,0` - harmless on a CFW without `swaymsg` (guarded by `command -v swaymsg`), and turned out not to be the actual fix for the R36S clipping (the config-driven layout change was), but costs nothing to keep.

## Screenshot capture note

`grim` (the Wayland screenshot tool used for this port's real on-device captures) works normally on the R36S. On the X55, this CFW's own `westonwrap.sh` prints *"Rocknix (Panfrost/SD) detected, bypassing weston setup entirely!"* and renders the game through a separate direct-DRM path that isn't the same Wayland output EmulationStation's own compositor session exposes - `grim` against that device only ever captures the ES background, not the game. The shipped `screenshot.png` is a real R36S capture for this reason, not a missing-capability workaround on the X55 build itself (both devices run the identical binary/zip).
