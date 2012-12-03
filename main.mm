#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZipArchive.h"
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

static BOOL quietInstall = NO;
static BOOL forceInstall = NO;
static BOOL removeMetadata = NO;
static BOOL deleteFile = NO;

int main (int argc, char **argv, char **envp)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    NSArray *arguments = [[NSProcessInfo processInfo] arguments];

    if ([arguments count] < 1)
        return IPA_FAILED;
    
    NSString *executableName = [[arguments objectAtIndex:0] lastPathComponent];
    
    NSString *helpString = [NSString stringWithFormat:@"Usage: %@ [OPTION]... [FILE]...\n\nOptions:\n    -a  Show about information.\n    -d  Delete IPA file(s) after installation.\n    -f  Force installation, do not check compatibilities and application version.\n    -h  Display usage information.\n    -q  Quiet mode, suppress all outputs.\n    -r  Remove Metadata.plist.", executableName];

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
                else if ([p isEqualToString:@"d"])
                    deleteFile = YES;
                else if ([p isEqualToString:@"f"])
                    forceInstall = YES;
                else if ([p isEqualToString:@"h"])
                    showHelp = YES;
                else if ([p isEqualToString:@"q"])
                    quietInstall = YES;
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
    
    if ((showAbout && showHelp ) ||(showAbout && (deleteFile || forceInstall || quietInstall || removeMetadata)) || (showHelp && (deleteFile || forceInstall || quietInstall || removeMetadata)))
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
        printf("File not found at path: \"%s\"'.\n", [[filesNotFound objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding]);
    }

    if ([ipaFiles count] < 1)
    {
        printf("Please specify any IPA file(s) to install.\n");
        return IPA_FAILED;
    }
    
    if (!quietInstall && forceInstall)
        printf("Force installation enabled.\n");
    if (!quietInstall && removeMetadata)
        printf("iTunesMetadata.plist will be removed after installation.\n");
    if (!quietInstall && deleteFile)
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
                    if (![[NSFileManager defaultManager] removeItemAtPath:file error:nil])
                        printf("Cannot delete \"%s\".\n", [file cStringUsingEncoding:NSUTF8StringEncoding]);
                }
            }
            
            NSString *workPath = nil;
            while (YES)
            {
                NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
                workPath = @"com.autopear.installipa.";

                for (int i=0; i<4; i++)
                {
                    workPath = [NSString stringWithFormat:@"%@%C", workPath, [letters characterAtIndex:arc4random() % [letters length]]];
                }
                
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

            if(![[NSFileManager defaultManager] createDirectoryAtPath:workPath withIntermediateDirectories:YES attributes:attrDir error:NULL])
            {
                printf("Failed to create workspace.\n");
                return IPA_FAILED;
            }

            NSString *installPath = [workPath stringByAppendingPathComponent:@"tmp.install.ipa"];
            
            for (unsigned i=0; i<[ipaFiles count]; i++)
            {
                NSString *ipa = [ipaFiles objectAtIndex:i];
                if (!quietInstall)
                    printf("Installing %d of %d \"%s\"'.\n", (i+1), [ipaFiles count], [[ipa lastPathComponent] cStringUsingEncoding:NSUTF8StringEncoding]);
                
                /*
                ZipArchive *za = [[ZipArchive alloc] init];
                if ([za UnzipOpenFile: @"/Volumes/data/testfolder/Archive.zip"]) {
                    BOOL ret = [za UnzipFileTo: @"/Volumes/data/testfolde/extract" overWrite: YES];
                    if (NO == ret){} [za UnzipCloseFile];
                }
                [za release];
                 */
                //Copy file to install
                if ([[NSFileManager defaultManager] fileExistsAtPath:installPath])
                {
                    if (![[NSFileManager defaultManager] removeItemAtPath:installPath error:nil])
                    {
                        printf("Failed to delete \"%s\".\n", [installPath cStringUsingEncoding:NSUTF8StringEncoding]);
                        return IPA_FAILED;
                    }
                }
                
                if (![[NSFileManager defaultManager] copyItemAtPath:ipa toPath:installPath error:nil])
                {
                    printf("Failed to create temporaty files.\n");
                    return IPA_FAILED;
                }
                
                int ret = install(installPath, [NSDictionary dictionaryWithObject:KEY_INSTALL_TYPE forKey:@"ApplicationType"], 0, installPath);
                if (ret == 0)
                {
                    successfulInstalls++;
                    if (!quietInstall)
                    {
                        if (i == [ipaFiles count] - 1)
                            printf("Installed successfully.\n");
                        else
                            printf("Installed successfully.\n\n");
                    }
                }
                else
                {
                    if (!quietInstall)
                    {
                        if (i == [ipaFiles count] - 1)
                            printf("Installlation failed.\n");
                        else
                            printf("Installlation failed.\n\n");
                    }
                }
                
                //Delete file
                if ([[NSFileManager defaultManager] fileExistsAtPath:installPath])
                {
                    if (![[NSFileManager defaultManager] removeItemAtPath:installPath error:nil])
                        printf("Failed to delete \"%s\".\n", [installPath cStringUsingEncoding:NSUTF8StringEncoding]);
                        return IPA_FAILED;
                }
                
                if (deleteFile && [[NSFileManager defaultManager] fileExistsAtPath:ipa])
                {
                    NSError *err;
                    [[NSFileManager defaultManager] removeItemAtPath:installPath error:&err];
                    if (err)
                        printf("Failed to delete \"%s\".\nReason: %s", [ipa cStringUsingEncoding:NSUTF8StringEncoding], [[err localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding]);
                }
            }
        }
    }
    dlclose(lib);

    [pool release];

    return successfulInstalls;
}
