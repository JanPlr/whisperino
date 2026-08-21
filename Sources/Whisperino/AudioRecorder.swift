import AVFoundation
import CoreAudio
import Foundation

/// Represents an available audio input device
struct AudioInputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat
    case startupTimedOut
    case startupStillInProgress
    case streamRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "The selected microphone reported an invalid audio format"
        case .startupTimedOut:
            return "The microphone did not respond. Reconnect it or choose another input"
        case .startupStillInProgress:
            return "CoreAudio is still trying to open the microphone. Restart Whisperino if it does not recover"
        case .streamRecoveryFailed:
            return "The microphone stream went silent and could not be restarted"
        }
    }
}

class AudioRecorder {
    private enum RecoveryReason: CustomStringConvertible {
        case configurationChanged
        case unhealthy(AudioStreamHealth.Failure)
        case inputChanged

        var description: String {
            switch self {
            case .configurationChanged: return "hardware configuration changed"
            case .unhealthy(let failure): return "stream health check failed: \(failure)"
            case .inputChanged: return "input changed"
            }
        }
    }

    private var audioEngine: AVAudioEngine?
    private var audioInputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var tempURL: URL?
    private var smoothedLevel: Float = 0
    /// Guards `audioFile`/`tempURL` - the tap writes from the realtime
    /// audio thread while `rotateChunk()` swaps files from the main
    /// thread. Contention is rare (one rotation every ~40s) and the
    /// critical sections are tiny, so a plain lock is fine.
    private let fileLock = NSLock()
    /// AVAudioEngine can block indefinitely while asking CoreAudio for its
    /// input node (notably after device churn around sleep, USB, and Bluetooth
    /// changes). Keep that work off the main run loop and guard publication of
    /// a completed engine so a timed-out/cancelled start can never come alive
    /// later as a ghost recording.
    private let setupQueue = DispatchQueue(
        label: "com.whisperino.audio-recorder.setup",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lifecycleLock = NSLock()
    private var pendingStartID: UUID?
    private var activeStartID: UUID?
    private var unresolvedStartCount = 0
    private static let startupTimeout: TimeInterval = 4
    /// Bluetooth headsets can report a valid format and a running engine while
    /// supplying only zero-filled PCM. Give the new route enough time to settle
    /// and the user enough time to begin speaking, then verify the actual data.
    private static let initialHealthDelay: TimeInterval = 2.4
    /// Once healthy, the tap must continue advancing. This also covers the
    /// related Bluetooth failure where callbacks stop after the first seconds.
    private static let livenessInterval: TimeInterval = 1.5
    private static let maximumAutomaticRecoveries = 2
    private var sessionID = ""
    private var chunkIndex = 0
    private var streamHealth = AudioStreamHealth()
    private var currentChunkHasNonZeroPCM = false
    private var isRecovering = false
    private var automaticRecoveryCount = 0
    private var watchdogGeneration = 0
    private var configurationObserver: NSObjectProtocol?
    private var preferredDeviceUID: String?
    private var levelCallback: ((Float) -> Void)?
    private var recoveredChunkCallback: ((URL) -> Void)?
    private var streamFailureCallback: ((Error) -> Void)?

    /// List all available audio input devices via CoreAudio
    static func availableInputDevices() -> [AudioInputDevice] {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize) == noErr else {
            return []
        }
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize) == noErr, inputSize > 0 else {
                return nil
            }
            // AudioBufferList is variable-length. Allocating just one struct
            // lets CoreAudio overwrite the heap for devices with multiple
            // input buffers (aggregate/virtual devices are common here).
            let bufferListStorage = UnsafeMutableRawPointer.allocate(
                byteCount: Int(inputSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { bufferListStorage.deallocate() }
            let bufferListPointer = bufferListStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPointer) == noErr else {
                return nil
            }
            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { return nil }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)

