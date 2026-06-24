import httpx


async def fetch_openapi_schema(base_url: str) -> dict:
    url = f"{base_url.rstrip('/')}/openapi.json"
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return resp.json()
