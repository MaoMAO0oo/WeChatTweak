#import <Foundation/Foundation.h>
#include "WeChatTweakRuntime.h"
#include <mutex>
#include <string_view>

struct WTRecallStore {
    NSString *path;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *records;
    NSMutableSet<NSArray<NSString *> *> *keys;
    NSMutableSet<NSArray<NSString *> *> *unpersisted;
    std::mutex lock;
};

const char *WTRuntimeProfile() {
    return "WeChatTweakRuntime:270353:8CB5F29E-FC1D-3D47-897A-272A4651E916";
}

bool WTShouldPreserveRecall(const char *notice) {
    if (notice == nullptr) return false;
    const std::string_view value(notice);
    for (const auto prefix : {"你撤回", "你收回", "You recalled "}) {
        if (value.substr(0, std::char_traits<char>::length(prefix)) == prefix) return false;
    }
    return value.find("撤回") != std::string_view::npos ||
           value.find("收回") != std::string_view::npos ||
           value.find(" recalled a message") != std::string_view::npos;
}

static NSArray<NSString *> *recordKey(const char *account, const char *session, uint64_t messageID) {
    NSString *owner = [NSString stringWithUTF8String:account];
    NSString *chat = [NSString stringWithUTF8String:session];
    return @[owner, chat, [NSString stringWithFormat:@"%llu", (unsigned long long)messageID]];
}

static bool save(WTRecallStore *store) {
    if (store->path == nil) return false;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"records": store->records}
                                                  options:NSJSONWritingSortedKeys error:&error];
    return data != nil && [data writeToFile:store->path options:NSDataWritingAtomic error:&error];
}

WTRecallStore *WTRecallStoreCreate(const char *path) {
    @autoreleasepool {
        WTRecallStore *store = new WTRecallStore;
        store->path = [NSString stringWithUTF8String:path];
        store->records = [NSMutableArray array];
        store->keys = [NSMutableSet set];
        store->unpersisted = [NSMutableSet set];
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:store->path options:0 error:&error];
        if (data != nil) {
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (![root isKindOfClass:[NSDictionary class]] ||
                ![root[@"version"] isEqual:@1] || ![root[@"records"] isKindOfClass:[NSArray class]]) {
                store->path = nil;
                return store;
            }
            for (id record in root[@"records"]) {
                if (![record isKindOfClass:[NSDictionary class]] ||
                    ![record[@"account"] isKindOfClass:[NSString class]] ||
                    ![record[@"session"] isKindOfClass:[NSString class]] ||
                    ![record[@"id"] isKindOfClass:[NSString class]]) {
                    store->path = nil;
                    return store;
                }
            }
            for (NSDictionary *record in root[@"records"]) {
                NSArray<NSString *> *key = @[record[@"account"], record[@"session"], record[@"id"]];
                if (![store->keys containsObject:key]) {
                    [store->keys addObject:key];
                    [store->records addObject:record];
                }
            }
        } else if (error.code != NSFileReadNoSuchFileError) {
            store->path = nil;
            return store;
        }
        if (![[NSFileManager defaultManager] createDirectoryAtPath:[store->path stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:&error] || !save(store)) {
            store->path = nil;
        }
        return store;
    }
}

void WTRecallStoreDestroy(WTRecallStore *store) { delete store; }

bool WTRecallStoreRecord(WTRecallStore *store, const char *account, const char *session, uint64_t messageID) {
    @autoreleasepool {
        std::lock_guard<std::mutex> guard(store->lock);
        NSArray<NSString *> *key = recordKey(account, session, messageID);
        if (![store->keys containsObject:key]) {
            [store->keys addObject:key];
            [store->records addObject:@{@"account": key[0], @"session": key[1], @"id": key[2]}];
            [store->unpersisted addObject:key];
        }
        if (store->unpersisted.count == 0) return true;
        if (!save(store)) return false;
        [store->unpersisted removeAllObjects];
        return true;
    }
}

bool WTRecallStoreContains(WTRecallStore *store, const char *account, const char *session, uint64_t messageID) {
    @autoreleasepool {
        std::lock_guard<std::mutex> guard(store->lock);
        return [store->keys containsObject:recordKey(account, session, messageID)];
    }
}

bool WTRecallStoreIsPersistent(WTRecallStore *store, const char *account, const char *session, uint64_t messageID) {
    @autoreleasepool {
        std::lock_guard<std::mutex> guard(store->lock);
        NSArray<NSString *> *key = recordKey(account,session,messageID);
        return [store->keys containsObject:key] && ![store->unpersisted containsObject:key];
    }
}
