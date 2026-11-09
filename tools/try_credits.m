// MiniMax 签到命令行：授权、查状态、查余额、领取、离线自检。
// 凭据只存在本机；这里从不打印 token。
// 用法：
//   try_credits path
//   try_credits authorize
//   try_credits status
//   try_credits balance
//   try_credits claim --yes
//   try_credits json
//   try_credits logout --yes
//   try_credits selftest
#import <Foundation/Foundation.h>
#import "credits.h"
#import "trae_credits.h"
#import "qoder_credits.h"
#import "workbuddy_credits.h"

static NSString *CreditsDir(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"DeskBoard/Credits"];
}

static void PrintWeek(DeskCreditsSnapshot *s) {
    if (s.days.count == 0) {
        printf("周条：（没有签到表）\n");
        return;
    }
    printf("周条：");
    for (DeskCreditsDay *d in s.days) {
        printf("%ld:%s%s%s ", (long)d.dayNo,
               d.claimed ? "已签" : "未签",
               d.isToday ? "·今天" : "",
               d.bonusPoints > 0 ? "·含奖励" : "");
    }
    printf("\n");
}

static void PrintSnapshot(DeskCreditsSnapshot *s) {
    printf("授权：%s\n", s.authorized ? "已授权" : "未授权");
    if (s.needsAuth) printf("凭据：已失效，需要重新授权\n");
    printf("状态：%s\n", DeskCreditsStatusText(s).UTF8String);
    if (s.authorized) {
        printf("余额：%s 积分", DeskCreditsFormatPoints(s.balance).UTF8String);
        if (s.freeBalance >= 0 || s.purchasedBalance >= 0) {
            printf("（免费 %s · 购买 %s）",
                   DeskCreditsFormatPoints(s.freeBalance).UTF8String,
                   DeskCreditsFormatPoints(s.purchasedBalance).UTF8String);
        }
        printf("\n");
    }
    if (s.hasToday) {
        printf("今天：第 %ld 天，%s %s\n", (long)s.todayDayNo,
               s.todayChecked ? "已签" : "待签",
               DeskCreditsFormatSignedPoints(s.todayPoints).UTF8String);
    } else {
        printf("今天：—\n");
    }
    printf("本轮：%s\n", DeskCreditsCycleText(s).UTF8String);
    printf("下一格：%s\n", DeskCreditsNextText(s).UTF8String);
    printf("同步：%s\n", DeskCreditsSyncText(s.lastSyncAt,
                                            [NSDate date].timeIntervalSince1970).UTF8String);
    if (s.lastError.length) printf("错误：%s\n", s.lastError.UTF8String);
    PrintWeek(s);
}

static void PrintClaim(DeskCreditsClaimResult *r, NSError *err) {
    const char *outcome = "失败";
    switch (r.outcome) {
        case DeskCreditsClaimOutcomeClaimed: outcome = "签到成功"; break;
        case DeskCreditsClaimOutcomeAlready: outcome = "今日已签"; break;
        case DeskCreditsClaimOutcomeNotAuthorized: outcome = "未授权"; break;
        case DeskCreditsClaimOutcomeFailed: outcome = "领取失败"; break;
        default: break;
    }
    printf("领取：%s %s（第 %ld 天）%s\n", outcome,
           DeskCreditsFormatSignedPoints(r.points).UTF8String,
           (long)r.dayNo, r.message.length ? r.message.UTF8String : "");
    if (err) printf("错误：%s\n", err.localizedDescription.UTF8String);
}

static int RunSelftest(void) {
    int fail = 0;
#define CHECK(cond, ...) do { \
    BOOL _ok = (cond); \
    printf("%s ", _ok ? "✓" : "✗"); \
    printf(__VA_ARGS__); \
    printf("\n"); \
    if (!_ok) fail++; \
} while (0)
    CHECK([DeskCreditsFormatPoints(14816.862) isEqualToString:@"14,817"], "余额格式化");
    CHECK([DeskCreditsFormatPoints(-1) isEqualToString:@"—"], "未知余额不印假 0");
    CHECK([DeskCreditsFormatSignedPoints(400) isEqualToString:@"+400"], "奖励带符号");
    CHECK([DeskCreditsDayKey(1793030400) isEqualToString:@"2026-10-27"], "UTC+8 日界");
    CHECK(DeskCreditsAutoClaimWindowOpen(1793066700), "10:05 自动签到窗口");
    CHECK([DeskCreditsPKCEChallenge(@"abc")
           isEqualToString:@"ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"], "PKCE S256 向量");

    NSString *mock = @"mock/credits_status.json";
    NSData *data = [NSData dataWithContentsOfFile:mock];
    if (data) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        DeskCreditsSnapshot *base = [DeskCreditsSnapshot new];
        base.authorized = YES;
        DeskCreditsSnapshot *s = DeskCreditsSnapshotByApplyingStatus(base, json, NULL);
        CHECK(s != nil && s.todayDayNo == 4 && s.todayChecked
              && fabs(s.todayPoints - 1000) < 0.001
              && fabs([s nextReward] - 400) < 0.001,
              "fixture 解析：第 4 天已签、明日 +400");
    } else {
        printf("· 跳过 fixture 解析（当前目录没有 mock/credits_status.json）\n");
    }
