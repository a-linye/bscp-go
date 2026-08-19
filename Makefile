# version
PRO_DIR   = $(shell pwd)
BUILDTIME = $(shell TZ=Asia/Shanghai date +%Y-%m-%dT%T%z)
GITHASH   = $(shell git rev-parse HEAD)
VERSION   = $(shell echo ${ENV_BK_BSCP_VERSION})
DEBUG     = $(shell echo ${ENV_BK_BSCP_ENABLE_DEBUG})
PREFIX   ?= $(shell pwd)

# 官方 Go 1.21+ 编译出的二进制在旧版 Windows（Server 2008 R2 / 2012 / 2012 R2、Win7 SP1 / 8.1）
# 上启动即崩溃，兼容这些系统需要打过补丁的 Go 工具链。该工具链只用于
# build_nodemanPlugin_winLegacy 这一个目标，常规产物（bkbscp 插件包、CLI、sidecar）一律使用
# 官方工具链。详见 docs/windows-legacy-os.md。
GO_WIN_TOOLCHAIN_TAG ?= patched-1.26.6
GO_WIN_TOOLCHAIN_DIR ?= $(PRO_DIR)/.toolchain/go-win7-$(GO_WIN_TOOLCHAIN_TAG)

# 清掉 GOROOT 是因为 gvm/asdf 这类版本管理器会导出它，会让 go 命令去用另一套工具链的
# 编译器，报 "compile: version does not match go tool version"。
# 锁定 GOTOOLCHAIN 是因为 go.mod 的 toolchain 指令会把补丁版换回官方版而静默丢掉补丁，
# 将来 go.mod 要求的版本若高于补丁工具链，这里会直接报错而不是产出有问题的二进制。
GO_WIN_LEGACY_ENV = env -u GOROOT GOTOOLCHAIN=local
# 显式传入 GO_WIN_LEGACY 可跳过工具链下载，用于对照验证（此时产物不再兼容旧版 Windows）：
#   make build_nodemanPlugin_winLegacy GO_WIN_LEGACY=$(command -v go)
ifeq ($(origin GO_WIN_LEGACY), undefined)
    GO_WIN_LEGACY = $(GO_WIN_TOOLCHAIN_DIR)/bin/go
    GO_WIN_LEGACY_DEP = install_go_win_toolchain
endif

GOBUILD=CGO_ENABLED=0 go build -trimpath
GOBUILD_LINUX_X64=CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath
GOBUILD_WINDOWS_X64=CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath
GOBUILD_WINDOWS_X64_LEGACY=$(GO_WIN_LEGACY_ENV) CGO_ENABLED=0 GOOS=windows GOARCH=amd64 "$(GO_WIN_LEGACY)" build -trimpath

ifeq (${GOOS}, windows)
    BIN_NAME=bscp.exe
else
    BIN_NAME=bscp
endif

ifeq ("$(ENV_BK_BSCP_VERSION)", "")
	VERSION=v1.0.0-devops-unknown
else ifeq ($(shell echo ${ENV_BK_BSCP_VERSION} | egrep "^v1\.[0-9]+\.[0-9]+"),)
	VERSION=v1.0.0-devops-${ENV_BK_BSCP_VERSION}
endif

# 语义化版本, 使用 sed 去掉版本前缀v
SEM_VERSION = $(shell echo $(VERSION) | sed 's/^v//')

export LDVersionFLAG = -X github.com/TencentBlueKing/bk-bscp/pkg/version.VERSION=${VERSION} \
    	-X github.com/TencentBlueKing/bk-bscp/pkg/version.BUILDTIME=${BUILDTIME} \
    	-X github.com/TencentBlueKing/bk-bscp/pkg/version.GITHASH=${GITHASH} \
    	-X github.com/TencentBlueKing/bk-bscp/pkg/version.DEBUG=${DEBUG}


.PHONY: lint
lint:
	@golangci-lint run --fix --issues-exit-code=0

.PHONY: install_go_win_toolchain
install_go_win_toolchain:
	@GO_WIN_TOOLCHAIN_TAG="$(GO_WIN_TOOLCHAIN_TAG)" \
		GO_WIN_TOOLCHAIN_DIR="$(GO_WIN_TOOLCHAIN_DIR)" \
		bash scripts/install-go-win-toolchain.sh

