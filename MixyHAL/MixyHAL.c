#include "MixyHAL.h"

#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Box = 2,
    kObjectID_Device = 3,
    kObjectID_Stream_Input = 4,
    kObjectID_Stream_Output = 5,
    kObjectID_Volume_Input = 6,
    kObjectID_Volume_Output = 7,
    kObjectID_Mute_Input = 8,
    kObjectID_Mute_Output = 9
};

enum {
    kChannelCount = 8,
    kRingFrames = 4096,
    kSafetyOffset = 0,
    kLatencyFrames = 0
};

static const Float64 kSampleRates[] = { 44100.0, 48000.0 };

#define kDeviceUID CFSTR("MixyHALDevice_UID")
#define kModelUID CFSTR("MixyHALDevice_ModelUID")
#define kDeviceName CFSTR("Mixy Loopback")
#define kManufacturer CFSTR("Mixy")
#define kBundleID CFSTR("com.mixy.MixyHAL")
#define kBoxName CFSTR("Mixy")
#define kBoxUID CFSTR("MixyHALBox_UID")

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;
static AudioServerPlugInHostRef gHost;
static UInt32 gRefCount = 1;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static Float64 gSampleRate = 48000.0;
static UInt32 gIORunning = 0;
static Float32 gInputVolume = 1.0f;
static Float32 gOutputVolume = 1.0f;
static UInt32 gInputMute = 0;
static UInt32 gOutputMute = 0;
static UInt32 gInputStreamActive = 1;
static UInt32 gOutputStreamActive = 1;

static Float32 gRing[kRingFrames * kChannelCount];
static UInt32 gRingWrite = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gClockSeed = 1;

static HRESULT Mixy_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG Mixy_AddRef(void *inDriver);
static ULONG Mixy_Release(void *inDriver);
static OSStatus Mixy_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Mixy_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus Mixy_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Mixy_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Mixy_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Mixy_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus Mixy_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean Mixy_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus Mixy_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus Mixy_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus Mixy_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus Mixy_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus Mixy_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Mixy_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Mixy_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus Mixy_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus Mixy_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus Mixy_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus Mixy_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static void Mixy_ComputeHostTicksPerFrame(void)
{
    mach_timebase_info_data_t theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    Float64 theHostClockFrequency = ((Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer) * 1.0e9;
    gHostTicksPerFrame = theHostClockFrequency / gSampleRate;
}

static AudioStreamBasicDescription Mixy_Format(void)
{
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = gSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = kChannelCount;
    format.mBytesPerFrame = kChannelCount * 4;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame;
    return format;
}

static AudioChannelLayoutTag Mixy_ChannelLayoutTag(void)
{
    return kAudioChannelLayoutTag_Unknown | kChannelCount;
}

void *MixyHAL_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;
    if (requestedTypeUUID == NULL) {
        return NULL;
    }
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    gInterface._reserved = NULL;
    gInterface.QueryInterface = Mixy_QueryInterface;
    gInterface.AddRef = Mixy_AddRef;
    gInterface.Release = Mixy_Release;
    gInterface.Initialize = Mixy_Initialize;
    gInterface.CreateDevice = Mixy_CreateDevice;
    gInterface.DestroyDevice = Mixy_DestroyDevice;
    gInterface.AddDeviceClient = Mixy_AddDeviceClient;
    gInterface.RemoveDeviceClient = Mixy_RemoveDeviceClient;
    gInterface.PerformDeviceConfigurationChange = Mixy_PerformDeviceConfigurationChange;
    gInterface.AbortDeviceConfigurationChange = Mixy_AbortDeviceConfigurationChange;
    gInterface.HasProperty = Mixy_HasProperty;
    gInterface.IsPropertySettable = Mixy_IsPropertySettable;
    gInterface.GetPropertyDataSize = Mixy_GetPropertyDataSize;
    gInterface.GetPropertyData = Mixy_GetPropertyData;
    gInterface.SetPropertyData = Mixy_SetPropertyData;
    gInterface.StartIO = Mixy_StartIO;
    gInterface.StopIO = Mixy_StopIO;
    gInterface.GetZeroTimeStamp = Mixy_GetZeroTimeStamp;
    gInterface.WillDoIOOperation = Mixy_WillDoIOOperation;
    gInterface.BeginIOOperation = Mixy_BeginIOOperation;
    gInterface.DoIOOperation = Mixy_DoIOOperation;
    gInterface.EndIOOperation = Mixy_EndIOOperation;
    gRefCount = 1;
    return gDriverRef;
}

