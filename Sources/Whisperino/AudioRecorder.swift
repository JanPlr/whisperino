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

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "The selected microphone reported an invalid audio format"
        case .startupTimedOut:
            return "The microphone did not respond. Reconnect it or choose another input"
        case .startupStillInProgress:
            return "CoreAudio is still trying to open the microphone. Restart Whisperino if it does not recover"
        }
    }
}

class AudioRecorder {
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
    private var sessionID = ""
    private var chunkIndex = 0

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

    /// Map raw RMS dB → 0..1 level for the meter, with a noise gate so
    /// ambient room noise doesn't make the bars dance.
    /// - dB scaling: -50 dB = 0, -15 dB = 1
    /// - Anything below the noise gate is forced to 0
    /// - Above the gate, a sub-linear curve boosts mid-range so normal
    ///   conversational voice produces a satisfying excursion
    private static func gatedLevel(db: Float) -> Float {
        let raw = max(0, min(1, (db + 50) / 35))
        let gate: Float = 0.14  // soft threshold ~ -45 dB
        if raw < gate { return 0 }
        let scaled = (raw - gate) / (1 - gate)
        // pow(x, 0.65) - pulls mid-range values up (0.5 → 0.63, 0.3 → 0.45)
        // so normal voice reads as a strong, visible swing.
        return pow(scaled, 0.65)
    }

    /// Start recording without ever putting AVAudioEngine/CoreAudio setup on
    /// the main run loop. Completion is delivered on the main queue.
    func start(
        preferredDeviceUID: String? = nil,
        levelCallback: @escaping (Float) -> Void,
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
        lifecycleLock.unlock()

        let newSessionID = requestID.uuidString
        let url = chunkURL(sessionID: newSessionID, index: 0)

        setupQueue.async { [weak self] in
            guard let self else { return }
            var engine: AVAudioEngine?
            var inputNode: AVAudioInputNode?
            do {
                guard self.isStartPending(requestID) else { throw CancellationError() }
                // Resolve the UID immediately before use. If it disappeared or
                // became invalid, leave the current system default untouched.
                if let preferredDeviceUID {
                    if let resolvedID = Self.inputDeviceID(forUID: preferredDeviceUID),
                       Self.isUsableInputDevice(resolvedID) {
                        // Avoid writing the default-device property when it is
                        // already correct; needless HAL reconfiguration can
                        // surface stale state after device churn.
                        if Self.defaultInputDeviceID() != resolvedID,
                           !Self.setDefaultInputDevice(resolvedID) {
                            print("[whisperino] preferred input \(preferredDeviceUID) could not be selected; using system default")
                        }
                    } else {
                        print("[whisperino] preferred input \(preferredDeviceUID) is unavailable; using system default")
                    }
                }

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

    private func handleBuffer(
        _ buffer: AVAudioPCMBuffer,
        requestID: UUID,
        levelCallback: (Float) -> Void
    ) {
        lifecycleLock.lock()
        guard activeStartID == requestID else {
            lifecycleLock.unlock()
            return
        }
        lifecycleLock.unlock()

        // Calculate RMS and convert to a visible 0..1 range.
        if let channelData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames {
                let sample = channelData[0][i]
                sum += sample * sample
            }
            let rms = sqrt(sum / max(Float(frames), 1))
            let db = 20 * log10(max(rms, 1e-6))
            let level = Self.gatedLevel(db: db)

            if level > smoothedLevel && smoothedLevel < 0.05 {
                smoothedLevel = level
            } else {
                let factor: Float = level > smoothedLevel ? 0.9 : 0.5
                smoothedLevel += factor * (level - smoothedLevel)
            }
            levelCallback(smoothedLevel)
        }

        // Re-check the generation while holding the same lock order used by
        // adoption. This prevents a late tap from writing into a newer take.
        lifecycleLock.lock()
        guard activeStartID == requestID else {
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

    /// Switch the input device while recording by changing the system default
    /// input device, then restarting the engine so it picks up the new default.
    func switchDevice(deviceID: AudioDeviceID, levelCallback: @escaping (Float) -> Void) throws {
        guard audioEngine != nil else { return }

        // Set the system default input device - AVAudioEngine always follows this
        guard Self.setDefaultInputDevice(deviceID) else {
            print("[whisperino] switchDevice: failed to set system default to \(deviceID)")
            return
        }

        audioInputNode?.removeTap(onBus: 0)
        audioEngine!.stop()
        smoothedLevel = 0

        // Start a fresh engine - it will use the new system default
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            if let channelData = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames {
                    let sample = channelData[0][i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / max(Float(frames), 1))
                let db = 20 * log10(max(rms, 1e-6))
                let level = Self.gatedLevel(db: db)
                if level > self.smoothedLevel && self.smoothedLevel < 0.05 {
                    self.smoothedLevel = level
                } else {
                    let factor: Float = level > self.smoothedLevel ? 0.9 : 0.5
                    self.smoothedLevel += factor * (level - self.smoothedLevel)
                }
                levelCallback(self.smoothedLevel)
            }

            self.fileLock.lock()
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                print("[whisperino] audio write error: \(error.localizedDescription)")
            }
            self.fileLock.unlock()
        }

        newEngine.prepare()
        try newEngine.start()
        self.audioEngine = newEngine
        self.audioInputNode = inputNode
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
        let isRecording = activeStartID != nil
        lifecycleLock.unlock()
        fileLock.lock()
        defer { fileLock.unlock() }
        guard isRecording, let current = audioFile, let finishedURL = tempURL else { return nil }

        chunkIndex += 1
        let newURL = chunkURL(index: chunkIndex)
        do {
            // Releasing the old AVAudioFile finalizes its WAV header.
            let newFile = try AVAudioFile(forWriting: newURL, settings: current.fileFormat.settings)
            audioFile = newFile
            tempURL = newURL
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
        audioEngine = nil
        audioInputNode = nil
        activeStartID = nil
        lifecycleLock.unlock()

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
