//
//  SettingsPageViewController.m
//  zxtouch
//
//  Created by Jason on 2021/1/18.
//

#import "SettingsPageViewController.h"
#import "ScriptListTableCell.h"
#import "TouchIndicatorConfigurationViewController.h"
#import "ActivatorConfigurationViewController.h"
#import "Util.h"
#import "Socket.h"

#import "TableViewCellWithSwitch.h"
#import "TableViewCellWithSlider.h"
#import "TableViewCellWithEntry.h"

#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerStreamedResponse.h"

#import "libactivator.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import "Config.h"
#import "ConfigManager.h"

#define SETTING_CELL_SWITCH 0
#define SETTING_CELL_ENTRY 1

static const NSUInteger kZXTouchWebServerPort = 8080;
static const int kZXTouchTaskScreenshot = 29;
static const int kZXTouchScreenshotActionCapture = 1;
static NSString *const kZXTouchWebServerSnapshotDirectory = @"/var/mobile/Library/ZXTouch/websnapshots";
static NSString *const kZXTouchWebServerStreamBoundary = @"zxtouch-frame";


@interface SettingsPageViewController ()
{
    GCDWebServer* _webServer;
}
@end

@implementation SettingsPageViewController
{
    NSArray *sections;
    NSArray<NSArray*> *cellsForEachSection;
    ConfigManager *configManager;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    sections = @[NSLocalizedString(@"remoteManagement", nil), NSLocalizedString(@"control", nil), NSLocalizedString(@"script", nil)]; // , @"HELP"
    configManager = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];
    BOOL doubleClickPopup = YES;
    if ([configManager getValueFromKey:@"double_click_volume_show_popup"])
    {
        doubleClickPopup = [[configManager getValueFromKey:@"double_click_volume_show_popup"] boolValue];
    }
    
    BOOL switchAppBeforeRunScript = YES;
    if ([configManager getValueFromKey:@"switch_app_before_run_script"])
    {
        switchAppBeforeRunScript = [[configManager getValueFromKey:@"switch_app_before_run_script"] boolValue];
    }
    
    // [@{"type": ?, @"title": ?, @"content": ?, ... more depends on the cell type}]
    //
    cellsForEachSection = @[
        @[
            @{@"type": @(SETTING_CELL_SWITCH), @"title": NSLocalizedString(@"webServer", nil), @"switch_click_handler": NSStringFromSelector(@selector(handleWebServerWithSwitchCellInstance:)), @"switch_init_status": @(NO)}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Activator", @"secondary_title": @"", @"row_click_handler": NSStringFromSelector(@selector(handleActivatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": NSLocalizedString(@"configActivatorEvents", nil), @"secondary_title": @"", @"row_click_handler": NSStringFromSelector(@selector(handleConfigActivatorEventsWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": NSLocalizedString(@"touchIndicator", nil), @"secondary_title": @"", @"row_click_handler": NSStringFromSelector(@selector(handleTouchIndicatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": NSLocalizedString(@"doubleClickShowPopup", nil), @"switch_click_handler": NSStringFromSelector(@selector(handlePopupWindowDoubleClick:)), @"switch_init_status": @(doubleClickPopup)}
        ],
        @[
            @{@"type": @(SETTING_CELL_SWITCH), @"title": NSLocalizedString(@"switchAppBeforePlaying", nil), @"switch_click_handler": NSStringFromSelector(@selector(handleSwitchAppBeforePlaying:)), @"switch_init_status": @(switchAppBeforeRunScript)}
        ]
    ];
     
    UINib *SwitchCellNib = [UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil];
    [_tableView registerNib:SwitchCellNib forCellReuseIdentifier:@"SwitchCell"];

    UINib *entryCellNib = [UINib nibWithNibName:@"TableViewCellWithEntry" bundle:nil];
    [_tableView registerNib:entryCellNib forCellReuseIdentifier:@"EntryCell"];
    
    _tableView.backgroundColor = [UIColor colorWithRed:243/255.0f green:242/255.0f blue:248/255.0f alpha:1.0f];
    _tableView.tableFooterView = [[UIView alloc] init];
}

- (void)handleSwitchAppBeforePlaying:(UISwitch*)s {
    if ([s isOn])
    {
        [configManager updateKey:@"switch_app_before_run_script" forValue:@(true)];
        [configManager save];
    }
    else
    {
        [configManager updateKey:@"switch_app_before_run_script" forValue:@(false)];
        [configManager save];
    }
    
    Socket *socket = [[Socket alloc] init];
    [socket connect:@"127.0.0.1" byPort:6000];
    [socket send:@"902"];
    [socket recv:1024];
    [socket close];
}

