#!/usr/bin/env python3
"""Speaker diarization using resemblyzer embeddings + spectral clustering.

Usage:
    diarize.py <audio-file> <whisper-json>

Reads Whisper JSON (with word timestamps), computes speaker embeddings
for sliding windows, assigns each word to a speaker, and outputs
labeled text to stdout.
"""
import sys
import json
import numpy as np
from pathlib import Path
from resemblyzer import VoiceEncoder, preprocess_wav
from sklearn.cluster import SpectralClustering
import warnings
warnings.filterwarnings("ignore")


def load_audio(path: str) -> np.ndarray:
    """Load audio as 16kHz mono float32 via resemblyzer's preprocessor."""
    wav = preprocess_wav(Path(path))
    return wav


def load_whisper_json(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def compute_windowed_embeddings(encoder, wav, sr=16000, window_sec=3.0, step_sec=0.5):
    """Compute speaker embeddings for overlapping windows across the audio."""
    window_samples = int(window_sec * sr)
    step_samples = int(step_sec * sr)
    total = len(wav)

    embeddings = []
    timestamps = []  # center time of each window

    pos = 0
    while pos + window_samples <= total:
        chunk = wav[pos:pos + window_samples]
        emb = encoder.embed_utterance(chunk)
        center = (pos + window_samples / 2) / sr
        embeddings.append(emb)
        timestamps.append(center)
        pos += step_samples

    # Handle last partial window if significant
    if pos < total and total - pos > sr:  # at least 1s remaining
        chunk = wav[pos:total]
        emb = encoder.embed_utterance(chunk)
        center = (pos + (total - pos) / 2) / sr
        embeddings.append(emb)
        timestamps.append(center)

    return np.array(embeddings), np.array(timestamps)


def cluster_embeddings(embeddings, n_speakers=None, max_speakers=6):
    """Cluster embeddings into speaker groups using spectral clustering."""
    if n_speakers is not None:
        n = n_speakers
    else:
        # Auto-detect: try different k, pick best silhouette score
        from sklearn.metrics import silhouette_score
        best_k, best_score = 2, -1
        for k in range(2, min(max_speakers + 1, len(embeddings))):
            sc = SpectralClustering(n_clusters=k, affinity='cosine', random_state=0)
            labels = sc.fit_predict(embeddings)
            score = silhouette_score(embeddings, labels, metric='cosine')
            if score > best_score:
                best_score = score
                best_k = k
        n = best_k
        print(f"Auto-detected {n} speakers (silhouette={best_score:.3f})", file=sys.stderr)

    sc = SpectralClustering(n_clusters=n, affinity='cosine', random_state=0)
    return sc.fit_predict(embeddings)


def assign_words_to_speakers(words, window_timestamps, window_labels):
    """Assign each word to the speaker of the nearest window."""
    labeled = []
    for w in words:
        mid = (w['start'] + w['end']) / 2
        # Find nearest window
        idx = np.argmin(np.abs(window_timestamps - mid))
        labeled.append({
            'word': w['word'],
            'start': w['start'],
            'end': w['end'],
            'speaker': int(window_labels[idx])
        })
    return labeled


def reorder_speakers_by_appearance(labeled_words):
    """Rename speakers so Speaker A is whoever speaks first."""
    mapping = {}
    next_id = 0
    for w in labeled_words:
        if w['speaker'] not in mapping:
            mapping[w['speaker']] = next_id
            next_id += 1
        w['speaker'] = mapping[w['speaker']]
    return labeled_words


def smooth_labels(labeled_words, window=7):
    """Majority-vote in sliding window to eliminate isolated speaker flips."""
    if len(labeled_words) <= 2:
        return labeled_words
    smoothed = [dict(w) for w in labeled_words]
    half = window // 2
    for i in range(len(labeled_words)):
        lo = max(0, i - half)
        hi = min(len(labeled_words), i + half + 1)
        neighbors = [labeled_words[j]['speaker'] for j in range(lo, hi)]
        smoothed[i]['speaker'] = max(set(neighbors), key=neighbors.count)
    return smoothed


def format_output(labeled_words):
    """Group consecutive same-speaker words into paragraphs."""
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
    """Join words, handling Whisper's leading-space convention."""
    result = ""
    for w in words:
        if w.startswith(" ") or not result:
            result += w
        else:
            result += " " + w
    return result.strip()


def main():
    if len(sys.argv) < 3:
        print("Usage: diarize.py <audio-file> <whisper-json>", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    json_path = sys.argv[2]
    n_speakers = int(sys.argv[3]) if len(sys.argv) > 3 else None

    # Load audio
    print("Loading audio...", file=sys.stderr)
    wav = load_audio(audio_path)
    print(f"Audio: {len(wav)/16000:.1f}s", file=sys.stderr)

    # Load whisper output
    whisper = load_whisper_json(json_path)
    words = []
    for seg in whisper['segments']:
        if 'words' in seg:
            words.extend(seg['words'])

    if not words:
        print("Error: no word timestamps in whisper JSON. "
              "Re-run whisper with --word_timestamps True", file=sys.stderr)
        sys.exit(1)

    print(f"Words: {len(words)}", file=sys.stderr)

    # Compute speaker embeddings
    print("Computing speaker embeddings...", file=sys.stderr)
    encoder = VoiceEncoder()
    embeddings, timestamps = compute_windowed_embeddings(
        encoder, wav, window_sec=1.5, step_sec=0.25
    )
    print(f"Embeddings: {len(embeddings)} windows", file=sys.stderr)

    # Cluster into speakers
    labels = cluster_embeddings(embeddings, n_speakers=n_speakers)
    n = len(set(labels))
    print(f"Speakers: {n}", file=sys.stderr)

    # Assign words to speakers
    labeled_words = assign_words_to_speakers(words, timestamps, labels)
    labeled_words = smooth_labels(labeled_words)
    labeled_words = reorder_speakers_by_appearance(labeled_words)

    # Format and output
    output = format_output(labeled_words)
    print(output)


if __name__ == "__main__":
    main()
