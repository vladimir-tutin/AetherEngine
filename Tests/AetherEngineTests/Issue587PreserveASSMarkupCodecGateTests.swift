import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#587: `LoadOptions.preserveASSMarkup` is documented as ASS/SSA only. The sidecar path gates on
/// the codec inside `SubtitleDecoder.StreamDecode`; the embedded path gates in
/// `EmbeddedSubtitleDecoder.init` rather than at the emit site, which is what made the report read
/// the emit branch as ungated. This drives both codecs through the real demuxer and decoder so the
/// contract is checked where a host can observe it: the cue body.
///
/// Fixture: a 3.1 KB Matroska with one video stream and TWO text subtitle streams, one subrip and
/// one ASS, so the same session decodes both under one flag. Regenerate with:
///
///     printf '1\n00:00:01,000 --> 00:00:02,000\nplain srt line\n\n2\n00:00:03,000 --> 00:00:04,000\nsecond srt line\n' > en.srt
///     # st.ass: [Script Info] PlayResX 1920 / PlayResY 1080, one Default style, two Dialogue lines,
///     # the first wrapped in {\i1}...{\i0}
///     ffmpeg -f lavfi -i color=c=black:s=16x16:r=1:d=5 -i en.srt -i st.ass \
///       -map 0:v -map 1:0 -map 2:0 -c:v libx264 -preset ultrafast -crf 51 -pix_fmt yuv420p -c:s copy \
///       -metadata:s:s:0 language=eng -metadata:s:s:1 language=ger ass-srt.mkv
///
/// Stream layout: 0 = h264 video, 1 = subrip (eng), 2 = ass (ger).
struct Issue587PreserveASSMarkupCodecGateTests {

    static let subripStreamIndex: Int32 = 1
    static let assStreamIndex: Int32 = 2

    /// Decode every packet of `streamIndex` and return the text bodies in order.
    private func textBodies(streamIndex: Int32, preserveASSMarkup: Bool) throws -> [String] {
        guard let data = Data(base64Encoded: Self.base64.joined()) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        defer { demuxer.close() }

        guard let stream = demuxer.stream(at: streamIndex),
              let decoder = EmbeddedSubtitleDecoder(stream: stream,
                                                    sourceVideoWidth: 16,
                                                    sourceVideoHeight: 16,
                                                    preserveASSMarkup: preserveASSMarkup)
        else { throw CocoaError(.fileReadCorruptFile) }

        var bodies: [String] = []
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == streamIndex,
               let event = decoder.decode(packet: pkt, streamTimeBase: stream.pointee.time_base) {
                for cue in event.cues {
                    switch cue.body {
                    case .text(let t): bodies.append(t)
                    case .richText(let runs): bodies.append(runs.map(\.text).joined())
                    case .image: break
                    }
                }
            }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        return bodies
    }

    @Test("an embedded SubRip track stays plain text under preserveASSMarkup")
    func subripIgnoresTheFlag() throws {
        // libavcodec normalises subrip through ff_ass_add_rect, so the rect carries an ASS payload
        // and an ungated emit site would hand the host the nine-field event line instead.
        let bodies = try textBodies(streamIndex: Self.subripStreamIndex, preserveASSMarkup: true)
        #expect(bodies == ["plain srt line", "second srt line"])
        for body in bodies {
            #expect(!body.contains("Default,,"), "raw ASS event-line header fields reached the host")
        }
    }

    @Test("an embedded SubRip track reads the same with the flag off")
    func subripFlagOffMatches() throws {
        let on = try textBodies(streamIndex: Self.subripStreamIndex, preserveASSMarkup: true)
        let off = try textBodies(streamIndex: Self.subripStreamIndex, preserveASSMarkup: false)
        #expect(on == off, "the flag must not change a non-ASS track at all")
    }

    @Test("an embedded ASS track does carry the raw event line under the flag")
    func assKeepsMarkup() throws {
        // The other half of the contract: the flag has to still do its job where it applies, or the
        // gate would be indistinguishable from the flag being ignored everywhere.
        let bodies = try textBodies(streamIndex: Self.assStreamIndex, preserveASSMarkup: true)
        #expect(bodies.count == 2)
        #expect(bodies.first?.contains("{\\i1}styled ass line") == true)
        #expect(bodies.first?.contains("Default,,") == true, "the nine header fields are the payload here")
    }

    @Test("the same ASS track is extracted to plain text with the flag off")
    func assStripsMarkupWithoutTheFlag() throws {
        let bodies = try textBodies(streamIndex: Self.assStreamIndex, preserveASSMarkup: false)
        #expect(bodies == ["styled ass line", "second ass line"])
    }

