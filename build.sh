#!/bin/bash

#开启严格模式 / Enable strict mode
#遇到任何非零退出码的错误直接退出
#Exit immediately on non-zero exit code
#管道命令中任一失败则整体失败
#Fail pipeline if any command fails
set -eo pipefail

#1.定义颜色输出 / Define color outputs
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' #无颜色 / No Color

#输出函数支持双语，短文本用单行，长文本用第二参数换行
#Output functions support bilingual: short text in one line, long text wraps via second arg
#使用 if 而非 [ ] && 以避免 set -e 在参数为空时退出
#Use if instead of [ ] && to avoid set -e exit when arg is empty
function msg() {
    echo -e "${GREEN}[INFO]${NC} $1"
    if [ -n "$2" ]; then echo -e "${GREEN}[INFO]${NC} $2"; fi
}
function warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    if [ -n "$2" ]; then echo -e "${YELLOW}[WARN]${NC} $2"; fi
}
function err() {
    echo -e "${RED}[ERROR]${NC} $1"
    if [ -n "$2" ]; then echo -e "${RED}[ERROR]${NC} $2"; fi
}

#2.依赖项与前置检查 / Dependencies and pre-checks
#检查基础依赖是否均已安装
#Check if basic dependencies are installed
msg "检查所需依赖项 / Checking required dependencies..."
for dep in git curl zip make; do
    if ! command -v "$dep" &> /dev/null; then
        err "未找到所需命令 '$dep'，请先安装" \
           "Required command '$dep' is not installed. Please install it first."
        exit 1
    fi
done

#3.工具链与环境变量设置
#3.Toolchain and environment settings
#确保编译器存在 / Ensure the compiler exists
if ! command -v "${CC:-clang}" &> /dev/null; then
    err "未找到编译器 '${CC:-clang}'，请检查环境" \
       "Compiler '${CC:-clang}' not found. Please check your environment."
    exit 1
fi

#获取 Clang 资源目录并向上回溯三级，推导出工具链根路径
#Get Clang resource dir and go up three levels to derive the toolchain root path
RESOURCE_DIR="$("${CC:-clang}" --print-resource-dir)"
TOOLCHAIN_PATH="$(dirname "$(dirname "$(dirname "$RESOURCE_DIR")")")"

#安全地获取 Git Commit ID / Safely get the Git Commit ID
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
else
    #不是 git 仓库，设置 COMMIT_ID 为 'unknown'
    #Not a git repository. Setting COMMIT_ID to 'unknown'
    warn "不是 git 仓库，COMMIT_ID 设为 'unknown'" \
        "Not a git repository. Setting COMMIT_ID to 'unknown'."
    GIT_COMMIT_ID="unknown"
fi

#检查工具链路径是否有效
#Check if toolchain path is valid
if [ ! -d "$TOOLCHAIN_PATH" ]; then
    err "工具链路径 [$TOOLCHAIN_PATH] 不存在，请确保工具链位于该路径，或在脚本中修改 TOOLCHAIN_PATH" \
       "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist. Please ensure the toolchain is at this path, or modify TOOLCHAIN_PATH in the script."
    exit 1
fi

msg "工具链路径 / TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

MAKE_ARGS="ARCH=arm64 O=out CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld CROSS_COMPILE=aarch64-linux-android- AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip"

#3.1 主机端 OpenSSL 头文件检测 / Host OpenSSL headers detection
#部分环境未安装 libssl-dev，导致 scripts/extract-cert.c 等主机工具
#编译时找不到 <openssl/bio.h>。此处优先使用系统头文件，缺失时回退到
#预置的本地副本，避免构建在配置阶段即失败。
#Some environments lack libssl-dev, which breaks host tools such as
#scripts/extract-cert.c that include <openssl/bio.h>. Prefer the system
#headers and fall back to a bundled local copy when they are missing.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SSL_INCLUDE="$SCRIPT_DIR/../.build-deps/ssl-usr/include"
LOCAL_SSL_ARCH_INCLUDE="$SCRIPT_DIR/../.build-deps/ssl-usr/include/x86_64-linux-gnu"
if [ ! -f /usr/include/openssl/bio.h ]; then
    if [ -f "$LOCAL_SSL_INCLUDE/openssl/bio.h" ]; then
        warn "未找到系统 openssl 头文件，使用本地副本 [$LOCAL_SSL_INCLUDE]" \
            "System openssl headers not found. Using local copy at [$LOCAL_SSL_INCLUDE]."
        #KBUILD_HOSTCFLAGS 在顶层 Makefile 中由 \$(HOSTCFLAGS) 拼接而成，
        #故通过环境变量导出即可同时追加多个 -I 路径（含架构相关的 opensslconf.h）。
        #KBUILD_HOSTCFLAGS is assembled from \$(HOSTCFLAGS) in the top-level
        #Makefile, so exporting it lets us append multiple -I paths at once,
        #including the arch-specific opensslconf.h location.
        export HOSTCFLAGS="-I$LOCAL_SSL_INCLUDE -I$LOCAL_SSL_ARCH_INCLUDE"
    else
        err "未找到 OpenSSL 头文件，请安装 libssl-dev 或将头文件放入 .build-deps/ssl-usr" \
           "OpenSSL headers not found. Install libssl-dev or place headers under .build-deps/ssl-usr."
        exit 1
    fi
