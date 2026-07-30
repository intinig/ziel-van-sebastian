# Fish Audio TTS backend (with sentence batching)

Date: 2026-07-30

## Goal

Replace ElevenLabs with fish.audio as the default TTS provider to cut synthesis
cost, without discarding the working ElevenLabs path and without making
sentence-to-sentence prosody drift worse than it is today.

fish.audio `s2.1-pro` bills $15 per 1M UTF-8 bytes. ElevenLabs list pricing is
$50/1M characters (Flash/Turbo) and $100/1M (Multilingual v2/v3). For ASCII
English, bytes ≈ characters, so this is roughly a 3–7x reduction.

## Non-goals

**End-to-end voice latency is explicitly out of scope.** The round trip from
"Sebastian, <request>" to Ziel responding feels slow, and that is a separate,
larger project. One diagnostic finding is recorded here so the latency project
starts from evidence rather than guesses: during the wait the face sits in
**amber (thinking) for a long time**, which places the dominant delay *upstream
of text* — OpenClaw session wake, LLM time-to-first-token, or tool use — not in
the TTS layer.

This spec still carries a hard constraint from that finding: since the wait is
already the felt pain, **nothing here may increase time-to-first-audio**. That
constraint kills one otherwise-attractive design (see Rejected alternatives).

Also out of scope: streaming playback (starting audio before a sentence's
synthesis completes), voice cloning, and fish's ASR or Voice Design endpoints.

## Current state

`ElevenLabsTTS` (220 lines) is two unrelated things in one class:

- ~45 lines of ElevenLabs-specific HTTP: `makeRequest`, `parseResponse`, `fetch`
- ~120 lines of provider-agnostic playback: the `AVAudioEngine`/`AVAudioPlayerNode`
  graph, the `.AVAudioEngineConfigurationChange` rebuild, and output-device
  pinning for the PowerConf (hardware AEC)

`SpeechCoordinator` fetches one sentence per request, up to
`maxConcurrentFetches = 2`, and plays strictly in order. `Director` feeds a
`SentenceChunker` progressively (`Director.swift:298`) and enqueues each sentence
the moment it completes, so Ziel starts speaking sentence 1 while OpenClaw is
still writing sentence 3.

### Why drift is visible today

Each sentence is an independent generation. The only glue is ElevenLabs'
`previous_request_ids`, and with a concurrency cap of 2 it applies unevenly:
sentences 1 and 2 launch together carrying no ids, sentence 3 carries `[id1]`,
sentence 4 carries `[id1, id2]`. So roughly 60–70% of sentence boundaries get
*some* conditioning and the rest get none — hence the existing
`// stitching is best-effort by design` comment, and hence the audible drift.

## Verified fish.audio API facts

Checked against the live production spec at `https://api.fish.audio/openapi.json`.

- `POST https://api.fish.audio/v1/tts/stream/with-timestamp`
- Auth `Authorization: Bearer <key>`; **`model` is a required HTTP header**
  (`s1`, `s2-pro`, `s2.1-pro`, `s2.1-pro-free`), not a body field
- Body (`Content-Type: application/json`): `text`, `reference_id` (voice),
  `format` (`wav`/`pcm`/`mp3`/`opus`), `sample_rate`, `latency`
  (`low`/`normal`/`balanced`), `prosody: {speed: 0.5–2.0, volume}`,
  `temperature` (default 0.7), `top_p`, `chunk_length` (100–300),
  `condition_on_previous_chunks` (default true), `normalize`
- Response is **SSE** (`text/event-stream`). Each `data:` line is a JSON object:
  `audio_base64`, `content`, `alignment: {segments: [{text, start, end}],
  audio_duration}`, `chunk_seq`, `chunk_audio_offset_sec`
- `alignment` is a **cumulative snapshot per `chunk_seq`** — clients must
  *replace* the previous snapshot for that chunk, never append. Segment
  `start`/`end` are relative to the chunk; add `chunk_audio_offset_sec` for
  absolute time
- Segments are word-level, so no character-grouping step is needed — but their
  text is punctuation- and apostrophe-stripped (`I can't believe it's` →
  `I / cant / its`), so it is **not** usable as display text
- **No cross-request continuity mechanism.** A full re-grep of the spec found no
  `request_id`, `previous_request_ids`, `history`, `session_id`, `continue_from`,
  or `prefix_audio`; `seed` exists only on Voice Design.
  `condition_on_previous_chunks` conditions only on chunks *within one request*
- Voices: `reference_id` is a 32-hex voice-model id; list with `GET /model`
  (the id field is `_id`, not `id`)

### Not verified from their docs — resolve empirically

- PCM bit depth, endianness, and channel count are documented nowhere.
  16-bit signed LE mono is the near-certain de-facto format, but it must be
  confirmed with one real request before trusting `AVAudioEngine` buffers
