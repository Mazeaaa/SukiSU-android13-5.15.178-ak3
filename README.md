# fuxi（小米 13）GKI 5.15.178 内核构建套件

SukiSU Nova + SUSFS + KPM + ZRAM（LZ4KD）增强，适配 **HyperOS 3 / 澎湃 3**（内核 `5.15.178-android13`）。

产出两种刷机包：

| 产物 | 用途 | 刷入方式 |
|---|---|---|
| `boot-fuxi-*.img` | **首选**，只替换 boot 分区内核 | `fastboot flash boot_a` |
| `fuxi-ak3-*.zip` | AnyKernel3 包，自动识别槽位、就地替换内核 | 第三方 Recovery / Kernel Flasher / Franco Kernel Manager |
| `fuxi-zram-lz4kd-*.zip` | 开机把 zram0 压缩算法切到 `lz4kd` | 管理器（KSU/APatch）模块刷入 |

## 当前产物状态（已构建完成，待真机验证）

| 项 | 值 |
|---|---|
| 产物 | `out/boot-fuxi-20261122-1831.img`（41MB）、`out/fuxi-ak3-20261122-1831.zip`（22MB）、`out/fuxi-zram-lz4kd-20261122-1831.zip` |
| 源码基线 | `common-android13-5.15-2025-03` @ `362d545d3` / Linux `5.15.178` |
| SukiSU Nova | `builtin` 分支（SUSFS_INLINE_HOOK），`KSU_VERSION=35079`，包名 `com.sukisu.nova`，`KSU_UAPI_VERSION=6` |
| SUSFS | **已内置**，`susfs_applied=1`，`SUSFS_VERSION=v2.4.0` |
| LZ4KD | 已内置，`lz4kd` 同时注册 `acomp` 与 `scomp` 两种算法 |
| KPM | `CONFIG_KPM=y`（接口已编入）但 **`inject_kpm=0`，未注入 kpimg**，KPM 需二次构建 |
| LTO | Thin LTO（Full LTO 单线程，14 核/10GB 下链接要 50 分钟以上） |
| AK3 结构 | 扁平结构，同 Wild Kernels 参考包：`Image` 在根目录、`block=boot`、`is_slot_device=auto`、`do.modules=0` |
| vermagic | `5.15.178-android13-8-android13-5.15-2025-03_r13-dirty SMP preempt mod_unload modversions aarch64` |

刷前先跑 `bash scripts/verify-artifacts.sh`，全绿再刷。

### 与最新版 SukiSU Nova 管理器的兼容性

Nova 管理器判断兼容用的是**精确相等**（`manager/.../HomeUiState.kt` 的 `isVersionMismatch`）：

```
kernelUAPIVersion == managerUAPIVersion  &&  ksuVersion == managerVersionCode
```

- `KSU_UAPI_VERSION`：内核 `6`，最新管理器也是 `6` → **匹配**。
- `ksuVersion`：管理器 `versionCode = 3*10000 + main分支commit数 + 996`。截至本次构建 main = 4083 commits → **35079**，本内核已按此对齐。
- 管理器一发新版，这个数就会变（差 1 也会被判 mismatch）。此时要么用新 versionCode 重编，要么在管理器里用「版本伪装」消除提示。重编命令：

```bash
# 从 release 名里读版本号，例如 "Manager CI (35079)" -> 35079
KSU_VERSION=35079 WITH_SUSFS=1 WITH_LZ4KD=1 bash scripts/build.sh
```

---

## 0. 可行性结论（先看这段）

能实现，路径明确，但有 3 个硬约束：

1. **GKI 模型**：fuxi 的 `boot.img` 里只有 GKI 内核（ACK `android13-5.15`），GPU/音频/触控/摄像头等驱动在 `vendor_dlkm`、`vendor_boot` 里。所以我们**不需要小米的机型内核源码**，只需 ACK 树 + 与 stock 一致的 config。这也意味着：**不要动 `init_boot` / `vendor_boot` / `system_dlkm` / `vbmeta`**。
2. **`CONFIG_MODVERSIONS=y`**（GKI 默认）：厂商模块加载时只比对 vermagic 的 flag 段（`SMP preempt mod_unload modversions aarch64`），版本号字符串不必逐字相同；但**导出符号 CRC 必须一致**——所以 config 只能“追加”不能“删改”，且源码基线要与 stock 同一条 ACK 线（这里就是 `2025-03`）。
3. **编译必须 Linux**：本机是 Windows，套件通过 WSL2（`fuxi-build` 发行版，导入在 D: 盘）本地编译，
   或用 **GitHub Actions 云端构建**（约 50–80 分钟，4 vCPU + Thin LTO）。两条路径产物一致。

