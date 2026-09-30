#!/usr/bin/env python3
"""
Offline retrieval benchmark for DocumentBrain — compare embedding models in minutes.

Replicates the app's retrieval pipeline in Python so candidate embedding models can be
evaluated *before* converting them to CoreML:

  ChunkingService (paragraph-aware, 800 chars, paragraph overlap)
  → embeddings (sentence-transformers, L2-normalised, mean pooling)
  → ChunkRepository.hybridSearch (cosine + SQLite FTS5, same scoring formula)
  → top-5 seeds, as ChatViewModel uses them

Metrics per model, overall and per question type (lexical / semantic / crosslingual):
  doc@1, doc@5      — the right document is the first / among the first 5 results
  evid@5            — a top-5 chunk from the right document contains the answer evidence
  MRR               — mean reciprocal rank of the right document (top 12)

The Swift test `RetrievalEvalTests` runs the real app code on the same corpus; use it
to confirm a model after conversion. Keep both in sync if scoring changes in Swift.

Usage:
  pip install sentence-transformers
  python eval/run_retrieval_eval.py                       # default model set
  python eval/run_retrieval_eval.py --models intfloat/multilingual-e5-small
  python eval/run_retrieval_eval.py --json results.json   # machine-readable output
"""

import argparse
import json
import re
import sqlite3
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DEFAULT_CORPUS = HERE.parent / "DocumentBrainTests" / "RetrievalEval" / "retrieval_eval_corpus.json"

DEFAULT_MODELS = [
    "sentence-transformers/multi-qa-MiniLM-L6-cos-v1",            # current app model (English-only)
    "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",  # 384-d multilingual drop-in
    "intfloat/multilingual-e5-small",                             # 384-d multilingual, query:/passage: prefixes
]

# Models that expect instruction prefixes.
PREFIXES = {
    "intfloat/multilingual-e5-small": ("query: ", "passage: "),
    "intfloat/multilingual-e5-base": ("query: ", "passage: "),
    "intfloat/multilingual-e5-large": ("query: ", "passage: "),
}

# ---------------------------------------------------------------------------
# ChunkingService port (DocumentBrain/Core/Services/ChunkingService.swift)
# ---------------------------------------------------------------------------
TARGET_CHUNK_CHARS = 800
MAX_OVERLAP_CHARS = 250
MIN_PARAGRAPH_CHARS = 60


def _preprocess(text):
    text = "\n".join(line.strip(" \t") for line in text.split("\n"))
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _split_sentences(text):
    sentences, current = [], ""
    for i, ch in enumerate(text):
        current += ch
        if ch in ".!?\n":
            nxt = text[i + 1] if i + 1 < len(text) else None
            if not (nxt is not None and nxt.isalpha()):
                t = current.strip(" ")
                if t:
                    sentences.append(t)
                current = ""
    t = current.strip(" ")
    if t:
        sentences.append(t)
    return sentences


def _split_long_block(block):
    if len(block) <= TARGET_CHUNK_CHARS * 2:
        return [block]
    result, current = [], ""
    for s in _split_sentences(block):
        candidate = s if not current else current + " " + s
        if len(candidate) > TARGET_CHUNK_CHARS and current:
            result.append(current)
            current = s
        else:
            current = candidate
    if current:
        result.append(current)
    return result


def chunk_text(text):
    cleaned = _preprocess(text)
    if not cleaned:
        return []
    blocks = [b.strip() for b in cleaned.split("\n\n") if b.strip()]
    paragraphs = [p for b in blocks for p in _split_long_block(b)]

    merged, pending = [], ""
    for p in paragraphs:
        if not pending:
            pending = p
        elif len(pending) < MIN_PARAGRAPH_CHARS:
            pending += "\n\n" + p
        else:
            merged.append(pending)
            pending = p
    if pending:
        merged.append(pending)

    chunks, current, overlap = [], [], None

    def flush():
        nonlocal current, overlap
        if not current:
            return
        parts = ([overlap] if overlap is not None else []) + current
        chunks.append("\n\n".join(parts))
        last = current[-1]
        overlap = last if len(last) <= MAX_OVERLAP_CHARS else last[-MAX_OVERLAP_CHARS:]
        current = []

    current_len = 0
    for p in merged:
        added = len(p) if current_len == 0 else current_len + 2 + len(p)
        if added > TARGET_CHUNK_CHARS and current:
            flush()
        current.append(p)
        current_len = sum(len(x) + 2 for x in current)
    flush()
    return chunks