- (void)handlePopupWindowDoubleClick:(UISwitch*)s {
    if ([s isOn])
    {
        [configManager updateKey:@"double_click_volume_show_popup" forValue:@(true)];
        [configManager save];
    }
    else
    {
        [configManager updateKey:@"double_click_volume_show_popup" forValue:@(false)];
        [configManager save];
    }
    Socket *socket = [[Socket alloc] init];
    [socket connect:@"127.0.0.1" byPort:6000];
    [socket send:@"901"];
    [socket recv:1024];
    [socket close];
}

- (void)handleConfigActivatorEventsWithEntryCellInstance:(TableViewCellWithEntry*)cell {
    dlopen("/usr/lib/libactivator.dylib", RTLD_LAZY);
    Class ac = objc_getClass("LAActivator");
    if (ac) {
        
        UIStoryboard *sb = [UIStoryboard storyboardWithName:@"SettingPages" bundle:nil];
        ActivatorConfigurationViewController *vc = [sb instantiateViewControllerWithIdentifier:@"ActivatorConfigurationViewController"];
        vc.title = NSLocalizedString(@"configActivatorEvents", nil);
        [self.navigationController pushViewController:vc animated:YES];
    }
    else
    {
        [Util showAlertBoxWithOneOption:self title:@"Error" message:NSLocalizedString(@"activatorNeedInstall", nil) buttonString:@"OK"];
    }
}

- (void)handleWebServerWithSwitchCellInstance:(UISwitch*)s {
    if ([s isOn])
    {
        if (_webServer && _webServer.isRunning)
        {
            return;
        }

        _webServer = [[GCDWebServer alloc] init];

        __weak typeof(self) weakSelf = self;
        [_webServer addHandlerForMethod:@"GET"
                                   path:@"/"
                           requestClass:[GCDWebServerRequest class]
                           processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            NSString *html = [NSString stringWithFormat:@"<html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" /></head><body style=\"margin:0;background:#000\"><img src=\"/stream\" style=\"width:100%%;height:auto;display:block;\" /></body></html>"];
            return [GCDWebServerDataResponse responseWithHTML:html];
        }];

        [_webServer addHandlerForMethod:@"GET"
                                   path:@"/snapshot"
                           requestClass:[GCDWebServerRequest class]
                           processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            NSError *error = nil;
            NSData *snapshotData = [strongSelf captureScreenshotPNGWithError:&error];
            if (!snapshotData)
            {
                return [GCDWebServerDataResponse responseWithStatusCode:500];
            }
            GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithData:snapshotData contentType:@"image/png"];
            response.cacheControlMaxAge = 0;
            return response;
        }];

        [_webServer addHandlerForMethod:@"GET"
                                   path:@"/stream"
                           requestClass:[GCDWebServerRequest class]
                           processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            GCDWebServerStreamedResponse *response = [GCDWebServerStreamedResponse responseWithContentType:[NSString stringWithFormat:@"multipart/x-mixed-replace; boundary=%@", kZXTouchWebServerStreamBoundary]
                                                                                                 asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf)
                    {
                        completionBlock(nil, nil);
                        return;
                    }
                    NSError *streamError = nil;
                    NSData *snapshotData = [strongSelf captureScreenshotPNGWithError:&streamError];
                    if (!snapshotData)
                    {
                        completionBlock(nil, streamError);
                        return;
                    }
                    NSMutableData *frameData = [NSMutableData data];
                    NSString *header = [NSString stringWithFormat:@"--%@\r\nContent-Type: image/png\r\nContent-Length: %lu\r\n\r\n", kZXTouchWebServerStreamBoundary, (unsigned long)snapshotData.length];
                    [frameData appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
                    [frameData appendData:snapshotData];
                    [frameData appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
                    completionBlock(frameData, nil);
                });
            }];
            response.cacheControlMaxAge = 0;
            return response;
        }];

        if (![_webServer startWithPort:kZXTouchWebServerPort bonjourName:nil])
        {
            [Util showAlertBoxWithOneOption:self title:@"ZXTouch" message:@"Failed to start web server." buttonString:@"OK"];
            [s setOn:NO];
            _webServer = nil;
            return;
        }

        NSString *urlString = _webServer.serverURL.absoluteString ?: [NSString stringWithFormat:@"http://127.0.0.1:%lu/", (unsigned long)kZXTouchWebServerPort];
        [Util showAlertBoxWithOneOption:self title:@"ZXTouch" message:[NSString stringWithFormat:@"Web server started: %@", urlString] buttonString:@"OK"];
    }
    else
    {
        if (_webServer)
        {
            [_webServer stop];
            _webServer = nil;
        }
    }
}

