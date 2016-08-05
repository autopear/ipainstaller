#include <dlfcn.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import "ZipArchive/ZipArchive.h"
#import "UIDevice-Capabilities/UIDevice-Capabilities.h"

#define EXECUTABLE_VERSION @"3.4.1"

#define KEY_INSTALL_TYPE @"User"
#define KEY_SDKPATH "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"

#define IPA_FAILED -1

typedef int (*MobileInstallationInstall)(NSString *path, NSDictionary *dict, void *na, NSString *backpath);
typedef int (*MobileInstallationUninstall)(NSString *bundleID, NSDictionary *dict, void *na);

@interface LSApplicationWorkspace : NSObject
+ (LSApplicationWorkspace *)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)path withOptions:(NSDictionary *)options;
- (BOOL)uninstallApplication:(NSString *)identifier withOptions:(NSDictionary *)options;
- (BOOL)applicationIsInstalled:(NSString *)appIdentifier;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
- (NSArray *)applicationsOfType:(unsigned int)appType; // 0 for user, 1 for system
@end

@interface LSApplicationProxy : NSObject
+ (LSApplicationProxy *)applicationProxyForIdentifier:(id)appIdentifier;
@property(readonly) NSString * applicationIdentifier;
@property(readonly) NSString * bundleVersion;
@property(readonly) NSString * bundleExecutable;
@property(readonly) NSArray * deviceFamily;
@property(readonly) NSURL * bundleContainerURL;
@property(readonly) NSString * bundleIdentifier;
@property(readonly) NSURL * bundleURL;
@property(readonly) NSURL * containerURL;
@property(readonly) NSURL * dataContainerURL;
@property(readonly) NSString * localizedShortName;
@property(readonly) NSString * localizedName;
@property(readonly) NSString * shortVersionString;
@end

static NSString *SystemVersion = nil;
static int DeviceModel = 0;

static BOOL isUninstall = NO;
static BOOL isGetInfo = NO;
static BOOL isListing = NO;
static BOOL isBackup = NO;
static BOOL isBackupFull = NO;

static BOOL cleanInstall = NO;
static int quietInstall = 0; //0 is show all outputs, 1 is to show only errors, 2 is to show nothing
static BOOL forceInstall = NO;
static BOOL removeMetadata = NO;
static BOOL deleteFile = NO;
static BOOL notRestore = NO;

static NSString * randomStringInLength(int len) {
    NSString *ret = @"";
    NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (int i=0; i<len; i++)
        ret = [NSString stringWithFormat:@"%@%C", ret, [letters characterAtIndex:arc4random() % [letters length]]];
    return ret;
}

static BOOL removeAllContentsUnderPath(NSString *path) {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    BOOL isDirectory;
    if ([fileMgr fileExistsAtPath:path isDirectory:&isDirectory]) {
        if (isDirectory) {
            NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:path error:nil];
            BOOL allRemoved = YES;
            for (int unsigned j=0; j<[dirContents count]; j++) {
                if (![fileMgr removeItemAtPath:[path stringByAppendingPathComponent:[dirContents objectAtIndex:j]] error:nil])
                    allRemoved = NO;
            }
            if (!allRemoved)
                return NO;
            if (![fileMgr removeItemAtPath:path error:nil])
                return NO;
        }
    }
    return YES;
}

static void setPermissionsForPath(NSString *path) {
    NSFileManager *fileMgr = [NSFileManager defaultManager];

    //Set root folder's attributes
    NSDictionary *directoryAttributes = [fileMgr attributesOfItemAtPath:path error:nil];
    NSMutableDictionary *defaultDirectoryAttributes = [NSMutableDictionary dictionaryWithCapacity:[directoryAttributes count]];
    [defaultDirectoryAttributes setDictionary:directoryAttributes];

    [defaultDirectoryAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileOwnerAccountID];
    [defaultDirectoryAttributes setObject:@"mobile" forKey:NSFileOwnerAccountName];
    [defaultDirectoryAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileGroupOwnerAccountID];
    [defaultDirectoryAttributes setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];

    [defaultDirectoryAttributes setObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions];

    [fileMgr setAttributes:defaultDirectoryAttributes ofItemAtPath:path error:nil];

    for (NSString *subPath in [fileMgr contentsOfDirectoryAtPath:path error:nil]) {
        NSDictionary *attributes = [fileMgr attributesOfItemAtPath:[path stringByAppendingPathComponent:subPath] error:nil];
        if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular]) {
            NSMutableDictionary *defaultAttributes = [NSMutableDictionary dictionaryWithDictionary:directoryAttributes];

            [defaultAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileOwnerAccountID];
            [defaultAttributes setObject:@"mobile" forKey:NSFileOwnerAccountName];
            [defaultAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileGroupOwnerAccountID];
            [defaultAttributes setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];
            [defaultAttributes setObject:[NSNumber numberWithShort:0644] forKey:NSFilePosixPermissions];

            [fileMgr setAttributes:defaultAttributes ofItemAtPath:[path stringByAppendingPathComponent:subPath] error:nil];
        } else if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory])
            setPermissionsForPath([path stringByAppendingPathComponent:subPath]);
        else {
            //Ignore symblic links
        }
    }
}

static void setExecutables(NSString *dirPath) {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    BOOL isDir;
    if (![fileMgr fileExistsAtPath:dirPath isDirectory:&isDir])
        return;
    if (!isDir)
        return;
    
    NSString *infoPlistPath = [dirPath stringByAppendingPathComponent:@"Info.plist"];
    if ([fileMgr fileExistsAtPath:infoPlistPath]) {
        NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        NSString *exeName = [infoDict objectForKey:@"CFBundleExecutable"];
        NSString *exePath = [dirPath stringByAppendingPathComponent:exeName];
        if ([fileMgr fileExistsAtPath:exePath]) {
            NSDictionary *attributes = [fileMgr attributesOfItemAtPath:exePath error:nil];
            if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular]) {
                NSMutableDictionary *executableAttributes = [NSMutableDictionary dictionaryWithDictionary:attributes];
                [executableAttributes setObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions];
                [fileMgr setAttributes:executableAttributes ofItemAtPath:exePath error:nil];
            }
        }
    }
    
    for (NSString *subPath in [fileMgr contentsOfDirectoryAtPath:dirPath error:nil]) {
        NSString *subDirPath = [dirPath stringByAppendingPathComponent:subPath];
        NSDictionary *attributes = [fileMgr attributesOfItemAtPath:subDirPath error:nil];
        if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory])
            setExecutables(subDirPath);
    }
}

static int versionCompare(NSString *ver1, NSString *ver2) {
    //-1: ver1<ver2; 0: ver1=ver2; 1: ver1>ver2
    BOOL isEmpty1 = (ver1 == nil || [ver1 length] == 0);
    BOOL isEmpty2 = (ver2 == nil || [ver2 length] == 0);
    if (isEmpty1 && isEmpty2)
        return 0;
    else if (isEmpty1 && !isEmpty2)
        return -1;
    else if (!isEmpty1 && isEmpty2)
        return 1;
    else {
        NSArray *components1 = [ver1 componentsSeparatedByString:@"."];
        NSArray *components2 = [ver2 componentsSeparatedByString:@"."];

        int count = [components1 count] > [components2 count] ? [components2 count] : [components1 count];
        for (int i=0; i<count; i++) {
            int num1 = [[components1 objectAtIndex:i] intValue];
            int num2 = [[components2 objectAtIndex:i] intValue];

            if (num1 < num2)
                return -1;
            else if (num1 > num2)
                return 1;
            else {
                if ([[components1 objectAtIndex:i] isEqualToString:[components2 objectAtIndex:i]])
                    continue;
                else
                    return [[components1 objectAtIndex:i] compare:[components2 objectAtIndex:i]] == NSOrderedDescending ? 1 : -1;
            }
        }

        if ([components1 count] != [components2 count])
            return [components1 count] > [components2 count] ? 1 : -1;
        else
            return 0;
    }
}

