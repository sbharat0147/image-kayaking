import os
from sentence_transformers import SentenceTransformer

_model = None
_MODEL_DIR = "/app/models/sentence-transformers_all-MiniLM-L6-v2"


def _get_model() -> SentenceTransformer:
    global _model
    if _model is None:
        if not (os.path.isdir(_MODEL_DIR) and os.listdir(_MODEL_DIR)):
            raise RuntimeError(
                f"Embedding model not found at {_MODEL_DIR}. "
                "Run bash scripts/download-model.sh then rebuild the image."
            )
        # Pass the absolute local path so sentence-transformers never contacts HF
        _model = SentenceTransformer(_MODEL_DIR)
    return _model


def embed_text(text: str) -> list:
    return _get_model().encode(text).tolist()