- Accepted `sample_rate` values (the spec puts no enum on the field), so whether
  24000 works at all is unconfirmed
- Whether omitting `reference_id` yields a default voice

## Design

### 1. Split fetch from playback

| File | Change |
|---|---|
| `Sources/Speech/AudioPlayback.swift` | **New.** `final class AudioPlayback`, holding `play`/`stopPlayback`, the engine/player pair, the configuration-change observer, `appliedDeviceID`, and `outputDeviceName` — moved verbatim out of `ElevenLabsTTS`. Already config-free: `play` reads `sampleRate` off the `SpokenAudio`. |
| `Sources/Speech/TTSFetching.swift` | **New.** The provider seam, plus the shared `TTSError { httpStatus(Int), malformedResponse }`. |
| `Sources/Speech/TTSService.swift` | **New.** `final class TTSService: SpeechSynthesizing` composing one `TTSFetching` + one `AudioPlayback`, forwarding `outputDeviceName` to the player so `AppDelegate:275`'s live reload keeps working. |
| `Sources/Speech/ElevenLabsTTS.swift` → `ElevenLabsFetcher.swift` | Keeps `makeRequest`/`parseResponse`/`fetch`, loses the audio half. Existing tests touch only the statics, so they need the new type name and nothing else. |
| `Sources/Speech/FishAudioFetcher.swift` | **New.** Same static-request/static-parse shape. |
| `Sources/Speech/SpokenAudioSplitter.swift` | **New.** Pure function splitting one batch `SpokenAudio` into per-sentence pieces. |
| `Sources/Core/AlignmentMapper.swift` | Gains `reconcile` (below), next to the existing `words(from: ElevenLabsAlignment)`. |

Composition over a shared base class or a duplicated synthesizer: the audio code
is the most fragile part of this module (it has already produced one OOM crash
from a lost playback completion), so it must exist exactly once.

### 2. Batching for continuity, without delaying the first sound

`SpeechCoordinator` coalesces queued sentences into a single TTS request. One
request covering several sentences is one generation context, which is genuine
continuity rather than stitching.

The batching rule protects time-to-first-audio:

- If nothing is playing, ready, or in flight — the start of a reply — fetch
  **exactly one** sentence. Time-to-first-audio is therefore identical to today.
- Otherwise coalesce up to `maxBatchSentences = 4` from `fetchQueue` into one
  request.

Batch size depends on how much text has arrived by the time a fetch slot frees
up. Early in a reply that may be very little — the second fetch can easily be a
single sentence, leaving the first boundaries unbatched — and batches grow as
playback falls behind generation. So the realistic gain is boundaries per reply
dropping from N−1 to roughly 1–3, not to exactly one. That is still strictly
better than today, where *every* boundary is a separate generation with at best
partial stitching, and it holds for either provider.

`maxConcurrentFetches` stays 2, now counting batched fetches.

**Risk: batching trades per-fetch latency for continuity.** A 4-sentence batch
takes longer to synthesize than a 1-sentence request. If a batch fetch outlasts
the audio currently playing, playback stalls mid-reply — a gap, not a failure
(the display keeps pacing), but audible. `maxBatchSentences = 4` is a starting
value chosen to bound this, and validation listens for mid-reply gaps
specifically. If gaps appear, the cap comes down.

### 3. The seam becomes batch-shaped

```swift
protocol TTSFetching: AnyObject {
    func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String],
               completion: @escaping (Result<[SpokenAudio], Error>) -> Void)
}
```

One `SpokenAudio` out per `SpeechRequest` in, in order, so `Director`'s
per-sentence `speechQueue` is untouched — it never learns that batching exists.
`SpeechSynthesizing.fetch` changes identically.

### 4. Word timings: reconcile onto our own tokens

`WordTiming.text` is what the face displays, so fish's stripped segment text
cannot be used directly. Timings come from the provider; text comes from us.

`AlignmentMapper.reconcile(_ timings: [WordTiming], displayTokens: [String]) -> [WordTiming]`:

- equal counts (the common case) → adopt each display token's text with the
  provider segment's `start`/`end`
- counts differ → distribute the total span across tokens proportional to
  character length, and log both counts

Proportional rather than index-aligning the first N: one dropped token makes
index alignment progressively wrong for the remainder of the sentence, whereas
proportional is uniformly slightly off.

**This function is what makes batching exact.** It guarantees exactly one
`WordTiming` per display token, so splitting a batch's word list at sentence
boundaries is always well-defined. Both providers route through it — for
ElevenLabs it is a no-op in the common case, since its character alignment is
derived from our own input text.

