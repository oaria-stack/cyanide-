//
//  syscolpatcher.m
//  System color patcher via CoreUI DesignLibrary asset catalog overwrite.
//
//  The iOS-Repositories file inside DesignLibrary-iOS.bundle is a Binary
//  Asset Catalog (.car) that CoreUI reads to resolve named semantic colors
//  (systemBlue, label, tint, etc.).  The color values are stored as
//  IEEE-754 single-precision floats, packed as four consecutive float32s
//  in RGBA order, repeated for each appearance variant (light/dark).
//
//  Strategy
//  --------
//  1. Copy the live system file into the app's Documents sandbox.
//  2. Keep a second copy as backup (only on first patch, before any
//     modifications are applied).
//  3. Scan the working copy for float[4] runs that match any of the known
//     system-blue / system-tint RGBA signatures (within an epsilon) and
//     replace them with the caller's requested color.
//  4. Call overwrite_system_file() to write the patched bytes over the
//     live system file using the kernel r/w primitives (strips MNT_RDONLY,
//     patches fileglob flags, mmap-memcpy, restores everything).
//  5. Post a Darwin notification so CoreUI flushes its color cache and
//     SpringBoard redraws.
//
//  On reset: overwrite the live file with the backup copy.
//
//  File-size constraint
//  --------------------
//  overwrite_system_file() requires from_size <= to_size.  Our working
//  copy is made from the original so it is always exactly the same size;
//  this is always satisfied.
//
//  Known RGBA signatures searched (tolerance ±0.04)
//  -------------------------------------------------
//  systemBlue  light  : 0.00  0.48  1.00  1.00
//  systemBlue  dark   : 0.04  0.52  1.00  1.00
//  systemTint  light  : 0.00  0.48  1.00  1.00  (same slot as systemBlue)
//  accentBlue  light  : 0.22  0.45  0.95  1.00
//  accentBlue  dark   : 0.26  0.49  0.99  1.00
//
//  To add more colors: append entries to kSCPSignatures below.
//

#import "syscolpatcher.h"
#import "../utils/file.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <notify.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <math.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/mman.h>

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

static NSString *scp_system_path(void)
{
    return @"/System/Library/PrivateFrameworks/CoreUI.framework"
            "/DesignLibrary-iOS.bundle/iOS-Repositories";
}

static NSString *scp_working_path(void)
{
    return [NSHomeDirectory()
            stringByAppendingPathComponent:
                @"Documents/syscolpatcher_working.car"];
}

static NSString *scp_backup_path(void)
{
    return [NSHomeDirectory()
            stringByAppendingPathComponent:
                @"Documents/syscolpatcher_backup.car"];
}

// ---------------------------------------------------------------------------
// Known system-color RGBA signatures
// ---------------------------------------------------------------------------

typedef struct {
    float r, g, b, a;
} SCPRGBA;

// Tolerance for float comparison when scanning the binary
#define SCP_EPSILON 0.04f

static const SCPRGBA kSCPSignatures[] = {
    // systemBlue / systemTint light
    { 0.00f, 0.478f, 1.00f, 1.00f },
    // systemBlue dark
    { 0.04f, 0.518f, 1.00f, 1.00f },
    // accentBlue light (some iOS versions)
    { 0.22f, 0.45f,  0.95f, 1.00f },
    // accentBlue dark
    { 0.26f, 0.49f,  0.99f, 1.00f },
    // systemIndigo light (often used as secondary accent)
    { 0.35f, 0.34f,  0.84f, 1.00f },
    // systemIndigo dark
    { 0.37f, 0.36f,  0.90f, 1.00f },
};
static const int kSCPSignatureCount =
    (int)(sizeof(kSCPSignatures) / sizeof(kSCPSignatures[0]));

static bool scp_float_near(float a, float b)
{
    return fabsf(a - b) <= SCP_EPSILON;
}

static bool scp_rgba_matches(const float *candidate, SCPRGBA sig)
{
    return scp_float_near(candidate[0], sig.r) &&
           scp_float_near(candidate[1], sig.g) &&
           scp_float_near(candidate[2], sig.b) &&
           scp_float_near(candidate[3], sig.a);
}

