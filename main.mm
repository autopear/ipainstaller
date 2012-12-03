//copy&move path will overwrite?


#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZipArchive/ZipArchive.h"
#import "UIDevice-Capabilities/UIDevice-Capabilities.h"

#include <dlfcn.h>

#define EXECUTABLE_VERSION @"2.0"

#define KEY_INSTALL_TYPE @"User"
#define KEY_SDKPATH "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"

#define IPA_FAILED -1
#define IPA_QUIT_NORMAL 0

typedef int (*MobileInstallationInstall)(NSString *path, NSDictionary *dict, void *na, NSString *backpath);

static NSString *SystemVersion = nil;
static int DeviceModel = 0;

static BOOL cleanInstall = NO;
static int quietInstall = 0; //0 is show all outputs, 1 is to show only errors, 2 is to show nothing
static BOOL forceInstall = NO;
static BOOL removeMetadata = NO;
static BOOL deleteFile = NO;


NSString * randomStringInLength(int len)
{
    NSString *ret = @"";
    NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (int i=0; i<len; i++)
    {
        ret = [NSString stringWithFormat:@"%@%C", ret, [letters characterAtIndex:arc4random() % [letters length]]];
    }
    return ret;
}

BOOL removeAllContentsUnderPath(NSString *path)
{
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    if ([fileMgr fileExistsAtPath:path] && ![fileMgr fileExistsAtPath:path isDirectory:NO])
    {
        NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:path error:nil];
        BOOL allRemoved = YES;
        for (int unsigned j=0; j<[dirContents count]; j++)
        {
            if (![fileMgr removeItemAtPath:[path stringByAppendingPathComponent:[dirContents objectAtIndex:j]] error:nil])
                allRemoved = NO;
        }
        if (!allRemoved)
            return NO;
    }
    return YES;
}

