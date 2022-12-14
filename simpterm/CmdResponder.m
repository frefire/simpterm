//
//  CmdResponder.m
//  simpterm
//
//  Created by Eric Wong on 2022/12/12.
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "SSZipArchive.h"

static NSString *sCurDir;
static NSDictionary *sCmdResponders;

static NSString *sPathBundle;
static NSString *sPathLibrary;
static NSString *sPathDocument;

static NSDictionary *sPredefinedMacros;

static
NSString *
resolvePath(NSString *path) {
    return [[path stringByExpandingTildeInPath] stringByStandardizingPath];
}

static
NSString *
escapeCharacters(NSString *str) {
    // Only support \(space), \', \", \\ For now.
    NSUInteger len = [str length];
    for (NSUInteger i = 0; i < len; i ++) {
        if ([str characterAtIndex:i] == '\\') {
            if (i + 1 < len) {
                switch ([str characterAtIndex:(i + 1)]) {
                    case ' ':
                    case '\'':
                    case '\"':
                    case '\\':
                        str = [str stringByReplacingCharactersInRange:NSMakeRange(i, 1) withString:@""];
                        len --;
                        break;
                    default:
                        NSLog(@"Unknown escape character: %c",
                              [str characterAtIndex:(i + 1)]);
                        return nil;
                        //break;
                }
            } else {
                NSLog(@"Escape character at the end of a line.");
                return nil;
            }
        }
    }
    
    return str;
}

static
NSString *
expandPredefinedMacros(NSString *path) {
    for (NSString *key in sPredefinedMacros.allKeys) {
        path = [path stringByReplacingOccurrencesOfString:key withString:sPredefinedMacros[key]];
    }
    return path;
}

static
NSString *
standardizePath(NSString *path) {
    NSString *result;
    result = expandPredefinedMacros(path);
    
    if (![result isAbsolutePath]) {
        result = [sCurDir stringByAppendingPathComponent:result];
    }
    
    result = escapeCharacters(result);
    return resolvePath(result);
}

static
NSArray<NSString *> *
breakCmdIntoPieces(NSString *whole) {
    NSUInteger len = [whole length];
    int index = 0, next_index;
    NSMutableArray<NSString *> *result = [[NSMutableArray alloc] init];
    
    while (index < [whole length]) {
        BOOL startWithQuote = NO;
        NSString *op = nil;
        
        while ([whole characterAtIndex:index] == ' ' && index < len) index ++;
        if (index == len) return result;
        
        if ([whole characterAtIndex:index] == '\"') startWithQuote = YES;
        
        next_index = index;
        BOOL breakCycle = NO;
        while (next_index < len) {
            switch ([whole characterAtIndex:next_index]) {
                case '\\':
                    // escape character, ignore next char in case it's space
                    // or a quote
                    next_index ++;
                    break;
                case ' ':
                    if (!startWithQuote) breakCycle = YES;
                    break;
                case '\"':
                    if (startWithQuote && next_index != index) breakCycle = YES;
                    break;
                default:
                    break;
            }
            if (breakCycle) break;
            next_index ++;
        }
        
        if (startWithQuote) {
            op = [whole substringWithRange:
                  NSMakeRange(index + 1,
                              next_index - index - 1)];
        } else {
            op = [whole substringWithRange:
                  NSMakeRange(index, next_index - index)];
        }
        [result addObject:op];
        index = next_index + 1;
    }
    return result;
}

static
NSString *(^cmd_ls)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args) {
    BOOL isDir;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *result = @"\nd\t\t.\nd\t\t..\n";
    
    NSArray *files = [fm contentsOfDirectoryAtPath:sCurDir error:nil];
    for (NSString *file in files) {
        NSString *fullPath = [sCurDir stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:fullPath isDirectory:&isDir]) {
            if (isDir) {
                result = [result stringByAppendingString:@"d"];
            }
        }
        
        result = [result stringByAppendingString:@"\t"];
        if (!isDir) {
            unsigned long long file_size = [[fm attributesOfItemAtPath:fullPath error:nil] fileSize];
            result = [result stringByAppendingFormat:@"%llu", file_size];
        }
        
        result = [result stringByAppendingString:@"\t"];
        result = [result stringByAppendingString:file];
        result = [result stringByAppendingString:@"\n"];
    }
    
    return result;
};

