import XCTest
@testable import BrickCore

final class PersonMaskTests: XCTestCase {
    /// A 4 x 3 mask over a 400 x 300 image: each mask pixel covers 100 x 100 image pixels. The person (a hand coming in
    /// from the right) covers the right-hand column and the middle of the column next to it.
    let mask = PersonMask(width: 4, height: 3, values: [0, 0, 0, 255,
                                                         0, 0, 255, 255,
                                                         0, 0, 0, 255])!

    func testBoxesAreMappedFromImageToMaskPixels() {
        XCTAssertEqual(mask.share(minX: 0, minY: 0, maxX: 200, maxY: 300, imageWidth: 400, imageHeight: 300), 0)
        XCTAssertEqual(mask.share(minX: 300, minY: 0, maxX: 400, maxY: 300, imageWidth: 400, imageHeight: 300), 1)
        // The right half: 4 of its 6 mask pixels.
        XCTAssertEqual(mask.share(minX: 200, minY: 0, maxX: 400, maxY: 300, imageWidth: 400, imageHeight: 300), 4 / 6, accuracy: 1e-6)
        // A box smaller than one mask pixel reads the pixel under its middle.
        XCTAssertEqual(mask.share(minX: 210, minY: 120, maxX: 230, maxY: 140, imageWidth: 400, imageHeight: 300), 1)
        XCTAssertEqual(mask.share(minX: 210, minY: 20, maxX: 230, maxY: 40, imageWidth: 400, imageHeight: 300), 0)
        // The same box in an image of another size maps to the same mask pixels.
        XCTAssertEqual(mask.share(minX: 2100, minY: 1200, maxX: 2300, maxY: 1400, imageWidth: 4000, imageHeight: 3000), 1)
        // Outside the image: nothing.
        XCTAssertEqual(mask.share(minX: 500, minY: 0, maxX: 600, maxY: 100, imageWidth: 400, imageHeight: 300), 0)
        XCTAssertNil(PersonMask(width: 4, height: 3, values: [0, 0]))
    }

    func blob(_ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int) -> DetectedBlob {
        DetectedBlob(minX: minX, minY: minY, maxX: maxX, maxY: maxY, area: (maxX - minX + 1) * (maxY - minY + 1),
                     cx: Float(minX + maxX) / 2, cy: Float(minY + maxY) / 2, major: Float(maxX - minX + 1),
                     minor: Float(maxY - minY + 1), r: 0, g: 0, b: 0)
    }

    func testDetectionsUnderTheHandAreDropped() {
        // Work frame 40 x 30 (step 10): a piece on the left, one under the hand, one only touching it.
        let blobs = [blob(2, 2, 6, 6), blob(32, 12, 36, 16), blob(17, 10, 21, 19)]
        let result = HandMasking.filter(blobs, mask: mask, step: 10, imageWidth: 400, imageHeight: 300)
        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.kept.map { $0.minX }, [2, 17])
        XCTAssertEqual(HandMasking.filter(blobs, mask: nil, step: 10, imageWidth: 400, imageHeight: 300).kept.count, 3)
        XCTAssertEqual(mask.share(of: blobs[1], step: 10, imageWidth: 400, imageHeight: 300), 1)
    }

    func testAHandOverAPieceIsNoEvidenceThatItIsGone() {
        // 640 x 480 view of the table from 30 cm, as in VisibilityTests; the hand covers the right quarter of the image.
        let width: Float = 640, height: Float = 480, f: Float = 640
        let projector = TableProjector(fx: f, fy: f, cx: width / 2, cy: height / 2, camera: lookingDown(from: SIMD3(0, 0.3, 0)), tableY: 0)
        var values = [UInt8](repeating: 0, count: 64 * 48)
        for y in 0..<48 { for x in 48..<64 { values[y * 64 + x] = 255 } }
        let hand = PersonMask(width: 64, height: 48, values: values)!
        let tracker = PieceTracker()
        var ledger = VisibilityLedger()
        let left = PieceObservation(position: SIMD3(-0.05, 0, 0), longMm: 16, shortMm: 8, r: 200, g: 30, b: 30, quality: 1)
        let right = PieceObservation(position: SIMD3(0.10, 0, 0), longMm: 16, shortMm: 8, r: 30, g: 30, b: 200, quality: 1)
        // Both seen three times, then the hand comes over the right one for ten frames.
        for i in 0..<13 {
            tracker.beginFrame()
            let matched = tracker.observe(frame: i < 3 ? [left, right] : [left], time: Double(i) * 0.2)
            let occluded = i < 3 ? [] : HandMasking.occluded(pieces: tracker.pieces, projector: projector, mask: hand,
                                                               imageWidth: width, imageHeight: height)
            if i >= 3 { XCTAssertEqual(occluded.count, 1) }
            ledger.record(view: projector, imageWidth: width, imageHeight: height, pieces: tracker.pieces,
                          matched: Set(matched.compactMap { $0?.id }), occluded: occluded)
            tracker.endFrame(time: Double(i) * 0.2)
        }
        let hidden = tracker.pieces.first { $0.position.x > 0 }!
        XCTAssertEqual(ledger.entry(hidden.id).misses, 0)
        XCTAssertFalse(ledger.isDoubtful(hidden.id))
        // Without the mask the same frames would have set it aside.
        var plain = VisibilityLedger()
        for _ in 0..<3 { plain.hit(hidden.id) }
        for _ in 0..<10 { plain.miss(hidden.id) }
        XCTAssertTrue(plain.isDoubtful(hidden.id))
        // Where it should appear: 0.10 m right of centre at 0.3 m with f = 640 is 213 px right of centre.
        let box = HandMasking.imageBox(of: hidden, projector: projector, margin: 0)!
        XCTAssertEqual((box.minX + box.maxX) / 2, 320 + 213.3, accuracy: 0.5)
        XCTAssertEqual(box.maxX - box.minX, 0.016 * 640 / 0.3, accuracy: 0.5)
    }
}