fi

#检查 Clang 版本 / Check Clang version
msg "检查 Clang 版本 / Checking Clang version:"
clang --version

#导出构建变量 / Export build variables
export KBUILD_BUILD_USER="github"
export KBUILD_BUILD_HOST="bcggxx"
export KBUILD_LAST_COMMIT=${GIT_COMMIT_ID}

#4.强制清理逻辑 / Forced Clean Build logic
#执行强制清理以确保没有旧文件干扰
#Perform forced clean to ensure no old files interfere
msg "清理上次构建的残留文件（强制清理）" \
    "Performing cleanup of previous build files (Forced Clean)..."
rm -rf out/
rm -f error.log
mkdir -p out/

#5.准备 AnyKernel3 / Prepare AnyKernel3
msg "准备 AnyKernel3 / Preparing AnyKernel3..."
if [ -d "anykernel/.git" ]; then
    msg "AnyKernel3 已克隆，跳过克隆 / AnyKernel3 already cloned. Skipping clone."
    #清理残留的打包内核文件以确保环境干净
    #Clean up residual packed kernel files to ensure a clean environment
    rm -f anykernel/Image anykernel/dtb anykernel/dtbo.img
else
    #删除不完整的目录并重新克隆
    #Remove incomplete directory and re-clone
    rm -rf anykernel
    msg "为 pipa 克隆 AnyKernel3 / Cloning AnyKernel3 for pipa..."
    git clone https://github.com/bcggxx/AnyKernel3 -b n0-A16 --single-branch --depth=1 anykernel
fi

#6.开始编译 / Start compilation
msg "为 PIPA 配置 (pipa_defconfig) / Configuring for PIPA (pipa_defconfig)..."
make $MAKE_ARGS pipa_defconfig

#6.0.1 合并 Droidspaces 配置片段 / Merge the Droidspaces config fragment
#patch-droidspaces 这个 composite action 只把 droidspaces.config 拷到
#arch/arm64/configs/, 而配置片段必须经 merge_config.sh 合并才会进 .config。
#只跑 `make pipa_defconfig` 的话该片段会被完全忽略 —— 结果是 Droidspaces
#打上了 patch 却依然起不来(缺 UTS_NS/PID_NS/SYSVIPC 等)。
#Merge rules live in scripts/kconfig/Makefile (%.config target).
if [ -f "arch/arm64/configs/droidspaces.config" ]; then
    msg "合并 Droidspaces 配置片段 / Merging Droidspaces config fragment..."
    ./scripts/kconfig/merge_config.sh -O out -m out/.config arch/arm64/configs/droidspaces.config
    make $MAKE_ARGS olddefconfig

    #校验关键符号确实进了 .config，缺失则明确失败而不是静默出一个不能用的内核
    #Verify the key symbols really landed in .config; fail loudly otherwise
    DROIDSPACES_MISSING=""
    for sym in CONFIG_UTS_NS CONFIG_PID_NS CONFIG_IPC_NS CONFIG_NET_NS \
               CONFIG_SYSVIPC CONFIG_OVERLAY_FS CONFIG_CGROUP_DEVICE CONFIG_DEVTMPFS; do
        if ! grep -q "^${sym}=y" out/.config; then
            DROIDSPACES_MISSING="${DROIDSPACES_MISSING} ${sym}"
        fi
    done
    if [ -n "$DROIDSPACES_MISSING" ]; then
        err "Droidspaces 配置未生效，缺少:${DROIDSPACES_MISSING}" \
            "Droidspaces config not applied, missing:${DROIDSPACES_MISSING}"
        exit 1
    fi
    msg "Droidspaces 配置已合并并通过校验 / Droidspaces config merged and verified."
else
    warn "未找到 arch/arm64/configs/droidspaces.config，跳过 / not found, skipping."
fi

