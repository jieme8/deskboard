// 每进程负载采集实现。约定全写在 procs.h 的注释里，那几条实测边界都是这轮量出来的，
// 别凭直觉改：刻度换算、只读得到本用户进程、能耗是估算、网络先用连接数。
#import "procs.h"
#import <libproc.h>
#import <sys/proc_info.h>
#import <sys/resource.h>
#import <sys/time.h>
#import <sys/sysctl.h>
#import <mach/mach_time.h>
#import <errno.h>
#import <stdlib.h>

// SDK 头里只有字段 proc_fdtype，没给取值名字。实测：node 进程直方图 {0:14, 1:1, 2:2}，
// 2 就是它的两个 socket（1 = vnode）。XNU 的 fdesc 类型表里 DTYPE_SOCKET 也是 2。
#define PROC_FDTYPE_SOCKET 2u

#pragma mark - 进程介绍（悬停气泡用）

// 这张表是给人看的，不是给程序判定的：一句话说清「它是干什么的」。
// 键一律小写，匹配时先拿可执行文件名、再拿 proc_name（两者都可能被截断）。
static NSDictionary<NSString *, NSString *> *DeskProcIntroTable(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{
            // 内核 / 窗口 / 登录
            @"kernel_task": @"内核主任务：调度 CPU、管理内存分页与硬件中断。",
            @"launchd": @"系统启动管理器：开机后按需拉起并看管所有后台服务。",
            @"windowserver": @"窗口服务器：合成所有窗口画面，并把键鼠事件投递给前台应用。",
            @"loginwindow": @"登录会话管理器：负责登录、锁屏与用户切换。",
            @"dock": @"程序坞：常驻桌面边缘，显示并切换正在运行的应用。",
            @"finder": @"访达：macOS 的文件管理器，也是桌面图标的宿主。",
            @"systemuiserver": @"系统界面服务：菜单栏右侧状态图标与系统菜单的一部分。",
            @"controlcenter": @"控制中心：菜单栏里的音量、网络、亮度等快捷开关。",
            @"notificationcenter": @"通知中心：显示横幅通知、通知列表与小组件。",
            @"spotlight": @"聚焦搜索：菜单栏放大镜与全盘搜索界面。",
            // 聚焦索引
            @"mds": @"聚焦索引：扫描磁盘元数据，支撑 Spotlight 搜索。",
            @"mds_stores": @"聚焦索引数据库：保存 Spotlight 的元数据索引。",
            @"mdworker_shared": @"聚焦索引工作进程：为 Spotlight 解析文件内容。",
            // 音频 / 网络 / 蓝牙 / 近场
            @"coreaudiod": @"Core Audio 音频服务：管理所有应用的音频输入输出。",
            @"corespeechd": @"语音识别服务：为听写与语音指令提供识别能力。",
            @"configd": @"系统配置服务：管理网络、电源等系统配置。",
            @"networkd": @"网络配置服务：维护网络接口与连接状态。",
            @"nehelper": @"网络扩展助手：为 VPN、内容过滤提供系统支持。",
            @"mdnsresponder": @"Bonjour 服务发现：在局域网内解析设备与服务名称。",
            @"wifip2pd": @"Wi‑Fi 点对点服务：支撑隔空投送、接力等近场功能。",
            @"bluetoothd": @"蓝牙服务：管理蓝牙连接与外设。",
            @"sharingd": @"共享服务：处理隔空投送、剪贴板共享等。",
            @"rapportd": @"接力通信服务：与其他 Apple 设备保持互联。",
            @"airportd": @"Wi‑Fi 管理服务：扫描、连接并维护无线网络。",
            @"nearbyd": @"近场发现服务：发现附近的设备与配件。",
            @"routined": @"位置服务：维护设备位置与常去地点。",
            // iCloud / 商店 / 更新
            @"bird": @"iCloud 云盘同步：上传、下载「桌面与文稿」等文件。",
            @"cloudd": @"iCloud 同步服务：协调云盘与账户数据的同步。",
            @"nsurlsessiond": @"后台传输服务：替应用执行后台下载与上传。",
            @"storeassetd": @"App Store 资源服务：下载应用与更新包。",
            @"appstoreagent": @"App Store 后台代理：处理更新与购买任务。",
            @"softwareupdated": @"系统更新服务：检查并下载 macOS 更新。",
            // 电源 / 硬件 / 文件
            @"powerd": @"电源管理服务：管理睡眠、唤醒与电池策略。",
            @"thermalmonitord": @"温度监控：采集传感器并触发降频保护。",
            @"hidd": @"人机接口服务：处理键盘、触控板与鼠标事件。",
            @"fontd": @"字体服务：为应用提供字体匹配与渲染数据。",
            @"distnoted": @"分布式通知服务：在进程之间转发系统通知。",
            @"cfprefsd": @"偏好设置服务：集中读写应用的 plist 配置。",
            @"usereventagent": @"用户事件代理：加载插件并参与系统事件处理。",
            @"fseventsd": @"文件事件服务：把文件变化通知给索引与备份。",
            @"diskarbitrationd": @"磁盘仲裁服务：挂载、卸载磁盘与磁盘映像。",
            @"runningboardd": @"进程生命周期管理：启动、挂起和回收 App 与扩展。",
            @"watchdogd": @"看门狗：监控关键系统进程，卡死时重启它们。",
            // 安全 / 日志 / 诊断
            @"securityd": @"安全服务：管理钥匙串与进程的权限凭据。",
            @"trustd": @"证书信任服务：校验证书链与网站身份。",
            @"secd": @"安全框架服务：为应用提供加密与签名能力。",
            @"tccd": @"隐私权限服务：管理相机、麦克风、屏幕录制等授权。",
            @"syspolicyd": @"系统策略服务：校验应用签名与首次运行许可。",
            @"amfid": @"代码签名校验：验证可执行文件的签名有效性。",
            @"opendirectoryd": @"目录服务：管理本地账户与用户身份查询。",
            @"socketfilterfw": @"应用防火墙：按规则放行或拦截网络连接。",
            @"logd": @"统一日志服务：收集系统与应用的日志。",
            @"diagnosticd": @"诊断服务：在异常时收集系统诊断信息。",
            @"spindump": @"卡顿诊断：采样无响应的进程并生成报告。",
            @"reportcrash": @"崩溃报告：捕获并整理崩溃日志。",
            @"systemstatsd": @"系统统计服务：汇总资源使用数据，和活动监视器同源。",
            // 视频编解码 / 驱动扩展
            @"vtdecoderxpcservice": @"视频解码服务：把视频流解成画面帧。",
            @"vtencoderxpcservice": @"视频编码服务：把画面帧压成视频流。",
            @"com.apple.driverkit-applebcmwlan": @"Wi‑Fi 驱动扩展：Apple 无线网卡的 DriverKit 驱动。",
            // 浏览器
            @"google chrome": @"Google Chrome 主进程：管理窗口、标签页与扩展。",
            @"google chrome helper": @"Chrome 的辅助进程：承载网页渲染、GPU 或插件。",
            @"safari": @"Safari 浏览器主进程。",
            @"com.apple.webkit.webcontent": @"Safari 网页进程：在沙盒里渲染页面。",
            @"com.apple.webkit.networking": @"Safari 网络进程：统一处理网页请求。",
            @"com.apple.webkit.gpu": @"Safari 图形进程：负责网页画面合成。",
            @"chrome_crashpad_handler": @"崩溃捕获组件：Chrome 系列应用崩溃时生成诊断报告。",
            // 开发 / 常用应用
            @"code": @"Visual Studio Code 主进程：代码编辑器。",
            @"qoder cn": @"Qoder 桌面端主进程：AI 编程工作台。",
            @"minimax code": @"MiniMax Code 主进程：AI 编程工作台。",
            @"qianwen": @"通义千问桌面端主进程。",
            @"qianwenshell": @"通义千问的辅助进程：承载界面或后台服务。",
            @"wallspace": @"动态壁纸应用：渲染桌面壁纸动画。",
            @"lemonmonitor": @"腾讯柠檬清理的监控组件：采集磁盘与系统状态。",
            @"deskboard": @"DeskBoard 本身：就是桌面上的这块监视器组件。",
            @"xcode": @"Xcode 主进程：Apple 平台的集成开发环境。",
            @"docker": @"Docker 桌面端：管理容器与虚拟机。",
            @"orbstack": @"OrbStack：轻量级容器与 Linux 虚拟机。",
            @"sourcetree": @"Sourcetree：Git 图形客户端。",
            @"terminal": @"终端应用主进程。",
            @"iterm2": @"iTerm2 终端主进程。",
            @"warp": @"Warp 终端主进程。",
            @"dropbox": @"Dropbox 同步客户端。",
            @"onedrive": @"OneDrive 同步客户端。",
            @"baidunetdisk": @"百度网盘客户端。",
            @"wechat": @"微信桌面端主进程。",
            @"qq": @"QQ 桌面端主进程。",
            @"dingtalk": @"钉钉桌面端主进程。",
            @"feishu": @"飞书桌面端主进程。",
            @"lark": @"飞书桌面端主进程。",
            @"notion": @"Notion 桌面端主进程。",
            @"slack": @"Slack 桌面端主进程。",
            @"discord": @"Discord 桌面端主进程。",
            @"spotify": @"Spotify 音乐客户端。",
            @"music": @"Apple Music 主进程。",
            @"photos": @"照片应用主进程：管理图库与图像处理。",
            @"preview": @"预览应用主进程：查看 PDF 与图片。",
            // 运行时 / 命令行
            @"node": @"Node.js 运行时：通常承载开发服务器、构建脚本或命令行工具。",
            @"python": @"Python 解释器：运行脚本或开发服务。",
            @"python3": @"Python 解释器：运行脚本或开发服务。",
            @"java": @"Java 虚拟机：运行 Java 应用或开发工具。",
            @"ruby": @"Ruby 解释器：运行 Ruby 脚本或工具。",
            @"perl": @"Perl 解释器：运行 Perl 脚本。",
            @"go": @"Go 工具链：常用于编译或运行 Go 程序。",
            @"ssh": @"SSH 客户端：远程登录或端口转发。",
            @"sshd": @"SSH 服务端：接受远程登录。",
            @"git": @"Git 版本控制：执行提交、拉取等仓库操作。",
            @"rsync": @"文件同步工具：增量复制本地或远程文件。",
            @"curl": @"命令行 HTTP 客户端：发起网络请求。",
            @"wget": @"命令行下载工具。",
            @"ffmpeg": @"音视频转码工具：解码、编码与封装多媒体流。",
            @"adb": @"Android 调试桥：与 Android 设备或模拟器通信。",
            @"zsh": @"Zsh：终端里的交互式命令行解释器。",
            @"bash": @"Bash：命令行解释器。",
            @"fish": @"Fish：命令行解释器。",
            @"tmux": @"终端复用器：在一个窗口里管理多个会话。",
            @"vim": @"Vim 文本编辑器。",
            @"nvim": @"Neovim 文本编辑器。",
        };
    });
    return t;
}

