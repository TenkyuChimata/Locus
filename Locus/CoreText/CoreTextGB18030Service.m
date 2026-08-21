//
//  CoreTextGB18030Service.m
//  Locus
//
//  Process-local validation of the 24A5390f CoreText GB18030 predicate.
//

#import "CoreTextGB18030Service.h"

#import <UIKit/UIKit.h>

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_region.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdint.h>
#import <string.h>
#import <sys/sysctl.h>

// -------------------------------------------------------------------------
// Exact 24A5390f / CoreText 900.0.0.0.0 addresses recovered from the DSC.
//
// __TEXT image base:                  0x19AA02000
// IsGB18030ComplianceRequired cache:  0x1E6E72E48 (uint8_t)
// dispatch_once token:                0x1E6E72E50 (int64_t)
//
// Both globals are in CoreText __DATA_DIRTY.__bss on this exact build.
// Never reuse these constants on another build without re-deriving them.
// -------------------------------------------------------------------------
static const uintptr_t kGECoreTextStaticImageBase =
    UINT64_C(0x19AA02000);

static const uintptr_t kGECoreTextGB18030CachedBoolStaticAddress =
    UINT64_C(0x1E6E72E48);

static const uintptr_t kGECoreTextGB18030OnceStaticAddress =
    UINT64_C(0x1E6E72E50);

static NSString * const kGECoreTextSupportedBuild = @"24A5390f";

static NSString * const kGECoreTextImageSuffix =
    @"/System/Library/Frameworks/CoreText.framework/CoreText";

static NSString * const kGECoreTextErrorDomain =
    @"io.github.tenkyuchimata.locus.coretext-gb18030";

typedef const void *(*GEDyldGetSharedCacheRangeFunction)(size_t *length);

static NSError *
GECoreTextError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:kGECoreTextErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: message ?: @"Unknown CoreText experiment error."
    }];
}

static NSString *
GECurrentOSBuild(void)
{
    size_t size = 0;

    if (sysctlbyname("kern.osversion", NULL, &size, NULL, 0) != 0 ||
        size <= 1) {
        return @"";
    }

    char *buffer = calloc(1, size);

    if (!buffer) {
        return @"";
    }

    NSString *result = @"";

    if (sysctlbyname("kern.osversion", buffer, &size, NULL, 0) == 0) {
        NSString *value = [NSString stringWithUTF8String:buffer];
        if (value) {
            result = value;
        }
    }

    free(buffer);
    return result;
}

static NSString *
GEHexAddress(uintptr_t value)
{
    return [NSString stringWithFormat:@"0x%016llX",
            (unsigned long long)value];
}

static NSString *
GEHexSignedSlide(intptr_t value)
{
    if (value < 0) {
        return [NSString stringWithFormat:@"-0x%llX",
                (unsigned long long)(-(int64_t)value)];
    }

    return [NSString stringWithFormat:@"0x%llX",
            (unsigned long long)value];
}

static NSString *
GEProtectionString(vm_prot_t protection)
{
    return [NSString stringWithFormat:@"%@%@%@ (0x%X)",
        (protection & VM_PROT_READ) ? @"r" : @"-",
        (protection & VM_PROT_WRITE) ? @"w" : @"-",
        (protection & VM_PROT_EXECUTE) ? @"x" : @"-",
        protection
    ];
}

static BOOL
GEFindLoadedCoreTextImage(
    const struct mach_header_64 * _Nullable *headerOut,
    intptr_t * _Nullable slideOut,
    NSString * _Nullable *imageNameOut
)
{
    uint32_t count = _dyld_image_count();

    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);

        if (!name) {
            continue;
        }

        NSString *imageName = [NSString stringWithUTF8String:name];

        if (!imageName || ![imageName hasSuffix:kGECoreTextImageSuffix]) {
            continue;
        }

        const struct mach_header *genericHeader =
            _dyld_get_image_header(index);

        if (!genericHeader || genericHeader->magic != MH_MAGIC_64) {
            return NO;
        }

        if (headerOut) {
            *headerOut =
                (const struct mach_header_64 *)genericHeader;
        }

        if (slideOut) {
            *slideOut =
                _dyld_get_image_vmaddr_slide(index);
        }

        if (imageNameOut) {
            *imageNameOut = imageName;
        }

        return YES;
    }

    return NO;
}