int main (int argc, char **argv, char **envp)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    //Get system info
    SystemVersion = [UIDevice currentDevice].systemVersion;
    NSString *deviceString = [UIDevice currentDevice].model;
    if ([deviceString isEqualToString:@"iPhone"] || [deviceString isEqualToString:@"iPod touch"])
        DeviceModel = 1;
    else if ([deviceString isEqualToString:@"iPad"])
        DeviceModel = 2;
    else
        DeviceModel = 3; //Apple TV maybe?

    //Process parameters
    NSArray *arguments = [[NSProcessInfo processInfo] arguments];

    if ([arguments count] < 1)
        return IPA_FAILED;

    NSString *executableName = [[arguments objectAtIndex:0] lastPathComponent];

    NSString *helpString = [NSString stringWithFormat:@"Usage: %@ [OPTION]... [FILE]...\n\nOptions:\n    -a  Show tool about information.\n    -c  Perform a clean install. If the application has already been installed, the saved caches, documents, settings etc. will be cleared.\n    -d  Delete IPA file(s) after installation.\n    -f  Force installation, do not check capabilities and system version. Installed application may not work properly.\n    -h  Display this usage information.\n    -q  Quiet mode, suppress all normal outputs.\n    -Q  Quieter mode, suppress all outputs including errors.\n    -r  Remove iTunesMetadata.plist.", executableName];

    NSString *aboutString = [NSString stringWithFormat:@"About %@\nInstall IPA via command line.\nVersion: %@\nAuhor: autopear", executableName, EXECUTABLE_VERSION];

    if ([arguments count] == 1)
    {
        printf("%s\n", [helpString cStringUsingEncoding:NSUTF8StringEncoding]);
        return IPA_FAILED;
    }

    NSMutableArray *ipaFiles = [[NSMutableArray alloc] initWithCapacity:0];
    NSMutableArray *filesNotFound = [[NSMutableArray alloc] initWithCapacity:0];
    BOOL noParameters = NO;
    BOOL showHelp = NO;
    BOOL showAbout = NO;
    for (unsigned int i=1; i<[arguments count]; i++)
    {
        NSString *arg = [arguments objectAtIndex:i];
        if ([arg characterAtIndex:0] == '-')
        {
            if ([arg length] < 2 || noParameters)
            {
                printf("Invalid parameters.\n");
                return IPA_FAILED;
            }

            for (unsigned int j=1; j<[arg length]; j++)
            {
                NSString *p = [arg substringWithRange:NSMakeRange(j, 1)];
                if ([p isEqualToString:@"a"])
                    showAbout = YES;
                else if ([p isEqualToString:@"c"])
                    cleanInstall = YES;
                else if ([p isEqualToString:@"d"])
                    deleteFile = YES;
                else if ([p isEqualToString:@"f"])
                    forceInstall = YES;
                else if ([p isEqualToString:@"h"])
                    showHelp = YES;
                else if ([p isEqualToString:@"q"])
                {
                    if (quietInstall != 0)
                    {
                        printf("Parameter q and Q cannot be specified at the same time.\n");
                        return IPA_FAILED;
                    }
                    quietInstall = 1;
                }
                else if ([p isEqualToString:@"Q"])
                {
                    if (quietInstall != 0)
                    {
                        printf("Parameter -q and -Q cannot be specified at the same time.\n");
                        return IPA_FAILED;
                    }
                    quietInstall = 2;
                }
                else if ([p isEqualToString:@"r"])
                    removeMetadata = YES;
                else
                {
                    printf("Invalid parameter '%s'.\n", [p cStringUsingEncoding:NSUTF8StringEncoding]);
                    return IPA_FAILED;
                }
            }
        }
        else
        {
            noParameters = YES;
            NSURL *url = [NSURL fileURLWithPath:arg isDirectory:NO];
            NSError *err;
            if (url && [url checkResourceIsReachableAndReturnError:&err])
                [ipaFiles addObject:[[url absoluteURL] path]]; //File exists
            else
                [filesNotFound addObject:arg];
            [err release];
        }
    }

    if ((showAbout && showHelp )
        || (showAbout && (cleanInstall || deleteFile || forceInstall || quietInstall != 0 || removeMetadata || ([ipaFiles count] + [filesNotFound count] > 0)))
        || (showHelp && (cleanInstall || deleteFile || forceInstall || quietInstall != 0 || removeMetadata || ([ipaFiles count] + [filesNotFound count] > 0))))
    {
        printf("Invalid parameters.\n");
        return IPA_FAILED;
    }

    if (showHelp)
    {
        printf("%s\n", [helpString cStringUsingEncoding:NSUTF8StringEncoding]);
        return IPA_FAILED;
    }

    if (showAbout)
    {
        printf("%s\n", [aboutString cStringUsingEncoding:NSUTF8StringEncoding]);
        return IPA_FAILED;
    }

    for (unsigned int i=0; i<[filesNotFound count]; i++)
    {
        if (quietInstall < 2)
            printf("File not found at path: \"%s\"'.\n", [[filesNotFound objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
    }

    if ([ipaFiles count] < 1)
    {
        if (quietInstall < 2)
            printf("Please specify any IPA file(s) to install.\n");
        return IPA_FAILED;
    }

    if (quietInstall == 0 && cleanInstall)
        printf("Clean installation enabled.\n");
    if (quietInstall == 0 && forceInstall)
        printf("Force installation enabled.\n");
    if (quietInstall == 0 && removeMetadata)
        printf("iTunesMetadata.plist will be removed after installation.\n");
    if (quietInstall == 0 && deleteFile)
    {
        if ([ipaFiles count] == 1)
            printf("\"%s\" will be deleted after installation.\n", [[[ipaFiles objectAtIndex:0] lastPathComponent] cStringUsingEncoding:NSUTF8StringEncoding]);
        else
            printf("IPA files will be deleted after installation.\n");
    }

    NSFileManager *fileMgr = [NSFileManager defaultManager];

    int successfulInstalls = 0;
    void *lib = dlopen(KEY_SDKPATH, RTLD_LAZY);
    if (lib)
    {
        MobileInstallationInstall install = (MobileInstallationInstall)dlsym(lib, "MobileInstallationInstall");
        if (install)
        {
            NSArray *filesInTemp = [fileMgr contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
            for (NSString *file in filesInTemp)
            {
                file = [NSTemporaryDirectory() stringByAppendingPathComponent:[file lastPathComponent]];
                if ([[file lastPathComponent] hasPrefix:@"com.autopear.installipa."] && ![fileMgr removeItemAtPath:file error:nil] && quietInstall < 2)
                    printf("Failed to delete \"%s\".\n", [file cStringUsingEncoding:NSUTF8StringEncoding]);
            }

            NSString *workPath = nil;
            while (YES)
            {
                workPath = [NSString stringWithFormat:@"com.autopear.installipa.%@", randomStringInLength(6)];
                workPath = [NSTemporaryDirectory() stringByAppendingPathComponent:workPath];
                if (![fileMgr fileExistsAtPath:workPath])
                    break;
            }

            //Create working directory
            NSMutableDictionary *attrMobile = [NSMutableDictionary dictionary];
            [attrMobile setObject:@"mobile" forKey:NSFileOwnerAccountName];
            [attrMobile setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];


            if(![fileMgr createDirectoryAtPath:workPath withIntermediateDirectories:YES attributes:attrMobile error:NULL] && quietInstall < 2)
            {
                printf("Failed to create workspace.\n");
                return IPA_FAILED;
            }

            NSString *installPath = [workPath stringByAppendingPathComponent:@"tmp.install.ipa"];

            for (unsigned i=0; i<[ipaFiles count]; i++)
            {
                //Before installation, make a clean workspace
                if (!removeAllContentsUnderPath(workPath))
                {
                    printf("Failed to create workspace.\n");
                    return IPA_FAILED;
                }

                NSString *ipa = [ipaFiles objectAtIndex:i];
                if (quietInstall == 0)
                    printf("Analyzing \"%s\"'.\n", [[ipa lastPathComponent] cStringUsingEncoding:NSUTF8StringEncoding]);

                BOOL isValidIPA = YES;
                BOOL hasContainer = NO;
                NSString *pathInfoPlist = nil;
                NSString *infoPath = nil;
                while (YES)
                {
                    pathInfoPlist = [workPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.Info.plist", randomStringInLength(6)]];
                    if (![fileMgr fileExistsAtPath:pathInfoPlist])
                        break;
                }

                ZipArchive *ipaArchive = [[ZipArchive alloc] init];
                if ([ipaArchive unzipOpenFile:[ipaFiles objectAtIndex:i]])
                {
                    NSMutableArray *array = [ipaArchive getZipFileContents];
                    int cnt = 0;
                    for (unsigned int j=0; j<[array count];j++)
                    {
                        NSString *name = [array objectAtIndex:j];
                        NSArray *components = [name pathComponents];
                        if ([components count] > 1 && [[components objectAtIndex:0] isEqualToString:@"Container"])
                            hasContainer = YES;
                        else
                        {
                            if ([components count] == 3 && [[components objectAtIndex:0] isEqualToString:@"Payload"] && [[components objectAtIndex:2] isEqualToString:@"Info.plist"])
                            {
                                infoPath = name;
                                cnt++;
                            }
                        }
                    }
                    if (cnt != 1)
                        isValidIPA = NO;

                    if (isValidIPA)
                    {
                        //Unzip Info.plist
                        NSData *infoData = [ipaArchive unzipFileToDataWithFilename:infoPath];
                        [infoData writeToFile:pathInfoPlist atomically:YES];
                    }
                    [ipaArchive unzipCloseFile];
                }
                else
                    isValidIPA = NO;
                [ipaArchive release];

                if (!isValidIPA)
                {
                    if (quietInstall < 2)
                        printf("\"%s\" is not a valid ipa.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                    if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                        printf("Failed to clean caches.\n");

                    continue;
                }

                NSString *appIdentifier = nil;
                NSString *appDisplayName = nil;
                NSString *appVersion = nil;
                NSString *appShortVersion = nil;
                NSString *minSysVersion = nil;
                NSMutableArray *supportedDeives = nil;
                NSMutableArray *requiredCapabilities = nil;

                NSMutableDictionary *infoDict = [[NSMutableDictionary alloc] initWithContentsOfFile:pathInfoPlist];

                if (infoDict)
                {
                    appIdentifier = [infoDict objectForKey:@"CFBundleIdentifier"];
                    appDisplayName = [infoDict objectForKey:@"CFBundleDisplayName"];
                    appVersion = [infoDict objectForKey:@"CFBundleVersion"];
                    appShortVersion = [infoDict objectForKey:@"CFBundleShortVersionString"];
                    minSysVersion = [infoDict objectForKey:@"MinimumOSVersion"];
                    supportedDeives = [infoDict objectForKey:@"UIDeviceFamily"];
                    requiredCapabilities = [infoDict objectForKey:@"UIRequiredDeviceCapabilities"];
                }
                else
                {
                    if (quietInstall < 2)
                        printf("\"%s\" is not a valid ipa.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                    if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                        printf("Failed to clean caches.\n");

                    continue;
                }

                if (!appIdentifier || !appDisplayName || !appVersion)
                {
                    if (quietInstall < 2)
                        printf("\"%s\" is not a valid ipa.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                    if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                        printf("Failed to clean caches.\n");

                    continue;
                }

                //Make a copy of extracted Info.plist
                NSString *pathOriginalInfoPlist = [NSString stringWithFormat:@"%@.original", pathInfoPlist];
                if (![fileMgr copyItemAtPath:pathInfoPlist toPath:pathOriginalInfoPlist error:nil])
                {
                   //Force installation has to be disabled.
                    if (forceInstall && quietInstall < 2)
                        printf("Force installation has to be disabled.\n");
                    forceInstall = NO;
                }

                //Check installed stats
                NSDictionary *mobileInstallationPlist = [[NSDictionary alloc] initWithContentsOfFile:@"/private/var/mobile/Library/Caches/com.apple.mobile.installation.plist"];
                NSDictionary *installedAppDict = (NSDictionary*)[(NSDictionary*)[mobileInstallationPlist objectForKey:@"User"] objectForKey:appIdentifier];

                BOOL appAlreadyInstalled = NO;
                if (installedAppDict)
                {
                    appAlreadyInstalled = YES;

                    NSString *installedVerion = [installedAppDict objectForKey:@"CFBundleVersion"];
                    NSString *installedShortVersion = [installedAppDict objectForKey:@"CFBundleShortVersionString"];

                    if (installedShortVersion != nil && appShortVersion != nil)
                    {
                        if ([installedShortVersion compare:appShortVersion] == NSOrderedDescending)
                        {
                            //Skip to avoid overriding a new version
                            if (forceInstall)
                            {
                                if (quietInstall == 0)
                                    printf("A newer version \"%s\" of \"%s\" is already installed. Will force to downgrade.%s", [installedShortVersion cStringUsingEncoding:NSUTF8StringEncoding], [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                            }
                            else
                            {
                                if (quietInstall < 2)
                                printf("A newer version \"%s\" of \"%s\" is already installed.%s", [installedShortVersion cStringUsingEncoding:NSUTF8StringEncoding], [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                                if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                                    printf("Failed to clean caches.\n");

                                continue;
                            }
                        }
                    }
                    else
                    {
                        if ([installedVerion compare:appVersion] == NSOrderedDescending)
                        {
                            //Skip to avoid overriding a new version
                            if (forceInstall)
                            {
                                if (quietInstall == 0)
                                    printf("A newer version \"%s\" of \"%s\" is already installed. Will force to downgrade.%s", [installedVerion cStringUsingEncoding:NSUTF8StringEncoding], [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                            }
                            else
                            {
                                if (quietInstall < 2)
                                    printf("A newer version \"%s\" of \"%s\" is already installed.%s", [installedVerion cStringUsingEncoding:NSUTF8StringEncoding], [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                                if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                                    printf("Failed to clean caches.\n");

                                continue;
                            }
                        }
                    }
                }

                BOOL shouldUpdateInfoPlist = NO;

                //Check device family
                BOOL supportiPhone = NO;
                BOOL supportiPad = NO;
                BOOL supportAppleTV = NO;
                for (unsigned int j=0; j<[supportedDeives count]; j++)
                {
                    int d =[[supportedDeives objectAtIndex:j] intValue];
                    if (d == 1)
                    {
                        supportiPhone = YES;
                        supportiPad = YES;
                    }
                    if (d == 2)
                        supportiPad = YES;
                    if (d == 3)
                        supportAppleTV = YES;
                }
                NSString *supportedDeivesString = nil;
                if (!supportiPhone && supportiPad && !supportAppleTV)
                    supportedDeivesString = @"iPad";
                else if (!supportiPhone && !supportiPad && supportAppleTV)
                    supportedDeivesString = @"Apple TV";
                else if (supportiPhone && supportiPad && !supportAppleTV)
                    supportedDeivesString = @"iPhone, iPod touch or iPad";
                else if (supportiPhone && !supportiPad && supportAppleTV)
                    supportedDeivesString = @"iPhone, iPod touch or Apple TV";
                else if (!supportiPhone && supportiPad && supportAppleTV)
                    supportedDeivesString = @"iPad or Apple TV";
                else if (supportiPhone && !supportiPad && !supportAppleTV)
                    supportedDeivesString = @"iPhone or iPod touch"; //Should not reach here, normally support iPhone should support iPad too
                else
                    supportedDeivesString = @"iPhone, iPod touch, iPad or Apple TV"; //Should not reach here

                if ((DeviceModel == 1 && !supportiPhone) //Not support iPhone / iPod touch
                    || (DeviceModel == 2 && !supportiPad) //Not support iPad
                    || (DeviceModel == 3 && !supportAppleTV)) //Not support Apple TV
                {
                    //Device not supported
                    if (forceInstall)
                    {
                        if (quietInstall == 0)
                            printf("\"%s\" version \"%s\" requires %s while your device is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [supportedDeivesString cStringUsingEncoding:NSUTF8StringEncoding], [deviceString cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                        [supportedDeives addObject:[NSNumber numberWithInt:DeviceModel]];
                        [infoDict setObject:[supportedDeives sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIDeviceFamily"];
                        shouldUpdateInfoPlist = YES;
                    }
                    else
                    {
                        if (quietInstall < 2)
                            printf("\"%s\" version \"%s\" requires %s while your device is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [supportedDeivesString cStringUsingEncoding:NSUTF8StringEncoding], [deviceString cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                        if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                            printf("Failed to clean caches.\n");

                        continue;
                    }
                }

                //Check minimun system requirement
                if (minSysVersion && [minSysVersion compare:SystemVersion] == NSOrderedDescending)
                {
                    //System version is less than the min required version
                    if (forceInstall)
                    {
                        if (quietInstall == 0)
                            printf("\"%s\" version \"%s\" requires iOS %s while your system is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [minSysVersion cStringUsingEncoding:NSUTF8StringEncoding], [SystemVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                        [infoDict setObject:SystemVersion forKey:@"MinimumOSVersion"];
                        shouldUpdateInfoPlist = YES;
                    }
                    else
                    {
                        if (quietInstall < 2)
                            printf("\"%s\" version \"%s\" requires iOS %s while your system is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [minSysVersion cStringUsingEncoding:NSUTF8StringEncoding], [SystemVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                        if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                            printf("Failed to clean caches.\n");

                        continue;
                    }
                }

                //Chekc capabilities
                if (requiredCapabilities)
                {
                    BOOL isCapable = YES;
                    for (unsigned int j=0; j<[requiredCapabilities count]; j++)
                    {
                        id capability = [requiredCapabilities objectAtIndex:j];
                        if ([capability isKindOfClass:[NSString class]])
                        {
                            if (![[UIDevice currentDevice] supportsCapability:capability])
                            {
                                isCapable = NO;
                                if (forceInstall)
                                {
                                    if (quietInstall == 0)
                                        printf("Your device does not support %s capability.\n", [capability cStringUsingEncoding:NSUTF8StringEncoding]);

                                    shouldUpdateInfoPlist = YES;
                                    NSDictionary *modifiedCapability = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], capability, nil];
                                    [requiredCapabilities replaceObjectAtIndex:j withObject:modifiedCapability];
                                }
                                else
                                {
                                    if (quietInstall < 2)
                                        printf("Your device does not support %s capability.\n", [capability cStringUsingEncoding:NSUTF8StringEncoding]);
                                }
                            }
                        }
                        else if ([capability isKindOfClass:[NSDictionary class]])
                        {
                            NSString *capabilityKey = [[(NSDictionary *)capability allKeys] objectAtIndex:0];
                            BOOL capabilityValue = [[(NSDictionary *)capability objectForKey:capabilityKey] boolValue];
                            //Only boolean value
                            if (capabilityValue != [[UIDevice currentDevice] supportsCapability:capabilityKey])
                            {
                                isCapable = NO;
                                if (forceInstall)
                                {
                                    if (quietInstall == 0)
                                    {
                                        if (capabilityValue) //Device does not support
                                            printf("Your device does not support %s capability.\n", [capabilityKey cStringUsingEncoding:NSUTF8StringEncoding]);
                                        else //Device support but IPA requires to be false
                                            printf("Your device conflicts with %s capability.\n", [capabilityKey cStringUsingEncoding:NSUTF8StringEncoding]);
                                    }

                                    shouldUpdateInfoPlist = YES;
                                    NSDictionary *modifiedCapability = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:!capabilityValue], capabilityKey, nil];
                                    [requiredCapabilities replaceObjectAtIndex:j withObject:modifiedCapability];
                                }
                                else
                                {
                                    if (quietInstall < 2)
                                    {
                                        if (capabilityValue) //Device does not support
                                            printf("Your device does not support %s capability.\n", [capabilityKey cStringUsingEncoding:NSUTF8StringEncoding]);
                                        else //Device support but IPA requires to be false
                                            printf("Your device conflicts with %s capability.\n", [capabilityKey cStringUsingEncoding:NSUTF8StringEncoding]);
                                    }
                                }
                            }
                        }
                        else
                        {
                            //is something else that dont know how to handle, so just skip
                        }
                    }
                    if (!isCapable)
                    {
                        if (forceInstall)
                            [infoDict setObject:[requiredCapabilities sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIRequiredDeviceCapabilities"];
                        else
                        {
                            if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                                printf("Failed to clean caches.\n");

                            if (i != [ipaFiles count] - 1) //Not the last output
                                printf("\n");

                            continue;
                        }
                    }
                }

                if (shouldUpdateInfoPlist && ![infoDict writeToFile:pathInfoPlist atomically:YES] && quietInstall < 2)
                {
                    printf("Failed to use force installation mode, \"%s\" version \"%s\" will not be installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    continue;
                }

                //Copy file to install
                if ([fileMgr fileExistsAtPath:installPath])
                {
                    if (![fileMgr removeItemAtPath:installPath error:nil])
                    {
                        if (quietInstall < 2)
                            printf("Failed to delete \"%s\".\n", [installPath cStringUsingEncoding:NSUTF8StringEncoding]);

                        if (![fileMgr removeItemAtPath:workPath error:nil] && quietInstall < 2)
                            printf("Failed to clean caches.\n");

                        return IPA_FAILED;
                    }
                }

                if (![fileMgr copyItemAtPath:ipa toPath:installPath error:nil])
                {
                    if (quietInstall < 2)
                        printf("Failed to create temporaty files.\n");

                    if (![fileMgr removeItemAtPath:workPath error:nil] && quietInstall < 2)
                        printf("Failed to clean caches.\n");

                    return IPA_FAILED;
                }

                //Modify ipa to force install
                if (shouldUpdateInfoPlist)
                {
                    BOOL shouldContinue = NO;
                    ZipArchive *tmpArchive = [[ZipArchive alloc] init];
                    if ([tmpArchive createZipFile2:installPath] && ![tmpArchive addFileToZip:pathInfoPlist newname:infoPath])
                    {
                        if (quietInstall < 2)
                            printf("Failed to use force installation mode, \"%s\" version \"%s\" will not be installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                        //Delete copied file
                        [fileMgr removeItemAtPath:installPath error:nil];

                        shouldContinue = YES;
                    }
                    [tmpArchive release];

                    //Remove extracted Info.plist
                    [fileMgr removeItemAtPath:pathInfoPlist error:nil];

                    if (shouldContinue)
                    {
                        if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                            printf("Failed to clean caches.\n");

                        continue;
                    }
                }

                if (quietInstall == 0)
                    printf("%snstalling \"%s\" version \"%s\"...\n", shouldUpdateInfoPlist ? "Force i" : "I", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
                int ret = install(installPath, [NSDictionary dictionaryWithObject:KEY_INSTALL_TYPE forKey:@"ApplicationType"], 0, installPath);
                if (ret == 0)
                {
                    //Get installation path
                    mobileInstallationPlist = [[NSDictionary alloc] initWithContentsOfFile:@"/private/var/mobile/Library/Caches/com.apple.mobile.installation.plist"];
                    installedAppDict = (NSDictionary*)[(NSDictionary*)[mobileInstallationPlist objectForKey:@"User"] objectForKey:appIdentifier];

                    if (installedAppDict)
                    {
                        NSString *installedVerion = [installedAppDict objectForKey:@"CFBundleVersion"];
                        NSString *installedShortVersion = [installedAppDict objectForKey:@"CFBundleShortVersionString"];
                        NSString *installedLocation = [installedAppDict objectForKey:@"Container"];

                        BOOL appInstalled = YES;
                        if (![installedVerion isEqualToString:appVersion])
                            appInstalled = NO;
                        if ((installedShortVersion && !appShortVersion) || (!installedShortVersion && appShortVersion))
                            appInstalled = NO;
                        if (installedShortVersion && appShortVersion && ![installedShortVersion isEqualToString:appShortVersion])
                            appInstalled = NO;

                        if (appInstalled)
                        {
                            //Recover the original Info.plist in force installation
                            if (shouldUpdateInfoPlist)
                            {
                                if ([fileMgr setAttributes:attrMobile ofItemAtPath:pathOriginalInfoPlist error:nil])
                                {
                                    NSString *pathInstalledInfoPlist = [NSString stringWithFormat:@"%@/%@/Info.plist", installedLocation, [[infoPath pathComponents] objectAtIndex:1]];
                                    if ([fileMgr fileExistsAtPath:pathInstalledInfoPlist isDirectory:NO])
                                    {
                                        if ([fileMgr removeItemAtPath:pathInstalledInfoPlist error:nil])
                                        {
                                            if ([fileMgr moveItemAtPath:pathOriginalInfoPlist toPath:pathInstalledInfoPlist error:nil])
                                            {
                                                [fileMgr setAttributes:attrMobile ofItemAtPath:pathOriginalInfoPlist error:nil];
                                                if ([fileMgr fileExistsAtPath:pathOriginalInfoPlist])
                                                    [fileMgr removeItemAtPath:pathOriginalInfoPlist error:nil];
                                            }
                                        }
                                    }
                                }
                            }

                            successfulInstalls++;
                            if (quietInstall == 0)
                                printf("%snstalled \"%s\" version \"%s\".%s", shouldUpdateInfoPlist ? "Force i" : "I", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                            BOOL tempEnableClean = NO;
                            if (!cleanInstall && hasContainer)
                            {
                                tempEnableClean = YES;
                                cleanInstall = YES;
                            }

                            //Clear documents, etc.
                            if (appAlreadyInstalled && cleanInstall)
                            {
                                if (quietInstall == 0)
                                    printf("Cleaning old contents of \"%s\"...\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);

                                NSString *dirDocuments = [installedLocation stringByAppendingPathComponent:@"Documents"];
                                NSString *dirLibrary = [installedLocation stringByAppendingPathComponent:@"Library"];
                                NSString *dirTmp = [installedLocation stringByAppendingPathComponent:@"tmp"];

                                BOOL allContentsCleaned = YES;

                                //Clear Documents
                                if ([fileMgr fileExistsAtPath:dirDocuments] && ![fileMgr fileExistsAtPath:dirDocuments isDirectory:NO])
                                {
                                    NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:dirDocuments error:nil];
                                    for (int unsigned j=0; j<[dirContents count]; j++)
                                    {
                                        if (![fileMgr removeItemAtPath:[dirDocuments stringByAppendingPathComponent:[dirContents objectAtIndex:j]] error:nil])
                                            allContentsCleaned = NO;
                                    }
                                }
                                //Clear Library
                                if ([fileMgr fileExistsAtPath:dirLibrary] && ![fileMgr fileExistsAtPath:dirLibrary isDirectory:NO])
                                {
                                    NSString *dirPreferences = [dirLibrary stringByAppendingPathComponent:@"Preferences"];
                                    NSString *dirCaches = [dirLibrary stringByAppendingPathComponent:@"Caches"];

                                    NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:dirLibrary error:nil];
                                    for (int unsigned j=0; j<[dirContents count]; j++)
                                    {
                                        NSString *fileName = [dirContents objectAtIndex:j];
                                        if ([fileName isEqualToString:@"Preferences"])
                                        {
                                            NSArray *preferencesContents = [fileMgr contentsOfDirectoryAtPath:dirPreferences error:nil];
                                            for (unsigned int k=0; k<[preferencesContents count]; k++)
                                            {
                                                NSString *preferenceFile = [preferencesContents objectAtIndex:k];
                                                if (![preferenceFile isEqualToString:@".GlobalPreferences.plist"] && ![preferenceFile isEqualToString:@"com.apple.PeoplePicker.plist"])
                                                {
                                                    if (![fileMgr removeItemAtPath:[dirPreferences stringByAppendingPathComponent:preferenceFile] error:nil])
                                                        allContentsCleaned = NO;
                                                }
                                            }
                                        }
                                        if ([fileName isEqualToString:@"Caches"])
                                        {
                                            NSArray *cachesContents = [fileMgr contentsOfDirectoryAtPath:dirCaches error:nil];
                                            for (unsigned int k=0; k<[cachesContents count]; k++)
                                            {
                                                if (![fileMgr removeItemAtPath:[dirCaches stringByAppendingPathComponent:[cachesContents objectAtIndex:k]] error:nil])
                                                    allContentsCleaned = NO;
                                            }
                                        }
                                        else
                                        {
                                            if (![fileMgr removeItemAtPath:[dirLibrary stringByAppendingPathComponent:fileName] error:nil])
                                                allContentsCleaned = NO;
                                        }
                                    }
                                }
                                //Clear tmp
                                if ([fileMgr fileExistsAtPath:dirTmp] && ![fileMgr fileExistsAtPath:dirTmp isDirectory:NO])
                                {
                                    NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:dirTmp error:nil];
                                    for (int unsigned j=0; j<[dirContents count]; j++)
                                    {
                                        if (![fileMgr removeItemAtPath:[dirTmp stringByAppendingPathComponent:[dirContents objectAtIndex:j]] error:nil])
                                            allContentsCleaned = NO;
                                    }
                                }
                                if (!allContentsCleaned && quietInstall < 2)
                                    printf("Failed to clean \"%s\"'s all contents.\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);
                            }

                            if (tempEnableClean)
                                cleanInstall = NO;

                            //Recover documents
                            if (!cleanInstall && hasContainer)
                            {
                                //The tmp ipa file is already deleted.
                                ipaArchive = [[ZipArchive alloc] init];
                                if ([ipaArchive unzipOpenFile:[ipaFiles objectAtIndex:i]])
                                {
                                    if ([ipaArchive unzipDirectoryWithName:@"Container" toPath:workPath])
                                    {
                                        NSArray *containerContents = [fileMgr contentsOfDirectoryAtPath:[workPath stringByAppendingPathComponent:@"Container"] error:nil];
                                        if ([containerContents count] > 0)
                                        {
                                            BOOL allSuccessfull = YES;
                                            for (unsigned int j=0; j<[containerContents count]; j++)
                                            {
                                                if (![fileMgr moveItemAtPath:[[workPath stringByAppendingPathComponent:@"Container"] stringByAppendingPathComponent:[containerContents objectAtIndex:j]] toPath:[installedLocation stringByAppendingPathComponent:[containerContents objectAtIndex:j]] error:nil])
                                                    allSuccessfull = NO;
                                            }
                                            if (!allSuccessfull && quietInstall < 2)
                                                printf("Cannot restore all saved documents, caches, preferences etc.\n");
                                        }
                                    }
                                    [ipaArchive unzipCloseFile];
                                }
                                [ipaArchive release];
                            }

                            //Remove metadata
                            if ([fileMgr fileExistsAtPath:[installedLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] isDirectory:NO])
                            {
                                if (quietInstall == 0)
                                    printf("Remove iTunesMetadata.plist for \"%s\".\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);
                                if (![fileMgr removeItemAtPath:[installedLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] error:nil] && quietInstall < 2)
                                    printf("Failed to remove \"%s\".\n", [[installedLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] cStringUsingEncoding:NSUTF8StringEncoding]);
                            }

                            //Set overall permission
                            system([[NSString stringWithFormat:@"chown -R mobile:mobile %@", installedLocation] cStringUsingEncoding:NSUTF8StringEncoding]);
                        }
                        else
                        {
                            if (quietInstall < 2)
                                printf("Failed to install \"%s\".%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                        }
                    }
                    else
                    {
                        if (quietInstall < 2)
                            printf("Failed to install \"%s\".%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    }
                }
                else
                {
                    NSLog(@"failed with return value : %d", ret);
                    if (quietInstall < 2)
                        printf("Failed to install \"%s\".%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                }

                //Delete tmp ipa file
                if (!removeAllContentsUnderPath(workPath))
                {
                    if (quietInstall < 2)
                        printf("Failed to delete \"%s\".\n", [installPath cStringUsingEncoding:NSUTF8StringEncoding]);

                    return IPA_FAILED;
                }

                //Delete original ipa
                if (deleteFile && [fileMgr fileExistsAtPath:ipa])
                {
                    NSError *err;
                    [fileMgr removeItemAtPath:installPath error:&err];
                    if (err && quietInstall < 2)
                        printf("Failed to delete \"%s\".\nReason: %s%s", [ipa cStringUsingEncoding:NSUTF8StringEncoding], [[err localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    [err release];
                }
            }

            if (![fileMgr removeItemAtPath:workPath error:nil] && quietInstall < 2)
                printf("Failed to clean caches.\n");
        }
    }
    dlclose(lib);

    [pool release];

    return successfulInstalls;
}
