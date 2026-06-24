from app.llm_router.scoring import estimate_complexity
from app.llm_router.policy import RoutingPolicy
from app.core.config import settings

_default_policy = RoutingPolicy()


def route_llm_request(prompt: str, policy: RoutingPolicy = None) -> str:
    """Return 'ollama' or 'vllm' based on prompt complexity, policy, and availability."""
    policy = policy or _default_policy
    default = settings.llm_default_backend  # honour operator config

    complexity = estimate_complexity(prompt)

    if complexity == "low":
        return "ollama"

    if complexity == "medium":
        preferred = "vllm" if policy.prefer_quality else "ollama"
    else:
        # high complexity
        preferred = "vllm"

    # Fall back to default backend when vLLM is not configured
    if preferred == "vllm" and default != "vllm":
        return default

    return preferred
