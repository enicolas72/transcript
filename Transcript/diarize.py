#!/usr/bin/env python3
"""Speaker diarization using resemblyzer embeddings + spectral clustering.

Strategy:
  1. Coarse windowed embeddings → spectral clustering → speaker profiles
  2. Split each Whisper segment at sentence punctuation into sub-segments
  3. Compute one embedding per sub-segment → assign to nearest speaker profile
  4. Run-length smoothing to absorb noisy short runs

This approach ensures speaker changes only happen at sentence boundaries,
matching natural conversation patterns.
"""
import os
os.environ["LOKY_MAX_CPU_COUNT"] = "1"
import sys
import io
import re
import contextlib
import json
import numpy as np
from pathlib import Path
from resemblyzer import VoiceEncoder, preprocess_wav
from sklearn.cluster import SpectralClustering
from sklearn.metrics.pairwise import cosine_similarity
import warnings
warnings.filterwarnings("ignore")


def load_audio(path):
    return preprocess_wav(Path(path))


def load_whisper_json(path):
    with open(path) as f:
        return json.load(f)


# ---------- Step 1: Coarse clustering to discover speakers ----------

def compute_windowed_embeddings(encoder, wav, sr=16000, window_sec=1.5, step_sec=0.5):
    window_samples = int(window_sec * sr)
    step_samples = int(step_sec * sr)
    embeddings = []
    pos = 0
    while pos + window_samples <= len(wav):
        embeddings.append(encoder.embed_utterance(wav[pos:pos + window_samples]))
        pos += step_samples
    if pos < len(wav) and len(wav) - pos > sr:
        embeddings.append(encoder.embed_utterance(wav[pos:]))
    return np.array(embeddings)


def cluster_embeddings(embeddings, n_speakers=None, max_speakers=6):
    if n_speakers is not None:
        n = n_speakers
    else:
        from sklearn.metrics import silhouette_score
        best_k, best_score = 2, -1
        for k in range(2, min(max_speakers + 1, len(embeddings))):
            sc = SpectralClustering(n_clusters=k, affinity='cosine', random_state=0, n_jobs=1)
            labels = sc.fit_predict(embeddings)
            score = silhouette_score(embeddings, labels, metric='cosine')
            if score > best_score:
                best_score = score
                best_k = k
        n = best_k
        print(f"Auto-detected {n} speakers (silhouette={best_score:.3f})", file=sys.stderr)
    sc = SpectralClustering(n_clusters=n, affinity='cosine', random_state=0, n_jobs=1)
    return sc.fit_predict(embeddings)


def build_speaker_profiles(embeddings, labels):
    profiles = {}
    for emb, label in zip(embeddings, labels):
        label = int(label)
        profiles.setdefault(label, []).append(emb)
    return {k: np.mean(v, axis=0) for k, v in profiles.items()}


# ---------- Step 2: Split whisper segments at punctuation ----------

def split_at_punctuation(words, min_words=3):
    """Split a list of words into sub-segments at sentence-ending punctuation."""
    subs = []
    current = []
    for w in words:
        current.append(w)
        if re.search(r'[.?!]$', w['word'].strip()):
            if len(current) >= min_words:
                subs.append(current)
                current = []
    # Handle remainder
    if current:
        if subs and len(current) < min_words:
            subs[-1].extend(current)
        else:
            subs.append(current)
    return subs if subs else [words]


# ---------- Step 3: Assign sub-segments to speakers ----------

