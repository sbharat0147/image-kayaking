import os
from sentence_transformers import SentenceTransformer
from app.core.config import settings

_model = None


def _get_model() -> SentenceTransformer:
    global _model
    if _model is None:
        # Use local path if available (airgap / no Hugging Face access)
        local_path = os.path.join(
            os.environ.get("SENTENCE_TRANSFORMERS_HOME", "/app/models"),
            settings.embedding_model.replace("/", "_"),
        )
        model_name = local_path if os.path.isdir(local_path) else settings.embedding_model
        _model = SentenceTransformer(model_name)
    return _model


def embed_text(text: str) -> list:
    return _get_model().encode(text).tolist()