#undef CHECK
    printf("\n%s（%d 项失败）\n", fail == 0 ? "自检通过" : "自检有失败项", fail);
    return fail == 0 ? 0 : 1;
}

static int RunAuthorize(DeskCreditsProvider *p) {
    printf("正在申请 MiniMax 设备码授权…\n");
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    __block NSError *authErr = nil;
    [p beginAuthorizationWithURLHandler:^(NSString *url) {
        printf("\n请在浏览器完成 MiniMax 登录授权：\n%s\n\n", url.UTF8String);
        NSTask *task = [NSTask new];
        task.launchPath = @"/usr/bin/open";
        task.arguments = @[url];
        @try { [task launch]; }
        @catch (NSException *e) { (void)e; }
        printf("已尝试自动打开浏览器；没弹出来就手动复制上面的地址。\n");
        printf("等待授权中（最多 300 秒）…\n");
    } completion:^(BOOL success, NSError *error) {
        ok = success;
        authErr = error;
        dispatch_semaphore_signal(sem);
    }];
    long timedOut = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(310 * NSEC_PER_SEC)));
    if (timedOut != 0) {
        fprintf(stderr, "等待授权超时。\n");
        [p cancelAuthorization];
        return 1;
    }
    if (!ok) {
        fprintf(stderr, "授权失败：%s\n",
                authErr.localizedDescription.UTF8String ?: "未知原因");
        return 1;
    }
    printf("授权成功。凭据只存在本机：%s/auth.json（0600）\n", p.directory.UTF8String);
    printf("下一步：%s status\n", "try_credits");
    return 0;
}

static void PrintTrae(DeskTraeSnapshot *t) {
    printf("登录态：%s", t.connected ? "已连接" : "未找到");
    if (t.connected) {
        printf("（%s · uid %s）",
               t.nickname.length ? t.nickname.UTF8String : "—",
               t.uid.length ? t.uid.UTF8String : "—");
    }
    printf("\n");
    if (t.planTier.length) printf("套餐：%s\n", t.planTier.UTF8String);
    if (t.tokenExpiresAt > 0) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm";
        printf("令牌：到期 %s（剩 %.0f 天）\n",
               [[df stringFromDate:[NSDate dateWithTimeIntervalSince1970:t.tokenExpiresAt]] UTF8String],
               MAX(0.0, t.loginDays));
    }
    if (t.hasStatus) {
        printf("状态：%s · 今日%s%s\n", t.enabled ? "活动开启" : "活动未开启",
               t.checkedIn ? "已签" : "待签",
               t.todayCredits >= 0
                   ? [[NSString stringWithFormat:@" +%.0f", t.todayCredits] UTF8String] : "");
        if (t.extraCredits > 0) printf("额外：+%.0f\n", t.extraCredits);
    } else {
        printf("状态：未同步\n");
    }
    if (t.balance >= 0) {
        printf("余额：%s", DeskCreditsFormatPoints(t.balance).UTF8String);
        if (t.total >= 0) printf("（总计 %s", DeskCreditsFormatPoints(t.total).UTF8String);
        if (t.consumed >= 0) printf(" · 已用 %s", DeskCreditsFormatPoints(t.consumed).UTF8String);
        if (t.total >= 0) printf("）");
        printf("\n");
    }
    if (t.deviceId.length) printf("设备号：%lu 位（不打印原值）\n", (unsigned long)t.deviceId.length);
    printf("同步：%s\n",
           DeskCreditsSyncText(t.lastSyncAt, [NSDate date].timeIntervalSince1970).UTF8String);
    if (t.lastError.length) printf("错误：%s\n", t.lastError.UTF8String);
}