// 表里写的是系统名，界面上显示中文名更省事
static NSString *DeskProcAppDisplayName(NSString *app) {
    static NSDictionary<NSString *, NSString *> *alias;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        alias = @{
            @"code": @"Visual Studio Code",
            @"qianwen": @"通义千问",
            @"qianwenshell": @"通义千问",
            @"lemonmonitor": @"腾讯柠檬",
            @"uuremote": @"UU 远程",
        };
    });
    return alias[app.lowercaseString] ?: app;
}

// Helper 进程的名字自带角色：Google Chrome Helper (Renderer)、Code Helper (Plugin)…
static NSString *DeskProcHelperRole(NSString *name) {
    NSString *n = name.lowercaseString;
    if ([n containsString:@"renderer"]) return @"网页与界面渲染";
    if ([n containsString:@"gpu"]) return @"图形加速";
    if ([n containsString:@"plugin"]) return @"插件宿主";
    if ([n containsString:@"network"]) return @"网络请求";
    return @"后台任务";
}

// "/Applications/Foo.app/Contents/MacOS/Foo …" → "/Applications/Foo.app"
static NSString *DeskProcAppBundlePath(NSString *path) {
    NSRange r = [path rangeOfString:@".app/"];
    if (r.location == NSNotFound) return nil;
    return [path substringToIndex:r.location + r.length - 1];
}

