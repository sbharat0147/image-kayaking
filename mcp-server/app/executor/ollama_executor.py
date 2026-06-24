import httpx
from app.core.config import settings
from app.core.exceptions import LLMBackendError


async def execute_ollama(args: dict) -> dict:
    """Call Ollama /api/generate for single-turn or /api/chat for multi-turn."""
    prompt = args.get("prompt")
    messages = args.get("messages")

    try:
        async with httpx.AsyncClient(timeout=settings.ollama_timeout) as client:
            if messages:
                payload = {"model": settings.ollama_model, "messages": messages, "stream": False}
                resp = await client.post(f"{settings.ollama_url}/api/chat", json=payload)
            else:
                payload = {"model": settings.ollama_model, "prompt": prompt or "", "stream": False}
                resp = await client.post(f"{settings.ollama_url}/api/generate", json=payload)

            resp.raise_for_status()
            data = resp.json()

        # Normalise to a consistent shape
        text = data.get("response") or data.get("message", {}).get("content", "")
        return {"backend": "ollama", "model": settings.ollama_model, "response": text, "raw": data}

    except httpx.ConnectError:
        raise LLMBackendError("ollama", f"Cannot connect to {settings.ollama_url}")
    except Exception as e:
        raise LLMBackendError("ollama", str(e))
