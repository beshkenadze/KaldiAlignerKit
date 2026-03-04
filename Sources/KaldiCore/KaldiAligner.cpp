#include "KaldiAligner.hpp"

// Kaldi core
#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "matrix/kaldi-matrix.h"

// Features
#include "feat/feature-mfcc.h"
#include "feat/feature-functions.h"
#include "transform/cmvn.h"

// Models
#include "tree/context-dep.h"
#include "gmm/am-diag-gmm.h"
#include "hmm/transition-model.h"
#include "hmm/hmm-utils.h"

// Decoder
#include "decoder/training-graph-compiler.h"
#include "decoder/faster-decoder.h"
#include "gmm/decodable-am-diag-gmm.h"

// FST
#include "fstext/fstext-lib.h"
#include "lat/kaldi-lattice.h"

#include <fstream>
#include <sstream>
#include <unordered_map>
#include <vector>
#include <string>
#include <memory>
#include <cmath>
#include <algorithm>
#include <cctype>

static_assert(sizeof(kaldi::BaseFloat) == sizeof(float),
              "Kaldi BaseFloat must be float for zero-copy audio input");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Minimal meta.json parser — extracts only the fields we need.
struct ModelMeta {
    float silence_probability = 0.17f;
    float initial_silence_probability = 0.17f;
    bool use_energy = true;
    float dither = 0.0001f;
    float energy_floor = 1.0f;
};

static float ParseJsonFloat(const std::string& json, const std::string& key, float def) {
    auto pos = json.find("\"" + key + "\"");
    if (pos == std::string::npos) return def;
    pos = json.find(':', pos);
    if (pos == std::string::npos) return def;
    try { return std::stof(json.substr(pos + 1)); }
    catch (...) { return def; }
}

static bool ParseJsonBool(const std::string& json, const std::string& key, bool def) {
    auto pos = json.find("\"" + key + "\"");
    if (pos == std::string::npos) return def;
    pos = json.find(':', pos);
    if (pos == std::string::npos) return def;
    auto rest = json.substr(pos + 1, 10);
    if (rest.find("true") != std::string::npos) return true;
    if (rest.find("false") != std::string::npos) return false;
    return def;
}

static ModelMeta ParseModelMeta(const std::string& dir) {
    ModelMeta m;
    std::ifstream f(dir + "/meta.json");
    if (!f.is_open()) return m;
    std::string json((std::istreambuf_iterator<char>(f)),
                      std::istreambuf_iterator<char>());
    m.silence_probability = ParseJsonFloat(json, "silence_probability", 0.17f);
    m.initial_silence_probability = ParseJsonFloat(json, "initial_silence_probability", 0.17f);
    m.use_energy = ParseJsonBool(json, "use_energy", true);
    m.dither = ParseJsonFloat(json, "dither", 0.0001f);
    m.energy_floor = ParseJsonFloat(json, "energy_floor", 1.0f);
    return m;
}

struct DictEntry {
    std::string word;
    std::vector<std::string> phones;
};

static std::unordered_map<std::string, int32> ParsePhonesFile(
    const std::string& path)
{
    std::unordered_map<std::string, int32> phone_to_id;
    std::ifstream in(path);
    if (!in.is_open())
        KALDI_ERR << "Cannot open phones file: " << path;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        std::istringstream ss(line);
        std::string phone;
        int32 id;
        if (ss >> phone >> id)
            phone_to_id[phone] = id;
    }
    return phone_to_id;
}

static std::vector<DictEntry> ParseDictionary(const std::string& path)
{
    std::vector<DictEntry> entries;
    std::ifstream in(path);
    if (!in.is_open())
        KALDI_ERR << "Cannot open dictionary: " << path;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        // MFA dict format: word\tphones  OR  word\tp1\tp2\tp3\tp4\tphones
        // Use last tab to find phones column
        auto last_tab = line.rfind('\t');
        if (last_tab == std::string::npos) continue;
        auto first_tab = line.find('\t');
        DictEntry e;
        e.word = line.substr(0, first_tab);
        std::istringstream ss(line.substr(last_tab + 1));
        std::string ph;
        while (ss >> ph) e.phones.push_back(ph);
        if (!e.phones.empty()) entries.push_back(std::move(e));
    }
    return entries;
}