static NSString *DeskProcShortPath(NSString *path) {
    NSString *home = NSHomeDirectory();
    if (home.length && [path hasPrefix:home]) {
        return [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    return path;
}

NSString *DeskProcExecutablePath(pid_t pid) {
    if (pid <= 0) return nil;
    char buf[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int n = proc_pidpath(pid, buf, sizeof(buf));
    if (n <= 0) return nil;
    return [NSString stringWithUTF8String:buf];
}

NSString *DeskProcIntroText(NSString *name, NSString *path) {
    NSString *exe = path.lastPathComponent;
    // proc_name 会被截断（pbi_name 只有 16 字节），可执行文件名通常更完整，取长的那个查表
    NSString *probe = exe.length > name.length ? exe : name;
    if (!probe.length) probe = name.length ? name : exe;
    NSString *key = probe.lowercaseString;
    if (!key.length) return nil;

    NSDictionary *table = DeskProcIntroTable();
    if (table[key]) return table[key];
    if (name.length && table[name.lowercaseString]) return table[name.lowercaseString];
    if (exe.length && table[exe.lowercaseString]) return table[exe.lowercaseString];

    // UU 远程这一家进程名是 UURemote / UURemoteDaemon / UURemoteService / UURemoteServer …
    if ([key hasPrefix:@"uuremote"]) return @"网易 UU 远程的组件：负责远程会话与串流。";
    if ([key hasPrefix:@"mdworker"]) return @"聚焦索引工作进程：为 Spotlight 解析文件内容。";

    // "Google Chrome Helper (Renderer)" → 应用名取 " Helper" 之前那段
    NSRange hr = [probe rangeOfString:@" Helper"];
    if (hr.location != NSNotFound) {
        NSString *app = DeskProcAppDisplayName([probe substringToIndex:hr.location]);
        return [NSString stringWithFormat:@"「%@」的辅助进程：负责%@。",
                app, DeskProcHelperRole(probe)];
    }

    NSString *bundlePath = DeskProcAppBundlePath(path);
    if (bundlePath.length) {
        NSString *app = DeskProcAppDisplayName([[bundlePath lastPathComponent] stringByDeletingPathExtension]);
        return [NSString stringWithFormat:@"「%@」应用内的进程。", app];
    }

    // 路径里认不出应用时，按所在目录给个诚实的定位，不硬猜用途
    if ([path containsString:@"/Library/Input Methods/"]) return @"输入法程序：接管键盘输入。";
    if ([path containsString:@".xpc/"]) {
        return [NSString stringWithFormat:@"macOS 的 XPC 服务「%@」：随用随起，用完即退。", exe];
    }
    if ([path containsString:@"/usr/libexec/"]) return @"macOS 系统后台服务，由 launchd 按需启动。";
    if ([path containsString:@"/System/Library/"]) return @"macOS 内置的系统服务或组件。";
    if ([path containsString:@"/usr/local/bin/"] || [path containsString:@"/opt/homebrew/"]) {
        return @"第三方命令行工具，通常由终端或脚本启动。";
    }
    if ([path hasPrefix:@"/usr/bin/"] || [path hasPrefix:@"/bin/"] || [path hasPrefix:@"/sbin/"]) {
        return @"macOS 自带的命令行工具。";
    }
    if ([path hasPrefix:@"/Library/"]) return @"第三方安装的系统级后台服务。";
    if ([path containsString:@"/Library/"]) return @"当前用户的后台服务或应用组件。";
    if ([path hasPrefix:NSHomeDirectory()]) return @"当前用户启动的命令行程序或后台进程。";
    if ([key containsString:@"helper"] || [key containsString:@"agent"] ||
        [key containsString:@"daemon"] || [key containsString:@"service"]) {
        return @"后台服务进程。";
    }
    return nil;
}

NSString *DeskProcOriginText(NSString *path) {
    if (!path.length) return nil;
    NSString *shown = DeskProcAppBundlePath(path) ?: path;
    return [@"来自 " stringByAppendingString:DeskProcShortPath(shown)];
}

// 上一拍的累计值。进程会退出/新建，所以按 pid 存，取不到就当新进程（这一拍不给 CPU）。
@interface PrevStat : NSObject
@property (nonatomic, assign) uint64_t cpuTicks;
@property (nonatomic, assign) uint64_t wakeups;
@property (nonatomic, assign) uint64_t energyNj;
@end
@implementation PrevStat
@end

@implementation DeskProc
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ pid=%d cpu=%.1f mem=%.0fM e=%.1f sk=%ld net=%.0f/%.0f>",
            self.name, (int)self.pid, self.cpu, self.mem / 1048576.0, self.energy,
            (long)self.sockets, self.netInRate, self.netOutRate];
}
@end

// 每进程累计流量：nettop 单次 CSV 采样。实测 `-L 1` 约 0.01s；
// 烧 146% 的是持续交互模式，不是这种一次性日志采样。
// CSV 形如 "Google Chrome H.84286,310589804,135583,"；进程名可能含逗号，
// 所以从右往左取两个数值列，剩下的整段再当 "name.pid"。
static NSDictionary<NSNumber *, NSArray<NSNumber *> *> *SampleNettop(void) {
    NSTask *task = [NSTask new];
    task.launchPath = @"/usr/bin/nettop";
    task.arguments = @[@"-P", @"-x", @"-L", @"1", @"-n", @"-J", @"bytes_in,bytes_out"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleForWritingAtPath:@"/dev/null"];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return nil;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0 || data.length == 0) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text.length) return nil;

    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *byPid = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@","];
        NSInteger n = (NSInteger)parts.count;
        if (n >= 2 && parts.lastObject.length == 0) n--;   // 行尾逗号
        if (n < 3) continue;
        NSString *outS = [parts[n - 1] stringByTrimmingCharactersInSet:space];
        NSString *inS = [parts[n - 2] stringByTrimmingCharactersInSet:space];
        NSString *namePid = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)(n - 2))]
                             componentsJoinedByString:@","];
        NSRange dot = [namePid rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location == NSNotFound) continue;
        NSString *pidS = [namePid substringFromIndex:dot.location + 1];
        if (!pidS.length || [pidS rangeOfCharacterFromSet:nonDigits].location != NSNotFound) continue;

        errno = 0;
        char *end = NULL;
        unsigned long long inB = strtoull(inS.UTF8String, &end, 10);
        if (errno || end == inS.UTF8String) continue;
        errno = 0;
        unsigned long long outB = strtoull(outS.UTF8String, &end, 10);
        if (errno || end == outS.UTF8String) continue;
        pid_t pid = (pid_t)pidS.intValue;
        if (pid <= 0) continue;
        byPid[@(pid)] = @[ @((double)inB), @((double)outB) ];
    }
    return byPid.count ? byPid : nil;
}

