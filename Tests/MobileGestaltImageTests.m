// SPDX-License-Identifier: GPL-3.0-only
// Synthetic loaded Mach-O; actual checked Mach VM reads in this process only.
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <assert.h>
#import <string.h>
#import <sys/mman.h>
#import <unistd.h>
static uint32_t TestCount(void);
static const char *TestName(uint32_t);
static const struct mach_header *TestHeader(uint32_t);
static intptr_t TestSlide(uint32_t);
static kern_return_t TestReadOverwrite(vm_map_read_t, vm_address_t, vm_size_t, vm_address_t, vm_size_t *);
#define _dyld_image_count TestCount
#define _dyld_get_image_name TestName
#define _dyld_get_image_header TestHeader
#define _dyld_get_image_vmaddr_slide TestSlide
#define vm_read_overwrite TestReadOverwrite
#import "../Locus/LowLevel/MobileGestaltImage.m"
#undef _dyld_image_count
#undef _dyld_get_image_name
#undef _dyld_get_image_header
#undef _dyld_get_image_vmaddr_slide
#undef vm_read_overwrite

typedef NS_ENUM(NSUInteger, ReadFault) { ReadFaultNone, ReadFaultStatus, ReadFaultShort, ReadFaultOversized };
static ReadFault readFault;
static NSUInteger readCalls;
static kern_return_t TestReadOverwrite(vm_map_read_t task, vm_address_t address, vm_size_t size,
                                      vm_address_t destination, vm_size_t *copied)
{
    readCalls++;
    assert(task == mach_task_self() && copied);
    switch (readFault) {
        case ReadFaultStatus: *copied = size; return KERN_FAILURE;
        case ReadFaultShort: *copied = size - 1; return KERN_SUCCESS;
        case ReadFaultOversized: *copied = size + 1; return KERN_SUCCESS;
        case ReadFaultNone: return vm_read_overwrite(task, address, size, destination, copied);
    }
    assert(0 && "Unknown VM read fault");
    return KERN_FAILURE;
}

