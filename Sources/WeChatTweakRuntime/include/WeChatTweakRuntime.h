#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool WTShouldPreserveRecall(const char *notice);
const char *WTRuntimeProfile(void);
uint64_t WTMessageServerIDFromDisplay(const void *display);

typedef struct WTRecallStore WTRecallStore;
WTRecallStore *WTRecallStoreCreate(const char *path);
void WTRecallStoreDestroy(WTRecallStore *store);
bool WTRecallStoreRecord(WTRecallStore *store, const char *account, const char *session, uint64_t messageID);
bool WTRecallStoreContains(WTRecallStore *store, const char *account, const char *session, uint64_t messageID);
bool WTRecallStoreIsPersistent(WTRecallStore *store, const char *account, const char *session, uint64_t messageID);

#ifdef __cplusplus
}
#endif
