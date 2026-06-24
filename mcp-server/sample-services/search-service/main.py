from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Optional
import re

app = FastAPI(title="Search Service", version="1.0.0")

# Sample document corpus for demo
_docs = [
    {"id": "1", "title": "PostgreSQL HA with Patroni", "content": "Patroni manages PostgreSQL high availability using Raft or etcd as DCS.", "tags": ["postgres", "ha"]},
    {"id": "2", "title": "MinIO Site Replication", "content": "MinIO supports active-active bidirectional site replication between datacenters.", "tags": ["minio", "storage"]},
    {"id": "3", "title": "Docker Compose Networking", "content": "Docker Compose creates isolated networks; containers communicate by service name.", "tags": ["docker"]},
    {"id": "4", "title": "FastAPI OpenAPI Auto-Discovery", "content": "FastAPI generates an OpenAPI spec at /openapi.json automatically.", "tags": ["fastapi", "api"]},
    {"id": "5", "title": "Ollama Local Inference", "content": "Ollama runs LLMs locally — llama3, mistral, qwen — with a simple REST API.", "tags": ["llm", "inference"]},
]

class SearchRequest(BaseModel):
    query: str
    limit: Optional[int] = 10

class SemanticSearchRequest(BaseModel):
    query: str
    collection: Optional[str] = "default"
    top_k: Optional[int] = 5

class SearchResult(BaseModel):
    id: str
    title: str
    content: str
    score: float

@app.get("/health")
def health():
    return {"status": "ok", "service": "search-service"}

@app.post("/search", response_model=List[SearchResult])
def search(req: SearchRequest):
    """Keyword search over the document corpus."""
    terms = req.query.lower().split()
    results = []
    for doc in _docs:
        text = f"{doc['title']} {doc['content']}".lower()
        score = sum(1 for t in terms if t in text) / max(len(terms), 1)
        if score > 0:
            results.append(SearchResult(id=doc["id"], title=doc["title"], content=doc["content"], score=round(score, 2)))
    results.sort(key=lambda x: x.score, reverse=True)
    return results[:req.limit]

@app.post("/semantic-search", response_model=List[SearchResult])
def semantic_search(req: SemanticSearchRequest):
    """Simulated semantic search (keyword fallback for demo — replace with real vectors)."""
    terms = req.query.lower().split()
    results = []
    for doc in _docs:
        text = f"{doc['title']} {doc['content']} {' '.join(doc['tags'])}".lower()
        score = sum(1 for t in terms if t in text) / max(len(terms), 1)
        results.append(SearchResult(id=doc["id"], title=doc["title"], content=doc["content"], score=round(score, 2)))
    results.sort(key=lambda x: x.score, reverse=True)
    return results[:req.top_k]
