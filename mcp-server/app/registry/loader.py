import json
import logging
from pathlib import Path
from typing import List

from app.registry.tool_registry import registry
from app.models.tool import Tool
from app.integrations.openapi.loader import fetch_openapi_schema
from app.integrations.openapi.parser import parse_openapi

logger = logging.getLogger("mcp_server.loader")


def load_static_tools():
    """Load tools from JSON definition files in the tools/ directory."""
    tools_dir = Path("tools")
    if not tools_dir.exists():
        return

    for file in tools_dir.glob("*.json"):
        try:
            data = json.loads(file.read_text())
            for tool_def in data:
                tool = Tool(**tool_def)
                registry.register(tool)
                logger.info("Loaded static tool: %s", tool.name)
        except Exception as e:
            logger.warning("Failed to load %s: %s", file.name, e)


async def load_openapi_tools(base_urls: List[str]):
    """Auto-discover tools from upstream FastAPI services via their OpenAPI specs."""
    for base_url in base_urls:
        try:
            spec = await fetch_openapi_schema(base_url)
            tools = parse_openapi(spec, base_url)
            for tool in tools:
                registry.register(tool)
                logger.info("Discovered tool '%s' from %s", tool.name, base_url)
            logger.info("Loaded %d tools from %s", len(tools), base_url)
        except Exception as e:
            logger.warning("Could not load OpenAPI tools from %s: %s", base_url, e)
