#import <Foundation/Foundation.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

int main(int argc, const char *argv[]) {
    if (argc != 2) return 64;
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSArray *profiles = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *hex = nil;
        for (NSDictionary *profile in profiles) {
            if (![profile[@"version"] isEqual:@"270353"]) continue;
            for (NSDictionary *target in profile[@"targets"]) {
                if (![target[@"identifier"] isEqual:@"screenshot-capture"]) continue;
                for (NSDictionary *entry in target[@"entries"]) {
                    if ([entry[@"arch"] isEqual:@"arm64"]) hex = entry[@"asm"];
                }
            }
        }
        if (hex.length != 16) {
            std::fputs("capture policy ABI: missing 270353 arm64 acknowledgement patch\n",stderr);
            return 1;
        }
        const size_t size = static_cast<size_t>(getpagesize());
        void *code = mmap(nullptr,size,PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANON|MAP_JIT,-1,0);
        if (code == MAP_FAILED) return 2;
        const char *source = hex.UTF8String;
        pthread_jit_write_protect_np(0);
        for (size_t i=0;i<8;++i) {
            const char pair[] = {source[i*2],source[i*2+1],0};
            static_cast<uint8_t *>(code)[i] = static_cast<uint8_t>(std::strtoul(pair,nullptr,16));
        }
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(code,8);
        auto acknowledge = reinterpret_cast<uint32_t (*)(const void *,const void *)>(code);
        const bool valid = acknowledge(nullptr,nullptr) == 1 &&
            acknowledge(reinterpret_cast<void *>(0x1234),reinterpret_cast<void *>(0x5678)) == 1;
        munmap(code,size);
        if (!valid) return 3;
        std::puts("capture policy ABI: native success without reading request pointers passed (2 checks)");
    }
}
