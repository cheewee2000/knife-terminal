# Knife Terminal — native builds
# make install-mac   build the macOS app and install to /Applications
# make mac           build only
# make ios           build the iOS app for the connected device (install via Xcode/devicectl)
# make gen           regenerate the Xcode project from apple/project.yml
# make release       archive, notarize, sign the appcast, publish the GitHub release

APPLE := apple
DERIVED := $(APPLE)/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Knife Terminal.app
IOS_APP := $(DERIVED)/Build/Products/Debug-iphoneos/Knife.app
# Per-machine overrides (gitignored), e.g. XCODEBUILD_FLAGS = DEVELOPMENT_TEAM=… CODE_SIGN_ENTITLEMENTS=…
-include local.mk
XCODEBUILD_FLAGS ?=
XCODEBUILD_FLAGS_IOS ?=

gen:
	cd $(APPLE) && xcodegen generate

mac: gen
	cd $(APPLE) && xcodebuild -project KnifeTerminal.xcodeproj -scheme KnifeMac \
		-configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration -skipPackagePluginValidation $(XCODEBUILD_FLAGS) build

install-mac: mac
	rm -rf "/Applications/Knife Terminal.app"
	cp -R "$(APP)" /Applications/
	@echo installed

ios: gen
	cd $(APPLE) && xcodebuild -project KnifeTerminal.xcodeproj -scheme KnifeiOS \
		-configuration Debug -destination 'generic/platform=iOS' \
		-derivedDataPath DerivedData -allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration -skipPackagePluginValidation $(XCODEBUILD_FLAGS_IOS) build

# IOS_DEVICE: a device id from `xcrun devicectl list devices` (set it in local.mk)
install-ios: ios
	xcrun devicectl device install app --device "$(IOS_DEVICE)" "$(IOS_APP)"
	@echo installed on $(IOS_DEVICE)

release:
	./release.sh "$(NOTES)"

.PHONY: gen mac install-mac ios install-ios release
