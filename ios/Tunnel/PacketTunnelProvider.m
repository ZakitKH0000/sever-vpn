#import "PacketTunnelProvider.h"
#import <Security/Security.h>
#import <net/if.h>
#import <sys/socket.h>
#import <string.h>
#if SEVER_XRAY
@import LibXray;
#else
@import OpenVPNAdapter;
#endif

static NSError *SeverTunnelError(NSString *message) {
    return [NSError errorWithDomain:@"dev.sever.tunnel" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

#if SEVER_XRAY
@interface PacketTunnelProvider ()
#else
@interface PacketTunnelProvider () <OpenVPNAdapterDelegate>
#endif
@property(nonatomic, strong) dispatch_queue_t stateQueue;
@property(nonatomic, copy) void (^startHandler)(NSError *);
#if !SEVER_XRAY
@property(nonatomic, strong) OpenVPNAdapter *adapter;
#endif
@property(nonatomic, copy) NSArray<NSDictionary *> *candidates;
@property(nonatomic) NSUInteger candidateIndex;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL hasConnected;
@property(nonatomic) BOOL xrayRunning;
@property(nonatomic, copy) dispatch_block_t deadline;
@end

@implementation PacketTunnelProvider

- (instancetype)init {
    self = [super init];
    if (self) _stateQueue = dispatch_queue_create("dev.sever.tunnel.lifecycle", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)finishStart:(NSError *)error {
    if (self.startHandler) {
        void (^handler)(NSError *) = self.startHandler;
        self.startHandler = nil;
        handler(error);
    }
}

- (void)cancelDeadline {
    if (self.deadline) { dispatch_block_cancel(self.deadline); self.deadline = nil; }
}

- (void)startTunnelWithOptions:(NSDictionary<NSString *,NSObject *> *)options
            completionHandler:(void (^)(NSError *))completionHandler {
    dispatch_async(self.stateQueue, ^{
        self.startHandler = completionHandler;
        self.stopping = NO; self.hasConnected = NO; self.candidateIndex = 0;
        NETunnelProviderProtocol *configuration = (NETunnelProviderProtocol *)self.protocolConfiguration;
        NSData *reference = configuration.passwordReference;
        if (!reference) { [self finishStart:SeverTunnelError(@"Нет ссылки на конфигурацию")]; return; }
        NSDictionary *query = @{(__bridge id)kSecValuePersistentRef: reference,
                                (__bridge id)kSecReturnData: @YES,
                                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status != errSecSuccess || !result) {
            [self finishStart:SeverTunnelError(@"Не удалось прочитать конфигурацию из Keychain. Проверьте подпись")]; return;
        }
        NSData *data = CFBridgingRelease(result);
        if (![data isKindOfClass:NSData.class] || data.length > 512 * 1024) {
            [self finishStart:SeverTunnelError(@"Некорректный размер конфигурации")]; return;
        }
        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"version"] isEqual:@1] ||
            ![envelope[@"candidates"] isKindOfClass:NSArray.class] || [envelope[@"candidates"] count] == 0 ||
            [envelope[@"candidates"] count] > 3) {
            [self finishStart:SeverTunnelError(@"Неизвестный формат конфигурации")]; return;
        }
        self.candidates = envelope[@"candidates"];
        for (id candidate in self.candidates) {
            if (![candidate isKindOfClass:NSDictionary.class] || ![candidate[@"configuration"] isKindOfClass:NSString.class]) {
                [self finishStart:SeverTunnelError(@"Повреждён профиль подключения")]; return;
            }
        }
#if SEVER_XRAY
        if ([envelope[@"engine"] isEqual:@"xray"]) [self startXray:self.candidates.firstObject[@"configuration"]];
#else
        if ([envelope[@"engine"] isEqual:@"openvpn"]) [self startNextOpenVPN];
#endif
        else [self finishStart:SeverTunnelError(@"Профиль не соответствует VPN-расширению")];
    });
}

- (NEPacketTunnelNetworkSettings *)strictNetworkSettings {
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"127.0.0.1"];
    settings.IPv4Settings = [[NEIPv4Settings alloc] initWithAddresses:@[@"172.19.0.1"] subnetMasks:@[@"255.255.255.252"]];
    settings.IPv4Settings.includedRoutes = @[[NEIPv4Route defaultRoute]];
    settings.IPv4Settings.excludedRoutes = @[];
    settings.IPv6Settings = [[NEIPv6Settings alloc] initWithAddresses:@[@"fd00:7365:7665::1"] networkPrefixLengths:@[@64]];
    settings.IPv6Settings.includedRoutes = @[[NEIPv6Route defaultRoute]];
    settings.IPv6Settings.excludedRoutes = @[];
    settings.DNSSettings = [[NEDNSSettings alloc] initWithServers:@[@"1.1.1.1", @"8.8.8.8"]];
    settings.DNSSettings.matchDomains = @[@""];
    settings.MTU = @1280;
    return settings;
}

