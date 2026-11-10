// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
// Loaded-image collection adapted from GestaltX (see notices).
// Locus uses checked Mach VM reads, segment bounds and separate evidence levels.
#import "MobileGestaltImage.h"
#import <TargetConditionals.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdint.h>
#import <string.h>

static NSData *LocusReadMemory(uint64_t address, uint64_t size)
{
    if (!address || !size || size > 32 * 1024 * 1024 || address > UINT64_MAX - size) return nil;
    // The native-width VM interface is exposed by mach/mach.h on iPhoneOS.
    // Reject truncation and range overflow before passing arguments to Mach.
    const uint64_t maximumVMAddress = (uint64_t)((vm_address_t)-1);
    vm_address_t source = (vm_address_t)address;
    vm_size_t length = (vm_size_t)size;
    if ((uint64_t)source != address || (uint64_t)length != size ||
        (uint64_t)(NSUInteger)size != size || size > maximumVMAddress ||
        address > maximumVMAddress - size) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
    uintptr_t buffer = (uintptr_t)data.mutableBytes;
    vm_address_t destination = (vm_address_t)buffer;
    if (!buffer || (uint64_t)destination != (uint64_t)buffer ||
        size > UINTPTR_MAX || buffer > UINTPTR_MAX - (uintptr_t)size ||
        (uint64_t)destination > maximumVMAddress - size) return nil;
    vm_size_t copied = 0;
    kern_return_t rc = vm_read_overwrite(mach_task_self(), source, length, destination, &copied);
    return rc == KERN_SUCCESS && copied == length ? data : nil;
}

static BOOL LocusSlide(uint64_t address, intptr_t slide, uint64_t *result)
{
    if (slide >= 0) {
        if (address > UINT64_MAX - (uint64_t)slide) return NO;
        *result = address + (uint64_t)slide;
    } else {
        uint64_t magnitude = (uint64_t)(-(slide + 1)) + 1;
        if (address < magnitude) return NO;
        *result = address - magnitude;
    }
    return *result != 0;
}