static int RunTrae(int argc, const char *argv[]) {
    NSString *sub = argc > 2 ? @(argv[2]) : @"status";
    NSString *dir = CreditsDir();
    DeskTraeCredits *p = [[DeskTraeCredits alloc]
        initWithStoragePath:nil
                  statePath:[dir stringByAppendingPathComponent:@"trae_state.json"]];
    p.onLog = ^(NSString *m) { printf("[trae] %s\n", m.UTF8String); };
    [p load];

    if ([sub isEqualToString:@"path"]) {
        printf("storage.json：%s\n", p.storagePath.length ? p.storagePath.UTF8String : "（没找到）");
        printf("快照：%s/trae_state.json\n", dir.UTF8String);
        PrintTrae(p.snapshot);
        return 0;
    }
    if ([sub isEqualToString:@"json"]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:[p.snapshot dictionaryRepresentation]
                                                    options:NSJSONWritingPrettyPrinted error:NULL];
        if (d) {
            printf("%s\n", [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] UTF8String]);
        }
        return 0;
    }
    if ([sub isEqualToString:@"reload"]) {
        PrintTrae(p.snapshot);
        return p.snapshot.connected ? 0 : 1;
    }
    if ([sub isEqualToString:@"status"] || [sub isEqualToString:@"balance"]) {
        BOOL withBalance = [sub isEqualToString:@"balance"];
        NSError *err = nil;
        BOOL ok = [p refreshSyncWithBalance:withBalance error:&err];
        if (!ok) fprintf(stderr, "刷新失败：%s\n\n", err.localizedDescription.UTF8String ?: "未知原因");
        PrintTrae(p.snapshot);
        return ok ? 0 : 1;
    }
    if ([sub isEqualToString:@"claim"]) {
        BOOL confirmed = NO;
        for (int i = 3; i < argc; i++) if (strcmp(argv[i], "--yes") == 0) confirmed = YES;
        if (!confirmed) {
            fprintf(stderr, "trae claim 会真实领取今天的积分（写操作），确认后加 --yes\n");
            return 2;
        }
        [p refreshSyncWithBalance:YES error:NULL];
        if (p.snapshot.checkedIn) {
            printf("今日已签，无需重复领取。\n");
            PrintTrae(p.snapshot);
            return 0;
        }
        NSError *err = nil;
        DeskCreditsClaimResult *r = [p claimSync:&err];
        PrintClaim(r, err);
        printf("\n");
        PrintTrae(p.snapshot);
        return (r.outcome == DeskCreditsClaimOutcomeClaimed
                || r.outcome == DeskCreditsClaimOutcomeAlready) ? 0 : 1;
    }
    fprintf(stderr, "未知 Trae 子命令：%s\n", sub.UTF8String);
    return 2;
}


static void PrintQoder(DeskQoderSnapshot *q) {
    if (!q.hasToken) printf("PT：未设置\n");
    else printf("PT：%s\n", q.tokenInvalid ? "已失效，需要重新生成" : "已设置（不打印原值）");
    if (q.nickname.length || q.uid.length) {
        printf("账号：%s · uid %s\n",
               q.nickname.length ? q.nickname.UTF8String : "—",
               q.uid.length ? q.uid.UTF8String : "—");
    }
    if (q.planTier.length) printf("套餐：%s（%s）\n",
                                  DeskQoderPlanName(q.planTier).UTF8String,
                                  q.planTier.UTF8String);
    if (q.balance >= 0) {
        printf("余额：%s Credits", DeskCreditsFormatPoints(q.balance).UTF8String);
        if (q.quotaTotal >= 0) {
            printf("（已用 %s / 总计 %s）",
                   DeskCreditsFormatPoints(q.quotaUsed).UTF8String,
                   DeskCreditsFormatPoints(q.quotaTotal).UTF8String);
        }
        printf("\n");
    } else {
        printf("余额：—\n");
    }
    if (q.hasStatus) {
        printf("本窗口：%s", q.claimable ? "可领" : (q.claimed ? "已领" : "无活动"));
        if (q.todayAmount >= 0) printf(" +%s Credits", DeskCreditsFormatPoints(q.todayAmount).UTF8String);
        printf(" · 活动 %ld 项\n", (long)q.campaignCount);
        if (q.windowEnd > 0) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyy-MM-dd HH:mm";
            printf("窗口截止：%s\n",
                   [[df stringFromDate:[NSDate dateWithTimeIntervalSince1970:q.windowEnd]] UTF8String]);
        }
    } else {
        printf("本窗口：未同步\n");
    }
    printf("同步：%s\n",
           DeskCreditsSyncText(q.lastSyncAt, [NSDate date].timeIntervalSince1970).UTF8String);
    if (q.lastError.length) printf("错误：%s\n", q.lastError.UTF8String);
}

