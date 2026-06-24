from typing import List
from app.models.tool import Tool
from app.integrations.openapi.converter import convert_path_to_tool


def parse_openapi(spec: dict, base_url: str) -> List[Tool]:
    tools = []
    paths = spec.get("paths", {})
    for path, methods in paths.items():
        for method, operation in methods.items():
            if method.upper() not in ("GET", "POST", "PUT", "PATCH", "DELETE"):
                continue
            tool = convert_path_to_tool(path, method, operation, spec, base_url)
            if tool:
                tools.append(tool)
    return tools