static BOOL
GEFindStaticSectionContainingAddress(
    const struct mach_header_64 *header,
    uintptr_t staticAddress,
    const char *requiredSegment,
    const char *requiredSection,
    uint64_t * _Nullable sectionAddressOut,
    uint64_t * _Nullable sectionSizeOut
)
{
    if (!header || header->magic != MH_MAGIC_64) {
        return NO;
    }

    const uint8_t *cursor =
        (const uint8_t *)header + sizeof(struct mach_header_64);

    for (uint32_t commandIndex = 0;
         commandIndex < header->ncmds;
         commandIndex++) {
        const struct load_command *command =
            (const struct load_command *)cursor;

        if (command->cmdsize < sizeof(struct load_command)) {
            return NO;
        }

        if (command->cmd == LC_SEGMENT_64 &&
            command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;

            if (segment->nsects > 4096) {
                return NO;
            }

            uint64_t requiredSize =
                sizeof(struct segment_command_64) +
                ((uint64_t)segment->nsects * sizeof(struct section_64));

            if (requiredSize > command->cmdsize) {
                return NO;
            }

            if (strncmp(segment->segname,
                        requiredSegment,
                        sizeof(segment->segname)) != 0) {
                cursor += command->cmdsize;
                continue;
            }

            const struct section_64 *sections =
                (const struct section_64 *)(segment + 1);

            for (uint32_t sectionIndex = 0;
                 sectionIndex < segment->nsects;
                 sectionIndex++) {
                const struct section_64 *section =
                    &sections[sectionIndex];

                if (strncmp(section->sectname,
                            requiredSection,
                            sizeof(section->sectname)) != 0) {
                    continue;
                }

                uint64_t start = section->addr;
                uint64_t end = start + section->size;

                if (end < start) {
                    return NO;
                }

                if ((uint64_t)staticAddress < start ||
                    (uint64_t)staticAddress >= end) {
                    return NO;
                }

                if (sectionAddressOut) {
                    *sectionAddressOut = start;
                }

                if (sectionSizeOut) {
                    *sectionSizeOut = section->size;
                }

                return YES;
            }
        }

        cursor += command->cmdsize;
    }

    return NO;
}

static BOOL
GERegionInfoForAddress(
    uintptr_t address,
    vm_prot_t * _Nullable protectionOut,
    vm_prot_t * _Nullable maxProtectionOut,
    uintptr_t * _Nullable regionStartOut,
    uint64_t * _Nullable regionSizeOut
)
{
    vm_address_t regionAddress =
        (vm_address_t)address;

    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t infoCount =
        VM_REGION_BASIC_INFO_COUNT_64;
    memory_object_name_t objectName =
        MACH_PORT_NULL;

    kern_return_t result =
        vm_region_64(
            mach_task_self(),
            &regionAddress,
            &regionSize,
            VM_REGION_BASIC_INFO_64,
            (vm_region_info_t)&info,
            &infoCount,
            &objectName
        );

    if (objectName != MACH_PORT_NULL) {
        mach_port_deallocate(
            mach_task_self(),
            objectName
        );
    }

    if (result != KERN_SUCCESS) {
        return NO;
    }

    uint64_t regionEnd =
        (uint64_t)regionAddress + (uint64_t)regionSize;

    if (regionEnd < (uint64_t)regionAddress ||
        (uint64_t)address < (uint64_t)regionAddress ||
        (uint64_t)address >= regionEnd) {
        return NO;
    }

    if (protectionOut) {
        *protectionOut = info.protection;
    }

    if (maxProtectionOut) {
        *maxProtectionOut = info.max_protection;
    }

    if (regionStartOut) {
        *regionStartOut = (uintptr_t)regionAddress;
    }

    if (regionSizeOut) {
        *regionSizeOut = (uint64_t)regionSize;
    }

    return YES;
}