static int RunQoder(int argc, const char *argv[]) {
    NSString *sub = argc > 2 ? @(argv[2]) : @"status";
    NSString *dir = CreditsDir();
    DeskQoderCredits *p = [[DeskQoderCredits alloc] initWithDirectory:dir];
    p.onLog = ^(NSString *m) { printf("[qoder] %s\n", m.UTF8String); };
    [p load];

    if ([sub isEqualToString:@"path"]) {
        printf("凭据：%s/qoder.json（0600，PT 不落日志）\n", dir.UTF8String);
        PrintQoder(p.snapshot);
        return 0;
    }
    if ([sub isEqualToString:@"token"]) {
        if (argc < 4) {
            fprintf(stderr, "用法：try_credits qoder token <pt-…>\n");
            return 2;
        }
        NSError *err = nil;
        if (![p setPersonalToken:@(argv[3]) error:&err]) {
            fprintf(stderr, "设置失败：%s\n", err.localizedDescription.UTF8String ?: "未知原因");
            return 1;
        }
        printf("PT 已写入 %s/qoder.json（0600）\n", dir.UTF8String);
        return 0;
    }
    if ([sub isEqualToString:@"json"]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:[p.snapshot dictionaryRepresentation]
                                                    options:NSJSONWritingPrettyPrinted error:NULL];
        if (d) printf("%s\n", [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] UTF8String]);
        return 0;
    }
    if ([sub isEqualToString:@"status"] || [sub isEqualToString:@"balance"]) {
        NSError *err = nil;
        BOOL ok = [p refreshSyncWithBalance:YES error:&err];
        if (!ok) fprintf(stderr, "刷新失败：%s\n\n", err.localizedDescription.UTF8String ?: "未知原因");
        PrintQoder(p.snapshot);
        return ok ? 0 : 1;
    }
    if ([sub isEqualToString:@"claim"]) {
        BOOL confirmed = NO;
        for (int i = 3; i < argc; i++) if (strcmp(argv[i], "--yes") == 0) confirmed = YES;
        if (!confirmed) {
            fprintf(stderr, "qoder claim 会真实领取本窗口的 Credits（写操作），确认后加 --yes\n");
            return 2;
        }
        [p refreshSyncWithBalance:YES error:NULL];
        if (p.snapshot.claimed) {
            printf("本窗口已领，无需重复领取。\n");
            PrintQoder(p.snapshot);
            return 0;
        }
        NSError *err = nil;
        DeskCreditsClaimResult *r = [p claimSync:&err];
        PrintClaim(r, err);
        printf("\n");
        PrintQoder(p.snapshot);
        return (r.outcome == DeskCreditsClaimOutcomeClaimed
                || r.outcome == DeskCreditsClaimOutcomeAlready) ? 0 : 1;
    }
    fprintf(stderr, "未知 Qoder 子命令：%s\n", sub.UTF8String);
    return 2;
}


static void PrintWorkbuddy(DeskWorkbuddySnapshot *w) {
    printf("登录：%s", w.hasToken ? "已登录" : "未登录");
    if (w.hasToken) {
        printf("（%s · %s · uid %s）",
               w.nickname.length ? w.nickname.UTF8String : "—",
               w.host.UTF8String,
               w.uid.length ? w.uid.UTF8String : "—");
    }
    printf("\n");
    if (!w.hasToken) { if (w.lastError.length) printf("提示：%s\n", w.lastError.UTF8String); return; }
    if (w.tokenExpiresAt > 0) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm";
        printf("令牌：到期 %s\n",
               [[df stringFromDate:[NSDate dateWithTimeIntervalSince1970:w.tokenExpiresAt]] UTF8String]);
    }
    if (w.hasStatus) {
        printf("今日：%s", w.checkedIn ? "已签" : (w.activityEnabled ? "待签" : "无签到活动"));
        if (w.todayCredit >= 0) printf(" +%.0f", w.todayCredit);
        else if (w.dailyCredit >= 0) printf("（每日 +%.0f）", w.dailyCredit);
        printf(" · 连签 %.0f 天\n", w.streakDays);
    } else {
        printf("今日：未同步\n");
    }
    if (w.balance >= 0) {
        printf("积分：%s 可用", DeskCreditsFormatPoints(w.balance).UTF8String);
        if (w.quotaTotal >= 0) {
            printf("（已用 %s / 总计 %s）",
                   DeskCreditsFormatPoints(w.quotaUsed).UTF8String,
                   DeskCreditsFormatPoints(w.quotaTotal).UTF8String);
        }
        printf("\n");
    }
    printf("同步：%s\n",
           DeskCreditsSyncText(w.lastSyncAt, [NSDate date].timeIntervalSince1970).UTF8String);
    if (w.lastError.length) printf("错误：%s\n", w.lastError.UTF8String);
}

