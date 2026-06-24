import time
import httpx
from app.models.tool import Tool
from app.core.exceptions import ExecutionError


async def execute_http(tool: Tool, args: dict) -> dict:
    method = (tool.method or "POST").upper()
    t0 = time.monotonic()

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            if method == "GET":
                resp = await client.get(tool.endpoint, params=args)
            else:
                resp = await client.request(method, tool.endpoint, json=args)
            resp.raise_for_status()
            elapsed = (time.monotonic() - t0) * 1000
            return {"data": resp.json(), "elapsed_ms": round(elapsed, 2)}
    except httpx.HTTPStatusError as e:
        raise ExecutionError(tool.name, f"HTTP {e.response.status_code}: {e.response.text}")
    except Exception as e:
        raise ExecutionError(tool.name, str(e))
