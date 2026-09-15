import ReplayKit
import VideoToolbox
import Network
import CoreMedia

/// Broadcast Upload Extension: captures the iPhone screen, encodes to H.264 with
/// VideoToolbox, and streams frames to the CarTV app over loopback TCP (port 47311).
/// Frame format matches `MirrorReceiver` in the app.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private var session: VTCompressionSession?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "cartv.relay", qos: .userInteractive)
    private var sentParameterSets = false
    private var lastSent = CFAbsoluteTimeGetCurrent()
    private var frameInterval: Double = 1.0 / 30.0
    private var targetWidth: Int32 = 1280

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        connect()
    }

    override func broadcastFinished() {
        if let s = session { VTCompressionSessionInvalidate(s); session = nil }
        connection?.cancel(); connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSent >= frameInterval else { return }   // cap at ~30 fps
        lastSent = now

        if session == nil { makeSession(for: pixel) }
        guard let session else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    // MARK: Encoder

    private func makeSession(for pixel: CVPixelBuffer) {
        let srcW = Int32(CVPixelBufferGetWidth(pixel)), srcH = Int32(CVPixelBufferGetHeight(pixel))
        // Downscale so the car gets a smooth stream: long edge 1280.
        let longEdge = max(srcW, srcH)
        let scale = longEdge > targetWidth ? Double(targetWidth) / Double(longEdge) : 1
        let w = Int32(Double(srcW) * scale) & ~1, h = Int32(Double(srcH) * scale) & ~1

        var s: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard let s else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        sentParameterSets = false
    }

    private func emit(_ sample: CMSampleBuffer) {
        guard let conn = connection, let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        if isKey || !sentParameterSets {
            var spsPtr: UnsafePointer<UInt8>?, spsLen = 0, ppsPtr: UnsafePointer<UInt8>?, ppsLen = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let spsPtr, let ppsPtr {
                var payload = Data()
                payload.append(UInt8(spsLen & 0xff)); payload.append(UInt8(spsLen >> 8))
                payload.append(spsPtr, count: spsLen)
                payload.append(UInt8(ppsLen & 0xff)); payload.append(UInt8(ppsLen >> 8))
                payload.append(ppsPtr, count: ppsLen)
                send(kind: 0, payload, on: conn)
                sentParameterSets = true
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0, ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { return }
        send(kind: 1, Data(bytes: ptr, count: length), on: conn)
    }

    // MARK: Transport

    private func connect() {
        let c = NWConnection(host: "127.0.0.1", port: 47311, using: .tcp)
        c.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.retry() }
            if case .cancelled = st { self?.retry() }
        }
        c.start(queue: queue)
        connection = c
    }

    private func retry() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.connection != nil else { return }
            self.sentParameterSets = false
            self.connect()
        }
    }

    private func send(kind: UInt8, _ payload: Data, on c: NWConnection) {
        var header = Data(count: 5)
        var len = UInt32(payload.count).littleEndian
        header.replaceSubrange(0..<4, with: Data(bytes: &len, count: 4))
        header[4] = kind
        c.send(content: header + payload, completion: .contentProcessed { _ in })
    }
}