def assign_subsegments(encoder, wav, whisper_segments, speaker_profiles, sr=16000):
    """For each whisper segment, split at punctuation, compute embedding
    per sub-segment, and assign to the nearest speaker profile."""
    profile_ids = sorted(speaker_profiles.keys())
    profile_matrix = np.array([speaker_profiles[k] for k in profile_ids])

    labeled_words = []

    for seg in whisper_segments:
        words = seg.get('words', [])
        if not words:
            continue

        subs = split_at_punctuation(words)

        for sub in subs:
            start_sec = sub[0]['start']
            end_sec = sub[-1]['end']

            start_sample = max(0, int(start_sec * sr))
            end_sample = min(len(wav), int(end_sec * sr))
            chunk = wav[start_sample:end_sample]

            # Ensure minimum audio length for reliable embedding
            min_samples = int(0.5 * sr)
            if len(chunk) < min_samples:
                center = (start_sample + end_sample) // 2
                start_sample = max(0, center - min_samples // 2)
                end_sample = min(len(wav), start_sample + min_samples)
                chunk = wav[start_sample:end_sample]

            emb = encoder.embed_utterance(chunk)
            sims = cosine_similarity([emb], profile_matrix)[0]
            speaker = profile_ids[int(np.argmax(sims))]
            conf = float(np.sort(sims)[-1] - np.sort(sims)[-2]) if len(sims) > 1 else 1.0

            for w in sub:
                labeled_words.append({
                    'word': w['word'],
                    'start': w['start'],
                    'end': w['end'],
                    'speaker': speaker,
                    'confidence': conf,
                })

    return labeled_words


# ---------- Step 4: Smoothing ----------

def carry_across_continuations(labeled_words, all_subs):
    """If a sub-segment continues an incomplete sentence (previous sub didn't
    end with . ? !), inherit the previous sub's speaker — but only when the
    current sub's own assignment has low confidence (ambiguous embedding).
    High-confidence assignments are kept even across continuations."""
    result = [dict(w) for w in labeled_words]

    # Compute confidence threshold
    all_conf = [w.get('confidence', 0) for w in result]
    conf_threshold = float(np.median(all_conf)) if all_conf else 0

    word_idx = 0
    prev_speaker = None
    prev_ended_with_punct = True

    for sub in all_subs:
        sub_len = len(sub)

        if not prev_ended_with_punct and prev_speaker is not None and word_idx < len(result):
            sub_conf = result[word_idx].get('confidence', 1.0)
            if sub_conf < conf_threshold:
                # Low confidence — carry forward previous speaker
                for i in range(word_idx, min(word_idx + sub_len, len(result))):
                    result[i]['speaker'] = prev_speaker

        prev_speaker = result[word_idx]['speaker'] if word_idx < len(result) else None
        last_word = sub[-1]['word'].strip()
        prev_ended_with_punct = bool(re.search(r'[.?!]$', last_word))
        word_idx += sub_len

    return result


def smooth_labels(labeled_words, min_run=5):
    """Absorb speaker runs shorter than min_run words into neighbors."""
    if len(labeled_words) <= min_run:
        return labeled_words

    result = [dict(w) for w in labeled_words]

    changed = True
    while changed:
        changed = False
        i = 0
        while i < len(result):
            j = i
            while j < len(result) and result[j]['speaker'] == result[i]['speaker']:
                j += 1
            run_length = j - i

            if run_length < min_run and (i > 0 or j < len(result)):
                absorb_speaker = result[i - 1]['speaker'] if i > 0 else result[j]['speaker']
                for k in range(i, j):
                    result[k]['speaker'] = absorb_speaker
                changed = True

            i = j

    return result


# ---------- Formatting ----------

def reorder_speakers_by_appearance(labeled_words):
    mapping = {}
    next_id = 0
    for w in labeled_words:
        if w['speaker'] not in mapping:
            mapping[w['speaker']] = next_id
            next_id += 1
        w['speaker'] = mapping[w['speaker']]
    return labeled_words


def format_output(labeled_words):
    if not labeled_words:
        return ""
    paragraphs = []
    current_speaker = labeled_words[0]['speaker']
    current_words = []
    for w in labeled_words:
        if w['speaker'] != current_speaker:
            text = join_words(current_words)
            letter = chr(65 + current_speaker) if current_speaker < 26 else str(current_speaker + 1)
            paragraphs.append(f"(Speaker {letter}) {text}")
            current_speaker = w['speaker']
            current_words = [w['word']]
        else:
            current_words.append(w['word'])
    if current_words:
        text = join_words(current_words)
        letter = chr(65 + current_speaker) if current_speaker < 26 else str(current_speaker + 1)
        paragraphs.append(f"(Speaker {letter}) {text}")
    return "\n\n".join(paragraphs) + "\n"


def join_words(words):
    result = ""
    for w in words:
        if w.startswith(" ") or not result:
            result += w
        else:
            result += " " + w
    return result.strip()


# ---------- Main ----------

def main():
    if len(sys.argv) < 3:
        print("Usage: diarize.py <audio-file> <whisper-json>", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    json_path = sys.argv[2]
    n_speakers = int(sys.argv[3]) if len(sys.argv) > 3 else None

    print("Loading audio...", file=sys.stderr)
    wav = load_audio(audio_path)
    print(f"Audio: {len(wav)/16000:.1f}s", file=sys.stderr)

    whisper = load_whisper_json(json_path)
    word_count = sum(len(s.get('words', [])) for s in whisper['segments'])
    if word_count == 0:
        print("Error: no word timestamps. Re-run whisper with --word_timestamps True", file=sys.stderr)
        sys.exit(1)
    print(f"Words: {word_count}", file=sys.stderr)

    print("Computing speaker embeddings...", file=sys.stderr)
    with contextlib.redirect_stdout(io.StringIO()):
        encoder = VoiceEncoder()

    # Step 1: Coarse clustering for reliable speaker profiles
    coarse_emb = compute_windowed_embeddings(encoder, wav, window_sec=1.5, step_sec=0.5)
    coarse_labels = cluster_embeddings(coarse_emb, n_speakers=n_speakers)
    n = len(set(coarse_labels))
    print(f"Speakers: {n}", file=sys.stderr)
    speaker_profiles = build_speaker_profiles(coarse_emb, coarse_labels)
    profile_ids = sorted(speaker_profiles.keys())
    profile_matrix = np.array([speaker_profiles[k] for k in profile_ids])

    # Step 2: Split whisper segments at punctuation into sub-segments
    all_subs = []
    for seg in whisper['segments']:
        words = seg.get('words', [])
        if words:
            all_subs.extend(split_at_punctuation(words))
    print(f"Sub-segments: {len(all_subs)}", file=sys.stderr)

    # Step 3: Assign each sub-segment to nearest speaker profile
    sr = 16000
    labeled_words = []
    for sub in all_subs:
        start_sample = max(0, int(sub[0]['start'] * sr))
        end_sample = min(len(wav), int(sub[-1]['end'] * sr))
        chunk = wav[start_sample:end_sample]
        min_samples = int(0.5 * sr)
        if len(chunk) < min_samples:
            center = (start_sample + end_sample) // 2
            start_sample = max(0, center - min_samples // 2)
            end_sample = min(len(wav), start_sample + min_samples)
            chunk = wav[start_sample:end_sample]

        emb = encoder.embed_utterance(chunk)
        sims = cosine_similarity([emb], profile_matrix)[0]
        speaker = profile_ids[int(np.argmax(sims))]
        conf = float(np.sort(sims)[-1] - np.sort(sims)[-2]) if len(sims) > 1 else 1.0

        for w in sub:
            labeled_words.append({
                'word': w['word'], 'start': w['start'], 'end': w['end'],
                'speaker': speaker, 'confidence': conf,
            })

    # Step 4: Carry speaker across incomplete sentences, then smooth
    labeled_words = carry_across_continuations(labeled_words, all_subs)
    labeled_words = smooth_labels(labeled_words)
    labeled_words = reorder_speakers_by_appearance(labeled_words)

    print(format_output(labeled_words))


if __name__ == "__main__":
    main()