static NSDictionary *LocusSnapshotImage(NSString *path, BOOL includeSections)
{
    const struct mach_header *headerPointer = NULL;
    intptr_t slide = 0;
    NSUInteger matches = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && !strcmp(name, path.UTF8String)) {
            matches++;
            headerPointer = _dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
        }
    }
    if (matches != 1) return @{@"error": @"Loaded image is missing or ambiguous."};
    NSData *headerData = LocusReadMemory((uint64_t)headerPointer, sizeof(struct mach_header_64));
    if (!headerData) return @{@"error": @"Cannot read loaded Mach-O header."};
    struct mach_header_64 header;
    memcpy(&header, headerData.bytes, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.sizeofcmds > 4 * 1024 * 1024 ||
        header.ncmds > header.sizeofcmds / sizeof(struct load_command))
        return @{@"error": @"Invalid Mach-O command bounds."};
    uint64_t commandsAddress = (uint64_t)headerPointer;
    if (commandsAddress > UINT64_MAX - sizeof(header)) return @{@"error": @"Header overflow."};
    NSData *commands = LocusReadMemory(commandsAddress + sizeof(header), header.sizeofcmds);
    if (!commands) return @{@"error": @"Cannot read load commands."};
    const uint8_t *bytes = commands.bytes;
    NSUInteger offset = 0, uuidCount = 0;
    NSString *uuid = nil;
    NSMutableArray *sections = [NSMutableArray new];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray new];
    NSString *failure = nil;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (offset > commands.length || commands.length - offset < sizeof(struct load_command)) {
            failure = @"Truncated load command."; break;
        }
        struct load_command command;
        memcpy(&command, bytes + offset, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > commands.length - offset || command.cmdsize % 8) {
            failure = @"Invalid load command size."; break;
        }
        if (command.cmd == LC_UUID) {
            if (command.cmdsize != sizeof(struct uuid_command)) { failure = @"Invalid UUID command."; break; }
            struct uuid_command value;
            memcpy(&value, bytes + offset, sizeof(value));
            uuid = [[NSUUID alloc] initWithUUIDBytes:value.uuid].UUIDString;
            uuidCount++;
        }
        if (command.cmd == LC_SEGMENT_64) {
            if (command.cmdsize < sizeof(struct segment_command_64)) { failure = @"Truncated segment."; break; }
            struct segment_command_64 segment;
            memcpy(&segment, bytes + offset, sizeof(segment));
            if (segment.nsects > 4096 || segment.nsects >
                (command.cmdsize - sizeof(segment)) / sizeof(struct section_64) ||
                segment.vmaddr > UINT64_MAX - segment.vmsize) {
                failure = @"Invalid segment/section bounds."; break;
            }
            for (uint32_t j = 0; includeSections && j < segment.nsects; j++) {
                struct section_64 section;
                memcpy(&section, bytes + offset + sizeof(segment) + j * sizeof(section), sizeof(section));
                BOOL strings = !strncmp(segment.segname, "__TEXT", 16) && !strncmp(section.sectname, "__cstring", 16);
                BOOL constants = (!strncmp(segment.segname, "__AUTH_CONST", 16) ||
                    !strncmp(segment.segname, "__DATA_CONST", 16) || !strncmp(segment.segname, "__DATA", 16)) &&
                    !strncmp(section.sectname, "__const", 16);
                if (!strings && !constants) continue;
                if (!section.size) continue; // Empty sections contain no candidate descriptors/strings.
                uint64_t runtime = 0;
                if (strncmp(section.segname, segment.segname, 16) ||
                    section.addr < segment.vmaddr || section.addr - segment.vmaddr > segment.vmsize ||
                    section.size > segment.vmsize - (section.addr - segment.vmaddr) ||
                    !LocusSlide(section.addr, slide, &runtime) ||
                    !section.size || section.size > 32 * 1024 * 1024 || runtime > UINT64_MAX - section.size) {
                    failure = @"Selected section escapes its segment."; break;
                }
                NSRange range = NSMakeRange((NSUInteger)runtime, (NSUInteger)section.size);
                for (NSValue *previous in ranges) {
                    if (NSIntersectionRange(previous.rangeValue, range).length) failure = @"Overlapping selected sections.";
                }
                if (failure) break;
                NSData *data = LocusReadMemory(runtime, section.size);
                if (!data) { failure = @"Selected section is not fully readable."; break; }
                [ranges addObject:[NSValue valueWithRange:range]];
                NSString *name = [NSString stringWithFormat:@"%.16s.%.16s", segment.segname, section.sectname];
                [sections addObject:@{@"name": name, @"address": @(runtime), @"data": data}];
            }
            if (failure) break;
        }
        offset += command.cmdsize;
    }
    if (failure || offset != commands.length || uuidCount != 1)
        return @{@"error": failure ?: @"Missing/duplicate LC_UUID or unused command bytes."};
    return @{@"binaryUUID": uuid, @"path": path, @"sections": sections,
             @"cpuType": @((uint32_t)header.cputype), @"cpuSubtype": @((uint32_t)header.cpusubtype),
             @"source": @"current process loaded image", @"slide": @(slide),
             @"pointerRepresentation": @"dyld-resolved key addresses",
             @"pointerComparison": @"Exact key-address comparison; unknown PAC/tag/fixup forms rejected. No PAC authentication performed."};
}

NSDictionary<NSString *, id> *LocusLoadedImageIdentity(NSString *path)
{
    return LocusSnapshotImage(path, NO);
}

NSDictionary<NSString *, id> *LocusCopyMobileGestaltImage(void)
{
#if TARGET_OS_SIMULATOR
    return @{@"error": @"Device mapping is unavailable in Simulator."};
#else
    // Observe an already loaded image only. dlopen could run initializers;
    // a missing image is not permission to initialize a cache during a probe.
    return LocusSnapshotImage(@"/usr/lib/libMobileGestalt.dylib", YES);
#endif
}
