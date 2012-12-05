export TARGET_CODESIGN_FLAGS="-Ssign.plist"
export TARGET=iphone:5.0:4.0
export ARCHS = armv6
GO_EASY_ON_ME=1
include theos/makefiles/common.mk

TOOL_NAME = ipainstaller
ipainstaller_FILES = ZipArchive/ZipArchive.mm UIDevice-Capabilities/UIDevice-Capabilities.m main.mm
ipainstaller_FRAMEWORKS = Foundation UIKit
ipainstaller_CFLAGS = -I./ZipArchive/minizip
ipainstaller_LDFLAGS = -MobileInstallation -lz
ipainstaller_INSTALL_PATH = /usr/bin
ipainstaller_SUBPROJECTS = ZipArchive/minizip

include theos/makefiles/tool.mk

before-package::
	ln -s ipainstaller _/usr/bin/installipa
	touch -r _/usr/bin/installipa _
	touch -r _/usr/bin/installipa _/DEBIAN
	touch -r _/usr/bin/installipa _/DEBIAN/*
	touch -r _/usr/bin/installipa _/usr
	touch -r _/usr/bin/installipa _/usr/bin
	touch -r _/usr/bin/installipa _/usr/bin/installipa.sh

after-package::
	rm -fr .theos/packages/*
