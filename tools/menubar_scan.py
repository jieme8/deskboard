#!/usr/bin/env python3
"""菜单栏扫描：把状态栏里的图标按「墨迹簇」列出来，替代肉眼判断。

用法：
  menubar_scan.py                     # 扫当前菜单栏，打印每个图标的 x 区间（点）
  menubar_scan.py --diff A.png B.png  # 比较两张菜单栏截图，列出 B 相对 A 新出现的区间
"""
import subprocess, sys
import numpy as np
from PIL import Image

# 这台机器是 Retina，截图 2 倍。像素↔点换算用这个。
PPP = 2.0


def capture(path):
    subprocess.run(["screencapture", "-x", "-R0,0,1512,30", path], check=True)
    return path


def ink_profile(path):
    """每列的墨迹量 = 该列像素与「本列中位色（背景）」的最大偏差。"""
    im = Image.open(path).convert("RGB")
    a = np.asarray(im).astype(np.int16)
    bg = np.median(a, axis=0)                       # 每列的中位色 = 背景
    diff = np.abs(a - bg[None, :, :]).max(axis=2)   # (h,w)
    return diff.max(axis=0)


def clusters(prof, thresh=38, gap_pt=2.0):
    """把连续有墨迹的列聚成簇，返回 [(x0pt, x1pt), ...]"""
    on = prof > thresh
    out = []
    i, n = 0, len(on)
    gap_px = gap_pt * PPP
    while i < n:
        if not on[i]:
            i += 1
            continue
        j, gap = i, 0
        while j < n:
            if on[j]:
                gap = 0
            else:
                gap += 1
                if gap > gap_px:
                    break
            j += 1
        out.append((round(i / PPP, 1), round(min(j, n) / PPP, 1)))
        i = j
    return out


def main():
    args = sys.argv[1:]
    if args[:1] == ["--diff"] and len(args) >= 3:
        pa, pb = args[1], args[2]
        profa = ink_profile(pa)
        profb = ink_profile(pb)
        n = min(len(profa), len(profb))
        delta = profb[:n] - profa[:n]
        cs = clusters(delta)
        print("新增墨迹簇（%s 相对 %s）：" % (pb, pa))
        for x0, x1 in cs:
            print("  x %.1f - %.1f 点  (宽 %.1f)" % (x0, x1, x1 - x0))
        if not cs:
            print("  （没有新增）")
        return
    path = capture("/tmp/_mb_scan.png")
    cs = clusters(ink_profile(path))
    print("菜单栏墨迹簇（共 %d 个）：" % len(cs))
    for x0, x1 in cs:
        print("  x %.1f - %.1f 点  (宽 %.1f)" % (x0, x1, x1 - x0))


if __name__ == "__main__":
    main()
