#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

/// CFPlugIn factory. Name must match CFPlugInFactories in Info.plist.
void *MixyHAL_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