/// Build lexicon FST (L) from dictionary.
/// Structure: start→loop with optional initial silence;
/// for each word pronunciation loop→...→end→loop with optional inter-word silence.
static fst::VectorFst<fst::StdArc>* BuildLexiconFst(
    const std::unordered_map<std::string, int32>& word_to_id,
    const std::unordered_map<std::string, int32>& phone_to_id,
    const std::vector<DictEntry>& dict,
    int32 sil_phone,
    float sil_prob,
    float init_sil_prob)
{
    using Arc = fst::StdArc;
    using Weight = Arc::Weight;
    auto* L = new fst::VectorFst<Arc>();

    auto start = L->AddState();
    L->SetStart(start);
    auto loop = L->AddState();
    L->SetFinal(loop, Weight::One());

    // start → loop (with / without initial silence)
    if (init_sil_prob > 0.0f && init_sil_prob < 1.0f) {
        L->AddArc(start, Arc(sil_phone, 0,
                              Weight(-std::log(init_sil_prob)), loop));
        L->AddArc(start, Arc(0, 0,
                              Weight(-std::log(1.0f - init_sil_prob)), loop));
    } else {
        L->AddArc(start, Arc(0, 0, Weight::One(), loop));
    }

    float no_sil_cost = (sil_prob > 0.0f && sil_prob < 1.0f)
                            ? -std::log(1.0f - sil_prob) : 0.0f;
    float sil_cost    = (sil_prob > 0.0f && sil_prob < 1.0f)
                            ? -std::log(sil_prob) : 0.0f;

    for (const auto& entry : dict) {
        auto wit = word_to_id.find(entry.word);
        if (wit == word_to_id.end()) continue;
        int32 wid = wit->second;
        if (entry.phones.empty()) continue;

        // Verify all phones exist
        bool all_ok = true;
        for (const auto& ph : entry.phones) {
            if (phone_to_id.find(ph) == phone_to_id.end()) {
                all_ok = false;
                break;
            }
        }
        if (!all_ok) continue;

        auto cur = loop;
        for (size_t i = 0; i < entry.phones.size(); ++i) {
            int32 pid = phone_to_id.at(entry.phones[i]);
            int32 olabel = (i == 0) ? wid : 0;

            if (i < entry.phones.size() - 1) {
                auto next = L->AddState();
                L->AddArc(cur, Arc(pid, olabel, Weight::One(), next));
                cur = next;
            } else {
                // Last phone → intermediate state → back to loop
                auto end_st = L->AddState();
                L->AddArc(cur, Arc(pid, olabel, Weight::One(), end_st));
                L->AddArc(end_st, Arc(0, 0, Weight(no_sil_cost), loop));
                if (sil_prob > 0.0f && sil_prob < 1.0f) {
                    L->AddArc(end_st, Arc(sil_phone, 0,
                                          Weight(sil_cost), loop));
                }
            }
        }
    }
    return L;
}