final class TrackingRecoveryTests: XCTestCase {
    func testRelocalisingAfterAnInterruption() {
        var recovery = TrackingRecovery()
        XCTAssertTrue(recovery.canMatch(.normal))
        XCTAssertNil(recovery.hint(.normal))
        recovery.interrupted()
        XCTAssertEqual(recovery.hint(.normal), "Camera paused.")
        recovery.interruptionEnded()
        // ARKit relocalises for 3 s, then is back.
        for t in stride(from: 10.0, through: 13.0, by: 0.5) {
            recovery.update(.relocalizing, time: t)
            XCTAssertFalse(recovery.canMatch(.relocalizing))
            XCTAssertFalse(recovery.offerFreshPass)
            XCTAssertTrue(recovery.hint(.relocalizing)!.hasPrefix("Finding its place again"))
        }
        recovery.update(.normal, time: 13.2)
        XCTAssertEqual(recovery.phase, .tracking)
        XCTAssertTrue(recovery.canMatch(.normal))
    }

    func testNoMatchingUntilTrackingIsNormalAgain() {
        var recovery = TrackingRecovery()
        recovery.interrupted()
        recovery.interruptionEnded()
        recovery.update(.initializing, time: 1)
        XCTAssertFalse(recovery.canMatch(.normal), "still relocalising, even if one frame says normal before update")
        recovery.update(.normal, time: 1.2)
        XCTAssertTrue(recovery.canMatch(.normal))
        XCTAssertFalse(recovery.canMatch(.excessiveMotion))
    }

    func testOfferAFreshPassWhenRelocalisingTakesTooLong() {
        var recovery = TrackingRecovery(relocaliseTimeout: 5)
        recovery.interrupted()
        recovery.interruptionEnded()
        recovery.update(.relocalizing, time: 100)
        recovery.update(.relocalizing, time: 104.9)
        XCTAssertFalse(recovery.offerFreshPass)
        recovery.update(.relocalizing, time: 105.1)
        XCTAssertTrue(recovery.offerFreshPass)
        XCTAssertTrue(recovery.hint(.relocalizing)!.contains("start a fresh pass"))
        // The user waits on; ARKit finds its place after all: the offer goes.
        recovery.keepTrying()
        XCTAssertFalse(recovery.offerFreshPass)
        recovery.update(.relocalizing, time: 106)
        recovery.update(.relocalizing, time: 110)
        XCTAssertFalse(recovery.offerFreshPass)
        recovery.update(.relocalizing, time: 111.5)
        XCTAssertTrue(recovery.offerFreshPass)
        recovery.update(.normal, time: 112)
        XCTAssertFalse(recovery.offerFreshPass)
        XCTAssertTrue(recovery.canMatch(.normal))
        // Or chooses a fresh pass.
        recovery.interrupted()
        recovery.interruptionEnded()
        recovery.update(.relocalizing, time: 200)
        recovery.update(.relocalizing, time: 206)
        XCTAssertTrue(recovery.offerFreshPass)
        recovery.startedFreshPass()
        recovery.update(.initializing, time: 206.2)
        XCTAssertEqual(recovery.phase, .tracking)
        XCTAssertTrue(recovery.hint(.initializing)!.hasPrefix("Getting started"))
    }

