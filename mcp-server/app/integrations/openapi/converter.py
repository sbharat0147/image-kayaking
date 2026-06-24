import re
from typing import Optional
from app.models.tool import Tool


def _sanitize_name(name: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_]", "_", name).strip("_")


def convert_path_to_tool(
    path: str, method: str, operation: dict, spec: dict, base_url: str
) -> Optional[Tool]:
    if not operation:
        return None

    # Derive a clean tool name from operationId or method+path
    raw_name = operation.get("operationId") or f"{method}_{path}"
    tool_name = _sanitize_name(raw_name)

    description = operation.get("summary") or operation.get("description") or tool_name

    # Build input schema from request body (POST/PUT/PATCH) or query params (GET)
    input_schema: dict = {"type": "object", "properties": {}, "required": []}

    request_body = operation.get("requestBody", {})
    if request_body:
        content = request_body.get("content", {})
        json_schema = (
            content.get("application/json", {}).get("schema", {})
        )
        if "$ref" in json_schema:
            json_schema = _resolve_ref(json_schema["$ref"], spec)
        input_schema = json_schema or input_schema

    # Also capture path/query parameters
    for param in operation.get("parameters", []):
        pname = param.get("name")
        pschema = param.get("schema", {"type": "string"})
        if pname:
            input_schema.setdefault("properties", {})[pname] = pschema
            if param.get("required"):
                input_schema.setdefault("required", []).append(pname)

    return Tool(
        name=tool_name,
        description=description,
        input_schema=input_schema,
        backend_type="http",
        method=method.upper(),
        endpoint=f"{base_url.rstrip('/')}{path}",
        source_service=base_url,
    )


def _resolve_ref(ref: str, spec: dict) -> dict:
    """Resolve a $ref like '#/components/schemas/Foo' from the spec."""
    try:
        parts = ref.lstrip("#/").split("/")
        node = spec
        for part in parts:
            node = node[part]
        return node
    except (KeyError, TypeError):
        return {}