风险点（已在本地构建中逐一解决，详见 `## 6. 已知限制`）：SUSFS 补丁在 5.15.178 上有 1 个 hunk 不匹配
（官方上下文含高通独有的 `#include <trace/hooks/blk.h>`），已用锚点插入补齐；LZ4KD 与 KPM 属于新增符号，不影响 KMI。

---

## 1. 目录

```
.
├─ .github/workflows/build-fuxi.yml   # Actions：可勾选 SUSFS / KPM / LZ4KD / AK3
├─ scripts/
│  ├─ build.sh                        # 主流程：sync ACK 2025-03 → lz4kd → SUSFS → Nova → 编译 → KPM → 打包
│  ├─ lz4kd_setup.py                  # 把 lz4kd 装进 crypto/ 树（Makefile + Kconfig 钩子）
│  ├─ repack_boot.py                  # 用 stock boot.img 做“继承式”重打包（最稳）
│  ├─ pack_bootimg.py                 # 无 stock 时从零生成 boot header v4
│  ├─ pack_ak3_wild.sh                # 按 Wild Kernels 参考包的扁平结构打 AK3（主流程用这个）
│  ├─ pack_anykernel3.sh              # 旧版打包（写死 by-name 全路径），保留备用
│  ├─ patch_ksu_version.py            # 固定 KSU_VERSION / FULL / 包名（自动识别 Kbuild 或 Makefile）
│  ├─ apply_hooks.py                  # builtin 分支的 4 个手工 hook（SUSFS 补丁已带，作幂等兜底）
│  ├─ susfs_namespace_fix.py          # 补齐 fs/namespace.c 那个打不上的 include hunk
│  ├─ verify-artifacts.sh             # 产物自检：符号 / vermagic / boot 头 / AK3 / ZRAM 模块
│  ├─ wsl-build.sh                    # WSL 侧一键：同步套件 + 规范化 CRLF + 调 build.sh
│  ├─ wsl-susfs-test.sh               # 只跑 SUSFS 补丁环节（1 分钟，不编译）
│  └─ wsl-deps.sh                     # WSL 内 apt 依赖安装
├─ configs/
│  ├─ fuxi-ksu.config                 # CONFIG_KSU / CONFIG_KPM
│  ├─ fuxi-susfs.config               # CONFIG_KSU_SUSFS*（11 项）
│  ├─ fuxi-zram.config                # CONFIG_LZ4KD 等
│  └─ fragment.fuxi                   # GKI_BUILD_CONFIG_FRAGMENT：关掉 KMI 纯净性校验
└─ modules/fuxi-zram-lz4kd/           # 开机切换 zram0 → lz4kd 的 KSU 模块
```

---

## 2. 构建前必须提供的 4 个信息（真机执行）

```bash
uname -r                                  # 期望形如 5.15.178-android13-xxxx-g<hash>
getprop ro.boot.slot_suffix               # _a / _b
getprop ro.build.version.incremental      # ROM 版本号，如 OS3.0.x.x.WMCCNXM
which su; echo $?                         # 当前是否已 root
```

再抓一份 **stock boot.img**（救砖底线，也是重打包的基准）：

```bash
# 已 root：
dd if=/dev/block/by-name/boot$(getprop ro.boot.slot_suffix) of=/sdcard/stock_boot.img
# 未 root：用对应 ROM 包里的 images/boot.img，或用 payload.bin 解包
```

把 `uname -r` 里的 `<hash>` 传给 `KERNEL_COMMIT`（可选，但强烈建议：CRC 最接近 stock）。

---

## 3. 方式 A：GitHub Actions（推荐）