#if SEVER_XRAY
- (NSDictionary *)invokeXray:(NSString *)method payload:(NSDictionary *)payload {
    NSDictionary *request = @{@"apiVersion": @3, @"method": method, @"payload": payload ?: @{}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (!data) return nil;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    char *response = CGoInvoke((char *)json.UTF8String);
    if (!response) return nil;
    NSData *responseData = [[NSString stringWithUTF8String:response] dataUsingEncoding:NSUTF8StringEncoding];
    CGoFree(response);
    if (!responseData) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

- (void)startXray:(NSString *)raw {
    [self setTunnelNetworkSettings:[self strictNetworkSettings] completionHandler:^(NSError *error) {
        dispatch_async(self.stateQueue, ^{
            if (self.stopping) return;
            if (error) { [self finishStart:SeverTunnelError(@"iOS не применила настройки туннеля")]; return; }
            int tunnelFD = -1;
            char foundName[IFNAMSIZ] = {0};
            // Same utun discovery mechanism documented by XTLS/Xray-core/proxy/tun.
            for (int fd = 0; fd < 1024; fd++) {
                char name[IFNAMSIZ] = {0}; socklen_t length = sizeof(name);
                if (getsockopt(fd, 2, 2, name, &length) == 0 && strncmp(name, "utun", 4) == 0) {
                    tunnelFD = fd; memcpy(foundName, name, sizeof(foundName)); break;
                }
            }
            if (tunnelFD < 0) { [self finishStart:SeverTunnelError(@"iOS не предоставила интерфейс VPN")]; return; }
            NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
            NSMutableDictionary *config = [[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] mutableCopy];
            if (![config isKindOfClass:NSMutableDictionary.class]) { [self finishStart:SeverTunnelError(@"Некорректная конфигурация Xray")]; return; }
            config[@"env"] = @{@"xray.tun.fd": [NSString stringWithFormat:@"%d", tunnelFD]};
            NSString *interfaceName = [[NSString alloc] initWithBytes:foundName length:strnlen(foundName, IFNAMSIZ) encoding:NSUTF8StringEncoding];
            config[@"inbounds"] = @[@{@"tag": @"sever-tun", @"protocol": @"tun", @"port": @0,
                                     @"settings": @{@"name": interfaceName ?: @"utun", @"mtu": @1280}}];
            config[@"log"] = @{@"loglevel": @"none"};
            NSData *finalData = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
            NSString *finalJSON = [[NSString alloc] initWithData:finalData encoding:NSUTF8StringEncoding];
            NSDictionary *reply = [self invokeXray:@"runXray" payload:@{@"xrayJson": finalJSON ?: @""}];
            if (![reply[@"success"] boolValue]) { [self finishStart:SeverTunnelError(@"Xray не смог запустить этот профиль")]; return; }
            self.xrayRunning = YES; self.hasConnected = YES;
            [self finishStart:nil];
        });
    }];
}

#else
- (void)armOpenVPNDeadline:(OpenVPNAdapter *)adapter {
    [self cancelDeadline];
    __weak typeof(self) weakSelf = self;
    dispatch_block_t block = dispatch_block_create(0, ^{
        typeof(self) self = weakSelf;
        if (self && !self.stopping && self.adapter == adapter) [self startNextOpenVPN];
    });
    self.deadline = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), self.stateQueue, block);
}