static NSDictionary<NSString *, id> *
GESharedCacheDiagnostics(
    const struct mach_header_64 * _Nullable coreTextHeader
)
{
    NSMutableDictionary<NSString *, id> *result =
        [NSMutableDictionary dictionary];

    GEDyldGetSharedCacheRangeFunction getRange =
        (GEDyldGetSharedCacheRangeFunction)dlsym(
            RTLD_DEFAULT,
            "_dyld_get_shared_cache_range"
        );

    result[@"sharedCacheRangeResolved"] = @(getRange != NULL);

    if (!getRange) {
        result[@"sharedCacheStart"] = NSNull.null;
        result[@"sharedCacheLength"] = NSNull.null;
        result[@"coreTextHeaderInsideSharedCache"] = NSNull.null;
        return result;
    }

    size_t length = 0;
    const void *startPointer = getRange(&length);

    if (!startPointer || length == 0) {
        result[@"sharedCacheStart"] = NSNull.null;
        result[@"sharedCacheLength"] = @(length);
        result[@"coreTextHeaderInsideSharedCache"] = @NO;
        return result;
    }

    uintptr_t start = (uintptr_t)startPointer;
    uintptr_t end = start + (uintptr_t)length;

    BOOL rangeValid = end >= start;
    BOOL containsHeader = NO;

    if (rangeValid && coreTextHeader) {
        uintptr_t headerAddress =
            (uintptr_t)coreTextHeader;

        containsHeader =
            headerAddress >= start &&
            headerAddress < end;
    }

    result[@"sharedCacheStart"] = GEHexAddress(start);
    result[@"sharedCacheLength"] = @(length);
    result[@"coreTextHeaderInsideSharedCache"] = @(containsHeader);

    return result;
}

