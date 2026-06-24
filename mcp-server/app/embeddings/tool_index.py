from typing import List
from app.embeddings.embedder import embed_text
from app.embeddings.similarity import cosine_similarity
from app.models.tool import Tool


class ToolVectorIndex:
    def __init__(self):
        self._vectors: List[tuple] = []  # (tool, embedding)
        self._dirty = True

    def build(self, tools: List[Tool]):
        self._vectors = []
        for tool in tools:
            text = f"{tool.name} {tool.description}"
            vec = embed_text(text)
            self._vectors.append((tool, vec))
        self._dirty = False

    def search(self, query: str, top_k: int = 6) -> List[Tool]:
        if not self._vectors:
            return []

        query_vec = embed_text(query)
        scored = [
            (cosine_similarity(query_vec, vec), tool)
            for tool, vec in self._vectors
        ]
        scored.sort(key=lambda x: x[0], reverse=True)
        return [tool for _, tool in scored[:top_k]]
