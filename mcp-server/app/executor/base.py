from abc import ABC, abstractmethod
from app.models.tool import Tool


class BaseExecutor(ABC):
    @abstractmethod
    async def execute(self, tool: Tool, args: dict) -> dict:
        ...
