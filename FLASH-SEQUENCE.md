# fuxi 刷机与验证顺序（HyperOS 3 / 5.15.178 / SukiSU Nova builtin + SUSFS + LZ4KD）

> 本轮产物：`sukisu_branch=builtin`、`susfs_applied=1`（SUSFS v2.4.0）、`with_lz4kd=1`、`inject_kpm=0`。
> 前提：**bootloader 已解锁**（本机 `androidboot.verifiedbootstate = orange`，已确认解锁）。
> 只动 `boot` 分区。**不碰 `init_boot` / `vendor_boot` / `dtbo` / `system_dlkm` / `vbmeta`**。

## 0. 准备与硬备份

```bash
adb devices                        # 能识别
adb reboot bootloader
fastboot getvar current-slot       # 期望 a
fastboot getvar unlocked           # 必须 yes/1
```

**救砖底线**：备份当前槽的原厂/可用 boot

```bash
adb shell "dd if=/dev/block/by-name/boot$(getprop ro.boot.slot_suffix) of=/sdcard/stock_boot.img"
MSYS_NO_PATHCONV=1 adb pull /sdcard/stock_boot.img
```

`device/boot_a_current.img` 已经是本机当前可启动的 boot（192MB），可直接当回滚镜像。

## 1. 刷内核

```bash
# 先只刷当前槽，另一槽留原厂兜底
fastboot flash boot_a boot-fuxi-20261122-1831.img
fastboot reboot
```

首次开机 2–5 分钟，别断电。

## 2. 开机验证（先别装管理器）

```bash
adb shell "uname -r"
# 期望：5.15.178-android13-8-android13-5.15-2025-03_r13-dirty

# 厂商模块是否正常加载（最关键：>400 且没有 Unknown symbol）
adb shell "cat /proc/modules | wc -l"
adb shell "dmesg | grep -iE 'disagrees about version|Unknown symbol|module_layout|CFI failure'"

# SUSFS 是否真的初始化
adb shell "dmesg | grep -i 'susfs'"
# 期望出现：susfs is initialized! version: v2.4.0

# LZ4KD 是否注册进 crypto
adb shell "cat /proc/crypto | grep -A4 -w lz4kd"
# 期望出现 name : lz4kd / driver : lz4kd-scomp
```

手动确认：WiFi、相机（前后）、指纹、声音、触控、UFS 读写、通话、蓝牙。

> 关于 `-dirty`：vermagic 里带 `-dirty` 是正常的（源码树被打过补丁）。
> 内核开了 `CONFIG_MODVERSIONS=y`，模块加载时**只比对 `SMP preempt mod_unload aarch64` 这段和符号 CRC，不比对版本号**，
> 所以厂商 `.ko` 照样能加载——前提是符号 CRC 一致（我们用的就是同一条 ACK 5.15.178 基线，并且只追加 config、没改已有项）。

确认稳定后再同步另一槽：

```bash
fastboot --slot=all flash boot boot-fuxi-20261122-1831.img
```

## 3. 安装 SukiSU Nova 管理器

```bash
adb install -r SukiSU_Nova_manager-ci_35079-arm64-v8a-release.apk
adb shell su -c id                          # 期望 uid=0(root)
```

- 管理器首页应显示 **内置 / Built-in** 模式（不是 LKM）。
- Nova 判断兼容是**精确相等**：`ksuVersion == 管理器 versionCode` 且 `KERNEL_SU_UAPI_VERSION` 一致。
  本内核 `KSU_VERSION=35079`、uapi `6`，对应最新 manager-ci。
  如果你装的管理器不是 35079（一发新版就差 1），首页会出现版本不匹配提示：
  要么在管理器里开「版本伪装」消除，要么用那个版本号重编：
  `KSU_VERSION=<版本号> WITH_SUSFS=1 WITH_LZ4KD=1 bash scripts/build.sh`。

## 4. 开启 SUSFS

内核侧已经编进去了，管理器里不需要装任何外挂 `.ko`：

1. 管理器 → **SUSFS** 页 → 确认显示版本 `v2.4.0`；
2. 按需打开：`隐藏 SUS 路径` / `隐藏 SUS 挂载` / `spoof kstat` / `自定义 uname` / `spoof bootconfig`；
3. 生效后用目标 App 自检（注意：开了 `HIDE_KSU_SUSFS_SYMBOLS` 后 `/proc/kallsyms` 里查不到 `susfs_` 符号，这是**预期行为**，不要误判为没编进去）。

