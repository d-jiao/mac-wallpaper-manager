# Wallpaper Manager

A small macOS menu bar app that shuffles your wallpaper from a folder and lets you act on the
picture you're looking at:

- **Move to Trash**: get rid of a picture you don't like, and go straight to the next one
- **Show in Finder**: jump to the file so you can rotate, edit, rename, or move it
- **Next / Previous Wallpaper**: skip ahead without waiting for the timer, or go back
- **Put Back**: undo the last Move to Trash

Click the menu bar icon (left or right click) to see a preview and the file name of the current
wallpaper, plus all the actions.

## Why the app does the shuffling itself

macOS's own "shuffle a folder" setting in System Settings › Wallpaper doesn't tell other apps
which file it is showing, so there is no reliable way to trace the wallpaper back to its file.
Wallpaper Manager therefore replaces that setting. It picks a random picture from your folder on
a timer and sets it as the wallpaper, so it always knows which file is on screen.

The shuffle is "random without repeats": every picture is shown once before any picture is shown
again, and new pictures you add to the folder are included automatically.

## Requirements

- macOS 13 Ventura or later
- Xcode, or just the Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/d-jiao/mac-wallpaper-manager.git
cd mac-wallpaper-manager
make install
```

This builds the app, copies it to `/Applications/Wallpaper Manager.app`, and starts it. Run
`make install` again to update after pulling changes.

On first launch, the app asks you to choose your wallpaper folder. After that:

1. Pick an interval under **Change Picture Every** (default: 10 minutes).
2. Turn on **Open at Login** in the menu so it starts with your Mac.
3. In **System Settings › Wallpaper**, turn on **Show on all Spaces** if you use several
   desktops (Spaces). The app also re-applies the current picture when you switch Spaces.

Setting a picture from the app replaces the folder rotation in System Settings, so the two
don't compete. If the system's rotation ever comes back (for example on a Space the app hasn't
visited yet), choose any single picture in System Settings › Wallpaper.

## Menu

- Preview and file name of the current wallpaper (click to open it; hover for the full path)
- When the next change happens
- Next / Previous Wallpaper
- Move to Trash / Show in Finder / Open / Put Back
- Pause or Resume Shuffling
- Change Picture Every: 1 minute to 1 day
- Picture Size: Fill, Fit, Stretch, Center
- Choose Folder…, Include Subfolders
- Open at Login, Quit

The same picture is shown on all connected displays.

## Notes

- **Trash is the normal macOS Trash.** Trashed pictures can be recovered with **Put Back** in
  the menu, or from the Trash in Finder, until you empty it.
- **Permissions:** if your folder is in Desktop, Documents, Downloads, iCloud Drive, or on an
  external drive, macOS will ask once whether Wallpaper Manager may access it. Because the app
  is signed locally (not with an Apple Developer ID), macOS may ask again after you rebuild it.
- **Settings** are stored in `~/Library/Preferences/io.github.d-jiao.WallpaperManager.plist`.
  To start over: quit the app, then run
  `defaults delete io.github.d-jiao.WallpaperManager`.

## Uninstall

```bash
make uninstall
```

Turn off **Open at Login** first, or remove the app in System Settings › General › Login Items.

## Development

```bash
make test   # unit tests for the shuffle and folder-scanning logic
make run    # build and run without installing
```

Project layout:

```
Sources/WallpaperCore/      Shuffle order, history, folder scanning (pure Swift, unit tested)
Sources/WallpaperManager/   Menu bar app: menu, wallpaper timer, Trash/Finder actions
Tests/WallpaperCoreTests/   Unit tests
Resources/Info.plist        App bundle metadata
scripts/build-app.sh        Builds the .app bundle
```

GitHub Actions builds the app and runs the tests on macOS for every push to `main`. The built
app is attached to each run as an artifact. Building it yourself with `make install` is simpler,
because macOS blocks unsigned apps downloaded from the internet.