A smarter mismatch path exists (normalize both sides to lowercase alphanumerics,
then greedy-match). It is deliberately deferred: mismatch frequency is unknown,
so the live probe measures it and we add matching only if the data justifies it.

### 5. Splitting a batch back into sentences

`SpokenAudioSplitter.split(_ audio: SpokenAudio, tokenCounts: [Int]) -> [SpokenAudio]`

- split the word list at the cumulative token counts (exact, per §4)
- cut PCM at the sample offset of the next sentence's first word start
- slice the envelope proportionally at `envelopeRate`
- rebase each piece's word times to zero, since `Director.speechStarted` stamps
  `startedAt` when that piece begins playing

Audio is generated as one continuous take, so the pieces share prosody even
though they are played as separate buffers with the coordinator's existing
`sentencePauseMs` gap between them.

### 6. Fish request

```json
{ "text": "…", "reference_id": "…", "format": "pcm",
  "sample_rate": 24000, "latency": "balanced",
  "temperature": 0.6, "prosody": { "speed": 1.0 } }
```

24 kHz matches the existing playback path. `temperature` is pinned below fish's
0.7 default to reduce take-to-take variance — a cheap complement to batching.
`speed` is clamped to fish's 0.5–2.0 range. `timeoutInterval` stays 10s;
URLSession treats it as an idle-between-packets limit, which is safe for SSE.

### 7. Response parsing

The coordinator plays whole sentences, so `fetch` uses a plain `dataTask` and
parses the complete SSE body once — no `URLSessionDataDelegate`, and
`parseResponse(Data, batch:) throws -> [SpokenAudio]` stays a pure static
function testable from fixtures, exactly like the ElevenLabs one.

1. split the body into SSE events, joining multi-line `data:` payloads
2. concatenate `audio_base64` in arrival order → PCM
3. keep `[chunk_seq: (segments, offset)]`, last write wins (replace, never append)
4. flatten in `chunk_seq` order, adding `chunk_audio_offset_sec` for absolute times
5. `reconcile` onto the batch's display tokens
6. `split` by per-sentence token counts
7. envelope per piece via the existing `AmplitudeEnvelope`

`SpokenAudio.requestID` is always `nil` on this path, so
`previousRequestIDs` stays permanently empty for fish and the parameter is
ignored.

### 8. Config

```json
"speech": {
  "enabled": false,
  "provider": "fish",
  "speed": 1.0,
  "volume": 1.0,
  "elevenlabs": { "apiKey": "", "voiceId": "JBFqnCBsd6RMkjVDRZzb",
                  "modelId": "eleven_flash_v2_5", "languageCode": null },
  "fish": { "apiKey": "", "referenceId": "", "model": "s2.1-pro",
            "latency": "balanced", "temperature": 0.6 }
}
```

`enabled`, `provider`, `speed`, and `volume` stay provider-agnostic; only
credentials, voice, and model nest. `speed` is clamped per provider (ElevenLabs
0.7–1.2, fish 0.5–2.0).

Three deliberate decisions:

1. **An unknown `provider` string does not throw.** `Config`'s decoder uses
   `decodeIfPresent ?? default` throughout; a strict enum would make one typo
   fail the entire config load, taking the gateway token with it. It decodes as
   `String`, mapping unknown values to the default plus an `NSLog`.
2. **No legacy shim for flat `speech.apiKey`/`voiceId`, but they are not ignored
   silently.** Since fish is the default, the appliance config needs editing
   regardless; the decoder logs when it sees the old flat keys so the failure
   mode is an explanatory log line rather than speech mysteriously stopping.
3. **Startup validation is provider-specific.** The existing URL-path-safety
   check on `voiceId` exists only because ElevenLabs puts it in the URL path;
   fish's `referenceId` travels in the JSON body and only needs to be non-empty.

### 9. Failure handling

The invariant is that TTS never blocks the face, so every failure lands on an
existing degradation path:

- missing `fish.apiKey` or `referenceId` at startup → no `TTSService`,
  display-only pacing, log naming the specific missing key
- HTTP 401/402/422, timeout, malformed SSE, empty PCM, zero words → `fetch`
  fails → `speechFailed`, and three consecutive failures open the existing
  circuit breaker. Fish's 402 (payment required) gets its own log line, since a
  dry account is a distinct and likely cause
- a failed **batch** fails every id it covered, and counts as one failure
  against the breaker — it was one HTTP call
- wrong PCM assumptions cannot degrade gracefully: a float32 or wrong-rate
  response produces noise or a chipmunk voice rather than an error. This is why
  the live probe is a required step

## Implementation phasing

Two phases, so the drift improvement is verifiable before the provider swap and
the batch-shaped seam is designed once with the batch shape already known.

