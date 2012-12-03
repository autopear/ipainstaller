#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZipArchive.h"
#import "UIDevice-Capabilities/UIDevice-Capabilities.h"

#include <dlfcn.h>

#define EXECUTABLE_VERSION @"2.0"

#define KEY_INSTALL_TYPE @"User"
#define KEY_SDKPATH "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"

#define IPA_FAILED -1
#define IPA_QUIT_NORMAL 0
#define IPA_DOWNGRADE 1
#define IPA_DEVICE_NOT_SUPPORTED 2
#define IPA_INCOMPATIBLE 3
#define IPA_UNKNOW_ERROR 4

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
    
    NSString *helpString = [NSString stringWithFormat:@"Usage: %@ [OPTION]... [FILE]...\n\nOptions:\n    -a  Show about information.\n    -c  Perform a clean install. If the application has already been installed, the saved caches, documents, settings etc. will be cleared.\n    -d  Delete IPA file(s) after installation.\n    -f  Force installation, do not check capabilities and application version. Installed application may not work properly.\n    -h  Display usage information.\n    -q  Quiet mode, suppress all normal outputs.    -Q  Quieter mode, suppress all outputs including errors.\n    -r  Remove Metadata.plist.", executableName];

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
                        printf("Parameter q and Q cannot be specified at the same time.\n");
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
        || (showAbout && (cleanInstall || deleteFile || forceInstall || quietInstall != 0 || removeMetadata))
        || (showHelp && (cleanInstall || deleteFile || forceInstall || quietInstall != 0 || removeMetadata)))
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

    int successfulInstalls = 0;
    void *lib = dlopen(KEY_SDKPATH, RTLD_LAZY);
    if (lib)
    {
        MobileInstallationInstall install = (MobileInstallationInstall)dlsym(lib, "MobileInstallationInstall");
        if (install)
        {
            NSArray *filesInTemp = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
            for (NSString *file in filesInTemp)
            {
                file = [NSTemporaryDirectory() stringByAppendingPathComponent:[file lastPathComponent]];
                if ([[file lastPathComponent] hasPrefix:@"com.autopear.installipa."])
                {
                    if (![[NSFileManager defaultManager] removeItemAtPath:file error:nil] && quietInstall < 2)
                        printf("Cannot delete \"%s\".\n", [file cStringUsingEncoding:NSUTF8StringEncoding]);
                }
            }
            
            NSString *workPath = nil;
            while (YES)
            {
                workPath = [NSString stringWithFormat:@"com.autopear.installipa.%@", randomStringInLength(6)];

                workPath = [NSTemporaryDirectory() stringByAppendingPathComponent:workPath];
                
                if (![[NSFileManager defaultManager] fileExistsAtPath:workPath])
                    break;
            }
            
            //Create working directory
            NSMutableDictionary *attrDir = [NSMutableDictionary dictionary];
            [attrDir setObject:@"mobile" forKey:NSFileOwnerAccountName];
            [attrDir setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];
            [attrDir setObject:[NSNumber numberWithInt:0755] forKey:NSFilePosixPermissions];

            NSMutableDictionary *attrFile = [NSMutableDictionary dictionary];
            [attrFile setObject:@"mobile" forKey:NSFileOwnerAccountName];
            [attrFile setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];
            [attrFile setObject:[NSNumber numberWithInt:0644] forKey:NSFilePosixPermissions];

            if(![[NSFileManager defaultManager] createDirectoryAtPath:workPath withIntermediateDirectories:YES attributes:attrDir error:NULL] && quietInstall < 2)
            {
                printf("Failed to create workspace.\n");
                return IPA_FAILED;
            }

            NSString *installPath = [workPath stringByAppendingPathComponent:@"tmp.install.ipa"];
            
            for (unsigned i=0; i<[ipaFiles count]; i++)
            {
                NSString *ipa = [ipaFiles objectAtIndex:i];
                if (quietInstall == 0)
                    printf("Analyzing \"%s\"'.\n", [[ipa lastPathComponent] cStringUsingEncoding:NSUTF8StringEncoding]);
                
                ZipArchive *ipaArchive = [[ZipArchive alloc] init];
                BOOL isValidIPA = YES;
                NSString *appName = nil;
                NSString *pathInfoPlist = nil;
                while (YES)
                {
                    pathInfoPlist = [workPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.Info.plist", randomStringInLength(6)]];
                    if (![[NSFileManager defaultManager] fileExistsAtPath:pathInfoPlist])
                        break;
                }
                if ([ipaArchive UnzipOpenFile:[ipaFiles objectAtIndex:0]])
                {
                    NSMutableArray *array = [ipaArchive getZipFileContents];
                    NSString *infoPath = nil;
                    int cnt = 0;
                    for (unsigned int i=0; i<[array count];i++)
                    {
                        NSString *name = [array objectAtIndex:i];
                        if ([name hasPrefix:@"Payload/"] && [name hasSuffix:@".app/Info.plist"])
                        {
                            appName = [[name substringToIndex:([name length]-[@".app/Info.plist" length])] substringFromIndex:[@"Payload/" length]];
                            if ([appName length] > 0 && [appName rangeOfString:@"/"].location == NSNotFound)
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
                        NSData *infoData = [ipaArchive UnzipFileToDataWithFilename:infoPath];
                        [infoData writeToFile:pathInfoPlist atomically:YES];
                    }
                    
                    [ipaArchive UnzipCloseFile];
                }
                else
                    isValidIPA = NO;
                [ipaArchive release];
                
                if (!isValidIPA && quietInstall < 2)
                {
                    printf("\"%s\" is not a valid ipa.\n\n", [[ipaFiles objectAtIndex:0] cStringUsingEncoding:NSUTF8StringEncoding]);
                    return IPA_FAILED;
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
                        printf("\"%s\" is not a valid ipa.\n\n", [[ipaFiles objectAtIndex:0] cStringUsingEncoding:NSUTF8StringEncoding]);
                    continue;
                }
                
                if (!appIdentifier || !appDisplayName || !appVersion)
                {
                    if (quietInstall < 2)
                        printf("\"%s\" is not a valid ipa.%s", [[ipaFiles objectAtIndex:0] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    return IPA_FAILED;
                }
                
                //Check installed states
                NSDictionary *mobileInstallationPlist = [[NSDictionary alloc] initWithContentsOfFile:@"/private/var/mobile/Library/Caches/com.apple.mobile.installation.plist"];
                NSDictionary *installedAppDict = (NSDictionary*)[(NSDictionary*)[mobileInstallationPlist objectForKey:@"User"] objectForKey:appIdentifier];
                
                if (installedAppDict)
                {
                    NSString *installedVerion = [installedAppDict objectForKey:@"CFBundleVersion"];
                    NSString *installedShortVersion = [installedAppDict objectForKey:@"CFBundleShortVersionString"];
                
                    if (installedShortVersion != nil && appShortVersion != nil)
                    {
                        if ([installedShortVersion compare:appShortVersion] == NSOrderedDescending && !forceInstall)
                        {
                            //Skip to avoid overriding a new version
                            if (quietInstall == 0)
                                printf("A newer version \"%s\" of \"%s\" is already installed.%s", [installedShortVersion cStringUsingEncoding:NSUTF8StringEncoding], [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                            continue;
                        }
                    }
                    else
                    {
                        if ([installedVerion compare:appVersion] == NSOrderedDescending && !forceInstall)
                        {
                            //Skip to avoid overriding a new version
                            if (quietInstall == 0)
                                printf("A newer version \"%s\" of \"%s\" is already installed.%s", [installedVerion cStringUsingEncoding:NSUTF8StringEncoding], [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                            continue;
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
                    if (quietInstall == 0)
                        printf("\"%s\" version \"%s\" requires %s while your device is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [appVersion cStringUsingEncoding:NSUTF8StringEncoding], [supportedDeivesString cStringUsingEncoding:NSUTF8StringEncoding], [deviceString cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                    //Device not supported
                    if (forceInstall)
                    {
                        [supportedDeives addObject:[NSNumber numberWithInt:DeviceModel]];
                        [infoDict setObject:[supportedDeives sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIDeviceFamily"];
                        shouldUpdateInfoPlist = YES;
                    }
                    else
                        continue;
                }
                
                //Check minimun system requirement
                if (minSysVersion && [minSysVersion compare:SystemVersion] == NSOrderedAscending)
                {
                    if (quietInstall == 0)
                        printf("\"%s\" version \"%s\" requires iOS %s while your system is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [appVersion cStringUsingEncoding:NSUTF8StringEncoding], [minSysVersion cStringUsingEncoding:NSUTF8StringEncoding], [SystemVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                    //System version is less than the min required version
                    if (forceInstall)
                    {
                        [infoDict setObject:SystemVersion forKey:@"MinimumOSVersion"];
                        shouldUpdateInfoPlist = YES;
                    }
                    else
                        continue;
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
                                    shouldUpdateInfoPlist = YES;
                                    NSDictionary *modifiedCapability = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], capability, nil];
                                    [requiredCapabilities replaceObjectAtIndex:j withObject:modifiedCapability];
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
                                    shouldUpdateInfoPlist = YES;
                                    NSDictionary *modifiedCapability = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:!capabilityValue], capabilityKey, nil];
                                    [requiredCapabilities replaceObjectAtIndex:j withObject:modifiedCapability];
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
                        if (quietInstall == 0)
                            printf("\"%s\" version \"%s\" requires iOS %s while your system is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [appVersion cStringUsingEncoding:NSUTF8StringEncoding], [minSysVersion cStringUsingEncoding:NSUTF8StringEncoding], [SystemVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                        if (forceInstall)
                            [infoDict setObject:[requiredCapabilities sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIRequiredDeviceCapabilities"];
                        else
                            continue;
                    }
                }
                
                if (shouldUpdateInfoPlist && ![infoDict writeToFile:pathInfoPlist atomically:YES] && quietInstall < 2)
                {
                    printf(@"Failed to use force installation mode, \"%s\" version \"%s\" will not be installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [appVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    continue;
                }
                
                //Copy file to install
                if ([[NSFileManager defaultManager] fileExistsAtPath:installPath])
                {
                    if (![[NSFileManager defaultManager] removeItemAtPath:installPath error:nil] && quietInstall < 2)
                    {
                        printf("Failed to delete \"%s\".\n", [installPath cStringUsingEncoding:NSUTF8StringEncoding]);
                        return IPA_FAILED;
                    }
                }
                
                if (![[NSFileManager defaultManager] copyItemAtPath:ipa toPath:installPath error:nil] && quietInstall < 2)
                {
                    printf("Failed to create temporaty files.\n");
                    return IPA_FAILED;
                }
                
                //Modify ipa to force install
                
                
                if (quietInstall == 0)
                    printf("Installing \"%s\" version \"%s\"...\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
                int ret = install(installPath, [NSDictionary dictionaryWithObject:KEY_INSTALL_TYPE forKey:@"ApplicationType"], 0, installPath);
                if (ret == 0)
                {
                    successfulInstalls++;
                    if (quietInstall == 0)
                        printf("Installed \"%s\" version \"%s\".%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                }
                else
                {
                    if (quietInstall == 0)
                        printf("Failed to install \"%s\".%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                }
                
                //Delete file
                if ([[NSFileManager defaultManager] fileExistsAtPath:installPath])
                {
                    if (![[NSFileManager defaultManager] removeItemAtPath:installPath error:nil] && quietInstall < 2)
                        printf("Failed to delete \"%s\".\n", [installPath cStringUsingEncoding:NSUTF8StringEncoding]);
                        return IPA_FAILED;
                }
                
                if (deleteFile && [[NSFileManager defaultManager] fileExistsAtPath:ipa])
                {
                    NSError *err;
                    [[NSFileManager defaultManager] removeItemAtPath:installPath error:&err];
                    if (err && quietInstall < 2)
                        printf("Failed to delete \"%s\".\nReason: %s%s", [ipa cStringUsingEncoding:NSUTF8StringEncoding], [[err localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    [err release];
                }
            }
        }
    }
    dlclose(lib);

    [pool release];

    return successfulInstalls;
}