// ---------------------------------------------------------------------------
// Binary patching
// ---------------------------------------------------------------------------

// Scan buf of length len for float[4] runs matching any known signature and
// replace them with replacement.  Returns the number of substitutions made.
static int scp_patch_buffer(uint8_t *buf, size_t len, SCPColor lightCol, SCPColor darkCol)
{
    int hits = 0;
    // Must have room for at least 4 floats
    if (len < 16) return 0;

    // The .car format has no fixed structure we can rely on across iOS
    // versions, so we do a sliding float-aligned scan.  Floats in .car files
    // are always 4-byte aligned.
    for (size_t i = 0; i + 16 <= len; i += 4) {
        float candidate[4];
        memcpy(candidate, buf + i, 16);

        for (int s = 0; s < kSCPSignatureCount; s++) {
            if (!scp_rgba_matches(candidate, kSCPSignatures[s])) continue;

            // Decide light vs dark: if the blue component is slightly higher
            // it is likely the dark variant.
            bool isDark = (kSCPSignatures[s].r > 0.02f);
            SCPColor replacement = isDark ? darkCol : lightCol;

            float patched[4] = {
                replacement.r,
                replacement.g,
                replacement.b,
                replacement.a
            };
            memcpy(buf + i, patched, 16);

            printf("[SCP] hit sig[%d] @ offset %zu  "
                   "(%.3f,%.3f,%.3f,%.3f) -> (%.3f,%.3f,%.3f,%.3f)\n",
                   s, i,
                   candidate[0], candidate[1], candidate[2], candidate[3],
                   patched[0],   patched[1],   patched[2],   patched[3]);
            hits++;
            break; // only replace once per position
        }
    }
    return hits;
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

static bool scp_copy_file(NSString *src, NSString *dst)
{
    NSError *err = nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:dst]) {
        [fm removeItemAtPath:dst error:nil];
    }
    bool ok = [fm copyItemAtPath:src toPath:dst error:&err];
    if (!ok) {
        printf("[SCP] copy %s -> %s failed: %s\n",
               src.UTF8String, dst.UTF8String,
               err.localizedDescription.UTF8String ?: "?");
    }
    return ok;
}

// Read entire file into a heap buffer.  Caller must free().
static uint8_t *scp_read_file(NSString *path, size_t *outLen)
{
    int fd = open(path.UTF8String, O_RDONLY);
    if (fd < 0) {
        printf("[SCP] open failed: %s\n", path.UTF8String);
        return NULL;
    }
    off_t sz = lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);
    if (sz <= 0) { close(fd); return NULL; }

    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) { close(fd); return NULL; }

    ssize_t rd = read(fd, buf, (size_t)sz);
    close(fd);
    if (rd != (ssize_t)sz) { free(buf); return NULL; }

    *outLen = (size_t)sz;
    return buf;
}

