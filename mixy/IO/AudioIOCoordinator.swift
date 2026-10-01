import AudioToolbox
import CoreAudio
import Foundation

public enum AudioIOError: Error, Sendable {
    case deviceNotFound(String)
    case unitCreateFailed(OSStatus)
    case unitInitializeFailed(OSStatus)
}

/// Per-strip mixer state that the I/O path and channel-strip UI share.
public struct MixerStrip: Equatable, Sendable, Identifiable {
    public var uid: String
    public var isEnabled: Bool
    /// Fader position in decibels. `linearGain` is the linear amplitude.
    public var gainDecibels: Float
    public var channelMap: [Int]
    /// When true this strip is an input source; otherwise it is an output destination.
    public var isInput: Bool
    public var isMuted: Bool
    public var isSoloed: Bool
    /// Stereo pan/balance in `[-1, 1]`. `0` leaves L/R at unity.
    public var pan: Float

    public var id: String { uid + (isInput ? "#in" : "#out") }

    public var linearGain: Float {
        AmplitudeGain.linear(fromDecibels: gainDecibels)
    }

    public init(
        uid: String,
        isEnabled: Bool,
        gainDecibels: Float,
        channelMap: [Int],
        isInput: Bool,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        pan: Float = 0
    ) {
        self.uid = uid
        self.isEnabled = isEnabled
        self.gainDecibels = gainDecibels
        self.channelMap = channelMap
        self.isInput = isInput
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.pan = min(max(pan, -1), 1)
    }
}

/// Retained per-unit context for AUHAL callbacks. The C callback calls into `handleHardwareIO`.
final class HALIOContext {
    let uid: String
    let role: HALIORole
    let channelCount: Int
    let maxFrames: Int
    var registration: InstalledIOCallback
    weak var coordinator: AudioIOCoordinator?
    var unit: AudioUnit?
    var scratch: [Float]
    /// Planar storage for AUHAL AudioUnitRender (one contiguous region, channel-major).
    var planar: UnsafeMutablePointer<Float>
    var bufferList: UnsafeMutablePointer<AudioBufferList>?

    init(uid: String, role: HALIORole, channelCount: Int, maxFrames: Int, coordinator: AudioIOCoordinator) {
        self.uid = uid
        self.role = role
        self.channelCount = max(channelCount, 1)
        self.maxFrames = max(maxFrames, 64)
        self.registration = InstalledIOCallback(
            uid: uid,
            role: AUHALCallbackBinding.roleName(role),
            propertySelector: AUHALCallbackBinding.propertySelector(for: role),
            propertyName: AUHALCallbackBinding.propertyName(for: role),
            procIsShippedAUHALCallback: false,
            setPropertySucceeded: false
        )
        self.coordinator = coordinator
        self.scratch = [Float](repeating: 0, count: self.maxFrames * self.channelCount)
        self.planar = UnsafeMutablePointer<Float>.allocate(capacity: self.channelCount * self.maxFrames)
        self.planar.initialize(repeating: 0, count: self.channelCount * self.maxFrames)
        let extra = MemoryLayout<AudioBuffer>.size * max(self.channelCount - 1, 0)
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size + extra,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    }

    deinit {
        planar.deinitialize(count: channelCount * maxFrames)
        planar.deallocate()
        if let bufferList {
            UnsafeMutableRawPointer(bufferList).deallocate()
        }
    }

    func bindBufferList(frames: Int) {
        guard let bufferList else { return }
        let framesToUse = min(frames, maxFrames)
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        abl.count = channelCount
        for index in 0..<channelCount {
            abl[index].mNumberChannels = 1
            abl[index].mDataByteSize = UInt32(framesToUse * MemoryLayout<Float>.size)
            abl[index].mData = UnsafeMutableRawPointer(planar + index * maxFrames)
        }
    }
}