    func testARKitRelocalisingByItselfIsWaitedForToo() {
        var recovery = TrackingRecovery()
        recovery.update(.relocalizing, time: 5)
        XCTAssertFalse(recovery.canMatch(.normal))
        recovery.update(.relocalizing, time: 11)
        XCTAssertTrue(recovery.offerFreshPass)
    }

    func testEveryLimitedReasonHasItsOwnHint() {
        let hints = [TrackingCondition.initializing, .excessiveMotion, .insufficientFeatures, .relocalizing, .notAvailable]
            .map { TrackingRecovery.hint(for: $0) }
        XCTAssertEqual(Set(hints.compactMap { $0 }).count, 5)
        XCTAssertTrue(TrackingRecovery.hint(for: .excessiveMotion)!.contains("Slow down"))
        XCTAssertTrue(TrackingRecovery.hint(for: .insufficientFeatures)!.contains("light"))
    }
}

final class ExposurePlanTests: XCTestCase {
    func testShutterForTwoWorkingPixelsAtTheAllowedSpeed() {
        // 4K: fx about 2,800 for the wide camera, 6 full pixels per working pixel; 30 cm over the table.
        let fourK = ExposurePlan.longestExposure(fx: 2800, step: 6, distance: 0.30)
        XCTAssertEqual(fourK, 2 * 6 * 0.30 / (2800 * 0.30), accuracy: 1e-9)
        XCTAssertEqual(fourK * 1000, 4.29, accuracy: 0.01)      // about 1/233 s
        // 1920 x 1440: half the focal length and half the step: the same.
        XCTAssertEqual(ExposurePlan.longestExposure(fx: 1400, step: 3, distance: 0.30), fourK, accuracy: 1e-9)
        // Nearer the table the picture moves faster, so the shutter must be shorter; not below the 20 cm floor.
        XCTAssertLessThan(ExposurePlan.longestExposure(fx: 2800, step: 6, distance: 0.20), fourK)
        XCTAssertEqual(ExposurePlan.longestExposure(fx: 2800, step: 6, distance: 0.05),
                       ExposurePlan.longestExposure(fx: 2800, step: 6, distance: 0.20))
    }

    func testDecisions() {
        let longest = 0.0043
        XCTAssertEqual(ExposurePlan.decide(duration: 0.002, iso: 100, longest: longest, minDuration: 1e-5, minISO: 32, maxISO: 3000), .lock)
        // Indoors at 1/60 s and ISO 200: 1/233 s needs about ISO 776.
        guard case let .custom(duration, iso) = ExposurePlan.decide(duration: 1.0 / 60, iso: 200, longest: longest,
                                                                     minDuration: 1e-5, minISO: 32, maxISO: 3000) else {
            return XCTFail("expected a custom exposure")
        }
        XCTAssertEqual(duration, longest)
        XCTAssertEqual(iso, 200 * Float(1.0 / 60 / longest), accuracy: 0.1)
        // A dim room at 1/30 s and ISO 640 would need about ISO 5,000: keep auto, suggest the light.
        guard case let .tooDark(needed) = ExposurePlan.decide(duration: 1.0 / 30, iso: 640, longest: longest,
                                                               minDuration: 1e-5, minISO: 32, maxISO: 6000) else {
            return XCTFail("expected too dark")
        }
        XCTAssertGreaterThan(needed, 4900)
        // The format's own ISO ceiling counts too.
        if case .custom = ExposurePlan.decide(duration: 1.0 / 60, iso: 200, longest: longest, minDuration: 1e-5, minISO: 32, maxISO: 500) {
            XCTFail("over the format's maximum ISO")
        }
    }
}

final class StillRequestTests: XCTestCase {
    func testOneStillEveryTwoSecondsServesEveryWaitingPiece() {
        var stills = StillRequests()
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertFalse(stills.shouldCapture(time: 0), "nobody waiting")
        XCTAssertTrue(stills.want(a, time: 0))
        XCTAssertTrue(stills.want(b, time: 0.2))
        XCTAssertTrue(stills.shouldCapture(time: 0.2))
        XCTAssertFalse(stills.shouldCapture(time: 0.4), "one under way")
        stills.captured(served: [a])                 // b was not in the still
        XCTAssertTrue(stills.done.contains(a))
        XCTAssertFalse(stills.want(a, time: 0.6), "a piece gets one still")
        XCTAssertTrue(stills.isWaiting(b))
        XCTAssertFalse(stills.shouldCapture(time: 1.0), "rate limit")
        XCTAssertTrue(stills.shouldCapture(time: 2.2))
        stills.captured(served: [])
        // b has waited more than 4 s: it goes ahead with its video crop.
        XCTAssertEqual(stills.expired(time: 4.1), [])
        XCTAssertEqual(stills.expired(time: 4.3), [b])
        XCTAssertFalse(stills.isWaiting(b))
        // A session that cannot capture stills hands every waiting piece back and stops asking.
        XCTAssertTrue(stills.want(c, time: 5))
        XCTAssertTrue(stills.shouldCapture(time: 5))
        XCTAssertEqual(stills.failed(permanently: true), [c])
        XCTAssertFalse(stills.available)
        XCTAssertFalse(stills.want(UUID(), time: 6))
    }

