#include <array>
#include <cstdint>
#include <cstdio>
#include <stdexcept>

struct Result {
    uint64_t first;
    std::array<uint8_t,0x270> payload;
    uint64_t last;
};
static_assert(sizeof(Result) == 0x280);
enum class Mode { Native, Preserve, BindThrows, BindCallbackThrows, RecallCallbackThrows, DestroyCallbackThrows };
static Mode mode;
static int originalCalls;

extern "C" {
void *WTOriginalReplace;
void *WTOriginalBind;
void *WTOriginalDestroy;
Result WTReplaceEntry(void *,void *);
void WTBindEntry(void *,void *);
void WTDestroyEntry(void *);

bool WTHandleRecall(void *,void *,void *result) {
    if (mode == Mode::RecallCallbackThrows) throw std::runtime_error("recall callback");
    if (mode != Mode::Preserve) return false;
    auto out = static_cast<Result *>(result);
    out->first = 0x12345678;
    out->last = 0xabcdef01;
    return true;
}
void WTDidBindView(void *) {
    if (mode == Mode::BindCallbackThrows) throw std::runtime_error("bind callback");
}
void WTWillDestroyView(void *) {
    if (mode == Mode::DestroyCallbackThrows) throw std::runtime_error("destroy callback");
}
}

__attribute__((noinline)) static Result originalReplace(void *service,void *message) {
    ++originalCalls;
    Result result{};
    result.first = reinterpret_cast<uintptr_t>(service);
    result.last = reinterpret_cast<uintptr_t>(message);
    return result;
}
__attribute__((noinline)) static void originalBind(void *,void *) {
    if (mode == Mode::BindThrows) throw std::runtime_error("native bind");
}
static void originalDestroy(void *) {}

template<typename Call> __attribute__((noinline)) static bool catches(Call call) {
    try { call(); } catch (const std::runtime_error &) { return true; }
    return false;
}

int main() {
    WTOriginalReplace = reinterpret_cast<void *>(&originalReplace);
    WTOriginalBind = reinterpret_cast<void *>(&originalBind);
    WTOriginalDestroy = reinterpret_cast<void *>(&originalDestroy);
    mode = Mode::Native;
    Result native = WTReplaceEntry(reinterpret_cast<void *>(0x1234),reinterpret_cast<void *>(0x5678));
    if (native.first != 0x1234 || native.last != 0x5678 || originalCalls != 1) return 1;
    mode = Mode::Preserve;
    Result preserved = WTReplaceEntry(nullptr,nullptr);
    if (preserved.first != 0x12345678 || preserved.last != 0xabcdef01 || originalCalls != 1) return 2;
    mode = Mode::BindThrows;
    if (!catches([] { originalBind(nullptr,nullptr); })) return 3;
    if (!catches([] { WTBindEntry(nullptr,nullptr); })) return 4;
    mode = Mode::BindCallbackThrows;
    if (!catches([] { WTBindEntry(nullptr,nullptr); })) return 5;
    mode = Mode::RecallCallbackThrows;
    if (!catches([] { (void)WTReplaceEntry(nullptr,nullptr); })) return 6;
    mode = Mode::DestroyCallbackThrows;
    if (!catches([] { WTDestroyEntry(nullptr); })) return 7;
    std::puts("arm64 entry ABI: SRET and exception propagation passed (7 checks)");
}