static HRESULT Mixy_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) {
        return kAudioHardwareBadObjectError;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    Boolean match = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!match) {
        return E_NOINTERFACE;
    }
    Mixy_AddRef(inDriver);
    *outInterface = gDriverRef;
    return S_OK;
}

static ULONG Mixy_AddRef(void *inDriver)
{
    (void)inDriver;
    return ++gRefCount;
}

static ULONG Mixy_Release(void *inDriver)
{
    (void)inDriver;
    if (gRefCount > 0) {
        gRefCount--;
    }
    return gRefCount;
}

static OSStatus Mixy_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef || inHost == NULL) {
        return kAudioHardwareBadObjectError;
    }
    gHost = inHost;
    Mixy_ComputeHostTicksPerFrame();
    memset(gRing, 0, sizeof(gRing));
    return kAudioHardwareNoError;
}

static OSStatus Mixy_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID)
{
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Mixy_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Mixy_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus Mixy_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus Mixy_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeInfo;
    pthread_mutex_lock(&gStateMutex);
    gSampleRate = (Float64)inChangeAction;
    Mixy_ComputeHostTicksPerFrame();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Mixy_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeAction;
    (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static Boolean Mixy_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver;
    (void)inClientProcessID;
    if (inAddress == NULL) {
        return false;
    }
    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyBundleID:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    return true;
                default:
                    return false;
            }
        case kObjectID_Box:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioObjectPropertyIdentify:
                case kAudioObjectPropertySerialNumber:
                case kAudioObjectPropertyFirmwareVersion:
                case kAudioBoxPropertyBoxUID:
                case kAudioBoxPropertyTransportType:
                case kAudioBoxPropertyHasAudio:
                case kAudioBoxPropertyHasVideo:
                case kAudioBoxPropertyHasMIDI:
                case kAudioBoxPropertyIsProtected:
                case kAudioBoxPropertyAcquired:
                case kAudioBoxPropertyAcquisitionFailed:
                case kAudioBoxPropertyDeviceList:
                    return true;
                default:
                    return false;
            }
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioObjectPropertyControlList:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyPreferredChannelLayout:
                    return true;
                default:
                    return false;
            }
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
                default:
                    return false;
            }
        case kObjectID_Volume_Input:
        case kObjectID_Volume_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    return true;
                default:
                    return false;
            }
        case kObjectID_Mute_Input:
        case kObjectID_Mute_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioBooleanControlPropertyValue:
                    return true;
                default:
                    return false;
            }
        default:
            return false;
    }
}

static OSStatus Mixy_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
    (void)inDriver;
    (void)inClientProcessID;
    if (inAddress == NULL || outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Mixy_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    *outIsSettable = false;
    switch (inObjectID) {
        case kObjectID_Device:
            if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
                *outIsSettable = true;
            }
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            if (inAddress->mSelector == kAudioStreamPropertyIsActive
                || inAddress->mSelector == kAudioStreamPropertyVirtualFormat
                || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
                *outIsSettable = true;
            }
            break;
        case kObjectID_Volume_Input:
        case kObjectID_Volume_Output:
            if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue
                || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
                *outIsSettable = true;
            }
            break;
        case kObjectID_Mute_Input:
        case kObjectID_Mute_Output:
            if (inAddress->mSelector == kAudioBooleanControlPropertyValue) {
                *outIsSettable = true;
            }
            break;
        default:
            break;
    }
    return kAudioHardwareNoError;
}

static OSStatus Mixy_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Mixy_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioBooleanControlPropertyValue:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioObjectPropertyIdentify:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
            *outDataSize = sizeof(Float64);
            if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue
                || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
                *outDataSize = sizeof(Float32);
            }
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyResourceBundle:
        case kAudioBoxPropertyBoxUID:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kObjectID_PlugIn) {
                *outDataSize = sizeof(AudioObjectID) * 2;
            } else if (inObjectID == kObjectID_Box) {
                *outDataSize = sizeof(AudioObjectID);
            } else if (inObjectID == kObjectID_Device) {
                *outDataSize = sizeof(AudioObjectID) * 6;
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyDeviceList:
        case kAudioBoxPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                *outDataSize = sizeof(AudioObjectID) * 2;
            } else {
                *outDataSize = sizeof(AudioObjectID);
            }
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = sizeof(AudioObjectID) * 4;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = (UInt32)(sizeof(AudioValueRange) * (sizeof(kSampleRates) / sizeof(kSampleRates[0])));
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = sizeof(UInt32) * 2;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = (UInt32)(sizeof(AudioStreamRangedDescription) * (sizeof(kSampleRates) / sizeof(kSampleRates[0])));
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelRange:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static void Mixy_RetainOutString(void *outData, CFStringRef string)
{
    *((CFStringRef *)outData) = string;
    CFRetain(string);
}

