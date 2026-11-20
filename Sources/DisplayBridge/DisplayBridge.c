// Apple silicon DDC transport adapted from MonitorControl (MIT).
// Copyright © MonitorControl, @JoniVR, @the0neyouseek, @waydabber and contributors.
#include "DisplayBridge.h"
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <unistd.h>

typedef CFTypeRef (*CreateAV)(CFAllocatorRef, io_service_t);
typedef IOReturn (*TransferAV)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef CFDictionaryRef (*DisplayInfo)(CGDirectDisplayID);

static struct {
    CreateAV create;
    TransferAV read, write;
    DisplayInfo info;
    int (*getBrightness)(CGDirectDisplayID, float *);
    int (*setBrightness)(CGDirectDisplayID, float);
} api;

static void loadAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        api.create = (CreateAV)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
        api.read = (TransferAV)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
        api.write = (TransferAV)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
        void *core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
        void *display = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
        if (display) {
            api.getBrightness = dlsym(display, "DisplayServicesGetBrightness");
            api.setBrightness = dlsym(display, "DisplayServicesSetBrightness");
        }
        if (core) api.info = (DisplayInfo)dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary");
    });
}

CFDictionaryRef MCCopyDisplayInfo(CGDirectDisplayID display) {
    loadAPI();
    return api.info ? api.info(display) : NULL;
}

bool MCGetNativeBrightness(CGDirectDisplayID display, float *brightness) {
    loadAPI();
    return api.getBrightness && api.setBrightness && api.getBrightness(display, brightness) == 0
        && *brightness >= 0.f && *brightness <= 1.f;
}

bool MCSetNativeBrightness(CGDirectDisplayID display, float brightness) {
    loadAPI();
    return brightness >= 0.f && brightness <= 1.f && api.setBrightness && api.setBrightness(display, brightness) == 0;
}

struct MCChannel {
    CFTypeRef service;
};

MCChannel *MCOpenARMChannel(io_service_t entry) {
    loadAPI();
    if (!api.create || !api.read || !api.write) return NULL;
    MCChannel *channel = calloc(1, sizeof(*channel));
    if (!channel) return NULL;
    channel->service = api.create(kCFAllocatorDefault, entry);
    if (!channel->service) { free(channel); return NULL; }
    return channel;
}

void MCCloseChannel(MCChannel *channel) {
    CFRelease(channel->service);
    free(channel);
}

bool MCReadFeature(MCChannel *channel, uint8_t feature, uint8_t *reply) {
    // The transport supplies the data address separately.
    uint8_t query[] = {0x82, 0x01, feature, 0x6e ^ 0x82 ^ 0x01 ^ feature};
    // Some panels return an old or empty response unless the Get VCP
    // request is repeated. This sequence matches MonitorControl's driver.
    for (int attempt = 0; attempt < 2; ++attempt) {
        usleep(10000);
        if (api.write(channel->service, 0x37, 0x51, query, sizeof(query)) != KERN_SUCCESS) return false;
    }
    usleep(50000);
    return api.read(channel->service, 0x37, 0, reply, 11) == KERN_SUCCESS;
}

bool MCWriteFeature(MCChannel *channel, uint8_t feature, uint16_t value) {
    uint8_t high = value >> 8, low = value & 0xff;
    // The checksum covers the 0x51 data address, which is passed separately.
    uint8_t packet[] = {0x84, 0x03, feature, high, low, 0x6e ^ 0x51 ^ 0x84 ^ 0x03 ^ feature ^ high ^ low};
    return api.write(channel->service, 0x37, 0x51, packet, sizeof(packet)) == KERN_SUCCESS;
}
