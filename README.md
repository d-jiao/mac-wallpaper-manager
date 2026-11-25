# Wallpaper Manager

A small macOS menu bar app that works alongside the wallpaper shuffle in **System Settings ›
Wallpaper**. It finds out which picture macOS is showing on each of your screens, so you can:

- **Move to Trash**: get rid of a picture you don't like
- **Show in Finder**: jump to the file so you can rotate, edit, rename, or move it
- **Next Picture**: skip ahead without waiting for the timer
- **Put Back**: undo the last Move to Trash

There's nothing to set up in the app. Keep choosing folders and intervals in System Settings as
usual. With several displays, each shuffling its own folder, every screen gets its own section
in the menu:

```
Studio Display · Landscapes
  [preview] hills.jpg
  Move to Trash
  Show in Finder
  macOS changes it every 10 minutes
DELL U2723QE · City Nights
  [preview] tokyo.jpg
  Move to Trash
  Show in Finder
  macOS changes it every 5 minutes
─────────────
Next Picture on All Screens
Put Back “bridge.jpg”
─────────────
Open at Login
Quit Wallpaper Manager
```

Click the menu bar icon (left or right click) to open it. Click a preview to open the picture,
or hover over it to see the full path.

## How it works, and its limits

macOS has no official way for apps to ask which picture its shuffle is showing, so the app
relies on two undocumented details, both observed on macOS 26:

- **Folders:** System Settings stores each display's wallpaper in
  `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`. The app reads the
  folder and the shuffle interval for each display from there.
- **Current picture:** macOS's wallpaper process keeps the picture on screen open. The app checks
  every few seconds which file in each screen's folder that process has open. Right after a
  change it can take a few seconds to catch up.

**Next Picture changes all screens at once.** It works by restarting macOS's wallpaper agent
(`killall WallpaperAgent`), which makes every screen pick a new picture from its folder and keeps
all your System Settings options. The screens may flash briefly. macOS offers no way to advance
just one screen without resetting that screen's shuffle settings.

**Move to Trash also moves every screen to a new picture**, so the deleted one disappears
right away.

Because these details aren't documented, a future macOS update could change them. If the menu
says "Finding the current picture…" for a long time, that's what happened. Please open an issue.

## Requirements

- macOS 13 Ventura or later (tested on macOS 26)
- Xcode, or just the Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/d-jiao/mac-wallpaper-manager.git
cd mac-wallpaper-manager
make install
```

This builds the app, copies it to `/Applications/Wallpaper Manager.app`, and starts it. Then
choose **Open at Login** in the menu so it starts with your Mac. Run `make install` again to
update after pulling changes.

## Notes

- **Trash is the normal macOS Trash.** Trashed pictures can be recovered with **Put Back** in
  the menu, or from the Trash in Finder, until you empty it.
- **Permissions:** if a wallpaper folder is in Desktop, Documents, Downloads, iCloud Drive, or on
  an external drive, macOS asks once whether Wallpaper Manager may access it. Because the app is
  signed locally (not with an Apple Developer ID), macOS may ask again after you rebuild it.
- Built-in wallpapers, Photos albums, and Aerials have no file to act on, so those screens only
  show "Not shuffling a folder".

## Uninstall

Turn off **Open at Login** first, then:

```bash
make uninstall
```

## Development

```bash
make test   # unit tests for reading the wallpaper settings and finding the current picture
make run    # build and run without installing
```

Project layout:

```
Sources/WallpaperCore/      Reads Index.plist, works out the current picture (pure Swift, unit tested)
Sources/WallpaperManager/   Menu bar app: menu, polling, Trash/Finder actions
Tests/WallpaperCoreTests/   Unit tests
Resources/Info.plist        App bundle metadata
scripts/build-app.sh        Builds the .app bundle
```

GitHub Actions builds the app and runs the tests on macOS for every push to `main`.
