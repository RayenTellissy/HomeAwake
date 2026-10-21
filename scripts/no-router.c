// Loaded into the agent with DYLD_INSERT_LIBRARIES. While $CFFIXED_USER_HOME/no-router exists, every dynamic store
// read finds nothing, the way State:/Network/Global/IPv4 disappears when Wi-Fi drops.
#include <SystemConfiguration/SystemConfiguration.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static CFPropertyListRef copyValue(SCDynamicStoreRef store, CFStringRef key) {
    char flag[PATH_MAX];
    snprintf(flag, sizeof flag, "%s/no-router", getenv("CFFIXED_USER_HOME"));
    return access(flag, F_OK) == 0 ? NULL : SCDynamicStoreCopyValue(store, key);
}

__attribute__((used, section("__DATA,__interpose")))
static const void *interpose[] = {(const void *)copyValue, (const void *)SCDynamicStoreCopyValue};
