from typing import Dict, List
from app.models.tool import Tool
from app.core.exceptions import ToolNotFoundError


class ToolRegistry:
    def __init__(self):
        self._tools: Dict[str, Tool] = {}

    def register(self, tool: Tool):
        self._tools[tool.name] = tool

    def get(self, name: str) -> Tool:
        if name not in self._tools:
            raise ToolNotFoundError(name)
        return self._tools[name]

    def list_tools(self) -> List[Tool]:
        return list(self._tools.values())

    def count(self) -> int:
        return len(self._tools)

    def clear(self):
        self._tools.clear()


registry = ToolRegistry()
