# whisper.cpp bridge (not yet vendored)

The Swift-side `WhisperCppEngine` is wired and conforms to `TranscriptionEngine`,
but the actual C library is not vendored in this repo. To enable it:

1. **Vendor the source.** From the project root:
   ```bash
   git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git /tmp/whisper.cpp
   mkdir -p Packages/VMTranscription/Sources/WhisperCppC
   cp /tmp/whisper.cpp/whisper.{cpp,h} Packages/VMTranscription/Sources/WhisperCppC/
   cp -R /tmp/whisper.cpp/ggml*.{c,h,m,cpp,metal} Packages/VMTranscription/Sources/WhisperCppC/
   ```

2. **Update `Package.swift`** in `Packages/VMTranscription/`:
   ```swift
   .target(
       name: "WhisperCppC",
       path: "Sources/WhisperCppC",
       resources: [.copy("ggml-metal.metal")],
       cSettings: [
           .define("GGML_USE_METAL"),
           .define("GGML_USE_ACCELERATE"),
           .unsafeFlags(["-O3"])
       ],
       linkerSettings: [
           .linkedFramework("Accelerate"),
           .linkedFramework("Metal"),
           .linkedFramework("MetalKit"),
           .linkedFramework("Foundation")
       ]
   ),
   ```
   Then add `WhisperCppC` to the `dependencies` of the `VMTranscription` target.

3. **Add a Swift shim** (`Sources/WhisperCppC/include/module.modulemap`):
   ```
   module WhisperCppC {
       header "../whisper.h"
       export *
   }
   ```

4. **Replace the bodies** of `loadModel`, `transcribeFile`, and the streaming
   inference path in `WhisperCppEngine.swift` with calls to:
   - `whisper_init_from_file_with_params(path, ctxParams)`
   - `whisper_full(ctx, params, samples, nSamples)`
   - `whisper_full_n_segments`, `whisper_full_get_segment_text`,
     `whisper_full_get_segment_t0/t1`, `whisper_full_get_token_data`
     for word-level timing.

5. **Use `StreamingTranscriber`** in `transcribeStream` to manage the 30 s sliding
   window — the same shape `WhisperKitEngine` already uses.

The catalog (`ModelCatalog`) already lists ggml model URLs from
`huggingface.co/ggerganov/whisper.cpp`, so download / install paths work the
moment the bridge is in place.