- (NSData *)captureScreenshotPNGWithError:(NSError **)error
{
    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:kZXTouchWebServerSnapshotDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&directoryError];
    if (directoryError)
    {
        if (error)
        {
            *error = directoryError;
        }
        return nil;
    }

    NSString *fileName = [NSString stringWithFormat:@"snapshot-%@.png", [[NSUUID UUID] UUIDString]];
    NSString *filePath = [kZXTouchWebServerSnapshotDirectory stringByAppendingPathComponent:fileName];

    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] != 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouch" code:500 userInfo:@{NSLocalizedDescriptionKey: @"Failed to connect to ZXTouch socket."}];
        }
        return nil;
    }

    NSString *command = [NSString stringWithFormat:@"%02d%d;;%@\r\n", kZXTouchTaskScreenshot, kZXTouchScreenshotActionCapture, filePath];
    [socket send:command];
    NSString *response = [socket recv:1024];
    [socket close];

    if (![response hasPrefix:@"0"])
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouch" code:500 userInfo:@{NSLocalizedDescriptionKey: @"ZXTouch screenshot task failed."}];
        }
        return nil;
    }

    NSArray *parts = [response componentsSeparatedByString:@";;"];
    NSString *returnedPath = nil;
    if (parts.count >= 2)
    {
        returnedPath = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    NSString *finalPath = returnedPath.length > 0 ? returnedPath : filePath;
    NSData *snapshotData = [NSData dataWithContentsOfFile:finalPath options:0 error:error];
    [[NSFileManager defaultManager] removeItemAtPath:finalPath error:nil];
    return snapshotData;
}

- (void)handleActivatorWithEntryCellInstance:(TableViewCellWithEntry*)cell {
    dlopen("/usr/lib/libactivator.dylib", RTLD_LAZY);
    Class la = objc_getClass("LAListenerSettingsViewController");
    if (la) {
        LAListenerSettingsViewController *vc = [[la alloc] init];
        [vc setListenerName:@"com.zjx.zxtouch"];
        vc.title = @"Assign Activator Events";
        [self.navigationController pushViewController:vc animated:YES];
    }
    else
    {
        [Util showAlertBoxWithOneOption:self title:@"Error" message:NSLocalizedString(@"activatorNeedInstall", nil) buttonString:@"OK"];
    }
}

- (void)handleTouchIndicatorWithEntryCellInstance:(TableViewCellWithEntry*)cell {
    if ([cell isSelected])
    {
        UIStoryboard *sb = [UIStoryboard storyboardWithName:@"SettingPages" bundle:nil];
        TouchIndicatorConfigurationViewController *touchIndicatorConfigurationViewController = [sb instantiateViewControllerWithIdentifier:@"TouchIndicatorConfigurationPage"];
        [self.navigationController pushViewController:touchIndicatorConfigurationViewController animated:YES];
        //[self.navigationController setTitle:@"Touch Indicator"];
    }

}


//配置每个section(段）有多少row（行） cell
//默认只有一个section
-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    return cellsForEachSection[section].count;
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return sections.count;
}

//每行显示什么东西
-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{

    UITableViewCell *result;
    

    NSInteger indexInCurrentSection = indexPath.row;

    
    NSArray* cellList = cellsForEachSection[indexPath.section];

    NSDictionary *cellInfo = cellList[indexInCurrentSection];
    if ([cellInfo[@"type"] intValue] == SETTING_CELL_SWITCH)
    {
        static NSString *cellID = @"SwitchCell";

        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        
        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            cell = [[TableViewCellWithSwitch alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        }
        
        cell.title.text = cellInfo[@"title"];
        [cell.switchBtn addTarget:self action:NSSelectorFromString(cellInfo[@"switch_click_handler"]) forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn setOn:[cellInfo[@"switch_init_status"] boolValue]];
        
        result = cell;
    }
    else if ([cellInfo[@"type"] intValue] == SETTING_CELL_ENTRY)
    {
        static NSString *cellID = @"EntryCell";

        TableViewCellWithEntry *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        
        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            NSLog(@"create a setting cell switch");
            cell = [[TableViewCellWithEntry alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        }
        
        cell.title.text = cellInfo[@"title"];
        cell.subTitle.text = cellInfo[@"secondary_title"];
        cell.clickHandler = cellInfo[@"row_click_handler"];
        
        result = cell;
    }
    
    
    return result;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    UITableViewCell *cell = [_tableView cellForRowAtIndexPath:indexPath];
    if ([cell isKindOfClass:[TableViewCellWithEntry class]])
    {
        TableViewCellWithEntry *entry = (TableViewCellWithEntry*)cell;
        [self performSelector:NSSelectorFromString(entry.clickHandler) withObject:entry];
    }
}

// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {

}


- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *resultView = [[UIView alloc] init];
    //view.backgroundColor = [UIColor greenColor];
    
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont boldSystemFontOfSize:13];
    title.textColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.7];

    title.text = sections[section];

    
    [resultView addSubview:title];
    
    [[title.leftAnchor constraintEqualToAnchor:resultView.leftAnchor constant:10] setActive:YES];
    [[title.bottomAnchor constraintEqualToAnchor:resultView.bottomAnchor constant:-5] setActive:YES];

    return resultView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 60;
}
/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
