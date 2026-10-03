//
//  VideoEncoder.swift
//
//  AVAssetWriter front end for the exporter. Pixel buffers come from the
//  adaptor's pool wrapped as Metal textures through a texture cache, so the
//  resolve kernel writes straight into what the encoder reads -- no CPU
//  copy per frame. HEVC for small files, HEVC HQ (3x bitrate) for editing,
//  H.264 for compatibility; anything the writer refuses falls back to HEVC
//  with a log line.
//

import AVFoundation
import CoreVideo
import Metal

/// visionOS has no ProRes writer, so "edit quality" is HEVC at three times
/// the bitrate; H.264 is for editors that still choke on HEVC.
enum ExportCodec: String, CaseIterable, Identifiable {
    case hevc, hevcHQ, h264
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hevc: return "HEVC"
        case .hevcHQ: return "HEVC HQ"
        case .h264: return "H.264"
        }
    }
}

struct VideoEncoderError: Error, CustomStringConvertible {
    let description: String
}

final class VideoEncoder {

    let url: URL
    private(set) var codecInUse: ExportCodec
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let textureCache: CVMetalTextureCache
    private let fps: Int
    private var started = false

    init(url: URL, width: Int, height: Int, fps: Int, codec: ExportCodec, device: MTLDevice) throws {
        self.url = url
        self.fps = fps
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        func settings(_ c: ExportCodec) -> [String: Any] {
            var s: [String: Any] = [
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
            // 40 Mbps at 1080p60, scaled by pixel count and frame rate.
            let baseMbps = Double(width * height) / Double(1920 * 1080) * 40 * Double(fps) / 60
            let mbps: Double
            switch c {
            case .hevc:
                s[AVVideoCodecKey] = AVVideoCodecType.hevc
                mbps = baseMbps
            case .hevcHQ:
                s[AVVideoCodecKey] = AVVideoCodecType.hevc
                mbps = baseMbps * 3
            case .h264:
                s[AVVideoCodecKey] = AVVideoCodecType.h264
                mbps = baseMbps * 1.5
            }
            s[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(mbps * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ]
            return s
        }

        var chosen = codec
        if !writer.canApply(outputSettings: settings(codec), forMediaType: .video) {
            print("video export: \(codec.rawValue) not supported by this writer, using hevc")
            chosen = .hevc
        }
        codecInUse = chosen
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings(chosen))
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else {
            throw VideoEncoderError(description: "writer refused the video input")
        }
        writer.add(input)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw VideoEncoderError(description: "no Metal texture cache")
        }
        textureCache = cache
    }

    /// Borrow a pixel buffer and a Metal texture aliasing it for one frame.
    func nextFrame() throws -> (CVPixelBuffer, MTLTexture) {
        if !started {
            guard writer.startWriting() else {
                throw VideoEncoderError(description: writer.error?.localizedDescription ?? "startWriting failed")
            }
            writer.startSession(atSourceTime: .zero)
            started = true
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw VideoEncoderError(description: "no pixel buffer pool (\(writer.error?.localizedDescription ?? "writer not ready"))")
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else { throw VideoEncoderError(description: "pixel buffer allocation failed") }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0,
                &cvTexture) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture)
        else { throw VideoEncoderError(description: "pixel buffer to Metal texture failed") }
        return (pixelBuffer, texture)
    }

    /// Hand a rendered frame back; call after the GPU finished writing it.
    func append(_ buffer: CVPixelBuffer, frameIndex: Int) throws {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw VideoEncoderError(description: writer.error?.localizedDescription ?? "append failed")
        }
    }

    /// Blocks until the file is complete. Nothing written: no file is left.
    func finish() throws {
        guard started else { cancel(); return }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed {
            throw VideoEncoderError(description: writer.error?.localizedDescription ?? "finishWriting failed")
        }
    }

    /// Discard the file.
    func cancel() {
        if started { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