/// Coordinates multiple HAL inputs into a mix and fans out to local + isolated AirPlay outputs.
public final class AudioIOCoordinator: @unchecked Sendable {
    public private(set) var isRunning = false
    public private(set) var graph = MixGraph(
        localClockDeviceUIDs: [],
        isolatedAirPlayUIDs: [],
        bufferFramesLocal: AirPlayPolicy.localBufferFrames,
        bufferFramesAirPlay: AirPlayPolicy.airPlayBufferFrames,
        extraLatencyFramesAirPlay: AirPlayPolicy.airPlayExtraLatencyFrames
    )
    public private(set) var lastCycle: IOCycleResult?
    public private(set) var installedCallbacks: [InstalledIOCallback] = []

    private let lock = NSLock()
    private var strips: [MixerStrip] = []
    private var devices: [DeviceRecord] = []
    private var inputCaptures: [String: PCMBuffer] = [:]
    private var captureGeneration: UInt64 = 0
    private var publishedGeneration: UInt64 = 0
    /// Capture generation already appended to the AirPlay ring. A remix of that
    /// same generation must not write the slice again.
    private var airPlayWrittenGeneration: UInt64?
    private var softwareLoopback = LoopbackBuffer(channelCount: 8, frameCapacity: 8192)
    private var airPlayFeeds: [String: AirPlaySafeBuffer] = [:]
    private var inputUnits: [AudioUnit] = []
    private var outputUnits: [AudioUnit] = []
    private var airPlayUnits: [AudioUnit] = []
    private var ioContexts: [HALIOContext] = []
    private var inputSources: [InputSource] = []
    private var tapSessions: [String: ProcessTapSession] = [:]
    public private(set) var lastTapError: String?

    public init() {}

    public func update(devices: [DeviceRecord], strips: [MixerStrip], inputs: [InputSource] = []) {
        lock.lock()
        self.devices = devices
        self.strips = strips
        self.inputSources = inputs
        let enabledOutputs = Set(strips.filter { $0.isEnabled && !$0.isInput }.map(\.uid))
        let previous = graph
        let result = AirPlayPolicy.applyingDeviceChange(
            previous: previous,
            devices: devices,
            enabledUIDs: enabledOutputs
        )
        graph = result.graph
        pruneAirPlayFeeds()
        lastCycle = nil
        lock.unlock()
    }

    public var currentGraph: MixGraph {
        lock.lock()
        defer { lock.unlock() }
        return graph
    }

    /// Stores a captured input buffer. The input callback publishes the cycle in the same lock.
    public func ingestCapture(uid: String, buffer: PCMBuffer) {
        lock.lock()
        storeCaptureLocked(uid: uid, buffer: buffer)
        lock.unlock()
    }

    /// Capture → ChannelMixer → local outputs. AirPlay is appended once per capture generation.
    @discardableResult
    public func processIOCycle(frameCount: Int, mixChannelCount: Int? = nil) -> IOCycleResult {
        lock.lock()
        let result = runCycleLocked(frameCount: frameCount, mixChannelCount: mixChannelCount)
        lock.unlock()
        return result
    }

    /// Reuses the cycle published for the captures still in hand. A newer capture
    /// invalidates that cycle so a local output cannot replay the previous slice.
    private func cycleForOutput(frameCount: Int) -> IOCycleResult {
        lock.lock()
        if let last = lastCycle,
           last.mixed.frameCount == frameCount,
           publishedGeneration == captureGeneration {
            lock.unlock()
            return last
        }
        let result = runCycleLocked(frameCount: frameCount, mixChannelCount: nil)
        lock.unlock()
        return result
    }

    private func storeCaptureLocked(uid: String, buffer: PCMBuffer) {
        inputCaptures[uid] = buffer
        captureGeneration &+= 1
    }

    /// Caller holds `lock`.
    private func runCycleLocked(frameCount: Int, mixChannelCount: Int?) -> IOCycleResult {
        let channels = mixChannelCount
            ?? MixIOCycle.mixChannelCount(devices: devices, strips: strips, captures: inputCaptures)
        let publishAirPlay = airPlayWrittenGeneration != captureGeneration
        let result = MixIOCycle.run(
            captures: inputCaptures,
            strips: strips,
            devices: devices,
            graph: graph,
            airPlayFeeds: &airPlayFeeds,
            frameCount: frameCount,
            mixChannelCount: channels,
            publishAirPlay: publishAirPlay
        )
        if publishAirPlay {
            airPlayWrittenGeneration = captureGeneration
        }
        lastCycle = result
        publishedGeneration = captureGeneration
        return result
    }

