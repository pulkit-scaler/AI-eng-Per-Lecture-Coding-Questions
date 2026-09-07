#!/usr/bin/env python3
"""The Orenford Dispatch newsroom service.

YOU WRITE THIS FILE. It is a service, not a script: it is started once and left
running, and the desk talks to it over HTTP.

    python3 serve.py                    starts it on http://127.0.0.1:8300
    nohup python3 serve.py > serve.log 2>&1 &     leaves it running

The plumbing is provided. Define a handler that takes the request body and
returns the briefing as a dict, then hand it to the kit:

    import news_kit as kit

    def handle_brief(payload):
        assignment_id = payload["assignment"]
        ...
        return {...}

    if __name__ == "__main__":
        kit.run_service(handle_brief)

`kit.run_service` answers `GET /health` for you and routes `POST /brief` to your
handler. What the briefing has to contain is in the problem statement.

Everything the newsroom provides is importable from `news_kit`:

    kit.load_assignment(assignment_id)   assignment, commissioned, brief
    kit.assignment_ids()
    kit.get_chat_model(role)             role: planner researcher writer critic
    kit.records_desk, kit.wire_desk, kit.people_desk
    kit.DESK_TOOLS, kit.DESKS, kit.DESK_ORDER, kit.MAX_REVISIONS
    kit.WireError                        raised when a desk is out of service
    kit.PLANNER_SYSTEM, kit.RESEARCHER_SYSTEM, kit.WRITER_SYSTEM,
    kit.CRITIC_SYSTEM
    kit.plan_prompt, kit.research_prompt, kit.draft_prompt, kit.critique_prompt

Split this into modules beside it if you prefer; only the service and the JSON
it answers with are fixed.
"""
import news_kit as kit


def handle_brief(payload):
    raise NotImplementedError(
        "serve.py is not implemented yet: asked for %r"
        % (payload.get("assignment") if isinstance(payload, dict) else payload)
    )


if __name__ == "__main__":
    kit.run_service(handle_brief)
