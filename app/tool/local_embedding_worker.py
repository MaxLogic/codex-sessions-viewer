"""Offline-only benchmark worker; reads JSON on stdin and emits JSON on stdout."""
import json
import os
import sys
import time

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'

request = json.load(sys.stdin)
started = time.perf_counter()
from sentence_transformers import SentenceTransformer
import psutil

model = SentenceTransformer(request['model'], revision=request['revision'],
                            local_files_only=True, device='cpu', trust_remote_code=False)
model.max_seq_length = 256
for text in request['texts']:
    if len(model.tokenizer.encode(text)) > model.max_seq_length:
        raise ValueError('Chunk exceeds model token budget; benchmark refuses silent truncation')
loaded = time.perf_counter()
corpus_count = request['corpus_count']
vectors = model.encode(request['texts'][:corpus_count], normalize_embeddings=True, show_progress_bar=False).tolist()
indexed = time.perf_counter()
query_ms = []
for text in request['texts'][corpus_count:]:
    query_start = time.perf_counter()
    vectors.append(model.encode(text, normalize_embeddings=True, show_progress_bar=False).tolist())
    query_ms.append((time.perf_counter()-query_start)*1000)
memory = psutil.Process().memory_info()
json.dump({'vectors': vectors, 'load_ms': (loaded-started)*1000,
           'corpus_encode_ms': (indexed-loaded)*1000, 'query_encode_ms': query_ms,
           'peak_rss_bytes': getattr(memory, 'peak_wset', memory.rss)}, sys.stdout)