#6.1 按内存动态计算并行度 / Compute parallelism based on available memory
#本工具链启用 thin-LTO + polly，单个 clang 进程峰值约 1.5~2GB。
#直接使用 -j$(nproc) 在低内存机器上会因并行 clang 实例过多导致 OOM /
#段错误（exit 139）。这里按可用内存估算安全的 -j，并允许通过 JOBS 环境变量覆盖。
#The toolchain enables thin-LTO + polly; each clang process peaks at ~1.5-2GB.
#Using -j$(nproc) on low-memory hosts triggers OOM / segfault (exit 139) under
#parallel load. Estimate a safe -j from available memory; allow override via JOBS.
if [ -z "${JOBS:-}" ]; then
    MEM_AVAIL_KB=$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    SWAP_FREE_KB=$(awk '/SwapFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    #每作业预算 1500000 KB（约 1.5GB），向下取整，至少 1
    #Per-job budget ~1.5GB; floor to an integer, minimum 1
    MEM_BASED_JOBS=$(( (MEM_AVAIL_KB + SWAP_FREE_KB) / 1500000 ))
    [ "$MEM_BASED_JOBS" -lt 1 ] && MEM_BASED_JOBS=1
    CPU_JOBS=$(nproc --all)
    if [ "$MEM_BASED_JOBS" -lt "$CPU_JOBS" ]; then
        JOBS=$MEM_BASED_JOBS
        warn "内存不足：并行度限制为 -j${JOBS}（cpus=${CPU_JOBS}，可用≈$((MEM_AVAIL_KB/1024))MB），可用 JOBS=<n> 覆盖" \
            "Low memory: capping parallelism to -j${JOBS} (cpus=${CPU_JOBS}, avail≈$((MEM_AVAIL_KB/1024))MB). Override with JOBS=<n>."
    else
        JOBS=$CPU_JOBS
    fi
fi
msg "使用 -j${JOBS} 编译 / Building with -j${JOBS}"

msg "开始为 PIPA 编译内核 / Starting Kernel Build for PIPA..."
#记录开始时间以计算耗时
#Record start time to calculate duration
BUILD_START=$(date +"%s")

#编译主流程：输出同步到终端和错误日志
#Main build process: sync output to terminal and error log
#临时关闭 set -e，以便捕获 make 的退出码并给出友好提示
#Temporarily disable set -e to capture make's exit code and show friendly message
set +e
make $MAKE_ARGS -j"${JOBS}" 2>&1 | tee error.log
MAKE_EXIT_CODE=${PIPESTATUS[0]}
set -e

BUILD_END=$(date +"%s")
DIFF=$(($BUILD_END - $BUILD_START))

#检查编译退出码 / Check build exit code
if [ "$MAKE_EXIT_CODE" -ne 0 ]; then
    err "内核编译失败，退出码 $MAKE_EXIT_CODE" \
       "Kernel build failed with exit code $MAKE_EXIT_CODE!"
    err "请查看 error.log 获取详细失败原因 / Check error.log for detailed failure reasons."
    exit 1
fi

#7.检查产物与打包 / Check artifacts and package
#检查构建产物 / Check build artifacts
if [ ! -f "out/arch/arm64/boot/Image" ]; then
    #如果核心镜像不存在则直接报错退出
    #Exit with error if the core Image does not exist
    err "文件 [out/arch/arm64/boot/Image] 不存在，构建失败" \
       "The file [out/arch/arm64/boot/Image] does not exist. Build failed!"
    err "请查看 error.log 获取详细失败原因 / Check error.log for detailed failure reasons."
    exit 1
fi

msg "内核编译成功，耗时 $(($DIFF / 60)) 分 $(($DIFF % 60)) 秒" \
    "Kernel compiled successfully in $(($DIFF / 60)) minute(s) and $(($DIFF % 60)) second(s)."
msg "使用 AnyKernel3 打包 / Packaging with AnyKernel3..."

#安全拷贝内核文件并做异常处理
#Safely copy kernel files and handle exceptions
cp out/arch/arm64/boot/Image anykernel/ || { err "拷贝 Image 失败 / Failed to copy Image."; exit 1; }

if [ -f "out/arch/arm64/boot/dtb" ]; then
    cp out/arch/arm64/boot/dtb anykernel/ || { err "拷贝 dtb 失败 / Failed to copy dtb."; exit 1; }
else
    warn "未找到 dtb，跳过 / dtb not found, skipping."
fi

if [ -f "out/arch/arm64/boot/dtbo.img" ]; then
    cp out/arch/arm64/boot/dtbo.img anykernel/ || { err "拷贝 dtbo.img 失败 / Failed to copy dtbo.img."; exit 1; }
else
    warn "未找到 dtbo.img，跳过 / dtbo.img not found, skipping."
fi

#进入 AnyKernel 目录打包
#Enter AnyKernel directory to package
cd anykernel || { err "进入 anykernel 目录失败 / Failed to enter anykernel directory."; exit 1; }

timestamp=$(date +%Y%m%d)
ZIP_FILENAME="Kernel_N0_pipa_A16_AOSP_MIUI_${timestamp}.zip"

#优化 zip 参数并排除多余文件
#Optimize zip parameters and exclude unnecessary files
#如果打包失败则报错退出
#Exit with error if packaging fails
if zip -r9 "$ZIP_FILENAME" ./* -x "*.git*" "*out*" "*.zip" > /dev/null; then
    mv "$ZIP_FILENAME" ../
else
    err "创建刷机 zip 失败 / Failed to create flashable zip."
    exit 1
fi

cd ..

msg "PIPA 构建完成 / Build for PIPA finished."
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}完成！刷机包位于: ./$ZIP_FILENAME${NC}"
echo -e "${GREEN}Done! The flashable zip is: ./$ZIP_FILENAME${NC}"
echo -e "${GREEN}=====================================================${NC}"