1. 新建仓库（Public/Private 都是 4 vCPU / 16GB / 14GB 盘，先跑清理步骤能腾到 ~40GB）。
2. 把本目录**内容**（不含最外层文件夹）推到仓库根目录，确认 `.github/workflows/build-fuxi.yml` 路径正确。
   `device/`、`work/`、`out/` 都在 `.gitignore` 里，**不用上传**（CI 也不需要 stock boot，见下）。

   本目录当前还不是 git 仓库，第一次推送：

   ```bash
   cd "本目录"
   git init -b main
   git add -A
   git commit -m "fuxi GKI 5.15.178: Nova builtin + SUSFS + LZ4KD + AK3 + Actions"
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

   推上去的应该只有 `README.md` / `FLASH-SEQUENCE.md` / `device.env` / `configs/` / `modules/` / `scripts/` / `.github/`，
   总量几百 KB。`git status` 如果看到 `device/`、`out/`、`work/` 就去查 `.gitignore`。

3. Actions → **Build fuxi GKI 5.15.178 (Nova builtin + SUSFS + LZ4KD)** → Run workflow：

| 输入 | 默认 | 说明 |
|---|---|---|
| `with_susfs` | `1` | 1 = Nova `builtin` 分支 + susfs4ksu 内置；0 = `main`（kprobe，无 SUSFS） |
| `with_lz4kd` | `1` | 1 = 内置 LZ4KD 压缩算法（crypto/lz4kd） |
| `inject_kpm` | `0` | 1 = 构建期用 KernelPatch 注入 kpimg。**这条路径还没真机验证过**，默认关 |
| `pack_ak3` | `1` | 1 = 额外产出 AnyKernel3 zip（扁平结构，同 Wild Kernels 参考包） |
| `ksu_version` | `35079` | 必须 = 你要装的管理器 versionCode（`3*10000+main_commits+996`） |
| `ksu_pkg` | `com.sukisu.nova` | Nova 管理器包名 |
| `kernel_commit` | 空 | stock `uname -r` 里的 `g<hash>`，留空则用分支 tip |

4. 产物在运行页底部 Artifacts：`boot-fuxi-*.img`、`fuxi-ak3-*.zip`、`fuxi-zram-lz4kd-*.zip`、`Image`、`BUILD_INFO.txt`、`SHA256SUMS`、`build-run.log`、`verify.log`。

CI 流水线做的事：清理磁盘 → 8GB swap → `install-deps.sh`（含 `repo` 启动器）→ `build.sh`（`repo sync` 带 3 次重试 + `--force-sync` → 打补丁 → Thin-LTO 编译 → 重打包 → AK3）→ `verify-artifacts.sh` 自检 → 上传。

各阶段大致耗时（GitHub 4 vCPU / 16GB）：`repo sync` 8–15 分钟 → 打补丁 2 分钟 → 编译 25–40 分钟（Thin LTO）→ 打包自检 3 分钟。**最不可控的是 `repo sync`**：`kernel/common` 单个仓库就有 1460 万个对象 / ~1.3GB，即使 `-c` 只拉一个分支也要完整历史。所以 workflow 给了 300 分钟超时，`build.sh` 里 sync 失败会重试 3 次（第二次起 `--force-sync`），三次都失败还会单独 `fetch_repo` 补 `common`。

### CI 没有 stock boot.img 也能出等价的 boot.img

本地是拿 `device/boot_a_current.img` 做「继承式重打包」，CI 上没有这个文件，会走 `scripts/pack_bootimg.py` 从零生成 v4 头。已实测两条路产物**逐字节相同**：

```
md5(scratch-boot.img) = e64a664e18602bb6f506de2caa931c85
md5(boot-fuxi-*.img)  = e64a664e18602bb6f506de2caa931c85
```

原因：fuxi 的 stock boot 本身就是 `v4 / header_size 1584 / ramdisk 0 / signature 0 / os_version 0 / cmdline 空`，从零生成用的正是同一组值。

管理器 APK：用最新 `com.sukisu.nova`（当前 manager-ci = `35079`）与本内核精确匹配；先刷内核，开机正常后再装。

---

## 4. 方式 B：本地 / 云主机

Ubuntu 22.04+，≥35GB 空闲磁盘，能访问 `android.googlesource.com`：

```bash
bash scripts/install-deps.sh
export PATH="$HOME/bin:$PATH"
KSU_VERSION=35079 KSU_PKG=com.sukisu.nova \
WITH_SUSFS=1 WITH_LZ4KD=1 INJECT_KPM=0 PACK_AK3=1 \
STOCK_BOOT=/path/to/stock_boot.img \
bash scripts/build.sh
```

可选覆盖：`ACK_REF`、`KERNEL_COMMIT`、`SUSFS_STRICT=1`（补丁失败直接中止）、`SKIP_SYNC=1`（复用已同步的 `work/`，本地二次构建必用，省 10 分钟）、`AK3_TEMPLATE`（指定一个参考 AK3 zip 当模板，工具版本与它保持一致）、`WORK`、`OUT`。

`repo sync` 失败时的行为：自动重试 3 次（`-j12` → `-j4 --force-sync` → `-j1 --force-sync --fail-fast`），仍失败则单独 `git clone` 补 `common`；最后校验 `common`/`build`/`prebuilts` 三者齐全才继续。

---

## 5. 功能是怎么实现的

| 功能 | 实现 | 关键 config |
|---|---|---|
| SukiSU Nova | `kernel/` 整棵拷进 `drivers/kernelsu`，挂 Makefile/Kconfig，固定 `KSU_VERSION`/包名 | `CONFIG_KSU=y` |
| SUSFS | `susfs4ksu` `gki-android13-5.15` 的 `50_add_susfs_in_gki-android13-5.15.patch`（fuzz 应用）+ 锚点补齐 `fs/namespace.c` | `CONFIG_KSU_SUSFS*` |
| KPM | KernelPatch `kpimg` 注入 `Image`（`kptools -p -i Image -k kpimg`） | `CONFIG_KPM=y` |
| ZRAM 增强 | `crypto/lz4kd` 注册 scomp 算法 `lz4kd`（LZ4K 4K 页剪裁 + Delta 跨页差分）；5.15 的 `zcomp_available_algorithm()` 走 `crypto_has_comp()`，**无需改 zram 源码** | `CONFIG_LZ4KD=y`、`CONFIG_CRYPTO_ACOMP2=y` |

`builtin` 分支的结构要点（改代码前必读）：

- 它把 `feature/ supercall/ runtime/ selinux/ ...` 全部 **`#include "xxx.c"` 进 `ksu_main.c`，是单编译单元**，
  所以只有 `CC drivers/kernelsu/ksu_main.o` 一条编译命令，没有 `Kbuild`；`KSU_VERSION` 由 `kernel/Makefile` 推算，
  必须用 `patch_ksu_version.py` 钉成硬值。
