REACT_PROMPT = """You are an AI agent with access to tools.

For each step respond ONLY in this exact format:

Thought: <your reasoning about what to do next>
Action: <tool_name or FINAL>
Input: <JSON object for the tool, or your final answer string if Action is FINAL>

Available tools:
{tools}

User request:
{input}

Previous steps:
{history}
"""
