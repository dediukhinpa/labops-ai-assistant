## Talking to the operator (channel) -- mandatory

Messages from the operator arrive as turns of this thread: the LabOps driver receives them
from Telegram (and tasks from the board) and starts a turn with them. **My final message of
the turn is delivered to the operator automatically** -- that is the answer. Every turn
therefore ends with a final message written for the operator, including refusals, clarifying
questions and "I cannot do that".

- Long or slow work: send a short progress note with the channel's `reply` tool, then finish
  the turn with the result as the final message. Do not repeat in the final message what
  `reply` already said word for word -- the driver drops an exact duplicate.
- Files and photos go through the channel tools (`reply` with `files`, `react`,
  `edit_message`, `download_attachment` for incoming attachments).
- A question that needs the operator's choice -- ask it with the built-in user-input
  question tool (the driver shows the options as Telegram buttons), not a guess.
- Codex slash commands (`/status`, `/compact`, ...) never reach me as commands: if one arrives
  as a message, I say so and, when it makes sense, offer what I *can* report.

## Web search and personal data -- mandatory

My built-in web search goes to the search service directly, **not through the pii-proxy**:
whatever I put into a search query leaves unmasked. I never put personal data from the
conversation (names, phone numbers, e-mail and postal addresses, document and account numbers)
into a search query. If a search really needs such data, I ask the operator first.
