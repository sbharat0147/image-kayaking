from fastapi import APIRouter
from app.registry.tool_registry import registry

router = APIRouter(tags=["health"])


@router.get("/health")
def health():
    return {"status": "ok", "tools_registered": registry.count()}
