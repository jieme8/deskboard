#!/usr/bin/env python3
# 拖完活动监视器后跑这个，它自己给结论，不用回来等我读日志。
# 判据来自 monitor_view.m 里那四条日志：按下 → 收到拖拽事件 → 拖动中 → 松手 位移，
# 外加一条「AppKit 会话就地搬完」（走 AppKit 拖拽会话那条路时才有）。
import re
import subprocess
import sys

LOG = sys.argv[1] if len(sys.argv) > 1 else \
    '/Users/%s/Library/Logs/DeskBoard.log' % subprocess.getoutput('id -un')

PATTERNS = [
    ('按下', re.compile(r'活动监视器 按下：')),
    ('拖拽到达', re.compile(r'活动监视器 收到拖拽事件')),
    ('逐帧挪窗', re.compile(r'活动监视器 拖动中 光标')),
    ('AppKit搬完', re.compile(r'活动监视器 AppKit 会话就地搬完')),
    ('松手', re.compile(r'活动监视器 松手 位移')),
]


def coverage():
    """当场量一次"谁压着它"。0 按下的两种可能（被窗口压住 / 投递层坏了）在这里分开：
    被压住是设计使然 —— 组件按硬约束永远在应用窗口之下，压着就点不到，不是 bug。"""
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    tool = next((c for c in (os.path.join(here, '..', 'build', 'tools', 'probe_clickcatcher'),
                             os.path.join(here, 'probe_clickcatcher'))
                 if os.path.exists(c)), None)
    if not tool:
        return None
    r = subprocess.run([tool, '监视器'], capture_output=True, text=True)
    return r.stdout


def main():
    try:
        lines = open(LOG, encoding='utf-8', errors='replace').read().split('\n')
    except OSError:
        print('读不到日志：%s' % LOG)
        return 2

    cov = coverage()
    if cov:
        eaters = []
        for l in cov.split('\n'):
            m = re.search(r'layer=(-?\d+)\s+覆盖(\d+)%\s+(.*)$', l)
            if not m:
                continue
            layer, cover, who = int(m.group(1)), int(m.group(2)), m.group(3).strip()
            # 只认"普通层的应用窗口"才吃点击：layer 0~10。
            # Dock(20)/菜单栏(24) 这类系统 UI 和 layer≈INT32 的投屏覆盖层都不吃点击 ——
            # 后者要是吃点击，整个桌面都点不动了（这个坑 probe_occlusion 第一版踩过）。
            if 0 <= layer <= 10 and cover >= 99:
                eaters.append('%s（layer=%d）' % (who, layer))
        print('当场覆盖：%s' % ('**被这些窗口整个压住 → 点它必然点不到，不是 bug**：' + '；'.join(eaters)
                                if eaters else '没有普通层窗口整个压着它 → 点得到，拖不动就要看下面的链路'))

    start = max((i for i, l in enumerate(lines) if '进程启动' in l), default=0)
    blk = lines[start:]
    hits = {k: [l for l in blk if r.search(l)] for k, r in PATTERNS}

    print('日志：%s（只看最近一次启动之后的 %d 行）' % (LOG, len(blk)))
    for k, _ in PATTERNS:
        n = len(hits[k])
        print('  %-12s %d 条' % (k, n))
        if n:
            print('    最后一条：%s' % hits[k][-1].strip()[:120])

    print()
    if not hits['按下']:
        print('结论：这次启动后**没有一次按下送到活动监视器视图**。')
        print('      → 事件根本没进来。先试菜单「活动监视器 › 摆到 / 微调 20pt」，')
        print('        那两条不依赖鼠标；再把组件挪个角落重拖一次看看是不是区域问题。')
        return 1
    if not (hits['拖拽到达'] or hits['AppKit搬完'] or hits['逐帧挪窗']):
        print('结论：按下到了，但**拖拽事件一条都没送到**（AppKit 会话也没搬窗）。')
        print('      → 断在 mouseDown 与 mouseDragged 之间，这是投递层的问题，不是算错了。')
        return 1
    if not hits['松手'] and not hits['AppKit搬完']:
        print('结论：拖拽进来了、也在挪窗，但**没有松手记录**。')
        print('      → 拖拽中途被打断（例如窗口被重建）。请把这段截图给我看。')
        return 1

    last = hits['松手'][-1] if hits['松手'] else hits['AppKit搬完'][-1]
    m = re.search(r'位移\(([+-]\d+),([+-]\d+)\)', last)
    if m and abs(int(m.group(1))) + abs(int(m.group(2))) < 3:
        print('结论：整条链路都通了，但**总位移只有 %s,%s**，接近没动。' % (m.group(1), m.group(2)))
        print('      → 说明拖拽被别处按存档重申回去了，把日志最后 30 行发我。')
        return 1
    print('结论：链路完整（按下 → 拖拽 → 挪窗 → 收尾落档）。拖得动。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
