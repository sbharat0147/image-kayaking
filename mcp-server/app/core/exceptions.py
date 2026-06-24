from fastapi import Request
from fastapi.responses import JSONResponse


class ToolNotFoundError(Exception):
    def __init__(self, name: str):
        self.name = name
        super().__init__(f"Tool not found: {name}")


class ExecutionError(Exception):
    def __init__(self, tool: str, detail: str):
        self.tool = tool
        self.detail = detail
        super().__init__(f"Execution failed for tool '{tool}': {detail}")


class LLMBackendError(Exception):
    def __init__(self, backend: str, detail: str):
        self.backend = backend
        super().__init__(f"LLM backend '{backend}' error: {detail}")


async def tool_not_found_handler(request: Request, exc: ToolNotFoundError):
    return JSONResponse(status_code=404, content={"error": str(exc)})


async def execution_error_handler(request: Request, exc: ExecutionError):
    return JSONResponse(status_code=502, content={"error": str(exc), "tool": exc.tool})


async def llm_error_handler(request: Request, exc: LLMBackendError):
    return JSONResponse(status_code=503, content={"error": str(exc), "backend": exc.backend})
