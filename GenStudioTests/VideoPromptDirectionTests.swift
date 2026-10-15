import XCTest
@testable import GenStudio

/// The Video Prompt node writes one flowing, present-tense shot description that video models read well:
/// action first, then a precise camera move, look and sound. Higgsfield-style camera presets and shot
/// recipes are one click; older saved nodes keep working.
final class VideoPromptDirectionTests: XCTestCase {
    private func settings(_ mode: VideoPromptMode = .imageToVideo, action: String = "The barber trims the client's beard.") -> VideoPromptSettings {
        var value = VideoPromptSettings(); value.mode = mode; value.action = action
        return value
    }

    func testAnActionThatEndsWithAFullStopIsNotDoubled() {
        let prompt = settings(action: "The man stands up and then lifts the clipboard to his chest.").compiledPrompt
        XCTAssertTrue(prompt.contains("The man stands up and then lifts the clipboard to his chest."), prompt)
        XCTAssertFalse(prompt.contains(".."), prompt)
        XCTAssertFalse(prompt.contains(" ."), prompt)
    }

    func testEveryCameraMoveBecomesAPreciseDirection() {
        for move in VideoCameraMove.all {
            var value = settings(); value.cameraMovement = move.title
            let prompt = value.compiledPrompt
            XCTAssertTrue(prompt.contains(move.direction), "\(move.title): \(prompt)")
            XCTAssertGreaterThan(move.direction.split(separator: " ").count, 6, "\(move.title) says how the camera moves, not just its name")
        }
        var orbit = settings(); orbit.cameraMovement = "Slow orbit"
        XCTAssertTrue(orbit.compiledPrompt.contains("arcs slowly around the subject"), orbit.compiledPrompt)
    }

    func testHiggsfieldStyleMovesAreOffered() {
        let titles = Set(VideoCameraMove.all.map(\.title))
        for title in ["Crash zoom", "Whip pan", "FPV fly-through", "Drone fly-over", "Product turntable", "Hero low angle", "Lead in front", "Tilt up reveal"] {
            XCTAssertTrue(titles.contains(title), title)
        }
        XCTAssertEqual(Set(VideoCameraMove.all.map(\.group)), Set(VideoCameraMove.Group.allCases))
    }

    func testCameraNamesSavedByOlderVersionsStillWork() {
        let saved = ["Static locked camera", "Gentle push in", "Pull back reveal", "Pan", "Tilt", "Lateral tracking", "Follow behind", "Slow orbit", "Crane up", "Crane down", "Handheld", "Rack focus"]
        for title in saved { XCTAssertNotNil(VideoCameraMove.named(title), title) }
        var custom = settings(); custom.cameraMovement = "Slow dolly left past the shop window"
        XCTAssertTrue(custom.compiledPrompt.contains("Slow dolly left past the shop window."), "A move written by hand passes through: \(custom.compiledPrompt)")
    }

    func testAStillCameraHasNoPaceSentence() {
        var still = settings(); still.cameraMovement = "Static locked camera"; still.cameraPace = "Energetic"
        XCTAssertFalse(still.compiledPrompt.contains("The camera moves with energy"), still.compiledPrompt)
        var push = settings(); push.cameraMovement = "Gentle push in"; push.cameraPace = "Steady"
        XCTAssertTrue(push.compiledPrompt.contains("The camera moves steadily."), push.compiledPrompt)
        push.cameraPace = "Natural"
        XCTAssertFalse(push.compiledPrompt.contains("The camera moves"), "Natural adds nothing to act on: \(push.compiledPrompt)")
    }

