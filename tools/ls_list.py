#!/usr/bin/env python3
"""读 LaunchServices 数据库，按 bundle id 列出登记路径。

`lsregister -dump` 的格式是「一条记录一块」，块内先出现 path: 再出现 identifier:
（identifier 就是那个 App 的 bundle id）。按块解析才不会把别的 App 的路径算进来。

用法：
  ls_list.py com.hujie.deskboard          # 列出该 id 的登记路径
  ls_list.py com.hujie.deskboard --clean  # 注销除第一个以外的全部登记
"""
import subprocess, sys, re, os

LSREG = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"


def dump():
    return subprocess.run([LSREG, "-dump"], capture_output=True, text=True).stdout


def records(text):
    """→ [(path, identifier), ...]"""
    out = []
    path = None
    ident = None
    for line in text.splitlines():
        m = re.match(r"^\s*path:\s+(.*?)\s*(?:\(0x[0-9a-fA-F]+\))?$", line)
        if m:
            path = m.group(1).strip()
            continue
        m = re.match(r"^\s*identifier:\s+(\S+)\s*$", line)
        if m:
            ident = m.group(1)
            if path:
                out.append((path, ident))
            path = None
            ident = None
    return out


def main():
    bid = sys.argv[1]
    clean = "--clean" in sys.argv
    keep = os.environ.get("DESKBOARD_APP_PATH", os.path.expanduser("~/Applications/DeskBoard.app"))
    recs = records(dump())
    hits = [p for p, i in recs if i == bid]
    print("bundle id %s 的登记：%d 条" % (bid, len(hits)))
    for p in hits:
        print("   ", p)
    if clean:
        for p in hits:
            if p == keep:
                continue
            subprocess.run([LSREG, "-u", p], capture_output=True)
        if keep in hits:
            # 最后再把「要留的那份」登记一遍：系统认定的身份以最后一次登记为准
            subprocess.run([LSREG, "-f", keep], capture_output=True)
        after = [p for p, i in records(dump()) if i == bid]
        print("清理后：%d 条" % len(after))
        for p in after:
            print("   ", p)


if __name__ == "__main__":
    main()
