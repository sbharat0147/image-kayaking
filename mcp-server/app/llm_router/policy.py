from dataclasses import dataclass


@dataclass
class RoutingPolicy:
    prefer_speed: bool = True
    prefer_quality: bool = False
    max_tokens_threshold: int = 4096