static BOOL
GEValidatedRuntimeAddresses(
    const struct mach_header_64 *header,
    intptr_t slide,
    uintptr_t * _Nullable cachedBoolAddressOut,
    uintptr_t * _Nullable onceAddressOut,
    NSDictionary<NSString *, id> * _Nullable *detailsOut,
    NSError **error
)
{
    if (!header || header->magic != MH_MAGIC_64) {
        if (error) {
            *error = GECoreTextError(
                10,
                @"CoreText is not loaded as a valid 64-bit Mach-O image."
            );
        }
        return NO;
    }

    uintptr_t expectedHeaderAddress =
        (uintptr_t)((intptr_t)kGECoreTextStaticImageBase + slide);

    if ((uintptr_t)header != expectedHeaderAddress) {
        if (error) {
            *error = GECoreTextError(
                11,
                [NSString stringWithFormat:
                    @"CoreText image-base validation failed. Expected %@, got %@.",
                    GEHexAddress(expectedHeaderAddress),
                    GEHexAddress((uintptr_t)header)
                ]
            );
        }
        return NO;
    }

    uint64_t cachedSectionAddress = 0;
    uint64_t cachedSectionSize = 0;

    BOOL cachedSectionValidated =
        GEFindStaticSectionContainingAddress(
            header,
            kGECoreTextGB18030CachedBoolStaticAddress,
            "__DATA_DIRTY",
            "__bss",
            &cachedSectionAddress,
            &cachedSectionSize
        );

    BOOL onceSectionValidated =
        GEFindStaticSectionContainingAddress(
            header,
            kGECoreTextGB18030OnceStaticAddress,
            "__DATA_DIRTY",
            "__bss",
            NULL,
            NULL
        );

    if (!cachedSectionValidated || !onceSectionValidated) {
        if (error) {
            *error = GECoreTextError(
                12,
                @"The recovered GB18030 globals are not inside CoreText __DATA_DIRTY.__bss on this runtime image."
            );
        }
        return NO;
    }

    uintptr_t cachedAddress =
        (uintptr_t)((intptr_t)kGECoreTextGB18030CachedBoolStaticAddress + slide);

    uintptr_t onceAddress =
        (uintptr_t)((intptr_t)kGECoreTextGB18030OnceStaticAddress + slide);

    vm_prot_t cachedProtection = VM_PROT_NONE;
    vm_prot_t cachedMaxProtection = VM_PROT_NONE;
    uintptr_t cachedRegionStart = 0;
    uint64_t cachedRegionSize = 0;

    if (!GERegionInfoForAddress(
            cachedAddress,
            &cachedProtection,
            &cachedMaxProtection,
            &cachedRegionStart,
            &cachedRegionSize)) {
        if (error) {
            *error = GECoreTextError(
                13,
                @"Unable to query the VM region containing CoreText's GB18030 cached byte."
            );
        }
        return NO;
    }

    vm_prot_t onceProtection = VM_PROT_NONE;

    if (!GERegionInfoForAddress(
            onceAddress,
            &onceProtection,
            NULL,
            NULL,
            NULL)) {
        if (error) {
            *error = GECoreTextError(
                14,
                @"Unable to query the VM region containing CoreText's GB18030 once token."
            );
        }
        return NO;
    }

    if ((cachedProtection & VM_PROT_READ) == 0 ||
        (cachedProtection & VM_PROT_WRITE) == 0) {
        if (error) {
            *error = GECoreTextError(
                15,
                [NSString stringWithFormat:
                    @"CoreText's cached-byte region is not already read/write (%@). No protection change will be attempted.",
                    GEProtectionString(cachedProtection)
                ]
            );
        }
        return NO;
    }

    if ((onceProtection & VM_PROT_READ) == 0) {
        if (error) {
            *error = GECoreTextError(
                16,
                @"CoreText's once-token region is not readable."
            );
        }
        return NO;
    }

    if (cachedBoolAddressOut) {
        *cachedBoolAddressOut = cachedAddress;
    }

    if (onceAddressOut) {
        *onceAddressOut = onceAddress;
    }

    if (detailsOut) {
        *detailsOut = @{
            @"sectionValidated": @YES,
            @"section": @"__DATA_DIRTY.__bss",
            @"sectionStaticStart": GEHexAddress((uintptr_t)cachedSectionAddress),
            @"sectionSize": @(cachedSectionSize),
            @"cachedBoolStaticAddress": GEHexAddress(kGECoreTextGB18030CachedBoolStaticAddress),
            @"cachedBoolRuntimeAddress": GEHexAddress(cachedAddress),
            @"onceStaticAddress": GEHexAddress(kGECoreTextGB18030OnceStaticAddress),
            @"onceRuntimeAddress": GEHexAddress(onceAddress),
            @"cachedRegionStart": GEHexAddress(cachedRegionStart),
            @"cachedRegionSize": @(cachedRegionSize),
            @"cachedRegionProtection": GEProtectionString(cachedProtection),
            @"cachedRegionMaxProtection": GEProtectionString(cachedMaxProtection),
            @"onceRegionProtection": GEProtectionString(onceProtection)
        };
    }

    if (error) {
        *error = nil;
    }

    return YES;
}