.PHONY: build_initContainer
build_initContainer:
	${GOBUILD} -ldflags "${LDVersionFLAG} \
	-X github.com/TencentBlueKing/bk-bscp/pkg/version.CLIENTTYPE=sidecar" \
	-o build/initContainer/bscp cmd/bscp/*.go

.PHONY: build_sidecar
build_sidecar:
	${GOBUILD} -ldflags "${LDVersionFLAG} \
	-X github.com/TencentBlueKing/bk-bscp/pkg/version.CLIENTTYPE=sidecar" \
	-o build/sidecar/bscp cmd/bscp/*.go

.PHONY: build_docker
build_docker: build_initContainer build_sidecar
	cd build/initContainer && docker build . -t bscp-init
	cd build/sidecar && docker build . -t bscp-sidecar

.PHONY: build
build:
	${GOBUILD} -ldflags "${LDVersionFLAG} \
	-X github.com/TencentBlueKing/bk-bscp/pkg/version.CLIENTTYPE=command" \
	-o bin/${BIN_NAME} cmd/bscp/*.go

# 节点管理插件包按平台分步组装，各包可以只包含自己需要的平台产物。公共参数：
#   $(1) 插件名。同时作为包内目录名、可执行文件名和配置文件名，并通过 -X main.pluginName
#        注入二进制：GSE 按插件名传 -c ../etc/<插件名>.conf、按 <插件名>.pid 检查进程存活，
#        任何一处不一致都会导致启动失败或被判定为未运行。描述里不要出现半角逗号，
#        否则会被 $(call) 当成参数分隔符。
#   $(2) 插件描述，展示在节点管理界面上。
#
# 即便文件名已按插件名区分，同一台 Windows 主机仍只能安装其中一个包：net_windows.go 里的
# ListenLocal 固定监听 127.0.0.1:9616。详见 docs/windows-legacy-os.md。
define plugin_add_linux
	mkdir -p "build/nodemanPlugin/$(1)/plugins_linux_x86_64/$(1)/etc" "build/nodemanPlugin/$(1)/plugins_linux_x86_64/$(1)/bin"
	${GOBUILD_LINUX_X64} -ldflags "${LDVersionFLAG} \
		-X github.com/TencentBlueKing/bk-bscp/pkg/version.CLIENTTYPE=agent \
		-X main.pluginName=$(1)" \
		-o build/nodemanPlugin/$(1)/plugins_linux_x86_64/$(1)/bin/$(1) build/nodemanPlugin/main.go
	sed -e "s/__VERSION__/$(SEM_VERSION)/g" \
	-e "s/__PLUGIN_NAME__/$(1)/g" \
	-e "s|__DESCRIPTION__|$(2)|g" \
	-e "s/__START_SCRIPT__/.\/start.sh/g" \
	-e "s/__STOP_SCRIPT__/.\/stop.sh/g" \
	-e "s/__RESTART_SCRIPT__/.\/restart.sh/g" \
	-e "s/__RELOAD_SCRIPT__/.\/restart.sh/g" build/nodemanPlugin/project.yaml.tpl > build/nodemanPlugin/$(1)/plugins_linux_x86_64/$(1)/project.yaml
	cp build/nodemanPlugin/etc/bkbscp.conf.tpl build/nodemanPlugin/$(1)/plugins_linux_x86_64/$(1)/etc/$(1).conf.tpl
endef

# 追加 Windows x86_64 产物。$(3) 为编译使用的构建命令。
define plugin_add_windows
	mkdir -p "build/nodemanPlugin/$(1)/plugins_windows_x86_64/$(1)/etc" "build/nodemanPlugin/$(1)/plugins_windows_x86_64/$(1)/bin"
	$(3) -ldflags "${LDVersionFLAG} \
		-X github.com/TencentBlueKing/bk-bscp/pkg/version.CLIENTTYPE=agent \
		-X main.pluginName=$(1)" \
		-o build/nodemanPlugin/$(1)/plugins_windows_x86_64/$(1)/bin/$(1).exe build/nodemanPlugin/main.go
	sed -e "s/__VERSION__/$(SEM_VERSION)/g" \
	-e "s/__PLUGIN_NAME__/$(1)/g" \
	-e "s|__DESCRIPTION__|$(2)|g" \
	-e "s/__START_SCRIPT__/start.bat/g" \
	-e "s/__STOP_SCRIPT__/stop.bat/g" \
	-e "s/__RESTART_SCRIPT__/restart.bat/g" \
	-e "s/__RELOAD_SCRIPT__/restart.bat/g" build/nodemanPlugin/project.yaml.tpl > build/nodemanPlugin/$(1)/plugins_windows_x86_64/$(1)/project.yaml
	cp build/nodemanPlugin/etc/bkbscp.conf.tpl build/nodemanPlugin/$(1)/plugins_windows_x86_64/$(1)/etc/$(1).conf.tpl
endef

.PHONY: build_nodemanPlugin
build_nodemanPlugin:
	@echo "Building nodemanPlugin version: ${SEM_VERSION}"
	rm -rf build/nodemanPlugin/bkbscp
	$(call plugin_add_linux,bkbscp,bscp服务配置分发和热更新)
	$(call plugin_add_windows,bkbscp,bscp服务配置分发和热更新,${GOBUILD_WINDOWS_X64})
	cd build/nodemanPlugin/bkbscp && tar -zcf ../bkbscp.tar.gz .

# 面向旧版 Windows 的插件包，只包含 Windows 产物：这些系统上跑不起来的只有 Windows 二进制，
# Linux 主机用 bkbscp 即可，没必要在这个包里重复一份。
.PHONY: build_nodemanPlugin_winLegacy
build_nodemanPlugin_winLegacy: $(GO_WIN_LEGACY_DEP)
	@echo "Building nodemanPlugin(win-legacy) version: ${SEM_VERSION}"
	rm -rf build/nodemanPlugin/bkbscp-win-legacy
	$(call plugin_add_windows,bkbscp-win-legacy,bscp服务配置分发和热更新（兼容旧版 Windows：Server 2008 R2 / 2012 / 2012 R2 及 Windows 7 SP1 / 8.1）,${GOBUILD_WINDOWS_X64_LEGACY})
	cd build/nodemanPlugin/bkbscp-win-legacy && tar -zcf ../bkbscp-win-legacy.tar.gz .

.PHONY: test
test:
	go test ./...


