import httpx
from app.core.config import settings
from app.core.exceptions import LLMBackendError


async def execute_vllm(args: dict) -> dict:
    """Call vLLM via OpenAI-compatible /v1/chat/completions endpoint."""
    messages = args.get("messages") or [{"role": "user", "content": args.get("prompt", "")}]

    payload = {
        "model": settings.vllm_model,
        "messages": messages,
    }

    try:
        async with httpx.AsyncClient(timeout=settings.vllm_timeout) as client:
            resp = await client.post(
                f"{settings.vllm_url}/v1/chat/completions", json=payload
            )
            resp.raise_for_status()
            data = resp.json()

        text = data["choices"][0]["message"]["content"]
        return {"backend": "vllm", "model": settings.vllm_model, "response": text, "raw": data}

    except httpx.ConnectError:
        raise LLMBackendError("vllm", f"Cannot connect to {settings.vllm_url}")
    except Exception as e:
        raise LLMBackendError("vllm", str(e))
