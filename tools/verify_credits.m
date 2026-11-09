// 签到中心的纯函数 / 解析 / 四槽布局 / 授权提示断言。不联网、不碰真实凭据。
// 用法：verify_credits <项目根目录>
#import <AppKit/AppKit.h>
#import <math.h>
#import "credits.h"
#import "credits_record.h"
#import "credits_view.h"
#import "trae_credits.h"
#import "qoder_credits.h"
#import "workbuddy_credits.h"

static NSString *ShortDay(NSString *key) {
    NSArray<NSString *> *parts = [key componentsSeparatedByString:@"-"];
    if (parts.count != 3) return key ?: @"—";
    return [NSString stringWithFormat:@"%ld/%ld",
            (long)[parts[1] integerValue], (long)[parts[2] integerValue]];
}

@interface DeskCreditsProvider (VerifyCredits)
- (BOOL)writeAuthFileForVerify:(NSDictionary *)auth;
@end

static int gFailures = 0;

static void Say(BOOL ok, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void Say(BOOL ok, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s %s\n", ok ? "✓" : "✗", msg.UTF8String);
    if (!ok) gFailures++;
}

static NSDictionary *LoadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *root = argc > 1 ? @(argv[1]) : @".";
        NSString *mock = [root stringByAppendingPathComponent:@"mock"];
        NSDictionary *statusJSON = LoadJSON([mock stringByAppendingPathComponent:@"credits_status.json"]);
        NSDictionary *balanceJSON = LoadJSON([mock stringByAppendingPathComponent:@"credits_balance.json"]);
        NSDictionary *claimJSON = LoadJSON([mock stringByAppendingPathComponent:@"credits_claim.json"]);
        NSDictionary *alreadyJSON = LoadJSON([mock stringByAppendingPathComponent:@"credits_claim_already.json"]);
        if (!statusJSON || !balanceJSON || !claimJSON || !alreadyJSON) {
            fprintf(stderr, "读不到 mock/credits_*.json（根目录 %s）\n", root.UTF8String);
            return 2;
        }
        NSApplicationLoad();

        // —— 状态解析：今天第 4 天已签，明日 +400 ——
        DeskCreditsSnapshot *base = [DeskCreditsSnapshot new];
        base.authorized = YES;
        NSError *err = nil;
        DeskCreditsSnapshot *s = DeskCreditsSnapshotByApplyingStatus(base, statusJSON, &err);
        Say(s != nil, @"签到状态能解析（%@）", err.localizedDescription ?: @"ok");
        Say(s.days.count == 7, @"一周 7 天（实际 %lu）", (unsigned long)s.days.count);
        Say(s.hasToday && s.todayDayNo == 4, @"is_today 指向第 4 天（实际 %ld）", (long)s.todayDayNo);
        Say(s.todayChecked, @"今天状态=已领");
        Say(fabs(s.todayPoints - 1000.0) < 0.001, @"今天实得 1,000（实际 %.1f）", s.todayPoints);
        Say(fabs([s nextReward] - 400.0) < 0.001, @"下一格 +400（实际 %.1f）", [s nextReward]);
        Say([s cycleLength] == 7, @"本轮长度 7");
        Say(s.phase == DeskCreditsPhaseCheckedIn, @"阶段=已签");
        Say(fabs(s.days[1].bonusPoints - 1024.0) < 0.001, @"第 2 天的奖励分 1,024 没丢");

        NSError *be = nil;
        BOOL balanceOK = DeskCreditsApplyMembership(s, balanceJSON, &be);
        Say(balanceOK, @"余额能解析（%@）", be.localizedDescription ?: @"ok");
        Say(fabs(s.balance - 14816.862) < 0.001, @"余额 14,816.862（实际 %.3f）", s.balance);
        Say([s.planTier isEqualToString:@"Explore"], @"套餐档位 Explore（实际 %@）", s.planTier);

        // —— 数字 / 文案口径 ——
        Say([DeskCreditsFormatPoints(-1) isEqualToString:@"—"], @"未知余额印 —，不印假 0");
        Say([DeskCreditsFormatPoints(1500) isEqualToString:@"1,500"], @"千分位分组");
        Say([DeskCreditsFormatSignedPoints(1000) isEqualToString:@"+1,000"], @"带符号 +1,000");
        Say([DeskCreditsStatusText(s) isEqualToString:@"已签 +1,000"], @"状态文案：已签 +1,000");
        Say([DeskCreditsCycleText(s) isEqualToString:@"本轮 4/7"], @"轮次文案：本轮 4/7");
        Say([DeskCreditsNextText(s) isEqualToString:@"明日 +400 · 00:00"], @"明日文案：明日 +400 · 00:00");

        // —— UTC+8 日界 / 10:05 统一自动签到窗口 ——
        Say([DeskCreditsDayKey(1793030399) isEqualToString:@"2026-10-26"],
            @"UTC 15:59:59 = 北京 23:59:59，仍是 10-26");
        Say([DeskCreditsDayKey(1793030400) isEqualToString:@"2026-10-27"],
            @"UTC 16:00:00 = 北京 00:00，翻到 10-27");
        Say(!DeskCreditsAutoClaimWindowOpen(1793066699), @"北京 10:04:59 还不自动领");
        Say(DeskCreditsAutoClaimWindowOpen(1793066700), @"北京 10:05:00 才自动领");
        Say(!DeskCreditsAutoClaimWindowOpen(1793030700), @"旧的 00:05 不再自动领");
        Say(DeskCreditsHourOfDay(1793066700) == 10, @"北京 10:05 的小时数是 10");
        Say(DeskCreditsHourlyCheckDue(1793066700, -1), @"10:05 到点做补签检查");
        Say(!DeskCreditsHourlyCheckDue(1793066760, 10), @"10:06 同一小时不重复检查");
        Say(!DeskCreditsHourlyCheckDue(1793070240, 10), @"11:04 还不到 :05");
        Say(DeskCreditsHourlyCheckDue(1793070300, 10), @"11:05 下一小时再检查");

        // —— PKCE S256 已知向量 ——
        Say([DeskCreditsPKCEChallenge(@"abc") isEqualToString:@"ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"],
            @"PKCE S256 已知向量");
        NSString *verifier = DeskCreditsPKCEVerifier();
        Say(verifier.length >= 43 && verifier.length <= 128, @"PKCE verifier 长度合法");

        // —— 领取返回 ——
        DeskCreditsClaimResult *cr = DeskCreditsClaimResultFromResponse(claimJSON, NULL);
        Say(cr.outcome == DeskCreditsClaimOutcomeClaimed && fabs(cr.points - 400) < 0.001
            && cr.dayNo == 5, @"claim_result=1 → 签到成功 +400（第 5 天）");
        DeskCreditsClaimResult *ar = DeskCreditsClaimResultFromResponse(alreadyJSON, NULL);
        Say(ar.outcome == DeskCreditsClaimOutcomeAlready, @"claim_result=2 → 今日已领");
        NSDictionary *bad = @{@"base_resp": @{@"status_code": @1, @"status_msg": @"bad"}};
        NSError *badErr = nil;
        DeskCreditsClaimResult *br = DeskCreditsClaimResultFromResponse(bad, &badErr);
        Say(br.outcome == DeskCreditsClaimOutcomeFailed && badErr != nil,
            @"base_resp 非 0 → 领取失败且带错误");

        // —— 快照落盘再读回 ——
        DeskCreditsSnapshot *restored = [DeskCreditsSnapshot snapshotWithDictionary:[s dictionaryRepresentation]];
        Say(restored.days.count == 7 && restored.todayDayNo == 4
            && restored.todayChecked && fabs(restored.balance - 14816.862) < 0.001,
            @"快照落盘再读回：4/7 已签、余额不丢");

        // —— 当前中心：MiniMax 已签 + 三个真实接入方式占位 ——
        DeskCreditsCenterSnapshot *current = [DeskCreditsCenterSnapshot centerWithMiniMax:s];
        Say(current.slots.count == 4, @"中心 4 个槽（实际 %lu）", (unsigned long)current.slots.count);
        Say(current.connectedCount == 1 && current.doneCount == 1
            && current.pendingCount == 0 && current.errorCount == 0,
            @"当前 1 已接入 / 1 已办 / 0 待办 / 0 异常");
        Say(current.oldestSyncAt > 0, @"最旧同步时间有值");
        DeskCreditsSlot *mm = [current slotForPlatform:DeskCreditsPlatformMiniMax];
        Say(mm.kind == DeskCreditsSlotKindSigned && mm.visual == DeskCreditsVisualCycle,
            @"MiniMax 槽：已签 + 轮次点");
        Say(fabs(mm.balance - 14816.862) < 0.001 && [mm.unit isEqualToString:@"积分"],
            @"MiniMax 余额 14,816.862 积分");
        Say([mm.planLine containsString:@"EXPLORE"] && [mm.planLine containsString:@"独立 OAuth"],
            @"MiniMax 副行写独立 OAuth（%@）", mm.planLine);
        Say([mm.statusText isEqualToString:@"已签 +1,000"], @"MiniMax 状态：已签 +1,000");
        Say([mm.footerText isEqualToString:@"本轮 4/7 · 明日 +400"],
            @"MiniMax 底部：本轮 4/7 · 明日 +400（实际 %@）", mm.footerText);
        Say(mm.cycleStates.count == 7 && mm.cycleStates[0].integerValue == 1
            && mm.cycleStates[1].integerValue == 1 && mm.cycleStates[2].integerValue == 1
            && mm.cycleStates[3].integerValue == 2,
            @"MiniMax 轮次点：1–3 已签，第 4 天是今天");
        Say(mm.cycleStates[4].integerValue == 0 && mm.cycleStates[6].integerValue == 0,
            @"MiniMax 轮次点：5–7 未签");
        Say(mm.cycleBonuses[1].boolValue, @"MiniMax 第 2 天奖励点还在");

        DeskCreditsSlot *trae = [current slotForPlatform:DeskCreditsPlatformTrae];
        Say(trae.kind == DeskCreditsSlotKindUnconnected && trae.visual == DeskCreditsVisualLoginLife,
            @"Trae 占位：未接入 + 登录态条");
        Say([trae.planLine containsString:@"storage.json"]
            && [trae.planLine containsString:@"不自动续期"],
            @"Trae 占位写明本机 storage.json + 不自动续期（%@）", trae.planLine);
        Say([trae.statusText isEqualToString:@"每日签到"]
            && [trae.footerText isEqualToString:@"待导入登录态"],
            @"Trae 占位：每日签到 / 待导入登录态");
        Say([trae.authActionTitle containsString:@"从本机导入"], @"Trae 菜单动作是从本机导入");

        // —— Trae 真接入：storage.json 解密 / 状态 / 余额 / 槽位 ——
        {
            NSDictionary *ts = LoadJSON([mock stringByAppendingPathComponent:@"trae_storage.json"]);
            NSDictionary *pending = LoadJSON([mock stringByAppendingPathComponent:@"trae_status_pending.json"]);
            NSDictionary *checked = LoadJSON([mock stringByAppendingPathComponent:@"trae_status_checked.json"]);
            NSDictionary *tbal = LoadJSON([mock stringByAppendingPathComponent:@"trae_balance.json"]);
            NSDictionary *tclaim = LoadJSON([mock stringByAppendingPathComponent:@"trae_claim.json"]);
            NSDictionary *tdev = LoadJSON([mock stringByAppendingPathComponent:@"trae_claim_device.json"]);
            Say(ts && pending && checked && tbal && tclaim && tdev, @"Trae mock 文件齐全");

            NSError *te = nil;
            NSDictionary *creds = DeskTraeStorageCredentials(ts, &te);
            Say(creds != nil, @"Trae storage.json 能解密（%@）", te.localizedDescription ?: @"ok");
            Say([creds[@"uid"] isEqualToString:@"424242"], @"Trae uid 解析（%@）", creds[@"uid"]);
            Say([creds[@"nickname"] isEqualToString:@"tester"], @"Trae 昵称解析（%@）", creds[@"nickname"]);
            Say([creds[@"deviceId"] isEqualToString:@"424242424242424"],
                @"Trae 设备号从 storage.json 键名解析（%@）", creds[@"deviceId"]);
            Say([creds[@"planTier"] isEqualToString:@"Free"], @"Trae 套餐从 iCubeServerData 解析");
            Say([creds[@"token"] length] > 20, @"Trae token 解出且非空");

            // 合成的坏密文必须红，不能把“解不开”当成空登录态混过去
            NSError *badErr = nil;
            NSData *bad = DeskTraeDecryptStorageValue(@"dGMFEAAAdeadbeef", &badErr);
            Say(bad == nil && badErr != nil, @"Trae 坏密文解不开且报错");

            NSString *statePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"trae-verify-%u.json", arc4random()]];
            NSString *storagePath = [mock stringByAppendingPathComponent:@"trae_storage.json"];
            DeskTraeCredits *prov = [[DeskTraeCredits alloc] initWithStoragePath:storagePath
                                                                       statePath:statePath];
            Say([prov load], @"Trae provider 读到登录态");
            Say(prov.snapshot.connected && prov.snapshot.tokenExpiresAt > 0,
                @"Trae 快照：已连接 + 令牌到期时间");

            NSError *ie = nil;
            Say([prov ingestStatusForVerify:pending error:&ie],
                @"Trae 待签状态能解析（%@）", ie.localizedDescription ?: @"ok");
            Say(!prov.snapshot.checkedIn && prov.snapshot.enabled
                && fabs(prov.snapshot.todayCredits - 100) < 0.001
                && fabs(prov.snapshot.extraCredits - 100) < 0.001,
                @"Trae 状态：待签 · +100 · 额外 +100");
            Say([prov ingestBalanceForVerify:tbal error:&ie], @"Trae 余额能解析");
            Say(fabs(prov.snapshot.balance - 3382.69) < 0.01,
                @"Trae 余额 = 总计 3400 - 已用 17.31（实际 %.2f）", prov.snapshot.balance);

            DeskCreditsCenterSnapshot *tc =
                [DeskCreditsCenterSnapshot centerWithMiniMax:s trae:prov.snapshot qoder:nil workbuddy:nil];
            Say(tc.connectedCount == 2, @"接上 Trae 后 2/4 已接入（实际 %ld）",
                (long)tc.connectedCount);
            DeskCreditsSlot *tslot = [tc slotForPlatform:DeskCreditsPlatformTrae];
            Say(tslot.connected && tslot.kind == DeskCreditsSlotKindPending,
                @"Trae 槽：已接入 · 待签");
            Say([tslot.statusText isEqualToString:@"待签 +100"],
                @"Trae 槽状态：待签 +100（实际 %@）", tslot.statusText);
            Say([tslot.planLine containsString:@"Free"]
                && [tslot.planLine containsString:@"本机登录态"],
                @"Trae 副行 Free · 本机登录态（%@）", tslot.planLine);
            Say([tslot.footerText containsString:@"登录态"], @"Trae 底部有登录态天数（%@）",
                tslot.footerText);
            Say(fabs(tslot.balance - 3382.69) < 0.01, @"Trae 槽显示余额");
            Say(tslot.visual == DeskCreditsVisualLoginLife && tslot.loginTotalDays > 0,
                @"Trae 槽视觉：登录态条");

            DeskCreditsView *tview = [[DeskCreditsView alloc] initWithFrame:
                                      NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
            [tview updateCenter:tc];
            NSString *tip = [tview tooltipTextForVerify];
            Say([tip containsString:@"Trae · 待签 +100"], @"Trae 悬停：状态词（%@）",
                [tip containsString:@"Trae · 待签 +100"] ? @"ok" : tip);
            Say([tip containsString:@"令牌到期"], @"Trae 悬停：令牌到期日");
            Say([tip containsString:@"剩余 3,383"], @"Trae 悬停：剩余积分（四舍五入到整数）");
            Say([tip containsString:@"不自动续期"], @"Trae 悬停：写明不自动续期");

            [prov ingestStatusForVerify:checked error:NULL];
            DeskCreditsSlot *tsigned = [[DeskCreditsCenterSnapshot centerWithMiniMax:s
                                                                               trae:prov.snapshot
                                                                              qoder:nil
                                                                          workbuddy:nil]
                                        slotForPlatform:DeskCreditsPlatformTrae];
            Say(tsigned.kind == DeskCreditsSlotKindSigned
                && [tsigned.statusText containsString:@"已签"],
                @"Trae 已签槽位（%@）", tsigned.statusText);

            DeskTraeCredits *empty = [[DeskTraeCredits alloc]
                initWithStoragePath:@"/nonexistent/storage.json" statePath:statePath];
            [empty load];
            DeskCreditsSlot *eslot = [[DeskCreditsCenterSnapshot centerWithMiniMax:s
                                                                             trae:empty.snapshot
                                                                            qoder:nil
                                                                        workbuddy:nil]
                                      slotForPlatform:DeskCreditsPlatformTrae];
            Say(eslot.kind == DeskCreditsSlotKindNeedsAuth
                && [eslot.statusText containsString:@"未找到登录态"],
                @"Trae 没有登录态时提示未找到（%@）", eslot.statusText);

            DeskCreditsClaimResult *okClaim = DeskTraeClaimResultFromResponse(tclaim);
            Say(okClaim.outcome == DeskCreditsClaimOutcomeClaimed, @"Trae claim code=0 → 成功");
            DeskCreditsClaimResult *devClaim = DeskTraeClaimResultFromResponse(tdev);
            Say(devClaim.outcome == DeskCreditsClaimOutcomeFailed
                && [devClaim.message containsString:@"9074"]
                && [devClaim.message containsString:@"设备校验"],
                @"Trae claim 9074 → 失败并指出设备校验（%@）", devClaim.message);
            DeskCreditsClaimResult *alreadyClaim =
                DeskTraeClaimResultFromResponse(@{@"code": @9006, @"message": @"今日已签到"});
            Say(alreadyClaim.outcome == DeskCreditsClaimOutcomeAlready, @"Trae 已签响应 → 已签");

            // 自动签到窗口：取一条干净的 pending 快照，只改时间/状态
            DeskTraeSnapshot *autoS = [prov.snapshot copy];
            autoS.connected = YES;
            autoS.hasStatus = YES;
            autoS.enabled = YES;
            autoS.checkedIn = NO;
            autoS.claiming = NO;
            autoS.phase = DeskTraePhaseReady;
            Say(DeskTraeShouldAutoClaim(autoS, 1793066700), @"北京 10:05:00 → 自动领");
            Say(!DeskTraeShouldAutoClaim(autoS, 1793066699), @"北京 10:04:59 → 还不领");
            autoS.checkedIn = YES;
            Say(!DeskTraeShouldAutoClaim(autoS, 1793066700), @"今日已签 → 不再领");
            autoS.checkedIn = NO;
            autoS.enabled = NO;
            Say(!DeskTraeShouldAutoClaim(autoS, 1793066700), @"活动关闭 → 不领");
            autoS.enabled = YES;
            autoS.connected = NO;
            Say(!DeskTraeShouldAutoClaim(autoS, 1793066700), @"没有登录态 → 不领");
            [[NSFileManager defaultManager] removeItemAtPath:statePath error:NULL];
        }


        // —— Qoder 真接入：PT 链路解析 / 额度 / 活动 / 槽位 ——
        {
            NSDictionary *qu = LoadJSON([mock stringByAppendingPathComponent:@"qoder_userinfo.json"]);
            NSDictionary *qq = LoadJSON([mock stringByAppendingPathComponent:@"qoder_quota.json"]);
            NSDictionary *qc = LoadJSON([mock stringByAppendingPathComponent:@"qoder_campaigns_claimable.json"]);
            NSDictionary *qcd = LoadJSON([mock stringByAppendingPathComponent:@"qoder_campaigns_claimed.json"]);
            NSDictionary *qcl = LoadJSON([mock stringByAppendingPathComponent:@"qoder_claim.json"]);
            Say(qu && qq && qc && qcd && qcl, @"Qoder mock 文件齐全");

            Say(DeskQoderTokenLooksValid(@"pt-0123456789abcdefghij"), @"Qoder PT 格式校验通过");
            Say(!DeskQoderTokenLooksValid(@"jt-0123456789abcdefghij"), @"Qoder 拒绝非 pt- 令牌");
            Say([DeskQoderPlanName(@"personal_standard") isEqualToString:@"个人标准版"],
                @"Qoder 套餐名翻译（%@）", DeskQoderPlanName(@"personal_standard"));
            NSTimeInterval qday = DeskCreditsDayStart(1793066700);
            Say([DeskQoderRefreshText(qday + 10 * 3600, qday + 8 * 3600)
                 isEqualToString:@"今日 10:00 刷新"],
                @"Qoder 窗口今天结束 → 今日 10:00 刷新");
            Say([DeskQoderRefreshText(qday + 34 * 3600, qday + 8 * 3600)
                 isEqualToString:@"明日 10:00 刷新"],
                @"Qoder 窗口明天结束 → 明日 10:00 刷新");

            DeskQoderSnapshot *qs = [DeskQoderSnapshot new];
            qs.hasToken = YES;
            qs.phase = DeskQoderPhaseReady;
            NSError *qe = nil;
            Say(DeskQoderApplyUserinfo(qs, qu) && [qs.nickname isEqualToString:@"qoder-tester"],
                @"Qoder 用户信息解析（%@）", qs.nickname);
            Say([qs.uid isEqualToString:@"019f5f44-9ad4-7448-a168-a5fab1b1cb05"], @"Qoder uid 解析");
            Say(DeskQoderApplyQuota(qs, qq, &qe), @"Qoder 额度解析（%@）", qe.localizedDescription ?: @"ok");
            Say(fabs(qs.balance - 2033.0) < 0.001, @"Qoder 余额 = 免费 0 + 活动包 2,033（实际 %.2f）", qs.balance);
            Say([qs.planTier isEqualToString:@"personal_standard"], @"Qoder userType 解析（%@）", qs.planTier);

            Say(DeskQoderApplyCampaigns(qs, qc, &qe), @"Qoder 活动解析（%@）", qe.localizedDescription ?: @"ok");
            Say(qs.hasStatus && qs.claimable && qs.campaignCount == 1
                && fabs(qs.todayAmount - 100) < 0.001,
                @"Qoder 活动：1 项可领 +100");
            Say(qs.windowEnd > 0, @"Qoder 活动窗口有截止时间");
            NSTimeInterval qnow = 1793066700; // 北京 10:05 · 用固定时间，早上跑断言不会假红
            Say(DeskQoderShouldAutoClaim(qs, qnow), @"Qoder 窗口内可领 → 自动领");
            Say(!DeskQoderShouldAutoClaim(qs, 1793066699), @"Qoder 10:04:59 前不自动领");
            Say(DeskQoderShouldAutoClaim(qs, 1793066700), @"Qoder 10:05 后自动领");
            qs.claiming = YES;
            Say(!DeskQoderShouldAutoClaim(qs, qnow), @"Qoder 领取中 → 不重复领");
            qs.claiming = NO;
            qs.claimable = NO;
            Say(!DeskQoderShouldAutoClaim(qs, qnow), @"Qoder 没活动 → 不领");
            qs.claimable = YES;

            DeskCreditsClaimResult *qcr = DeskQoderClaimResultFromResponse(qcl);
            Say(qcr.outcome == DeskCreditsClaimOutcomeClaimed && fabs(qcr.points - 100) < 0.001,
                @"Qoder claim status=CLAIMED → +100");
            DeskCreditsClaimResult *qca = DeskQoderClaimResultFromResponse(
                @{@"status": @"ALREADY_CLAIMED", @"message": @"already claimed"});
            Say(qca.outcome == DeskCreditsClaimOutcomeAlready, @"Qoder 重复领取 → 已领");

            Say(DeskQoderApplyCampaigns(qs, qcd, &qe), @"Qoder 已领活动能解析");
            Say(qs.claimed && !qs.claimable && !DeskQoderShouldAutoClaim(qs, qnow),
                @"Qoder 本窗口已领 → 不再自动领");

            NSString *qdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"qoder-verify-%u", arc4random()]];
            DeskQoderCredits *empty = [[DeskQoderCredits alloc] initWithDirectory:qdir];
            [empty load];
            DeskCreditsSlot *eq = [[DeskCreditsCenterSnapshot centerWithMiniMax:s trae:nil qoder:empty.snapshot workbuddy:nil]
                                   slotForPlatform:DeskCreditsPlatformQoder];
            Say(eq.kind == DeskCreditsSlotKindNeedsAuth && [eq.statusText containsString:@"未设置 PT"],
                @"Qoder 没有 PT 时提示设置（%@）", eq.statusText);

            DeskQoderCredits *qp = [[DeskQoderCredits alloc] initWithDirectory:qdir];
            [qp ingestUserinfoForVerify:qu error:NULL];
            [qp ingestQuotaForVerify:qq error:NULL];
            [qp ingestCampaignsForVerify:qc error:NULL];
            DeskCreditsCenterSnapshot *qcenter =
                [DeskCreditsCenterSnapshot centerWithMiniMax:s trae:nil qoder:qp.snapshot workbuddy:nil];
            DeskCreditsSlot *qslot = [qcenter slotForPlatform:DeskCreditsPlatformQoder];
            Say(qcenter.connectedCount == 2, @"接上 Qoder 后 2/4 已接入（实际 %ld）",
                (long)qcenter.connectedCount);
            Say(qslot.connected && qslot.kind == DeskCreditsSlotKindPending,
                @"Qoder 槽：已接入 · 待领");
            Say([qslot.statusText isEqualToString:@"待领 +100"],
                @"Qoder 槽状态：待领 +100（实际 %@）", qslot.statusText);
            Say([qslot.planLine containsString:@"个人标准版"] && [qslot.planLine containsString:@"PT"],
                @"Qoder 副行：个人标准版 · PT（%@）", qslot.planLine);
            Say([qslot.unit isEqualToString:@"Credits"], @"Qoder 单位 Credits");
            Say(fabs(qslot.balance - 2033.0) < 0.001, @"Qoder 槽显示余额 2,033");
            Say(qslot.visual == DeskCreditsVisualClaim && qslot.claimCount == 1 && qslot.deviceReady,
                @"Qoder 槽：活动牌 1 项 + PT 有效点");

            DeskCreditsView *qview = [[DeskCreditsView alloc] initWithFrame:
                                      NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
            [qview updateCenter:qcenter];
            NSString *qtip = [qview tooltipTextForVerify];
            Say([qtip containsString:@"Qoder · 待领 +100"], @"Qoder 悬停：状态词");
            Say([qtip containsString:@"2,033"], @"Qoder 悬停：可用余额");
            Say([qtip containsString:@"每天 10:00 刷新"], @"Qoder 悬停：刷新时间");
            Say([[qview pillTextForVerify:3] isEqualToString:@"签到"],
                @"MiniMax 已签药丸仍是手动签到按钮（%@）", [qview pillTextForVerify:3]);
            Say([[qview pillTextForVerify:2] isEqualToString:@"签到"],
                @"Qoder 待签药丸是手动签到按钮（%@）", [qview pillTextForVerify:2]);
            __block DeskCreditsPlatform manual = (DeskCreditsPlatform)-1;
            qview.onSlotCheckNow = ^(DeskCreditsPlatform p) { manual = p; };
            NSRect pill = [qview pillRectForVerify:2];
            NSPoint pillCenter = NSMakePoint(NSMidX(pill), NSMidY(pill));
            NSPoint pillInWindow = [qview convertPoint:pillCenter toView:nil];
            NSEvent *pdown = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                location:pillInWindow
                                           modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                            eventNumber:0 clickCount:1 pressure:1.0];
            NSEvent *pup = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                              location:pillInWindow
                                         modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                          eventNumber:0 clickCount:1 pressure:1.0];
            [qview mouseDown:pdown];
            [qview mouseUp:pup];
            Say(manual == DeskCreditsPlatformQoder, @"点 Qoder 药丸触发手动签到");
            manual = (DeskCreditsPlatform)-1;
            NSRect pill0 = [qview pillRectForVerify:3];
            NSPoint p0 = [qview convertPoint:NSMakePoint(NSMidX(pill0), NSMidY(pill0)) toView:nil];
            NSEvent *d0 = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                            location:p0 modifierFlags:0 timestamp:0 windowNumber:0
                                              context:nil eventNumber:0 clickCount:1 pressure:1.0];
            NSEvent *u0 = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                            location:p0 modifierFlags:0 timestamp:0 windowNumber:0
                                              context:nil eventNumber:0 clickCount:1 pressure:1.0];
            [qview mouseDown:d0];
            [qview mouseUp:u0];
            Say(manual == DeskCreditsPlatformMiniMax, @"已签格子的药丸也能点（手动补签）");
            [[NSFileManager defaultManager] removeItemAtPath:qdir error:NULL];
        }


        // —— WorkBuddy 真接入：状态 / 积分 / 领取 / 登录令牌 ——
        {
            NSDictionary *wpend = LoadJSON([mock stringByAppendingPathComponent:@"workbuddy_status_pending.json"]);
            NSDictionary *wchk = LoadJSON([mock stringByAppendingPathComponent:@"workbuddy_status_checked.json"]);
            NSDictionary *wres = LoadJSON([mock stringByAppendingPathComponent:@"workbuddy_resource.json"]);
            NSDictionary *wclaim = LoadJSON([mock stringByAppendingPathComponent:@"workbuddy_claim.json"]);
            NSDictionary *wstate = LoadJSON([mock stringByAppendingPathComponent:@"workbuddy_auth_state.json"]);
            NSDictionary *wtoken = LoadJSON([mock stringByAppendingPathComponent:@"workbuddy_auth_token.json"]);
            Say(wpend && wchk && wres && wclaim && wstate && wtoken, @"WorkBuddy mock 文件齐全");

            DeskWorkbuddySnapshot *w = [DeskWorkbuddySnapshot new];
            w.hasToken = YES;
            w.host = @"www.codebuddy.cn";
            w.source = @"browser";
            w.phase = DeskWorkbuddyPhaseReady;
            NSError *we = nil;
            Say(DeskWorkbuddyApplyStatus(w, wpend, &we), @"WorkBuddy 签到状态解析（%@）",
                we.localizedDescription ?: @"ok");
            Say(w.hasStatus && !w.checkedIn && fabs(w.streakDays - 3) < 0.001
                && fabs(w.dailyCredit - 100) < 0.001,
                @"WorkBuddy 待签 · 连签 3 天 · 每日 +100");
            Say(DeskWorkbuddyShouldAutoClaim(w, 1793066700), @"WorkBuddy 北京 10:05 后自动签");
            Say(!DeskWorkbuddyShouldAutoClaim(w, 1793066699), @"WorkBuddy 北京 10:05 前不签");
            w.checkedIn = YES;
            Say(!DeskWorkbuddyShouldAutoClaim(w, 1793066700), @"WorkBuddy 已签 → 不重复签");
            w.checkedIn = NO;

            Say(DeskWorkbuddyApplyResource(w, wres, &we), @"WorkBuddy 积分解析（%@）",
                we.localizedDescription ?: @"ok");
            Say(fabs(w.balance - 1900.0) < 0.01 && fabs(w.quotaTotal - 2500.0) < 0.01
                && fabs(w.quotaUsed - 600.0) < 0.01,
                @"WorkBuddy 余额 = 400 + 1,500 = 1,900（实际 %.0f）", w.balance);

            DeskCreditsClaimResult *wcr = DeskWorkbuddyClaimResultFromResponse(wclaim);
            Say(wcr.outcome == DeskCreditsClaimOutcomeClaimed && fabs(wcr.points - 100) < 0.001,
                @"WorkBuddy claim code=0 → +100");
            DeskCreditsClaimResult *wa = DeskWorkbuddyClaimResultFromResponse(
                @{@"code": @10001, @"msg": @"今日已签到"});
            Say(wa.outcome == DeskCreditsClaimOutcomeAlready, @"WorkBuddy 10001 → 今日已签");

            Say(DeskWorkbuddyApplyStatus(w, wchk, &we) && w.checkedIn
                && fabs(w.streakDays - 4) < 0.001 && !DeskWorkbuddyShouldAutoClaim(w, [NSDate date].timeIntervalSince1970),
                @"WorkBuddy 已签状态 → 连签 4 天且不再自动签");

            NSString *wdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"workbuddy-verify-%u", arc4random()]];
            DeskWorkbuddyCredits *wp = [[DeskWorkbuddyCredits alloc] initWithDirectory:wdir];
            Say([wp ingestAuthStateForVerify:wstate error:NULL], @"WorkBuddy 授权初始化能解析");
            Say([wp ingestAuthTokenForVerify:wtoken error:NULL], @"WorkBuddy 授权 token 能解析");
            Say([wp.snapshot.host isEqualToString:@"www.codebuddy.cn"],
                @"WorkBuddy 从 JWT 解析区域域名（%@）", wp.snapshot.host);
            [wp ingestResourceForVerify:wres error:NULL];
            [wp ingestStatusForVerify:wpend error:NULL];
            DeskCreditsCenterSnapshot *wcenter =
                [DeskCreditsCenterSnapshot centerWithMiniMax:s trae:nil qoder:nil workbuddy:wp.snapshot];
            DeskCreditsSlot *wslot = [wcenter slotForPlatform:DeskCreditsPlatformWorkBuddy];
            Say(wcenter.connectedCount == 2, @"接上 WorkBuddy 后 2/4 已接入（实际 %ld）",
                (long)wcenter.connectedCount);
            Say(wslot.connected && wslot.kind == DeskCreditsSlotKindPending,
                @"WorkBuddy 槽：已接入 · 待签");
            Say([wslot.statusText isEqualToString:@"待签 +100"],
                @"WorkBuddy 槽状态：待签 +100（实际 %@）", wslot.statusText);
            Say([wslot.footerText isEqualToString:@"连签 3 天 · 明日 +100"],
                @"WorkBuddy 槽底部：连签 3 天 · 明日 +100（实际 %@）", wslot.footerText);
            Say([wslot.planLine containsString:@"国内版"] && [wslot.planLine containsString:@"浏览器登录"],
                @"WorkBuddy 副行：国内版 · 浏览器登录（%@）", wslot.planLine);
            Say(fabs(wslot.balance - 1900.0) < 0.01 && wslot.streakCount == 3
                && wslot.visual == DeskCreditsVisualStreak,
                @"WorkBuddy 槽：余额 1,900 + 连签 3 点");

            DeskCreditsView *wview = [[DeskCreditsView alloc] initWithFrame:
                                      NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
            [wview updateCenter:wcenter];
            NSString *wtip = [wview tooltipTextForVerify];
            Say([wtip containsString:@"WorkBuddy · 待签 +100"], @"WorkBuddy 悬停：状态词");
            Say([wtip containsString:@"连签 3 天"], @"WorkBuddy 悬停：连签天数");
            Say([wtip containsString:@"1,900"], @"WorkBuddy 悬停：可用积分");
            Say([[wview pillTextForVerify:1] isEqualToString:@"签到"],
                @"WorkBuddy 待签药丸是手动签到按钮（%@）", [wview pillTextForVerify:1]);

            DeskWorkbuddyCredits *wempty = [[DeskWorkbuddyCredits alloc] initWithDirectory:
                [wdir stringByAppendingString:@"-empty"]];
            [wempty load];
            DeskCreditsSlot *wemptySlot = [[DeskCreditsCenterSnapshot centerWithMiniMax:s trae:nil
                                                                                 qoder:nil
                                                                             workbuddy:wempty.snapshot]
                                           slotForPlatform:DeskCreditsPlatformWorkBuddy];
            Say(wemptySlot.kind == DeskCreditsSlotKindNeedsAuth
                && [wemptySlot.statusText containsString:@"未登录"],
                @"WorkBuddy 未登录时提示登录（%@）", wemptySlot.statusText);
            [[NSFileManager defaultManager] removeItemAtPath:wdir error:NULL];
            [[NSFileManager defaultManager] removeItemAtPath:[wdir stringByAppendingString:@"-empty"] error:NULL];
        }

        DeskCreditsSlot *wb = [current slotForPlatform:DeskCreditsPlatformWorkBuddy];
        Say(wb.kind == DeskCreditsSlotKindUnconnected && wb.visual == DeskCreditsVisualStreak,
            @"WorkBuddy 占位：未接入 + 连签点");
        Say([wb.planLine containsString:@"浏览器登录"], @"WorkBuddy 占位写明浏览器登录（%@）", wb.planLine);
        Say([wb.statusText isEqualToString:@"国内签到 · 国际无"], @"WorkBuddy 占位写明国内/国际差异");

        DeskCreditsSlot *qoder = [current slotForPlatform:DeskCreditsPlatformQoder];
        Say(qoder.kind == DeskCreditsSlotKindUnconnected && qoder.visual == DeskCreditsVisualClaim,
            @"Qoder 占位：未接入 + 活动牌");
        Say([qoder.planLine containsString:@"PT"] && [qoder.unit isEqualToString:@"Credits"],
            @"Qoder 占位：PT 令牌 / Credits");
        Say([qoder.statusText isEqualToString:@"活动领取 · 每日 10:00"],
            @"Qoder 占位写明日 10:00 刷新（%@）", qoder.statusText);

        // —— 全接入预览：每槽主状态不同 ——
        DeskCreditsCenterSnapshot *full = [DeskCreditsCenterSnapshot previewFullCenterWithMiniMax:s];
        Say(full.slots.count == 4 && full.connectedCount == 4
            && full.doneCount == 3 && full.pendingCount == 1 && full.errorCount == 0,
            @"全接入：4/4 已接入 / 3 已办 / 1 待办");
        DeskCreditsSlot *ft = [full slotForPlatform:DeskCreditsPlatformTrae];
        Say(ft.kind == DeskCreditsSlotKindPending && ft.visual == DeskCreditsVisualLoginLife,
            @"Trae 全接入：待签 + 登录态条");
        Say([ft.statusText isEqualToString:@"待签 +100"]
            && [ft.footerText isEqualToString:@"登录态 22 天"],
            @"Trae 全接入：待签 +100 / 登录态 22 天");
        Say(fabs(ft.loginDays - 22) < 0.001 && ft.loginTotalDays == 30,
            @"Trae 登录态 22/30 天");
        Say([ft.planLine containsString:@"不自动续期"], @"Trae 全接入仍写不自动续期");

        DeskCreditsSlot *fw = [full slotForPlatform:DeskCreditsPlatformWorkBuddy];
        Say(fw.kind == DeskCreditsSlotKindSigned && fw.visual == DeskCreditsVisualStreak,
            @"WorkBuddy 全接入：已签 + 连签点");
        Say([fw.statusText isEqualToString:@"已签 +100"]
            && [fw.footerText isEqualToString:@"连签 3 天 · 明日 +100"]
            && fw.streakCount == 3, @"WorkBuddy 全接入：连签 3 天");

        DeskCreditsSlot *fq = [full slotForPlatform:DeskCreditsPlatformQoder];
        Say(fq.kind == DeskCreditsSlotKindClaimed && fq.visual == DeskCreditsVisualClaim,
            @"Qoder 全接入：已领 + 活动牌");
        Say([fq.statusText isEqualToString:@"已领 +100"]
            && [fq.footerText isEqualToString:@"已领 · 明日 10:00 刷新"]
            && fq.claimCount == 1 && fq.deviceReady,
            @"Qoder 全接入：1 项活动 / PT 有效");

        // —— 登录过期 / 未授权：组件里必须给出“点此授权” ——
        DeskCreditsSnapshot *expired = [s copy];
        expired.authorized = YES;
        expired.needsAuth = YES;
        DeskCreditsCenterSnapshot *expiredCenter = [DeskCreditsCenterSnapshot centerWithMiniMax:expired];
        DeskCreditsSlot *em = [expiredCenter slotForPlatform:DeskCreditsPlatformMiniMax];
        Say(em.kind == DeskCreditsSlotKindNeedsAuth
            && [em.statusText containsString:@"点此授权"],
            @"登录过期时 MiniMax 槽提示点此授权（%@）", em.statusText);
        Say(expiredCenter.errorCount == 1, @"登录过期计入异常数");

        DeskCreditsSnapshot *noAuth = [DeskCreditsSnapshot new];
        DeskCreditsCenterSnapshot *noAuthCenter = [DeskCreditsCenterSnapshot centerWithMiniMax:noAuth];
        DeskCreditsSlot *nm = [noAuthCenter slotForPlatform:DeskCreditsPlatformMiniMax];
        Say(nm.kind == DeskCreditsSlotKindNeedsAuth
            && [nm.statusText isEqualToString:@"未授权 · 点此授权"],
            @"未授权时 MiniMax 槽写未授权 · 点此授权");

        // —— 视图：700×190、四槽等宽、主状态视觉正确 ——
        DeskCreditsView *view = [[DeskCreditsView alloc] initWithFrame:NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
        [view updateCenter:current];
        Say(fabs(kCreditsViewWidth - 700.0) < 0.01 && fabs(kCreditsViewHeight - 132.0) < 0.01,
            @"组件尺寸 700×132（删掉抬头/表尾，实际 %.0f×%.0f）", kCreditsViewWidth, kCreditsViewHeight);
        Say([view slotCountForVerify] == 4, @"视图 4 个槽");
        NSRect r0 = [view slotRectForVerify:0];
        NSRect r3 = [view slotRectForVerify:3];
        Say(fabs(NSMinX(r0) - 12.0) < 0.01, @"首槽距左 12pt（实际 %.1f）", NSMinX(r0));
        Say(fabs(NSMinY(r0) - 10.0) < 0.01, @"首槽距顶 10pt，没有抬头（实际 %.1f）", NSMinY(r0));
        Say(fabs(NSMaxX(r3) - (kCreditsViewWidth - 12.0)) < 0.01,
            @"末槽贴右 12pt（实际 %.1f）", NSMaxX(r3));
        Say(fabs(NSHeight(r0) - 114.0) < 0.01, @"槽高 114pt（实际 %.1f）", NSHeight(r0));
        BOOL even = YES, noOverlap = YES, inside = YES;
        for (NSInteger i = 0; i < 4; i++) {
            NSRect r = [view slotRectForVerify:i];
            if (fabs(NSWidth(r) - NSWidth(r0)) > 0.01) even = NO;
            if (!NSContainsRect(view.bounds, r)) inside = NO;
            if (i > 0) {
                NSRect prev = [view slotRectForVerify:i - 1];
                if (NSMinX(r) - NSMaxX(prev) < -0.01) noOverlap = NO;
            }
        }
        Say(even, @"4 槽等宽");
        Say(noOverlap, @"4 槽不重叠");
        Say(inside, @"4 槽都在组件内");
        Say([view platformNameForVerify:0].length > 0
            && [[view platformNameForVerify:0] isEqualToString:@"Trae"]
            && [[view platformNameForVerify:1] isEqualToString:@"WorkBuddy"]
            && [[view platformNameForVerify:2] isEqualToString:@"Qoder"]
            && [[view platformNameForVerify:3] isEqualToString:@"MiniMax"],
            @"槽位顺序 Trae → WorkBuddy → Qoder → MiniMax");
        Say([[view statusTextForVerify:3] isEqualToString:@"已签 +1,000"],
            @"视图 MiniMax 状态：已签 +1,000");
        Say([[view balanceTextForVerify:3] isEqualToString:@"14,817"], @"视图 MiniMax 余额 14,817");
        Say([[view unitTextForVerify:3] isEqualToString:@"积分"], @"视图 MiniMax 单位 积分");
        Say([[view footerTextForVerify:3] isEqualToString:@"本轮 4/7 · 明日 +400"],
            @"视图 MiniMax footer 本轮 4/7 · 明日 +400");
        Say([view visualForVerify:0] == DeskCreditsVisualLoginLife
            && [view visualForVerify:1] == DeskCreditsVisualStreak
            && [view visualForVerify:2] == DeskCreditsVisualClaim
            && [view visualForVerify:3] == DeskCreditsVisualCycle,
            @"四槽主状态视觉：登录态条 / 连签点 / 活动牌 / 轮次点");
        Say([[view summaryTextForVerify] isEqualToString:@"1 已办 · 0 待办 · 3 待接入"],
            @"视图汇总：1 已办 · 0 待办 · 3 待接入（实际 %@）", [view summaryTextForVerify]);
        Say([[view oldestSyncTextForVerify] containsString:@"最旧同步"]
            || [[view oldestSyncTextForVerify] isEqualToString:@"未同步"],
            @"视图表尾有最旧同步（%@）", [view oldestSyncTextForVerify]);

        [view updateCenter:full];
        Say([[view summaryTextForVerify] isEqualToString:@"3 已办 · 1 待办"],
            @"全接入视图汇总：3 已办 · 1 待办（实际 %@）", [view summaryTextForVerify]);
        Say([[view statusTextForVerify:0] isEqualToString:@"待签 +100"], @"全接入 Trae 待签");
        Say([[view footerTextForVerify:0] isEqualToString:@"登录态 22 天"], @"全接入 Trae 登录态");
        Say([[view footerTextForVerify:2] isEqualToString:@"已领 · 明日 10:00 刷新"],
            @"全接入 Qoder 底部写本窗口已领");
        Say([[view unitTextForVerify:2] isEqualToString:@"Credits"], @"全接入 Qoder 单位 Credits");

        [view updateCenter:expiredCenter];
        Say([[view statusTextForVerify:3] containsString:@"点此授权"],
            @"登录过期视图提示点此授权（%@）", [view statusTextForVerify:3]);
        Say([[view summaryTextForVerify] isEqualToString:@"0 已办 · 0 待办 · 1 异常"],
            @"登录过期视图汇总：0 已办 · 0 待办 · 1 异常");

        [view updateCenter:noAuthCenter];
        Say([[view statusTextForVerify:3] isEqualToString:@"未授权 · 点此授权"],
            @"未授权视图提示未授权 · 点此授权");

        // —— 90 天纪录：窗口 / 峰值 / 覆盖 / 并列 / 滚出 / 换号 / 最近签到 ——
        {
            NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"credits-record-verify-%u", arc4random()]];
            NSString *path = [dir stringByAppendingPathComponent:@"records.json"];
            DeskCreditsRecordStore *store = [[DeskCreditsRecordStore alloc] initWithPath:path];
            Say([store load], @"记录仓库能在空文件上启动");

            NSTimeInterval rnow = [NSDate date].timeIntervalSince1970;
            for (NSInteger daysAgo = 94; daysAgo >= 0; daysAgo--) {
                double balance = (daysAgo == 54) ? 2000.0 : 1000.0 + (double)(94 - daysAgo);
                [store samplePlatform:DeskCreditsPlatformMiniMax
                              balance:balance
                                   at:rnow - (NSTimeInterval)daysAgo * 86400.0];
            }
            DeskCreditsRecord *r = [store recordForPlatform:DeskCreditsPlatformMiniMax at:rnow];
            Say(r.coverageDays == 90, @"记录窗口只保留 90 天（实际 %ld）", (long)r.coverageDays);
            Say(fabs(r.maxBalance - 2000.0) < 0.001, @"窗口峰值 2,000（实际 %.0f）", r.maxBalance);
            Say([r.peakDayKey isEqualToString:DeskCreditsDayKey(rnow - 54 * 86400)],
                @"峰值落在 54 天前（实际 %@）", r.peakDayKey);
            Say(!r.newHigh, @"峰值不是今天 → 不标新高");
            Say(r.rail.count == 90 &&
                (r.rail[0].integerValue & DeskCreditsRecordRailSampled) != 0,
                @"记录尺 90 格且有采样标记");

            NSString *yesterday = DeskCreditsDayKey(rnow - 86400);
            NSString *today = DeskCreditsDayKey(rnow);
            NSString *older = DeskCreditsDayKey(rnow - 2 * 86400);
            Say([store markCheckInPlatform:DeskCreditsPlatformMiniMax amount:100 dayKey:yesterday],
                @"最近签到：昨天写入");
            Say(![store markCheckInPlatform:DeskCreditsPlatformMiniMax amount:50 dayKey:older],
                @"更旧的日期不覆盖最近签到");
            Say([store markCheckInPlatform:DeskCreditsPlatformMiniMax amount:1000 dayKey:today],
                @"最近签到：今天覆盖昨天");
            r = [store recordForPlatform:DeskCreditsPlatformMiniMax at:rnow];
            Say([r.lastCheckInDayKey isEqualToString:today] &&
                fabs(r.lastCheckInAmount - 1000) < 0.001,
                @"最近签到 = 今天 +1,000（实际 %@ / %.0f）",
                r.lastCheckInDayKey, r.lastCheckInAmount);

            [store samplePlatform:DeskCreditsPlatformMiniMax balance:3000 at:rnow];
            r = [store recordForPlatform:DeskCreditsPlatformMiniMax at:rnow];
            Say(fabs(r.maxBalance - 3000) < 0.001 && r.newHigh,
                @"今天余额超过旧峰值 → 新高 + 峰值日今天");
            [store samplePlatform:DeskCreditsPlatformMiniMax balance:2500 at:rnow];
            r = [store recordForPlatform:DeskCreditsPlatformMiniMax at:rnow];
            Say(fabs(r.maxBalance - 3000) < 0.001,
                @"同一天回落不改当日桶（仍是 3,000）");

            [store samplePlatform:DeskCreditsPlatformWorkBuddy balance:500 at:rnow - 86400];
            [store samplePlatform:DeskCreditsPlatformWorkBuddy balance:500 at:rnow];
            r = [store recordForPlatform:DeskCreditsPlatformWorkBuddy at:rnow];
            Say([r.peakDayKey isEqualToString:yesterday] && !r.newHigh,
                @"并列峰值保留最早那天（实际 %@）", r.peakDayKey);
            NSString *oldEvent = DeskCreditsDayKey(rnow - 200 * 86400);
            Say([store markCheckInPlatform:DeskCreditsPlatformWorkBuddy amount:50 dayKey:oldEvent],
                @"最近签到不受 90 天窗口限制");
            r = [store recordForPlatform:DeskCreditsPlatformWorkBuddy at:rnow];
            Say([r.lastCheckInDayKey isEqualToString:oldEvent],
                @"90 天前的签到日期仍保留（实际 %@）", r.lastCheckInDayKey);

            [store samplePlatform:DeskCreditsPlatformQoder balance:9999 at:rnow - 89 * 86400];
            [store samplePlatform:DeskCreditsPlatformQoder balance:1 at:rnow];
            r = [store recordForPlatform:DeskCreditsPlatformQoder at:rnow];
            Say(fabs(r.maxBalance - 9999) < 0.001,
                @"窗口最左端仍计入峰值（实际 %.0f）", r.maxBalance);
            r = [store recordForPlatform:DeskCreditsPlatformQoder at:rnow + 86400];
            Say(fabs(r.maxBalance - 1) < 0.001 && r.coverageDays == 1,
                @"峰值滚出 90 天窗口后回落到窗口内最高（实际 %.0f / %ld 天）",
                r.maxBalance, (long)r.coverageDays);

            [store samplePlatform:DeskCreditsPlatformTrae balance:100 at:rnow];
            Say([store setAccountKey:@"acct-A" forPlatform:DeskCreditsPlatformTrae] == NO,
                @"首次写入账号标识不重置");
            Say([store setAccountKey:@"acct-B" forPlatform:DeskCreditsPlatformTrae] == YES,
                @"换账号 → 重置该平台记录");
            r = [store recordForPlatform:DeskCreditsPlatformTrae at:rnow];
            Say(r.maxBalance < 0 && r.coverageDays == 0 && r.lastCheckInDayKey == nil,
                @"换账号后记录和最近签到都清空");

            [store markCheckInPlatform:DeskCreditsPlatformTrae amount:100 dayKey:today];
            [store samplePlatform:DeskCreditsPlatformTrae balance:120 at:rnow];
            [store save];
            DeskCreditsRecordStore *reloaded = [[DeskCreditsRecordStore alloc] initWithPath:path];
            Say([reloaded load], @"记录文件能重新载入");
            DeskCreditsRecord *rr = [reloaded recordForPlatform:DeskCreditsPlatformTrae at:rnow];
            Say(fabs(rr.maxBalance - 120) < 0.001 &&
                [rr.lastCheckInDayKey isEqualToString:today],
                @"记录落盘再读回：余额和最近签到不丢");
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
            NSInteger mode = [attrs[NSFilePosixPermissions] integerValue];
            Say((mode & 0777) == 0600, @"记录文件权限 0600（实际 %03lo）", (long)(mode & 0777));
            [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        }

        // —— 记录行/最近签到视图：四槽独立、文案、新高、未接入不画 ——
        {
            DeskCreditsView *recordView = [[DeskCreditsView alloc] initWithFrame:
                                          NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
            [recordView updateCenter:full];
            NSTimeInterval vnow = [NSDate date].timeIntervalSince1970;
            NSString *todayKey = DeskCreditsDayKey(vnow);
            NSString *yKey = DeskCreditsDayKey(vnow - 86400);
            NSString *peak0 = full.slots[3].recordPeakDayKey;
            Say([[recordView recordTextForVerify:3] isEqualToString:
                 [NSString stringWithFormat:@"90天最高 16,200 积分 · %@", ShortDay(peak0)]],
                @"视图 MiniMax 记录行（%@）", [recordView recordTextForVerify:3]);
            Say([[recordView lastEventTextForVerify:3] isEqualToString:
                 [NSString stringWithFormat:@"最近签到 %@", ShortDay(todayKey)]],
                @"视图 MiniMax 最近签到（%@）", [recordView lastEventTextForVerify:3]);
            Say([[recordView recordTextForVerify:0] hasPrefix:@"63天最高 3,420 积分 · "],
                @"视图 Trae 记录行写 63 天（%@）", [recordView recordTextForVerify:0]);
            Say([[recordView lastEventTextForVerify:0] isEqualToString:
                 [NSString stringWithFormat:@"最近签到 %@", ShortDay(yKey)]],
                @"视图 Trae 最近签到是昨天（%@）", [recordView lastEventTextForVerify:0]);
            Say([recordView recordIsNewHighForVerify:2] &&
                [[recordView recordTextForVerify:2] containsString:@" · 今天"],
                @"视图 Qoder 新高态：今天（%@）", [recordView recordTextForVerify:2]);
            Say([[recordView lastEventTextForVerify:2] containsString:@"最近领取 "],
                @"视图 Qoder 用“最近领取”（%@）", [recordView lastEventTextForVerify:2]);
            Say([recordView recordRailCountForVerify:3] == 90 &&
                [recordView recordRailCountForVerify:2] == 90,
                @"视图已接入槽都有 90 格记录尺");
            Say([[recordView tooltipTextForVerify] containsString:@"90天最高 16,200 积分"] &&
                [[recordView tooltipTextForVerify] containsString:@"最近签到 "],
                @"悬停详情包含 90 天纪录和最近签到");
            Say([[recordView pillToneForVerify:3] isEqualToString:@"cyan"],
                @"MiniMax 当天已签：药丸青色");
            Say([[recordView pillToneForVerify:0] isEqualToString:@"amber"],
                @"Trae 待签：药丸黄色");
            Say([[recordView pillToneForVerify:2] isEqualToString:@"cyan"],
                @"Qoder 当天已领：药丸青色");
            DeskCreditsSlot *qYesterday = [full.slots[2] copy];
            qYesterday.lastCheckInDayKey = DeskCreditsDayKey(
                [[NSDate date] timeIntervalSince1970] - 86400);
            DeskCreditsCenterSnapshot *qWindowCenter = [DeskCreditsCenterSnapshot new];
            qWindowCenter.slots = @[full.slots[0], full.slots[1], qYesterday, full.slots[3]];
            [recordView updateCenter:qWindowCenter];
            Say([[recordView pillToneForVerify:2] isEqualToString:@"amber"],
                @"Qoder 窗口仍是昨天已领、当天未签：药丸黄色（%@）",
                [recordView pillToneForVerify:2]);
            DeskCreditsSlot *dup = [full.slots[2] copy];
            dup.recordNewHigh = NO;
            dup.lastCheckInDayKey = dup.recordPeakDayKey;
            DeskCreditsCenterSnapshot *dupCenter = [DeskCreditsCenterSnapshot new];
            dupCenter.slots = @[full.slots[0], full.slots[1], dup, full.slots[3]];
            [recordView updateCenter:dupCenter];
            Say([[recordView recordTextForVerify:2] isEqualToString:@"90天最高 1,200 Credits"],
                @"峰值日 = 最近签到日时记录行不重复日期（%@）",
                [recordView recordTextForVerify:2]);
            [recordView updateCenter:current];
            Say([[recordView recordTextForVerify:0] isEqualToString:@""] &&
                [recordView recordRailCountForVerify:0] == 0 &&
                [[recordView lastEventTextForVerify:0] isEqualToString:@""],
                @"未接入槽不画记录行/记录尺/最近签到");
            Say([[recordView pillToneForVerify:0] isEqualToString:@"muted"],
                @"未接入槽药丸灰色");
            [recordView updateCenter:expiredCenter];
            Say([[recordView lastEventTextForVerify:3] isEqualToString:@""],
                @"授权过期态隐藏状态行右侧日期");
            Say([[recordView pillToneForVerify:3] isEqualToString:@"red"],
                @"授权过期药丸红色");
        }

        // —— 组件内授权入口：未授权时点 MiniMax 槽应触发 onSlotActivate ——
        __block DeskCreditsPlatform activated = (DeskCreditsPlatform)-1;
        DeskCreditsView *clickView = [[DeskCreditsView alloc] initWithFrame:
                                      NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
        [clickView updateCenter:expiredCenter];
        clickView.onSlotActivate = ^(DeskCreditsPlatform p) { activated = p; };
        NSRect mmRect = [clickView slotRectForVerify:3];
        NSPoint mmAt = NSMakePoint(NSMidX(mmRect), NSMidY(mmRect));
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                          location:mmAt
                                     modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                      eventNumber:0 clickCount:1 pressure:1.0];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                        location:mmAt
                                   modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                    eventNumber:0 clickCount:1 pressure:1.0];
        [clickView mouseDown:down];
        [clickView mouseUp:up];
        Say(activated == DeskCreditsPlatformMiniMax,
            @"组件里点击登录过期的 MiniMax 槽会触发授权入口");

        // —— 凭据文件必须是 0600 ——
        NSString *tmp = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"deskboard-credits-verify-%u",
                                            arc4random()]];
        DeskCreditsProvider *provider = [[DeskCreditsProvider alloc] initWithDirectory:tmp];
        [provider load];
        NSDictionary *fakeAuth = @{
            @"schemaVersion": @1,
            @"accessToken": @"verify-only-not-a-real-token",
            @"refreshToken": @"verify-only-not-a-real-token",
            @"expiresAtMs": @1,
            @"needsAuth": @NO,
        };
        BOOL wrote = [provider writeAuthFileForVerify:fakeAuth];
        NSString *authPath = [tmp stringByAppendingPathComponent:@"auth.json"];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:authPath error:NULL];
        NSInteger mode = [attrs[NSFilePosixPermissions] integerValue];
        Say(wrote && ((mode & 0777) == 0600), @"凭据文件落盘且权限 0600（实际 %03lo）", (long)(mode & 0777));
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];

        // —— 全局锁定：签到组件锁住后不挪窗，解锁恢复 ——
        {
            NSWindow *cw = [[NSWindow alloc] initWithContentRect:
                            NSMakeRect(300, 300, kCreditsViewWidth, kCreditsViewHeight)
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered defer:NO];
            DeskCreditsView *lv = [[DeskCreditsView alloc] initWithFrame:
                                   NSMakeRect(0, 0, kCreditsViewWidth, kCreditsViewHeight)];
            [lv updateCenter:current];
            cw.contentView = lv;
            NSPoint mid = NSMakePoint(NSMidX(lv.bounds), NSMidY(lv.bounds));
            NSEvent *md = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:mid
                                          modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                           windowNumber:cw.windowNumber context:nil
                                            eventNumber:41 clickCount:1 pressure:1.0];
            NSEvent *mu = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:mid
                                          modifierFlags:0 timestamp:[NSDate date].timeIntervalSince1970
                                           windowNumber:cw.windowNumber context:nil
                                            eventNumber:42 clickCount:1 pressure:0.0];
            lv.locked = YES;
            [lv mouseDown:md];
            NSRect lf = cw.frame;
            [lv dragWindowToMouse:NSMakePoint(NSEvent.mouseLocation.x + 40,
                                              NSEvent.mouseLocation.y + 30)];
            Say(NSEqualPoints(cw.frame.origin, lf.origin), @"锁定后签到组件不挪窗");
            [lv mouseUp:mu];
            lv.locked = NO;
            [lv mouseDown:md];
            [lv dragWindowToMouse:NSMakePoint(NSEvent.mouseLocation.x + 40,
                                              NSEvent.mouseLocation.y + 30)];
            Say(fabs((cw.frame.origin.x - lf.origin.x) - 40.0) < 1.0 &&
                fabs((cw.frame.origin.y - lf.origin.y) - 30.0) < 1.0,
                @"解锁后签到组件挪窗跟上鼠标 (+40,+30)，实际 (%+.0f,%+.0f)",
                cw.frame.origin.x - lf.origin.x, cw.frame.origin.y - lf.origin.y);
            [lv mouseUp:mu];
            [cw orderOut:nil];
        }

        // —— 字体清晰度：签到大量的 6~7pt 小字曾看不清；守住提档后的字号/亮度 ——
        {
            NSString *csrc = [NSString stringWithContentsOfFile:
                              [root stringByAppendingPathComponent:@"credits_view.m"]
                                                       encoding:NSUTF8StringEncoding error:NULL];
            Say(csrc.length > 0, @"读到了 credits_view.m 源码（字体断言的前提）");
            Say([csrc containsString:@"Mono(7.4, NSFontWeightRegular)"]
                && [csrc containsString:@"systemFontOfSize:7.0 weight:NSFontWeightMedium"]
                && [csrc containsString:@"MonoDigits(9.2, NSFontWeightBold)"]
                && [csrc containsString:@"Mono(6.8, NSFontWeightRegular)"]
                && [csrc containsString:@"Mono(6.8, NSFontWeightMedium)"]
                && [csrc containsString:@"systemFontOfSize:9.5 weight:NSFontWeightSemibold"]
                && [csrc containsString:@"Mono(7.8, NSFontWeightMedium)"]
                && [csrc containsString:@"Mono(8.0, NSFontWeightMedium)"]
                && [csrc containsString:@"Mono(7.5, actionable ?"],
                @"签到小字提档：计划 7.4 / 记录 7.0+9.2 / 状态 9.5 / 页脚 8.0 / 药丸 7.5");
            Say([csrc containsString:@"colorWithAlphaComponent:0.70"]
                && [csrc containsString:@"colorWithAlphaComponent:0.72"]
                && [csrc containsString:@"colorWithAlphaComponent:0.68"],
                @"签到副标签从 VaultMuted 提到 paper 0.68~0.72");
        }

        printf("\n%s 签到断言：%d 项失败\n", gFailures == 0 ? "全部通过。" : "有失败项。", gFailures);
    }
    return gFailures == 0 ? 0 : 1;
}