// 每 6 拍才数一次 socket（10 秒一拍 → 60 秒）：一次 PROC_PIDLISTFDS 要两趟系统调用，
// 567 个进程全数一遍是这组件里最贵的一笔开销，而连接数本来就是慢变量
static const NSInteger kSocketEveryTicks = 6;
// nettop 单次采样虽然只有 ~0.01s，但每拍起一个进程本身就要唤醒 CPU；每进程流量是慢变量，
// 20 秒一次足够，中间几拍沿用上一次的速率（历史按 dt 加权，总量不会被重复放大）
static const NSInteger kNetEveryTicks = 2;

@interface DeskProcsMonitor () {
    NSMutableDictionary<NSNumber *, PrevStat *> *_prev;
    NSMutableDictionary<NSNumber *, DeskProc *> *_last;      // 上一拍结果，排序接口直接复用
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *_prevNet;  // pid -> @[累计收, 累计发]
    double _prevNetAt;
    uint64_t _lastTickAt;
    NSInteger _tick;
    mach_timebase_info_data_t _tb;
}
@property (nonatomic, assign) NSInteger readable;
@property (nonatomic, assign) NSInteger denied;
@end

@implementation DeskProcsMonitor

- (instancetype)init {
    if ((self = [super init])) {
        _prev = [NSMutableDictionary dictionary];
        _last = [NSMutableDictionary dictionary];
        _prevNet = [NSMutableDictionary dictionary];
        mach_timebase_info(&_tb);
        if (_tb.denom == 0) { _tb.numer = 1; _tb.denom = 1; }
    }
    return self;
}

