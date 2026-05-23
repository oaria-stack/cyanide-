//
//  syscolpatcher.h
//  Patches system colors by overwriting the DesignLibrary iOS-Repositories
//  asset catalog in CoreUI.framework with a modified copy that has the
//  requested RGBA float values substituted in-place.
//
//  The target file is:
//    /System/Library/PrivateFrameworks/CoreUI.framework/
//      DesignLibrary-iOS.bundle/iOS-Repositories
//
//  Because overwrite_system_file() is an in-place mmap overwrite the
//  replacement must be <= the original size; padding with 0xff at the end
//  satisfies this since asset catalogs ignore trailing bytes.
//
//  A backup is written to the app's Documents directory before the first
//  patch so that reset can restore the original bytes exactly.
//
//  Color channels are floats in 0.0–1.0.
//

#ifndef syscolpatcher_h
#define syscolpatcher_h

#import <stdbool.h>

typedef struct {
    float r, g, b, a;
} SCPColor;

// Apply a tint by scanning the asset catalog binary for float[4] RGBA
// sequences that match known system color signatures and replacing them.
// light and dark may differ; both appearances are patched.
// Returns true if at least one substitution was made and the file was
// written successfully.
bool syscolpatcher_apply(SCPColor light, SCPColor dark);

// Restore the original iOS-Repositories file from the backup taken at
// first apply time.  No-op if no backup exists.
bool syscolpatcher_reset(void);

// Returns true if a backup of the original file exists in Documents.
bool syscolpatcher_has_backup(void);

#endif /* syscolpatcher_h */
