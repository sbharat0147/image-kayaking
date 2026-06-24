from fastapi import APIRouter, Depends
from app.models.request import AgentRequest
from app.models.response import AgentResponse
from app.agent.loop import run_agent
from app.executor.dispatcher import dispatch_llm
from app.core.security import require_api_key

router = APIRouter(tags=["agent"])


@router.post("/run", response_model=AgentResponse, dependencies=[Depends(require_api_key)])
async def agent_run(req: AgentRequest):
    state = await run_agent(user_input=req.query, llm=dispatch_llm)
    return AgentResponse(
        result=state.final_answer,
        steps=state.iteration,
        tools_used=state.tools_used,
    )