    /// Ingest and the mix cycle share one lock, so a local output cannot publish
    /// the same capture into the AirPlay ring a second time.
    private func publishCapture(uid: String, buffer: PCMBuffer, frameCount: Int) {
        lock.lock()
        storeCaptureLocked(uid: uid, buffer: buffer)
        _ = runCycleLocked(frameCount: frameCount, mixChannelCount: nil)
        lock.unlock()
    }

    /// Mixes currently captured input buffers through the shipped ChannelMixer.
    public func renderMix(frameCount: Int, outputChannelCount: Int) -> PCMBuffer {
        processIOCycle(frameCount: frameCount, mixChannelCount: outputChannelCount).mixed
    }

    /// Writes a known buffer into the software loopback (virtual output) and returns a matching read.
    public func loopbackRoundTrip(_ buffer: PCMBuffer) -> PCMBuffer {
        lock.lock()
        softwareLoopback.write(buffer)
        let read = softwareLoopback.read(frameCount: buffer.frameCount)
        lock.unlock()
        return read
    }

    /// Entry invoked by real AUHAL callbacks (and by tests on the same path).
    /// - input: copies interleaved frames into captures, then runs the mix cycle
    /// - localOutput: runs the cycle and writes local (non-AirPlay) frames
    /// - airPlayOutput: pulls only from AirPlaySafeBuffer — never ChannelMixer
    public func handleHardwareIO(
        role: HALIORole,
        uid: String,
        interleavedFrames: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        let count = max(frameCount, 0) * max(channelCount, 1)
        switch role {
        case .input:
            let samples = Array(UnsafeBufferPointer(start: interleavedFrames, count: count))
            publishCapture(
                uid: uid,
                buffer: PCMBuffer(samples: samples, channelCount: max(channelCount, 1)),
                frameCount: frameCount
            )
        case .localOutput:
            let result = cycleForOutput(frameCount: frameCount)
            let buffer = result.localOutputs[uid]
                ?? PCMBuffer(frameCount: frameCount, channelCount: max(channelCount, 1))
            copy(buffer, into: interleavedFrames, frameCount: frameCount, channelCount: channelCount)
        case .airPlayOutput:
            let buffer = pullAirPlay(uid: uid, frameCount: frameCount, channelCount: max(channelCount, 1))
            copy(buffer, into: interleavedFrames, frameCount: frameCount, channelCount: channelCount)
        }
    }