static NSData * _Nullable
GERenderEmojiSample(CGFloat fontSize)
{
    // Keep this literal out of the SwiftUI view so merely opening the
    // diagnostics screen does not intentionally draw the Taiwan flag before
    // the experiment runs.
    NSString *sample =
        @"TW  🇹🇼     JP  🇯🇵\nCN  🇨🇳     HK  🇭🇰";

    CGSize canvasSize = CGSizeMake(900.0, 260.0);

    UIGraphicsImageRendererFormat *format =
        [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = YES;
    format.scale = 2.0;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc]
            initWithSize:canvasSize
                  format:format];

    UIImage *image =
        [renderer imageWithActions:
            ^(UIGraphicsImageRendererContext *context) {
                [[UIColor whiteColor] setFill];
                UIRectFill((CGRect){ .origin = CGPointZero, .size = canvasSize });

                NSMutableParagraphStyle *paragraph =
                    [NSMutableParagraphStyle new];
                paragraph.alignment = NSTextAlignmentCenter;
                paragraph.lineSpacing = 12.0;

                UIFont *font =
                    [UIFont systemFontOfSize:fontSize
                                      weight:UIFontWeightRegular];

                NSDictionary<NSAttributedStringKey, id> *attributes = @{
                    NSFontAttributeName: font,
                    NSForegroundColorAttributeName: UIColor.blackColor,
                    NSParagraphStyleAttributeName: paragraph
                };

                CGRect textRect =
                    CGRectInset(
                        (CGRect){ .origin = CGPointZero, .size = canvasSize },
                        18.0,
                        20.0
                    );

                [sample drawWithRect:textRect
                             options:
                    NSStringDrawingUsesLineFragmentOrigin |
                    NSStringDrawingUsesFontLeading
                          attributes:attributes
                             context:nil];
            }];

    return UIImagePNGRepresentation(image);
}

@implementation CoreTextGB18030Service

+ (NSDictionary<NSString *, id> *)probeWithError:(NSError **)error
{
    NSString *build = GECurrentOSBuild();
    BOOL buildSupported =
        [build isEqualToString:kGECoreTextSupportedBuild];

    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    NSString *imageName = nil;

    BOOL loaded =
        GEFindLoadedCoreTextImage(
            &header,
            &slide,
            &imageName
        );

    NSMutableDictionary<NSString *, id> *result =
        [NSMutableDictionary dictionaryWithDictionary:@{
            @"build": build,
            @"buildSupported": @(buildSupported),
            @"coreTextLoaded": @(loaded),
            @"imageName": imageName ?: NSNull.null,
            @"headerAddress": header
                ? GEHexAddress((uintptr_t)header)
                : (id)NSNull.null,
            @"slide": loaded
                ? GEHexSignedSlide(slide)
                : (id)NSNull.null,
            @"staticImageBase": GEHexAddress(kGECoreTextStaticImageBase)
        }];

    [result addEntriesFromDictionary:
        GESharedCacheDiagnostics(header)];

    if (!buildSupported || !loaded) {
        result[@"addressValidationAvailable"] = @NO;

        if (error) {
            *error = nil;
        }

        return result;
    }

    uintptr_t cachedAddress = 0;
    uintptr_t onceAddress = 0;
    NSDictionary<NSString *, id> *details = nil;
    NSError *validationError = nil;

    BOOL validated =
        GEValidatedRuntimeAddresses(
            header,
            slide,
            &cachedAddress,
            &onceAddress,
            &details,
            &validationError
        );

    result[@"addressValidationAvailable"] = @YES;
    result[@"addressValidated"] = @(validated);

    if (!validated) {
        result[@"validationError"] =
            validationError.localizedDescription ?: @"Unknown validation error.";

        if (error) {
            *error = nil;
        }

        return result;
    }

    [result addEntriesFromDictionary:details];

    uint8_t cachedByte =
        __atomic_load_n(
            (uint8_t *)cachedAddress,
            __ATOMIC_SEQ_CST
        );

    int64_t onceValue = 0;
    memcpy(
        &onceValue,
        (const void *)onceAddress,
        sizeof(onceValue)
    );

    result[@"cachedByte"] = @(cachedByte);
    result[@"onceTokenValue"] =
        [NSString stringWithFormat:@"%lld / 0x%016llX",
            (long long)onceValue,
            (unsigned long long)(uint64_t)onceValue
        ];
    result[@"onceComplete"] = @(onceValue == -1);

    if (error) {
        *error = nil;
    }

    return result;
}

