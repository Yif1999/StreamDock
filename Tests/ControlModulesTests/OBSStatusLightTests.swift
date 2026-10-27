import Testing
import DockCore
@testable import ControlModules

@MainActor
struct OBSStatusLightTests {
    @Test func recordingBreathesWithoutGoingDarkAndPauseIsAmber() {
        let light = OBSStatusLight(state: OBSOutputState(recording: true))
        let bright = light.colors(at: 0.5, ledCount: 24)
        let dim = light.colors(at: 1.5, ledCount: 24)
        #expect(bright.allSatisfy { $0 == OBSStatusLight.recordingColor })
        #expect(dim[0].red >= 127 && dim[0].red <= 128)
        let paused = OBSStatusLight(state: OBSOutputState(recording: true, paused: true))
        #expect(paused.isActive)
        #expect(paused.colors(at: 0.5, ledCount: 24) == paused.colors(at: 1.5, ledCount: 24))
        #expect(paused.colors(at: 0.5, ledCount: 24)[0] == OBSStatusLight.pausedColor)
    }

    @Test func simultaneousOutputsSplitRingAndBarsWithSynchronizedBreath() {
        let light = OBSStatusLight(state: OBSOutputState(recording: true, streaming: true))
        let colors = light.colors(at: 0.5, ledCount: 24)
        #expect(colors[LightLayout.leftBar] == OBSStatusLight.recordingColor)
        #expect(colors[LightLayout.rightBar] == OBSStatusLight.streamingColor)
        // Split by where the LEDs sit: the middle falls between 5/6 (front) and 16/17 (back).
        for index in [0, 1, 4, 5, 17, 21] {
            #expect(colors[LightLayout.ring[index]].red > colors[LightLayout.ring[index]].green)
        }
        for index in [6, 10, 11, 12, 15, 16] {
            #expect(colors[LightLayout.ring[index]].green > colors[LightLayout.ring[index]].red)
        }
        let paused = OBSStatusLight(state: OBSOutputState(recording: true, paused: true, streaming: true))
        #expect(paused.colors(at: 1.5, ledCount: 24)[LightLayout.leftBar] == OBSStatusLight.pausedColor)
        #expect(paused.colors(at: 1.5, ledCount: 24)[LightLayout.rightBar] != OBSStatusLight.streamingColor)
    }

    @Test func streamingIsGreenAndMusicPauseStaysActive() {
        let stream = OBSStatusLight(state: OBSOutputState(streaming: true))
        #expect(stream.colors(at: 0.5, ledCount: 24).allSatisfy { $0 == OBSStatusLight.streamingColor })
        let music = MusicGlow(palette: [Swatch(.white, share: 1)])
        #expect(music.isActive)
        // Paused music still shows its glow: no extra global dimming on top.
        music.playing = false
        #expect(music.isActive)
    }
}
