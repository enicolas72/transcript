import Foundation
import Accelerate

/// Extracts voice features from audio segments and clusters them into speakers.
enum VoiceAnalyzer {
    /// Feature vector representing a segment's voice characteristics.
    struct VoiceFeatures {
        let spectralCentroid: Float   // brightness of voice
        let spectralSpread: Float     // how spread the spectrum is
        let rmsEnergy: Float          // loudness
        let zeroCrossingRate: Float   // correlates with pitch/noisiness
        let pitch: Float              // estimated fundamental frequency

        var vector: [Float] { [spectralCentroid, spectralSpread, rmsEnergy, zeroCrossingRate, pitch] }
    }

    // MARK: - Public API

    /// Analyze segments and assign speakers based on voice similarity.
    ///
    /// 1. Extracts full audio as 16kHz mono PCM
    /// 2. Computes voice features per segment
    /// 3. Clusters segments into 2 speakers using k-means
    static func assignSpeakers(
        filePath: String,
        segments: [WhisperSegment]
    ) async -> [LabeledSegment] {
        guard !segments.isEmpty else { return [] }

        // Extract full audio as raw PCM
        guard let samples = await extractPCM(filePath: filePath) else {
            // Fallback: no speaker labels
            return segments.map { LabeledSegment(start: $0.start, end: $0.end,
                text: $0.text.trimmingCharacters(in: .whitespaces), speaker: "Speaker A") }
        }

        let sampleRate: Float = 16000.0

        // Compute features for each segment
        var features: [VoiceFeatures] = []
        for seg in segments {
            let startSample = Int(Float(seg.start) * sampleRate)
            let endSample = min(Int(Float(seg.end) * sampleRate), samples.count)

            if startSample >= endSample || endSample - startSample < 1600 {
                // Segment too short for analysis, use zero features
                features.append(VoiceFeatures(spectralCentroid: 0, spectralSpread: 0,
                    rmsEnergy: 0, zeroCrossingRate: 0, pitch: 0))
                continue
            }

            let segSamples = Array(samples[startSample..<endSample])
            features.append(computeFeatures(segSamples, sampleRate: sampleRate))
        }

        // Cluster into 2 speakers
        let labels = kMeansClustering(features: features, k: 2)

        return zip(segments, labels).map { seg, label in
            LabeledSegment(
                start: seg.start,
                end: seg.end,
                text: seg.text.trimmingCharacters(in: .whitespaces),
                speaker: label == 0 ? "Speaker A" : "Speaker B"
            )
        }
    }

    // MARK: - PCM Extraction

