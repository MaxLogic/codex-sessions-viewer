# Optional semantic search evaluation (T-129)

This is an isolated screening experiment. Production search does not import these
tools, start an embedding service, download a model, or send session text anywhere.
The benchmark uses synthetic session messages and locally computed embeddings.

## Reproduce

Run on Windows with the existing Flutter SDK, Python, `sentence-transformers`,
PyTorch, and `psutil`. The measured environment used sentence-transformers 5.0.0,
transformers 4.57.3, torch 2.7.1+cu128 (CPU execution), and psutil 7.0.0.
The model must already be in the Hugging Face cache. Explicit provisioning is
separate from evaluation; the evaluator is always offline and never downloads:

```powershell
python -c "from huggingface_hub import snapshot_download; snapshot_download('sentence-transformers/all-MiniLM-L6-v2', revision='1110a243fdf4706b3f48f1d95db1a4f5529b4d41', allow_patterns=['*.json','*.txt','model.safetensors','1_Pooling/*'])"
cd app
dart run tool/evaluate_semantic_search.dart --manifest ../samples/search-eval/manifest.json --out ../docs/semantic-search-evaluation.json
flutter test test/search/semantic_search_evaluation_test.dart
```

The downloaded snapshot occupies 91,607,178 bytes. Weights remain outside the
repository. The [publisher's model card](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
describes a 384-dimensional English sentence encoder and a 256-word-piece limit.
The worker rejects overlong chunks rather than silently truncating them. It uses
`local_files_only=True`, disables telemetry, and disallows remote model code.
Unavailable Python packages or weights produce `status: unavailable` and exit 2;
that result is not a successful semantic comparison. It is written to
`<out>.unavailable.json`, so the retained measured JSON is never overwritten.

## Method and results

The retained [manifest](../samples/search-eval/manifest.json) was labeled before
running the model: 24 synthetic sessions, 14 queries, 61 non-tool chunks. All modes
use exactly these messages, source filters, and relevance labels. The manifest
digest in the [measured JSON](semantic-search-evaluation.json) identifies the input.
Each session has one relevant label per applicable query; recall and reciprocal
rank are computed over distinct sessions, retaining the strongest chunk citation.

| Mode | Recall@10 | MRR@10 | Mean ranking time | Mean query encoding |
|---|---:|---:|---:|---:|
| Lexical token overlap | 0.7143 | 0.7143 | 2.32 ms | 0 ms |
| SkillSearch-style lexical-candidate hybrid | 0.7143 | 0.7143 | 0.93 ms | 26.96 ms |
| Independent semantic retrieval | 1.0000 | 1.0000 | 1.34 ms | 26.96 ms |

This lexical baseline is token overlap, **not the production FTS5 query**. Hybrid
uses the observed 0.35 lexical / 0.65 cosine weighting solely as a comparison
point. Ranking timings include one run in a fixed order and JIT warmup; the
apparent hybrid speed advantage is not evidence of a performance improvement.
Encoding time is measured separately for each query with the already loaded
model. Cold startup adds 11.48 seconds in this run. Corpus encoding takes
346.38 ms and SQLite cache insertion 54.66 ms. Whole worker startup, inference,
IPC and cache insertion take 13.93 seconds.

The corpus vector cache occupies 557,056 bytes, or 679,936 bytes including query
vectors; it stores JSON double arrays for inspectability. Lexical mode builds no
persistent index. Python peak working set is 770,285,568 bytes; Dart peak RSS is
262,373,376 bytes. These are separate process high-water marks, not a measured
simultaneous aggregate peak. This tiny corpus cannot establish scaling limits.
An unchanged repeat of all 75 unique texts performs zero cache re-embeddings.

## What was adapted

Source comparison: `F:/projects/MaxLogic/SkillSearch/src/Semantic/Chunker.pas`
hashes normalized chunk text, and `src/Search/SkillSearchService.pas` caches
`chunk_vec` with model/dimension metadata and combines lexical and cosine scores
in `ApplySemanticRerank`. That function's candidate restriction prevents a rerank
from recovering results absent from lexical search.

This experiment keeps normalized content hashes and SQLite caching keyed by
content, model revision and dimension. Chunks stay inside messages and use
`session/message@offset` citations; adding a message leaves old citations intact.
The 400-character bound is an experiment setting, not a production choice.
Tool output is deliberately excluded; the fixture includes 3,000 noisy tool
lines and a long assistant message. Queries such as “vehicle fixing” have zero
lexical candidates, yet independent semantic retrieval returns the labeled
automobile repair session. Hybrid cannot recover those missing candidates.

Five retained tests cover append stability and bounded long messages, tool noise,
unchanged-content reuse, content/model/dimension invalidation, source filters,
independent zero-lexical retrieval, cancellation before/after inference with no
partial cache write, invalid vectors, and lexical operation after model failure.
Test vectors are controlled unit fixtures; the JSON comparison uses real model
vectors. Cancellation does not interrupt a running model call; it stops cache
commit when that call returns. The CLI bounds the worker to five minutes.

## Recommendation

Keep ordinary FTS search as the default. Consider optional semantic retrieval as
an independent candidate source, because reranking alone misses paraphrases.
This small English synthetic corpus supports that architectural choice, but
does not select MiniLM, the chunk bound, hybrid weights, or an index for production.
Before choosing those, compare production FTS5, at least one alternative model,
and message/token chunk configurations on a larger human-labeled local corpus
including code, Polish, negative queries and relevant tool output. Measure warm
latency percentiles, cancellation latency, and memory at real corpus scale.

The measured CPU model adds meaningful startup and memory costs. A persistent
optional worker could amortize startup, but requires its own lifecycle and privacy
design. Do not introduce that service based on this screening result alone.
