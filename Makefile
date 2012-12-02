export TARGET_CODESIGN_FLAGS="-Ssign.plist"
export TARGET=iphone:5.1
export ARCHS=armv7
#export ARCHS = armv6 armv7
#export TARGET=iphone:5.1:4.3

include theos/makefiles/common.mk

TOOL_NAME = installipa
installipa_FILES = main.mm
installipa_FRAMEWORKS = UIKit
installipa_LDFLAGS = -MobileInstallation
installipa_INSTALL_PATH = /usr/bin

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