    /// Extract audio as 16kHz mono Float32 PCM using ffmpeg.
    private static func extractPCM(filePath: String) async -> [Float]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-i", filePath,
            "-f", "f32le",       // raw float32 little-endian
            "-ac", "1",          // mono
            "-ar", "16000",      // 16kHz
            "-acodec", "pcm_f32le",
            "-v", "quiet",
            "pipe:1"             // output to stdout
        ]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0, !data.isEmpty else { return nil }

            // Convert Data to [Float]
            let count = data.count / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                let floatBuffer = raw.bindMemory(to: Float.self)
                for i in 0..<count {
                    samples[i] = floatBuffer[i]
                }
            }
            return samples
        } catch {
            return nil
        }
    }

    // MARK: - Feature Computation

    private static func computeFeatures(_ samples: [Float], sampleRate: Float) -> VoiceFeatures {
        let rms = computeRMS(samples)
        let zcr = computeZeroCrossingRate(samples)
        let (centroid, spread) = computeSpectralFeatures(samples, sampleRate: sampleRate)
        let pitch = estimatePitch(samples, sampleRate: sampleRate)

        return VoiceFeatures(
            spectralCentroid: centroid,
            spectralSpread: spread,
            rmsEnergy: rms,
            zeroCrossingRate: zcr,
            pitch: pitch
        )
    }

    private static func computeRMS(_ samples: [Float]) -> Float {
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrt(meanSquare)
    }

    private static func computeZeroCrossingRate(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings: Float = 0
        for i in 1..<samples.count {
            if (samples[i] >= 0) != (samples[i - 1] >= 0) {
                crossings += 1
            }
        }
        return crossings / Float(samples.count)
    }

    /// Compute spectral centroid and spread via FFT.
    private static func computeSpectralFeatures(_ samples: [Float], sampleRate: Float) -> (centroid: Float, spread: Float) {
        // Use a fixed FFT window size, process multiple windows and average
        let fftSize = 2048
        let log2n = vDSP_Length(log2(Float(fftSize)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)),
              samples.count >= fftSize else {
            return (0, 0)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let hopSize = fftSize / 2
        let numWindows = max(1, (samples.count - fftSize) / hopSize + 1)
        let halfN = fftSize / 2

        var totalCentroid: Float = 0
        var totalSpread: Float = 0
        var validWindows: Float = 0

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        for w in 0..<numWindows {
            let start = w * hopSize
            guard start + fftSize <= samples.count else { break }

            // Apply window
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(samples[start..<start + fftSize]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            // FFT
            var real = [Float](repeating: 0, count: halfN)
            var imag = [Float](repeating: 0, count: halfN)

            windowed.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                    var splitComplex = DSPSplitComplex(realp: &real, imagp: &imag)
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }

            // Magnitude spectrum
            var magnitudes = [Float](repeating: 0, count: halfN)
            var splitResult = DSPSplitComplex(realp: &real, imagp: &imag)
            vDSP_zvmags(&splitResult, 1, &magnitudes, 1, vDSP_Length(halfN))

            // Spectral centroid = sum(f * |X(f)|) / sum(|X(f)|)
            var totalMag: Float = 0
            var weightedSum: Float = 0
            let freqResolution = sampleRate / Float(fftSize)

            for i in 1..<halfN {
                let mag = sqrt(magnitudes[i])
                let freq = Float(i) * freqResolution
                weightedSum += freq * mag
                totalMag += mag
            }

            guard totalMag > 0 else { continue }

            let centroid = weightedSum / totalMag
            totalCentroid += centroid

            // Spectral spread = sqrt(sum((f - centroid)^2 * |X(f)|) / sum(|X(f)|))
            var spreadSum: Float = 0
            for i in 1..<halfN {
                let mag = sqrt(magnitudes[i])
                let freq = Float(i) * freqResolution
                let diff = freq - centroid
                spreadSum += diff * diff * mag
            }
            totalSpread += sqrt(spreadSum / totalMag)
            validWindows += 1
        }

        guard validWindows > 0 else { return (0, 0) }
        return (totalCentroid / validWindows, totalSpread / validWindows)
    }

    /// Estimate fundamental frequency via autocorrelation.
    private static func estimatePitch(_ samples: [Float], sampleRate: Float) -> Float {
        // Analyze a chunk from the middle of the segment (more stable than edges)
        let chunkSize = min(4096, samples.count)
        let startOffset = max(0, (samples.count - chunkSize) / 2)
        let chunk = Array(samples[startOffset..<startOffset + chunkSize])

        // Autocorrelation
        let maxLag = min(chunkSize - 1, Int(sampleRate / 80))   // 80 Hz minimum
        let minLag = Int(sampleRate / 500)                        // 500 Hz maximum

        guard maxLag > minLag else { return 0 }

        var autocorr = [Float](repeating: 0, count: maxLag)
        for lag in minLag..<maxLag {
            var sum: Float = 0
            vDSP_dotpr(chunk, 1, Array(chunk[lag...]), 1, &sum, vDSP_Length(chunkSize - lag))
            autocorr[lag] = sum
        }

        // Find the peak in autocorrelation (corresponds to pitch period)
        var bestLag = minLag
        var bestVal: Float = -Float.infinity
        for lag in minLag..<maxLag {
            if autocorr[lag] > bestVal {
                bestVal = autocorr[lag]
                bestLag = lag
            }
        }

        // Verify it's a real peak (not just noise)
        guard bestVal > 0 else { return 0 }
        return sampleRate / Float(bestLag)
    }

    // MARK: - Clustering

    /// Simple k-means clustering on feature vectors.
    private static func kMeansClustering(features: [VoiceFeatures], k: Int) -> [Int] {
        let n = features.count
        guard n >= k else {
            return Array(0..<n)
        }

        // Normalize features to [0,1] range
        let vectors = features.map { $0.vector }
        let dim = vectors[0].count
        var mins = [Float](repeating: Float.infinity, count: dim)
        var maxs = [Float](repeating: -Float.infinity, count: dim)

        for v in vectors {
            for d in 0..<dim {
                mins[d] = min(mins[d], v[d])
                maxs[d] = max(maxs[d], v[d])
            }
        }

        let normalized: [[Float]] = vectors.map { v in
            (0..<dim).map { d in
                let range = maxs[d] - mins[d]
                return range > 0 ? (v[d] - mins[d]) / range : 0
            }
        }

        // Initialize centroids: pick first and the most distant from it
        var centroids = [normalized[0]]
        var maxDist: Float = -1
        var farthestIdx = 0
        for i in 1..<n {
            let d = distance(normalized[i], centroids[0])
            if d > maxDist {
                maxDist = d
                farthestIdx = i
            }
        }
        centroids.append(normalized[farthestIdx])

        var labels = [Int](repeating: 0, count: n)

        // Run k-means for up to 20 iterations
        for _ in 0..<20 {
            // Assign
            var changed = false
            for i in 0..<n {
                var bestCluster = 0
                var bestDist: Float = Float.infinity
                for c in 0..<k {
                    let d = distance(normalized[i], centroids[c])
                    if d < bestDist {
                        bestDist = d
                        bestCluster = c
                    }
                }
                if labels[i] != bestCluster {
                    labels[i] = bestCluster
                    changed = true
                }
            }

            if !changed { break }

            // Update centroids
            for c in 0..<k {
                var sum = [Float](repeating: 0, count: dim)
                var count: Float = 0
                for i in 0..<n {
                    if labels[i] == c {
                        for d in 0..<dim { sum[d] += normalized[i][d] }
                        count += 1
                    }
                }
                if count > 0 {
                    centroids[c] = sum.map { $0 / count }
                }
            }
        }

        // Ensure Speaker A is the one who speaks first
        if labels[0] != 0 {
            labels = labels.map { $0 == 0 ? 1 : 0 }
        }

        return labels
    }

    private static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<a.count {
            let diff = a[i] - b[i]
            sum += diff * diff
        }
        return sqrt(sum)
    }
}
