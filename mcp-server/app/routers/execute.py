import time
from fastapi import APIRouter, Depends
from app.models.request import ExecuteRequest
from app.models.response import ToolExecutionResponse
from app.executor.dispatcher import dispatch
from app.core.security import require_api_key

router = APIRouter(tags=["execute"])


@router.post("", response_model=ToolExecutionResponse, dependencies=[Depends(require_api_key)])
async def execute(req: ExecuteRequest):
    t0 = time.monotonic()
    result = await dispatch(req.tool, req.arguments)
    elapsed = round((time.monotonic() - t0) * 1000, 2)
    return ToolExecutionResponse(tool=req.tool, result=result, elapsed_ms=elapsed)
