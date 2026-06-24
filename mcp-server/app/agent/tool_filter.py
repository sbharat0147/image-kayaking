from typing import List
from app.embeddings.tool_index import ToolVectorIndex
from app.registry.tool_registry import registry
from app.models.tool import Tool
from app.core.config import settings

_index = ToolVectorIndex()


def get_relevant_tools(query: str) -> List[Tool]:
    tools = registry.list_tools()
    _index.build(tools)
    return _index.search(query, top_k=settings.agent_top_k_tools)