static
NSString *(^cmd_cp)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args)  {
    if ([args count] < 1) {
        return @"Invalid cp command.";
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *srcPath = nil, *dstPath = nil;
    NSString *srcFileName;
    BOOL bForce = NO, bRecursive = NO;
    BOOL isDir, bExists;
    
    for (NSString *arg in args) {
        if ([arg characterAtIndex:0] == '-') {
            if ([arg length] >= 2) {
                for (NSUInteger i = 1; i < [arg length]; i ++) {
                    switch ([arg characterAtIndex:i]) {
                        case 'f':
                            bForce = YES;
                            break;
                        case 'r':
                            bRecursive = YES;
                            break;
                        default:
                            return @"Unknown flag specified.";
                    }
                }
            } else {
                return @"Unknown flag specified.";
            }
        } else {
            if (srcPath != nil) {
                if (dstPath != nil) {
                    return @"Too many paths specified.";
                }
                dstPath = standardizePath(arg);
                if (dstPath == nil) {
                    return @"Invalid destination path.";
                }
            } else {
                srcPath = standardizePath(arg);
                if (srcPath == nil) {
                    return @"Invalid source path.";
                }
            }
        }
    }
    
    if (srcPath == nil) {
        return @"Source path not specified.";
    }
    if (dstPath == nil) {
        return @"Destination path not specified.";
    }
    
    bExists = [fm fileExistsAtPath:srcPath isDirectory:&isDir];
    if (!bExists) {
        return @"Source path does not exist.";
    }
    
    if (isDir && !bRecursive) {
        return @"You need to copy a directory with -r flag.";
    }
    
    srcFileName = [srcPath lastPathComponent];
    
    // Destination path adoption
    [fm fileExistsAtPath:dstPath isDirectory:&isDir];
    if (isDir) {
        dstPath = [dstPath stringByAppendingPathComponent:srcFileName];
    }
    bExists = [fm fileExistsAtPath:dstPath isDirectory:&isDir];
    NSError *error;
    if (bExists) {
        if (!bForce)
            return @"Destination path already exists.";
        else {
            if (![fm removeItemAtPath:dstPath error:&error]) {
                return [NSString stringWithFormat:@"Cannot remove destination file: %@", [error localizedDescription]];
            }
        }
    }
    
    if (![fm copyItemAtPath:srcPath toPath:dstPath error:&error]) {
        return [NSString stringWithFormat:@"cp error: %@", [error localizedDescription]];
    }
    
    return @"ok";
};

static
NSString *(^cmd_pwd)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args) {
    return sCurDir;
};

static
NSString *(^cmd_cd)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args)  {
    if ([args count] < 1) {
        return @"Invalid cd command.";
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *newDir;
    NSString *partDir = [args objectAtIndex:0];
    
    newDir = standardizePath(partDir);
    
    if (newDir == nil) {
        return @"Invalid cd path.";
    }
    
    if (![fm isReadableFileAtPath:newDir]) {
        return @"Permission denied.";
    }
    
    BOOL isDir;
    if (![fm fileExistsAtPath:newDir isDirectory:&isDir]) {
        return @"File does not exist.";
    }
    
    if (!isDir) {
        return @"File is not a directory.";
    }
    
    sCurDir = newDir;
    return @"";
};

static
NSString *(^cmd_mkdir)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args)  {
    if ([args count] < 1) {
        return @"Invalid mkdir command.";
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = nil;
    BOOL bIntermediate = NO;
    
    for (NSString *arg in args) {
        if ([arg characterAtIndex:0] == '-') {
            if ([arg length] == 2 && [arg characterAtIndex:1] == 'p') {
                bIntermediate = YES;
            } else {
                return @"Unknown flag specified.";
            }
        } else {
            if (path != nil) {
                return @"Multiple path specified.";
            }
            
            path = standardizePath(arg);
            if (path == nil) {
                return @"Invalid path.";
            }
        }
    }
    
    if (path == nil) {
        return @"Path not specified.";
    }
    
    NSError *error;
    if (![fm createDirectoryAtPath:path
                withIntermediateDirectories:bIntermediate
                attributes:nil error:&error]) {
        return [NSString stringWithFormat:@"mkdir error: %@", [error localizedDescription]];
    }
    
    return @"ok";
};

static
NSString *(^cmd_rm)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args) {
    if ([args count] < 1) {
        return @"Invalid rm command.";
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = nil;
    BOOL bForce = NO, bRecursive = NO;
    BOOL isDir, bExists;
    
    for (NSString *arg in args) {
        if ([arg characterAtIndex:0] == '-') {
            if ([arg length] >= 2) {
                for (NSUInteger i = 1; i < [arg length]; i ++) {
                    switch ([arg characterAtIndex:i]) {
                        case 'f':
                            bForce = YES;
                            break;
                        case 'r':
                            bRecursive = YES;
                            break;
                        default:
                            return @"Unknown flag specified.";
                    }
                }
            } else {
                return @"Unknown flag specified.";
            }
        } else {
            if (path != nil) {
                return @"Multiple path specified.";
            }
            
            path = standardizePath(arg);
        }
    }
    
    if (path == nil) {
        return @"Path not specified.";
    }
    
    bExists = [fm fileExistsAtPath:path isDirectory:&isDir];
    if (!bExists && !bForce) {
        return @"File does not exist.";
    }
    
    if (isDir && !bRecursive) {
        return @"You need to remove a directory with -r flag.";
    }
    
    NSError *error;
    if (![fm removeItemAtPath:path error:&error]) {
        return [NSString stringWithFormat:@"rm error: %@", [error localizedDescription]];
    }
    
    return @"ok";
};

static
NSString *(^cmd_info)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args) {
    NSString *bundle = [[NSBundle mainBundle] bundlePath];
    NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    NSString *document = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    return [NSString stringWithFormat:@"bundle: %@\nlibrary: %@\ndocument: %@\n",
            bundle, library, document];
};

