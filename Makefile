export TARGET_CODESIGN_FLAGS="-Ssign.plist"
export ARCHS = armv7
export TARGET=iphone:8.1:4.0
GO_EASY_ON_ME=1
include theos/makefiles/common.mk

TOOL_NAME = ipainstaller
ipainstaller_FILES = ZipArchive/ZipArchive.mm UIDevice-Capabilities/UIDevice-Capabilities.m main.mm
ipainstaller_FRAMEWORKS = Foundation UIKit ImageIO CoreGraphics
ipainstaller_PRIVATE_FRAMEWORKS = GraphicsServices MobileCoreServices
ipainstaller_CFLAGS = -I./ZipArchive/minizip
ipainstaller_LDFLAGS = MobileInstallation -lz
ipainstaller_INSTALL_PATH = /usr/bin
ipainstaller_SUBPROJECTS = ZipArchive/minizip

include theos/makefiles/tool.mk

VERSION.INC_BUILD_NUMBER = 2

before-package::
	ln -s ipainstaller _/usr/bin/installipa
	touch -r _/usr/bin/ipainstaller _
	touch -r _/usr/bin/ipainstaller _/DEBIAN
	touch -r _/usr/bin/ipainstaller _/DEBIAN/*
	touch -r _/usr/bin/ipainstaller _/usr
	touch -r _/usr/bin/ipainstaller _/usr/bin
	chmod 0755 _/usr/bin/ipainstaller*

after-package::
	rm -fr .theos/packages/*
