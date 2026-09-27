## Notes

Thanks to [Dave Cole and the Pioneers team](https://sourceforge.net/projects/pio/) for creating this game, a faithful, full-featured Settlers of Catan clone with a real AI opponent, seafarers/gold variants, and dozens of official and community map layouts.

This port runs Pioneers' own GTK client and console server natively on aarch64 handhelds. A single distribution auto-detects the screen's aspect ratio at first launch and picks Pioneers' own 16:9 (chat beside the board) or 4:3 (chat stacked below) layout accordingly, so wide and narrow-screen devices both get a UI that actually fits.

## Controls

| Key | Action |
|--|--|
| D-Pad / Left Stick | Move cursor |
| A | Left click |
| B | Right click |
| X (hold) | Precision cursor (half speed) |
| Start | Enter |
| Select/Back | Escape |

## License

Pioneers itself is GPLv2+. The bundled `libgdk_pixbuf-2.0.so.0`/loader modules are LGPLv2.1+ (gdk-pixbuf, librsvg).

## Compile

```bash
tar xf pioneers-15.6.tar.gz
cd pioneers-15.6
./configure --prefix=/usr --datadir=/tmp/pioneers-data --without-avahi --disable-help --without-notify --without-sound
make
```

### gdk-pixbuf (bundled image loader modules)

The target CFW's own gdk-pixbuf ships with its entire loader-module directory stripped (every image format, not just one), and its `libgdk_pixbuf` build relies on external modules for all of them rather than compiling common formats in. Build a local gdk-pixbuf with every format as a real loadable module instead of the distro's `builtin_loaders=png,jpeg` default:

```bash
sudo apt build-dep gdk-pixbuf2.0
apt source gdk-pixbuf2.0
cd gdk-pixbuf-2.42.10+dfsg
meson setup build -Dbuiltin_loaders=none -Dman=false -Dgtk_doc=false -Dintrospection=disabled -Dtests=false -Dinstalled_tests=false
ninja -C build
```

### Compiled MIME database

The target CFW also ships an empty `/usr/share/mime` (source XML packages, never run through `update-mime-database`), which breaks GIO's own content-type sniffing that gdk-pixbuf depends on for every format. Generate a real one from the standard freedesktop.org spec:

```bash
sudo apt install shared-mime-info
update-mime-database /path/to/output/mime
```
