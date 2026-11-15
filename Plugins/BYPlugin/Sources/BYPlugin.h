#ifndef BY_PLUGIN_H
#define BY_PLUGIN_H
#include <stdint.h>

#define BY_EXPORT __attribute__((visibility("default")))
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1 uses fixed-width C values; no Swift runtime or jailbreak dependency. */
BY_EXPORT uint32_t BYPluginABIVersion(void);
BY_EXPORT uint32_t BYPluginFeatureFlags(void);
BY_EXPORT int64_t BYPluginDownloadPartSize(int64_t base, int64_t file_size, uint32_t mode);
BY_EXPORT int32_t BYPluginPendingParts(int32_t base, uint32_t mode);
#ifdef __cplusplus
}
#endif
#endif