- 仓库根的 `uapi/` 是相对符号链接 `-> ./kernel/include/uapi`，`cp -a` 会复制成断链，必须先 `readlink -f` 解析真实目录。
- 4 个手工 hook（`ksu_handle_execveat` / `faccessat` / `stat` / `sys_reboot`）**SUSFS 补丁自己就注入了**；
  `ksu_handle_setresuid`（下发 manager fd 的关键）也是 SUSFS 补丁注入在 `kernel/sys.c`。`apply_hooks.py` 只是幂等兜底。

开机确认：

```bash
dmesg | grep -i 'susfs'                        # 期望 susfs is initialized! version: v2.4.0
grep -c lz4kd /proc/crypto                     # >0 说明算法已注册
cat /sys/block/zram0/comp_algorithm            # 切过之后应出现 [lz4kd]
cat /sys/block/zram0/mm_stat                   # 观察 orig_data_size / compr_data_size 比值
```

`lz4kd` 比 lz4 压缩比高、比 zstd 延迟低，随机读写（mm_stat 里的 `compr_data_size` 下降）是主要收益；可用 `modules/fuxi-zram-lz4kd` 模块开机自动切换。

---

## 6. 已知限制

- **zram 是模块**（GKI `CONFIG_ZRAM=m`，在 `system_dlkm`）：不要把 `lz4kd` 设成“编译期默认压缩算法”，只能运行时切（模块脚本负责）。刷新 `system_dlkm` 不在本套件范围；也**不要**把 zram 改成 `=y`，会与 `system_dlkm` 里的 `zram.ko` 抢符号。
- **SUSFS 那个打不上的 hunk**：官方补丁 `fs/namespace.c` 的 include hunk 上下文里有 `#include <trace/hooks/blk.h>`（高通私有），纯 ACK 没有这行，所以 hunk 必然失败。已由 `scripts/susfs_namespace_fix.py` 按锚点幂等补齐，不要手工改 `.rej`。
- **失败回滚必须覆盖所有被改目录**：官方补丁同时改了 `block/`、`drivers/input/`、`fs/`、`kernel/`、`mm/`、`security/`。只回滚 `fs include kernel security mm` 会把这些半应用状态留到下一轮，下一轮就报 `Reversed (or previously applied) patch detected`。
- **KPM 本轮未注入**：`CONFIG_KPM=y` 只打开了接口，没注入 kpimg，加载 `.kpm` 会失败。需要 `INJECT_KPM=1` 再编一轮。
- **Full LTO 在这台机器上不可行**：`ld.lld` 单线程，14 核/10GB 下链接 50 分钟以上、RSS 8.2GB。默认已切 Thin LTO，ABI/CRC 不受影响。
- **OTA 会覆盖 boot**，升级系统后需重新刷。
- 改内核后**永不重锁 BL**（`system has been destroyed`）。

刷机与回滚见 [FLASH-SEQUENCE.md](FLASH-SEQUENCE.md)。

[wbs-reply-done]: #
