import Foundation
import Network
import AVFoundation
import VideoToolbox
import UIKit
import OSLog
import Observation

/// Receives H.264 frames from the `ScreenRelay` broadcast extension over a
/// loopback TCP socket and renders them with `AVSampleBufferDisplayLayer`.
/// The extension is the only process allowed to capture the screen; it can't
/// draw on the car window, so it relays to us.
///
/// Wire format (little-endian): [u32 length][u8 kind][payload]
///   kind 0 = SPS+PPS (Annex-B), kind 1 = frame (AVCC length-prefixed NALs), kind 2 = heartbeat
@Observable
final class MirrorReceiver {
    static let port: UInt16 = 47_311

    enum State: Equatable { case idle, listening, mirroring, error(String) }
    private(set) var state: State = .idle
    private(set) var frameSize: CGSize = .zero
    private(set) var fps: Int = 0

    let displayView = MirrorDisplayView()

    private let queue = DispatchQueue(label: "cartv.mirror.rx", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var formatDesc: CMVideoFormatDescription?
    private var frameCount = 0
    private var fpsTimer: DispatchSourceTimer?
    private var lastFrameAt: Date = .distantPast

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor [weak self] in
                    switch st {
                    case .ready: self?.state = .listening
                    case .failed(let e): self?.state = .error(e.localizedDescription)
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.attach(c) }
            l.start(queue: queue)
            listener = l
            startFPS()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func stop() {
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        fpsTimer?.cancel(); fpsTimer = nil
        displayView.flush()
        state = .idle
    }

    private func attach(_ c: NWConnection) {
        connection?.cancel()
        connection = c
        c.stateUpdateHandler = { [weak self] st in
            Task { @MainActor [weak self] in
                switch st {
                case .ready: self?.state = .mirroring
                case .cancelled, .failed: if self?.state == .mirroring { self?.state = .listening }; self?.displayView.flush()
                default: break
                }
            }
        }
        c.start(queue: queue)
        readHeader(c)
    }

    private func readHeader(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, done, err in
            guard let self, let data, data.count == 5, err == nil else { c.cancel(); return }
            let len = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let kind = data[4]
            if len == 0 { self.readHeader(c); return }
            self.readPayload(c, Int(len), kind)
        }
    }

    private func readPayload(_ c: NWConnection, _ len: Int, _ kind: UInt8) {
        c.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, _, err in
            guard let self, let data, data.count == len, err == nil else { c.cancel(); return }
            switch kind {
            case 0: self.handleParameterSets(data)
            case 1: self.handleFrame(data)
            default: break
            }
            self.readHeader(c)
        }
    }

    // MARK: Decode → display

    private func handleParameterSets(_ data: Data) {
        // Payload: [u16 spsLen][sps][u16 ppsLen][pps]
        var offset = 0
        func read16() -> Int { let v = Int(data[offset]) | Int(data[offset + 1]) << 8; offset += 2; return v }
        let spsLen = read16(); let sps = data.subdata(in: offset..<offset + spsLen); offset += spsLen
        let ppsLen = read16(); let pps = data.subdata(in: offset..<offset + ppsLen)
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let sets = [spsPtr.bindMemory(to: UInt8.self).baseAddress!, ppsPtr.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                var desc: CMFormatDescription?
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: sets, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                formatDesc = desc
                if let desc {
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    Task { @MainActor in self.frameSize = CGSize(width: Int(dims.width), height: Int(dims.height)) }
                }
            }
        }
    }

    private func handleFrame(_ data: Data) {
        guard let formatDesc else { return }
        var block: CMBlockBuffer?
        let status = data.withUnsafeBytes { ptr -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        }
        guard status == noErr, let block else { return }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var size = data.count
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDesc, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        frameCount += 1
        displayView.enqueue(sample)
    }

    private func startFPS() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let n = self.frameCount; self.frameCount = 0
            Task { @MainActor in self.fps = n }
        }
        t.resume(); fpsTimer = t
    }
}

/// UIView backed by AVSampleBufferDisplayLayer. Thread-safe enqueue.
final class MirrorDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }

    nonisolated func enqueue(_ sample: CMSampleBuffer) {
        MainActor.assumeIsolatedIfNeeded { [self] in
            if displayLayer.status == .failed { displayLayer.flush() }
            if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(sample) }
        }
    }
    nonisolated func flush() {
        MainActor.assumeIsolatedIfNeeded { [self] in displayLayer.flushAndRemoveImage() }
    }
}

extension MainActor {
    /// Runs synchronously if already on main, else dispatches async. For hot render paths.
    nonisolated static func assumeIsolatedIfNeeded(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.async { body() } }
    }
}
