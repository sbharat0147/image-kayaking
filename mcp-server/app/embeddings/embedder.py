from sentence_transformers import SentenceTransformer
from app.core.config import settings

_model = None


def _get_model() -> SentenceTransformer:
    global _model
    if _model is None:
        _model = SentenceTransformer(settings.embedding_model)
    return _model


def embed_text(text: str) -> list:
    return _get_model().encode(text).tolist()
