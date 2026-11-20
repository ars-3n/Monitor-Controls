#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct MCChannel MCChannel;

CFDictionaryRef _Nullable MCCopyDisplayInfo(CGDirectDisplayID display) CF_RETURNS_RETAINED;
bool MCGetNativeBrightness(CGDirectDisplayID display, float * _Nonnull brightness);
bool MCSetNativeBrightness(CGDirectDisplayID display, float brightness);
MCChannel * _Nullable MCOpenARMChannel(io_service_t registryEntry);
void MCCloseChannel(MCChannel * _Nonnull channel);
bool MCReadFeature(MCChannel * _Nonnull channel, uint8_t feature, uint8_t * _Nonnull reply);
bool MCWriteFeature(MCChannel * _Nonnull channel, uint8_t feature, uint16_t value);
