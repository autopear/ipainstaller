#import <UIKit/UIKit.h>
#include <dlfcn.h>

#define KEY_INSTALL_TYPE @"User"
#define KEY_SDKPATH "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"

typedef int (*MobileInstallationInstall)(NSString *path, NSDictionary *dict, void *na, NSString *backpath);

int main (int argc, char **argv, char **envp)
{
    if (argc <= 0)
        return -1;

    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    NSString *path = [[[NSString alloc] initWithUTF8String:argv[1]] autorelease];
    path = [[[NSURL fileURLWithPath:path] absoluteURL] path];
    
    void *lib = dlopen(KEY_SDKPATH, RTLD_LAZY);
    if (lib)
    {   
        MobileInstallationInstall install = (MobileInstallationInstall)dlsym(lib, "MobileInstallationInstall");
        if (install)
        {
            int c = install(path, [NSDictionary dictionaryWithObject:KEY_INSTALL_TYPE forKey:@"ApplicationType"], 0, path);
            dlclose(lib);
            return c;
        }
    }
    
    [pool release];
    return 0;
}
