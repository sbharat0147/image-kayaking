from app.registry.tool_registry import registry
from app.executor.http_executor import execute_http
from app.executor.ollama_executor import execute_ollama
from app.executor.vllm_executor import execute_vllm
from app.llm_router.llm_router import route_llm_request
from app.core.exceptions import ExecutionError


async def dispatch(tool_name: str, args: dict) -> dict:
    tool = registry.get(tool_name)  # raises ToolNotFoundError if missing

    if tool.backend_type == "http":
        return await execute_http(tool, args)

    if tool.backend_type == "ollama":
        return await execute_ollama(args)

    if tool.backend_type == "vllm":
        return await execute_vllm(args)

    raise ExecutionError(tool_name, f"Unknown backend type: {tool.backend_type}")


async def dispatch_llm(prompt: str = "", messages: list = None, backend: str = None) -> dict:
    """Route an LLM request to Ollama or vLLM based on complexity or explicit override."""
    chosen = backend or route_llm_request(prompt or (messages[-1]["content"] if messages else ""))

    if chosen == "ollama":
        return await execute_ollama({"prompt": prompt, "messages": messages})

    if chosen == "vllm":
        return await execute_vllm({"prompt": prompt, "messages": messages or []})

    raise ExecutionError("llm", f"Unknown backend: {chosen}")