    func testImageToVideoSkipsPreserveFillerAndKeepsTheStartingImage() {
        let prompt = settings().compiledPrompt
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("preserve the established"), prompt)
        XCTAssertTrue(prompt.contains("as in the starting image"), prompt)
        XCTAssertTrue(prompt.hasPrefix("The barber trims"), "The action leads: \(prompt)")
    }

    func testTextToVideoDescribesTheSceneBeforeTheAction() {
        var value = settings(.textToVideo, action: "She pours coffee into a white cup.")
        value.subjectScene = "A young barista in a sunny Cape Town café"
        value.framing = "Close-up"
        let prompt = value.compiledPrompt
        XCTAssertTrue(prompt.hasPrefix("Close-up. A young barista in a sunny Cape Town café. She pours coffee"), prompt)
        XCTAssertFalse(prompt.contains("starting image"), prompt)
    }

    func testChosenLookIsDescribedAndPreserveIsNot() {
        var value = settings(.textToVideo)
        value.lighting = "Warm golden-hour light"; value.visualLook = "Clean commercial"; value.mood = "Warm and inviting"
        XCTAssertTrue(value.compiledPrompt.contains("Warm golden-hour light, clean commercial look, warm and inviting mood."), value.compiledPrompt)
    }

    func testSoundIsDescribedWithASpokenLineInQuotes() {
        var value = settings()
        value.ambience = "Busy street outside"; value.music = "Upbeat acoustic guitar"
        value.speaker = "The barber"; value.spokenLine = "Fresh cuts all weekend!"
        let prompt = value.compiledPrompt
        XCTAssertTrue(prompt.contains("Sound: busy street outside, upbeat acoustic guitar."), prompt)
        XCTAssertTrue(prompt.contains(#"The barber says, "Fresh cuts all weekend!""#), prompt)
    }

    func testNoSoundSentenceWithoutSound() {
        XCTAssertFalse(settings().compiledPrompt.contains("Sound:"))
        XCTAssertFalse(settings().compiledPrompt.contains("says,"))
    }

    func testASpokenLineWithoutASpeakerStillReadsNaturally() {
        var value = settings(); value.spokenLine = "Book today"
        XCTAssertTrue(value.compiledPrompt.contains(#"A voice says, "Book today.""#), value.compiledPrompt)
    }

    func testLongSpokenLinesAreFlaggedForAFiveSecondClip() {
        var value = settings()
        value.spokenLine = "Come visit us this weekend for a fresh cut and a hot towel shave"
        XCTAssertTrue(value.spokenLineIsLong)
        value.spokenLine = "Fresh cuts all weekend"
        XCTAssertFalse(value.spokenLineIsLong)
    }

    func testTimelineBeatsReadInOrder() {
        var value = settings()
        value.openingBeat = "the client sits down"; value.middleBeat = "the clippers buzz"; value.endingBeat = "he smiles at the mirror"
        XCTAssertTrue(value.compiledPrompt.contains("First, the client sits down. Then the clippers buzz. Finally, he smiles at the mirror."), value.compiledPrompt)
    }

    func testShotRecipesSetTheDirectionButNotTheStory() {
        XCTAssertGreaterThanOrEqual(VideoShotRecipe.all.count, 6)
        for recipe in VideoShotRecipe.all {
            var value = settings(); value.subjectScene = "A barbershop in Soweto"
            value.apply(recipe)
            XCTAssertEqual(value.action, "The barber trims the client's beard.", recipe.title)
            XCTAssertEqual(value.subjectScene, "A barbershop in Soweto", recipe.title)
            XCTAssertNotNil(VideoCameraMove.named(value.cameraMovement), "\(recipe.title) picks a real camera move")
            XCTAssertTrue(VideoPromptSettings.framings.contains(value.framing), recipe.title)
            XCTAssertTrue(VideoPromptSettings.lightings.contains(value.lighting), recipe.title)
        }
    }

    func testANodeSavedByAnOlderVersionStillOpensAndCompiles() throws {
        // The owner's own saved node from "06. Audition", before sound and presets existed.
        let json = #"{"action":"The man stands up and then lifts the clipboard to his chest.","avoid":"","cameraMovement":"Gentle push in","cameraPace":"Natural","continuity":"","endingBeat":"","focus":"Keep the main subject in focus","framing":"Medium shot","lighting":"Preserve the established lighting","middleBeat":"","mode":"imageToVideo","mood":"Calm and cinematic","motionStyle":"Slow motion feel","openingBeat":"","outputIntent":"One continuous short shot","subjectScene":"","visualLook":"Preserve the established visual style"}"#
        let saved = try JSONDecoder().decode(VideoPromptSettings.self, from: Data(json.utf8))
        XCTAssertEqual(saved.mode, .imageToVideo)
        XCTAssertEqual(saved.spokenLine, ""); XCTAssertEqual(saved.ambience, ""); XCTAssertEqual(saved.music, "")
        XCTAssertTrue(saved.compiledPrompt.hasPrefix("The man stands up"), saved.compiledPrompt)
        let roundTrip = try JSONDecoder().decode(VideoPromptSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(roundTrip, saved)
    }

    func testAnEmptyActionStillProducesNoPrompt() {
        XCTAssertEqual(settings(action: "  ").compiledPrompt, "")
    }

    func testStartEndAndReworkModesSayWhatTheModelMustDo() {
        XCTAssertTrue(settings(.startEndVideo).compiledPrompt.contains("no cuts"))
        XCTAssertTrue(settings(.videoToVideo).compiledPrompt.contains("source clip"))
    }
}
