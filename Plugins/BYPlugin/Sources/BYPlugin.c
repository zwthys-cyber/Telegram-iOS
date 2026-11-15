#include "BYPlugin.h"

#ifndef BY_PLUGIN_ABI
#define BY_PLUGIN_ABI 1
#endif
#ifndef BY_PLUGIN_FEATURES
#define BY_PLUGIN_FEATURES 511
#endif

enum { BY_DOWNLOAD_BOOST = 8 };
enum { BY_MEDIUM = 1, BY_MAXIMUM = 2 };

uint32_t BYPluginABIVersion(void) { return BY_PLUGIN_ABI; }
uint32_t BYPluginFeatureFlags(void) { return BY_PLUGIN_FEATURES; }

int64_t BYPluginDownloadPartSize(int64_t base, int64_t file_size, uint32_t mode) {
    if (!(BYPluginFeatureFlags() & BY_DOWNLOAD_BOOST) || file_size < 0 ||
        file_size <= 1024 * 1024) {
        return base;
    }
    int64_t proposed = mode == BY_MEDIUM ? 512 * 1024 :
                       mode == BY_MAXIMUM ? 1024 * 1024 : base;
    return proposed > base ? proposed : base;
}

int32_t BYPluginPendingParts(int32_t base, uint32_t mode) {
    if (!(BYPluginFeatureFlags() & BY_DOWNLOAD_BOOST)) {
        return base;
    }
    int32_t proposed = mode == BY_MEDIUM ? 8 : mode == BY_MAXIMUM ? 12 : base;
    return proposed > base ? proposed : base;
}
