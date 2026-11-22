#!/usr/bin/env python3
"""用 stock boot.img 做“继承式”重打包：只换内核，其余 header 字段 / ramdisk / dtb 原样保留。

比从零构造 header 更稳：os_version、cmdline、name、分区页大小、dtb 全部沿用原厂，
只把 kernel 段换掉、更新 kernel_size，并去掉 boot signature（改过内核后签名必然失效，
解锁 BL 下 AVB 不强制）。

支持 header v0/v1/v2/v3/v4。fuxi（GKI）实际是 v4 + 无 ramdisk。

布局差异（容易踩坑）：
  v0/v1/v2：page_size 存在 header@36，kernel/ramdisk/second 均按 page 对齐；
  v3/v4   ：header 结构重排，无 page_size 字段（固定 4096），
            kernel_size@8，ramdisk_size@12，os_version@16，header_size@20，
            header_version@40，cmdline@44，v4 的 signature_size@1580。

用法：
  repack_boot.py --stock stock_boot.img --kernel Image[.kpm] --output boot-new.img
"""
import argparse
import struct
import sys

MAGIC = b"ANDROID!"
PAGE_V34 = 4096


def align(n, page):
    return (n + page - 1) // page * page


def u32(b, off):
    return struct.unpack_from("<I", b, off)[0]


def parse(b):
    if b[:8] != MAGIC:
        sys.exit("repack_boot: 不是 Android boot image（magic 不符）")

    hv = u32(b, 40)
    h = {"hv": hv, "rec_size": 0, "dtb_size": 0, "sig_size": 0}

    if hv in (0, 1, 2):
        h["page"] = u32(b, 36) or 2048
        h["kernel_size"] = u32(b, 8)
        h["ramdisk_size"] = u32(b, 16)
        h["second_size"] = u32(b, 24)
        if hv == 0:
            h["header_size"] = 1632
            h["order"] = ("kernel", "ramdisk", "second")
        elif hv == 1:
            h["header_size"] = u32(b, 1644) or 1648
            h["rec_size"] = u32(b, 1632)
            h["order"] = ("kernel", "ramdisk", "second", "recovery_dtbo")
        else:
            h["header_size"] = u32(b, 1644) or 1660
            h["rec_size"] = u32(b, 1632)
            h["dtb_size"] = u32(b, 1648)
            h["order"] = ("kernel", "ramdisk", "second", "recovery_dtbo", "dtb")
    elif hv in (3, 4):
        h["page"] = PAGE_V34
        h["kernel_size"] = u32(b, 8)
        h["ramdisk_size"] = u32(b, 12)   # v3/v4 没有 kernel_addr，ramdisk_size 前移
        h["second_size"] = 0
        h["header_size"] = 1584 if hv == 4 else 1580
        h["sig_size"] = u32(b, 1580) if hv == 4 else 0
        h["order"] = ("kernel", "ramdisk")
    else:
        sys.exit(f"repack_boot: 不支持 header_version={hv}")

    return h


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock", required=True)
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    stock = open(args.stock, "rb").read()
    kernel = open(args.kernel, "rb").read()
    if not kernel:
        sys.exit("repack_boot: 内核镜像为空")
    if len(stock) < 4096:
        sys.exit("repack_boot: stock boot.img 过小")

    h = parse(stock)
    page = h["page"]
    hv = h["hv"]

    if h["ramdisk_size"] or h["second_size"] or h["rec_size"] or h["dtb_size"]:
        print("[repack] 警告：stock boot 含 ramdisk/second/dtbo/dtb，将按序重排，务必核对产物",
              file=sys.stderr)

    # ---- 按 header 顺序切段（每段页对齐） ----
    off = page
    blobs = {}
    for name in h["order"]:
        size = {
            "kernel": h["kernel_size"],
            "ramdisk": h["ramdisk_size"],
            "second": h["second_size"],
            "recovery_dtbo": h["rec_size"],
            "dtb": h["dtb_size"],
        }[name]
        blobs[name] = stock[off:off + size]
        off += align(size, page)

    blobs["kernel"] = kernel

    # ---- header：只改 kernel_size / signature_size ----
    head = bytearray(stock[:page])
    struct.pack_into("<I", head, 8, len(kernel))
    if hv == 4:
        struct.pack_into("<I", head, 1580, 0)   # 内核变了，原签名失效，清零

    out = bytearray(head)
    for name in h["order"]:
        blob = blobs[name]
        out += blob
        out += b"\x00" * (align(len(blob), page) - len(blob))

    with open(args.output, "wb") as f:
        f.write(out)

    print(f"[repack] stock v{hv} page={page} kernel={h['kernel_size']} ramdisk={h['ramdisk_size']} "
          f"sig={h['sig_size']} -> new kernel={len(kernel)} image={len(out)}")
    print(f"[repack] 输出 {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
