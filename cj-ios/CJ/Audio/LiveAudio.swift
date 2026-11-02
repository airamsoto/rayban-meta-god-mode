import AVFoundation

/// The audio side of a real-time conversation: the glasses' mic (Bluetooth HFP) streamed up as 128 ms frames of
/// 16 kHz mono 16-bit PCM, and CJ's voice (24 kHz mono 16-bit PCM from the brain) played back on the glasses.
///
/// Ported from Live.kt / Mic.kt: while CJ talks only clearly louder speech goes up (you interrupting), not CJ's own
/// voice coming back into the mic. iOS's voice-chat mode also runs Apple's echo canceller.
final class LiveAudio {
    static let upRate = 16_000.0
    static let downRate = 24_000.0
    static let frameSamples = 2048  // 128 ms at 16 kHz, like the Android app

    /// Called on the audio thread with each frame to send (silence when it's held back as echo).
    var onFrame: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let upFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: upRate, channels: 1, interleaved: true)!
    private let downFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: downRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var pending: [Int16] = []
    private var configObserver: NSObjectProtocol?

    private let lock = NSLock()
    private var playingUntil: CFTimeInterval = 0  // when the audio queued so far will have finished playing
    private var echo = 0.0                        // how loud CJ's own voice comes back into the mic
    private(set) var noiseFloor = 200.0           // typical loudness of the room

    private(set) var inputName = ""
    private(set) var inputIsGlasses = false

    /// True while CJ's voice is still playing.
    var speaking: Bool { lock.withLock { CACurrentMediaTime() < playingUntil } }
    /// Seconds of CJ's voice still queued.
    var remaining: TimeInterval { lock.withLock { max(0, playingUntil - CACurrentMediaTime()) } }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setActive(true)
        if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(glasses)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: downFormat)
        try startInput()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // A route change (glasses connecting, HFP renegotiating its sample rate) stops the engine: rebuild the tap.
            try? self?.startInput()
        }
    }

    private func startInput() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw LiveAudioError.noMic }
        converter = AVAudioConverter(from: format, to: upFormat)
        pending.removeAll()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        let port = AVAudioSession.sharedInstance().currentRoute.inputs.first
        inputIsGlasses = port?.portType == .bluetoothHFP
        inputName = port.map { inputIsGlasses ? "\($0.portName) (gafas)" : $0.portName } ?? "sin micrófono"
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - CJ's voice

    /// Queues one chunk of CJ's voice (24 kHz mono 16-bit little-endian PCM).
    func play(_ pcm: Data) {
        let count = pcm.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: downFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        lock.withLock {
            playingUntil = max(playingUntil, CACurrentMediaTime()) + Double(count) / Self.downRate
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    /// Stops CJ mid-sentence (you interrupted, or said "stop") and drops what was queued.
    func flush() {
        player.stop()
        player.play()
        lock.withLock { playingUntil = 0 }
    }

    // MARK: - the mic

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.upRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: upFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        while pending.count >= Self.frameSamples {
            let frame = Array(pending.prefix(Self.frameSamples))
            pending.removeFirst(Self.frameSamples)
            send(frame)
        }
    }

    private func send(_ frame: [Int16]) {
        let level = Self.rms(frame)
        let (talking, bar): (Bool, Double) = lock.withLock {
            // Falls fast to quiet, rises slowly, so speech barely moves it (Mic.kt).
            noiseFloor = level < noiseFloor ? 0.7 * noiseFloor + 0.3 * level : 0.995 * noiseFloor + 0.005 * level
            return (CACurrentMediaTime() < playingUntil, max(echo * 2.5, noiseFloor * 5, 600))
        }
        // While CJ talks, only clearly louder speech goes up (you interrupting), not CJ's own voice. Learn the echo
        // only from what was held back, or talking over CJ would keep raising the bar.
        let pass = !talking || level > bar
        if talking && !pass { lock.withLock { echo = 0.9 * echo + 0.1 * level } }
        let out = pass ? frame : [Int16](repeating: 0, count: frame.count)
        onFrame?(out.withUnsafeBufferPointer { Data(buffer: $0) })  // iOS is little-endian, as the brain expects
    }

    static func rms(_ frame: [Int16]) -> Double {
        var sum = 0.0
        for s in frame { sum += Double(s) * Double(s) }
        return (sum / Double(max(frame.count, 1))).squareRoot()
    }
}

enum LiveAudioError: LocalizedError {
    case noMic
    var errorDescription: String? { "No hay micrófono disponible." }
}
