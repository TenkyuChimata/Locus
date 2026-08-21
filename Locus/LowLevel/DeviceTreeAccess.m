//
//  DeviceTreeAccess.m
//  Locus
//

#import "DeviceTreeAccess.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <stdint.h>

typedef mach_port_t LocusIOObject;
typedef LocusIOObject LocusIORegistryEntry;
typedef uint32_t LocusIOOptionBits;

typedef LocusIORegistryEntry (*LocusIORegistryEntryFromPath)(
    mach_port_t mainPort,
    const char *path
);
typedef CFTypeRef (*LocusIORegistryEntryCreateCFProperty)(
    LocusIORegistryEntry entry,
    CFStringRef key,
    CFAllocatorRef allocator,
    LocusIOOptionBits options
);
typedef kern_return_t (*LocusIORegistryEntryCreateCFProperties)(
    LocusIORegistryEntry entry,
    CFMutableDictionaryRef _Nullable *properties,
    CFAllocatorRef allocator,
    LocusIOOptionBits options
);
typedef kern_return_t (*LocusIOObjectRelease)(LocusIOObject object);

static NSString * const LocusIOKitPath =
    @"/System/Library/Frameworks/IOKit.framework/IOKit";

static NSError *LocusDeviceTreeError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"io.github.tenkyuchimata.locus.devicetree"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation DeviceTreeAccess

+ (instancetype)shared
{
    static DeviceTreeAccess *access;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        access = [DeviceTreeAccess new];
    });
    return access;
}

- (NSDictionary<NSString *, id> *)chosenPropertiesForNames:
    (NSArray<NSString *> *)names
    error:(NSError **)error
{
    if (names.count == 0) {
        if (error) {
            *error = nil;
        }
        return @{};
    }

    void *handle = dlopen(LocusIOKitPath.fileSystemRepresentation,
                          RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        if (error) {
            *error = LocusDeviceTreeError(
                1,
                [NSString stringWithFormat:@"Failed to load IOKit: %s",
                    dlerror() ?: "unknown error"]
            );
        }
        return nil;
    }

    LocusIORegistryEntryFromPath entryFromPath =
        (LocusIORegistryEntryFromPath)dlsym(handle, "IORegistryEntryFromPath");
    LocusIORegistryEntryCreateCFProperty createProperty =
        (LocusIORegistryEntryCreateCFProperty)dlsym(
            handle,
            "IORegistryEntryCreateCFProperty"
        );
    LocusIOObjectRelease releaseObject =
        (LocusIOObjectRelease)dlsym(handle, "IOObjectRelease");
    if (!entryFromPath || !createProperty || !releaseObject) {
        dlclose(handle);
        if (error) {
            *error = LocusDeviceTreeError(2, @"Required IOKit symbols are unavailable.");
        }
        return nil;
    }

    LocusIORegistryEntry chosen = entryFromPath(
        MACH_PORT_NULL,
        "IODeviceTree:/chosen"
    );
    if (chosen == MACH_PORT_NULL) {
        dlclose(handle);
        if (error) {
            *error = LocusDeviceTreeError(3, @"Could not open IODeviceTree:/chosen.");
        }
        return nil;
    }

    NSMutableDictionary<NSString *, id> *result =
        [NSMutableDictionary dictionaryWithCapacity:names.count];
    for (NSString *name in names) {
        if (![name isKindOfClass:NSString.class] || name.length == 0) {
            continue;
        }
        CFTypeRef value = createProperty(
            chosen,
            (__bridge CFStringRef)name,
            kCFAllocatorDefault,
            0
        );
        if (value) {
            result[name] = (__bridge id)value;
            CFRelease(value);
        } else {
            result[name] = NSNull.null;
        }
    }

    releaseObject(chosen);
    dlclose(handle);
    if (error) {
        *error = nil;
    }
    return [result copy];
}

- (NSDictionary<NSString *, id> *)propertiesAtPath:(NSString *)path
    error:(NSError **)error
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) {
        if (error) {
            *error = LocusDeviceTreeError(10, @"The IODeviceTree path is empty.");
        }
        return nil;
    }

    void *handle = dlopen(LocusIOKitPath.fileSystemRepresentation,
                          RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        if (error) {
            *error = LocusDeviceTreeError(
                11,
                [NSString stringWithFormat:@"Failed to load IOKit: %s",
                    dlerror() ?: "unknown error"]
            );
        }
        return nil;
    }

    LocusIORegistryEntryFromPath entryFromPath =
        (LocusIORegistryEntryFromPath)dlsym(handle, "IORegistryEntryFromPath");
    LocusIORegistryEntryCreateCFProperties createProperties =
        (LocusIORegistryEntryCreateCFProperties)dlsym(
            handle,
            "IORegistryEntryCreateCFProperties"
        );
    LocusIOObjectRelease releaseObject =
        (LocusIOObjectRelease)dlsym(handle, "IOObjectRelease");
    if (!entryFromPath || !createProperties || !releaseObject) {
        dlclose(handle);
        if (error) {
            *error = LocusDeviceTreeError(12, @"Required IOKit symbols are unavailable.");
        }
        return nil;
    }

    LocusIORegistryEntry entry = entryFromPath(MACH_PORT_NULL, path.UTF8String);
    if (entry == MACH_PORT_NULL) {
        dlclose(handle);
        if (error) {
            *error = LocusDeviceTreeError(
                13,
                [NSString stringWithFormat:@"Could not open %@.", path]
            );
        }
        return nil;
    }

    CFMutableDictionaryRef properties = NULL;
    kern_return_t status = createProperties(
        entry,
        &properties,
        kCFAllocatorDefault,
        0
    );
    releaseObject(entry);
    dlclose(handle);
    if (status != KERN_SUCCESS || !properties) {
        if (properties) {
            CFRelease(properties);
        }
        if (error) {
            *error = LocusDeviceTreeError(
                14,
                [NSString stringWithFormat:
                    @"IORegistryEntryCreateCFProperties failed (%d).",
                    status]
            );
        }
        return nil;
    }

    NSDictionary *result = [(__bridge NSDictionary *)properties copy];
    CFRelease(properties);
    if (error) {
        *error = nil;
    }
    return result;
}

@end
