import json
import logging
import re
from typing import Callable, Awaitable

from app.agent.state import AgentState
from app.agent.tool_filter import get_relevant_tools
from app.agent.prompts import REACT_PROMPT
from app.executor.dispatcher import dispatch
from app.core.config import settings

logger = logging.getLogger("mcp_server.agent")


def _parse_llm_step(text: str) -> dict:
    """Extract Thought / Action / Input from LLM response text."""
    thought = re.search(r"Thought:\s*(.+?)(?=\nAction:|$)", text, re.S)
    action = re.search(r"Action:\s*(\S+)", text)
    input_match = re.search(r"Input:\s*(.+?)$", text, re.S)

    raw_input = (input_match.group(1).strip() if input_match else "")

    # Try to parse Input as JSON; fall back to raw string
    try:
        parsed_input = json.loads(raw_input)
    except (json.JSONDecodeError, ValueError):
        parsed_input = raw_input

    return {
        "thought": thought.group(1).strip() if thought else "",
        "action": action.group(1).strip() if action else "FINAL",
        "input": parsed_input,
    }


async def run_agent(user_input: str, llm: Callable[..., Awaitable[dict]]) -> AgentState:
    """
    ReAct agent loop.

    llm: async callable accepting (prompt=str) and returning a dict with key 'response'.
    """
    state = AgentState(user_input=user_input)

    for _ in range(settings.agent_max_iterations):
        relevant_tools = get_relevant_tools(state.user_input)

        tool_list = "\n".join(
            f"{t.name}: {t.description}" for t in relevant_tools
        )

        prompt = REACT_PROMPT.format(
            tools=tool_list,
            input=state.user_input,
            history="\n".join(str(s) for s in state.steps) or "None",
        )

        llm_result = await llm(prompt=prompt)
        raw_text = llm_result.get("response", "")
        logger.debug("LLM raw output: %s", raw_text)

        step = _parse_llm_step(raw_text)
        state.steps.append(step)

        if step["action"].upper() == "FINAL":
            state.final_answer = str(step["input"]) if step["input"] else raw_text
            break

        # Execute the chosen tool
        try:
            tool_result = await dispatch(step["action"], step["input"] if isinstance(step["input"], dict) else {})
            state.tool_results.append(tool_result)
            state.tools_used.append(step["action"])
            state.user_input += f"\nTool '{step['action']}' result: {json.dumps(tool_result)}"
        except Exception as e:
            logger.warning("Tool execution failed: %s", e)
            state.user_input += f"\nTool '{step['action']}' error: {e}"

        state.iteration += 1

    if not state.final_answer:
        state.final_answer = "Agent reached max iterations without a final answer."

    return state
