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
static BOOL notRestore = NO;

static BOOL isFile = NO;
static BOOL isDirectory = YES;

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
    if ([fileMgr fileExistsAtPath:path isDirectory:&isFile])
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
/*
void setPermissionsForPath(NSString *path, NSString *executablePath)
{
    NSFileManager *fileMgr = [NSFileManager defaultManager];

    //Set root folder's attributes
    NSDictionary *directoryAttributes = [fileMgr attributesOfItemAtPath:path error:nil];
    NSMutableDictionary *defaultDirectoryAttributes = [directoryAttributes mutableCopy];//[NSMutableDictionary dictionaryWithCapacity:[[directoryAttributes allKeys] count]];
    
    
    
    
    for (NSString *key in [directoryAttributes allKeys])
    {
        if ([key isEqualToString:NSFileOwnerAccountName] || [key isEqualToString:NSFileGroupOwnerAccountName])
            [defaultDirectoryAttributes setObject:@"mobile" forkey:key];
        else if ([key isEqualToString:NSFilePosixPermissions])
            [defaultDirectoryAttributes setObject:[NSNumber numberWithInt:0755] forKey:key];
        else
            [defaultDirectoryAttributes setObject:[directoryAttributes objectForKey:key] forKey:key];
    }
    [fileMgr setAttributes:defaultDirectoryAttributes ofItemAtPath:path error:nil];

    for (NSString *subPath in [fileMgr contentsOfDirectoryAtPath:path error:nil])
    {
        NSDictionary *attributes = [fileMgr attributesOfItemAtPath:[path stringByAppendingPathComponent:subPath] error:nil];
        if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular])
        {
            NSMutableDictionary *defaultAttributes = [NSMutableDictionary dictionaryWithCapacity:[[directoryAttributes allKeys] count]];
            for (NSString *key in [attributes allKeys])
            {
                if ([key isEqualToString:NSFileOwnerAccountName] || [key isEqualToString:NSFileGroupOwnerAccountName])
                    [defaultAttributes setObject:@"mobile" forkey:key];
                else if ([key isEqualToString:NSFilePosixPermissions])
                    [defaultAttributes setObject:[NSNumber numberWithInt:([[path stringByAppendingPathComponent:subPath] isEqualToString:executablePath] ? 0755 : 0644)] forKey:key];
                else
                    [defaultAttributes setObject:[attributes objectForKey:key] forKey:key];
            }
            
            [fileMgr setAttributes:defaultAttributes ofItemAtPath:[path stringByAppendingPathComponent:subPath] error:nil];
        }
        else if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory])
        {
            setPermissionsForPath([path stringByAppendingPathComponent:subPath], executablePath);
        }
        else
        {
            //Ignore symblic links
        }
    }
}*/

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

    NSString *helpString = [NSString stringWithFormat:@"Usage: %@ [OPTION]... [FILE]...\n\nOptions:\n    -a  Show tool about information.\n    -c  Perform a clean install.\n        If the application has already been installed, the existing documents and other resources will be cleared.\n        This implements -n automatically.\n    -d  Delete IPA file(s) after installation.\n    -f  Force installation, do not check capabilities and system version.\n        Installed application may not work properly.\n    -h  Display this usage information.\n    -n  Do not restore saved documents and other resources.\n    -q  Quiet mode, suppress all normal outputs.\n    -Q  Quieter mode, suppress all outputs including errors.\n    -r  Remove iTunesMetadata.plist after installation.", executableName];

    NSString *aboutString = [NSString stringWithFormat:@"About %@\nInstall IPAs via command line.\nVersion: %@\nAuhor: autopear", executableName, EXECUTABLE_VERSION];

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
        if ([arg hasPrefix:@"-" ])
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
                else if ([p isEqualToString:@"n"])
                    notRestore = YES;
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
            if (url && [url checkResourceIsReachableAndReturnError:nil])
                [ipaFiles addObject:[[url absoluteURL] path]]; //File exists
            else
                [filesNotFound addObject:arg];
        }
    }
    
    if ((showAbout && showHelp )
        || (showAbout && (cleanInstall || deleteFile || forceInstall || notRestore || quietInstall != 0 || removeMetadata || ([ipaFiles count] + [filesNotFound count] > 0)))
        || (showHelp && (cleanInstall || deleteFile || forceInstall || notRestore || quietInstall != 0 || removeMetadata || ([ipaFiles count] + [filesNotFound count] > 0))))
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
            printf("File not found at path: %s.\n", [[filesNotFound objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
    }

    if ([ipaFiles count] < 1)
    {
        if (quietInstall < 2)
            printf("Please specify any IPA file(s) to install.\n");
        return IPA_FAILED;
    }

    if (cleanInstall)
        notRestore = YES;
    if (quietInstall == 0 && cleanInstall)
        printf("Clean installation enabled.\n");
    if (quietInstall == 0 && forceInstall)
        printf("Force installation enabled.\n");
    if (quietInstall == 0 && notRestore)
        printf("Will not restore any saved documents and other resources.\n");
    if (quietInstall == 0 && removeMetadata)
        printf("iTunesMetadata.plist will be removed after installation.\n");
    if (quietInstall == 0 && deleteFile)
    {
        if ([ipaFiles count] == 1)
            printf("%s will be deleted after installation.\n", [[[ipaFiles objectAtIndex:0] lastPathComponent] cStringUsingEncoding:NSUTF8StringEncoding]);
        else
            printf("IPA files will be deleted after installation.\n");
    }
    
    if (quietInstall == 0 && (cleanInstall || forceInstall || notRestore || removeMetadata || deleteFile))
        printf("\n");
    
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
                    printf("Failed to delete %s.\n", [file cStringUsingEncoding:NSUTF8StringEncoding]);
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
            //NSMutableDictionary *attrMobile = [NSMutableDictionary dictionary];
            //[attrMobile setObject:@"mobile" forKey:NSFileOwnerAccountName];
            //[attrMobile setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];

            //if(![fileMgr createDirectoryAtPath:workPath withIntermediateDirectories:YES attributes:attrMobile error:NULL] && quietInstall < 2)
            if(![fileMgr createDirectoryAtPath:workPath withIntermediateDirectories:YES attributes:nil error:NULL] && quietInstall < 2)
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
                    printf("Analyzing %s...\n", [[ipa lastPathComponent] cStringUsingEncoding:NSUTF8StringEncoding]);

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
                        [ipaArchive unzipFileWithName:infoPath toPath:pathInfoPlist overwrite:YES];
                    }
                    [ipaArchive unzipCloseFile];
                }
                else
                    isValidIPA = NO;
                [ipaArchive release];
                
                if (!isValidIPA)
                {
                    if (quietInstall < 2)
                        printf("%s is not a valid ipa.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

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
                        printf("%s is not a valid ipa.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                    if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                        printf("Failed to clean caches.\n");

                    continue;
                }

                if (!appIdentifier || !appDisplayName || !appVersion)
                {
                    if (quietInstall < 2)
                        printf("%s is not a valid ipa.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                    if (!removeAllContentsUnderPath(workPath) && quietInstall < 2)
                        printf("Failed to clean caches.\n");

                    continue;
                }

                //Make a copy of extracted Info.plist
                NSString *pathOriginalInfoPlist = [NSString stringWithFormat:@"%@.original", pathInfoPlist];
                if ([fileMgr fileExistsAtPath:pathOriginalInfoPlist])
                {
                    if (![fileMgr removeItemAtPath:pathOriginalInfoPlist error:nil])
                    {
                        if (![fileMgr copyItemAtPath:pathInfoPlist toPath:pathOriginalInfoPlist error:nil])
                        {
                            //Force installation has to be disabled.
                            if (forceInstall && quietInstall < 2)
                                printf("Force installation has to be disabled.\n");
                            forceInstall = NO;
                        }
                    }
                }
                else
                {
                    if (![fileMgr copyItemAtPath:pathInfoPlist toPath:pathOriginalInfoPlist error:nil])
                    {
                        //Force installation has to be disabled.
                        if (forceInstall && quietInstall < 2)
                            printf("Force installation has to be disabled.\n");
                        forceInstall = NO;
                    }
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
                                    printf("%s (v%s) is already installed. Will force to downgrade.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [installedShortVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                            }
                            else
                            {
                                if (quietInstall < 2)
                                printf("%s (v%s) is already installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [installedShortVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

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
                                    printf("%s (v%s) is already installed. Will force to downgrade.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [installedVerion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                            }
                            else
                            {
                                if (quietInstall < 2)
                                    printf("%s (v%s) is already installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [installedVerion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
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
                            printf("%s (v%s) requires %s while your device is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [supportedDeivesString cStringUsingEncoding:NSUTF8StringEncoding], [deviceString cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                        [supportedDeives addObject:[NSNumber numberWithInt:DeviceModel]];
                        [infoDict setObject:[supportedDeives sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIDeviceFamily"];
                        shouldUpdateInfoPlist = YES;
                    }
                    else
                    {
                        if (quietInstall < 2)
                            printf("%s (v%s) requires %s while your device is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [supportedDeivesString cStringUsingEncoding:NSUTF8StringEncoding], [deviceString cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

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
                            printf("%s (v%s) requires iOS %s while your system is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [minSysVersion cStringUsingEncoding:NSUTF8StringEncoding], [SystemVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                        [infoDict setObject:SystemVersion forKey:@"MinimumOSVersion"];
                        shouldUpdateInfoPlist = YES;
                    }
                    else
                    {
                        if (quietInstall < 2)
                            printf("%s (v%s) requires iOS %s while your system is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [minSysVersion cStringUsingEncoding:NSUTF8StringEncoding], [SystemVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

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
                    printf("Failed to use force installation mode, %s (v%s) will not be installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    continue;
                }

                //Copy file to install
                if ([fileMgr fileExistsAtPath:installPath])
                {
                    if (![fileMgr removeItemAtPath:installPath error:nil])
                    {
                        if (quietInstall < 2)
                            printf("Failed to delete %s.\n", [installPath cStringUsingEncoding:NSUTF8StringEncoding]);

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
                     // APPEND_STATUS_ADDINZIP = 2
                    if ([tmpArchive openZipFile2:installPath withZipModel:APPEND_STATUS_ADDINZIP] && ![tmpArchive addFileToZip:pathInfoPlist newname:infoPath])
                    {
                        if (quietInstall < 2)
                            printf("Failed to use force installation mode, %s (v%s) will not be installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

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
                    printf("%snstalling %s (v%s)...\n", shouldUpdateInfoPlist ? "Force i" : "I", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
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
                        //NSString *executablePath = [[installedAppDict objectForKey:@"Path"] stringByAppendingPathComponent:[installedAppDict objectForKey:@"CFBundleExecutable"]];

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
                                NSString *pathInstalledInfoPlist = [NSString stringWithFormat:@"%@/%@/Info.plist", installedLocation, [[infoPath pathComponents] objectAtIndex:1]];
                                if ([fileMgr fileExistsAtPath:pathInstalledInfoPlist isDirectory:&isFile])
                                {
                                    if ([fileMgr removeItemAtPath:pathInstalledInfoPlist error:nil])
                                    {
                                        if ([fileMgr moveItemAtPath:pathOriginalInfoPlist toPath:pathInstalledInfoPlist error:nil])
                                        {
                                            if ([fileMgr fileExistsAtPath:pathOriginalInfoPlist])
                                                [fileMgr removeItemAtPath:pathOriginalInfoPlist error:nil];
                                        }
                                    }
                                }
                            }

                            successfulInstalls++;
                            if (quietInstall == 0)
                                printf("%snstalled %s (v%s).\n", shouldUpdateInfoPlist ? "Force i" : "I", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);

                            BOOL tempEnableClean = NO;
                            if (!cleanInstall && hasContainer && !notRestore)
                            {
                                tempEnableClean = YES;
                                cleanInstall = YES;
                            }

                            //Clear documents, etc.
                            if (appAlreadyInstalled && cleanInstall)
                            {
                                if (quietInstall == 0)
                                    printf("Cleaning old contents of %s...\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);

                                NSString *dirDocuments = [installedLocation stringByAppendingPathComponent:@"Documents"];
                                NSString *dirLibrary = [installedLocation stringByAppendingPathComponent:@"Library"];
                                NSString *dirTmp = [installedLocation stringByAppendingPathComponent:@"tmp"];

                                BOOL allContentsCleaned = YES;

                                //Clear Documents
                                if ([fileMgr fileExistsAtPath:dirDocuments isDirectory:&isDirectory])
                                {
                                    NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:dirDocuments error:nil];
                                    for (int unsigned j=0; j<[dirContents count]; j++)
                                    {
                                        if (![fileMgr removeItemAtPath:[dirDocuments stringByAppendingPathComponent:[dirContents objectAtIndex:j]] error:nil])
                                            allContentsCleaned = NO;
                                    }
                                }
                                //Clear Library
                                if ([fileMgr fileExistsAtPath:dirLibrary isDirectory:&isDirectory])
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
                                        else if ([fileName isEqualToString:@"Caches"])
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
                                if ([fileMgr fileExistsAtPath:dirTmp isDirectory:&isDirectory])
                                {
                                    NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:dirTmp error:nil];
                                    for (int unsigned j=0; j<[dirContents count]; j++)
                                    {
                                        if (![fileMgr removeItemAtPath:[dirTmp stringByAppendingPathComponent:[dirContents objectAtIndex:j]] error:nil])
                                            allContentsCleaned = NO;
                                    }
                                }
                                if (!allContentsCleaned && quietInstall < 2)
                                    printf("Failed to clean old contents of %s.\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);
                            }

                            if (tempEnableClean)
                                cleanInstall = NO;

                            //Recover documents
                            if (!cleanInstall && hasContainer && !notRestore)
                            {
                                //The tmp ipa file is already deleted.
                                ipaArchive = [[ZipArchive alloc] init];
                                if ([ipaArchive unzipOpenFile:[ipaFiles objectAtIndex:i]])
                                {
                                    if ([ipaArchive unzipFileWithName:@"Container" toPath:[workPath stringByAppendingPathComponent:@"Container"] overwrite:YES])
                                    {
                                        NSString *containerPath = [workPath stringByAppendingPathComponent:@"Container"];
                                        
                                        NSArray *containerContents = [fileMgr contentsOfDirectoryAtPath:containerPath error:nil];
                                        if ([containerContents count] > 0)
                                        {
                                            BOOL allSuccessfull = YES;
                                            for (unsigned int j=0; j<[containerContents count]; j++)
                                            {
                                                NSString *dirName = [containerContents objectAtIndex:j];
                                                if ([dirName isEqualToString:@"Documents"])
                                                {
                                                    NSString *containerDocumentsPath = [containerPath stringByAppendingPathComponent:dirName];
                                                    NSArray *containerDocumentsContents = [fileMgr contentsOfDirectoryAtPath:containerDocumentsPath error:nil];
                                                    for (unsigned int k=0; k<[containerDocumentsContents count]; k++)
                                                    {
                                                        if (![fileMgr moveItemAtPath:[containerDocumentsPath stringByAppendingPathComponent:[containerDocumentsContents objectAtIndex:k]] toPath:[[installedLocation stringByAppendingPathComponent:dirName] stringByAppendingPathComponent:[containerDocumentsContents objectAtIndex:k]] error:nil])
                                                            allSuccessfull = NO;
                                                    }
                                                }
                                                else if ([dirName isEqualToString:@"Library"])
                                                {
                                                    NSString *containerLibraryPath = [containerPath stringByAppendingPathComponent:dirName];
                                                    NSArray *containerLibraryContents = [fileMgr contentsOfDirectoryAtPath:containerLibraryPath error:nil];
                                                    for (unsigned int k=0; k<[containerLibraryContents count]; k++)
                                                    {
                                                        NSString *dirLibraryName = [containerLibraryContents objectAtIndex:k];
                                                        if ([dirLibraryName isEqualToString:@"Caches"])
                                                        {
                                                            NSString *dirCachePath = [containerLibraryPath stringByAppendingPathComponent:dirLibraryName];
                                                            NSArray *containerCachesContents = [fileMgr contentsOfDirectoryAtPath:dirCachePath error:nil];
                                                            for (unsigned int m=0; m<[containerCachesContents count]; m++)
                                                            {
                                                                if (![fileMgr moveItemAtPath:[dirCachePath stringByAppendingPathComponent:[containerCachesContents objectAtIndex:m]] toPath:[[[installedLocation stringByAppendingPathComponent:dirName] stringByAppendingPathComponent:dirLibraryName] stringByAppendingPathComponent:[containerCachesContents objectAtIndex:m]] error:nil])
                                                                    allSuccessfull = NO;
                                                            }
                                                        }
                                                        else if ([dirLibraryName isEqualToString:@"Preferences"])
                                                        {
                                                            NSString *dirPreferencesPath = [containerLibraryPath stringByAppendingPathComponent:dirLibraryName];
                                                            NSArray *containerPreferencesContents = [fileMgr contentsOfDirectoryAtPath:dirPreferencesPath error:nil];
                                                            for (unsigned int m=0; m<[containerPreferencesContents count]; m++)
                                                            {
                                                                NSString *preferencesFileName = [containerPreferencesContents objectAtIndex:m];
                                                                if (![preferencesFileName isEqualToString:@".GlobalPreferences.plist"] && ![preferencesFileName isEqualToString:@"com.apple.PeoplePicker.plist"])
                                                                {
                                                                    if (![fileMgr moveItemAtPath:[dirPreferencesPath stringByAppendingPathComponent:preferencesFileName] toPath:[[[installedLocation stringByAppendingPathComponent:dirName] stringByAppendingPathComponent:dirLibraryName] stringByAppendingPathComponent:preferencesFileName] error:nil])
                                                                        allSuccessfull = NO;
                                                                }
                                                            }
                                                        }
                                                        else
                                                        {
                                                            if (![fileMgr moveItemAtPath:[containerLibraryPath stringByAppendingPathComponent:dirLibraryName] toPath:[[installedLocation stringByAppendingPathComponent:dirName] stringByAppendingPathComponent:dirLibraryName] error:nil])
                                                                allSuccessfull = NO;
                                                        }
                                                    }
                                                }
                                                else if ([dirName isEqualToString:@"tmp"])
                                                {
                                                    NSString *containerTmpPath = [containerPath stringByAppendingPathComponent:dirName];
                                                    NSArray *containerTmpContents = [fileMgr contentsOfDirectoryAtPath:containerTmpPath error:nil];
                                                    for (unsigned int k=0; k<[containerTmpContents count]; k++)
                                                    {
                                                        if (![fileMgr moveItemAtPath:[containerTmpPath stringByAppendingPathComponent:[containerTmpContents objectAtIndex:k]] toPath:[[installedLocation stringByAppendingPathComponent:dirName] stringByAppendingPathComponent:[containerTmpContents objectAtIndex:k]] error:nil])
                                                            allSuccessfull = NO;
                                                    }
                                                }
                                                else
                                                {
                                                    if ([fileMgr fileExistsAtPath:[installedLocation stringByAppendingPathComponent:dirName]])
                                                    {
                                                        if ([fileMgr removeItemAtPath:[installedLocation stringByAppendingPathComponent:dirName] error:nil])
                                                        {
                                                            if (![fileMgr moveItemAtPath:[containerPath stringByAppendingPathComponent:dirName] toPath:[installedLocation stringByAppendingPathComponent:dirName] error:nil])
                                                                allSuccessfull = NO;
                                                        }
                                                    }
                                                    else
                                                    {
                                                        if (![fileMgr moveItemAtPath:[containerPath stringByAppendingPathComponent:dirName] toPath:[installedLocation stringByAppendingPathComponent:dirName] error:nil])
                                                            allSuccessfull = NO;
                                                    }
                                                }
                                            }
                                            if (!allSuccessfull && quietInstall < 2)
                                                printf("Cannot restore all saved documents and other resources.\n");
                                        }
                                    }
                                    [ipaArchive unzipCloseFile];
                                }
                                [ipaArchive release];
                            }

                            //Remove metadata
                            if (removeMetadata && [fileMgr fileExistsAtPath:[installedLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] isDirectory:&isFile])
                            {
                                if (quietInstall == 0)
                                    printf("Remove iTunesMetadata.plist for %s...\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);
                                if (![fileMgr removeItemAtPath:[installedLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] error:nil] && quietInstall < 2)
                                    printf("Failed to remove %s.\n", [[installedLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] cStringUsingEncoding:NSUTF8StringEncoding]);
                            }

                            //Set overall permission
                            system([[NSString stringWithFormat:@"chown -R mobile:mobile %@", installedLocation] cStringUsingEncoding:NSUTF8StringEncoding]);
                            //setPermissionsForPath(installedLocation, executablePath);
                        }
                        else
                        {
                            if (quietInstall < 2)
                                printf("Failed to install %s (v%s).\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
                        }
                    }
                    else
                    {
                        if (quietInstall < 2)
                            printf("Failed to install %s (v%s).\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
                    }
                }
                else
                {
                    if (quietInstall < 2)
                        printf("Failed to install %s (v%s).\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
                }

                //Delete tmp ipa file
                if (!removeAllContentsUnderPath(workPath))
                {
                    if (quietInstall < 2)
                        printf("Failed to delete %s.%s", [installPath cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                    return IPA_FAILED;
                }

                //Delete original ipa
                if (deleteFile && [fileMgr fileExistsAtPath:ipa])
                {
                    NSError *err;
                    [fileMgr removeItemAtPath:ipa error:&err];
                    if (err && quietInstall < 2)
                        printf("Failed to delete %s.\nReason: %s\n", [ipa cStringUsingEncoding:NSUTF8StringEncoding], [[err localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding]);
                    [err release];
                }
                
                if (quietInstall == 0 && i < [ipaFiles count]-1)
                    printf("\n");
            }

            if (![fileMgr removeItemAtPath:workPath error:nil] && quietInstall < 2)
                printf("Failed to clean caches.\n");
        }
    }
    dlclose(lib);

    [pool release];

    return successfulInstalls;
}
