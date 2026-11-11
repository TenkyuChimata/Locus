// SPDX-License-Identifier: GPL-3.0-only
#import "MobileGestaltImage.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <ptrauth.h>
#import <stdint.h>
#import <string.h>

#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && defined(__arm64__)
static NSData *LocusImageRead(uint64_t address, uint64_t length) {
    if (!address || !length || length > 32 * 1024 * 1024 || address > UINT64_MAX - length) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    mach_vm_size_t copied = 0;
    kern_return_t result = mach_vm_read_overwrite(mach_task_self(), address, length,
                                                 (mach_vm_address_t)data.mutableBytes, &copied);
    return result == KERN_SUCCESS && copied == length ? data : nil;
}

static BOOL LocusSlide(uint64_t address, intptr_t slide, uint64_t *out) {
    if (slide >= 0) {
        if (address > UINT64_MAX - (uint64_t)slide) return NO;
        *out = address + (uint64_t)slide;
    } else {
        uint64_t magnitude = (uint64_t)(-(slide + 1)) + 1;
        if (address < magnitude) return NO;
        *out = address - magnitude;
    }
    return YES;
}

// An arm64 application can inspect an arm64e system dylib. On that target the
// ptrauth.h macro may be an identity operation. XPACD/XPACI strip only local
// register copies; execute them only for a dyld-loaded arm64e image (which
// already requires pointer-auth hardware). No pointer is authenticated/called.
static uintptr_t LocusImageStripData(uintptr_t value, BOOL arm64e) {
#if __has_feature(ptrauth_intrinsics)
    (void)arm64e;
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_asda);
#else
    if (!arm64e) return value;
    register uintptr_t stripped __asm__("x16") = value;
    __asm__ volatile(".inst 0xdac147f0" : "+r"(stripped)); // xpacd x16
    return stripped;
#endif
}
static uintptr_t LocusImageStripCode(uintptr_t value, BOOL arm64e) {
#if __has_feature(ptrauth_intrinsics)
    (void)arm64e;
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_asia);
#else
    if (!arm64e) return value;
    register uintptr_t stripped __asm__("x16") = value;
    __asm__ volatile(".inst 0xdac143f0" : "+r"(stripped)); // xpaci x16
    return stripped;
#endif
}
#endif

@implementation MobileGestaltImage
+ (NSDictionary<NSString *, id> *)snapshotWithError:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"io.github.tenkyuchimata.locus.layout" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Loaded MobileGestalt image is unavailable or malformed; dynamic layout refused."}];
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && defined(__arm64__)
    const char *path = "/usr/lib/libMobileGestalt.dylib";
    const struct mach_header *found = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || strcmp(name, path)) continue;
        if (found) return nil;
        found = _dyld_get_image_header(i);
        slide = _dyld_get_image_vmaddr_slide(i);
    }
    if (!found) return nil;
    NSData *prefix = LocusImageRead((uintptr_t)found, sizeof(struct mach_header_64));
    if (!prefix) return nil;
    struct mach_header_64 header;
    memcpy(&header, prefix.bytes, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
        header.filetype != MH_DYLIB || !header.ncmds || header.ncmds > 4096 ||
        header.sizeofcmds > 1024 * 1024 || header.sizeofcmds < header.ncmds * 8) return nil;
    NSData *commands = LocusImageRead((uintptr_t)found, sizeof(header) + header.sizeofcmds);
    if (!commands) return nil;
    const uint8_t *bytes = commands.bytes;
    NSUInteger offset = sizeof(header), total = 0;
    NSMutableArray *sections = [NSMutableArray array];
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (offset > commands.length - 8) return nil;
        struct load_command command;
        memcpy(&command, bytes + offset, sizeof(command));
        if (command.cmdsize < 8 || command.cmdsize % 8 || command.cmdsize > commands.length - offset) return nil;
        if (command.cmd == LC_SEGMENT_64) {
            if (command.cmdsize < sizeof(struct segment_command_64)) return nil;
            struct segment_command_64 segment;
            memcpy(&segment, bytes + offset, sizeof(segment));
            if (segment.nsects > 256 || sizeof(segment) + segment.nsects * sizeof(struct section_64) != command.cmdsize) return nil;
            for (uint32_t j = 0; j < segment.nsects; j++) {
                struct section_64 section;
                memcpy(&section, bytes + offset + sizeof(segment) + j * sizeof(section), sizeof(section));
                BOOL text = !strncmp(segment.segname, "__TEXT", 16) &&
                    (!strncmp(section.sectname, "__text", 16) || !strncmp(section.sectname, "__cstring", 16));
                BOOL constants = (!strncmp(segment.segname, "__AUTH_CONST", 16) ||
                    !strncmp(segment.segname, "__DATA_CONST", 16) || !strncmp(segment.segname, "__DATA", 16)) &&
                    (!strncmp(section.sectname, "__const", 16) || !strncmp(section.sectname, "__cfstring", 16));
                if (!text && !constants) continue;
                if (strncmp(section.segname, segment.segname, 16) || !(segment.initprot & VM_PROT_READ) ||
                    section.addr < segment.vmaddr || section.size > segment.vmsize ||
                    section.addr - segment.vmaddr > segment.vmsize - section.size ||
                    section.size > 32 * 1024 * 1024 || total > 64 * 1024 * 1024 - section.size) return nil;
                if (!section.size) continue;
                uint64_t address;
                if (!LocusSlide(section.addr, slide, &address)) return nil;
                NSData *data = LocusImageRead(address, section.size);
                if (!data) return nil;
                // Strip with the platform primitive, never a low-bit address mask.
                // These words are compared within copied sections, never dereferenced
                // or called. Stripping is not a claim of PAC authentication.
                NSMutableData *pointers = [data mutableCopy];
                if (constants) {
                    for (NSUInteger k = 0; k + 8 <= data.length; k += 8) {
                        uintptr_t word;
                        memcpy(&word, (const uint8_t *)data.bytes + k, 8);
                        word = LocusImageStripData(word, (header.cpusubtype & 0x00FFFFFF) == CPU_SUBTYPE_ARM64E);
                        memcpy((uint8_t *)pointers.mutableBytes + k, &word, 8);
                    }
                }
                [sections addObject:@{@"segment": [[NSString alloc] initWithBytes:segment.segname length:strnlen(segment.segname, 16) encoding:NSASCIIStringEncoding],
                    @"name": [[NSString alloc] initWithBytes:section.sectname length:strnlen(section.sectname, 16) encoding:NSASCIIStringEncoding],
                    @"address": @(address), @"data": data, @"pointers": pointers}];
                total += data.length;
            }
        }
        offset += command.cmdsize;
    }
    if (offset != commands.length || !sections.count) return nil;
    void *symbol = dlsym(RTLD_DEFAULT, "_MGWriteCache");
    symbol = (void *)LocusImageStripCode((uintptr_t)symbol,
        (header.cpusubtype & 0x00FFFFFF) == CPU_SUBTYPE_ARM64E);
    Dl_info info;
    if (!symbol || !dladdr(symbol, &info) || info.dli_fbase != found) return nil;
    if (error) *error = nil;
    return @{@"header": commands, @"slide": @(slide), @"sections": sections,
             @"writerAddress": @((uintptr_t)symbol)};
#else
    return nil;
#endif
}
@end
