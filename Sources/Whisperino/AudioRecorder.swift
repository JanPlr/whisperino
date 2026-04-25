import AVFoundation
import CoreAudio
import Foundation

/// Represents an available audio input device
struct AudioInputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempURL: URL?
    private var smoothedLevel: Float = 0
    private var isPaused = false

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
            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPointer.deallocate() }
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
        // pow(x, 0.65) — pulls mid-range values up (0.5 → 0.63, 0.3 → 0.45)
        // so normal voice reads as a strong, visible swing.
        return pow(scaled, 0.65)
    }

    func start(deviceID: AudioDeviceID? = nil, levelCallback: @escaping (Float) -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("whisperino_\(UUID().uuidString).wav")
        self.tempURL = url
        smoothedLevel = 0
        isPaused = false

        // Set the system default input device if a specific one is requested
        if let deviceID = deviceID {
            if !Self.setDefaultInputDevice(deviceID) {
                print("[whisperino] failed to set system default input device (\(deviceID))")
            }
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let audioFile = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        self.audioFile = audioFile

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // When paused, keep engine running but skip writing and report zero level
            guard !self.isPaused else {
                levelCallback(0)
                return
            }

            // Calculate RMS and convert to a visible 0..1 range
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

                // Smooth: moderate attack, slow decay
                let attack: Float = 0.55
                let decay: Float = 0.18
                let factor = level > self.smoothedLevel ? attack : decay
                self.smoothedLevel += factor * (level - self.smoothedLevel)

                levelCallback(self.smoothedLevel)
            }

            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                print("[whisperino] audio write error: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    /// Switch the input device while recording by changing the system default
    /// input device, then restarting the engine so it picks up the new default.
    func switchDevice(deviceID: AudioDeviceID, levelCallback: @escaping (Float) -> Void) throws {
        guard audioEngine != nil else { return }

        // Set the system default input device — AVAudioEngine always follows this
        guard Self.setDefaultInputDevice(deviceID) else {
            print("[whisperino] switchDevice: failed to set system default to \(deviceID)")
            return
        }

        // Tear down current engine
        audioEngine!.inputNode.removeTap(onBus: 0)
        audioEngine!.stop()
        audioEngine = nil
        smoothedLevel = 0

        // Start a fresh engine — it will use the new system default
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard !self.isPaused else {
                levelCallback(0)
                return
            }

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
                let factor = level > self.smoothedLevel ? Float(0.55) : Float(0.18)
                self.smoothedLevel += factor * (level - self.smoothedLevel)
                levelCallback(self.smoothedLevel)
            }

            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                print("[whisperino] audio write error: \(error.localizedDescription)")
            }
        }

        newEngine.prepare()
        try newEngine.start()
        self.audioEngine = newEngine
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func stop() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        let url = tempURL
        tempURL = nil
        return url
    }
}