static bool scp_write_file(NSString *path, const uint8_t *buf, size_t len)
{
    int fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        printf("[SCP] write open failed: %s\n", path.UTF8String);
        return false;
    }
    ssize_t wr = write(fd, buf, len);
    close(fd);
    if (wr != (ssize_t)len) {
        printf("[SCP] write short: wrote %zd of %zu\n", wr, len);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool syscolpatcher_has_backup(void)
{
    return [NSFileManager.defaultManager fileExistsAtPath:scp_backup_path()];
}

bool syscolpatcher_apply(SCPColor light, SCPColor dark)
{
    printf("[SCP] apply light(%.3f,%.3f,%.3f,%.3f) dark(%.3f,%.3f,%.3f,%.3f)\n",
           light.r, light.g, light.b, light.a,
           dark.r,  dark.g,  dark.b,  dark.a);

    NSString *sysPath     = scp_system_path();
    NSString *workingPath = scp_working_path();
    NSString *backupPath  = scp_backup_path();
    NSFileManager *fm     = NSFileManager.defaultManager;

    // --- 1. Sanity check: system file must exist ---
    if (![fm fileExistsAtPath:sysPath]) {
        printf("[SCP] system file not found: %s\n", sysPath.UTF8String);
        return false;
    }

    // --- 2. Take backup if this is the first patch ---
    if (![fm fileExistsAtPath:backupPath]) {
        printf("[SCP] taking backup -> %s\n", backupPath.UTF8String);
        if (!scp_copy_file(sysPath, backupPath)) return false;
    }

    // --- 3. Copy the ORIGINAL (backup) into working, so repeated Apply
    //         calls start fresh from stock, not from a previously patched
    //         working file. ---
    printf("[SCP] seeding working copy from backup\n");
    if (!scp_copy_file(backupPath, workingPath)) return false;

    // --- 4. Read working copy into memory ---
    size_t len = 0;
    uint8_t *buf = scp_read_file(workingPath, &len);
    if (!buf) {
        printf("[SCP] failed to read working copy\n");
        return false;
    }
    printf("[SCP] working copy size = %zu bytes\n", len);

    // --- 5. Patch the buffer ---
    int hits = scp_patch_buffer(buf, len, light, dark);
    printf("[SCP] %d substitution(s) made\n", hits);

    if (hits == 0) {
        free(buf);
        printf("[SCP] no known color signatures found in file — "
               "iOS version may use different float values\n");
        // Still proceed: write the unmodified file back so the
        // overwrite_system_file path is exercised; caller gets false.
        return false;
    }

    // --- 6. Write patched buffer back to working path ---
    bool wrote = scp_write_file(workingPath, buf, len);
    free(buf);
    if (!wrote) {
        printf("[SCP] failed to write patched working copy\n");
        return false;
    }

    // --- 7. Overwrite the live system file ---
    char sysPathC[PATH_MAX];
    char workPathC[PATH_MAX];
    strlcpy(sysPathC,  sysPath.UTF8String,     sizeof(sysPathC));
    strlcpy(workPathC, workingPath.UTF8String,  sizeof(workPathC));

    uint64_t result = overwrite_system_file(sysPathC, workPathC);
    if (result != 0) {
        printf("[SCP] overwrite_system_file failed (result=%llu)\n", result);
        return false;
    }
    printf("[SCP] overwrite_system_file succeeded\n");

    // --- 8. Notify CoreUI to flush its color cache ---
    // com.apple.UIKit.systemColorCacheInvalidate is posted by UIKit itself
    // when trait collections change; reusing it triggers a redraw pass.
    notify_post("com.apple.UIKit.systemColorCacheInvalidate");
    notify_post("com.apple.springboard.ioscolorcache-invalidate");
    // Also blast a generic SpringBoard theme change notification that some
    // iOS versions listen to for color refreshes.
    notify_post("com.apple.springboard.theme");

    printf("[SCP] done\n");
    return true;
}

bool syscolpatcher_reset(void)
{
    printf("[SCP] reset\n");

    NSString *sysPath    = scp_system_path();
    NSString *backupPath = scp_backup_path();

    if (![NSFileManager.defaultManager fileExistsAtPath:backupPath]) {
        printf("[SCP] no backup found, nothing to restore\n");
        return false;
    }

    char sysPathC[PATH_MAX];
    char backPathC[PATH_MAX];
    strlcpy(sysPathC,  sysPath.UTF8String,    sizeof(sysPathC));
    strlcpy(backPathC, backupPath.UTF8String,  sizeof(backPathC));

    uint64_t result = overwrite_system_file(sysPathC, backPathC);
    if (result != 0) {
        printf("[SCP] reset overwrite_system_file failed (result=%llu)\n", result);
        return false;
    }

    // Remove the backup and working copy so a future apply starts fresh
    [[NSFileManager defaultManager] removeItemAtPath:backupPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:scp_working_path() error:nil];

    notify_post("com.apple.UIKit.systemColorCacheInvalidate");
    notify_post("com.apple.springboard.ioscolorcache-invalidate");
    notify_post("com.apple.springboard.theme");

    printf("[SCP] reset done\n");
    return true;
}
