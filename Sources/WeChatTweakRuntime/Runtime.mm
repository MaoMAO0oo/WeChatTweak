#import <Foundation/Foundation.h>
#include "WeChatTweakRuntime.h"
#include <dispatch/dispatch.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <os/log.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#if defined(__arm64__)
extern "C" {
void *WTOriginalReplace = nullptr;
void *WTOriginalBind = nullptr;
void *WTOriginalDestroy = nullptr;
void WTReplaceEntry();
void WTBindEntry();
void WTDestroyEntry();
}

namespace {
// All offsets refer to the immutable 270353 arm64 image, UUID below.
constexpr uint8_t profileUUID[16] = {0x8c,0xb5,0xf2,0x9e,0xfc,0x1d,0x3d,0x47,0x89,0x7a,0x27,0x2a,0x46,0x51,0xe9,0x16};
uintptr_t imageBase = 0;
WTRecallStore *recallStore = nullptr;
std::unordered_map<void *, void *> *messageViews = nullptr;
std::array<void *,3> trampolines{};
size_t trampolineSize = 0;

template<typename Function> Function native(uintptr_t offset) {
    return reinterpret_cast<Function>(imageBase + offset);
}

void *checkedCast(void *object, uintptr_t sourceType, uintptr_t destinationType) {
    using Cast = void *(*)(void *, const void *, const void *, intptr_t);
    return native<Cast>(0x72b0e58)(object, reinterpret_cast<void *>(imageBase + sourceType),
                               reinterpret_cast<void *>(imageBase + destinationType), 0);
}

std::string currentAccount() {
    void *service = native<void *(*)()>(0x47990b4)();
    if (service == nullptr) return {};
    auto table = *reinterpret_cast<uintptr_t **>(service);
    auto username = reinterpret_cast<const std::string *(*)(void *)>(table[5])(service);
    return *username;
}

// Qt 5.15.14 QStringLiteral ABI: static QArrayData followed by UTF-16.
template<size_t N> struct alignas(8) MarkerLiteral {
    int32_t ref = -1;
    int32_t size = static_cast<int32_t>(N-1);
    uint32_t allocation = 0;
    uint32_t padding = 0;
    int64_t offset = 24;
    char16_t text[N]{};
    constexpr MarkerLiteral(const char16_t (&value)[N]) {
        for (size_t i=0;i<N;++i) text[i] = value[i];
    }
};
template<size_t N> MarkerLiteral(const char16_t (&)[N]) -> MarkerLiteral<N>;
constexpr MarkerLiteral markerLiteral(u"对方尝试撤回此消息");
constexpr MarkerLiteral transientMarkerLiteral(u"对方尝试撤回此消息（无法持久化）");
constexpr int markerTextIndent = 60;
static_assert(offsetof(decltype(markerLiteral),text) == 24);

void setVisible(void *widget, bool visible) {
    auto table = *reinterpret_cast<uintptr_t **>(widget);
    reinterpret_cast<void (*)(void *,bool)>(table[0x68 / 8])(widget,visible);
}

void refreshView(void *view) {
    auto found = messageViews->find(view);
    if (found == messageViews->end()) return;
    void *rawModel = *reinterpret_cast<void **>(static_cast<uint8_t *>(view) + 0x230);
    void *model = rawModel == nullptr ? nullptr : checkedCast(rawModel,0x9d7b498,0x9d7bee0);
    bool marked = false;
    bool persistent = false;
    if (model != nullptr) {
        auto data = static_cast<uint8_t *>(model) + 0x120;
        auto &session = *reinterpret_cast<std::string *>(data + 0x58);
        const uint64_t messageID = WTMessageServerIDFromDisplay(data);
        const std::string account = currentAccount();
        marked = !account.empty() && WTRecallStoreContains(recallStore,account.c_str(),session.c_str(),messageID);
        if (marked) persistent = WTRecallStoreIsPersistent(recallStore,account.c_str(),session.c_str(),messageID);
    }
    void *label = found->second;
    if (marked && label == nullptr) {
        // The common message builder puts the bubble in its own QHBoxLayout.
        // Insert beside that bubble, before any trailing status or stretch items.
        void *bubble = native<void *(*)(void *)>(0x5a45c0)(view);
        if (bubble == nullptr) return;
        void *row = native<void *(*)(void *)>(0x136d91c)(bubble);
        if (row == nullptr) return;
        void *layout = native<void *(*)(void *)>(0x6b747a0)(row);
        if (layout == nullptr) return;
        layout = checkedCast(layout,0xa106190,0xa105d70);
        if (layout == nullptr) return;
        const int bubbleIndex = native<int (*)(void *,void *)>(0x6b5d200)(layout,bubble);
        if (bubbleIndex < 0) return;
        label = native<void *(*)(size_t)>(0x72b0d5c)(48);
        native<void *(*)(void *,void *,uint32_t)>(0x6c276ac)(label,row,0);
        // Qt WriteProperty=2; QLabel local property 7 is indent.
        int indent = markerTextIndent;
        void *arguments[] = {&indent};
        native<void (*)(void *,int,int,void **)>(0x6c2ab3c)(label,2,7,arguments);
        native<void (*)(void *,int,void *,int,uint32_t)>(0x6b539e4)(layout,bubbleIndex+1,label,0,0);
        auto current = messageViews->find(view);
        if (current == messageViews->end()) return;
        current->second = label;
    }
    if (label != nullptr) {
        if (marked) {
            const void *data = persistent ? static_cast<const void *>(&markerLiteral)
                                          : static_cast<const void *>(&transientMarkerLiteral);
            native<void (*)(void *,const void *)>(0x6c277b0)(label,&data);
        }
        setVisible(label,marked);
    }
}

void refreshAllViews() {
    std::vector<void *> views;
    for (const auto &entry : *messageViews) views.push_back(entry.first);
    for (void *view : views) refreshView(view);
}

[[noreturn]] void failStartup(const char *reason) {
    os_log_fault(OS_LOG_DEFAULT,"WeChatTweak runtime setup failed: %{public}s",reason);
    std::abort();
}

struct Hook {
    uintptr_t entry;
    uintptr_t slot;
    std::array<uint32_t,3> saved;
    void *replacement;
    void **original;
};

void makeTrampoline(const Hook &hook, size_t index) {
    void *region = mmap(nullptr,trampolineSize,PROT_READ|PROT_WRITE|PROT_EXEC,
                        MAP_PRIVATE|MAP_ANON|MAP_JIT,-1,0);
    if (region == MAP_FAILED) failStartup("MAP_JIT allocation failed");
    uint8_t bytes[32]{};
    std::memcpy(bytes,hook.saved.data(),12);
    const uint32_t jump[3] = {0x58000071,0xd61f0220,0xd503201f};
    std::memcpy(bytes+12,jump,sizeof(jump));
    const uintptr_t continuation = imageBase + hook.entry + 12;
    std::memcpy(bytes+24,&continuation,sizeof(continuation));
    pthread_jit_write_protect_np(0);
    std::memcpy(region,bytes,sizeof(bytes));
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(region,sizeof(bytes));
    trampolines[index] = region;
    *hook.original = region;
}

void install(const mach_header *header, intptr_t slide) {
    if (imageBase != 0 || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return;
    auto h = reinterpret_cast<const mach_header_64 *>(header);
    auto command = reinterpret_cast<const load_command *>(h+1);
    bool matched = false;
    for (uint32_t i=0;i<h->ncmds;++i) {
        if (command->cmd == LC_UUID) {
            auto uuid = reinterpret_cast<const uuid_command *>(command);
            matched = std::memcmp(uuid->uuid,profileUUID,sizeof(profileUUID)) == 0;
        }
        command = reinterpret_cast<const load_command *>(reinterpret_cast<const uint8_t *>(command)+command->cmdsize);
    }
    if (!matched) return;
    @autoreleasepool {
        imageBase = static_cast<uintptr_t>(slide);
        messageViews = new std::unordered_map<void *, void *>;
        trampolineSize = static_cast<size_t>(getpagesize());
        const std::array<Hook,3> hooks = {{
            {0x364ce68,0xa68bfc0,{0xa9bb6ffc,0xa9015ff8,0xa90257f6},reinterpret_cast<void *>(&WTReplaceEntry),&WTOriginalReplace},
            {0x5cf83c,0xa68bfc8,{0xd10543ff,0xa9116ffc,0xa91257f6},reinterpret_cast<void *>(&WTBindEntry),&WTOriginalBind},
            {0x5cf53c,0xa68bfd0,{0xa9be4ff4,0xa9017bfd,0x910043fd},reinterpret_cast<void *>(&WTDestroyEntry),&WTOriginalDestroy}
        }};
        for (size_t i=0;i<hooks.size();++i) {
            const auto &hook = hooks[i];
            const uint32_t *entry = reinterpret_cast<const uint32_t *>(imageBase+hook.entry);
            const int64_t pages = static_cast<int64_t>((hook.slot & ~uintptr_t(4095))-(hook.entry & ~uintptr_t(4095))) >> 12;
            const uint32_t immediate = static_cast<uint32_t>(pages) & 0x1fffff;
            const uint32_t expected[3] = {
                0x90000010u|((immediate&3)<<29)|(((immediate>>2)&0x7ffff)<<5),
                0xf9400210u|static_cast<uint32_t>(((hook.slot&4095)/8)<<10),0xd61f0200u
            };
            if (std::memcmp(entry,expected,sizeof(expected)) != 0) failStartup("Entry patch does not match profile");
            if (*reinterpret_cast<uintptr_t *>(imageBase+hook.slot) != 0) failStartup("Hook slot is occupied");
            makeTrampoline(hook,i);
        }
        for (const auto &hook : hooks) {
            __atomic_store_n(reinterpret_cast<uintptr_t *>(imageBase+hook.slot),reinterpret_cast<uintptr_t>(*hook.original),__ATOMIC_RELEASE);
        }
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/WeChatTweak/recalled-messages.json"];
        recallStore = WTRecallStoreCreate(path.fileSystemRepresentation);
        for (const auto &hook : hooks) {
            __atomic_store_n(reinterpret_cast<uintptr_t *>(imageBase+hook.slot),reinterpret_cast<uintptr_t>(hook.replacement),__ATOMIC_RELEASE);
        }
    }
}
}

extern "C" bool WTHandleRecall(void *, void *message, void *result) {
    void *extension = *reinterpret_cast<void **>(static_cast<uint8_t *>(message)+0x220);
    if (extension == nullptr) return false;
    auto parsed = static_cast<uint8_t *>(checkedCast(extension,0xa000e98,0xa005d78));
    if (parsed == nullptr) return false;
    auto &notice = *reinterpret_cast<std::string *>(parsed+0x1d0);
    const uint64_t messageID = *reinterpret_cast<uint64_t *>(parsed+0x1c8);
    if (messageID == 0 || !WTShouldPreserveRecall(notice.c_str())) return false;
    const auto &session = *reinterpret_cast<std::string *>(parsed+0x1e8);
    const std::string account = currentAccount();
    if (account.empty() || session.empty()) return false;
    @autoreleasepool {
        if (!WTRecallStoreRecord(recallStore,account.c_str(),session.c_str(),messageID)) {
            os_log_error(OS_LOG_DEFAULT,"WeChatTweak could not persist a recall marker");
        }
        // Native empty-result construction: leave the original message untouched.
        auto bytes = static_cast<uint8_t *>(result);
        bytes[0] = 0;
        bytes[0x278] = 0;
        dispatch_async(dispatch_get_main_queue(),^{ refreshAllViews(); });
    }
    return true;
}

extern "C" void WTDidBindView(void *view) {
    if (!pthread_main_np()) return;
    messageViews->try_emplace(view,nullptr);
    dispatch_async(dispatch_get_main_queue(),^{ refreshView(view); });
}

extern "C" void WTWillDestroyView(void *view) {
    if (pthread_main_np()) messageViews->erase(view);
}

__attribute__((constructor)) static void startRuntime() {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.tencent.xinWeChat"]) return;
        _dyld_register_func_for_add_image(&install);
    }
}

__attribute__((destructor)) static void stopRuntime() {
    if (recallStore != nullptr) WTRecallStoreDestroy(recallStore);
    delete messageViews;
    for (void *region : trampolines) if (region != nullptr) munmap(region,trampolineSize);
}
#endif
