/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __ASM_PROTOTYPES_H
#define __ASM_PROTOTYPES_H
/*
 * CONFIG_MODVERSIONS requires a C declaration to generate the appropriate CRC
 * for each symbol. Since commit:
 *
 *   4efca4ed05cbdfd1 ("kbuild: modversions for EXPORT_SYMBOL() for asm")
 *
 * ... kbuild will automatically pick these up from <asm/asm-prototypes.h> and
 * feed this to genksyms when building assembly files.
 *
 * 2026-09-12 (n0_kernel_pipa): 本树缺失该文件(上游 4.19 即已存在, 属 backport
 * 遗漏)。后果不是编译报错, 而是 scripts/Makefile.build 第 378 行的
 * ASM_PROTOTYPES wildcard 为空, 导致其下 $(cmd_modversions_S) 条件块不生效,
 * 于是 .S 文件的导出符号(arch/arm64/lib 的 .S、kernel/smccc-call.S、
 * kernel/entry-ftrace.S, 共 26 个)拿不到 genksyms 算出的 CRC, __crc_* 保持
 * .weak 未定义, vmlinux 链接近 200 行 ABS32 重定位错误(recompile with -fPIC)。
 * 补回本文件即修复。注意: 本文件会经 .S 的预处理链, 注释里的单引号会让
 * clang 报 missing terminating ' 警告, 故不使用单引号。
 */
#include <linux/arm-smccc.h>

#include <asm/ftrace.h>
#include <asm/page.h>
#include <asm/string.h>
#include <asm/uaccess.h>

#include <asm-generic/asm-prototypes.h>

long long __ashlti3(long long a, int b);
long long __ashrti3(long long a, int b);
long long __lshrti3(long long a, int b);

#endif /* __ASM_PROTOTYPES_H */