static NSArray *getInstalledApplications() {
    if (kCFCoreFoundationVersionNumber < 1140.10) {
        NSDictionary *mobileInstallationPlist = [NSDictionary dictionaryWithContentsOfFile:@"/private/var/mobile/Library/Caches/com.apple.mobile.installation.plist"];
        NSDictionary *installedAppDict = (NSDictionary*)[mobileInstallationPlist objectForKey:@"User"];

        NSArray * identifiers = [[installedAppDict allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

        return identifiers;
    } else {
        Class LSApplicationWorkspace_class = objc_getClass("LSApplicationWorkspace");
        if (LSApplicationWorkspace_class) {
            LSApplicationWorkspace *workspace = [LSApplicationWorkspace_class performSelector:@selector(defaultWorkspace)];
            if (workspace) {
                NSArray *allApps = [workspace applicationsOfType:0];
                NSMutableArray *identifiers = [NSMutableArray arrayWithCapacity:[allApps count]];
                for (LSApplicationProxy *appBundle in allApps)
                    [identifiers addObject:appBundle.bundleIdentifier];
                return [identifiers sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            }
        }
    }
    return nil;
}

static NSString *formatDictValue(NSObject *object) {
    return object ? (NSString *)object : @"";
}

static NSString *getBestString(NSString *main, NSString *minor) {
    return (minor && [minor length] > 0) ? minor : (main ? main : @"");
}

static NSDictionary *getInstalledAppInfo(NSString *appIdentifier) {
    if (kCFCoreFoundationVersionNumber < 1140.10) {
        NSDictionary *mobileInstallationPlist = [NSDictionary dictionaryWithContentsOfFile:@"/private/var/mobile/Library/Caches/com.apple.mobile.installation.plist"];
        NSDictionary *installedAppDict = (NSDictionary*)[mobileInstallationPlist objectForKey:@"User"];

        NSDictionary *appInfo = [installedAppDict objectForKey:appIdentifier];
        if (appInfo) {
            NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:8];
            [info setObject:formatDictValue([appInfo objectForKey:@"CFBundleIdentifier"]) forKey:@"APP_ID"];
            [info setObject:formatDictValue([appInfo objectForKey:@"Container"]) forKey:@"BUNDLE_PATH"];
            [info setObject:formatDictValue([appInfo objectForKey:@"Path"]) forKey:@"APP_PATH"];
            [info setObject:formatDictValue([appInfo objectForKey:@"Container"]) forKey:@"DATA_PATH"];
            [info setObject:formatDictValue([appInfo objectForKey:@"CFBundleVersion"]) forKey:@"VERSION"];
            [info setObject:formatDictValue([appInfo objectForKey:@"CFBundleShortVersionString"]) forKey:@"SHORT_VERSION"];
            [info setObject:formatDictValue([appInfo objectForKey:@"CFBundleName"]) forKey:@"NAME"];
            [info setObject:formatDictValue([appInfo objectForKey:@"CFBundleDisplayName"]) forKey:@"DISPLAY_NAME"];
            return info;
        }
    } else {
        Class LSApplicationWorkspace_class = objc_getClass("LSApplicationWorkspace");
        if (LSApplicationWorkspace_class) {
            LSApplicationWorkspace *workspace = [LSApplicationWorkspace_class performSelector:@selector(defaultWorkspace)];
            if (workspace && [workspace applicationIsInstalled:appIdentifier]) {
                Class LSApplicationProxy_class = objc_getClass("LSApplicationProxy");
                if (LSApplicationProxy_class) {
                    LSApplicationProxy *app = [LSApplicationProxy_class applicationProxyForIdentifier:appIdentifier];
                    if (app) {
                        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:9];
                        [info setObject:formatDictValue(app.bundleIdentifier) forKey:@"APP_ID"];
                        [info setObject:formatDictValue([app.bundleContainerURL path]) forKey:@"BUNDLE_PATH"];
                        [info setObject:formatDictValue([app.bundleURL path]) forKey:@"APP_PATH"];
                        [info setObject:formatDictValue([app.dataContainerURL path]) forKey:@"DATA_PATH"];
                        [info setObject:formatDictValue(app.bundleVersion) forKey:@"VERSION"];
                        [info setObject:formatDictValue(app.shortVersionString) forKey:@"SHORT_VERSION"];
                        [info setObject:formatDictValue(app.localizedName) forKey:@"NAME"];
                        [info setObject:formatDictValue(app.localizedShortName) forKey:@"DISPLAY_NAME"];
                        return info;
                    }
                }
            }
        }
    }
    return nil;
}

static int installApp(NSString *ipaPath, NSString *ipaId) {
    int ret = -1;
    if (kCFCoreFoundationVersionNumber < 1140.10) {
        void *lib = dlopen(KEY_SDKPATH, RTLD_LAZY);
        if (lib) {
            MobileInstallationInstall install = (MobileInstallationInstall)dlsym(lib, "MobileInstallationInstall");
            if (install)
                ret = install(ipaPath, [NSDictionary dictionaryWithObject:KEY_INSTALL_TYPE forKey:@"ApplicationType"], 0, ipaPath);
            dlclose(lib);
        }
    } else {
        Class LSApplicationWorkspace_class = objc_getClass("LSApplicationWorkspace");
        if (LSApplicationWorkspace_class) {
            LSApplicationWorkspace *workspace = [LSApplicationWorkspace_class performSelector:@selector(defaultWorkspace)];
            if (workspace && [workspace installApplication:[NSURL fileURLWithPath:ipaPath] withOptions:[NSDictionary dictionaryWithObject:ipaId forKey:@"CFBundleIdentifier"]])
                ret = 0;
        }
    }
    return ret;
}

static BOOL uninstallApplication(NSString *appIdentifier) {
    if (kCFCoreFoundationVersionNumber < 1140.10) {
        void *lib = dlopen(KEY_SDKPATH, RTLD_LAZY);
        if (lib) {
            MobileInstallationUninstall uninstall = (MobileInstallationUninstall)dlsym(lib, "MobileInstallationUninstall");
            if (uninstall)
                return 0 == uninstall(appIdentifier, nil, nil);
            dlclose(lib);
        }
    } else {
        Class LSApplicationWorkspace_class = objc_getClass("LSApplicationWorkspace");
        if (LSApplicationWorkspace_class) {
            LSApplicationWorkspace *workspace = [LSApplicationWorkspace_class performSelector:@selector(defaultWorkspace)];
            if (workspace && [workspace uninstallApplication:appIdentifier withOptions:nil])
                return YES;
        }

    }
    return NO;
}

int main (int argc, char **argv, char **envp) {
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    freopen("/dev/null", "w", stderr); //Suppress output from NSLog

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

    if ([arguments count] < 1) {
        [pool release];
        return IPA_FAILED;
    }

    NSString *executableName = [[arguments objectAtIndex:0] lastPathComponent];

    NSString *helpString = [NSString stringWithFormat:@"Usage: %@ [OPTION]... [FILE]...\n       %@ -{bB} [APP_ID] [-o OUTPUT_PATH]\n       %@ -i [APP_ID]...\n       %@ -l\n       %@ -u [APP_ID]...\n\n\nOptions:\n    -a  Show tool about information.\n    -b  Back up application with given identifier to IPA.\n    -B  Back up application with given identifier and its documents and settings to IPA.\n    -c  Perform a clean install.\n        If the application has already been installed, the existing documents and other resources will be cleared.\n        This implements -n automatically.\n    -d  Delete IPA file(s) after installation.\n    -f  Force installation, do not check capabilities and system version.\n        Installed application may not work properly.\n    -h  Display this usage information.\n    -i  Display information of installed application(s).\n    -l  List identifiers of all installed App Store applications.\n    -n  Do not restore saved documents and other resources.\n    -o  Output IPA to specified path, or the IPA will be saved under /var/mobile/Documents/.\n    -q  Quiet mode, suppress all normal outputs.\n    -Q  Quieter mode, suppress all outputs including errors.\n    -r  Remove iTunesMetadata.plist after installation.\n    -u  Uninstall application with given identifier(s).", executableName, executableName, executableName, executableName, executableName];

    NSDate *today = [NSDate date];

    NSDateFormatter *currentFormatter = [[NSDateFormatter alloc] init];

    [currentFormatter setDateFormat:@"yyyy"];

    NSString *aboutString = [NSString stringWithFormat:@"About %@\nInstall IPAs via command line or back up/browse/uninstall installed applications.\nVersion: %@\nAuthor: Merlin Mao\n\nZipArchive from Matt Connolly\nFSSystemHasCapability from Ryan Petrich\n\nCopyright \u00A9 2012%@ Merlin Mao. All rights reserved.", executableName, EXECUTABLE_VERSION, [[currentFormatter stringFromDate:today] isEqualToString:@"2012"] ? @"" : [@"-" stringByAppendingString:[currentFormatter stringFromDate:today]]];

    [currentFormatter release];

    if ([arguments count] == 1) {
        printf("%s\n", [helpString cStringUsingEncoding:NSUTF8StringEncoding]);
        [pool release];
        return 0;
    }

    NSFileManager *fileMgr = [NSFileManager defaultManager];

    if ([arguments count] >= 3) {
        NSMutableArray *identifiers = [NSMutableArray array];

        NSString *op1 = [arguments objectAtIndex:1];
        if ([op1 isEqualToString:@"-uq"] || [op1 isEqualToString:@"-qu"]) {
            isUninstall = YES;
            quietInstall = 1;
            for (unsigned int i=2; i<[arguments count]; i++)
                [identifiers addObject:[arguments objectAtIndex:i]];
        }
        if ([op1 isEqualToString:@"-uQ"] || [op1 isEqualToString:@"-Qu"]) {
            isUninstall = YES;
            quietInstall = 2;
            for (unsigned int i=2; i<[arguments count]; i++)
                [identifiers addObject:[arguments objectAtIndex:i]];
        }
        NSString *op2 = [arguments objectAtIndex:2];
        if ([op1 isEqualToString:@"-u"]) {
            isUninstall = YES;
            if ([op2 isEqualToString:@"-q"]) {
                quietInstall = 1;
                for (unsigned int i=3; i<[arguments count]; i++)
                    [identifiers addObject:[arguments objectAtIndex:i]];
            }
            else if ([op2 isEqualToString:@"-Q"]) {
                quietInstall = 2;
                for (unsigned int i=3; i<[arguments count]; i++)
                    [identifiers addObject:[arguments objectAtIndex:i]];
            } else {
                for (unsigned int i=2; i<[arguments count]; i++)
                    [identifiers addObject:[arguments objectAtIndex:i]];
            }
        }
        if ([op1 isEqualToString:@"-i"]) {
            isGetInfo = YES;
            for (unsigned int i=2; i<[arguments count]; i++)
                [identifiers addObject:[arguments objectAtIndex:i]];
        }

        if ([op2 isEqualToString:@"-u"]) {
            if ([op1 isEqualToString:@"-q"]) {
                isUninstall = YES;
                quietInstall = 1;
                for (unsigned int i=3; i<[arguments count]; i++)
                    [identifiers addObject:[arguments objectAtIndex:i]];
            }
            if ([op1 isEqualToString:@"-Q"]) {
                quietInstall = 2;
                for (unsigned int i=3; i<[arguments count]; i++)
                    [identifiers addObject:[arguments objectAtIndex:i]];
            }
        }

        if (isGetInfo) {
            if ([identifiers count] < 1) {
                printf("You must specify at least one application identifier.\n");
                [pool release];
                return IPA_FAILED;
            }

            NSArray *installedApps = getInstalledApplications();

            for (unsigned int i=0; i<[identifiers count]; i++) {
                NSString *identifier = [identifiers objectAtIndex:i];
                if ([installedApps containsObject:identifier]) {
                    NSDictionary *installedAppInfo = getInstalledAppInfo(identifier);

                    NSString *appDirPath = [installedAppInfo objectForKey:@"BUNDLE_PATH"];
                    NSString *appPath = [installedAppInfo objectForKey:@"APP_PATH"];
                    NSString *dataPath = [installedAppInfo objectForKey:@"DATA_PATH"];
                    NSString *appName = [installedAppInfo objectForKey:@"NAME"];
                    NSString *appDisplayName = [installedAppInfo objectForKey:@"DISPLAY_NAME"];
                    NSString *appVersion = [installedAppInfo objectForKey:@"VERSION"];
                    NSString *appShortVersion = [installedAppInfo objectForKey:@"SHORT_VERSION"];

                    printf("Identifier: %s\n", [identifier cStringUsingEncoding:NSUTF8StringEncoding]);
                    if ([appVersion length] > 0)
                        printf("Version: %s\n", [appVersion cStringUsingEncoding:NSUTF8StringEncoding]);
                    if ([appShortVersion length] > 0)
                        printf("Short Version: %s\n", [appShortVersion cStringUsingEncoding:NSUTF8StringEncoding]);
                    if ([appName length] > 0)
                        printf("Name: %s\n", [appName cStringUsingEncoding:NSUTF8StringEncoding]);
                    if ([appDisplayName length] > 0)
                        printf("Display Name: %s\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);
                    if ([appDirPath length] > 0)
                        printf("Bundle: %s\n", [appDirPath cStringUsingEncoding:NSUTF8StringEncoding]);
                    if ([appPath length] > 0)
                        printf("Application: %s\n", [appPath cStringUsingEncoding:NSUTF8StringEncoding]);
                    if ([dataPath length] > 0)
                        printf("Data: %s\n", [dataPath cStringUsingEncoding:NSUTF8StringEncoding]);
                } else {
                    if (quietInstall < 2)
                        printf("Application \"%s\" is not installed.\n", [identifier cStringUsingEncoding:NSUTF8StringEncoding]);
                }
                if (i < [identifiers count] - 1)
                    printf("\n");
            }
            return 0;
        }

        if (isUninstall) {
            if ([identifiers count] < 1) {
                printf("You must specify at least one application identifier.\n");
                [pool release];
                return IPA_FAILED;
            } else {
                NSArray *installedApps = getInstalledApplications();

                for (unsigned int i=0; i<[identifiers count]; i++) {
                    if ([installedApps containsObject:[identifiers objectAtIndex:i]]) {
                        printf("Removing application \"%s\".\n", [[identifiers objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
                        if (uninstallApplication([identifiers objectAtIndex:i])) {
                            if (quietInstall == 0)
                                printf("Successfully removed application \"%s\".\n", [[identifiers objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
                        } else {
                            if (quietInstall < 2)
                                printf("Failed to remove application \"%s\".\n", [[identifiers objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
                        }
                    } else {
                        if (quietInstall < 2)
                            printf("Application \"%s\" is not installed.\n", [[identifiers objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
                    }
                }

                [pool release];
                return 0;
            }
        }

        NSString *identifier = nil, *savePath = nil;
        if ([op1 isEqualToString:@"-bq"] || [op1 isEqualToString:@"-qb"]) {
            isBackup = YES;
            quietInstall = 1;
            if ([arguments count] == 5) {
                identifier = [arguments objectAtIndex:2];
                NSString *opOutput = [arguments objectAtIndex:3];
                if (![opOutput isEqualToString:@"-o"]) {
                    printf("Invalid parameters.\n");
                    [pool release];
                    return 0;
                }
                savePath = [arguments objectAtIndex:4];
            } else if ([arguments count] != 3) {
                printf("Invalid parameters.\n");
                [pool release];
                return 0;
            } else
                identifier = [arguments objectAtIndex:2];
        }
        if ([op1 isEqualToString:@"-bQ"] || [op1 isEqualToString:@"-Qb"]) {
            isBackup = YES;
            quietInstall = 2;
            if ([arguments count] == 5) {
                identifier = [arguments objectAtIndex:2];
                NSString *opOutput = [arguments objectAtIndex:3];
                if (![opOutput isEqualToString:@"-o"]) {
                    printf("Invalid parameters.\n");
                    [pool release];
                    return 0;
                }
                savePath = [arguments objectAtIndex:4];
            } else if ([arguments count] != 3) {
                printf("Invalid parameters.\n");
                [pool release];
                return 0;
            } else
                identifier = [arguments objectAtIndex:2];
        }
        if ([op1 isEqualToString:@"-Bq"] || [op1 isEqualToString:@"-qB"]) {
            isBackupFull = YES;
            quietInstall = 1;
            if ([arguments count] == 5) {
                identifier = [arguments objectAtIndex:2];
                NSString *opOutput = [arguments objectAtIndex:3];
                if (![opOutput isEqualToString:@"-o"]) {
                    printf("Invalid parameters.\n");
                    [pool release];
                    return 0;
                }
                savePath = [arguments objectAtIndex:4];
            } else if ([arguments count] != 3) {
                printf("Invalid parameters.\n");
                [pool release];
                return 0;
            } else
                identifier = [arguments objectAtIndex:2];
        }
        if ([op1 isEqualToString:@"-BQ"] || [op1 isEqualToString:@"-QB"]) {
            isBackupFull = YES;
            quietInstall = 2;
            if ([arguments count] == 5) {
                identifier = [arguments objectAtIndex:2];
                NSString *opOutput = [arguments objectAtIndex:3];
                if (![opOutput isEqualToString:@"-o"]) {
                    printf("Invalid parameters.\n");
                    [pool release];
                    return 0;
                }
                savePath = [arguments objectAtIndex:4];
            } else if ([arguments count] != 3) {
                printf("Invalid parameters.\n");
                [pool release];
                return 0;
            } else
                identifier = [arguments objectAtIndex:2];
        }
        if ([op1 isEqualToString:@"-b"] || [op1 isEqualToString:@"-B"]) {
            if ([op1 isEqualToString:@"-b"])
                isBackup = YES;
            else
                isBackupFull = YES;

            if ([op2 isEqualToString:@"-q"] || [op2 isEqualToString:@"-Q"]) {
                quietInstall = [op2 isEqualToString:@"-q"] ? 1 : 2;
                if ([arguments count] == 6) {
                    identifier = [arguments objectAtIndex:3];
                    NSString *opOutput = [arguments objectAtIndex:4];
                    if (![opOutput isEqualToString:@"-o"]) {
                        printf("Invalid parameters.\n");
                        [pool release];
                        return 0;
                    }
                    savePath = [arguments objectAtIndex:5];
                } else if ([arguments count] != 4) {
                    printf("Invalid parameters.\n");
                    [pool release];
                    return 0;
                } else
                    identifier = [arguments objectAtIndex:3];
            } else {
                if ([arguments count] == 5) {
                    identifier = [arguments objectAtIndex:2];
                    NSString *opOutput = [arguments objectAtIndex:3];
                    if (![opOutput isEqualToString:@"-o"]) {
                        printf("Invalid parameters.\n");
                        [pool release];
                        return 0;
                    }
                    savePath = [arguments objectAtIndex:4];
                } else if ([arguments count] != 3) {
                    printf("Invalid parameters.\n");
                    [pool release];
                    return 0;
                } else
                    identifier = [arguments objectAtIndex:2];
            }
        }
        if ([op2 isEqualToString:@"-b"] || [op2 isEqualToString:@"-B"]) {
            if ([op1 isEqualToString:@"-q"] || [op1 isEqualToString:@"-Q"]) {
                if ([op2 isEqualToString:@"-b"])
                    isBackup = YES;
                else
                    isBackupFull = YES;
                quietInstall = [op1 isEqualToString:@"-q"] ? 1 : 2;
                if ([arguments count] == 6) {
                    identifier = [arguments objectAtIndex:3];
                    NSString *opOutput = [arguments objectAtIndex:4];
                    if (![opOutput isEqualToString:@"-o"]) {
                        printf("Invalid parameters.\n");
                        [pool release];
                        return 0;
                    }
                    savePath = [arguments objectAtIndex:5];
                } else if ([arguments count] != 4) {
                    printf("Invalid parameters.\n");
                    [pool release];
                    return 0;
                } else
                    identifier = [arguments objectAtIndex:3];
            }
        }

        if (isBackup || isBackupFull) {
            if ([identifier length] < 1) {
                printf("You must specify an application identifier.\n");
                [pool release];
                return 0;
            }

            if (savePath) {
                if (![savePath hasPrefix:@"/"])
                    savePath = [[fileMgr currentDirectoryPath] stringByAppendingPathComponent:savePath];

                savePath = [savePath stringByStandardizingPath];;
            }

            if ([fileMgr fileExistsAtPath:savePath]) {
                printf("%s already exists.\n", [savePath cStringUsingEncoding:NSUTF8StringEncoding]);
                [pool release];
                return IPA_FAILED;
            }

            NSDictionary *installedAppInfo = getInstalledAppInfo(identifier);

            if (!installedAppInfo) {
                if (quietInstall < 2)
                    printf("Application \"%s\" is not installed.\n", [identifier cStringUsingEncoding:NSUTF8StringEncoding]);
                [pool release];
                return IPA_FAILED;
            } else
                printf("Backing up application with identifier \"%s\"...\n", [identifier cStringUsingEncoding:NSUTF8StringEncoding]);

            NSString *appDirPath = [installedAppInfo objectForKey:@"BUNDLE_PATH"];
            NSString *appPath = [installedAppInfo objectForKey:@"APP_PATH"];
            NSString *dataPath = [installedAppInfo objectForKey:@"DATA_PATH"];
            NSString *appName = [installedAppInfo objectForKey:@"NAME"];
            NSString *appDisplayName = [installedAppInfo objectForKey:@"DISPLAY_NAME"];
            NSString *appVersion = [installedAppInfo objectForKey:@"VERSION"];
            NSString *appShortVersion = [installedAppInfo objectForKey:@"SHORT_VERSION"];
            if (!appDisplayName || [appDisplayName length] < 1)
                appDisplayName = appName;
            if (!appShortVersion || [appShortVersion length] < 1)
                appShortVersion = appVersion;

            BOOL isDirectory;
            if (![fileMgr fileExistsAtPath:appDirPath isDirectory:&isDirectory]) {
                if (quietInstall < 2)
                    printf("Cannot find %s.\n", [appDirPath cStringUsingEncoding:NSUTF8StringEncoding]);
                [pool release];
                return IPA_FAILED;
            }
            if (!isDirectory) {
                if (quietInstall < 2)
                    printf("%s is not a directory.\n", [appDirPath cStringUsingEncoding:NSUTF8StringEncoding]);
                [pool release];
                return IPA_FAILED;
            }
            if (![fileMgr fileExistsAtPath:appPath isDirectory:&isDirectory]) {
                if (quietInstall < 2)
                    printf("Cannot find %s.\n", [appPath cStringUsingEncoding:NSUTF8StringEncoding]);
                [pool release];
                return IPA_FAILED;
            }
            if (!isDirectory) {
                if (quietInstall < 2)
                    printf("%s is not a directory.\n", [appPath cStringUsingEncoding:NSUTF8StringEncoding]);
                [pool release];
                return IPA_FAILED;
            }
            if (isBackupFull) {
                if (![fileMgr fileExistsAtPath:dataPath isDirectory:&isDirectory]) {
                    if (quietInstall < 2)
                        printf("Cannot find %s.\n", [dataPath cStringUsingEncoding:NSUTF8StringEncoding]);
                    [pool release];
                    return IPA_FAILED;
                }
                if (!isDirectory) {
                    if (quietInstall < 2)
                        printf("%s is not a directory.\n", [dataPath cStringUsingEncoding:NSUTF8StringEncoding]);
                    [pool release];
                    return IPA_FAILED;
                }
            }

            //Clean before
            NSArray *filesInTemp = [fileMgr contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
            for (NSString *file in filesInTemp) {
                file = [NSTemporaryDirectory() stringByAppendingPathComponent:[file lastPathComponent]];
                if ([[file lastPathComponent] hasPrefix:@"com.autopear.ipainstaller."] && ![fileMgr removeItemAtPath:file error:nil]) {
                    if (quietInstall < 2)
                        printf("Failed to delete %s.\n", [file cStringUsingEncoding:NSUTF8StringEncoding]);
                }
            }

            //Create temp path
            NSString *workPath = nil;
            while (YES) {
                workPath = [NSString stringWithFormat:@"com.autopear.ipainstaller.%@", randomStringInLength(6)];
                workPath = [NSTemporaryDirectory() stringByAppendingPathComponent:workPath];
                if (![fileMgr fileExistsAtPath:workPath])
                    break;
            }

            if(![fileMgr createDirectoryAtPath:workPath withIntermediateDirectories:YES attributes:nil error:NULL] ) {
                if (quietInstall < 2)
                    printf("Failed to create workspace.\n");
                [pool release];
                return IPA_FAILED;
            }

            ZipArchive *ipaArchive = [[ZipArchive alloc] init];
            // APPEND_STATUS_ADDINZIP = 2
            if (![ipaArchive openZipFile2:[workPath stringByAppendingPathComponent:@"temp.zip"] withZipModel:APPEND_STATUS_ADDINZIP]) {
                [ipaArchive release];
                if (quietInstall < 2)
                    printf("Failed to create IPA file.\n");

                if (!removeAllContentsUnderPath(workPath)) {
                    if (quietInstall < 2)
                        printf("Failed to clean caches.\n");
                }

                [pool release];
                return IPA_FAILED;
            }

            if (![ipaArchive addDirectoryToZip:appPath toPathInZip:[NSString stringWithFormat:@"Payload/%@/", [appPath lastPathComponent]]]) {
                if (quietInstall < 2)
                    printf("Failed to create ipa file.\n");
                [ipaArchive release];

                if (!removeAllContentsUnderPath(workPath)) {
                    if (quietInstall < 2)
                        printf("Failed to clean caches.\n");
                }

                [pool release];
                return IPA_FAILED;
            }

            if ([fileMgr fileExistsAtPath:[appDirPath stringByAppendingPathComponent:@"iTunesArtwork"]])
                [ipaArchive addFileToZip:[appDirPath stringByAppendingPathComponent:@"iTunesArtwork"] newname:@"iTunesArtwork"];

            if ([fileMgr fileExistsAtPath:[appDirPath stringByAppendingPathComponent:@"iTunesMetadata.plist"]])
                [ipaArchive addFileToZip:[appDirPath stringByAppendingPathComponent:@"iTunesMetadata.plist"] newname:@"iTunesMetadata.plist"];

            if (isBackupFull) {
                if (quietInstall == 0)
                    printf("Backing up application data...\n");

                NSArray *dataContents = [fileMgr contentsOfDirectoryAtPath:dataPath error:nil];
                for (NSString *file in dataContents) {
                    if ([file hasSuffix:@".app"] ||
                        [file isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"] ||
                        [file isEqualToString:@".com.apple.mobileinstallation.placeholder"] ||
                        [file isEqualToString:@".GlobalPreferences.plist"] ||
                        [file isEqualToString:@"com.apple.PeoplePicker.plist"] ||
                        [file isEqualToString:@"iTunesArtwork"] ||
                        [file isEqualToString:@"iTunesMetadata.plist"])
                        continue;

                    if ([file isEqualToString:@"Library"]){
                        BOOL globalMoved = NO;
                        if ([fileMgr moveItemAtPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"] toPath:[dataPath stringByAppendingPathComponent:@".GlobalPreferences.plist"] error:nil])
                            globalMoved = YES;
                        BOOL pickerMoved = NO;
                        if ([fileMgr moveItemAtPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences/com.apple.PeoplePicker.plist"] toPath:[dataPath stringByAppendingPathComponent:@"com.apple.PeoplePicker.plist"] error:nil])
                            pickerMoved = YES;

                        [ipaArchive addDirectoryToZip:[dataPath stringByAppendingPathComponent:@"Library"] toPathInZip:@"Container/Library/"];
                        if (globalMoved)
                            [fileMgr moveItemAtPath:[dataPath stringByAppendingPathComponent:@".GlobalPreferences.plist"] toPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"] error:nil];
                        if (pickerMoved)
                            [fileMgr moveItemAtPath:[dataPath stringByAppendingPathComponent:@"com.apple.PeoplePicker.plist"] toPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences/com.apple.PeoplePicker.plist"] error:nil];
                    } else {
                        NSString *sourcePath = [dataPath stringByAppendingPathComponent:file];
                        BOOL isDir;
                        if ([fileMgr fileExistsAtPath:sourcePath isDirectory:&isDir] && isDir)
                            [ipaArchive addDirectoryToZip:sourcePath toPathInZip:[NSString stringWithFormat:@"Container/%@/", file]];
                        else
                            [ipaArchive addFileToZip:sourcePath newname:[NSString stringWithFormat:@"Container/%@/", file]];
                    }
                }
            }

            [ipaArchive release];

            if (savePath) {
                NSString *saveDir = [savePath stringByDeletingLastPathComponent];

                BOOL isDirectory;
                if ([fileMgr fileExistsAtPath:saveDir isDirectory:&isDirectory]) {
                    if (!isDirectory) {
                        if (quietInstall < 2)
                            printf("%s is not a directory.\n", [saveDir cStringUsingEncoding:NSUTF8StringEncoding]);

                        if (!removeAllContentsUnderPath(workPath)) {
                            if (quietInstall < 2)
                                printf("Failed to clean caches.\n");
                        }

                        [pool release];
                        return IPA_FAILED;
                    }
                } else {
                    if(![fileMgr createDirectoryAtPath:saveDir withIntermediateDirectories:YES attributes:nil error:NULL] ) {
                        if (quietInstall < 2)
                            printf("Failed to create directory %s.\n", [saveDir cStringUsingEncoding:NSUTF8StringEncoding]);

                        if (!removeAllContentsUnderPath(workPath)) {
                            if (quietInstall < 2)
                                printf("Failed to clean caches.\n");
                        }

                        [pool release];
                        return IPA_FAILED;
                    }

                    //Set root folder's attributes
                    NSDictionary *directoryAttributes = [fileMgr attributesOfItemAtPath:saveDir error:nil];
                    NSMutableDictionary *defaultDirectoryAttributes = [NSMutableDictionary dictionaryWithCapacity:[directoryAttributes count]];
                    [defaultDirectoryAttributes setDictionary:directoryAttributes];

                    [defaultDirectoryAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileOwnerAccountID];
                    [defaultDirectoryAttributes setObject:@"mobile" forKey:NSFileOwnerAccountName];
                    [defaultDirectoryAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileGroupOwnerAccountID];
                    [defaultDirectoryAttributes setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];

                    [defaultDirectoryAttributes setObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions];

                    [fileMgr setAttributes:defaultDirectoryAttributes ofItemAtPath:saveDir error:nil];
                }

                //Move
                if (![fileMgr moveItemAtPath:[workPath stringByAppendingPathComponent:@"temp.zip"] toPath:savePath error:nil]) {
                    if (quietInstall < 2)
                        printf("Failed to create IPA file.\n");

                    if (!removeAllContentsUnderPath(workPath)) {
                        if (quietInstall < 2)
                            printf("Failed to clean caches.\n");
                    }

                    [pool release];
                    return IPA_FAILED;
                }

                if (!removeAllContentsUnderPath(workPath)) {
                    if (quietInstall < 2)
                        printf("Failed to clean caches.\n");
                }

                if (quietInstall == 0)
                    printf("The application has been backed up as %s.\n", [savePath cStringUsingEncoding:NSUTF8StringEncoding]);

                [pool release];
                return 0;
            } else {
                NSString *nameBase;
                if (isBackup)
                    nameBase = [NSString stringWithFormat:@"%@ (%@) v%@", getBestString(appName, appDisplayName), identifier, getBestString(appVersion, appShortVersion)];
                else
                    nameBase = [NSString stringWithFormat:@"%@ (%@) v%@ (Full)", getBestString(appName, appDisplayName), identifier, getBestString(appVersion, appShortVersion)];
                NSString *saveDir = @"/private/var/mobile/Documents";

                if (![fileMgr fileExistsAtPath:saveDir]) {
                    if(![fileMgr createDirectoryAtPath:saveDir withIntermediateDirectories:YES attributes:nil error:NULL] ) {
                        if (quietInstall < 2)
                            printf("Failed to create /var/mobile/Documents.\n");

                        if (!removeAllContentsUnderPath(workPath)) {
                            if (quietInstall < 2)
                                printf("Failed to clean caches.\n");
                        }

                        [pool release];
                        return IPA_FAILED;
                    }

                    //Set root folder's attributes
                    NSDictionary *directoryAttributes = [fileMgr attributesOfItemAtPath:saveDir error:nil];
                    NSMutableDictionary *defaultDirectoryAttributes = [NSMutableDictionary dictionaryWithCapacity:[directoryAttributes count]];
                    [defaultDirectoryAttributes setDictionary:directoryAttributes];

                    [defaultDirectoryAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileOwnerAccountID];
                    [defaultDirectoryAttributes setObject:@"mobile" forKey:NSFileOwnerAccountName];
                    [defaultDirectoryAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileGroupOwnerAccountID];
                    [defaultDirectoryAttributes setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];

                    [defaultDirectoryAttributes setObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions];

                    [fileMgr setAttributes:defaultDirectoryAttributes ofItemAtPath:saveDir error:nil];
                }

                //Move
                NSString *ipaPath = [[NSString stringWithFormat:@"%@/%@.ipa", saveDir, nameBase] stringByStandardizingPath];
                if ([fileMgr fileExistsAtPath:ipaPath]) {
                    for (int i=1; ; i++) {
                        ipaPath = [NSString stringWithFormat:@"%@/%@ %d.ipa", saveDir, nameBase, i];
                        if (![fileMgr fileExistsAtPath:ipaPath])
                            break;
                    }
                }

                if (![fileMgr moveItemAtPath:[workPath stringByAppendingPathComponent:@"temp.zip"] toPath:ipaPath error:nil]) {
                    if (quietInstall < 2)
                        printf("Failed to create IPA file.\n");

                    if (!removeAllContentsUnderPath(workPath)) {
                        if (quietInstall < 2)
                            printf("Failed to clean caches.\n");
                    }

                    [pool release];
                    return IPA_FAILED;
                }

                if (!removeAllContentsUnderPath(workPath)) {
                    if (quietInstall < 2)
                        printf("Failed to clean caches.\n");
                }

                if (quietInstall == 0)
                    printf("The application has been backed up as %s.\n", [ipaPath cStringUsingEncoding:NSUTF8StringEncoding]);

                [pool release];
                return 0;
            }
        }
    }

    NSMutableArray *ipaFiles = [NSMutableArray arrayWithCapacity:0];
    NSMutableArray *filesNotFound = [NSMutableArray arrayWithCapacity:0];
    BOOL noParameters = NO;
    BOOL showHelp = NO;
    BOOL showAbout = NO;
    for (unsigned int i=1; i<[arguments count]; i++) {
        NSString *arg = [arguments objectAtIndex:i];
        if ([arg hasPrefix:@"-" ]) {
            if ([arg length] < 2 || noParameters) {
                printf("Invalid parameters.\n");
                [pool release];
                return IPA_FAILED;
            }

            for (unsigned int j=1; j<[arg length]; j++) {
                NSString *p = [arg substringWithRange:NSMakeRange(j, 1)];
                if ([p isEqualToString:@"u"])
                    isUninstall = YES;
                else if ([p isEqualToString:@"l"])
                    isListing = YES;
                else if ([p isEqualToString:@"b"]) {
                    if (isBackupFull) {
                        printf("Parameter b and B cannot be specified at the same time.\n");
                        [pool release];
                        return IPA_FAILED;
                    }
                    isBackup = YES;
                } else if ([p isEqualToString:@"B"]) {
                    if (isBackup) {
                        printf("Parameter -b and -B cannot be specified at the same time.\n");
                        [pool release];
                        return IPA_FAILED;
                    }
                    isBackupFull = YES;
                } else if ([p isEqualToString:@"a"])
                    showAbout = YES;
                else if ([p isEqualToString:@"c"])
                    cleanInstall = YES;
                else if ([p isEqualToString:@"d"])
                    deleteFile = YES;
                else if ([p isEqualToString:@"i"] || [p isEqualToString:@"I"])
                    isGetInfo = YES;
                else if ([p isEqualToString:@"f"])
                    forceInstall = YES;
                else if ([p isEqualToString:@"h"])
                    showHelp = YES;
                else if ([p isEqualToString:@"n"])
                    notRestore = YES;
                else if ([p isEqualToString:@"q"]) {
                    if (quietInstall != 0) {
                        printf("Parameter -q and -Q cannot be specified at the same time.\n");
                        [pool release];
                        return IPA_FAILED;
                    }
                    quietInstall = 1;
                } else if ([p isEqualToString:@"Q"]) {
                    if (quietInstall != 0) {
                        printf("Parameter -q and -Q cannot be specified at the same time.\n");
                        [pool release];
                        return IPA_FAILED;
                    }
                    quietInstall = 2;
                } else if ([p isEqualToString:@"r"])
                    removeMetadata = YES;
                else if ([p isEqualToString:@"o"]) {
                    if (!isBackup && !isBackupFull) {
                        printf("You must specify -b or -B before -o.\n");
                        [pool release];
                        return IPA_FAILED;
                    }
                } else {
                    printf("Invalid parameter '%s'.\n", [p cStringUsingEncoding:NSUTF8StringEncoding]);
                    [pool release];
                    return IPA_FAILED;
                }
            }
        } else {
            if (!isBackup && !isBackupFull) {
                noParameters = YES;
                NSURL *url = [NSURL fileURLWithPath:arg isDirectory:NO];
                BOOL isDirectory;
                if (url && [fileMgr fileExistsAtPath:[[url absoluteURL] path] isDirectory:&isDirectory]) {
                    if (isDirectory)
                        [filesNotFound addObject:arg];
                    else
                        [ipaFiles addObject:[[url absoluteURL] path]]; //File exists
                } else
                    [filesNotFound addObject:arg];
            }
        }
    }

    if (isListing) {
        getInstalledApplications();
        if ([arguments count] != 2) {
            printf("Invalid parameters.\n");
            [pool release];
            return IPA_FAILED;
        } else {
            NSArray * identifiers = getInstalledApplications();

            for (unsigned int i=0; i<[identifiers count]; i++)
                printf("%s\n", [(NSString *)[identifiers objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
            [pool release];
            return 0;
        }
    }

    if ((showAbout && showHelp) ||
        ((showAbout || showHelp) &&
         (cleanInstall ||
          deleteFile ||
          forceInstall ||
          notRestore ||
          quietInstall != 0 ||
          removeMetadata ||
          ([ipaFiles count] + [filesNotFound count] > 0)))) {
        printf("Invalid parameters.\n");
        [pool release];
        return IPA_FAILED;
    }

    if (showHelp) {
        printf("%s\n", [helpString cStringUsingEncoding:NSUTF8StringEncoding]);
        [pool release];
        return 0;
    }

    if (showAbout) {
        printf("%s\n", [aboutString cStringUsingEncoding:NSUTF8StringEncoding]);
        [pool release];
        return 0;
    }

    for (unsigned int i=0; i<[filesNotFound count]; i++) {
        if (quietInstall < 2)
            printf("File not found at path: %s.\n", [[filesNotFound objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
    }

    if ([ipaFiles count] < 1) {
        if (quietInstall < 2)
            printf("Please specify any IPA file(s) to install.\n");
        [pool release];
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
    if (quietInstall == 0 && deleteFile) {
        if ([ipaFiles count] == 1)
            printf("%s will be deleted after installation.\n", [[[ipaFiles objectAtIndex:0] lastPathComponent] cStringUsingEncoding:NSUTF8StringEncoding]);
        else
            printf("IPA files will be deleted after installation.\n");
    }

    if (quietInstall == 0 && (cleanInstall || forceInstall || notRestore || removeMetadata || deleteFile))
        printf("\n");

    NSArray *filesInTemp = [fileMgr contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
    for (NSString *file in filesInTemp) {
        file = [NSTemporaryDirectory() stringByAppendingPathComponent:[file lastPathComponent]];
        if ([[file lastPathComponent] hasPrefix:@"com.autopear.ipainstaller."] && ![fileMgr removeItemAtPath:file error:nil]) {
            if (quietInstall < 2)
                printf("Failed to delete %s.\n", [file cStringUsingEncoding:NSUTF8StringEncoding]);
        }
    }

    NSString *workPath = nil;
    while (YES) {
        workPath = [NSString stringWithFormat:@"com.autopear.ipainstaller.%@", randomStringInLength(6)];
        workPath = [NSTemporaryDirectory() stringByAppendingPathComponent:workPath];
        if (![fileMgr fileExistsAtPath:workPath])
            break;
    }

    if(![fileMgr createDirectoryAtPath:workPath withIntermediateDirectories:YES attributes:nil error:NULL]) {
        if (quietInstall < 2)
            printf("Failed to create workspace.\n");
        [pool release];
        return IPA_FAILED;
    }

    NSString *installPath = [workPath stringByAppendingPathComponent:@"tmp.install.ipa"];

    int successfulInstalls = 0;

    for (unsigned i=0; i<[ipaFiles count]; i++) {
        //Before installation, make a clean workspace
        if (!removeAllContentsUnderPath(workPath)) {
            if (quietInstall < 2)
                printf("Failed to create workspace.\n");
            [pool release];
            return IPA_FAILED;
        }

        NSString *ipa = [ipaFiles objectAtIndex:i];
        if (quietInstall == 0)
            printf("Analyzing %s...\n", [[ipa lastPathComponent] cStringUsingEncoding:NSUTF8StringEncoding]);

        BOOL isValidIPA = YES;
        BOOL hasContainer = NO;
        NSString *pathInfoPlist = nil;
        NSString *infoPath = nil;
        while (YES) {
            pathInfoPlist = [workPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.Info.plist", randomStringInLength(6)]];
            if (![fileMgr fileExistsAtPath:pathInfoPlist])
                break;
        }

        ZipArchive *ipaArchive = [[ZipArchive alloc] init];
        if ([ipaArchive unzipOpenFile:[ipaFiles objectAtIndex:i]]) {
            NSMutableArray *array = [ipaArchive getZipFileContents];
            NSMutableArray *infoStrings = [NSMutableArray arrayWithCapacity:0];
            NSString *appPathName = nil;

            int cnt = 0;
            for (unsigned int j=0; j<[array count]; j++) {
                NSString *name = [array objectAtIndex:j];
                NSArray *components = [name pathComponents];
                if ([components count] > 1 && [[components objectAtIndex:0] isEqualToString:@"Container"])
                    hasContainer = YES;
                else {
                    //Extract Info.plist
                    if ([components count] == 3 &&
                        [[components objectAtIndex:0] isEqualToString:@"Payload"] &&
                        [[components objectAtIndex:1] hasSuffix:@".app"] &&
                        [[components objectAtIndex:2] isEqualToString:@"Info.plist"]) {
                        appPathName = [@"Payload" stringByAppendingPathComponent:[components objectAtIndex:1]];
                        infoPath = name;
                        cnt++;
                    }

                    //Extract InfoPlist.strings if available
                    if ([components count] == 4 &&
                        [[components objectAtIndex:0] isEqualToString:@"Payload"] &&
                        [[components objectAtIndex:1] hasSuffix:@".app"] &&
                        [[components objectAtIndex:2] hasSuffix:@".lproj"] &&
                        [[components objectAtIndex:3] isEqualToString:@"InfoPlist.strings"]) {
                        [infoStrings addObject:[components objectAtIndex:2]];
                    }
                }
            }
            if (cnt != 1)
                isValidIPA = NO;

            if (isValidIPA) {
                //Unzip Info.plist
                [ipaArchive unzipFileWithName:infoPath toPath:pathInfoPlist overwrite:YES];

                //Unzip all InfoPlist.strings
                for (unsigned int j=0; j<[infoStrings count]; j++) {
                    NSString *lprojPath = [[workPath stringByAppendingPathComponent:@"localizations"] stringByAppendingPathComponent:[infoStrings objectAtIndex:j]];
                    if ([fileMgr createDirectoryAtPath:lprojPath withIntermediateDirectories:YES attributes:nil error:NULL]) {
                        //Unzip to this directory
                        [ipaArchive unzipFileWithName:[[appPathName stringByAppendingPathComponent:[infoStrings objectAtIndex:j]] stringByAppendingPathComponent:@"InfoPlist.strings"] toPath:[lprojPath stringByAppendingPathComponent:@"InfoPlist.strings"] overwrite:YES];
                    }
                }
            }
            [ipaArchive unzipCloseFile];
        } else
            isValidIPA = NO;
        [ipaArchive release];

        if (!isValidIPA) {
            if (quietInstall < 2)
                printf("%s is not a valid IPA.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

            if (!removeAllContentsUnderPath(workPath)) {
                if (quietInstall < 2)
                    printf("Failed to clean caches.\n");
            }

            continue;
        }

        NSString *appIdentifier = nil;
        NSString *appDisplayName = nil;
        NSString *appVersion = nil;
        NSString *appShortVersion = nil;
        NSString *minSysVersion = nil;
        NSMutableArray *supportedDeives = nil;
        id requiredCapabilities = nil;

        NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfFile:pathInfoPlist];

        if (infoDict) {
            appIdentifier = [infoDict objectForKey:@"CFBundleIdentifier"];
            appVersion = [infoDict objectForKey:@"CFBundleVersion"];
            appShortVersion = [infoDict objectForKey:@"CFBundleShortVersionString"];
            minSysVersion = [infoDict objectForKey:@"MinimumOSVersion"];
            supportedDeives = [infoDict objectForKey:@"UIDeviceFamily"];
            requiredCapabilities = [infoDict objectForKey:@"UIRequiredDeviceCapabilities"];

            appDisplayName = [infoDict objectForKey:@"CFBundleDisplayName"] ? [infoDict objectForKey:@"CFBundleDisplayName"] : [infoDict objectForKey:@"CFBundleName"];

            //Obtain localized display name
            BOOL isDirectory;
            if ([fileMgr fileExistsAtPath:[workPath stringByAppendingPathComponent:@"localizations"] isDirectory:&isDirectory]) {
                if (isDirectory) {
                    NSBundle *localizedBundle = [NSBundle bundleWithPath:[workPath stringByAppendingPathComponent:@"localizations"]];

                    if ([localizedBundle localizedStringForKey:@"CFBundleDisplayName" value:nil table:@"InfoPlist"])
                        appDisplayName = [localizedBundle localizedStringForKey:@"CFBundleDisplayName" value:appDisplayName table:@"InfoPlist"];
                    else
                        appDisplayName = [localizedBundle localizedStringForKey:@"CFBundleName" value:appDisplayName table:@"InfoPlist"];

                    //Delete the directory
                    [fileMgr removeItemAtPath:[workPath stringByAppendingPathComponent:@"localizations"] error:nil];
                }
            }
        } else {
            if (quietInstall < 2)
                printf("%s is not a valid IPA.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

            if (!removeAllContentsUnderPath(workPath)) {
                if (quietInstall < 2)
                    printf("Failed to clean caches.\n");
            }

            continue;
        }

        if (!appIdentifier || !appDisplayName || !appVersion) {
            if (quietInstall < 2)
                printf("%s is not a valid IPA.%s", [[ipaFiles objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

            if (!removeAllContentsUnderPath(workPath)) {
                if (quietInstall < 2)
                    printf("Failed to clean caches.\n");
            }

            continue;
        }

        //Make a copy of extracted Info.plist
        NSString *pathOriginalInfoPlist = [NSString stringWithFormat:@"%@.original", pathInfoPlist];
        if ([fileMgr fileExistsAtPath:pathOriginalInfoPlist]) {
            if (![fileMgr removeItemAtPath:pathOriginalInfoPlist error:nil]) {
                if (![fileMgr copyItemAtPath:pathInfoPlist toPath:pathOriginalInfoPlist error:nil]) {
                    //Force installation has to be disabled.
                    if (forceInstall && quietInstall < 2)
                        printf("Force installation has to be disabled.\n");
                    forceInstall = NO;
                }
            }
        } else {
            if (![fileMgr copyItemAtPath:pathInfoPlist toPath:pathOriginalInfoPlist error:nil]) {
                //Force installation has to be disabled.
                if (forceInstall && quietInstall < 2)
                    printf("Force installation has to be disabled.\n");
                forceInstall = NO;
            }
        }

        //Check installed stats
        NSDictionary *installedAppDict = getInstalledAppInfo(appIdentifier);

        BOOL appAlreadyInstalled = NO;
        if (installedAppDict) {
            appAlreadyInstalled = YES;

            NSString *installedVerion = [installedAppDict objectForKey:@"VERSION"];
            NSString *installedShortVersion = [installedAppDict objectForKey:@"SHORT_VERSION"];

            if (installedShortVersion != nil && appShortVersion != nil) {
                if (versionCompare(installedShortVersion, appShortVersion) == 1) {
                    //Skip to avoid overriding a new version
                    if (forceInstall) {
                        if (quietInstall == 0)
                            printf("%s (v%s) is already installed. Will force to downgrade.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [installedShortVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    } else {
                        if (quietInstall < 2)
                            printf("%s (v%s) is already installed. You may use -f parameter to force downgrade.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [installedShortVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                        if (!removeAllContentsUnderPath(workPath)) {
                            if (quietInstall < 2)
                                printf("Failed to clean caches.\n");
                        }

                        continue;
                    }
                }
            } else {
                if (versionCompare(installedVerion, appVersion) == 1) {
                    //Skip to avoid overriding a new version
                    if (forceInstall) {
                        if (quietInstall == 0)
                            printf("%s (v%s) is already installed. Will force to downgrade.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [installedVerion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                    } else {
                        if (quietInstall < 2)
                            printf("%s (v%s) is already installed. You may use -f parameter to force downgrade.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [installedVerion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
                        if (!removeAllContentsUnderPath(workPath)) {
                            if (quietInstall < 2)
                                printf("Failed to clean caches.\n");
                        }

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
        if (!supportedDeives || [supportedDeives count] == 0) {
            supportiPhone = YES;
            supportiPad = YES;
            supportAppleTV = YES;
        } else {
            for (unsigned int j=0; j<[supportedDeives count]; j++) {
                int d =[[supportedDeives objectAtIndex:j] intValue];
                if (d == 1) {
                    supportiPhone = YES;
                    supportiPad = YES;
                }
                if (d == 2)
                    supportiPad = YES;
                if (d == 3)
                    supportAppleTV = YES;
            }
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

        if ((DeviceModel == 1 && !supportiPhone) || //Not support iPhone / iPod touch
            (DeviceModel == 2 && !supportiPad) || //Not support iPad
            (DeviceModel == 3 && !supportAppleTV)) { //Not support Apple TV
            //Device not supported
            if (forceInstall) {
                if (quietInstall == 0)
                    printf("%s (v%s) requires %s while your device is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [supportedDeivesString cStringUsingEncoding:NSUTF8StringEncoding], [deviceString cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                [supportedDeives addObject:[NSNumber numberWithInt:DeviceModel]];
                [infoDict setObject:[supportedDeives sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIDeviceFamily"];
                shouldUpdateInfoPlist = YES;
            } else {
                if (quietInstall < 2)
                    printf("%s (v%s) requires %s while your device is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [supportedDeivesString cStringUsingEncoding:NSUTF8StringEncoding], [deviceString cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                if (!removeAllContentsUnderPath(workPath)) {
                    if (quietInstall < 2)
                        printf("Failed to clean caches.\n");
                }

                continue;
            }
        }

        //Check minimun system requirement
        if (minSysVersion && versionCompare(minSysVersion, SystemVersion) == 1) {
            //System version is less than the min required version
            if (forceInstall) {
                if (quietInstall == 0)
                    printf("%s (v%s) requires iOS %s while your system is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [minSysVersion cStringUsingEncoding:NSUTF8StringEncoding], [SystemVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                [infoDict setObject:SystemVersion forKey:@"MinimumOSVersion"];
                shouldUpdateInfoPlist = YES;
            } else {
                if (quietInstall < 2)
                    printf("%s (v%s) requires iOS %s while your system is %s.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], [minSysVersion cStringUsingEncoding:NSUTF8StringEncoding], [SystemVersion cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) || forceInstall ? "\n" : "\n\n");

                if (!removeAllContentsUnderPath(workPath)) {
                    if (quietInstall < 2)
                        printf("Failed to clean caches.\n");
                }

                continue;
            }
        }

        //Chekc capabilities
        if (requiredCapabilities) {
            BOOL isCapable = YES;
            //requiredCapabilities is NSArray, contains only strings
            if ([requiredCapabilities isKindOfClass:[NSArray class]]) {
                NSMutableArray *newCapabilities = [NSMutableArray arrayWithCapacity:0];

                for (unsigned int j=0; j<[(NSArray *)requiredCapabilities count]; j++) {
                    NSString *capability = [(NSArray *)requiredCapabilities objectAtIndex:j];
                    if ([[UIDevice currentDevice] supportsCapability:capability])
                        [newCapabilities addObject:capability];
                    else {
                        isCapable = NO;
                        if (forceInstall) {
                            if (quietInstall == 0)
                                printf("Your device does not support %s capability.\n", [capability cStringUsingEncoding:NSUTF8StringEncoding]);

                            shouldUpdateInfoPlist = YES;
                        } else {
                            if (quietInstall < 2)
                                printf("Your device does not support %s capability.\n", [capability cStringUsingEncoding:NSUTF8StringEncoding]);
                        }
                    }
                }

                if (!isCapable) {
                    if (forceInstall)
                        [infoDict setObject:[newCapabilities sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIRequiredDeviceCapabilities"];
                    else {
                        if (!removeAllContentsUnderPath(workPath)) {
                            if (quietInstall < 2)
                                printf("Failed to clean caches.\n");
                        }

                        if (i != [ipaFiles count] - 1) //Not the last output
                            printf("\n");

                        continue;
                    }
                }
            } else if ([requiredCapabilities isKindOfClass:[NSDictionary class]]) {
                //requiredCapabilities is NSDictionary, contains only key-object pairs
                NSMutableDictionary *newCapabilities = [NSMutableDictionary dictionaryWithCapacity:0];

                for (NSString *capabilityKey in [(NSDictionary *)requiredCapabilities allKeys]) {
                    BOOL capabilityValue = [[(NSDictionary *)requiredCapabilities objectForKey:capabilityKey] boolValue];

                    //Only boolean value
                    if (capabilityValue == [[UIDevice currentDevice] supportsCapability:capabilityKey])
                        [newCapabilities setObject:[NSNumber numberWithBool:!capabilityValue] forKey:capabilityKey];
                    else {
                        isCapable = NO;
                        if (forceInstall) {
                            if (quietInstall == 0) {
                                if (capabilityValue) //Device does not support
                                    printf("Your device does not support %s capability.\n", [capabilityKey cStringUsingEncoding:NSUTF8StringEncoding]);
                                else //Device support but IPA requires to be false
                                    printf("Your device conflicts with %s capability.\n", [capabilityKey cStringUsingEncoding:NSUTF8StringEncoding]);
                            }

                            shouldUpdateInfoPlist = YES;
                        } else {
                            if (quietInstall < 2) {
                                if (capabilityValue) //Device does not support
                                    printf("Your device does not support %s capability.\n", [capabilityKey cStringUsingEncoding:NSUTF8StringEncoding]);
                                else //Device support but IPA requires to be false
                                    printf("Your device conflicts with %s capability.\n", [capabilityKey cStringUsingEncoding:NSUTF8StringEncoding]);
                            }
                        }
                    }
                }
                if (!isCapable) {
                    if (forceInstall)
                        [infoDict setObject:newCapabilities forKey:@"UIRequiredDeviceCapabilities"];
                    else {
                        if (!removeAllContentsUnderPath(workPath)) {
                            if (quietInstall < 2)
                                printf("Failed to clean caches.\n");
                        }

                        if (i != [ipaFiles count] - 1) //Not the last output
                            printf("\n");

                        continue;
                    }
                }
            }
        }

        if (shouldUpdateInfoPlist && ![infoDict writeToFile:pathInfoPlist atomically:YES]) {
            if (quietInstall < 2)
                printf("Failed to use force installation mode, %s (v%s) will not be installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");
            continue;
        }

        //Copy file to install
        if ([fileMgr fileExistsAtPath:installPath]) {
            if (![fileMgr removeItemAtPath:installPath error:nil]) {
                if (quietInstall < 2)
                    printf("Failed to delete %s.\n", [installPath cStringUsingEncoding:NSUTF8StringEncoding]);

                if (![fileMgr removeItemAtPath:workPath error:nil]) {
                    if (quietInstall < 2)
                        printf("Failed to clean caches.\n");
                }

                [pool release];
                return IPA_FAILED;
            }
        }

        if (![fileMgr copyItemAtPath:ipa toPath:installPath error:nil]) {
            if (quietInstall < 2)
                printf("Failed to create temporaty files.\n");

            if (![fileMgr removeItemAtPath:workPath error:nil] && quietInstall < 2)
                printf("Failed to clean caches.\n");

            [pool release];
            return IPA_FAILED;
        }

        //Modify ipa to force install
        if (shouldUpdateInfoPlist) {
            BOOL shouldContinue = NO;
            ZipArchive *tmpArchive = [[ZipArchive alloc] init];
            // APPEND_STATUS_ADDINZIP = 2
            if ([tmpArchive openZipFile2:installPath withZipModel:APPEND_STATUS_ADDINZIP] && ![tmpArchive addFileToZip:pathInfoPlist newname:infoPath]) {
                if (quietInstall < 2)
                    printf("Failed to use force installation mode, %s (v%s) will not be installed.%s", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

                //Delete copied file
                [fileMgr removeItemAtPath:installPath error:nil];

                shouldContinue = YES;
            }
            [tmpArchive release];

            //Remove extracted Info.plist
            [fileMgr removeItemAtPath:pathInfoPlist error:nil];

            if (shouldContinue) {
                if (!removeAllContentsUnderPath(workPath)) {
                    if (quietInstall < 2)
                        printf("Failed to clean caches.\n");
                }

                continue;
            }
        }

        if (quietInstall == 0)
            printf("%snstalling %s (v%s)...\n", shouldUpdateInfoPlist ? "Force i" : "I", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);

        //Set permission before installation
        setPermissionsForPath(workPath);

        int ret = installApp(installPath, appIdentifier);

        if (ret == 0) {
            //Get installation path
            NSDictionary *installedAppDict = getInstalledAppInfo(appIdentifier);

            if (installedAppDict) {
                NSString *installedVerion = [installedAppDict objectForKey:@"VERSION"];
                NSString *installedShortVersion = [installedAppDict objectForKey:@"SHORT_VERSION"];
                NSString *installedAppLocation = [installedAppDict objectForKey:@"BUNDLE_PATH"];
                NSString *installedDataLocation = [installedAppDict objectForKey:@"DATA_PATH"];
                NSString *appDirPath = [installedAppDict objectForKey:@"APP_PATH"];

                BOOL appInstalled = YES;
                if (appInstalled && versionCompare(installedVerion, appVersion) != 0)
                    appInstalled = NO;
                if (appInstalled && versionCompare(installedShortVersion, appShortVersion) != 0)
                    appInstalled = NO;

                if (appInstalled) {
                    //Recover the original Info.plist in force installation
                    if (shouldUpdateInfoPlist) {
                        NSString *pathInstalledInfoPlist = [NSString stringWithFormat:@"%@/%@/Info.plist", installedAppLocation, [[infoPath pathComponents] objectAtIndex:1]];
                        BOOL isDirectory;
                        if ([fileMgr fileExistsAtPath:pathInstalledInfoPlist isDirectory:&isDirectory]) {
                            if (!isDirectory) {
                                if ([fileMgr removeItemAtPath:pathInstalledInfoPlist error:nil]) {
                                    if ([fileMgr moveItemAtPath:pathOriginalInfoPlist toPath:pathInstalledInfoPlist error:nil]) {
                                        if ([fileMgr fileExistsAtPath:pathOriginalInfoPlist])
                                            [fileMgr removeItemAtPath:pathOriginalInfoPlist error:nil];
                                    }
                                }
                            }
                        }
                    }

                    successfulInstalls++;
                    if (quietInstall == 0)
                        printf("%snstalled %s (v%s) successfully%s.\n", shouldUpdateInfoPlist ? "Force i" : "I", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding], shouldUpdateInfoPlist ? ", but it may not work properly" : "");

                    BOOL tempEnableClean = NO;
                    if (!cleanInstall && hasContainer && !notRestore) {
                        tempEnableClean = YES;
                        cleanInstall = YES;
                    }

                    //Clear documents, etc.
                    if (appAlreadyInstalled && cleanInstall) {
                        if (quietInstall == 0)
                            printf("Cleaning old contents of %s...\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);

                        BOOL allContentsCleaned = YES;

                        NSArray *dataContents = [fileMgr contentsOfDirectoryAtPath:installedDataLocation error:nil];
                        for (NSString *file in dataContents) {
                            if ([file hasSuffix:@".app"] ||
                                [file isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"] ||
                                [file isEqualToString:@".com.apple.mobileinstallation.placeholder"] ||
                                [file isEqualToString:@"iTunesArtwork"] ||
                                [file isEqualToString:@"iTunesMetadata.plist"])
                                continue;

                            if ([file isEqualToString:@"Library"]){
                                NSString *dirLibrary = [installedDataLocation stringByAppendingPathComponent:@"Library"];
                                NSString *dirPreferences = [dirLibrary stringByAppendingPathComponent:@"Preferences"];
                                NSString *dirCaches = [dirLibrary stringByAppendingPathComponent:@"Caches"];

                                NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:dirLibrary error:nil];
                                for (int unsigned j=0; j<[dirContents count]; j++) {
                                    NSString *fileName = [dirContents objectAtIndex:j];
                                    if ([fileName isEqualToString:@"Preferences"]) {
                                        NSArray *preferencesContents = [fileMgr contentsOfDirectoryAtPath:dirPreferences error:nil];
                                        for (unsigned int k=0; k<[preferencesContents count]; k++) {
                                            NSString *preferenceFile = [preferencesContents objectAtIndex:k];
                                            if (![preferenceFile isEqualToString:@".GlobalPreferences.plist"] && ![preferenceFile isEqualToString:@"com.apple.PeoplePicker.plist"]) {
                                                if (![fileMgr removeItemAtPath:[dirPreferences stringByAppendingPathComponent:preferenceFile] error:nil])
                                                    allContentsCleaned = NO;
                                            }
                                        }
                                    } else if ([fileName isEqualToString:@"Caches"]) {
                                        NSArray *cachesContents = [fileMgr contentsOfDirectoryAtPath:dirCaches error:nil];
                                        for (unsigned int k=0; k<[cachesContents count]; k++) {
                                            if (![fileMgr removeItemAtPath:[dirCaches stringByAppendingPathComponent:[cachesContents objectAtIndex:k]] error:nil])
                                                allContentsCleaned = NO;
                                        }
                                    } else {
                                        if (![fileMgr removeItemAtPath:[dirLibrary stringByAppendingPathComponent:fileName] error:nil])
                                            allContentsCleaned = NO;
                                    }
                                }
                            } else {
                                NSString *sourcePath = [installedDataLocation stringByAppendingPathComponent:file];
                                BOOL isDir;
                                if ([fileMgr fileExistsAtPath:sourcePath isDirectory:&isDir] && isDir) {
                                    NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:sourcePath error:nil];
                                    for (int unsigned j=0; j<[dirContents count]; j++) {
                                        if (![fileMgr removeItemAtPath:[sourcePath stringByAppendingPathComponent:[dirContents objectAtIndex:j]] error:nil])
                                            allContentsCleaned = NO;
                                    }
                                } else {
                                    if (![fileMgr removeItemAtPath:sourcePath error:nil])
                                        allContentsCleaned = NO;
                                }
                            }
                        }

                        if (!allContentsCleaned) {
                            if (quietInstall < 2)
                                printf("Failed to clean old contents of %s.\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);
                        }
                    }

                    if (tempEnableClean)
                        cleanInstall = NO;

                    //Recover documents
                    if (!cleanInstall && hasContainer && !notRestore) {
                        //The tmp ipa file is already deleted.
                        ipaArchive = [[ZipArchive alloc] init];
                        if ([ipaArchive unzipOpenFile:[ipaFiles objectAtIndex:i]]) {
                            if ([ipaArchive unzipFileWithName:@"Container" toPath:[workPath stringByAppendingPathComponent:@"Container"] overwrite:YES]) {
                                NSString *containerPath = [workPath stringByAppendingPathComponent:@"Container"];

                                NSArray *containerContents = [fileMgr contentsOfDirectoryAtPath:containerPath error:nil];
                                if ([containerContents count] > 0) {
                                    BOOL allSuccessfull = YES;
                                    for (unsigned int j=0; j<[containerContents count]; j++) {
                                        NSString *dirName = [containerContents objectAtIndex:j];
                                        if ([dirName isEqualToString:@"Library"]) {
                                            NSString *containerLibraryPath = [containerPath stringByAppendingPathComponent:dirName];
                                            NSArray *containerLibraryContents = [fileMgr contentsOfDirectoryAtPath:containerLibraryPath error:nil];
                                            for (unsigned int k=0; k<[containerLibraryContents count]; k++) {
                                                NSString *dirLibraryName = [containerLibraryContents objectAtIndex:k];
                                                if ([dirLibraryName isEqualToString:@"Caches"]) {
                                                    NSString *dirCachePath = [containerLibraryPath stringByAppendingPathComponent:dirLibraryName];
                                                    NSArray *containerCachesContents = [fileMgr contentsOfDirectoryAtPath:dirCachePath error:nil];
                                                    for (unsigned int m=0; m<[containerCachesContents count]; m++) {
                                                        if (![fileMgr moveItemAtPath:[dirCachePath stringByAppendingPathComponent:[containerCachesContents objectAtIndex:m]] toPath:[[[installedDataLocation stringByAppendingPathComponent:dirName] stringByAppendingPathComponent:dirLibraryName] stringByAppendingPathComponent:[containerCachesContents objectAtIndex:m]] error:nil])
                                                            allSuccessfull = NO;
                                                    }
                                                } else if ([dirLibraryName isEqualToString:@"Preferences"]) {
                                                    NSString *dirPreferencesPath = [containerLibraryPath stringByAppendingPathComponent:dirLibraryName];
                                                    NSArray *containerPreferencesContents = [fileMgr contentsOfDirectoryAtPath:dirPreferencesPath error:nil];
                                                    for (unsigned int m=0; m<[containerPreferencesContents count]; m++) {
                                                        NSString *preferencesFileName = [containerPreferencesContents objectAtIndex:m];
                                                        if (![preferencesFileName isEqualToString:@".GlobalPreferences.plist"] && ![preferencesFileName isEqualToString:@"com.apple.PeoplePicker.plist"]) {
                                                            if (![fileMgr moveItemAtPath:[dirPreferencesPath stringByAppendingPathComponent:preferencesFileName] toPath:[[[installedDataLocation stringByAppendingPathComponent:dirName] stringByAppendingPathComponent:dirLibraryName] stringByAppendingPathComponent:preferencesFileName] error:nil])
                                                                allSuccessfull = NO;
                                                        }
                                                    }
                                                } else {
                                                    if (![fileMgr moveItemAtPath:[containerLibraryPath stringByAppendingPathComponent:dirLibraryName] toPath:[[installedDataLocation stringByAppendingPathComponent:dirName] stringByAppendingPathComponent:dirLibraryName] error:nil])
                                                        allSuccessfull = NO;
                                                }
                                            }
                                        } else {
                                            NSString *containerSourcePath = [containerPath stringByAppendingPathComponent:dirName];
                                            NSString *destPath = [installedDataLocation stringByAppendingPathComponent:dirName];
                                            if ([fileMgr fileExistsAtPath:destPath]) {
                                                if ([fileMgr removeItemAtPath:destPath error:nil]) {
                                                    if (![fileMgr moveItemAtPath:containerSourcePath toPath:destPath error:nil])
                                                        allSuccessfull = NO;
                                                } else
                                                    allSuccessfull = NO;
                                            } else {
                                                if (![fileMgr moveItemAtPath:containerSourcePath toPath:destPath error:nil])
                                                    allSuccessfull = NO;
                                            }
                                        }
                                    }
                                    if (!allSuccessfull) {
                                        if (quietInstall < 2)
                                            printf("Cannot restore all saved documents and other resources.\n");
                                    }
                                }
                            }
                            [ipaArchive unzipCloseFile];
                        }
                        [ipaArchive release];
                    }

                    //Remove metadata
                    BOOL isDirectory;
                    if (removeMetadata && [fileMgr fileExistsAtPath:[installedAppLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] isDirectory:&isDirectory]) {
                        if (!isDirectory) {
                            if (quietInstall == 0)
                                printf("Removing iTunesMetadata.plist for %s...\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding]);
                            if (![fileMgr removeItemAtPath:[installedAppLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] error:nil]) {
                                if (quietInstall < 2)
                                    printf("Failed to remove %s.\n", [[installedAppLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"] cStringUsingEncoding:NSUTF8StringEncoding]);
                            }
                        }
                    }

                    //Set overall permission
                    if (kCFCoreFoundationVersionNumber < 793.00)
                        setPermissionsForPath(installedAppLocation);
                    else
                        setPermissionsForPath(installedDataLocation); //Restore data directory's user/group for writing
                    setExecutables(appDirPath);
                } else {
                    if (quietInstall < 2)
                        printf("Failed to install %s (v%s).\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
                }
            } else {
                if (quietInstall < 2)
                    printf("Failed to install %s (v%s).\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
            }
        } else {
            if (quietInstall < 2)
                printf("Failed to install %s (v%s).\n", [appDisplayName cStringUsingEncoding:NSUTF8StringEncoding], [(appShortVersion ? appShortVersion : appVersion) cStringUsingEncoding:NSUTF8StringEncoding]);
        }

        //Delete tmp ipa file
        if (!removeAllContentsUnderPath(workPath)) {
            if (quietInstall < 2)
                printf("Failed to delete %s.%s", [installPath cStringUsingEncoding:NSUTF8StringEncoding], (i == [ipaFiles count] - 1) ? "\n" : "\n\n");

            [pool release];
            return IPA_FAILED;
        }

        //Delete original ipa
        if (deleteFile && [fileMgr fileExistsAtPath:ipa]) {
            if (![fileMgr removeItemAtPath:ipa error:nil]) {
                if (quietInstall < 2)
                    printf("Failed to delete %s.\n", [ipa cStringUsingEncoding:NSUTF8StringEncoding]);
            }
        }

        if (quietInstall == 0 && i < [ipaFiles count]-1)
            printf("\n");
    }

    if (!removeAllContentsUnderPath(workPath)) {
        if (quietInstall < 2)
            printf("Failed to clean caches.\n");
    }

    [pool release];

    return successfulInstalls;
}