+ (NSDictionary<NSString *, id> *)runGB18030RenderingExperimentWithError:
    (NSError **)error
{
    if (![NSThread isMainThread]) {
        if (error) {
            *error = GECoreTextError(
                20,
                @"The CoreText rendering experiment must run on the main thread."
            );
        }
        return nil;
    }

    NSString *build = GECurrentOSBuild();

    if (![build isEqualToString:kGECoreTextSupportedBuild]) {
        if (error) {
            *error = GECoreTextError(
                21,
                [NSString stringWithFormat:
                    @"This experiment is hard-gated to %@. Current build: %@.",
                    kGECoreTextSupportedBuild,
                    build.length > 0 ? build : @"<unknown>"
                ]
            );
        }
        return nil;
    }

    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    NSString *imageName = nil;

    if (!GEFindLoadedCoreTextImage(
            &header,
            &slide,
            &imageName)) {
        if (error) {
            *error = GECoreTextError(
                22,
                @"CoreText is not currently present in dyld's loaded-image list."
            );
        }
        return nil;
    }

    uintptr_t cachedAddress = 0;
    uintptr_t onceAddress = 0;
    NSDictionary<NSString *, id> *details = nil;
    NSError *validationError = nil;

    if (!GEValidatedRuntimeAddresses(
            header,
            slide,
            &cachedAddress,
            &onceAddress,
            &details,
            &validationError)) {
        if (error) {
            *error = validationError;
        }
        return nil;
    }

    // Prime the exact path we actually care about instead of making a direct
    // arm64e call to the private C++ predicate. Rendering the Taiwan-flag
    // sample naturally reaches CoreText's emoji/color-glyph path. If that
    // path consults IsGB18030ComplianceRequired(), Apple's own dispatch_once
    // callback initializes the cached byte and once token.
    //
    // This is intentionally a baseline image: it is rendered before any byte
    // mutation and is useful as the visual control for the current behavior.
    NSData *baselinePNG = GERenderEmojiSample(70.0);

    if (!baselinePNG) {
        if (error) {
            *error = GECoreTextError(
                23,
                @"Failed to render the baseline emoji sample. No CoreText byte was modified."
            );
        }
        return nil;
    }

    int64_t onceValueAfterPriming = 0;
    memcpy(
        &onceValueAfterPriming,
        (const void *)onceAddress,
        sizeof(onceValueAfterPriming)
    );

    uint8_t originalByte =
        __atomic_load_n(
            (uint8_t *)cachedAddress,
            __ATOMIC_SEQ_CST
        );

    // If the token is still zero, the real rendering path did not touch this
    // recovered predicate in this process. That is a useful result in itself;
    // do not manufacture state by directly calling the private function or by
    // modifying the once token.
    if (onceValueAfterPriming != -1) {
        if (error) {
            *error = GECoreTextError(
                24,
                [NSString stringWithFormat:
                    @"Baseline emoji rendering completed, but CoreText's recovered GB18030 dispatch_once token is still %lld (0x%016llX) and cached byte is %u. The experiment will not modify the byte because this process has not naturally initialized that predicate.",
                    (long long)onceValueAfterPriming,
                    (unsigned long long)(uint64_t)onceValueAfterPriming,
                    originalByte
                ]
            );
        }
        return nil;
    }

    if (originalByte > 1) {
        if (error) {
            *error = GECoreTextError(
                25,
                [NSString stringWithFormat:
                    @"Unexpected CoreText GB18030 cached byte after priming: %u.",
                    originalByte
                ]
            );
        }
        return nil;
    }

    NSData *forcedPNG = nil;
    NSData *restoredPNG = nil;
    NSException *caughtException = nil;
    uint8_t duringByte = originalByte;
    uint8_t restoredByte = originalByte;

    @try {
        // Exactly one process-local byte is changed. No page-protection change
        // is performed; GEValidatedRuntimeAddresses already required RW.
        __atomic_store_n(
            (uint8_t *)cachedAddress,
            (uint8_t)0,
            __ATOMIC_SEQ_CST
        );

        duringByte =
            __atomic_load_n(
                (uint8_t *)cachedAddress,
                __ATOMIC_SEQ_CST
            );

        // Render through the same public UIKit/CoreText path while the cached
        // answer is forced false. The once token is already complete, so the
        // recovered CoreText predicate's fast path reads this byte directly.
        forcedPNG = GERenderEmojiSample(72.0);
    }
    @catch (NSException *exception) {
        caughtException = exception;
    }
    @finally {
        __atomic_store_n(
            (uint8_t *)cachedAddress,
            originalByte,
            __ATOMIC_SEQ_CST
        );

        restoredByte =
            __atomic_load_n(
                (uint8_t *)cachedAddress,
                __ATOMIC_SEQ_CST
            );
    }

    BOOL restoreVerified =
        restoredByte == originalByte;

    if (!restoreVerified) {
        if (error) {
            *error = GECoreTextError(
                26,
                [NSString stringWithFormat:
                    @"CoreText cached-byte restoration verification failed: original=%u restored=%u.",
                    originalByte,
                    restoredByte
                ]
            );
        }
        return nil;
    }

    if (caughtException) {
        if (error) {
            *error = GECoreTextError(
                27,
                [NSString stringWithFormat:
                    @"Rendering raised %@: %@. The original cached byte was restored.",
                    caughtException.name,
                    caughtException.reason ?: @"<no reason>"
                ]
            );
        }
        return nil;
    }

    if (!forcedPNG) {
        if (error) {
            *error = GECoreTextError(
                28,
                @"Failed to encode the forced-false rendering as PNG. The original cached byte was restored."
            );
        }
        return nil;
    }

    // Create a post-restore control only after the byte has been restored.
    // A slightly different font size is deliberate: it reduces the chance of
    // an already-created color-glyph image object being reused across draws.
    restoredPNG = GERenderEmojiSample(74.0);

    if (!restoredPNG) {
        if (error) {
            *error = GECoreTextError(
                29,
                @"Failed to encode the restored control rendering as PNG."
            );
        }
        return nil;
    }

    BOOL cachedPredicateBefore = originalByte != 0;
    BOOL cachedPredicateDuring = duringByte != 0;
    BOOL cachedPredicateRestored = restoredByte != 0;

    NSMutableDictionary<NSString *, id> *result =
        [NSMutableDictionary dictionaryWithDictionary:@{
            @"build": build,
            @"imageName": imageName ?: NSNull.null,
            @"headerAddress": GEHexAddress((uintptr_t)header),
            @"slide": GEHexSignedSlide(slide),
            @"onceTokenAfterPriming":
                [NSString stringWithFormat:@"%lld / 0x%016llX",
                    (long long)onceValueAfterPriming,
                    (unsigned long long)(uint64_t)onceValueAfterPriming
                ],
            @"originalCachedByte": @(originalByte),
            @"forcedCachedByte": @(duringByte),
            @"restoredCachedByte": @(restoredByte),
            @"restoreVerified": @(restoreVerified),
            @"didActuallyChangeByte": @(originalByte != 0),
            @"cachedPredicateBefore": @(cachedPredicateBefore),
            @"cachedPredicateWhileForced": @(cachedPredicateDuring),
            @"cachedPredicateAfterRestore": @(cachedPredicateRestored),
            @"predicateTransitionVerified": @(
                cachedPredicateDuring == NO &&
                cachedPredicateRestored == cachedPredicateBefore
            ),
            @"predicateMeasurement": @"direct cached-byte observation; no private predicate function pointer call",
            @"baselinePNG": baselinePNG,
            @"forcedPNG": forcedPNG,
            @"restoredPNG": restoredPNG,
            @"systemFilesModified": @NO,
            @"pageProtectionChanged": @NO,
            @"onceTokenModified": @NO
        }];

    [result addEntriesFromDictionary:details];
    [result addEntriesFromDictionary:
        GESharedCacheDiagnostics(header)];

    if (error) {
        *error = nil;
    }

    return result;
}

@end
