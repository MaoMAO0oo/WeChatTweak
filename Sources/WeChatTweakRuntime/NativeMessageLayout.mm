#include "WeChatTweakRuntime.h"
#include <cstring>

uint64_t WTMessageServerIDFromDisplay(const void *display) {
    uint64_t messageID;
    // Native Message+0xF8 is copied to display+0x90 in build 270353.
    std::memcpy(&messageID,static_cast<const uint8_t *>(display)+0x90,sizeof(messageID));
    return messageID;
}
