from app.llm_router.scoring import estimate_complexity
from app.llm_router.policy import RoutingPolicy
from app.core.config import settings

_default_policy = RoutingPolicy()


def route_llm_request(prompt: str, policy: RoutingPolicy = None) -> str:
    """Return 'ollama' or 'vllm' based on prompt complexity and policy."""
    policy = policy or _default_policy
    complexity = estimate_complexity(prompt)

    if complexity == "low":
        return "ollama"

    if complexity == "medium":
        return "vllm" if policy.prefer_quality else "ollama"

    # high complexity → always vLLM if available, else fall back
    return "vllm"
