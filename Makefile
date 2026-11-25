APP_NAME := Wallpaper Manager
APP := build/$(APP_NAME).app
INSTALL_DIR := /Applications

.PHONY: app install uninstall run test clean

## Build "build/Wallpaper Manager.app"
app:
	./scripts/build-app.sh

## Build, copy to /Applications, and (re)start the app
install: app
	-pkill -x WallpaperManager
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	open "$(INSTALL_DIR)/$(APP_NAME).app"

## Quit the app and remove it from /Applications (keeps your pictures and settings)
uninstall:
	-pkill -x WallpaperManager
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

## Build and run from the build folder without installing
run: app
	-pkill -x WallpaperManager
	open "$(APP)"

test:
	swift test

clean:
	rm -rf .build build
