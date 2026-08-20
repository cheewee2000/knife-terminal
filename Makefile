# Knife Terminal — native builds
# make install-mac   build the macOS app and install to /Applications
# make mac           build only
# make ios           build the iOS app for the connected device (install via Xcode/devicectl)
# make gen           regenerate the Xcode project from apple/project.yml

APPLE := apple
DERIVED := $(APPLE)/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Knife Terminal.app

gen:
	cd $(APPLE) && xcodegen generate

mac: gen
	cd $(APPLE) && xcodebuild -project KnifeTerminal.xcodeproj -scheme KnifeMac \
		-configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration -skipPackagePluginValidation build

install-mac: mac
	rm -rf "/Applications/Knife Terminal.app"
	cp -R "$(APP)" /Applications/
	@echo installed

ios: gen
	cd $(APPLE) && xcodebuild -project KnifeTerminal.xcodeproj -scheme KnifeiOS \
		-configuration Debug -destination 'generic/platform=iOS' \
		-derivedDataPath DerivedData -allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration -skipPackagePluginValidation build

.PHONY: gen mac install-mac ios
