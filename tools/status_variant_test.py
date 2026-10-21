#!/usr/bin/env python3
"""状态栏项变体测试（隔离 LaunchServices 干扰）。

要点：测试副本一律用独立 bundle id（com.hujie.deskboard.test），
否则每跑一次就在系统里多一条 com.hujie.deskboard 的登记，
几百条之后状态栏项会被整个压制 —— 那会把「代码问题」和「注册表问题」搅成一锅。

判据：
  ① 新增墨迹簇数 = 探针项（● ▲ ★）有没有活下来
  ② 红像素数     = 正式项有没有被画出来
用法：status_variant_test.py
"""
import subprocess, time, sys, os, shutil, plistlib
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from menubar_scan import capture, ink_profile, clusters

SRC = "./build/DeskBoard.app"
TEST_APP = "/tmp/DeskTest.app"
TEST_ID = "com.hujie.deskboard.test"


def prepare():
    shutil.rmtree(TEST_APP, ignore_errors=True)
    shutil.copytree(SRC, TEST_APP)
    p = plistlib.load(open(TEST_APP + "/Contents/Info.plist", "rb"))
    p["CFBundleIdentifier"] = TEST_ID
    plistlib.dump(p, open(TEST_APP + "/Contents/Info.plist", "wb"))
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", TEST_APP],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def red_pixels(path):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.int16)
    m = (a[:, :, 0] > 140) & (a[:, :, 1] < 90) & (a[:, :, 2] < 90)
    return int(m.sum())


def run(variant, probes=True):
    env = dict(os.environ)
    env.pop("DESKBOARD_STATUS_VARIANT", None)
    if variant is not None:
        env["DESKBOARD_STATUS_VARIANT"] = variant
    if probes:
        env["DESKBOARD_PROBE_ITEM"] = "1"
    else:
        env.pop("DESKBOARD_PROBE_ITEM", None)
    capture('/tmp/sv1.png')
    subprocess.Popen([TEST_APP + "/Contents/MacOS/DeskBoard"], env=env,
                     stdout=open('/tmp/sv.log', 'w'), stderr=subprocess.STDOUT)
    time.sleep(3.5)
    capture('/tmp/sv2.png')
    subprocess.run(["pkill", "-f", "DeskTest.app"])
    time.sleep(1.5)
    a = ink_profile('/tmp/sv1.png'); b = ink_profile('/tmp/sv2.png')
    n = min(len(a), len(b))
    return len(clusters(b[:n] - a[:n])), red_pixels('/tmp/sv2.png') - red_pixels('/tmp/sv1.png')


if __name__ == "__main__":
    prepare()
    print("%-10s %-22s %s" % ("变体", "新增簇(探针存活)", "红像素(正式项画出)"))
    for v in ["none", "red", "noimage", "notip", "nomenu", "nosync", "glyph"]:
        cl, rp = run(v)
        print("%-10s %-22s %s" % (v, cl, rp))
    cl, rp = run(None, probes=False)
    print("%-10s %-22s %s" % ("正常无探针", cl, rp))
