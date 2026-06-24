from pydantic_settings import BaseSettings
from typing import List


class Settings(BaseSettings):
    # Server
    app_name: str = "MCP Server"
    app_version: str = "1.0.0"
    debug: bool = False

    # Auth
    api_key: str = "changeme-mcp-api-key"

    # Upstream FastAPI services — comma-separated base URLs
    # e.g. http://notes-service:8000,http://search-service:8000
    upstream_services: str = ""

    # Ollama
    ollama_url: str = "http://localhost:11434"
    ollama_model: str = "llama3"
    ollama_timeout: int = 120

    # vLLM
    vllm_url: str = "http://localhost:8000"
    vllm_model: str = "qwen"
    vllm_timeout: int = 120

    # Embeddings model (sentence-transformers)
    embedding_model: str = "all-MiniLM-L6-v2"

    # Agent
    agent_max_iterations: int = 5
    agent_top_k_tools: int = 6

    # LLM routing
    llm_default_backend: str = "ollama"  # ollama | vllm

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"

    def upstream_service_list(self) -> List[str]:
        if not self.upstream_services:
            return []
        return [u.strip() for u in self.upstream_services.split(",") if u.strip()]


settings = Settings()
