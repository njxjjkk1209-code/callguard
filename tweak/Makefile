# CallGuard Tweak
#
# 目标：Dopamine rootless（iOS 15.7.1 / arm64e）
# 打包：make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallGuardTweak

# 构建标识：CI 通过命令行传入，本地手编回落到 dev。
# 这两个值会写进 tweak_ready.json，App 概览页显示 build xxx，
# 用来判断手机上跑的和手上拿的是不是同一代产物。
CGBUILD_COMMIT ?= dev
CGBUILD_TIME ?= unknown

CallGuardTweak_FILES = Tweak.xm
# 注意：字符串宏必须写成 \"value\"，不能套单引号 ——
# 写成 '\"value\"' 会让 clang 收到 '"value"'，直接报
# "missing terminating '\"' character" 并连带整个模块构建失败。
CallGuardTweak_CFLAGS = -fobjc-arc -std=c++17 -I$(THEOS_PROJECT_DIR)/../core \
	-DCGBUILD_COMMIT=\"$(CGBUILD_COMMIT)\" \
	-DCGBUILD_TIME=\"$(CGBUILD_TIME)\"
CallGuardTweak_FRAMEWORKS = UIKit Foundation AVFoundation
CallGuardTweak_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