    public func start(beginHardwareIO: Bool = true) throws {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        installedCallbacks = []
        lastTapError = nil
        let snapshotStrips = strips
        let snapshotGraph = graph
        let snapshotDevices = devices
        let snapshotInputs = inputSources
        lock.unlock()

        var newInputs: [AudioUnit] = []
        var newOutputs: [AudioUnit] = []
        var newAirPlay: [AudioUnit] = []
        var newContexts: [HALIOContext] = []
        var newTaps: [String: ProcessTapSession] = [:]

        do {
            for strip in snapshotStrips where strip.isEnabled && strip.isInput {
                var deviceID: AudioObjectID?
                if strip.uid.hasPrefix("app:"),
                   let source = snapshotInputs.first(where: { $0.uid == strip.uid }) {
                    switch ProcessTapAdapter.activate(source: source) {
                    case .success(let session):
                        newTaps[strip.uid] = session
                        deviceID = ProcessTapAdapter.inputDeviceID(for: session)
                    case .failure(let error):
                        lastTapError = error.localizedDescription
                    }
                }
                let channels = MixIOCycle.destinationChannelCount(
                    uid: strip.uid,
                    devices: snapshotDevices,
                    fallback: sourceChannelFallback(strip, snapshotInputs),
                    role: .input
                )
                if let created = try makeHALUnit(
                    uid: strip.uid,
                    role: .input,
                    channelCount: channels,
                    bufferFrames: snapshotGraph.bufferFramesLocal,
                    captureUID: strip.uid,
                    deviceID: deviceID
                ) {
                    newInputs.append(created.unit)
                    newContexts.append(created.context)
                }
            }
            for strip in snapshotStrips where strip.isEnabled && !strip.isInput {
                if snapshotGraph.isolatedAirPlayUIDs.contains(strip.uid) {
                    let channels = MixIOCycle.destinationChannelCount(
                        uid: strip.uid,
                        devices: snapshotDevices,
                        fallback: 2,
                        role: .airPlayOutput
                    )
                    if let created = try makeHALUnit(
                        uid: strip.uid,
                        role: .airPlayOutput,
                        channelCount: channels,
                        bufferFrames: snapshotGraph.bufferFramesAirPlay
                    ) {
                        newAirPlay.append(created.unit)
                        newContexts.append(created.context)
                    }
                } else if snapshotGraph.localClockDeviceUIDs.contains(strip.uid) {
                    let channels = MixIOCycle.destinationChannelCount(
                        uid: strip.uid,
                        devices: snapshotDevices,
                        fallback: 2,
                        role: .localOutput
                    )
                    if let created = try makeHALUnit(
                        uid: strip.uid,
                        role: .localOutput,
                        channelCount: channels,
                        bufferFrames: snapshotGraph.bufferFramesLocal
                    ) {
                        newOutputs.append(created.unit)
                        newContexts.append(created.context)
                    }
                }
            }
        } catch {
            newInputs.forEach { AudioComponentInstanceDispose($0) }
            newOutputs.forEach { AudioComponentInstanceDispose($0) }
            newAirPlay.forEach { AudioComponentInstanceDispose($0) }
            newTaps.values.forEach { ProcessTapAdapter.teardown($0) }
            throw error
        }

        lock.lock()
        inputUnits = newInputs
        outputUnits = newOutputs
        airPlayUnits = newAirPlay
        ioContexts = newContexts
        tapSessions = newTaps
        installedCallbacks = newContexts.map(\.registration)
        isRunning = true
        lock.unlock()

        if beginHardwareIO {
            for unit in newInputs + newOutputs + newAirPlay {
                AudioOutputUnitStart(unit)
            }
        }
    }

    /// Contexts still retained when `AudioOutputUnitStop`/`Dispose` ran (Stop Mix must not UAF).
    public private(set) var retainedContextCountAtDispose = 0

