export TARGET_CODESIGN_FLAGS="-Ssign.plist"
export ARCHS = armv7 arm64
export TARGET=iphone:9.2:4.0
GO_EASY_ON_ME=1
include theos/makefiles/common.mk

TOOL_NAME = ipainstaller
ipainstaller_FILES = \
					ZipArchive/minizip/ioapi.c \
					ZipArchive/minizip/mztools.c \
					ZipArchive/minizip/unzip.c \
					ZipArchive/minizip/zip.c \
					ZipArchive/ZipArchive.mm \
					UIDevice-Capabilities/UIDevice-Capabilities.m \
					main.mm
ipainstaller_FRAMEWORKS = Foundation UIKit ImageIO CoreGraphics
ipainstaller_PRIVATE_FRAMEWORKS = GraphicsServices MobileCoreServices
ipainstaller_LDFLAGS = MobileInstallation -lz
ipainstaller_INSTALL_PATH = /usr/bin

include theos/makefiles/tool.mk

VERSION.INC_BUILD_NUMBER = 1

before-package::
	ln -s ipainstaller $(THEOS_STAGING_DIR)/usr/bin/installipa
	find $(THEOS_STAGING_DIR) -exec touch -r $(THEOS_STAGING_DIR)/usr/bin/installipa {} \;
	chmod 0755 $(THEOS_STAGING_DIR)/usr/bin/ipainstaller
	chmod 0644 $(THEOS_STAGING_DIR)/DEBIAN/control

after-package::
	rm -fr .theos