    static let base64 = [
        "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAIqBFNm3TAv4QrfW8sTbuLU6uEFUmpZlOs",
        "gaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIID9k27jFOrhBxTu2tTrIIIPOwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsu/hGgSNtMq",
        "17GDD0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJCPeE8EHmuABm0oRQcXzDF5RImIQLOIAAAAAAAWVK5rQv+/",
        "hPOx60iuAQAAAAAAAIDXgQFzxYg7nQ/xtPepTpyBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OBASPjg4Q7msoA4JCwgRC6",
        "gRCagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAAY6KlAULACv/hABVnQsAK2nsBEAAAAwAQAAADACDxImoBAAVozgGXIK4BAAAAAAAA",
        "LNeBAnPFiK/xeUwsbVg6nIEAIrWcg2VuZ4aLU19URVhUL1VURjiDgRFV7oEArgEAAAAAAAIy14EDc8WIHdtZg7FvYdCcgQAitZyD",
        "Z2VyiIEAhopTX1RFWFQvQVNTg4ERVe6BAGOiQgBbU2NyaXB0IEluZm9dClNjcmlwdFR5cGU6IHY0LjAwKwpQbGF5UmVzWDogMTky",
        "MApQbGF5UmVzWTogMTA4MAoKW1Y0KyBTdHlsZXNdCkZvcm1hdDogTmFtZSwgRm9udG5hbWUsIEZvbnRzaXplLCBQcmltYXJ5Q29s",
        "b3VyLCBTZWNvbmRhcnlDb2xvdXIsIE91dGxpbmVDb2xvdXIsIEJhY2tDb2xvdXIsIEJvbGQsIEl0YWxpYywgVW5kZXJsaW5lLCBT",
        "dHJpa2VPdXQsIFNjYWxlWCwgU2NhbGVZLCBTcGFjaW5nLCBBbmdsZSwgQm9yZGVyU3R5bGUsIE91dGxpbmUsIFNoYWRvdywgQWxp",
        "Z25tZW50LCBNYXJnaW5MLCBNYXJnaW5SLCBNYXJnaW5WLCBFbmNvZGluZwpTdHlsZTogRGVmYXVsdCxBcmlhbCw0OCwmSDAwRkZG",
        "RkZGLCZIMDAwMDAwRkYsJkgwMDAwMDAwMCwmSDAwMDAwMDAwLDAsMCwwLDAsMTAwLDEwMCwwLDAsMSwyLDAsMiwxMCwxMCwxMCwx",
        "CgpbRXZlbnRzXQpGb3JtYXQ6IExheWVyLCBTdGFydCwgRW5kLCBTdHlsZSwgTmFtZSwgTWFyZ2luTCwgTWFyZ2luUiwgTWFyZ2lu",
        "ViwgRWZmZWN0LCBUZXh0ChJUw2dA7b+Eq9mN/nNzoGPAgGfImkWjh0VOQ09ERVJEh41MYXZmNjIuMTIuMTAxc3PXY8CLY8WIO50P",
        "8bT3qU5nyKJFo4dFTkNPREVSRIeVTGF2YzYyLjI4LjEwMSBsaWJ4MjY0Z8ihRaOIRFVSQVRJT05Eh5MwMDowMDowNS4wMDAwMDAw",
        "MDAAc3OyY8CLY8WIr/F5TCxtWDpnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjA0LjAwMDAwMDAwMABzc7JjwItjxYgd21mDsW9h0GfI",
        "oUWjiERVUkFUSU9ORIeTMDA6MDA6MDQuMDAwMDAwMDAwAB9DtnVDTb+EBemaSOeBAKNCaIEAAIAAAAJTBgX//0/cRem95tlIt5Ys",
        "2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAw",
        "My0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2Nr",
        "PTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFu",
        "Z2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJv",
        "bWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRl",
        "PTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5",
        "aW50PTI1MCBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj01MS4wIHFj",
        "b21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAAlliIQ6JigAFcCjjYED6AAA",
        "AAAFQZogFKWgmKGSggPoAHBsYWluIHNydCBsaW5lm4ID6KC3obGDA+gAMCwwLERlZmF1bHQsLDAsMCwwLCx7XGkxfXN0eWxlZCBh",
        "c3MgbGluZXtcaTB9m4ID6KONgQfQAAAAAAVBmkAVpaONgQu4AAAAAAVBmmAVpaCZoZOCC7gAc2Vjb25kIHNydCBsaW5lm4ID6KCt",
        "oaeDC7gAMSwwLERlZmF1bHQsLDAsMCwwLCxzZWNvbmQgYXNzIGxpbmWbggPoo42BD6AAAAAABUGagBWlHFO7a+e/hKOkdm27j7OB",
        "ALeK94EB8YIE6fCBCbums4ID6LeP94EC8YIE6fCCAoOyggPot4/3gQPxggTp8IICnbKCA+i7prOCC7i3j/eBAvGCBOnwggL0soID",
        "6LeP94ED8YIE6fCCAw+yggPo",
    ]
}
