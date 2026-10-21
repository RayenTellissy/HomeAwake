// check-agent.sh loads this into one agent run with DYLD_INSERT_LIBRARIES.
// - While $CFFIXED_USER_HOME/router exists, the dynamic store reports the router it names, or none when it is empty,
//   the way State:/Network/Global/IPv4 looks before ARP resolves a new router or after Wi-Fi drops.
// - Each posix_spawn prints "spawn <path>" to stderr, so the script counts arp and sudo runs.
// - The power source notification is registered as dev.homeawake.check.power, so the script can post one.
#include <IOKit/ps/IOPowerSources.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <limits.h>
#include <notify.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CFPropertyListRef copyValue(SCDynamicStoreRef store, CFStringRef key) {
    char path[PATH_MAX], ip[64] = "";
    snprintf(path, sizeof path, "%s/router", getenv("CFFIXED_USER_HOME"));
    FILE *file = fopen(path, "r");
    if (!file) return SCDynamicStoreCopyValue(store, key);
    fscanf(file, "%63s", ip);
    fclose(file);
    if (!ip[0]) return NULL;
    CFStringRef router = CFStringCreateWithCString(NULL, ip, kCFStringEncodingUTF8);
    CFDictionaryRef value = CFDictionaryCreate(NULL, (const void **)&kSCPropNetIPv4Router, (const void **)&router, 1,
                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(router);
    return value;
}

static int spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    fprintf(stderr, "spawn %s\n", path);
    return posix_spawn(pid, path, actions, attributes, argv, envp);
}

static uint32_t registerDispatch(const char *name, int *token, dispatch_queue_t queue, notify_handler_t handler) {
    if (strcmp(name, kIOPSNotifyPowerSource) == 0) name = "dev.homeawake.check.power";
    return notify_register_dispatch(name, token, queue, handler);
}

__attribute__((used, section("__DATA,__interpose"))) static const void *interpose[] = {
    (const void *)copyValue, (const void *)SCDynamicStoreCopyValue,
    (const void *)spawn, (const void *)posix_spawn,
    (const void *)registerDispatch, (const void *)notify_register_dispatch,
};
