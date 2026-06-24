from dataclasses import dataclass, field
from typing import Any, Dict, List


@dataclass
class AgentState:
    user_input: str
    steps: List[Dict[str, Any]] = field(default_factory=list)
    tool_results: List[Any] = field(default_factory=list)
    tools_used: List[str] = field(default_factory=list)
    final_answer: str = ""
    iteration: int = 0
