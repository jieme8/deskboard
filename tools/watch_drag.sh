#!/bin/zsh
# 等一次真人拖动，然后当场给出链路结论。用法：tools/watch_drag.sh [最多等几分钟]
# 前提：组件此刻没被普通层窗口压住（脚本会先自检这一条）。
cd "$(dirname "$0")/.." || exit 1
L=~/Library/Logs/DeskBoard.log
mins=${1:-10}

if ./build/tools/probe_clickcatcher 监视器 2>&1 | grep -q "真吃点击"; then
    echo "✗ 组件现在被别的窗口整个压住，点不到。先把压着它的窗口挪开（脚本会告诉你是谁）："
    ./build/tools/probe_clickcatcher 监视器 2>&1 | grep "layer=0" | head -3
    exit 2
fi

base=$(grep -n "进程启动" "$L" | tail -1 | cut -d: -f1)
echo "就绪：盯着日志等一次真人拖动（最多 ${mins} 分钟）。直接在组件上按住拖一段再松手，别按菜单。"
for i in $(seq 1 $((mins * 20))); do
    win=$(tail -n +$((base + 1)) "$L" | grep -E "活动监视器 (按下|收到拖拽事件|拖动中|松手)")
    if echo "$win" | grep -q "活动监视器 按下"; then
        echo
        echo "—— 抓到的链路 ——"
        echo "$win" | tail -8
        echo
        if echo "$win" | grep -q "收到拖拽事件"; then
            last=$(echo "$win" | grep "松手" | tail -1)
            if [ -n "$last" ]; then
                disp=$(echo "$last" | grep -oE "位移\([^)]*\)" | head -1)
                echo "✓ 完整链路：按下 → 拖拽事件 → 松手（$disp）"
                echo "  再看窗口是否停在松手处（不回弹就是修好了）："
                ./build/tools/dump_window 2>&1 | grep "活动监视器 bounds"
            else
                echo "… 按下和拖拽事件都有，但还没等到松手 —— 再按一下让它结束，或看日志最后几行。"
            fi
        else
            echo "✗ 只有按下、没有拖拽事件：鼠标按住了但移动事件没送给视图（投递问题，不是算术问题）。"
        fi
        exit 0
    fi
    sleep 3
done
echo "超时：这 ${mins} 分钟内没等到按下。可能是组件又被窗口压住了，重跑本脚本看提示。"
exit 1
