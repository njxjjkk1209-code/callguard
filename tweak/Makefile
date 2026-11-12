# CallGuard Tweak
#
# 目标：Dopamine rootless（iOS 15.7.1 / arm64e）
# 打包：make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallGuardTweak

CallGuardTweak_FILES = Tweak.xm
CallGuardTweak_CFLAGS = -fobjc-arc -std=c++17 -I$(THEOS_PROJECT_DIR)/../core
CallGuardTweak_FRAMEWORKS = UIKit Foundation AVFoundation
CallGuardTweak_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
