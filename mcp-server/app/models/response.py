from pydantic import BaseModel
from typing import Any, List, Optional


class ToolExecutionResponse(BaseModel):
    tool: str
    result: Any
    elapsed_ms: Optional[float] = None


class LLMResponse(BaseModel):
    backend_used: str
    model: str
    response: str


class AgentResponse(BaseModel):
    result: str
    steps: int
    tools_used: List[str] = []
