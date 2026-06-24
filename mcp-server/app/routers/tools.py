from fastapi import APIRouter, Depends
from app.registry.tool_registry import registry
from app.core.security import require_api_key

router = APIRouter(tags=["tools"])


@router.get("", dependencies=[Depends(require_api_key)])
def list_tools():
    return [t.model_dump() for t in registry.list_tools()]


@router.get("/{name}", dependencies=[Depends(require_api_key)])
def get_tool(name: str):
    return registry.get(name).model_dump()