static OSStatus Mixy_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    UInt32 needed = 0;
    OSStatus status = Mixy_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, &needed);
    if (status != kAudioHardwareNoError) {
        return status;
    }
    if (inDataSize < needed) {
        return kAudioHardwareBadPropertySizeError;
    }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    Mixy_RetainOutString(outData, kManufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    ((AudioObjectID *)outData)[0] = kObjectID_Box;
                    ((AudioObjectID *)outData)[1] = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID) * 2;
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyBundleID:
                    Mixy_RetainOutString(outData, kBundleID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyDeviceList:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL
                        && CFEqual(*((const CFStringRef *)inQualifierData), kDeviceUID)) {
                        *((AudioObjectID *)outData) = kObjectID_Device;
                    } else {
                        *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    }
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyResourceBundle:
                    Mixy_RetainOutString(outData, CFSTR(""));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
        case kObjectID_Box:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioBoxClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                    Mixy_RetainOutString(outData, kBoxName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertySerialNumber:
                case kAudioObjectPropertyFirmwareVersion:
                    Mixy_RetainOutString(outData, CFSTR(""));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    Mixy_RetainOutString(outData, kManufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyIdentify:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioBoxPropertyBoxUID:
                    Mixy_RetainOutString(outData, kBoxUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioBoxPropertyTransportType:
                    *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioBoxPropertyHasAudio:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioBoxPropertyHasVideo:
                case kAudioBoxPropertyHasMIDI:
                case kAudioBoxPropertyIsProtected:
                case kAudioBoxPropertyAcquisitionFailed:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioBoxPropertyAcquired:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioBoxPropertyDeviceList:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                    Mixy_RetainOutString(outData, kDeviceName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    Mixy_RetainOutString(outData, kManufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID owned[] = {
                        kObjectID_Stream_Input,
                        kObjectID_Stream_Output,
                        kObjectID_Volume_Input,
                        kObjectID_Volume_Output,
                        kObjectID_Mute_Input,
                        kObjectID_Mute_Output
                    };
                    memcpy(outData, owned, sizeof(owned));
                    *outDataSize = sizeof(owned);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyDeviceUID:
                    Mixy_RetainOutString(outData, kDeviceUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyModelUID:
                    Mixy_RetainOutString(outData, kModelUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyTransportType:
                    *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockDomain:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceIsAlive:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceIsRunning:
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32 *)outData) = gIORunning > 0 ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyLatency:
                    *((UInt32 *)outData) = kLatencyFrames;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                    if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                        *((AudioObjectID *)outData) = kObjectID_Stream_Input;
                        *outDataSize = sizeof(AudioObjectID);
                    } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                        *((AudioObjectID *)outData) = kObjectID_Stream_Output;
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        ((AudioObjectID *)outData)[0] = kObjectID_Stream_Input;
                        ((AudioObjectID *)outData)[1] = kObjectID_Stream_Output;
                        *outDataSize = sizeof(AudioObjectID) * 2;
                    }
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyControlList: {
                    AudioObjectID controls[] = {
                        kObjectID_Volume_Input,
                        kObjectID_Volume_Output,
                        kObjectID_Mute_Input,
                        kObjectID_Mute_Output
                    };
                    memcpy(outData, controls, sizeof(controls));
                    *outDataSize = sizeof(controls);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertySafetyOffset:
                    *((UInt32 *)outData) = kSafetyOffset;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    pthread_mutex_lock(&gStateMutex);
                    *((Float64 *)outData) = gSampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange *ranges = (AudioValueRange *)outData;
                    for (size_t i = 0; i < sizeof(kSampleRates) / sizeof(kSampleRates[0]); ++i) {
                        ranges[i].mMinimum = kSampleRates[i];
                        ranges[i].mMaximum = kSampleRates[i];
                    }
                    *outDataSize = needed;
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyIsHidden:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *((UInt32 *)outData) = kRingFrames;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    ((UInt32 *)outData)[0] = 1;
                    ((UInt32 *)outData)[1] = 2;
                    *outDataSize = sizeof(UInt32) * 2;
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelLayout: {
                    AudioChannelLayout *layout = (AudioChannelLayout *)outData;
                    memset(layout, 0, needed);
                    layout->mChannelLayoutTag = Mixy_ChannelLayoutTag();
                    *outDataSize = needed;
                    return kAudioHardwareNoError;
                }
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: {
            Boolean isInput = inObjectID == kObjectID_Stream_Input;
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyIsActive:
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32 *)outData) = isInput ? gInputStreamActive : gOutputStreamActive;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyDirection:
                    *((UInt32 *)outData) = isInput ? 1 : 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyTerminalType:
                    *((UInt32 *)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyStartingChannel:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyLatency:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    AudioStreamBasicDescription format = Mixy_Format();
                    memcpy(outData, &format, sizeof(format));
                    *outDataSize = sizeof(format);
                    return kAudioHardwareNoError;
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    AudioStreamRangedDescription *desc = (AudioStreamRangedDescription *)outData;
                    for (size_t i = 0; i < sizeof(kSampleRates) / sizeof(kSampleRates[0]); ++i) {
                        desc[i].mFormat = Mixy_Format();
                        desc[i].mFormat.mSampleRate = kSampleRates[i];
                        desc[i].mSampleRateRange.mMinimum = kSampleRates[i];
                        desc[i].mSampleRateRange.mMaximum = kSampleRates[i];
                    }
                    *outDataSize = needed;
                    return kAudioHardwareNoError;
                }
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
        }
        case kObjectID_Volume_Input:
        case kObjectID_Volume_Output: {
            Boolean isInput = inObjectID == kObjectID_Volume_Input;
            Float32 volume = isInput ? gInputVolume : gOutputVolume;
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioLevelControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioVolumeControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioControlPropertyScope:
                    *((AudioObjectPropertyScope *)outData) = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    return kAudioHardwareNoError;
                case kAudioControlPropertyElement:
                    *((AudioObjectPropertyElement *)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyScalarValue:
                    *((Float32 *)outData) = volume;
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyDecibelValue:
                    *((Float32 *)outData) = (volume <= 0.0f) ? -96.0f : (20.0f * log10f(volume));
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyDecibelRange: {
                    AudioValueRange range = { -96.0, 0.0 };
                    memcpy(outData, &range, sizeof(range));
                    *outDataSize = sizeof(range);
                    return kAudioHardwareNoError;
                }
                case kAudioLevelControlPropertyConvertScalarToDecibels: {
                    Float32 scalar = *((Float32 *)outData);
                    *((Float32 *)outData) = (scalar <= 0.0f) ? -96.0f : (20.0f * log10f(scalar));
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                }
                case kAudioLevelControlPropertyConvertDecibelsToScalar: {
                    Float32 db = *((Float32 *)outData);
                    *((Float32 *)outData) = (db <= -96.0f) ? 0.0f : powf(10.0f, db / 20.0f);
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                }
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
        }
        case kObjectID_Mute_Input:
        case kObjectID_Mute_Output: {
            Boolean isInput = inObjectID == kObjectID_Mute_Input;
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioBooleanControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioMuteControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioControlPropertyScope:
                    *((AudioObjectPropertyScope *)outData) = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    return kAudioHardwareNoError;
                case kAudioControlPropertyElement:
                    *((AudioObjectPropertyElement *)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    return kAudioHardwareNoError;
                case kAudioBooleanControlPropertyValue:
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32 *)outData) = isInput ? gInputMute : gOutputMute;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
        }
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus Mixy_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;
    (void)inClientProcessID;
    if (inAddress == NULL || inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    Boolean settable = false;
    OSStatus status = Mixy_IsPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, &settable);
    if (status != kAudioHardwareNoError) {
        return status;
    }
    if (!settable) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inObjectID) {
        case kObjectID_Device:
            if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
                if (inDataSize != sizeof(Float64)) {
                    return kAudioHardwareBadPropertySizeError;
                }
                Float64 rate = *((const Float64 *)inData);
                if (rate != 44100.0 && rate != 48000.0) {
                    return kAudioHardwareIllegalOperationError;
                }
                pthread_mutex_lock(&gStateMutex);
                Boolean changed = rate != gSampleRate;
                pthread_mutex_unlock(&gStateMutex);
                if (changed && gHost != NULL) {
                    gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)rate, NULL);
                }
                return kAudioHardwareNoError;
            }
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
                if (inDataSize != sizeof(UInt32)) {
                    return kAudioHardwareBadPropertySizeError;
                }
                pthread_mutex_lock(&gStateMutex);
                if (inObjectID == kObjectID_Stream_Input) {
                    gInputStreamActive = *((const UInt32 *)inData) ? 1 : 0;
                } else {
                    gOutputStreamActive = *((const UInt32 *)inData) ? 1 : 0;
                }
                pthread_mutex_unlock(&gStateMutex);
                return kAudioHardwareNoError;
            }
            if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat
                || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
                if (inDataSize < sizeof(AudioStreamBasicDescription)) {
                    return kAudioHardwareBadPropertySizeError;
                }
                const AudioStreamBasicDescription *format = (const AudioStreamBasicDescription *)inData;
                if (format->mSampleRate != 44100.0 && format->mSampleRate != 48000.0) {
                    return kAudioHardwareIllegalOperationError;
                }
                pthread_mutex_lock(&gStateMutex);
                Boolean changed = format->mSampleRate != gSampleRate;
                pthread_mutex_unlock(&gStateMutex);
                if (changed && gHost != NULL) {
                    gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)format->mSampleRate, NULL);
                }
                return kAudioHardwareNoError;
            }
            break;
        case kObjectID_Volume_Input:
        case kObjectID_Volume_Output: {
            Float32 scalar = 1.0f;
            if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue) {
                if (inDataSize != sizeof(Float32)) {
                    return kAudioHardwareBadPropertySizeError;
                }
                scalar = *((const Float32 *)inData);
            } else if (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
                if (inDataSize != sizeof(Float32)) {
                    return kAudioHardwareBadPropertySizeError;
                }
                Float32 db = *((const Float32 *)inData);
                scalar = (db <= -96.0f) ? 0.0f : powf(10.0f, db / 20.0f);
            }
            if (scalar < 0.0f) {
                scalar = 0.0f;
            }
            if (scalar > 1.0f) {
                scalar = 1.0f;
            }
            pthread_mutex_lock(&gStateMutex);
            if (inObjectID == kObjectID_Volume_Input) {
                gInputVolume = scalar;
            } else {
                gOutputVolume = scalar;
            }
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareNoError;
        }
        case kObjectID_Mute_Input:
        case kObjectID_Mute_Output:
            if (inDataSize != sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            pthread_mutex_lock(&gStateMutex);
            if (inObjectID == kObjectID_Mute_Input) {
                gInputMute = *((const UInt32 *)inData) ? 1 : 0;
            } else {
                gOutputMute = *((const UInt32 *)inData) ? 1 : 0;
            }
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareNoError;
        default:
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Mixy_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning == 0) {
        memset(gRing, 0, sizeof(gRing));
        gRingWrite = 0;
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        gClockSeed += 1;
    }
    gIORunning += 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Mixy_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning > 0) {
        gIORunning -= 1;
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Mixy_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    pthread_mutex_lock(&gStateMutex);
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerRingBuffer = gHostTicksPerFrame * ((Float64)kRingFrames);
    while (true) {
        Float64 next = ((Float64)gAnchorHostTime) + (((Float64)(gNumberTimeStamps + 1)) * hostTicksPerRingBuffer);
        if (((Float64)currentHostTime) < next) {
            break;
        }
        gNumberTimeStamps += 1;
    }
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)(((Float64)gNumberTimeStamps) * hostTicksPerRingBuffer);
    *outSeed = gClockSeed;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Mixy_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    if (outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    Boolean will = (inOperationID == kAudioServerPlugInIOOperationReadInput)
        || (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    *outWillDo = will;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Mixy_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus Mixy_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;
    if (ioMainBuffer == NULL) {
        return kAudioHardwareNoError;
    }
    Float32 *samples = (Float32 *)ioMainBuffer;
    UInt32 frames = inIOBufferFrameSize;
    pthread_mutex_lock(&gStateMutex);
    Float32 inGain = gInputMute ? 0.0f : gInputVolume;
    Float32 outGain = gOutputMute ? 0.0f : gOutputVolume;
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_Stream_Output) {
        for (UInt32 frame = 0; frame < frames; ++frame) {
            UInt32 dest = (gRingWrite % kRingFrames) * kChannelCount;
            for (UInt32 ch = 0; ch < kChannelCount; ++ch) {
                gRing[dest + ch] = samples[frame * kChannelCount + ch] * outGain;
            }
            gRingWrite += 1;
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObjectID_Stream_Input) {
        UInt32 readPos = (gRingWrite + kRingFrames - frames) % kRingFrames;
        for (UInt32 frame = 0; frame < frames; ++frame) {
            UInt32 src = ((readPos + frame) % kRingFrames) * kChannelCount;
            for (UInt32 ch = 0; ch < kChannelCount; ++ch) {
                samples[frame * kChannelCount + ch] = gRing[src + ch] * inGain;
            }
        }
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Mixy_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
