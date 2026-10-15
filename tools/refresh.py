#!/usr/bin/env python3
"""刷新 DeskBoard 的油价数据：从东方财富数据中心取上海 92 号汽油最新价，
按"10 个工作日一调"推算下次调价窗口，写回仓库样例与 App 实际读取的 mock.json。

用法：
    ./tools/refresh.py                 # 拉接口 + 写两处
    ./tools/refresh.py --next 2026-10-20   # 发改委公布的具体日期，手动覆盖推算值

注意：下次窗口只扣了周末与 HOLIDAYS 里列出的法定假日，**调休上班日没有建模**
（该接口不提供），所以推算值可能差一两天；官方公布后用 --next 覆盖即可。
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta

API = "https://datacenter-web.eastmoney.com/api/data/v1/get"
TOKEN = "894050c76af8597a853f5b408b759f5d"
CITY = "上海"
GRADE = "92号汽油"
PRICE_KEY = "V92"
WINDOW_WORKDAYS = 10

# 只影响推算，按需补
HOLIDAYS = {date(2026, 10, d) for d in range(1, 8)}


def fetch_rows(city):
    params = {
        "reportName": "RPTA_WEB_YJ_JH",
        "columns": "ALL",
        "sortColumns": "dim_date",
        "sortTypes": "-1",
        "filter": f'(CITYNAME="{city}")',
        "token": TOKEN,
        "pageNumber": "1",
        "pageSize": "10",
        "source": "WEB",
    }
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "DeskBoard/0.1"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if not payload.get("success"):
        raise SystemExit(f"接口返回失败：{payload.get('message')}")
    return payload["result"]["data"]


def next_window(last, holidays=HOLIDAYS):
    """从上次调价日起再走 10 个工作日。"""
    d, n = last, 0
    while n < WINDOW_WORKDAYS:
        d += timedelta(days=1)
        if d.weekday() < 5 and d not in holidays:
            n += 1
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--next", dest="next_date", help="手动指定下次调价窗口 YYYY-MM-DD")
    ap.add_argument("--dry-run", action="store_true", help="只打印不写文件")
    args = ap.parse_args()

    rows = fetch_rows(CITY)
    latest = rows[0]
    price = latest[PRICE_KEY]
    last = datetime.strptime(latest["DIM_DATE"][:10], "%Y-%m-%d").date()
    if price is None:
        raise SystemExit(f"接口里 {CITY} 的 {GRADE} 是空值")

    if args.next_date:
        nxt = datetime.strptime(args.next_date, "%Y-%m-%d").date()
        source = "手动指定"
    else:
        nxt = next_window(last)
        source = "按 10 个工作日推算（未计调休）"

    today = date.today()
    data = {
        "city": CITY,
        "grade": GRADE,
        "price": price,
        "unit": "元/升",
        "nextDate": f"{nxt.month}月{nxt.day}日",
        "nextTime": "24:00",
        "daysLeft": (nxt - today).days,
        "updatedAt": datetime.now().strftime("%H:%M"),
        "demo": False,
        "lastAdjust": last.isoformat(),
        "from": "datacenter-web.eastmoney.com RPTA_WEB_YJ_JH",
    }
    body = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    print(f"上海 92 号：{price} 元/升（上次调价 {last}，较调整前 {latest.get('QE92')} 涨 {latest.get('ZDE92')}）")
    print(f"下次窗口：{nxt}（{source}）距今天 {(nxt - today).days} 天")

    if args.dry_run:
        print(body)
        return

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    targets = [os.path.join(here, "mock", "mock.json"),
               os.path.expanduser("~/Library/Application Support/DeskBoard/mock.json")]
    for path in targets:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        print("→", path)


if __name__ == "__main__":
    main()
