# SPDX-License-Identifier: GPL-2.0-only
#
# shexiangtou — MacBook Pro FaceTime HD 摄像头驱动
#

KVER    ?= $(shell uname -r)
KDIR    ?= /lib/modules/$(KVER)/build
REPO    := $(shell pwd)

.PHONY: all build verify audit firmware clean install

all: build

## 编译内核模块
build:
	@./scripts/build.sh $(KVER)

## 校验固件 + 交叉审计寄存器表
verify:
	@./scripts/verify.sh

## 只跑寄存器交叉审计
audit:
	@python3 tools/audit-registers.py \
		--kext $(REPO)/artifacts/apple-camera-interface \
		--linux $(REPO)/kernel/facetimehd/fthd_reg.h \
		--json $(REPO)/artifacts/register-audit.json

## 从 Apple CDN 重新抓取固件并校验
firmware:
	@./tools/fetch-firmware.sh --dest $(REPO)/firmware

## 安装（需要 root）
install:
	@sudo ./scripts/install.sh

clean:
	@$(MAKE) -C $(KDIR) M=$(REPO)/kernel/facetimehd clean
	@rm -f $(REPO)/artifacts/apple-camera-interface.asm
