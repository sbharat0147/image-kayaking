from pydantic import BaseModel
from typing import Any, Dict, List, Optional


class ExecuteRequest(BaseModel):
    tool: str
    arguments: Dict[str, Any] = {}


class LLMRequest(BaseModel):
    prompt: str
    messages: List[Dict[str, str]] = []
    backend: Optional[str] = None  # override routing; None = auto


class AgentRequest(BaseModel):
    query: str
    session_id: Optional[str] = None
