export TARGET_CODESIGN_FLAGS="-Ssign.plist"
export TARGET=iphone:5.0:4.0
export ARCHS = armv6
GO_EASY_ON_ME=1
include theos/makefiles/common.mk

TOOL_NAME = installipa
installipa_FILES = ZipArchive/ZipArchive.mm UIDevice-Capabilities/UIDevice-Capabilities.m main.mm
installipa_FRAMEWORKS = Foundation UIKit
installipa_CFLAGS = -I./ZipArchive/minizip
installipa_LDFLAGS = -MobileInstallation -lz
installipa_INSTALL_PATH = /usr/bin
installipa_SUBPROJECTS = ZipArchive/minizip

include theos/makefiles/tool.mk

before-package::
	mv -f _/usr/bin/installipa _/usr/bin/install-ipa
	mv -f _/usr/bin/installipa.sh _/usr/bin/installipa
	touch -r _/usr/bin/install-ipa _
	touch -r _/usr/bin/install-ipa _/DEBIAN
	touch -r _/usr/bin/install-ipa _/DEBIAN/*
	touch -r _/usr/bin/install-ipa _/usr
	touch -r _/usr/bin/install-ipa _/usr/bin
	touch -r _/usr/bin/install-ipa _/usr/bin/*

after-package::
	rm -fr .theos/packages/*
