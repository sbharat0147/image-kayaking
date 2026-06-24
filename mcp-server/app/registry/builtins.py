from app.registry.tool_registry import registry
from app.models.tool import Tool


def register_builtin_tools():
    """Register built-in inference tools for Ollama and vLLM."""
    registry.register(Tool(
        name="ollama_generate",
        description="Generate text using the local Ollama inference server.",
        input_schema={
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "The prompt to send to the model"}
            },
            "required": ["prompt"]
        },
        backend_type="ollama",
    ))

    registry.register(Tool(
        name="vllm_chat",
        description="Chat completion using the local vLLM inference server.",
        input_schema={
            "type": "object",
            "properties": {
                "messages": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "OpenAI-style messages array"
                }
            },
            "required": ["messages"]
        },
        backend_type="vllm",
    ))