    public func stop() {
        lock.lock()
        let units = inputUnits + outputUnits + airPlayUnits
        let contexts = ioContexts
        let taps = Array(tapSessions.values)
        inputUnits = []
        outputUnits = []
        airPlayUnits = []
        ioContexts = []
        tapSessions = [:]
        installedCallbacks = []
        isRunning = false
        retainedContextCountAtDispose = contexts.count
        lock.unlock()
        for unit in units {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
        for session in taps {
            ProcessTapAdapter.teardown(session)
        }
        // mixyAUHALCallback holds Unmanaged.passUnretained(context); keep objects alive
        // until the units can no longer invoke the I/O proc.
        withExtendedLifetime(contexts) {}
    }

    /// Pushes mixed frames into every isolated AirPlay path (never into the local clock group).
    public func feedAirPlay(mix: PCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        for uid in graph.isolatedAirPlayUIDs {
            if airPlayFeeds[uid] == nil {
                airPlayFeeds[uid] = AirPlaySafeBuffer(channelCount: max(mix.channelCount, 2))
            }
            airPlayFeeds[uid]?.write(mix)
        }
    }

    public func pullAirPlay(uid: String, frameCount: Int, channelCount: Int) -> PCMBuffer {
        lock.lock()
        defer { lock.unlock() }
        if airPlayFeeds[uid] == nil {
            airPlayFeeds[uid] = AirPlaySafeBuffer(channelCount: channelCount)
        }
        return airPlayFeeds[uid]?.read(frameCount: frameCount)
            ?? PCMBuffer(frameCount: frameCount, channelCount: channelCount)
    }

    private func pruneAirPlayFeeds() {
        let live = Set(graph.isolatedAirPlayUIDs)
        airPlayFeeds = airPlayFeeds.filter { live.contains($0.key) }
        for uid in live where airPlayFeeds[uid] == nil {
            airPlayFeeds[uid] = AirPlaySafeBuffer(channelCount: 2)
        }
    }

    private func copy(
        _ buffer: PCMBuffer,
        into destination: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        let destCount = frameCount * channelCount
        for index in 0..<destCount {
            destination[index] = 0
        }
        let srcChannels = buffer.channelCount
        let frames = min(frameCount, buffer.frameCount)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                if channel < srcChannels {
                    let src = frame * srcChannels + channel
                    if src < buffer.samples.count {
                        destination[frame * channelCount + channel] = buffer.samples[src]
                    }
                }
            }
        }
    }

    private func sourceChannelFallback(_ strip: MixerStrip, _ inputs: [InputSource]) -> Int {
        inputs.first(where: { $0.uid == strip.uid })?.inputChannelCount ?? 2
    }

    /// Opens an AUHAL unit on a known `AudioObjectID` (private tap aggregates must
    /// pass `deviceID` — they are not listed in `kAudioHardwarePropertyDevices`).
    func attachInputUnit(
        deviceID: AudioObjectID,
        captureUID: String,
        channelCount: Int,
        bufferFrames: Int,
        initialize: Bool = true
    ) throws -> HALIOContext? {
        try makeHALUnit(
            uid: captureUID,
            role: .input,
            channelCount: channelCount,
            bufferFrames: bufferFrames,
            captureUID: captureUID,
            deviceID: deviceID,
            initialize: initialize
        )?.context
    }

    private func makeHALUnit(
        uid: String,
        role: HALIORole,
        channelCount: Int,
        bufferFrames: Int,
        captureUID: String? = nil,
        deviceID knownID: AudioObjectID? = nil,
        initialize: Bool = true
    ) throws -> (unit: AudioUnit, context: HALIOContext)? {
        let deviceID: AudioObjectID
        if let knownID, knownID != kAudioObjectUnknown {
            deviceID = knownID
        } else if let lookedUp = HALDeviceEnumerator.audioObjectID(forUID: uid) {
            deviceID = lookedUp
        } else {
            return nil
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioIOError.unitCreateFailed(-1)
        }
        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw AudioIOError.unitCreateFailed(status)
        }

        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        let isInput = role == .input
        if isInput {
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableIO,
                UInt32(MemoryLayout<UInt32>.size)
            )
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disableIO,
                UInt32(MemoryLayout<UInt32>.size)
            )
        } else {
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &enableIO,
                UInt32(MemoryLayout<UInt32>.size)
            )
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &disableIO,
                UInt32(MemoryLayout<UInt32>.size)
            )
        }

        var device = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        let currentFrames: UInt32 = HALProperty.value(
            object: deviceID,
            selector: kAudioDevicePropertyBufferFrameSize
        ) ?? 0
        let range: AudioValueRange? = HALProperty.value(
            object: deviceID,
            selector: kAudioDevicePropertyBufferFrameSizeRange
        )
        let minimumFrames = Int((range?.mMinimum ?? 1).rounded(.up))
        let ceiling = role == .airPlayOutput
            ? AirPlayPolicy.airPlayBufferFrames
            : AirPlayPolicy.localBufferFrames
        var frames = UInt32(
            AirPlayPolicy.deviceBufferFrames(
                requested: bufferFrames,
                ceiling: ceiling,
                deviceCurrent: Int(currentFrames),
                deviceMinimum: max(minimumFrames, 1)
            )
        )
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &frames
        )

        let nominalRate: Float64 = HALProperty.value(
            object: deviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) ?? 0
        var asbd = AudioStreamBasicDescription(
            mSampleRate: AirPlayPolicy.streamSampleRate(deviceNominal: nominalRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(max(channelCount, 1)),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        if isInput {
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &asbd,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
        } else {
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &asbd,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
        }

        let context = HALIOContext(
            uid: captureUID ?? uid,
            role: role,
            channelCount: max(channelCount, 1),
            maxFrames: max(bufferFrames * 2, 4096),
            coordinator: self
        )
        context.unit = unit
        context.registration = AUHALCallbackBinding.install(
            on: unit,
            role: role,
            uid: uid,
            context: Unmanaged.passUnretained(context).toOpaque()
        )

        if initialize {
            status = AudioUnitInitialize(unit)
            if status != noErr {
                AudioComponentInstanceDispose(unit)
                throw AudioIOError.unitInitializeFailed(status)
            }
        }
        return (unit, context)
    }
}

