#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define LS_LOG 1 // 诊断轮：日志开启；定版改0

static void LLog(NSString *msg) {
    if (!LS_LOG) return;
    FILE *f = fopen("/var/mobile/lockshot.log", "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[LS %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

static NSString *g_lockShortcut = @"";   // 锁屏时运行的快捷指令名（空=禁用）
static NSString *g_unlockShortcut = @""; // 解锁时运行的快捷指令名（空=禁用）
static BOOL g_screenOn = YES;            // displayStatus广播跟踪

static NSString *ConfigPath(void) {
    return @"/var/mobile/Library/Preferences/com.user.lockshot.plist";
}

static void SaveConfig(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (g_lockShortcut.length) d[@"lockShortcut"] = g_lockShortcut;
    if (g_unlockShortcut.length) d[@"unlockShortcut"] = g_unlockShortcut;
    [d writeToFile:ConfigPath() atomically:YES];
    LLog([NSString stringWithFormat:@"config saved: lock=%@ unlock=%@", g_lockShortcut, g_unlockShortcut]);
}

static void LoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:ConfigPath()];
    if (d) {
        NSString *l = d[@"lockShortcut"];
        NSString *u = d[@"unlockShortcut"];
        if (l) g_lockShortcut = [l copy];
        if (u) g_unlockShortcut = [u copy];
    }
    LLog([NSString stringWithFormat:@"config loaded: lock=%@ unlock=%@", g_lockShortcut, g_unlockShortcut]);
}

static void RunShortcut(NSString *name) {
    if (name.length == 0) return;
    NSString *enc = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"shortcuts://run-shortcut?name=%@", enc];
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u) { LLog(@"bad shortcut url"); return; }
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:^(BOOL ok) {
        LLog([NSString stringWithFormat:@"run shortcut '%@': %@", name, ok ? @"ok" : @"failed"]);
    }];
}

static void ToggleScreen(void) {
    g_screenOn = !g_screenOn;
    LLog(g_screenOn ? @"screen ON" : @"screen OFF");
}

// 锁屏/解锁判定：lockstate事件 → 0.5秒后看屏幕（灭=锁屏，亮=解锁）
static void LSStateChanged(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_screenOn) {
            // 解锁动作
            if (g_unlockShortcut.length) { LLog(@"unlock -> run shortcut"); RunShortcut(g_unlockShortcut); }
            return;
        }
        // 锁屏动作
        if (g_lockShortcut.length) { LLog(@"lock -> run shortcut"); RunShortcut(g_lockShortcut); }
    });
}

static void StartServer(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int sfd = socket(AF_INET, SOCK_STREAM, 0);
        if (sfd < 0) { LLog(@"socket failed"); return; }
        int opt = 1;
        setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(18091); // 独立端口，与散热器18090互不干扰
        if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { LLog(@"bind failed"); close(sfd); return; }
        if (listen(sfd, 4) < 0) { LLog(@"listen failed"); close(sfd); return; }
        LLog(@"http server ready :18091");
        char buf[1024];
        for (;;) {
            int cfd = accept(sfd, NULL, NULL);
            if (cfd < 0) continue;
            memset(buf, 0, sizeof(buf));
            read(cfd, buf, sizeof(buf) - 1);
            LLog([NSString stringWithUTF8String:buf]);
            const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
            if (strstr(buf, "/set?")) {
                char params[512] = {0};
                const char *q = strstr(buf, "/set?") + strlen("/set?");
                sscanf(q, "%511[^ ]", params);
                NSString *qs = [NSString stringWithUTF8String:params];
                NSMutableDictionary *kv = [NSMutableDictionary dictionary];
                for (NSString *pair in [qs componentsSeparatedByString:@"&"]) {
                    NSRange eq = [pair rangeOfString:@"="];
                    if (eq.location == NSNotFound || eq.location == 0) continue;
                    NSString *k = [pair substringToIndex:eq.location];
                    NSString *v = [[pair substringFromIndex:eq.location + 1] stringByRemovingPercentEncoding];
                    if (v) kv[k] = v;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (kv[@"lock"]) g_lockShortcut = [kv[@"lock"] copy];
                    if (kv[@"unlock"]) g_unlockShortcut = [kv[@"unlock"] copy];
                    if (kv[@"clear"]) { g_lockShortcut = @""; g_unlockShortcut = @""; }
                    SaveConfig();
                });
            } else if (strstr(buf, "/clear")) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    g_lockShortcut = @""; g_unlockShortcut = @"";
                    SaveConfig();
                });
            } else if (strstr(buf, "/test?which=lock")) {
                dispatch_async(dispatch_get_main_queue(), ^{ RunShortcut(g_lockShortcut); });
            } else if (strstr(buf, "/test?which=unlock")) {
                dispatch_async(dispatch_get_main_queue(), ^{ RunShortcut(g_unlockShortcut); });
            }
            write(cfd, resp, strlen(resp));
            close(cfd);
        }
    });
}

// 快捷指令App侦察模式：dump触发器/自动化相关类名（原生触发器选项的研发情报）
static void StartShortcutsRecon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FILE *f = fopen("/var/mobile/lockshot_recon.log", "w");
        if (!f) return;
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        unsigned int hits = 0;
        for (unsigned int i = 0; i < count; i++) {
            const char *nm = class_getName(classes[i]);
            if (strstr(nm, "Trigger") || strstr(nm, "Automation") || strstr(nm, "Picker")) {
                fprintf(f, "%s\n", nm);
                hits++;
            }
        }
        fprintf(f, "--- total classes: %u, hits: %u\n", count, hits);
        free(classes);
        fclose(f);
    });
}

%ctor {
    %init;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.shortcuts"]) { StartShortcutsRecon(); return; } // 侦察模式
    if (![bid isEqualToString:@"com.apple.springboard"]) return; // 只在SpringBoard运行主逻辑
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LLog(@"lockshot loaded");
        LoadConfig();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)LSStateChanged, CFSTR("com.apple.springboard.lockstate"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)ToggleScreen, CFSTR("com.apple.iokit.hid.displayStatus"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        StartServer();
        LLog(@"armed: lock/unlock shortcut trigger");
    });
}