// 刻度 → 纳秒。本机实测 125/3，也就是 1 刻度 ≈ 41.667ns
- (double)nsPerTick { return (double)_tb.numer / (double)_tb.denom; }

- (NSArray<DeskProc *> *)sample {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double dt = _lastTickAt ? (now - _lastTickAt) / 1e9 : 0.0;
    _lastTickAt = now;
    _tick++;
    BOOL wantSockets = (_tick % kSocketEveryTicks) == 1;
    BOOL wantNet = (_tick % kNetEveryTicks) == 1;

    double nowSec = now / 1e9;
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *netNow = wantNet ? SampleNettop() : nil;
    double netDt = (wantNet && _prevNetAt > 0) ? nowSec - _prevNetAt : 0.0;

    // boottime 一拍只取一次。之前写在进程循环里，567 个可读进程就是 567 次 sysctl，
    // 而它和进程本身无关 —— 纯属把 10 秒一拍的采样成本抬了一个数量级。
    struct timeval boot; size_t bl = sizeof(boot);
    int bootMib[2] = { CTL_KERN, KERN_BOOTTIME };
    BOOL haveBoot = sysctl(bootMib, 2, &boot, &bl, NULL, 0) == 0;
    double nowUnix = [[NSDate date] timeIntervalSince1970];

    int cap = proc_listallpids(NULL, 0);
    if (cap <= 0) return _last.allValues;
    pid_t *pids = calloc((size_t)cap * 2 + 64, sizeof(pid_t));
    int n = proc_listallpids(pids, (int)((cap * 2 + 64) * sizeof(pid_t)));

    NSMutableDictionary<NSNumber *, DeskProc *> *fresh = [NSMutableDictionary dictionary];
    NSInteger readable = 0, denied = 0;
    double nsPerTick = [self nsPerTick];
    uint64_t ticksNow = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    double measuredEnergySum = 0;

    for (int i = 0; i < n; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct rusage_info_v6 ru;
        memset(&ru, 0, sizeof(ru));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru) != 0) { denied++; continue; }
        readable++;

        char namebuf[256] = {0};
        if (proc_name(pid, namebuf, sizeof(namebuf)) <= 0) strcpy(namebuf, "?");

        DeskProc *p = [[DeskProc alloc] init];
        p.pid = pid;
        // ri_proc_start_abstime 是 mach absolute 刻度，换算成 unix 秒要绕一下 boottime：
        // 墙上时间 = boottime + (当前绝对时刻 - 启动绝对时刻)
        if (haveBoot && ru.ri_proc_start_abstime && ru.ri_proc_start_abstime < ticksNow) {
            double agoSec = (double)(ticksNow - ru.ri_proc_start_abstime) * nsPerTick / 1e9;
            p.startedAt = (long long)(nowUnix - agoSec);
        }
        p.name = [NSString stringWithUTF8String:namebuf] ?: @"?";
        p.mem = (double)ru.ri_resident_size;

        uint64_t ticks = ru.ri_user_time + ru.ri_system_time;
        uint64_t wk = ru.ri_pkg_idle_wkups + ru.ri_interrupt_wkups;
        PrevStat *prev = _prev[@(pid)];
        if (prev && dt > 0.05) {
            double cpuNs = (double)(ticks - prev.cpuTicks) * nsPerTick;
            double wallNs = dt * 1e9;
            p.cpu = cpuNs / wallNs * 100.0;
            p.wakeups = (double)(wk - prev.wakeups) / dt;
            // 能耗直接取内核的 ri_energy_nj（纳焦）差分，换算成瓦。这是真正的功耗归因，
            // 不再是 "CPU% + 唤醒次数×系数" 的估算：UURemoteServer 每秒 1000+ 次唤醒
            // 但实测只有 0.014W，按旧公式会被顶到榜首，而真正的耗电大户（本组件自己）
            // 反而排到第六。计数器回退（重启/首次读）时这一拍按 0，不把负值印出去。
            uint64_t eDelta = ru.ri_energy_nj >= prev.energyNj ? ru.ri_energy_nj - prev.energyNj : 0;
            p.energy = (double)eDelta / 1e9 / dt;
            measuredEnergySum += p.energy;
        } else {
            p.cpu = -1; p.wakeups = -1; p.energy = -1;
        }
        if (!prev) prev = [[PrevStat alloc] init];
        prev.cpuTicks = ticks;
        prev.wakeups = wk;
        prev.energyNj = ru.ri_energy_nj;
        _prev[@(pid)] = prev;

        p.sockets = -1;
        p.netIn = -1; p.netOut = -1; p.netInRate = -1; p.netOutRate = -1;
        if (wantNet) {
            NSArray<NSNumber *> *nb = netNow[@(pid)];
            if (nb) {
                p.netIn = nb[0].doubleValue;
                p.netOut = nb[1].doubleValue;
                NSArray<NSNumber *> *pb = _prevNet[@(pid)];
                if (pb && netDt > 0.05) {
                    double inDelta = p.netIn - pb[0].doubleValue;
                    double outDelta = p.netOut - pb[1].doubleValue;
                    // 计数器回退（进程重启/接口重置）时这一拍按 0 算，不把负速率印出去
                    p.netInRate = inDelta >= 0 ? inDelta / netDt : 0;
                    p.netOutRate = outDelta >= 0 ? outDelta / netDt : 0;
                }
            }
        } else {
            // 没到 nettop 那一拍：沿用上一拍读数，别让网络榜每隔两拍闪一次「—」
            DeskProc *old = _last[@(pid)];
            if (old) {
                p.netIn = old.netIn; p.netOut = old.netOut;
                p.netInRate = old.netInRate; p.netOutRate = old.netOutRate;
            }
        }
        fresh[@(pid)] = p;
        if (wantSockets) {
            p.sockets = [self countSockets:pid];
        }
    }

    // 只在真正跑了 nettop 的那一拍更新基线；中间几拍保留旧的，
    // 否则下一次采样会把 20 秒的字节数除以 10 秒，速率虚高 2 倍。
    if (wantNet) {
        if (netNow) {
            NSMutableDictionary *kept = [NSMutableDictionary dictionary];
            for (NSNumber *k in netNow) if (fresh[k]) kept[k] = netNow[k];
            _prevNet = kept;
            _prevNetAt = nowSec;
        } else {
            // 这一拍没采到就丢掉基线：下次成功时重新起算，不拿几分钟前的差值冒充当前速率
            _prevNet = [NSMutableDictionary dictionary];
            _prevNetAt = 0;
        }
    }

    // 老系统 / 内核没给能量计数时退回旧公式，保证界面还能排出名次；
    // 只要这一拍有任何真实能量读数，就全部用真实值（空闲进程的 0 就是 0，不虚增）。
    if (measuredEnergySum <= 0) {
        for (DeskProc *p in fresh.allValues) {
            if (p.cpu < 0) continue;
            p.energy = p.cpu + p.wakeups * 0.08;
        }
    }

    // 没轮到重数的进程，沿用上一次的连接数，别让榜单数字跳成 -1
    if (!wantSockets) {
        [fresh enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, DeskProc *p, BOOL *stop) {
            DeskProc *old = _last[k];
            if (old && old.sockets >= 0) p.sockets = old.sockets;
        }];
    }

    // 清掉已经退出的进程的累计值，不然字典只进不出
    [_prev enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, PrevStat *v, BOOL *stop) {
        if (!fresh[k]) [_prev removeObjectForKey:k];
    }];
    self->_last = fresh;
    self.readable = readable;
    self.denied = denied;
    return fresh.allValues;
}

