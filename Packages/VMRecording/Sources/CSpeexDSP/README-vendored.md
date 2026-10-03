# Vendored: SpeexDSP 1.2.1

Subset of https://github.com/xiph/speexdsp (tag `SpeexDSP-1.2.1`, tarball sha256
`d17ca363654556a4ff1d02cc13d9eb1fc5a8642c90b40bd54ce266c3807b91a7`), BSD-3-Clause — see `COPYING`.

Files are unmodified copies from `libspeexdsp/` and `include/speex/`:
`mdf.c` (multi-delay-block-frequency echo canceller), `preprocess.c` (noise/residual-echo
suppressor), `fftwrap.c`, `smallft.c`, `filterbank.c` and the headers they include.
Built as floating point with the built-in FFT (`FLOATING_POINT`, `USE_SMALLFT`; see Package.swift).
Resampler, jitter buffer, kiss FFT and fixed-point headers are intentionally not vendored.