**Phase 1 — extraction and batching, still on ElevenLabs.** Split
`AudioPlayback`/`TTSFetching`/`TTSService` out of `ElevenLabsTTS`, add
`reconcile` and `SpokenAudioSplitter`, make the seam batch-shaped, and teach
`SpeechCoordinator` to coalesce. Ends with `make test` green and a `make run`
listening test against today's drift, on the provider already in use. If
batching does not audibly help, that is discovered here — before any of the fish
work depends on it.

**Phase 2 — the fish provider.** `FishAudioFetcher`, the config reshape,
provider-specific startup validation, docs, and the live validation checklist.

## Rejected alternatives

**fish WebSocket session (`wss://api.fish.audio/v1/tts/live`).** This *is* a real
continuity mechanism — config is set once per session via `StartEvent`, text
arrives as `TextEvent`s, and `condition_on_previous_chunks` is session-scoped.
Rejected because its server→client messages are exactly two, `audio` and
`finish`: no alignment, no timestamps, confirmed against both the AsyncAPI docs
and fish's official SDK. Word timings drive the entire RSVP face. It also
narrows the model enum to `s1`/`s2-pro` only, and the cross-`TextEvent`
continuity is inferred from session-scoped config rather than documented.

**Whole-reply batching** (one request per reply, per-sentence display driven by
`chunk_seq`/`content`). Strongest continuity with timestamps intact, but speech
could not start until the full reply text arrived — directly against the
latency constraint. Rejected for that reason alone.

**Passing the previous sentence's audio as a `references` entry.** fish scopes
`references` to voice *identity*; their voice-cloning guidance wants references
neutral and uniform ("avoid big changes in volume or emotion"), i.e. the pipeline
is built to extract timbre while discarding the prosodic specifics we would be
trying to carry. It also forces MessagePack and re-uploads audio every sentence.

**A standalone `FishAudioTTS: SpeechSynthesizing`.** Duplicates the engine, the
route-change observer, and device pinning — the code most likely to need a
future fix, in two places that will drift.

**Base class with `fetch` overridden.** Same deduplication as composition, but
Swift has no `protected`, so the shared state would have to widen to `internal`.

## Accepted regressions

- No cross-request continuity on the fish path. Batching more than compensates
  versus today's partial stitching, but a batch boundary is still a boundary.
- `SpokenAudio.requestID` is always `nil` for fish.
- Non-ASCII text costs more on fish, which bills UTF-8 bytes rather than
  characters.

## Testing

The extraction must be provably behavior-preserving: `make test` (161 tests)
stays green, with `ElevenLabsTTSTests` changing only the type name.

New unit tests, all fixture-driven against pure functions:

- **fish `makeRequest`**: URL, `Authorization: Bearer`, the `model` header, body
  fields, speed clamped to 0.5–2.0, temperature present
- **SSE parsing**: multi-event body; multi-line `data:` payloads; the
  replace-not-append snapshot rule (a later event for the same `chunk_seq` must
  supersede the earlier segment list, not concatenate); `chunk_audio_offset_sec`
  making times absolute across chunks; malformed and empty bodies throwing
  rather than yielding silent garbage
- **`reconcile`**: equal counts adopt our token text (`can't` / `it's` is the
  regression test); mismatched counts distribute proportionally; the result is
  always 1:1 with tokens
- **`split`**: word lists cut at the right boundaries, times rebased to zero,
  PCM and envelope lengths consistent, single-sentence batch is identity
- **coordinator batching**: first request of a reply is exactly one sentence;
  subsequent fetches coalesce up to the cap; a failed batch fails every id it
  covered and counts once against the breaker; `cancelAll` mid-batch discards
  via the generation guard

## Live validation

Requires the fish API key. Ordered so each step de-risks the next:

1. One real request; dump the PCM and confirm 16-bit LE mono at 24 kHz, and that
   `sample_rate: 24000` is accepted at all
2. Pick a `reference_id` by auditioning the fish.audio voice library in a browser
   (it has playable samples; `GET /model` returns metadata only). Document
   `GET /model?self=true` in the ops docs for listing cloned voices
3. Log segment-count vs token-count over a handful of real replies, to decide
   whether the normalized-matching upgrade from §4 is needed
4. Measure `balanced` vs `low` latency to confirm the default
5. `make run` end-to-end, listening for two things specifically: drift at batch
   boundaries versus the ElevenLabs baseline, and mid-reply gaps caused by a
   batch fetch outlasting the audio playing ahead of it
6. Appliance run on the Mac mini with the PowerConf, confirming device pinning
   still holds through `AudioPlayback`

## Docs

`config.example.json` gets the new shape. The README speech section gets setup
for both providers, the fish-is-now-default upgrade note, and the drift/latency
notes. `CLAUDE.md`'s `Sources/Speech/` architecture line needs updating, since
`ElevenLabsTTS` no longer exists as the synthesizer.
