from pydantic import BaseModel
from typing import Dict, Any, Optional, Literal


class Tool(BaseModel):
    name: str
    description: str
    input_schema: Dict[str, Any]
    backend_type: Literal["http", "ollama", "vllm"]
    endpoint: Optional[str] = None
    method: str = "POST"
    source_service: Optional[str] = None  # base URL it was discovered from