/// UTF-8 aware: lowercase ASCII + Cyrillic, strip ASCII punctuation, keep all other Unicode.
static std::string CleanWord(const std::string& tok)
{
    std::string result;
    result.reserve(tok.size());
    size_t i = 0;
    while (i < tok.size()) {
        unsigned char c = tok[i];
        if (c < 0x80) {
            // ASCII: keep alpha and apostrophe, lowercase
            if (std::isalpha(c) || c == '\'')
                result += static_cast<char>(std::tolower(c));
            i++;
        } else {
            // Decode UTF-8 codepoint
            uint32_t cp = 0;
            int len = 0;
            if (c < 0xE0)      { cp = c & 0x1F; len = 2; }
            else if (c < 0xF0) { cp = c & 0x0F; len = 3; }
            else               { cp = c & 0x07; len = 4; }
            for (int j = 1; j < len && (i + j) < tok.size(); j++)
                cp = (cp << 6) | (tok[i + j] & 0x3F);
            // Cyrillic uppercase А-Я (U+0410-042F) → lowercase а-я
            if (cp >= 0x0410 && cp <= 0x042F) cp += 0x20;
            // Ё (U+0401) → ё (U+0451)
            else if (cp == 0x0401) cp = 0x0451;
            // Re-encode UTF-8
            if (cp < 0x80) {
                result += static_cast<char>(cp);
            } else if (cp < 0x800) {
                result += static_cast<char>(0xC0 | (cp >> 6));
                result += static_cast<char>(0x80 | (cp & 0x3F));
            } else if (cp < 0x10000) {
                result += static_cast<char>(0xE0 | (cp >> 12));
                result += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                result += static_cast<char>(0x80 | (cp & 0x3F));
            } else {
                result += static_cast<char>(0xF0 | (cp >> 18));
                result += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
                result += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                result += static_cast<char>(0x80 | (cp & 0x3F));
            }
            i += len;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Opaque handle
// ---------------------------------------------------------------------------

struct KaldiAlignerOpaque {
    kaldi::TransitionModel trans_model;
    kaldi::AmDiagGmm am_gmm;
    kaldi::ContextDependency ctx_dep;
    kaldi::Matrix<kaldi::BaseFloat> lda_mat;

    std::unique_ptr<kaldi::TrainingGraphCompiler> graph_compiler;
    ModelMeta meta;

    std::unordered_map<std::string, int32> word_to_id;
    std::vector<std::string> id_to_word;
    std::unordered_map<std::string, int32> phone_to_id;

    int32 sil_phone_id = 1;
    int32 spn_phone_id = 2;
    kaldi::BaseFloat acoustic_scale = 0.1;
    kaldi::BaseFloat beam = 10.0;
    kaldi::BaseFloat retry_beam = 40.0;

    std::string last_error;
};

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

KaldiAlignerRef kaldi_aligner_create(
    const char* model_dir,
    const char* dict_path)
{
    auto* a = new KaldiAlignerOpaque();
    try {
        std::string dir(model_dir);

        // 1. Phone mapping
        a->phone_to_id = ParsePhonesFile(dir + "/phones.txt");
        a->sil_phone_id = a->phone_to_id.at("sil");
        if (a->phone_to_id.count("spn"))
            a->spn_phone_id = a->phone_to_id.at("spn");

        // 2. Dictionary → word IDs
        auto dict = ParseDictionary(dict_path);
        int32 next_wid = 1;  // 0 = epsilon
        for (const auto& e : dict) {
            if (!a->word_to_id.count(e.word))
                a->word_to_id[e.word] = next_wid++;
        }
        // Add <unk> word mapped to spn phone (for OOV handling)
        if (!a->word_to_id.count("<unk>")) {
            a->word_to_id["<unk>"] = next_wid++;
            DictEntry unk_entry;
            unk_entry.word = "<unk>";
            unk_entry.phones.push_back("spn");
            dict.push_back(std::move(unk_entry));
        }
        a->id_to_word.resize(next_wid);
        a->id_to_word[0] = "<eps>";
        for (const auto& [w, id] : a->word_to_id)
            a->id_to_word[id] = w;

        // 3. Load acoustic model (TransitionModel + AmDiagGmm)
        {
            bool binary;
            kaldi::Input ki(dir + "/final.alimdl", &binary);
            a->trans_model.Read(ki.Stream(), binary);
            a->am_gmm.Read(ki.Stream(), binary);
        }

        // 4. Load tree
        {
            bool binary;
            kaldi::Input ki(dir + "/tree", &binary);
            a->ctx_dep.Read(ki.Stream(), binary);
        }

        // 5. Load LDA matrix
        {
            bool binary;
            kaldi::Input ki(dir + "/lda.mat", &binary);
            a->lda_mat.Read(ki.Stream(), binary);
        }

        // 6. Build lexicon FST
        auto* lex_fst = BuildLexiconFst(
            a->word_to_id, a->phone_to_id, dict,
            a->sil_phone_id,
            a->meta.silence_probability,
            a->meta.initial_silence_probability);

        // 7. Create graph compiler (takes ownership of lex_fst)
        kaldi::TrainingGraphCompilerOptions gopts;
        gopts.transition_scale = 0.0;  // MFA pattern: compile with 0/0, add probs separately
        gopts.self_loop_scale = 0.0;
        std::vector<int32> disambig_syms;

        a->graph_compiler = std::make_unique<kaldi::TrainingGraphCompiler>(
            a->trans_model, a->ctx_dep,
            lex_fst, disambig_syms, gopts);

        KALDI_LOG << "KaldiAligner initialized: "
                  << a->word_to_id.size() << " words, "
                  << a->phone_to_id.size() << " phones, "
                  << "LDA " << a->lda_mat.NumRows() << "x"
                  << a->lda_mat.NumCols();

    } catch (const std::exception& e) {
        a->last_error = std::string("Init failed: ") + e.what();
    }
    return a;
}

void kaldi_aligner_destroy(KaldiAlignerRef aligner) {
    delete aligner;
}

struct AlignmentResult kaldi_aligner_align(
    KaldiAlignerRef a,
    const float* audio_samples,
    int32_t num_samples,
    int32_t sample_rate,
    const char* transcript)
{
    struct AlignmentResult result = {nullptr, 0, nullptr};

    if (!a) {
        result.error = strdup("Null aligner");
        return result;
    }
    if (!a->last_error.empty()) {
        result.error = strdup(a->last_error.c_str());
        return result;
    }

    try {
        using namespace kaldi;

        // ---- 1. Wrap audio (zero-copy) ----
        SubVector<BaseFloat> wave(audio_samples, num_samples);

        // ---- 2. MFCC (params from meta.json) ----
        MfccOptions mfcc_opts;
        mfcc_opts.frame_opts.frame_shift_ms  = 10.0;
        mfcc_opts.frame_opts.frame_length_ms = 25.0;
        mfcc_opts.frame_opts.snip_edges      = false;
        mfcc_opts.frame_opts.dither          = a->meta.dither;
        mfcc_opts.frame_opts.preemph_coeff   = 0.97;
        mfcc_opts.frame_opts.samp_freq       = static_cast<BaseFloat>(sample_rate);
        mfcc_opts.mel_opts.low_freq  = 20.0;
        mfcc_opts.mel_opts.high_freq = 7800.0;
        mfcc_opts.mel_opts.num_bins  = 23;
        mfcc_opts.num_ceps       = 13;
        mfcc_opts.use_energy     = a->meta.use_energy;
        mfcc_opts.energy_floor   = a->meta.energy_floor;
        mfcc_opts.cepstral_lifter = 22.0;

        Mfcc mfcc(mfcc_opts);
        Matrix<BaseFloat> feats;
        mfcc.ComputeFeatures(wave, static_cast<BaseFloat>(sample_rate),
                             1.0, &feats);
        if (feats.NumRows() == 0) {
            result.error = strdup("No frames extracted from audio");
            return result;
        }

        // ---- 3. CMVN (per-utterance, mean only — MFA uses norm_vars=false) ----
        Matrix<double> cmvn_stats;
        InitCmvnStats(feats.NumCols(), &cmvn_stats);
        AccCmvnStats(feats, nullptr, &cmvn_stats);
        ApplyCmvn(cmvn_stats, false, &feats);

        // ---- 4. Splice features (context ±3 for LDA input) ----
        Matrix<BaseFloat> spliced_feats;
        SpliceFrames(feats, 3, 3, &spliced_feats);

        // ---- 5. LDA transform ----
        int32 lda_rows = a->lda_mat.NumRows();
        Matrix<BaseFloat> lda_feats(spliced_feats.NumRows(), lda_rows);
        lda_feats.AddMatMat(1.0, spliced_feats, kNoTrans,
                            a->lda_mat, kTrans, 0.0);

        // ---- 6. Parse transcript → word IDs (OOV → <unk>/spn) ----
        std::vector<int32> word_ids;
        std::vector<std::string> words_str;
        // Reserve a word ID for <unk> if not already present
        int32 unk_wid = 0;
        if (a->word_to_id.count("<unk>")) {
            unk_wid = a->word_to_id.at("<unk>");
        }
        {
            std::istringstream ss(transcript);
            std::string tok;
            while (ss >> tok) {
                std::string lower = CleanWord(tok);
                if (lower.empty()) continue;
                auto it = a->word_to_id.find(lower);
                if (it != a->word_to_id.end()) {
                    word_ids.push_back(it->second);
                    words_str.push_back(lower);
                } else {
                    // OOV word → map to <unk> (spn phone)
                    if (unk_wid != 0) {
                        word_ids.push_back(unk_wid);
                        words_str.push_back("<unk>");
                    }
                }
            }
        }
        if (word_ids.empty()) {
            result.error = strdup("No words found in dictionary");
            return result;
        }


        // ---- 7. Compile decoding graph ----
        fst::VectorFst<fst::StdArc> decode_fst;
        if (!a->graph_compiler->CompileGraphFromText(word_ids, &decode_fst)) {
            result.error = strdup("Graph compilation failed");
            return result;
        }

        // ---- 8. Add transition probabilities (MFA pattern) ----
        {
            std::vector<int32> disambig_syms;
            AddTransitionProbs(a->trans_model, disambig_syms,
                               1.0, 0.1, &decode_fst);
        }

        // ---- 9. Decode (FasterDecoder, mirror AlignUtteranceWrapper) ----
        DecodableAmDiagGmmScaled decodable(
            a->am_gmm, a->trans_model, lda_feats, a->acoustic_scale);

        FasterDecoderOptions dec_opts;
        dec_opts.beam = a->beam;
        FasterDecoder decoder(decode_fst, dec_opts);
        decoder.Decode(&decodable);

        bool reached = decoder.ReachedFinal();
        if (!reached && a->retry_beam > 0) {
            dec_opts.beam = a->retry_beam;
            decoder.SetOptions(dec_opts);
            decoder.Decode(&decodable);
            reached = decoder.ReachedFinal();
        }
        if (!reached) {
            result.error = strdup("Alignment failed: no final state reached");
            return result;
        }

        // ---- 10. Extract best path ----
        fst::VectorFst<LatticeArc> decoded_lat;
        decoder.GetBestPath(&decoded_lat);

        // Walk lattice: collect per-frame transition-ids and word labels
        struct FrameInfo { int32 tid; int32 word_id; };
        std::vector<FrameInfo> frames;
        int32 cur_word = 0;
        {
            auto state = decoded_lat.Start();
            while (state != fst::kNoStateId) {
                bool has_arc = false;
                for (fst::ArcIterator<fst::VectorFst<LatticeArc>>
                         aiter(decoded_lat, state);
                     !aiter.Done(); aiter.Next())
                {
                    const auto& arc = aiter.Value();
                    if (arc.olabel != 0) cur_word = arc.olabel;
                    if (arc.ilabel != 0) {
                        frames.push_back({arc.ilabel, cur_word});
                    }
                    state = arc.nextstate;
                    has_arc = true;
                    break;
                }
                if (!has_arc) break;
            }
        }

        // ---- 11. Extract word boundaries ----
        // Group consecutive frames by word_id; silence phones break groups
        struct WordBound {
            std::string word;
            float start;
            float end;
        };
        std::vector<WordBound> bounds;
        constexpr float kFrameShift = 0.01f;

        int32 prev_word = 0;
        int first_frame = -1;
        int last_frame = -1;

        for (int f = 0; f < static_cast<int>(frames.size()); ++f) {
            int32 phone = a->trans_model.TransitionIdToPhone(frames[f].tid);
            int32 wid = frames[f].word_id;

            // Silence/noise → close current word
            if (phone == a->sil_phone_id || phone == a->spn_phone_id) {
                if (prev_word != 0 && first_frame >= 0) {
                    bounds.push_back({a->id_to_word[prev_word],
                                      first_frame * kFrameShift,
                                      (last_frame + 1) * kFrameShift});
                    prev_word = 0;
                    first_frame = -1;
                }
                continue;
            }

            // New word?
            if (wid != 0 && wid != prev_word) {
                if (prev_word != 0 && first_frame >= 0) {
                    bounds.push_back({a->id_to_word[prev_word],
                                      first_frame * kFrameShift,
                                      (last_frame + 1) * kFrameShift});
                }
                prev_word = wid;
                first_frame = f;
            }
            last_frame = f;
        }
        // Close trailing word
        if (prev_word != 0 && first_frame >= 0) {
            bounds.push_back({a->id_to_word[prev_word],
                              first_frame * kFrameShift,
                              (last_frame + 1) * kFrameShift});
        }

        // ---- 12. Build C result ----
        result.count = static_cast<int32_t>(bounds.size());
        if (result.count > 0) {
            result.intervals = static_cast<struct WordInterval*>(
                malloc(result.count * sizeof(struct WordInterval)));
            for (int32_t i = 0; i < result.count; ++i) {
                result.intervals[i].word =
                    strdup(bounds[i].word.c_str());
                result.intervals[i].start_time = bounds[i].start;
                result.intervals[i].end_time   = bounds[i].end;
            }
        }
    } catch (const std::exception& e) {
        result.error = strdup(e.what());
    }
    return result;
}

void kaldi_aligner_free_result(struct AlignmentResult r) {
    if (r.intervals) {
        for (int32_t i = 0; i < r.count; ++i)
            free(const_cast<char*>(r.intervals[i].word));
        free(r.intervals);
    }
    if (r.error) free(const_cast<char*>(r.error));
}

const char* kaldi_aligner_last_error(KaldiAlignerRef aligner) {
    if (!aligner) return "Null aligner";
    return aligner->last_error.empty() ? nullptr
                                       : aligner->last_error.c_str();
}