/// Real AUHAL I/O proc. Input pulls via AudioUnitRender then `handleHardwareIO`;
/// outputs fill `ioData` from the shipped mix cycle (AirPlay from AirPlaySafeBuffer only).
func mixyAUHALCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<HALIOContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let coordinator = context.coordinator else { return noErr }
    let frames = Int(inNumberFrames)
    let channels = context.channelCount
    let usableFrames = min(frames, context.maxFrames)

    if context.role == .input {
        guard let unit = context.unit, let abl = context.bufferList else { return noErr }
        context.bindBufferList(frames: usableFrames)
        var flags = ioActionFlags.pointee
        let status = AudioUnitRender(unit, &flags, inTimeStamp, inBusNumber, UInt32(usableFrames), abl)
        guard status == noErr else { return status }
        interleave(abl, channels: channels, frames: usableFrames, into: &context.scratch)
        context.scratch.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            coordinator.handleHardwareIO(
                role: .input,
                uid: context.uid,
                interleavedFrames: base,
                frameCount: usableFrames,
                channelCount: channels
            )
        }
        return noErr
    }

    guard let ioData else { return noErr }
    let needed = usableFrames * channels
    if context.scratch.count < needed {
        context.scratch = [Float](repeating: 0, count: needed)
    } else {
        for index in 0..<needed { context.scratch[index] = 0 }
    }
    context.scratch.withUnsafeMutableBufferPointer { pointer in
        guard let base = pointer.baseAddress else { return }
        coordinator.handleHardwareIO(
            role: context.role,
            uid: context.uid,
            interleavedFrames: base,
            frameCount: usableFrames,
            channelCount: channels
        )
    }
    writeInterleaved(context.scratch, channels: channels, frames: usableFrames, into: ioData)
    return noErr
}

private func interleave(
    _ abl: UnsafeMutablePointer<AudioBufferList>,
    channels: Int,
    frames: Int,
    into scratch: inout [Float]
) {
    let needed = frames * channels
    if scratch.count < needed {
        scratch = [Float](repeating: 0, count: needed)
    }
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    if buffers.count == 1, Int(buffers[0].mNumberChannels) == channels, let data = buffers[0].mData {
        let src = data.assumingMemoryBound(to: Float.self)
        for index in 0..<needed {
            scratch[index] = src[index]
        }
        return
    }
    for channel in 0..<min(channels, buffers.count) {
        guard let data = buffers[channel].mData else { continue }
        let src = data.assumingMemoryBound(to: Float.self)
        let available = Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size
        for frame in 0..<min(frames, available) {
            scratch[frame * channels + channel] = src[frame]
        }
    }
}

private func writeInterleaved(
    _ scratch: [Float],
    channels: Int,
    frames: Int,
    into abl: UnsafeMutablePointer<AudioBufferList>
) {
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    if buffers.count == 1, Int(buffers[0].mNumberChannels) >= channels, let data = buffers[0].mData {
        let dest = data.assumingMemoryBound(to: Float.self)
        let count = min(frames * channels, scratch.count)
        for index in 0..<count {
            dest[index] = scratch[index]
        }
        return
    }
    for channel in 0..<min(channels, buffers.count) {
        guard let data = buffers[channel].mData else { continue }
        let dest = data.assumingMemoryBound(to: Float.self)
        let available = Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size
        for frame in 0..<min(frames, available) {
            let src = frame * channels + channel
            dest[frame] = src < scratch.count ? scratch[src] : 0
        }
    }
}
