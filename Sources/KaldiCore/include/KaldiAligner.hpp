#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KaldiAlignerOpaque* KaldiAlignerRef;

struct WordInterval {
    const char* word;
    float start_time;
    float end_time;
};

struct AlignmentResult {
    struct WordInterval* intervals;
    int32_t count;
    const char* error;
};

/// Create aligner from MFA model directory and dictionary file.
/// model_dir: path to extracted MFA model (contains final.mdl, tree, lda.mat)
/// dict_path: path to pronunciation dictionary (word\tphone1 phone2...)
/// Returns NULL on failure (check kaldi_aligner_last_error).
KaldiAlignerRef kaldi_aligner_create(
    const char* model_dir,
    const char* dict_path);

void kaldi_aligner_destroy(KaldiAlignerRef aligner);

/// Perform forced alignment.
/// audio_samples: raw PCM float samples (mono, should be 16kHz)
/// num_samples: number of samples
/// sample_rate: sample rate in Hz
/// transcript: space-separated words to align
struct AlignmentResult kaldi_aligner_align(
    KaldiAlignerRef aligner,
    const float* audio_samples,
    int32_t num_samples,
    int32_t sample_rate,
    const char* transcript);

void kaldi_aligner_free_result(struct AlignmentResult result);

/// Returns last error message, or NULL if no error.
const char* kaldi_aligner_last_error(KaldiAlignerRef aligner);

#ifdef __cplusplus
}
#endif
