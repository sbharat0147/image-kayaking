import os
from sentence_transformers import SentenceTransformer
from app.core.config import settings

_model = None
_MODEL_DIR = "/app/models/sentence-transformers_all-MiniLM-L6-v2"


def _get_model() -> SentenceTransformer:
    global _model
    if _model is None:
        if os.path.isdir(_MODEL_DIR) and os.listdir(_MODEL_DIR):
            # Load directly from local path — no HF lookup at all
            _model = SentenceTransformer(_MODEL_DIR)
        else:
            # Fallback: load by name (requires internet — dev only)
            _model = SentenceTransformer(settings.embedding_model)
    return _model


def embed_text(text: str) -> list:
    return _get_model().encode(text).tolist()
