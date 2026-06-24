from fastapi import APIRouter, Depends
from app.models.request import LLMRequest
from app.models.response import LLMResponse
from app.executor.dispatcher import dispatch_llm
from app.core.security import require_api_key

router = APIRouter(tags=["inference"])


@router.post("/llm", response_model=LLMResponse, dependencies=[Depends(require_api_key)])
async def run_llm(req: LLMRequest):
    result = await dispatch_llm(
        prompt=req.prompt,
        messages=req.messages or None,
        backend=req.backend,
    )
    return LLMResponse(
        backend_used=result["backend"],
        model=result["model"],
        response=result["response"],
    )