static void CheckMemoryReads(void)
{
    const char sample[] = "checked VM read";
    uint64_t address = (uint64_t)(uintptr_t)sample;
    NSData *copy = LocusReadMemory(address, sizeof(sample));
    assert(copy.length == sizeof(sample) && !memcmp(copy.bytes, sample, sizeof(sample)));
    NSUInteger before = readCalls;
    assert(!LocusReadMemory(0, 1));
    assert(!LocusReadMemory(address, 0));
    assert(!LocusReadMemory(address, 32 * 1024 * 1024 + 1));
    assert(!LocusReadMemory(UINT64_MAX, 1));
    assert(!LocusReadMemory(UINT64_MAX - 3, 8));
    assert(readCalls == before); // Invalid ranges must not reach Mach.
    size_t pageSize = (size_t)getpagesize();
    void *unreadable = mmap(NULL, pageSize, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(unreadable != MAP_FAILED);
    assert(!LocusReadMemory((uint64_t)(uintptr_t)unreadable, 1));
    assert(munmap(unreadable, pageSize) == 0);
    for (ReadFault fault = ReadFaultStatus; fault <= ReadFaultOversized; fault++) {
        readFault = fault;
        before = readCalls;
        assert(!LocusReadMemory(address, sizeof(sample)));
        assert(readCalls == before + 1);
    }
    readFault = ReadFaultStatus;
    before = readCalls;
    assert(!LocusReadMemory(address, 32 * 1024 * 1024));
    assert(readCalls == before + 1); // The existing inclusive limit is retained.
    readFault = ReadFaultNone;
    copy = LocusReadMemory(address, sizeof(sample));
    assert(copy.length == sizeof(sample) && !memcmp(copy.bytes, sample, sizeof(sample)));
}

struct FixtureImage {
    struct mach_header_64 header;
    struct uuid_command uuid;
    struct segment_command_64 text;
    struct section_64 strings;
    struct segment_command_64 constants;
    struct section_64 descriptors;
};
static struct FixtureImage fixture;
static char strings[64];
static char constants[128];
static intptr_t testSlide;
static uint32_t imageCount = 1;
static uint32_t TestCount(void) { return imageCount; }
static const char *TestName(uint32_t i) { (void)i; return "/usr/lib/libMobileGestalt.dylib"; }
static const struct mach_header *TestHeader(uint32_t i) { (void)i; return (const void *)&fixture; }
static intptr_t TestSlide(uint32_t i) { (void)i; return testSlide; }
static void Reset(intptr_t slide)
{
    memset(&fixture, 0, sizeof(fixture));
    testSlide = slide;
    imageCount = 1;
    fixture.header.magic = MH_MAGIC_64;
    fixture.header.cputype = CPU_TYPE_ARM64;
    fixture.header.cpusubtype = CPU_SUBTYPE_ARM64E;
    fixture.header.ncmds = 3;
    fixture.header.sizeofcmds = sizeof(fixture) - sizeof(fixture.header);
    fixture.uuid.cmd = LC_UUID;
    fixture.uuid.cmdsize = sizeof(fixture.uuid);
    fixture.uuid.uuid[0] = 1;
    struct segment_command_64 *segments[] = {&fixture.text, &fixture.constants};
    struct section_64 *sections[] = {&fixture.strings, &fixture.descriptors};
    for (int i = 0; i < 2; i++) {
        struct segment_command_64 *segment = segments[i];
        struct section_64 *section = sections[i];
        segment->cmd = LC_SEGMENT_64;
        segment->cmdsize = sizeof(*segment) + sizeof(*section);
        segment->nsects = 1;
        segment->vmaddr = (uint64_t)(i ? constants : strings) - slide;
        segment->vmsize = i ? sizeof(constants) : sizeof(strings);
        strcpy(segment->segname, i ? "__AUTH_CONST" : "__TEXT");
        strcpy(section->segname, segment->segname);
        strcpy(section->sectname, i ? "__const" : "__cstring");
        section->addr = segment->vmaddr;
        section->size = segment->vmsize;
    }
}
static NSDictionary *Snapshot(void) { return LocusSnapshotImage(@"/usr/lib/libMobileGestalt.dylib", YES); }
int main(void)
{
    @autoreleasepool {
        CheckMemoryReads();
        for (int sign = -1; sign <= 1; sign++) {
            Reset(sign * 0x100000);
            NSDictionary *value = Snapshot();
            assert(!value[@"error"] && [value[@"sections"] count] == 2 && value[@"binaryUUID"]);
            assert([value[@"cpuType"] unsignedIntValue] == CPU_TYPE_ARM64);
            assert([value[@"cpuSubtype"] unsignedIntValue] == CPU_SUBTYPE_ARM64E);
            assert([value[@"pointerRepresentation"] isEqual:@"dyld-resolved key addresses"]);
        }
        Reset(0); fixture.header.sizeofcmds = UINT32_MAX; assert(Snapshot()[@"error"]);
        Reset(0); fixture.header.ncmds++; assert(Snapshot()[@"error"]);
        Reset(0); fixture.uuid.cmdsize = 0; assert(Snapshot()[@"error"]);
        Reset(0); fixture.uuid.cmd = LC_LOAD_DYLIB; assert(Snapshot()[@"error"]);
        Reset(0);
        fixture.header.ncmds = 2;
        fixture.header.sizeofcmds = 2 * sizeof(struct uuid_command);
        struct uuid_command duplicate = fixture.uuid;
        duplicate.uuid[0] = 2;
        memcpy(&fixture.text, &duplicate, sizeof(duplicate));
        assert([Snapshot()[@"error"] hasPrefix:@"Missing/duplicate LC_UUID"]);
        Reset(0); fixture.text.nsects = UINT32_MAX; assert(Snapshot()[@"error"]);
        Reset(0); fixture.strings.addr--; assert(Snapshot()[@"error"]);
        Reset(0); fixture.strings.size++; assert(Snapshot()[@"error"]);
        Reset(0); strcpy(fixture.strings.segname, "__DATA"); assert(Snapshot()[@"error"]);
        Reset(0); fixture.text.vmaddr = fixture.strings.addr = 1; assert(Snapshot()[@"error"]); // safe read failure
        Reset(0); fixture.constants.vmaddr = fixture.descriptors.addr = fixture.strings.addr;
        fixture.constants.vmsize = fixture.descriptors.size = fixture.strings.size;
        assert(Snapshot()[@"error"]);
        Reset(0); imageCount = 2; assert(Snapshot()[@"error"]);
        Reset(0); imageCount = 0; assert(Snapshot()[@"error"]);
        puts("PASS: checked VM reads, status/byte-count/range rejection, loaded-image bounds, UUID conflicts, unreadable pages and signed ASLR slides (synthetic Mach-O)");
    }
}