static int RunWorkbuddy(int argc, const char *argv[]) {
    NSString *sub = argc > 2 ? @(argv[2]) : @"status";
    DeskWorkbuddyCredits *p = [[DeskWorkbuddyCredits alloc] initWithDirectory:CreditsDir()];
    p.onLog = ^(NSString *m) { printf("[workbuddy] %s\n", m.UTF8String); };
    [p load];

    if ([sub isEqualToString:@"path"]) {
        printf("凭据：%s/workbuddy.json（0600，token 不落日志）\n", CreditsDir().UTF8String);
        PrintWorkbuddy(p.snapshot);
        return 0;
    }
    if ([sub isEqualToString:@"import"]) {
        NSError *err = nil;
        BOOL ok = [p importLocalSession:&err];
        if (!ok) fprintf(stderr, "导入失败：%s\n", err.localizedDescription.UTF8String ?: "未知原因");
        PrintWorkbuddy(p.snapshot);
        return ok ? 0 : 1;
    }
    if ([sub isEqualToString:@"json"]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:[p.snapshot dictionaryRepresentation]
                                                    options:NSJSONWritingPrettyPrinted error:NULL];
        if (d) printf("%s\n", [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] UTF8String]);
        return 0;
    }
    if ([sub isEqualToString:@"login"]) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        __block NSError *loginErr = nil;
        [p beginAuthorizationWithURLHandler:^(NSString *url) {
            printf("请在浏览器完成 WorkBuddy 登录：\n%s\n", url.UTF8String);
            NSTask *task = [NSTask new];
            task.launchPath = @"/usr/bin/open";
            NSString *browser = NSProcessInfo.processInfo.environment[@"TRY_CREDITS_BROWSER"];
            task.arguments = browser.length ? @[@"-a", browser, url] : @[url];
            @try { [task launch]; } @catch (NSException *e) { (void)e; }
            printf("已尝试打开浏览器；等待授权（最多 10 分钟）…\n");
        } completion:^(BOOL success, NSError *err) {
            ok = success;
            loginErr = err;
            dispatch_semaphore_signal(sem);
        }];
        long timedOut = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(620 * NSEC_PER_SEC)));
        if (timedOut != 0) {
            fprintf(stderr, "等待登录超时\n");
            [p cancelAuthorization];
            return 1;
        }
        if (!ok) {
            fprintf(stderr, "登录失败：%s\n", loginErr.localizedDescription.UTF8String ?: "未知原因");
            return 1;
        }
        printf("登录成功。\n\n");
        [p refreshSyncWithBalance:YES error:NULL];
        PrintWorkbuddy(p.snapshot);
        return 0;
    }
    if ([sub isEqualToString:@"status"] || [sub isEqualToString:@"balance"]) {
        NSError *err = nil;
        BOOL ok = [p refreshSyncWithBalance:YES error:&err];
        if (!ok) fprintf(stderr, "刷新失败：%s\n\n", err.localizedDescription.UTF8String ?: "未知原因");
        PrintWorkbuddy(p.snapshot);
        return ok ? 0 : 1;
    }
    if ([sub isEqualToString:@"claim"]) {
        BOOL confirmed = NO;
        for (int i = 3; i < argc; i++) if (strcmp(argv[i], "--yes") == 0) confirmed = YES;
        if (!confirmed) {
            fprintf(stderr, "workbuddy claim 会真实签到（写操作），确认后加 --yes\n");
            return 2;
        }
        [p refreshSyncWithBalance:YES error:NULL];
        if (p.snapshot.checkedIn) {
            printf("今日已签，无需重复领取。\n");
            PrintWorkbuddy(p.snapshot);
            return 0;
        }
        NSError *err = nil;
        DeskCreditsClaimResult *r = [p claimSync:&err];
        PrintClaim(r, err);
        printf("\n");
        PrintWorkbuddy(p.snapshot);
        return (r.outcome == DeskCreditsClaimOutcomeClaimed
                || r.outcome == DeskCreditsClaimOutcomeAlready) ? 0 : 1;
    }
    fprintf(stderr, "未知 WorkBuddy 子命令：%s\n", sub.UTF8String);
    return 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        NSString *command = argc > 1 ? @(argv[1]) : @"help";
        if ([command isEqualToString:@"help"] || [command isEqualToString:@"--help"]
            || [command isEqualToString:@"-h"]) {
            printf("用法：try_credits <path|authorize|status|balance|claim --yes|json|logout --yes|selftest>\n");
            printf("      try_credits trae <path|status|balance|claim --yes|json|reload>\n");
            printf("      try_credits qoder <path|status|claim --yes|json|token <pt>>\n");
            printf("      try_credits workbuddy <path|status|claim --yes|json|import|login>\n");
            return 0;
        }
        if ([command isEqualToString:@"selftest"]) return RunSelftest();
        if ([command isEqualToString:@"trae"]) return RunTrae(argc, argv);
        if ([command isEqualToString:@"qoder"]) return RunQoder(argc, argv);
        if ([command isEqualToString:@"workbuddy"]) return RunWorkbuddy(argc, argv);

        DeskCreditsProvider *p = [[DeskCreditsProvider alloc] initWithDirectory:CreditsDir()];
        p.onLog = ^(NSString *m) { printf("[credits] %s\n", m.UTF8String); };
        [p load];

        if ([command isEqualToString:@"path"]) {
            printf("目录：%s\n", p.directory.UTF8String);
            printf("凭据：%s/auth.json（0600，绝不外传）\n", p.directory.UTF8String);
            printf("快照：%s/state.json\n", p.directory.UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"authorize"]) return RunAuthorize(p);
        if ([command isEqualToString:@"json"]) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:[p.snapshot dictionaryRepresentation]
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:NULL];
            if (data) {
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                printf("%s\n", text.UTF8String);
            }
            return 0;
        }
        if ([command isEqualToString:@"logout"]) {
            BOOL confirmed = NO;
            for (int i = 2; i < argc; i++) if (strcmp(argv[i], "--yes") == 0) confirmed = YES;
            if (!confirmed) {
                fprintf(stderr, "logout 会删掉本机凭据，确认后加 --yes\n");
                return 2;
            }
            NSString *auth = [p.directory stringByAppendingPathComponent:@"auth.json"];
            NSString *state = [p.directory stringByAppendingPathComponent:@"state.json"];
            [[NSFileManager defaultManager] removeItemAtPath:auth error:NULL];
            [[NSFileManager defaultManager] removeItemAtPath:state error:NULL];
            printf("已删除本机凭据与快照。下次需要重新授权。\n");
            return 0;
        }
        if ([command isEqualToString:@"claim"]) {
            BOOL confirmed = NO;
            for (int i = 2; i < argc; i++) if (strcmp(argv[i], "--yes") == 0) confirmed = YES;
            if (!confirmed) {
                fprintf(stderr, "claim 会真实领取今天的积分（写操作），确认后加 --yes\n");
                return 2;
            }
            NSError *err = nil;
            DeskCreditsClaimResult *r = [p claimSync:&err];
            PrintClaim(r, err);
            printf("\n");
            PrintSnapshot(p.snapshot);
            return (r.outcome == DeskCreditsClaimOutcomeClaimed
                    || r.outcome == DeskCreditsClaimOutcomeAlready) ? 0 : 1;
        }
        if ([command isEqualToString:@"status"] || [command isEqualToString:@"balance"]) {
            BOOL withBalance = [command isEqualToString:@"balance"];
            NSError *err = nil;
            BOOL ok = [p refreshSyncWithBalance:withBalance error:&err];
            if (!ok) {
                fprintf(stderr, "刷新失败：%s\n\n",
                        err.localizedDescription.UTF8String ?: "未知原因");
            }
            PrintSnapshot(p.snapshot);
            return ok ? 0 : 1;
        }
        fprintf(stderr, "未知命令：%s（用 --help 看用法）\n", command.UTF8String);
        return 2;
    }
}
