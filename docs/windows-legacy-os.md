# Windows 旧版本兼容说明

## 问题现象

在 Windows Server 2008 R2 / 2012 上部署 `bkbscp` 节点管理插件，进程启动即崩溃，节点管理侧
只能看到 `start bkbscp fail`、`run user script exit-code(1)`，标准输出里是一段没有 Go 栈帧的
崩溃信息：

```
Exception 0xc0000005 0x8 0x0 0x0
PC=0x0

runtime.asmstdcall(...)
        runtime/sys_windows_amd64.s:76 +0x89
rax     0x0
...
rip     0x0
```

判断依据：

- `0xc0000005` 是访问违例，第一个参数 `0x8` 表示执行了不可执行内存，访问地址为 `0x0`；
- `PC=0x0` 且 `rip 0x0`，说明调用了空函数指针；
- 栈顶是 `runtime.asmstdcall`，即 Go 调用 Windows DLL 导出函数的那条间接 CALL；
- 崩溃前没有任何应用日志（连版本 banner 都没有），说明还在 runtime 初始化阶段。

## 根因

Go 1.21 起官方把 Windows 最低要求提到 Windows 10 / Server 2016，并移除了对旧系统的降级路径。
runtime 初始化随机数种子时会调用 `bcryptprimitives.dll` 的 `ProcessPrng`，该 DLL 从
Windows 8 / Server 2012 才引入。在更旧的系统上符号解析结果为 0，runtime 仍照常调用，于是
在 `asmstdcall` 里跳到地址 0。

## 采用的方案：两个相互独立的插件包

没有把现有插件包的 Windows 产物直接换掉，而是新增了一个专用插件包。原因是方案落地时补丁工具链的
产物还没有实机验证条件（见下文「验证状态」），一旦有意外，替换方案会波及全部 Windows 主机，
包括原本工作正常的那些；新增方案只影响本来就起不来的老机器。

