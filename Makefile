export TARGET_CODESIGN_FLAGS="-Ssign.plist"
#export TARGET=iphone:4.0
#export ARCHS= armv6
export ARCHS = armv6 armv7
export TARGET=iphone:5.0:4.0
GO_EASY_ON_ME=1
include theos/makefiles/common.mk

TOOL_NAME = installipa
installipa_FILES = ZipArchive.mm main.mm
installipa_FRAMEWORKS = Foundation
pincrush_CFLAGS = -I./minizip
installipa_LDFLAGS = -MobileInstallation
installipa_INSTALL_PATH = /usr/bin
installipa_SUBPROJECTS = minizip

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
SUBPROJECTS += zipzap
include $(THEOS_MAKE_PATH)/aggregate.mk
