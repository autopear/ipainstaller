//
//  ZipArchive.h
//  
//
//  Created by aish on 08-9-11.
//  acsolu@gmail.com
//  Copyright 2008  Inc. All rights reserved.
//
// History: 
//    09-11-2008 version 1.0    release
//    10-18-2009 version 1.1    support password protected zip files
//    10-21-2009 version 1.2    fix date bug

#import <UIKit/UIKit.h>

#include "minizip/zip.h"
#include "minizip/unzip.h"


@protocol ZipArchiveDelegate <NSObject>
@optional
-(void) ErrorMessage:(NSString*) msg;
-(BOOL) OverWriteOperation:(NSString*) file;

@end


@interface ZipArchive : NSObject {
@private
	zipFile		_zipFile;
	unzFile		_unzFile;
	
	NSString*   _password;
	id			_delegate;
}

@property (nonatomic, retain) id delegate;

- (BOOL)openZipFile2:(NSString *)zipFile withZipModel:(int)model;
- (BOOL)openZipFile2:(NSString *)zipFile Password:(NSString *)password withZipModel:(int)model;
- (BOOL)addFileToZip:(NSString*) file newname:(NSString*) newname;
- (BOOL)closeZipFile2;

- (int)unzipOpenFile:(NSString*) zipFile;
- (int)unzipOpenFile:(NSString*) zipFile Password:(NSString*) password;
- (BOOL)unzipFileTo:(NSString*) path overWrite:(BOOL) overwrite;
- (BOOL)unzipCloseFile;

- (NSMutableArray *)getZipFileContents;
- (NSArray *)unzipFileToData;
- (NSData *)unzipFileToDataWithFilename:(NSString *)name;
- (BOOL)addDirectoryToZip:(NSString*)fromPath;
- (BOOL)addDirectoryToZip:(NSString*)fromPath toPathInZip:(NSString *)toPathInZip;
- (BOOL)unzipFileWithName:(NSString *)name toPath:(NSString *)path overwrite:(BOOL)overwrite;
@end