            return AudioInputDevice(id: deviceID, name: name as String, uid: uid as String)
        }
    }

    /// Get the system default input device ID
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return deviceID
    }

    /// Resolve a persistent CoreAudio UID to its current transient device ID.
    /// This avoids relying on an ID cached before sleep or a USB/BT reconnect.
    private static func inputDeviceID(forUID uid: String) -> AudioDeviceID? {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidString = uid as CFString
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uidString) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propAddress,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &dataSize,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Reject dead or output-only IDs before passing them to the HAL. These
    /// checks deliberately happen on the setup worker because stale IDs can
    /// themselves make CoreAudio property queries slow.
    private static func isUsableInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &aliveAddress, 0, nil, &aliveSize, &isAlive) == noErr,
              isAlive != 0 else { return false }

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize) == noErr,
              inputSize > 0 else { return false }
        let bufferListStorage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(inputSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListStorage.deallocate() }
        let bufferListPointer = bufferListStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPointer) == noErr else {
            return false
        }
        return UnsafeMutableAudioBufferListPointer(bufferListPointer)
            .contains { $0.mNumberChannels > 0 }
    }

    /// Set the system default input device via CoreAudio
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devID
        )
        return status == noErr
    }

    private struct InputDeviceSignature: Equatable {
        let sampleRate: Double
        let channels: Int
    }

    /// Bluetooth input selection can trigger an A2DP -> hands-free profile
    /// transition. During that transition the device ID is already the system
    /// default while its sample rate/channel layout is still changing. Starting
    /// AVAudioEngine in that window is a common route to a stopped or zero-only
    /// tap, so wait for several identical hardware observations first.
    private static func waitForStableInputDevice(
        _ deviceID: AudioDeviceID,
        timeout: TimeInterval = 1.2
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: InputDeviceSignature?
        var stableObservations = 0

        while Date() < deadline {
            guard defaultInputDeviceID() == deviceID,
                  let current = inputDeviceSignature(deviceID) else {
                previous = nil
                stableObservations = 0
                Thread.sleep(forTimeInterval: 0.06)
                continue
            }

            if current == previous {
                stableObservations += 1
                if stableObservations >= 3 { return }
            } else {
                previous = current
                stableObservations = 1
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
    }

    private static func inputDeviceSignature(
        _ deviceID: AudioDeviceID
    ) -> InputDeviceSignature? {
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Double = 0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &rateAddress,
            0,
            nil,
            &rateSize,
            &sampleRate
        ) == noErr else { return nil }

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &inputAddress,
            0,
            nil,
            &inputSize
        ) == noErr, inputSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(inputSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let buffers = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(
            deviceID,
            &inputAddress,
            0,
            nil,
            &inputSize,
            buffers
        ) == noErr else { return nil }
        let channels = UnsafeMutableAudioBufferListPointer(buffers)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
        guard sampleRate > 0, channels > 0 else { return nil }
        return InputDeviceSignature(sampleRate: sampleRate, channels: channels)
    }

    private func selectPreferredInputIfNeeded(_ uid: String?) {
        guard let uid else {
            // "Automatic" can still resolve to a Bluetooth headset. Stabilize
            // the current default too; otherwise only explicitly pinned Bose /
            // AirPods users would benefit from the profile-transition fix.
            if let deviceID = Self.defaultInputDeviceID(),
               Self.isUsableInputDevice(deviceID) {
                Self.waitForStableInputDevice(deviceID)
            }
            return
        }
        guard let resolvedID = Self.inputDeviceID(forUID: uid),
              Self.isUsableInputDevice(resolvedID) else {
            print("[whisperino] preferred input \(uid) is unavailable; using system default")
            return
        }

        if Self.defaultInputDeviceID() != resolvedID {
            guard Self.setDefaultInputDevice(resolvedID) else {
                print("[whisperino] preferred input \(uid) could not be selected; using system default")
                return
            }
        }
        Self.waitForStableInputDevice(resolvedID)
    }

    /// Map raw RMS dB → 0..1 level for the meter, with a noise gate so
    /// ambient room noise doesn't make the bars dance.
    /// - dB scaling begins at -54 dB so quiet, close speech is still visible
    /// - Anything below the noise gate is forced to 0
    /// - Above the gate, a sub-linear curve boosts mid-range so normal
    ///   conversational voice produces a satisfying excursion
    private static func gatedLevel(db: Float) -> Float {
        let raw = max(0, min(1, (db + 54) / 40))
        // Keep a real noise floor (~ -50 dB), but do not discard soft speech
        // in the -49…-45 dB range as the previous gate did.
        let gate: Float = 0.10
        if raw < gate { return 0 }
        let scaled = (raw - gate) / (1 - gate)
        // A slightly stronger lift keeps quiet speech alive while the hard
        // gate above still prevents stationary room noise from animating.
        return pow(scaled, 0.60)
    }

    /// Start recording without ever putting AVAudioEngine/CoreAudio setup on
    /// the main run loop. Completion is delivered on the main queue.
    func start(
        preferredDeviceUID: String? = nil,
        levelCallback: @escaping (Float) -> Void,
        recoveredChunkCallback: @escaping (URL) -> Void,
        streamFailureCallback: @escaping (Error) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let requestID = UUID()

        lifecycleLock.lock()
        guard audioEngine == nil, pendingStartID == nil, unresolvedStartCount == 0 else {
            lifecycleLock.unlock()
            DispatchQueue.main.async { completion(.failure(AudioRecorderError.startupStillInProgress)) }
            return
        }
        pendingStartID = requestID
        unresolvedStartCount += 1
        self.preferredDeviceUID = preferredDeviceUID
        self.levelCallback = levelCallback
        self.recoveredChunkCallback = recoveredChunkCallback
        self.streamFailureCallback = streamFailureCallback
        lifecycleLock.unlock()

        let newSessionID = requestID.uuidString
        let url = chunkURL(sessionID: newSessionID, index: 0)

        setupQueue.async { [weak self] in
            guard let self else { return }
            var engine: AVAudioEngine?
            var inputNode: AVAudioInputNode?
            do {
                guard self.isStartPending(requestID) else { throw CancellationError() }
                self.selectPreferredInputIfNeeded(preferredDeviceUID)

                // Cancellation or the timeout may have won while CoreAudio was
                // resolving/validating the device. Do not enter inputNode in
                // that case; it is the call known to become uninterruptible.
                guard self.isStartPending(requestID) else { throw CancellationError() }
                let newEngine = AVAudioEngine()
                engine = newEngine
                let newInputNode = newEngine.inputNode
                inputNode = newInputNode
                let inputFormat = newInputNode.outputFormat(forBus: 0)
                guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                    throw AudioRecorderError.invalidInputFormat
                }
                print("[whisperino] opening input at \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channel(s)")

                let newAudioFile = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
                newInputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
                    self?.handleBuffer(buffer, requestID: requestID, levelCallback: levelCallback)
                }

                newEngine.prepare()
                try newEngine.start()

                if self.adoptStartedEngine(
                    newEngine,
                    inputNode: newInputNode,
                    audioFile: newAudioFile,
                    url: url,
                    sessionID: newSessionID,
                    requestID: requestID
                ) {
                    self.beginMonitoring(engine: newEngine, requestID: requestID)
                    DispatchQueue.main.async { completion(.success(())) }
                } else {
                    newInputNode.removeTap(onBus: 0)
                    newEngine.stop()
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                inputNode?.removeTap(onBus: 0)
                engine?.stop()
                try? FileManager.default.removeItem(at: url)
                if self.finishFailedStart(requestID: requestID) {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.startupTimeout) { [weak self] in
            guard let self, self.timeoutStart(requestID: requestID) else { return }
            print("[whisperino] audio startup timed out after \(Self.startupTimeout)s")
            DispatchQueue.main.async { completion(.failure(AudioRecorderError.startupTimedOut)) }
        }
    }

    private func isStartPending(_ requestID: UUID) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return pendingStartID == requestID
    }

    private func adoptStartedEngine(
        _ engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        audioFile: AVAudioFile,
        url: URL,
        sessionID: String,
        requestID: UUID
    ) -> Bool {
        lifecycleLock.lock()
        unresolvedStartCount = max(0, unresolvedStartCount - 1)
        guard pendingStartID == requestID else {
            lifecycleLock.unlock()
            return false
        }

        // Keep the lock order lifecycle -> file everywhere the two overlap.
        fileLock.lock()
        self.audioFile = audioFile
        tempURL = url
        fileLock.unlock()
        self.sessionID = sessionID
        chunkIndex = 0
        smoothedLevel = 0
        streamHealth.reset()
        currentChunkHasNonZeroPCM = false
        isRecovering = false
        automaticRecoveryCount = 0
        watchdogGeneration &+= 1
        audioEngine = engine
        audioInputNode = inputNode
        activeStartID = requestID
        pendingStartID = nil
        lifecycleLock.unlock()
        return true
    }

    private func finishFailedStart(requestID: UUID) -> Bool {
        lifecycleLock.lock()
        unresolvedStartCount = max(0, unresolvedStartCount - 1)
        let shouldComplete = pendingStartID == requestID
        if shouldComplete { pendingStartID = nil }
        lifecycleLock.unlock()
        return shouldComplete
    }

    private func timeoutStart(requestID: UUID) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard pendingStartID == requestID else { return false }
        // The blocked system call cannot safely be cancelled. Leave its
        // unresolved count in place so further hotkey presses fail fast rather
        // than accumulating more spinning CoreAudio threads. If it eventually
        // returns, the worker cleans up and recording can be attempted again.
        pendingStartID = nil
        return true
    }

    // MARK: - Bluetooth stream health and recovery

    /// Apple documents that an AVAudioEngine configuration change stops and
    /// uninitializes the engine. Bluetooth headsets trigger this while moving
    /// between their music and hands-free profiles, so a recording app must
    /// rebuild the graph with the new hardware format.
    private func beginMonitoring(engine: AVAudioEngine, requestID: UUID) {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, engine != nil else { return }
            // Apple explicitly warns against tearing an engine down from this
            // callback's internal queue. requestRecovery only records intent;
            // all AVAudioEngine teardown happens asynchronously on setupQueue.
            self.requestRecovery(
                requestID: requestID,
                reason: .configurationChanged
            )
        }

        lifecycleLock.lock()
        guard activeStartID == requestID, audioEngine === engine else {
            lifecycleLock.unlock()
            NotificationCenter.default.removeObserver(observer)
            return
        }
        let previousObserver = configurationObserver
        configurationObserver = observer
        let generation = watchdogGeneration
        lifecycleLock.unlock()
        if let previousObserver {
            NotificationCenter.default.removeObserver(previousObserver)
        }

        setupQueue.asyncAfter(deadline: .now() + Self.initialHealthDelay) { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            guard self.activeStartID == requestID,
                  self.watchdogGeneration == generation,
                  !self.isRecovering,
                  let currentEngine = self.audioEngine else {
                self.lifecycleLock.unlock()
                return
            }
            let failure = self.streamHealth.startupFailure(
                engineIsRunning: currentEngine.isRunning
            )
            let checkpoint = self.streamHealth.bufferCount
            self.lifecycleLock.unlock()

            if let failure {
                self.requestRecovery(
                    requestID: requestID,
                    reason: .unhealthy(failure)
                )
            } else {
                self.armLivenessCheck(
                    requestID: requestID,
                    generation: generation,
                    previousBufferCount: checkpoint
                )
            }
        }
    }

    private func armLivenessCheck(
        requestID: UUID,
        generation: Int,
        previousBufferCount: UInt64
    ) {
        setupQueue.asyncAfter(deadline: .now() + Self.livenessInterval) { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            guard self.activeStartID == requestID,
                  self.watchdogGeneration == generation,
                  !self.isRecovering,
                  let engine = self.audioEngine else {
                self.lifecycleLock.unlock()
                return
            }
            let failure = self.streamHealth.livenessFailure(
                engineIsRunning: engine.isRunning,
                previousBufferCount: previousBufferCount
            )
            let nextCheckpoint = self.streamHealth.bufferCount
            self.lifecycleLock.unlock()

            if let failure {
                self.requestRecovery(
                    requestID: requestID,
                    reason: .unhealthy(failure)
                )
            } else {
                self.armLivenessCheck(
                    requestID: requestID,
                    generation: generation,
                    previousBufferCount: nextCheckpoint
                )
            }
        }
    }

    private func requestRecovery(
        requestID: UUID,
        reason: RecoveryReason,
        preferredUIDOverride: String? = nil,
        isAutomatic: Bool = true
    ) {
        lifecycleLock.lock()
        guard activeStartID == requestID, !isRecovering else {
            lifecycleLock.unlock()
            return
        }

        if isAutomatic,
           automaticRecoveryCount >= Self.maximumAutomaticRecoveries {
            let failureCallback = streamFailureCallback
            lifecycleLock.unlock()
            DispatchQueue.main.async {
                failureCallback?(AudioRecorderError.streamRecoveryFailed)
            }
            return
        }

        if let preferredUIDOverride {
            preferredDeviceUID = preferredUIDOverride
            automaticRecoveryCount = 0
        } else if isAutomatic {
            automaticRecoveryCount += 1
        }
        isRecovering = true
        watchdogGeneration &+= 1

        let oldEngine = audioEngine
        let oldInputNode = audioInputNode
        audioEngine = nil
        audioInputNode = nil
        let oldObserver = configurationObserver
        configurationObserver = nil
        let selectedUID = preferredDeviceUID
        let callback = levelCallback
        let segmentCallback = recoveredChunkCallback
        let failureCallback = streamFailureCallback
        lifecycleLock.unlock()

        if let oldObserver {
            NotificationCenter.default.removeObserver(oldObserver)
        }

        print("[whisperino] rebuilding microphone graph (\(reason))")
        setupQueue.async { [weak self] in
            guard let self else { return }

            oldInputNode?.removeTap(onBus: 0)
            oldEngine?.stop()

            self.lifecycleLock.lock()
            guard self.activeStartID == requestID, self.isRecovering else {
                self.lifecycleLock.unlock()
                return
            }

            // Finalize the old WAV before creating a graph with the possibly
            // different Bluetooth sample rate. Preserve useful audio as a
            // normal rolling chunk; discard a known all-zero startup file.
            self.fileLock.lock()
            self.audioFile = nil
            let finishedURL = self.tempURL
            self.tempURL = nil
            self.fileLock.unlock()

            let preserveFinishedChunk = self.currentChunkHasNonZeroPCM
            let nextURL: URL
            if preserveFinishedChunk {
                self.chunkIndex += 1
                nextURL = self.chunkURL(index: self.chunkIndex)
            } else {
                nextURL = finishedURL ?? self.chunkURL(index: self.chunkIndex)
            }
            self.lifecycleLock.unlock()

            if !preserveFinishedChunk, let finishedURL {
                try? FileManager.default.removeItem(at: finishedURL)
            }

            var newEngine: AVAudioEngine?
            var newInputNode: AVAudioInputNode?
            do {
                self.selectPreferredInputIfNeeded(selectedUID)

                let engine = AVAudioEngine()
                newEngine = engine
                let inputNode = engine.inputNode
                newInputNode = inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)
                guard inputFormat.channelCount > 0,
                      inputFormat.sampleRate > 0 else {
                    throw AudioRecorderError.invalidInputFormat
                }

                print("[whisperino] recovered input at \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channel(s)")
                let file = try AVAudioFile(
                    forWriting: nextURL,
                    settings: inputFormat.settings
                )
                inputNode.installTap(
                    onBus: 0,
                    bufferSize: 512,
                    format: inputFormat
                ) { [weak self] buffer, _ in
                    guard let callback else { return }
                    self?.handleBuffer(
                        buffer,
                        requestID: requestID,
                        levelCallback: callback
                    )
                }
                engine.prepare()
                try engine.start()

                self.lifecycleLock.lock()
                guard self.activeStartID == requestID, self.isRecovering else {
                    self.lifecycleLock.unlock()
                    inputNode.removeTap(onBus: 0)
                    engine.stop()
                    try? FileManager.default.removeItem(at: nextURL)
                    return
                }
                self.fileLock.lock()
                self.audioFile = file
                self.tempURL = nextURL
                self.fileLock.unlock()
                self.audioEngine = engine
                self.audioInputNode = inputNode
                self.smoothedLevel = 0
                self.streamHealth.reset()
                self.currentChunkHasNonZeroPCM = false
                self.isRecovering = false
                self.watchdogGeneration &+= 1
                self.lifecycleLock.unlock()

                self.beginMonitoring(engine: engine, requestID: requestID)
                if preserveFinishedChunk, let finishedURL {
                    DispatchQueue.main.async { segmentCallback?(finishedURL) }
                }
            } catch {
                newInputNode?.removeTap(onBus: 0)
                newEngine?.stop()
                try? FileManager.default.removeItem(at: nextURL)

                self.lifecycleLock.lock()
                let stillActive = self.activeStartID == requestID
                if stillActive { self.isRecovering = false }
                self.lifecycleLock.unlock()

                if preserveFinishedChunk, let finishedURL {
                    DispatchQueue.main.async { segmentCallback?(finishedURL) }
                }
                if stillActive {
                    print("[whisperino] microphone graph recovery failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        failureCallback?(AudioRecorderError.streamRecoveryFailed)
                    }
                }
            }
        }
    }

    private func handleBuffer(
        _ buffer: AVAudioPCMBuffer,
        requestID: UUID,
        levelCallback: (Float) -> Void
    ) {
        lifecycleLock.lock()
        guard activeStartID == requestID, !isRecovering else {
            lifecycleLock.unlock()
            return
        }
        lifecycleLock.unlock()

        // Calculate RMS and convert to a visible 0..1 range.
        if let channelData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            var sum: Float = 0
            var maxAbsoluteSample: Float = 0
            for channel in 0..<channels {
                for frame in 0..<frames {
                    let sample = channelData[channel][frame]
                    sum += sample * sample
                    maxAbsoluteSample = max(maxAbsoluteSample, abs(sample))
                }
            }
            let sampleCount = max(Float(frames * max(channels, 1)), 1)
            let rms = sqrt(sum / sampleCount)
            let db = 20 * log10(max(rms, 1e-6))
            let level = Self.gatedLevel(db: db)

            lifecycleLock.lock()
            guard activeStartID == requestID, !isRecovering else {
                lifecycleLock.unlock()
                return
            }
            streamHealth.observeBuffer(maxAbsoluteSample: maxAbsoluteSample)
            if maxAbsoluteSample > 0 {
                currentChunkHasNonZeroPCM = true
                // A genuinely live stream earns a fresh retry budget. This
                // lets a later Bluetooth profile change recover independently.
                automaticRecoveryCount = 0
            }
            lifecycleLock.unlock()

            // Preserve just enough filtering to avoid single-buffer jitter.
            // Speech attacks immediately and silence clears within a few
            // CoreAudio buffers instead of leaving a long synthetic tail.
            let factor: Float = level > smoothedLevel ? 0.42 : 0.55
            smoothedLevel += factor * (level - smoothedLevel)
            levelCallback(smoothedLevel)
        }

        // Re-check the generation while holding the same lock order used by
        // adoption. This prevents a late tap from writing into a newer take.
        lifecycleLock.lock()
        guard activeStartID == requestID, !isRecovering else {
            lifecycleLock.unlock()
            return
        }
        fileLock.lock()
        lifecycleLock.unlock()
        do {
            try audioFile?.write(from: buffer)
        } catch {
            print("[whisperino] audio write error: \(error.localizedDescription)")
        }
        fileLock.unlock()
    }

    /// Device selection uses the same graph rebuild as automatic Bluetooth
    /// recovery. One path means the picker cannot reintroduce the timing race
    /// that the watchdog just repaired.
    func switchDevice(_ device: AudioInputDevice) {
        lifecycleLock.lock()
        guard let requestID = activeStartID else {
            lifecycleLock.unlock()
            return
        }
        lifecycleLock.unlock()
        requestRecovery(
            requestID: requestID,
            reason: .inputChanged,
            preferredUIDOverride: device.uid,
            isAutomatic: false
        )
    }

    private func chunkURL(sessionID: String? = nil, index: Int) -> URL {
        let id = sessionID ?? self.sessionID
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperino_\(id)_part\(index).wav")
    }

    /// Close the file being written and start a fresh one, returning the
    /// finished chunk's URL so it can be transcribed while recording
    /// continues. Returns nil if not recording or the swap fails (in
    /// which case recording just keeps writing the current file -
    /// nothing is lost, the chunk only gets longer).
    func rotateChunk() -> URL? {
        lifecycleLock.lock()
        guard activeStartID != nil, !isRecovering else {
            lifecycleLock.unlock()
            return nil
        }
        fileLock.lock()
        defer {
            fileLock.unlock()
            lifecycleLock.unlock()
        }
        guard let current = audioFile, let finishedURL = tempURL else { return nil }

        chunkIndex += 1
        let newURL = chunkURL(index: chunkIndex)
        do {
            // Releasing the old AVAudioFile finalizes its WAV header.
            let newFile = try AVAudioFile(forWriting: newURL, settings: current.fileFormat.settings)
            audioFile = newFile
            tempURL = newURL
            currentChunkHasNonZeroPCM = false
            return finishedURL
        } catch {
            print("[whisperino] chunk rotation failed: \(error.localizedDescription)")
            chunkIndex -= 1
            return nil
        }
    }

    func stop() -> URL? {
        lifecycleLock.lock()
        // Cancels a setup that is still in flight. The worker owns and cleans
        // up its local engine/file if CoreAudio eventually returns.
        pendingStartID = nil
        let engine = audioEngine
        let inputNode = audioInputNode
        let observer = configurationObserver
        audioEngine = nil
        audioInputNode = nil
        configurationObserver = nil
        activeStartID = nil
        isRecovering = false
        watchdogGeneration &+= 1
        streamHealth.reset()
        currentChunkHasNonZeroPCM = false
        automaticRecoveryCount = 0
        preferredDeviceUID = nil
        levelCallback = nil
        recoveredChunkCallback = nil
        streamFailureCallback = nil
        lifecycleLock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        inputNode?.removeTap(onBus: 0)
        engine?.stop()
        fileLock.lock()
        defer { fileLock.unlock() }
        audioFile = nil
        let url = tempURL
        tempURL = nil
        return url
    }
}