- (void)startNextOpenVPN {
    if (self.stopping) return;
    [self cancelDeadline];
    self.adapter.delegate = nil;
    [self.adapter disconnect]; self.adapter = nil;
    if (self.candidateIndex >= self.candidates.count) {
        if (!self.hasConnected) { [self finishStart:SeverTunnelError(@"Сохранённые серверы недоступны. Обновите каталог")]; return; }
        self.reasserting = YES;
        self.candidateIndex = 0;
        __weak typeof(self) weakSelf = self;
        dispatch_block_t retry = dispatch_block_create(0, ^{ if (!weakSelf.stopping) [weakSelf startNextOpenVPN]; });
        self.deadline = retry;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), self.stateQueue, retry);
        return;
    }
    NSDictionary *candidate = self.candidates[self.candidateIndex++];
    NSString *raw = candidate[@"configuration"];
    OpenVPNAdapter *adapter = [[OpenVPNAdapter alloc] init];
    self.adapter = adapter; adapter.delegate = self;
    OpenVPNConfiguration *configuration = [[OpenVPNConfiguration alloc] init];
    configuration.fileContent = [raw dataUsingEncoding:NSUTF8StringEncoding];
    configuration.tunPersist = YES;
    configuration.connectionTimeout = 25;
    configuration.disableClientCert = [raw rangeOfString:@"<cert>" options:NSCaseInsensitiveSearch].location == NSNotFound;
    NSError *error = nil;
    OpenVPNConfigurationEvaluation *evaluation = [adapter applyConfiguration:configuration error:&error];
    if (error || !evaluation) { [self startNextOpenVPN]; return; }
    if (!evaluation.autologin) {
        if (![candidate[@"username"] isKindOfClass:NSString.class] || ![candidate[@"password"] isKindOfClass:NSString.class]) {
            [self finishStart:SeverTunnelError(@"Профиль требует логин и пароль. В этой версии поддержана авторизация каталога VPN Gate")]; return;
        }
        OpenVPNCredentials *credentials = [[OpenVPNCredentials alloc] init];
        credentials.username = candidate[@"username"]; credentials.password = candidate[@"password"];
        if (![adapter provideCredentials:credentials error:&error] || error) { [self startNextOpenVPN]; return; }
    }
    [self armOpenVPNDeadline:adapter];
    [adapter connectUsingPacketFlow:(id<OpenVPNAdapterPacketFlow>)self.packetFlow];
}

- (void)openVPNAdapter:(OpenVPNAdapter *)adapter configureTunnelWithNetworkSettings:(NEPacketTunnelNetworkSettings *)settings
    completionHandler:(void (^)(NSError *))completionHandler {
    dispatch_async(self.stateQueue, ^{
        if (self.stopping || adapter != self.adapter) { completionHandler(SeverTunnelError(@"Подключение отменено")); return; }
        // Keep the existing routes during reconnect; never deliberately fall back to direct networking.
        if (!settings) { completionHandler(nil); return; }
        if (!settings.IPv4Settings) { completionHandler(SeverTunnelError(@"Сервер не выдал IPv4-настройки")); return; }
        settings.IPv4Settings.includedRoutes = @[[NEIPv4Route defaultRoute]];
        settings.IPv4Settings.excludedRoutes = @[];
        if (!settings.IPv6Settings) settings.IPv6Settings = [self strictNetworkSettings].IPv6Settings;
        settings.IPv6Settings.includedRoutes = @[[NEIPv6Route defaultRoute]];
        settings.IPv6Settings.excludedRoutes = @[];
        if (!settings.DNSSettings || settings.DNSSettings.servers.count == 0) settings.DNSSettings = [self strictNetworkSettings].DNSSettings;
        settings.DNSSettings.matchDomains = @[@""];
        [self setTunnelNetworkSettings:settings completionHandler:completionHandler];
    });
}

- (void)openVPNAdapter:(OpenVPNAdapter *)adapter handleEvent:(OpenVPNAdapterEvent)event message:(NSString *)message {
    dispatch_async(self.stateQueue, ^{
        if (self.stopping || adapter != self.adapter) return;
        switch (event) {
            case OpenVPNAdapterEventConnected:
                [self cancelDeadline]; self.hasConnected = YES; self.reasserting = NO; [self finishStart:nil]; break;
            case OpenVPNAdapterEventReconnecting:
                self.reasserting = YES; [self armOpenVPNDeadline:adapter]; break;
            case OpenVPNAdapterEventDisconnected:
                [self startNextOpenVPN]; break;
            default: break;
        }
    });
}

- (void)openVPNAdapter:(OpenVPNAdapter *)adapter handleError:(NSError *)error {
    dispatch_async(self.stateQueue, ^{ if (!self.stopping && self.adapter == adapter) [self startNextOpenVPN]; });
}
#endif

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    dispatch_async(self.stateQueue, ^{
        self.stopping = YES; [self cancelDeadline];
#if SEVER_XRAY
        if (self.xrayRunning) { [self invokeXray:@"stopXray" payload:@{}]; self.xrayRunning = NO; }
#else
        self.adapter.delegate = nil; [self.adapter disconnect]; self.adapter = nil;
#endif
        [self finishStart:SeverTunnelError(@"Подключение остановлено")];
        self.candidates = nil;
        completionHandler();
    });
}

@end
