HIGH_COMPLEXITY_KEYWORDS = {"analyze", "compare", "reason", "explain", "code", "debug", "summarize", "plan"}
MEDIUM_COMPLEXITY_KEYWORDS = {"list", "search", "find", "describe", "generate"}


def estimate_complexity(prompt: str) -> str:
    lower = prompt.lower()

    if len(prompt) > 2000:
        return "high"

    if any(w in lower for w in HIGH_COMPLEXITY_KEYWORDS):
        return "high"

    if any(w in lower for w in MEDIUM_COMPLEXITY_KEYWORDS):
        return "medium"

    return "low"
