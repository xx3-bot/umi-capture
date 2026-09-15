import Foundation

struct CoordinatorClockEstimator {
    private(set) var samples: [CaptureClockMappingSample] = []
    private var candidates: [CaptureClockMappingSample] = []

    mutating func accept(
        probeID: String,
        localSendNs: UInt64,
        localReceiveNs: UInt64,
        coordinatorReceiveNs: UInt64,
        coordinatorSendNs: UInt64
    ) -> CaptureClockMappingSample? {
        guard
            localReceiveNs >= localSendNs,
            coordinatorSendNs >= coordinatorReceiveNs
        else {
            return nil
        }
        let localElapsed = localReceiveNs - localSendNs
        let coordinatorElapsed = coordinatorSendNs - coordinatorReceiveNs
        guard localElapsed >= coordinatorElapsed else {
            return nil
        }
        let rtt = localElapsed - coordinatorElapsed
        let localMidpoint = localSendNs + localElapsed / 2
        let coordinatorMidpoint =
            coordinatorReceiveNs + coordinatorElapsed / 2
        let offset = Int64(clamping: coordinatorMidpoint)
            &- Int64(clamping: localMidpoint)
        let candidate = CaptureClockMappingSample(
            probeID: probeID,
            localMidpointMonotonicNs: localMidpoint,
            coordinatorMidpointMonotonicNs: coordinatorMidpoint,
            offsetNs: offset,
            rttNs: rtt,
            uncertaintyNs: rtt / 2,
            sampledAtLocalMonotonicNs: localReceiveNs
        )
        candidates.append(candidate)
        candidates = candidates.filter {
            localReceiveNs >= $0.sampledAtLocalMonotonicNs
                && localReceiveNs - $0.sampledAtLocalMonotonicNs
                    <= CaptureCoordinationPolicy.clockFusionWindowNs
        }
        if candidates.count
            > CaptureCoordinationPolicy.maximumRetainedClockCandidates {
            candidates.removeFirst(
                candidates.count
                    - CaptureCoordinationPolicy.maximumRetainedClockCandidates
            )
        }

        guard let sample = fusedSample(endingAt: candidate),
              sample.uncertaintyNs
                <= CaptureCoordinationPolicy.maximumClockUncertaintyNs
        else { return nil }
        samples.append(sample)
        samples.sort {
            if $0.uncertaintyNs == $1.uncertaintyNs {
                return $0.sampledAtLocalMonotonicNs
                    > $1.sampledAtLocalMonotonicNs
            }
            return $0.uncertaintyNs < $1.uncertaintyNs
        }
        if samples.count > CaptureCoordinationPolicy
            .maximumRetainedClockSamples {
            samples.removeLast(
                samples.count
                    - CaptureCoordinationPolicy.maximumRetainedClockSamples
            )
        }
        return sample
    }

    func bestSample(nowLocalMonotonicNs: UInt64)
        -> CaptureClockMappingSample? {
        samples.first {
            $0.ageNs(nowLocalMonotonicNs: nowLocalMonotonicNs)
                <= CaptureCoordinationPolicy.maximumClockSampleAgeNs
        }
    }

    mutating func reset() {
        samples.removeAll()
        candidates.removeAll()
    }

    private func fusedSample(
        endingAt newest: CaptureClockMappingSample
    ) -> CaptureClockMappingSample? {
        guard !candidates.isEmpty else { return nil }
        var lowerBound = Int64.min
        var upperBound = Int64.max
        for candidate in candidates {
            let uncertainty = Int64(clamping: candidate.uncertaintyNs)
            lowerBound = max(
                lowerBound,
                candidate.offsetNs.subtractingReportingOverflow(uncertainty)
                    .overflow
                    ? Int64.min
                    : candidate.offsetNs - uncertainty
            )
            upperBound = min(
                upperBound,
                candidate.offsetNs.addingReportingOverflow(uncertainty)
                    .overflow
                    ? Int64.max
                    : candidate.offsetNs + uncertainty
            )
        }
        if lowerBound <= upperBound {
            let span = UInt64(upperBound - lowerBound)
            let uncertainty = span / 2
            if uncertainty
                <= CaptureCoordinationPolicy.maximumClockUncertaintyNs {
                let offset = lowerBound + Int64(clamping: uncertainty)
                return makeFusedSample(
                    newest: newest,
                    offset: offset,
                    uncertainty: uncertainty,
                    rtt: uncertainty * 2
                )
            }
        }

        guard candidates.count
            >= CaptureCoordinationPolicy.minimumClockFusionCandidates
        else {
            return candidates.min { $0.uncertaintyNs < $1.uncertaintyNs }
        }
        let offsets = candidates.map(\.offsetNs).sorted()
        let medianOffset = offsets[offsets.count / 2]
        let deviations = offsets.map { offset -> UInt64 in
            if offset >= medianOffset {
                return UInt64(offset - medianOffset)
            }
            return UInt64(medianOffset - offset)
        }.sorted()
        let medianDeviation = deviations[deviations.count / 2]
        let scaledDeviation = medianDeviation.multipliedReportingOverflow(by: 3)
        let uncertainty = max(
            CaptureCoordinationPolicy.statisticalClockUncertaintyFloorNs,
            scaledDeviation.overflow ? UInt64.max : scaledDeviation.partialValue
        )
        return makeFusedSample(
            newest: newest,
            offset: medianOffset,
            uncertainty: uncertainty,
            rtt: newest.rttNs
        )
    }

    private func makeFusedSample(
        newest: CaptureClockMappingSample,
        offset: Int64,
        uncertainty: UInt64,
        rtt: UInt64
    ) -> CaptureClockMappingSample? {
        let coordinatorMidpointSigned =
            Int64(clamping: newest.localMidpointMonotonicNs) &+ offset
        guard coordinatorMidpointSigned >= 0 else { return nil }
        return CaptureClockMappingSample(
            probeID: newest.probeID,
            localMidpointMonotonicNs: newest.localMidpointMonotonicNs,
            coordinatorMidpointMonotonicNs: UInt64(coordinatorMidpointSigned),
            offsetNs: offset,
            rttNs: rtt,
            uncertaintyNs: uncertainty,
            sampledAtLocalMonotonicNs: newest.sampledAtLocalMonotonicNs
        )
    }
}