## 5. 切 ZRAM 到 lz4kd

**手动切（重启失效，用来先验效果）：**

```bash
su -c 'A=/sys/block/zram0; \
       swapoff /dev/block/zram0; \
       echo 1 > $A/reset; \
       echo lz4kd > $A/comp_algorithm; \
       echo $(( $(awk "/MemTotal/{print \$2}" /proc/meminfo) * 512 )) > $A/disksize; \
       mkswap /dev/block/zram0; swapon /dev/block/zram0'
cat /sys/block/zram0/comp_algorithm      # 期望 [lz4kd] lzo-rle lz4 lz4hc zstd
```

⚠️ **必须先把 `disksize` 归零（reset）再写 `comp_algorithm`**，否则内核会拒绝（`-EBUSY`）。
这是 5.15 的行为，也是模块脚本里那几步顺序的原因。

**开机自动**：刷 `fuxi-zram-lz4kd-20261122-1831.zip`（管理器 → 模块 → 从本地安装 → 重启）。
日志在 `/data/local/tmp/fuxi_zram_lz4kd.log`。

效果对比看 `cat /sys/block/zram0/mm_stat` 第 1/2 列（orig_data_size / compr_data_size），
比值越小压缩率越高；同时看 `cat /proc/meminfo | grep -i swap` 的使用量。

## 6. KPM（本轮**未**注入，需要二次构建）

`BUILD_INFO.txt` 里是 `inject_kpm=0`。当前内核 `CONFIG_KPM=y`（接口已编入），但**没有注入 kpimg**，
所以管理器 KPM 页可能显示可用、实际加载 `.kpm` 会失败。

要用 KPM 需要下一轮：

```bash
INJECT_KPM=1 bash scripts/build.sh     # 需要 WORK 下已有 KernelPatch 的 kptools-linux + kpimg
```

它会走 `kptools-linux -p -s 123 -i Image -k kpimg -o Image.kpm`，改动 `Image` 后重新打包 boot。
**注意**：KPM 注入会改写 Image 头部区域，注入失败时不要拿半成品刷机。

## 7. AnyKernel3 zip（可选路径）

`fuxi-ak3-20261122-1831.zip` 用 Kernel Flasher / Franco Kernel Manager 之类刷入，效果等同刷 `boot.img`。

结构与 Wild Kernels 那两个参考包**完全一致**：`Image` 在 zip 根目录，无 `patch/`、`modules/` 目录；
`anykernel.sh` 用 `block=boot` + `is_slot_device=auto`（自动判断当前槽）、`do.modules=0`、`no_magisk_check=1`；
`split_boot` 后如果没有 `ramdisk.cpio` 就走 `flash_boot`（fuxi 的 GKI boot 正是无 ramdisk）。

**优先用 `boot.img` + fastboot**：fuxi 没有成熟 TWRP，AK3 依赖 App 的分区挂载与 magiskboot，失败面比 fastboot 直刷大。

## 8. 回滚

```bash
fastboot --slot=all flash boot stock_boot.img
fastboot reboot
# 整包救砖（保数据）：ROM 目录下 flash_all_except_storage.bat
```

## 9. 红线

- 改过 boot 后**永不重锁 BL**（`system has been destroyed` / 变砖）。
- 官方 OTA 会覆盖 boot，升级后需重刷内核。
- 不要刷 `system_dlkm`（`zram.ko` 在里面；本套件的 LZ4KD 走 crypto 算法注册，**不需要**换 zram 模块）。
- 不要改用 `CONFIG_ZRAM=y` 重编：会和 `system_dlkm` 里的 `zram.ko` 抢同一批符号。
- anti 版本不要回刷更低 ROM。

## 10. 刷前自检（电脑侧）

```bash
bash scripts/verify-artifacts.sh
```

会检查：内核符号（susfs/ksu/lz4kd）、vermagic 含 modversions、SUSFS 版本串、boot 头与 stock 逐字段一致、
AK3 包结构、ZRAM 模块脚本。**全绿再刷**。