# ---------------------------------------------------------------------------
# ChunkRepository.hybridSearch port
# ---------------------------------------------------------------------------
STOPWORDS = {
    "que", "qué", "de", "del", "la", "el", "en", "es", "lo", "los", "las",
    "un", "una", "uno", "por", "con", "para", "al", "se", "su", "sus",
    "mi", "mis", "tu", "tus", "nos", "les", "como", "pero", "mas", "más",
    "ya", "este", "esta", "ese", "esa", "hay", "fue", "son", "ser", "sin",
    "sobre", "entre", "cuando", "muy", "puede", "donde", "tiene", "sido",
    "desde", "está", "están", "era", "han", "todo", "otra", "otro",
    "cual", "cuál", "aquí", "también", "cada", "porque",
    "the", "is", "at", "which", "on", "and", "or", "in", "to", "of",
    "for", "with", "was", "are", "has", "have", "had", "not", "but",
    "from", "this", "that", "these", "those", "what", "when", "where",
    "how", "who", "why", "my", "your", "his", "her", "its", "our",
    "do", "does", "did", "will", "would", "could", "should", "can",
    "about", "been", "being", "were", "they", "them", "their",
    "all", "any", "some", "much", "many", "more", "most", "very",
}

_SPLIT = re.compile(r"[^0-9A-Za-zÀ-ɏ]+")


def fold(s):
    return "".join(c for c in unicodedata.normalize("NFD", s.lower()) if unicodedata.category(c) != "Mn")


def words(text):
    return [w for w in _SPLIT.split(text) if w]


def fts_terms(q):
    return [w for w in words(q) if len(w) > 1 and w.lower() not in STOPWORDS]


def meaningful_words(q):
    return [w for w in words(q) if len(w) > 2 and w.lower() not in STOPWORDS]


def entity_terms(q):
    """Mirror of ChunkRepository.entityTerms: capitalised words, skipping each sentence's
    first word unless it looks like a code (contains a digit or is all caps)."""
    out = set()
    for sentence in re.split(r"[.?!¿¡\n]", q):
        ws = [w for w in words(sentence) if len(w) > 1]
        for pos, w in enumerate(ws):
            if not w[0].isupper():
                continue
            looks_like_code = any(ch.isdigit() for ch in w) or w == w.upper()
            if pos == 0 and not looks_like_code:
                continue
            out.add(fold(w))
    return out


def token_set(text):
    return {w for w in words(fold(text)) if len(w) > 1}