- (DeskProc *)procWithPid:(pid_t)pid {
    if (pid <= 0) return nil;
    return _last[@(pid)];
}

- (NSInteger)countSockets:(pid_t)pid {
    int sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (sz <= 0) return 0;
    int room = sz + (int)sizeof(struct proc_fdinfo) * 8;
    struct proc_fdinfo *fds = calloc(1, (size_t)room);
    int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, room);
    NSInteger count = 0;
    if (got > 0) {
        for (int i = 0; i + (int)sizeof(struct proc_fdinfo) <= got;
             i += (int)sizeof(struct proc_fdinfo)) {
            if (fds[i].proc_fdtype == PROC_FDTYPE_SOCKET) count++;
        }
    }
    free(fds);
    return count;
}

// 并列时按 pid 稳定排：只按值排的话，两个 0.0% 的进程每拍互换位置，榜单会肉眼可见地抖
static NSArray<DeskProc *> *Ranked(NSDictionary<NSNumber *, DeskProc *> *byPid,
                                   double (^key)(DeskProc *), NSInteger n) {
    NSMutableArray<DeskProc *> *all = [NSMutableArray array];
    [byPid enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, DeskProc *p, BOOL *stop) {
        if (key(p) >= 0) [all addObject:p];
    }];
    [all sortUsingComparator:^NSComparisonResult(DeskProc *a, DeskProc *b) {
        double ka = key(a), kb = key(b);
        if (ka != kb) return ka > kb ? NSOrderedAscending : NSOrderedDescending;
        return a.pid < b.pid ? NSOrderedAscending : NSOrderedDescending;
    }];
    return n >= 0 && (NSInteger)all.count > n ? [all subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] : all;
}

- (NSArray<DeskProc *> *)topByCPU:(NSInteger)n { return Ranked(_last, ^(DeskProc *p) { return p.cpu; }, n); }
- (NSArray<DeskProc *> *)topByMem:(NSInteger)n { return Ranked(_last, ^(DeskProc *p) { return p.mem; }, n); }
- (NSArray<DeskProc *> *)topByEnergy:(NSInteger)n { return Ranked(_last, ^(DeskProc *p) { return p.energy; }, n); }
- (NSArray<DeskProc *> *)topByNet:(NSInteger)n {
    return Ranked(_last, ^(DeskProc *p) {
        if (p.netInRate < 0 || p.netOutRate < 0) return -1.0;
        double total = p.netInRate + p.netOutRate;
        return total > 0 ? total : -1.0;   // 没流量的进程不占网络榜
    }, n);
}

@end
