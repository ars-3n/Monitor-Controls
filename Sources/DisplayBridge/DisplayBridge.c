// Apple silicon and Intel DDC transports adapted from MonitorControl (MIT).
// Copyright © MonitorControl, @JoniVR, @the0neyouseek, @waydabber and contributors.
#include "DisplayBridge.h"
#include <IOKit/i2c/IOI2CInterface.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <mach/mach_time.h>
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
    io_service_t framebuffer;
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

MCChannel *MCOpenIntelChannel(CGDirectDisplayID display) {
#if defined(__x86_64__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    io_service_t framebuffer = CGDisplayIOServicePort(display);
#pragma clang diagnostic pop
    IOItemCount count = 0;
    if (framebuffer && IOFBGetI2CInterfaceCount(framebuffer, &count) == KERN_SUCCESS && count) {
        if (IOObjectRetain(framebuffer) != KERN_SUCCESS) return NULL; // CG returns a borrowed port.
    } else {
        // Some Intel systems only expose the per-display framebuffer via CGS.
        typedef void (*ServiceForDisplay)(CGDirectDisplayID, io_service_t *);
        ServiceForDisplay find = (ServiceForDisplay)dlsym(RTLD_DEFAULT, "CGSServiceForDisplayNumber");
        if (!find) return NULL;
        framebuffer = IO_OBJECT_NULL;
        find(display, &framebuffer);
        if (!framebuffer) return NULL;
        if (IOFBGetI2CInterfaceCount(framebuffer, &count) != KERN_SUCCESS || !count) {
            IOObjectRelease(framebuffer);
            return NULL;
        }
    }
    MCChannel *channel = calloc(1, sizeof(*channel));
    if (!channel) { IOObjectRelease(framebuffer); return NULL; }
    channel->framebuffer = framebuffer;
    return channel;
#else
    (void)display;
    return NULL;
#endif
}

void MCCloseChannel(MCChannel *channel) {
    if (channel->service) CFRelease(channel->service);
    if (channel->framebuffer) IOObjectRelease(channel->framebuffer);
    free(channel);
}

#if defined(__x86_64__)
static bool intelExchange(io_service_t framebuffer, uint8_t *packet, uint32_t count, uint8_t *reply) {
    IOItemCount buses = 0;
    if (IOFBGetI2CInterfaceCount(framebuffer, &buses) != KERN_SUCCESS) return false;
    for (IOOptionBits bus = 0; bus < buses; ++bus) {
        io_service_t interface = IO_OBJECT_NULL;
        if (IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) != KERN_SUCCESS) continue;
        CFNumberRef types = IORegistryEntryCreateCFProperty(interface, CFSTR(kIOI2CTransactionTypesKey), kCFAllocatorDefault, 0);
        uint32_t mask = 0;
        if (types) {
            if (CFGetTypeID(types) == CFNumberGetTypeID()) CFNumberGetValue(types, kCFNumberSInt32Type, &mask);
            CFRelease(types);
        }
        IOI2CConnectRef connection = NULL;
        IOReturn status = IOI2CInterfaceOpen(interface, 0, &connection);
        IOObjectRelease(interface);
        if (status != KERN_SUCCESS) continue;
        IOI2CRequest request = {0};
        request.sendAddress = 0x6e;
        request.sendTransactionType = kIOI2CSimpleTransactionType;
        request.sendBuffer = (vm_address_t)packet;
        request.sendBytes = count;
        if (reply) {
            request.replyAddress = 0x6f;
            request.replySubAddress = 0x51;
            request.replyTransactionType = (mask & (1u << kIOI2CDDCciReplyTransactionType)) ? kIOI2CDDCciReplyTransactionType : kIOI2CSimpleTransactionType;
            mach_timebase_info_data_t clock;
            mach_timebase_info(&clock);
            request.minReplyDelay = 50000000ull * clock.denom / clock.numer; // 50 ms in mach absolute time
            request.replyBuffer = (vm_address_t)reply;
            request.replyBytes = 11;
        }
        status = IOI2CSendRequest(connection, 0, &request);
        IOI2CInterfaceClose(connection, 0);
        if (status == KERN_SUCCESS && request.result == KERN_SUCCESS) return true;
    }
    return false;
}
#endif

bool MCReadFeature(MCChannel *channel, uint8_t feature, uint8_t *reply) {
    // The Apple silicon transport supplies the data address separately.
    if (channel->service) {
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
#if defined(__x86_64__)
    uint8_t query[] = {0x51, 0x82, 0x01, feature, 0x6e ^ 0x51 ^ 0x82 ^ 0x01 ^ feature};
    return intelExchange(channel->framebuffer, query, sizeof(query), reply);
#else
    return false;
#endif
}

bool MCWriteFeature(MCChannel *channel, uint8_t feature, uint16_t value) {
    uint8_t high = value >> 8, low = value & 0xff;
    uint8_t packet[] = {0x51, 0x84, 0x03, feature, high, low, 0x6e ^ 0x51 ^ 0x84 ^ 0x03 ^ feature ^ high ^ low};
    if (channel->service) return api.write(channel->service, 0x37, 0x51, packet + 1, sizeof(packet) - 1) == KERN_SUCCESS;
#if defined(__x86_64__)
    return intelExchange(channel->framebuffer, packet, sizeof(packet), NULL);
#else
    return false;
#endif
}
