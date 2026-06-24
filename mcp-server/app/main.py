from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.core.logging import setup_logging, logger
from app.core.exceptions import (
    ToolNotFoundError, ExecutionError, LLMBackendError,
    tool_not_found_handler, execution_error_handler, llm_error_handler,
)
from app.registry.loader import load_static_tools, load_openapi_tools
from app.registry.builtins import register_builtin_tools
from app.routers import health, tools, execute, inference, agent


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_logging(settings.debug)
    logger.info("Starting MCP Server v%s", settings.app_version)

    # 1. Register built-in LLM tools (ollama_generate, vllm_chat)
    register_builtin_tools()

    # 2. Load static tool definitions from tools/*.json
    load_static_tools()

    # 3. Auto-discover tools from upstream FastAPI services
    upstream = settings.upstream_service_list()
    if upstream:
        logger.info("Discovering tools from %d upstream services...", len(upstream))
        await load_openapi_tools(upstream)
    else:
        logger.info("No UPSTREAM_SERVICES configured — skipping OpenAPI discovery")

    logger.info("Tool registry ready: %d tools registered", __import__('app.registry.tool_registry', fromlist=['registry']).registry.count())
    yield
    logger.info("MCP Server shutting down")


app = FastAPI(
    title=settings.app_name,
    version=settings.app_version,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_exception_handler(ToolNotFoundError, tool_not_found_handler)
app.add_exception_handler(ExecutionError, execution_error_handler)
app.add_exception_handler(LLMBackendError, llm_error_handler)

app.include_router(health.router)
app.include_router(tools.router, prefix="/tools")
app.include_router(execute.router, prefix="/execute")
app.include_router(inference.router, prefix="/inference")
app.include_router(agent.router, prefix="/agent")