static
NSString *(^cmd_dlopen)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args) {
    if ([args count] != 1) {
        return @"Invalid dlopen command.";
    }
    
    NSString *path = standardizePath([args objectAtIndex:0]);
    if (path == nil) {
        return @"Invalid path.";
    }
    
    void *p = dlopen([path UTF8String], RTLD_LAZY);
    if (nil == p) {
        return [NSString stringWithFormat:@"dlopen error: %s", dlerror()];
    }
    return @"Library loaded.";
};

static
NSString *(^cmd_curl)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args) {
    if ([args count] < 1) {
        return @"Invalid curl command.";
    }
    // Defaulting to -O option..
    NSString *stringURL = [args objectAtIndex:0];
    NSString *fileName = [stringURL lastPathComponent];
    NSString *fullPath = [sCurDir stringByAppendingPathComponent:fileName];
    
    NSURL  *url = [NSURL URLWithString:stringURL];
    NSData *urlData = [NSData dataWithContentsOfURL:url];
    if (urlData) {
        if (![urlData writeToFile:fullPath atomically:YES]) {
            return @"Cannot write to file.";
        }
    }
    return [NSString stringWithFormat:@"File saved to %@", fileName];
};

static
NSString *(^cmd_cat)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args) {
    if ([args count] < 1) {
        return @"Invalid cat command.";
    }
    
    NSString *file = standardizePath([args objectAtIndex:0]);
    if (file == nil) {
        return @"Invalid path.";
    }
    
    NSError *error;
    NSString *strFileContent = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:&error];

    if (error) {
        return [NSString stringWithFormat:@"cat error: %@", [error localizedDescription]];
    }

    return strFileContent;
};

static
NSString *(^cmd_unzip)(NSArray<NSString *> *args) = ^NSString *(NSArray<NSString *> *args) {
    if ([args count] < 2) {
        return @"Invalid unzip command.";
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir;
    
    NSString *zipFile = standardizePath([args objectAtIndex:0]);
    if (zipFile == nil) {
        return @"Invalid zip file path.";
    }
    NSString *dstPath = standardizePath([args objectAtIndex:1]);
    if (dstPath == nil) {
        return @"Invalid destination path.";
    }
    
    if (![fm fileExistsAtPath:zipFile isDirectory:&isDir]) {
        return @"Zip file does not exist.";
    }
    if (isDir) {
        return @"Cannot extract a directory.";
    }
    [fm fileExistsAtPath:dstPath isDirectory:&isDir];
    if (!isDir) {
        return @"File must be extracted into a directory.";
    }
    
    NSError *error;
    if (![SSZipArchive unzipFileAtPath:zipFile toDestination:dstPath overwrite:YES password:nil error:&error]) {
        return [NSString stringWithFormat:@"unzip error: %@", [error localizedDescription]];
    }
    
    return @"ok";
};

static void
initCmdResponder(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sPathBundle = [[NSBundle mainBundle] bundlePath];
        sPathLibrary = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
        sPathDocument = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
        
        sCurDir = sPathBundle;
        
        sPredefinedMacros = @{@"${BUNDLE_PATH}": sPathBundle,
                              @"${LIBRARY_PATH}": sPathLibrary,
                              @"${DOCUMENT_PATH}": sPathDocument};
        
        sCmdResponders = @{@"ls": cmd_ls, @"cd": cmd_cd, @"pwd": cmd_pwd,
                           @"cp": cmd_cp, @"rm": cmd_rm, @"info": cmd_info,
                           @"unzip": cmd_unzip, @"curl": cmd_curl, @"cat": cmd_cat,
                           @"dlopen": cmd_dlopen, @"mkdir": cmd_mkdir };
        
    });
}

NSString *
cmdRespond(NSString *input) {
    initCmdResponder();
    
    NSArray *args = breakCmdIntoPieces(input);
    if (args == nil || [args count] < 1) {
        return @"";
    }
    
    NSString *cmd = [args objectAtIndex:0];
    NSString *(^handler)(NSArray *args) = sCmdResponders[cmd];
    if (handler == nil) {
        return @"Unknown command.";
    }
    
    return handler([args subarrayWithRange:NSMakeRange(1, [args count] - 1)]);
}