| | `bkbscp` | `bkbscp-win-legacy` |
| --- | --- | --- |
| 构建目标 | `make build_nodemanPlugin` | `make build_nodemanPlugin_winLegacy` |
| 包内平台目录 | `plugins_linux_x86_64` + `plugins_windows_x86_64` | 仅 `plugins_windows_x86_64` |
| Windows 产物 | 官方工具链 | [XTLS/go-win7](https://github.com/XTLS/go-win7) 补丁工具链 |
| 适用主机 | Server 2016 及以上、各 Linux | Server 2008 R2 / 2012 / 2012 R2、Win 7 SP1 / 8.1 |

`bkbscp-win-legacy` 只包含 Windows 产物：在这些旧系统上起不来的只有 Windows 二进制，Linux 主机
用 `bkbscp` 即可。两个包的配置模板内容和参数定义完全相同（只有配置文件名跟随插件名），`go.mod` 与依赖版本没有任何改动。

选择补丁工具链而不是把 `go.mod` 降到 Go 1.20 的原因：降级需要把 `golang.org/x/crypto` 一并
降版本，并且会让产物长期停留在已经 EOL 的 Go 1.20 上、拿不到后续安全修复，同时 `go` directive
从 1.23 降到 1.20 还会让 Go 1.22 的循环变量语义回退，属于容易踩的隐性风险。

### 插件名必须贯穿到文件名

GSE 按插件名下发和查找一批文件，插件侧必须完全对齐，否则要么起不来，要么起来了也会被判定为
未运行：

| 文件 | GSE 侧 | 插件侧 |
| --- | --- | --- |
| 配置文件 | `start.bat` 传 `-c ../etc/<插件名>.conf` | `project.yaml` 的 `config_file`、`config_templates[].name`、`source_path` |
| pid 文件 | 进程配置里的 `pid_path` 为 `<data>\<插件名>.pid` | `main.go` 的 `pidFile` |

常规包一直正常，是因为插件名恰好等于代码里硬编码的 `bkbscp`。换成 `bkbscp-win-legacy` 后两侧错开，
首次灰度报的就是这个：

```
Error: read config file: open ../etc/bkbscp-win-legacy.conf: The system cannot find the file specified.
start bkbscp-win-legacy fail, run user script exit-code(1)
```

因此做了两处参数化：

- `project.yaml.tpl` 里三处文件名改为 `__PLUGIN_NAME__`，`Makefile` 打包时把
  `etc/bkbscp.conf.tpl` 拷贝为 `etc/<插件名>.conf.tpl`；
- `main.go` 里原先硬编码 `bkbscp` 的 `defaultConfigPath`、`pidFile`、`unitSocketFile`、`logFile`
  改由包级变量 `pluginName` 拼出，构建时通过 `-ldflags -X main.pluginName=<插件名>` 注入。

`pluginName` 的默认值仍是 `bkbscp`，常规包注入的也是 `bkbscp`，四个文件名的取值与改动前完全一致，
`project.yaml` 与配置模板的渲染结果逐字节不变。

### 同一台主机只能装一个

配置文件、pid、socket、日志的文件名现在都由 `pluginName` 拼出，两个包各用各的，在 GSE 平铺的
`bin/`、`etc/`、`data/` 目录下不会互相覆盖。但 Windows 上仍然不能共存：
`internal/util/net_windows.go` 里的 `ListenLocal` 忽略传入的 socket 路径，固定监听
`127.0.0.1:9616`（Linux 走的是 unix socket，按 pid 目录天然区分），而监听失败会直接
`return err` 让进程退出。因此同机部署两个包时，后启动的那个必然起不来。

部署时按主机的 Windows 版本二选一，不要同时下发。如果将来确实需要同机共存，需要把这个端口
改成可配置项。

## 补丁的改动面

补丁基于同版本官方 SDK，只改了 11 个源文件、约 256 行。改动全部落在 Windows 执行路径上：

- `ProcessPrng`（`bcryptprimitives.dll`，Win8+）换回 `BCryptGenRandom`（`bcrypt.dll`，Vista+）：
  `crypto/internal/sysrand/rand_windows.go`、`internal/syscall/windows/{syscall,zsyscall}_windows.go`，
  以及 `crypto/rand/rand.go`（仅改注释文字）；
- Windows 上的 `os.Root` / `os.RemoveAll` 从依赖 Win8+ 新 API 的 `openat` 系实现切回基于路径的
  旧实现：`os/{removeall_at,removeall_noat,root_noopenat,root_openat,root_windows}.go`。其中
  `os/removeall_at.go` 的 build tag 由 `unix || wasip1 || windows` 改为 `unix || wasip1`，
  函数体只在文件间搬家，对 unix 语义等价；
- 去掉对 `RtlGetCurrentPeb` 的依赖、恢复 Windows 7 的旧版控制台句柄处理：`runtime/os_windows.go`；
- 进程创建相关的旧系统兼容：`syscall/exec_windows.go`。

复核方法（下载同版本官方源码做全量对比）：

```bash
make install_go_win_toolchain
ver=$(head -1 .toolchain/go-win7-patched-*/VERSION)   # 例如 go1.26.6
curl -fsSLO "https://go.dev/dl/${ver}.src.tar.gz" && tar -xzf "${ver}.src.tar.gz"
diff -rq go/src .toolchain/go-win7-patched-*/src | grep -v '^Only in'
```

`Only in` 的条目可以忽略：官方源码包不含发行版构建时生成的 `zbootstrap.go`、`zversion.go`
等文件，补丁包不含 `_test.go`，另外补丁包里有 3 个 `.orig` 备份文件（后缀不是 `.go`，不参与编译）。

也可以直接从产物确认用的是哪套 API：

```bash
# bkbscp 包的产物：应命中 bcryptprimitives / ProcessPrng
strings -a build/nodemanPlugin/bkbscp/plugins_windows_x86_64/bkbscp/bin/bkbscp.exe \
  | grep -icE "bcryptprimitives|ProcessPrng"

# bkbscp-win-legacy 包的产物：应命中 bcrypt.dll / BCryptGenRandom，且不含上面两个符号
strings -a build/nodemanPlugin/bkbscp-win-legacy/plugins_windows_x86_64/bkbscp-win-legacy/bin/bkbscp-win-legacy.exe \
  | grep -icE "bcrypt\.dll|BCryptGenRandom"
```

### 已知限制

补丁把 `canUseLongPaths` 固定为 `false`，即进程不再声明自己感知长路径（这个声明依赖 Win8+ 的
`RtlGetCurrentPeb`）。超长路径仍然可用：`os` 包会对长度达到 248 字节的路径自动补上 `\\?\`
扩展前缀，这也是 Go 1.20 及更早版本在所有 Windows 上的既有行为。代价是这类路径经由扩展前缀访问，
会绕过 Win32 的路径规范化，因此依赖 `MAX_PATH` 之外行为的场景需要实测确认。

补丁版 SDK 也不支持 `-race`，但插件构建不使用该参数。

### 验证状态

已实机确认：补丁版产物在目标机上不再出现 `Exception 0xc0000005 / PC=0x0 / runtime.asmstdcall`，
进程能完整走完 runtime 初始化并进入业务代码——首次灰度时报的是应用层的
`read config file: open ../etc/bkbscp-win-legacy.conf`，说明 cobra 参数解析和 viper 已经执行到，
即 `randinit` / `alginit` 均已正常完成。该错误由本文「插件名必须贯穿到文件名」一节修复。

常规包（`bkbscp`）方面：`project.yaml` 与配置模板的渲染结果已比对确认与改动前逐字节一致；二进制会
因 `pluginName` 从常量改为注入变量而重新编译，但注入值仍是 `bkbscp`，四个文件名取值不变，行为等价。

仍待确认：

- 修复文件名后完成一次完整的配置拉取与热更新；
- 常规包重新构建后在现有环境回归一次启停；
- 补丁版产物在 Server 2016 及以上系统上行为与官方版一致（`BCryptGenRandom` 在这些系统上同样
  存在，且 Go 1.20 及之前的官方版本用的就是它，因此预期一致）。

## 构建方式

两个目标相互独立，各自只重建自己的包，可以单独跑也可以一条命令跑完：

```bash
# 只构建常规插件包（投放 Server 2016 及以上、Linux 主机）
make build_nodemanPlugin ENV_BK_BSCP_VERSION=v1.3.6

# 只构建兼容旧版 Windows 的插件包（投放 Server 2008 R2 / 2012 / 2012 R2、Win 7 SP1 / 8.1）
# 首次会自动下载并校验补丁工具链（约 69MB，之后跳过）
make build_nodemanPlugin_winLegacy ENV_BK_BSCP_VERSION=v1.3.6

# 两个包一起构建
make build_nodemanPlugin build_nodemanPlugin_winLegacy ENV_BK_BSCP_VERSION=v1.3.6
```

产物是两个可直接上传到节点管理的包：

```
build/nodemanPlugin/bkbscp.tar.gz             # 含 Linux 与 Windows 两个平台目录
build/nodemanPlugin/bkbscp-win-legacy.tar.gz    # 只含 plugins_windows_x86_64
```

版本号必须是 `v1.x.x` 格式。这不是 Makefile 的限制，而是 `pkg/version` 在 `init()` 里用
`^v1\.\d+\.\d+` 做了校验，`v9.9.9` 这类版本号能打出包，但二进制启动就会
`panic: invalid build version`。不传 `ENV_BK_BSCP_VERSION` 时版本号落成
`1.0.0-devops-unknown`，只适合本地验证。`ENV_BK_BSCP_VERSION=` 与 `VERSION=` 两种传法都生效，
CI 里用的是后者。模板注入 `project.yaml` 时会剥掉 `v` 前缀，ldflags 里保留。

只想验证工具链安装：

```bash
make install_go_win_toolchain
```

构建机无法访问 GitHub 时，可以让 `winLegacy` 目标退回官方工具链，用于验证打包流程本身
（产出的 exe 在 Server 2008 R2 / 2012 上仍会崩溃）：

```bash
make build_nodemanPlugin_winLegacy GO_WIN_LEGACY=$(command -v go)
```

## 升级补丁工具链版本

1. 在 [releases](https://github.com/XTLS/go-win7/releases) 选择新的 tag，例如 `patched-1.26.7`；
2. 下载 `go-for-win7-linux-amd64.zip`，核对 sha256；
3. 更新 `Makefile` 里的 `GO_WIN_TOOLCHAIN_TAG`；
4. 把新的 sha256 补进 `scripts/install-go-win-toolchain.sh` 的 `checksum_for()`。

第 4 步是必须的：安装脚本在查不到对应 tag 的校验值时会直接失败，而不会静默跳过校验。

## 维护注意事项

- `GOTOOLCHAIN=local` 不能去掉。`go.mod` 里有 `toolchain` 指令，一旦它要求的版本高于补丁
  工具链，Go 会自动下载官方工具链来构建，补丁就静默失效了。加上之后这种情况会直接报错。
- 构建时会清除 `GOROOT` 环境变量。gvm、asdf 这类版本管理器会导出 `GOROOT`，指向另一套
  工具链的编译器，会导致 `compile: version ... does not match go tool version ...`。
- 插件名同时是包内目录名、可执行文件名和配置文件名：GSE 的启停脚本按这个名字定位进程，也按
  这个名字拼出 `-c ../etc/<插件名>.conf`。改名时四者必须一起改（`Makefile` 的
  `plugin_add_linux` / `plugin_add_windows` 已用 `$(1)` 统一处理，`project.yaml.tpl` 里对应
  `__PLUGIN_NAME__`）。
- 该 fork 声明从 Go 1.27 起不再支持未打 KB3125574 补丁的 Windows 7 / Server 2008 R2。
  如果届时仍需支持这批机器，需要重新评估方案。

## 受影响的系统范围

| 系统 | `bkbscp` 的 Windows 产物 | `bkbscp-win-legacy` 的 Windows 产物 |
| --- | --- | --- |
| Windows Server 2008 R2 / 2012 / 2012 R2 | 启动即崩溃 | 已实机启动通过，不再崩溃 |
| Windows 7 SP1 / 8.1 | 启动即崩溃 | 预期可运行（同上原理，未单独验证） |
| Windows Server 2016 及以上 / Windows 10 及以上 | 可运行 | 预期可运行（待实机验证） |