class Index:
    def __init__(self, corpus, model, prefixes):
        self.model = model
        self.q_prefix, self.p_prefix = prefixes
        self.chunks = []  # dicts: id, doc, title, idx, content
        for d in corpus["documents"]:
            for i, c in enumerate(chunk_text(d["text"])):
                self.chunks.append({"id": len(self.chunks), "doc": d["id"], "title": d["title"], "idx": i, "content": c})
        texts = [self.p_prefix + c["content"] for c in self.chunks]
        self.vectors = model.encode(texts, normalize_embeddings=True, batch_size=16, show_progress_bar=False)

        self.db = sqlite3.connect(":memory:")
        self.db.execute("CREATE VIRTUAL TABLE fts USING fts5(content)")
        self.db.executemany("INSERT INTO fts(rowid, content) VALUES (?, ?)",
                            [(c["id"], c["content"]) for c in self.chunks])

    def embed_query(self, q):
        return self.model.encode([self.q_prefix + q], normalize_embeddings=True, show_progress_bar=False)[0]

    def vector_search(self, qv, limit, min_score):
        scores = self.vectors @ qv
        order = np.argsort(-scores)
        return [(int(i), float(scores[i])) for i in order if scores[i] >= min_score][:limit]

    def fts_search(self, q, limit):
        terms = fts_terms(q)
        if not terms:
            return []

        def run(sep):
            query = sep.join(f'"{t}"' for t in terms)
            return [r[0] for r in self.db.execute(
                "SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY rank LIMIT ?", (query, limit))]

        rows = run(" AND ")
        if not rows and len(terms) > 1:
            rows = run(" OR ")
        return rows

    def hybrid_search(self, q, qv, limit=12, min_score=0.2):
        vec = self.vector_search(qv, limit * 3, 0.15)
        fts = self.fts_search(q, limit * 3)
        meaningful = {fold(w) for w in meaningful_words(q)}
        entities = entity_terms(q)

        entries = {cid: [s, False] for cid, s in vec}
        for cid in fts:
            if cid in entries:
                entries[cid][1] = True
            else:
                entries[cid] = [0.0, True]

        merged = []
        for cid, (sem, fts_hit) in entries.items():
            c = self.chunks[cid]
            toks = token_set(c["content"]) | token_set(c["title"])
            lex = meaningful & toks
            coverage = len(lex) / len(meaningful) if meaningful else 0.0
            entity_hit = bool(entities) and not entities.isdisjoint(toks)
            if meaningful and not lex and not entity_hit and sem < 0.50:
                continue
            if fts_hit and lex:
                kb = 0.05 + coverage * 0.10
            elif lex:
                kb = coverage * 0.05
            else:
                kb = 0.0
            eb = 0.10 if entity_hit else 0.0
            final = 0.65 * sem + 0.20 * coverage + kb + eb
            if final >= min_score:
                merged.append((cid, final))
        merged.sort(key=lambda x: -x[1])
        return merged[:limit]


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------
def evaluate(index, corpus):
    stats = {"hybrid": defaultdict(lambda: defaultdict(float)), "vector": defaultdict(lambda: defaultdict(float))}
    misses = []
    for q in corpus["questions"]:
        qv = index.embed_query(q["q"])
        runs = {
            "hybrid": index.hybrid_search(q["q"], qv),
            "vector": index.vector_search(qv, 12, -1.0),
        }
        for mode, results in runs.items():
            docs = [index.chunks[cid]["doc"] for cid, _ in results]
            top5 = results[:5]
            evid = any(index.chunks[cid]["doc"] == q["doc"] and fold(q["evidence"]) in fold(index.chunks[cid]["content"])
                       for cid, _ in top5)
            rank = docs.index(q["doc"]) + 1 if q["doc"] in docs else None
            for bucket in ("all", q["type"]):
                s = stats[mode][bucket]
                s["n"] += 1
                s["doc@1"] += 1 if rank == 1 else 0
                s["doc@5"] += 1 if rank and rank <= 5 else 0
                s["evid@5"] += 1 if evid else 0
                s["MRR"] += 1 / rank if rank else 0
            if mode == "hybrid" and not evid:
                misses.append((q["type"], q["q"], q["doc"], docs[:3]))
    out = {}
    for mode, buckets in stats.items():
        out[mode] = {b: {k: (v / s["n"] if k != "n" else int(v)) for k, v in s.items()} for b, s in buckets.items()}
    return out, misses


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    ap.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    ap.add_argument("--json", help="write results to this file")
    ap.add_argument("--show-misses", action="store_true")
    args = ap.parse_args()

    from sentence_transformers import SentenceTransformer

    corpus = json.loads(Path(args.corpus).read_text(encoding="utf-8"))
    n_chunks = sum(len(chunk_text(d["text"])) for d in corpus["documents"])
    print(f"Corpus: {len(corpus['documents'])} documents, {n_chunks} chunks, {len(corpus['questions'])} questions\n")

    all_results = {}
    for name in args.models:
        model = SentenceTransformer(name, device="cpu")
        model.max_seq_length = min(model.max_seq_length or 512, 512)
        index = Index(corpus, model, PREFIXES.get(name, ("", "")))
        results, misses = evaluate(index, corpus)
        all_results[name] = results

        print(f"== {name}")
        print(f"   {'mode':<7} {'bucket':<13} {'n':>3} {'doc@1':>6} {'doc@5':>6} {'evid@5':>7} {'MRR':>6}")
        for mode in ("hybrid", "vector"):
            for bucket in ("all", "lexical", "semantic", "crosslingual"):
                s = results[mode].get(bucket)
                if not s:
                    continue
                print(f"   {mode:<7} {bucket:<13} {s['n']:>3} {s['doc@1']:>6.2f} {s['doc@5']:>6.2f} {s['evid@5']:>7.2f} {s['MRR']:>6.2f}")
        if args.show_misses and misses:
            print("   hybrid misses (evidence not in top 5):")
            for t, q, doc, got in misses:
                print(f"     [{t}] {q}  → expected {doc}, got {got}")
        print()

    if args.json:
        Path(args.json).write_text(json.dumps(all_results, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
