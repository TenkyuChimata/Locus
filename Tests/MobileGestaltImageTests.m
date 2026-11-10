// SPDX-License-Identifier: GPL-3.0-only
// Synthetic loaded Mach-O; actual checked Mach VM reads in this process only.
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <assert.h>
#import <string.h>
static uint32_t TestCount(void);
static const char *TestName(uint32_t);
static const struct mach_header *TestHeader(uint32_t);
static intptr_t TestSlide(uint32_t);
#define _dyld_image_count TestCount
#define _dyld_get_image_name TestName
#define _dyld_get_image_header TestHeader
#define _dyld_get_image_vmaddr_slide TestSlide
#import "../Locus/LowLevel/MobileGestaltImage.m"
#undef _dyld_image_count
#undef _dyld_get_image_name
#undef _dyld_get_image_header
#undef _dyld_get_image_vmaddr_slide

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
        for (int sign = -1; sign <= 1; sign++) {
            Reset(sign * 0x100000);
            NSDictionary *value = Snapshot();
            assert(!value[@"error"] && [value[@"sections"] count] == 2 && value[@"binaryUUID"]);
        }
        Reset(0); fixture.header.sizeofcmds = UINT32_MAX; assert(Snapshot()[@"error"]);
        Reset(0); fixture.header.ncmds++; assert(Snapshot()[@"error"]);
        Reset(0); fixture.uuid.cmdsize = 0; assert(Snapshot()[@"error"]);
        Reset(0); fixture.uuid.cmd = LC_LOAD_DYLIB; assert(Snapshot()[@"error"]);
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
        puts("PASS: loaded-image section/segment/command bounds, safe read failure, identity ambiguity and signed ASLR slides (synthetic Mach-O)");
    }
}