    func testAPassingFailureKeepsThePiecesWaiting() {
        var stills = StillRequests()
        let a = UUID()
        _ = stills.want(a, time: 0)
        XCTAssertTrue(stills.shouldCapture(time: 0))
        XCTAssertEqual(stills.failed(permanently: false), [])
        XCTAssertTrue(stills.isWaiting(a))
        XCTAssertTrue(stills.shouldCapture(time: 2))
    }

    func testCropOfAPieceInAStillFromAnotherViewpoint() {
        // A 4032 x 3024 still, fx 3000, 30 cm above the table, 5 cm to the side of the piece.
        let projector = TableProjector(fx: 3000, fy: 3000, cx: 2016, cy: 1512, camera: lookingDown(from: SIMD3(-0.05, 0.3, 0)), tableY: 0)
        let square = StillCrop.square(position: SIMD3(0, 0, 0), longMm: 16, heightMm: 0, projector: projector,
                                      imageWidth: 4032, imageHeight: 3024)!
        XCTAssertEqual(square.centreX, 2016 + 0.05 * 3000 / 0.3, accuracy: 0.5)
        XCTAssertEqual(square.centreY, 1512, accuracy: 0.5)
        XCTAssertEqual(square.side, 0.016 * 3000 / 0.3 / 0.7, accuracy: 0.5)   // 229 px: the piece fills 70%
        // A tall piece is cropped around its middle, which is nearer the camera.
        let tall = StillCrop.square(position: SIMD3(0, 0, 0), longMm: 16, heightMm: 40, projector: projector,
                                    imageWidth: 4032, imageHeight: 3024)!
        XCTAssertEqual(tall.centreX, 2016 + 0.05 * 3000 / 0.28, accuracy: 0.5)
        // Not wholly in the still: no crop.
        XCTAssertNil(StillCrop.square(position: SIMD3(0.25, 0, 0), longMm: 16, heightMm: 0, projector: projector,
                                      imageWidth: 4032, imageHeight: 3024))
    }
}

final class HandReplayTests: XCTestCase {
    /// The camera holds still over the tiny sweep; from frame 3 a hand rests on the middle piece. With negative evidence
    /// and no mask, the hidden piece is set aside and the fingertip is counted; with the mask, neither.
    func testHandMaskingKeepsHiddenPiecesAndDropsTheFingertip() throws {
        let cameras: [(x: Float, time: Double)] = (0..<10).map { (-0.03, Double($0) * 0.2) }
        let sweep = ReplayRunnerTests.sweep(cameras: cameras)
        let images = sweep.frames.map { ReplayRunnerTests.render(sweep, frame: $0) }
        var settings = ReplayRunner.Settings()
        settings.matchWholeFrame = true
        settings.negativeEvidence = true
        var hand = HandSimulation(position: SIMD2(0, 0), firstFrame: 3)
        hand.radius = 0.02
        settings.hand = hand
        var reports: [Bool: ReplayScoring.Report] = [:]
        for masking in [false, true] {
            settings.handMasking = masking
            let run = try ReplayRunner.run(sweep: sweep, detector: .truth, settings: settings) { index in
                ReplayFrameData(rgba: images[index].rgba, ids: images[index].ids)
            }
            XCTAssertEqual(run.handFrames, 7)
            if masking { XCTAssertEqual(run.handDropped, 7, "the fingertip, every frame") }
            reports[masking] = ReplayScoring.report(sweep: sweep, run: run, detector: .truth)
        }
        let plain = reports[false]!, masked = reports[true]!
        XCTAssertEqual(plain.found, masked.found - 1, "the piece under the hand is set aside without the mask")
        XCTAssertEqual(plain.piecesCounted, masked.piecesCounted, "one piece lost, one fingertip gained")
        XCTAssertEqual(masked.phantom + masked.countedTwice, 0)
        XCTAssertEqual(masked.found, masked.piecesCouldBeSeen)
    }
}
